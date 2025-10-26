#!/bin/sh
set -e

# Set múi giờ (mặc định Asia/Ho_Chi_Minh, có thể override qua env TZ)
TZ=${TZ:-Asia/Ho_Chi_Minh}
export TZ

# Hàm log sạch
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}
error() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}
success() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Biến môi trường và mặc định
ENC_PATH=${ENC_PATH:-/encrypted}
DEC_PATH=${DEC_PATH:-/decrypted}
TIMEOUT=${TIMEOUT:-7200}
WEBDAV_CONFIG=${WEBDAV_CONFIG:-/tmp/webdav.yml}
WEBDAV_USER=${WEBDAV_USER:-admin}
WEBDAV_PASS=${WEBDAV_PASS:-admin}
WEBDAV_PORT=${WEBDAV_PORT:-6065}
GOCRYPTFS_PASS_FILE=${GOCRYPTFS_PASS_FILE:-/run/secrets/gocryptfs_pass}

# Tạo thư mục cần thiết
log "📁 Creating directories: $ENC_PATH, $DEC_PATH"
mkdir -p "$ENC_PATH" "$DEC_PATH" || { error "Failed to create directories"; exit 1; }

# 🔑 Load password cho gocryptfs
if [ -f "$GOCRYPTFS_PASS_FILE" ]; then
  log "🔍 Using password from file: $GOCRYPTFS_PASS_FILE"
  PASS_FILE="$GOCRYPTFS_PASS_FILE"
elif [ -n "$PASSWD" ]; then
  log "🔍 Using password from PASSWD env"
  PASS_FILE="/tmp/pass.tmp"
  echo "$PASSWD" > "$PASS_FILE"
  chmod 600 "$PASS_FILE" || { error "Failed to set permissions for $PASS_FILE"; exit 1; }
else
  error "No password found (neither $GOCRYPTFS_PASS_FILE nor PASSWD)"
  exit 1
fi

# 🧱 Tạo file webdav.yml
log "🔧 Generating WebDAV config at $WEBDAV_CONFIG"
cat > "$WEBDAV_CONFIG" <<EOF
address: 0.0.0.0
port: $WEBDAV_PORT
directory: $DEC_PATH
users:
  - username: $WEBDAV_USER
    password: $WEBDAV_PASS
    permissions: CRUD
EOF
[ $? -eq 0 ] || { error "Failed to create $WEBDAV_CONFIG"; exit 1; }

# 🧱 Init gocryptfs nếu cần
if [ ! -f "${ENC_PATH}/gocryptfs.conf" ]; then
  if [ ! -d "$ENC_PATH" ]; then
    log "🔧 Creating and initializing new encrypted folder at $ENC_PATH"
    mkdir -p "$ENC_PATH" || { error "Failed to create $ENC_PATH"; exit 1; }
    gocryptfs -init --passfile "$PASS_FILE" "$ENC_PATH" >> /var/log/gocryptfs.log 2>&1 || {
      error "Failed to initialize gocryptfs"
      exit 1
    }
  elif [ -n "$(find "$ENC_PATH" -maxdepth 0 -empty 2>/dev/null)" ]; then
    log "🔧 Initializing new encrypted folder at $ENC_PATH"
    gocryptfs -init --passfile "$PASS_FILE" "$ENC_PATH" >> /var/log/gocryptfs.log 2>&1 || {
      error "Failed to initialize gocryptfs"
      exit 1
    }
  else
    log "⚠️ $ENC_PATH is not empty and no gocryptfs.conf found — skipping initialization"
  fi
fi

# 🔓 Mount gocryptfs
log "🔓 Mounting gocryptfs: $ENC_PATH -> $DEC_PATH"
gocryptfs -nosyslog -allow_other --passfile "$PASS_FILE" "$ENC_PATH" "$DEC_PATH" >> /var/log/gocryptfs.log 2>&1 &
PID_FUSE=$!
sleep 1
if ! mountpoint -q "$DEC_PATH"; then
  error "Failed to mount $DEC_PATH"
  exit 1
fi
success "Mounted $DEC_PATH successfully"

# Start webdav
log "🌐 Starting WebDAV server on port $WEBDAV_PORT"
webdav --config "$WEBDAV_CONFIG" >> /var/log/webdav.log 2>&1 &
PID_WEBDAV=$!
sleep 1
if ! kill -0 "$PID_WEBDAV" 2>/dev/null; then
  error "Failed to start WebDAV server"
  cat /var/log/webdav.log >&2
  exit 1
fi
success "WebDAV server started (PID: $PID_WEBDAV)"

# Wait for timeout
log "⏳ Waiting for $TIMEOUT seconds"
sleep "$TIMEOUT"

# Cleanup
log "🛑 Cleaning up..."
if [ -n "$PID_WEBDAV" ] && kill -0 "$PID_WEBDAV" 2>/dev/null; then
  log "🛑 Stopping WebDAV (PID: $PID_WEBDAV)"
  kill "$PID_WEBDAV" || error "Failed to kill WebDAV process"
fi
if [ -n "$PID_FUSE" ] && kill -0 "$PID_FUSE" 2>/dev/null; then
  log "🛑 Stopping gocryptfs (PID: $PID_FUSE)"
  kill "$PID_FUSE" || error "Failed to kill gocryptfs process"
fi
if mountpoint -q "$DEC_PATH"; then
  log "🛑 Unmounting $DEC_PATH"
  fusermount -u "$DEC_PATH" 2>/dev/null || umount "$DEC_PATH" 2>/dev/null || error "Failed to unmount $DEC_PATH"
else
  log "ℹ️ $DEC_PATH is not mounted, skipping unmount"
fi

# Dọn file tạm
[ "$PASS_FILE" = "/tmp/pass.tmp" ] && rm -f "$PASS_FILE" && log "🗑️ Removed temporary password file"
rm -f "$WEBDAV_CONFIG" && log "🗑️ Removed temporary WebDAV config"
success "Cleanup completed"

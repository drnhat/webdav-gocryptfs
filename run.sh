#!/bin/sh
set -e

# Set múi giờ
TZ=${TZ:-Asia/Ho_Chi_Minh}
export TZ

# Hàm log và kiểm tra lỗi
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1: $2"; }
check() { [ $? -eq 0 ] || { log ERROR "$1"; exit 1; }; }

# Biến môi trường
ENC_PATH=${ENC_PATH:-/encrypted}
DEC_PATH=${DEC_PATH:-/decrypted}
TIMEOUT=${TIMEOUT:-7200}
WEBDAV_CONFIG=${WEBDAV_CONFIG:-/tmp/webdav.yml}
WEBDAV_USER=${WEBDAV_USER:-admin}
WEBDAV_PASS=${WEBDAV_PASS:-admin}
WEBDAV_PORT=${WEBDAV_PORT:-6065}
GOCRYPTFS_PASS_FILE=${GOCRYPTFS_PASS_FILE:-/run/secrets/gocryptfs_pass}

# Tạo thư mục
log INFO "Creating directories: $ENC_PATH, $DEC_PATH"
mkdir -p "$ENC_PATH" "$DEC_PATH"; check "Failed to create directories"

# Load password
if [ -f "$GOCRYPTFS_PASS_FILE" ]; then
  log INFO "Using password from file: $GOCRYPTFS_PASS_FILE"
  PASS_FILE="$GOCRYPTFS_PASS_FILE"
elif [ -n "$PASSWD" ]; then
  log INFO "Using password from PASSWD env"
  PASS_FILE="/tmp/pass.tmp"
  echo "$PASSWD" > "$PASS_FILE"
  chmod 600 "$PASS_FILE"; check "Failed to set permissions for $PASS_FILE"
else
  log ERROR "No password found (neither $GOCRYPTFS_PASS_FILE nor PASSWD)"
  exit 1
fi

# Tạo webdav.yml
log INFO "Generating WebDAV config at $WEBDAV_CONFIG"
cat > "$WEBDAV_CONFIG" <<EOF
address: 0.0.0.0
port: $WEBDAV_PORT
directory: $DEC_PATH
users:
  - username: $WEBDAV_USER
    password: $WEBDAV_PASS
    permissions: CRUD
EOF
check "Failed to create $WEBDAV_CONFIG"

# Init gocryptfs
if [ ! -f "${ENC_PATH}/gocryptfs.conf" ]; then
  [ -d "$ENC_PATH" ] || mkdir -p "$ENC_PATH"; check "Failed to create $ENC_PATH"
  if [ -z "$(find "$ENC_PATH" -maxdepth 0 -empty 2>/dev/null)" ]; then
    log INFO "$ENC_PATH not empty and no gocryptfs.conf — skipping initialization"
  else
    log INFO "Initializing encrypted folder at $ENC_PATH"
    gocryptfs -init --passfile "$PASS_FILE" "$ENC_PATH" >> /var/log/gocryptfs.log 2>&1
    check "Failed to initialize gocryptfs"
  fi
fi

# Mount gocryptfs
log INFO "Mounting gocryptfs: $ENC_PATH -> $DEC_PATH"
gocryptfs -nosyslog -allow_other --passfile "$PASS_FILE" "$ENC_PATH" "$DEC_PATH" >> /var/log/gocryptfs.log 2>&1 &
PID_FUSE=$!
sleep 1
mountpoint -q "$DEC_PATH"; check "Failed to mount $DEC_PATH"
log SUCCESS "Mounted $DEC_PATH"

# Start webdav
log INFO "Starting WebDAV server on port $WEBDAV_PORT"
webdav --config "$WEBDAV_CONFIG" >> /var/log/webdav.log 2>&1 &
PID_WEBDAV=$!
sleep 1
kill -0 "$PID_WEBDAV" 2>/dev/null; check "Failed to start WebDAV server"
log SUCCESS "WebDAV server started (PID: $PID_WEBDAV)"

# Wait for timeout
log INFO "Waiting for $TIMEOUT seconds"
sleep "$TIMEOUT"

# Cleanup
log INFO "Cleaning up..."
[ -n "$PID_WEBDAV" ] && kill -0 "$PID_WEBDAV" 2>/dev/null && { log INFO "Stopping WebDAV (PID: $PID_WEBDAV)"; kill "$PID_WEBDAV" || log ERROR "Failed to kill WebDAV"; }
[ -n "$PID_FUSE" ] && kill -0 "$PID_FUSE" 2>/dev/null && { log INFO "Stopping gocryptfs (PID: $PID_FUSE)"; kill "$PID_FUSE" || log ERROR "Failed to kill gocryptfs"; }
mountpoint -q "$DEC_PATH" && { log INFO "Unmounting $DEC_PATH"; fusermount -u "$DEC_PATH" 2>/dev/null || umount "$DEC_PATH" 2>/dev/null || log ERROR "Failed to unmount $DEC_PATH"; } || log INFO "$DEC_PATH not mounted, skipping unmount"
[ "$PASS_FILE" = "/tmp/pass.tmp" ] && rm -f "$PASS_FILE" && log INFO "Removed temporary password file"
rm -f "$WEBDAV_CONFIG" && log INFO "Removed temporary WebDAV config"
log SUCCESS "Cleanup completed"
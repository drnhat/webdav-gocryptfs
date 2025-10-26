#!/bin/sh
set -e

# Set múi giờ
TZ=${TZ:-Asia/Ho_Chi_Minh}
export TZ

# Hàm log và kiểm tra lỗi
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1: $2"; }
check() {
  [ $? -eq 0 ] || {
    log ERROR "$1"
    [ -f /var/log/lighttpd.log ] && log ERROR "lighttpd log:" && cat /var/log/lighttpd.log >&2
    [ -f "$LIGHTTPD_CONFIG" ] && log ERROR "lighttpd config:" && cat "$LIGHTTPD_CONFIG" >&2
    [ -f /tmp/webdav.passwd ] && log ERROR "webdav passwd:" && cat /tmp/webdav.passwd >&2
    log ERROR "Directory permissions:" && ls -ld "$DEC_PATH" >&2
    log ERROR "Passwd file permissions:" && ls -l /tmp/webdav.passwd >&2
    log ERROR "Lighttpd modules:" && ls /usr/lib/lighttpd >&2
    log ERROR "Lighttpd version:" && lighttpd -v >&2
    exit 1
  }
}

# Cleanup khi container dừng
cleanup() {
  log INFO "Cleaning up..."
  [ -n "$PID_LIGHTTPD" ] && kill -0 "$PID_LIGHTTPD" 2>/dev/null && { log INFO "Stopping lighttpd (PID: $PID_LIGHTTPD)"; kill "$PID_LIGHTTPD" || log ERROR "Failed to kill lighttpd"; }
  [ -n "$PID_FUSE" ] && kill -0 "$PID_FUSE" 2>/dev/null && { log INFO "Stopping gocryptfs (PID: $PID_FUSE)"; kill "$PID_FUSE" || log ERROR "Failed to kill gocryptfs"; }
  mountpoint -q "$DEC_PATH" && { log INFO "Unmounting $DEC_PATH"; fusermount -u "$DEC_PATH" 2>/dev/null || umount "$DEC_PATH" 2>/dev/null || log ERROR "Failed to unmount $DEC_PATH"; } || log INFO "$DEC_PATH not mounted, skipping unmount"
  [ "$PASS_FILE" = "/tmp/pass.tmp" ] && rm -f "$PASS_FILE" && log INFO "Removed temporary password file"
  rm -f "$LIGHTTPD_CONFIG" /tmp/webdav.passwd && log INFO "Removed temporary lighttpd config and passwd"
  log SUCCESS "Cleanup completed"
}
trap cleanup EXIT

# Biến môi trường
ENC_PATH=${ENC_PATH:-/encrypted}
DEC_PATH=${DEC_PATH:-/decrypted}
TIMEOUT=${TIMEOUT:-7200}
LIGHTTPD_CONFIG=${LIGHTTPD_CONFIG:-/tmp/lighttpd.conf}
WEBDAV_USER=${WEBDAV_USER:-admin}
WEBDAV_PORT=${WEBDAV_PORT:-6065}
GOCRYPTFS_PASS_FILE=${GOCRYPTFS_PASS_FILE:-/run/secrets/gocryptfs_pass}

# Tạo thư mục và log file
log INFO "Creating directories: $ENC_PATH, $DEC_PATH"
mkdir -p "$ENC_PATH" "$DEC_PATH" /var/log
touch /var/log/lighttpd.log
chown lighttpd:lighttpd /var/log/lighttpd.log
chmod 644 /var/log/lighttpd.log
check "Failed to create directories or log file"

# Load password
if [ -f "$GOCRYPTFS_PASS_FILE" ]; then
  log INFO "Using password from file: $GOCRYPTFS_PASS_FILE"
  PASS_FILE="$GOCRYPTFS_PASS_FILE"
  WEBDAV_PASS=$(cat "$PASS_FILE" | tr -d '\r\n:' | tr -dc 'A-Za-z0-9_-')
elif [ -n "$PASSWD" ]; then
  log INFO "Using password from PASSWD env"
  PASS_FILE="/tmp/pass.tmp"
  WEBDAV_PASS=$(echo "$PASSWD" | tr -d '\r\n:' | tr -dc 'A-Za-z0-9_-')
  echo "$PASSWD" > "$PASS_FILE"
  chmod 600 "$PASS_FILE"; check "Failed to set permissions for $PASS_FILE"
else
  log ERROR "No password found (neither $GOCRYPTFS_PASS_FILE nor PASSWD)"
  exit 1
fi

# Kiểm tra password hợp lệ
[ -n "$WEBDAV_PASS" ] || { log ERROR "Password is empty after cleaning"; exit 1; }

# Tạo lighttpd.conf (với auth)
log INFO "Generating lighttpd config at $LIGHTTPD_CONFIG"
echo "$WEBDAV_USER:$WEBDAV_PASS" > /tmp/webdav.passwd
chown lighttpd:lighttpd /tmp/webdav.passwd
chmod 644 /tmp/webdav.passwd
check "Failed to create $LIGHTTPD_CONFIG or set passwd permissions"
cat > "$LIGHTTPD_CONFIG" <<EOF
server.document-root = "$DEC_PATH"
server.port = $WEBDAV_PORT
server.modules = ( "mod_webdav", "mod_auth", "mod_authn_file" )
webdav.activate = "enable"
webdav.is-readonly = "disable"
auth.backend = "plain"
auth.backend.plain.userfile = "/tmp/webdav.passwd"
auth.require = ( "/" => (
  "method" => "basic",
  "realm" => "WebDAV",
  "require" => "valid-user"
))
EOF
check "Failed to create $LIGHTTPD_CONFIG"

# Test lighttpd config
log INFO "Testing lighttpd config"
lighttpd -t -f "$LIGHTTPD_CONFIG" >> /var/log/lighttpd.log 2>&1
check "Failed to test lighttpd config"

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
chown lighttpd:lighttpd "$DEC_PATH"; chmod 755 "$DEC_PATH"; check "Failed to set permissions for $DEC_PATH"
log SUCCESS "Mounted $DEC_PATH"

# Kiểm tra port
log INFO "Checking if port $WEBDAV_PORT is available"
netstat -tuln | grep ":$WEBDAV_PORT " && { log ERROR "Port $WEBDAV_PORT is already in use"; exit 1; }

# Debug lighttpd modules and version
log INFO "Lighttpd modules:" && ls /usr/lib/lighttpd
log INFO "Lighttpd version:" && lighttpd -v

# Start lighttpd
log INFO "Starting lighttpd on port $WEBDAV_PORT"
lighttpd -D -f "$LIGHTTPD_CONFIG" 2>&1 | tee -a /var/log/lighttpd.log &
PID_LIGHTTPD=$!
sleep 1
kill -0 "$PID_LIGHTTPD" 2>/dev/null || { log ERROR "Failed to start lighttpd"; cat /var/log/lighttpd.log >&2; cat "$LIGHTTPD_CONFIG" >&2; cat /tmp/webdav.passwd >&2; ls -ld "$DEC_PATH" >&2; ls -l /tmp/webdav.passwd >&2; ls /usr/lib/lighttpd >&2; lighttpd -v >&2; exit 1; }
log SUCCESS "lighttpd started (PID: $PID_LIGHTTPD)"

# Wait for timeout or run indefinitely
if [ "$TIMEOUT" -eq 0 ]; then
  log INFO "Running indefinitely until stopped"
  while true; do sleep 3600; done
else
  log INFO "Waiting for $TIMEOUT seconds"
  sleep "$TIMEOUT"
fi
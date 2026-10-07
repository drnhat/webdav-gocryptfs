#!/bin/sh
# webdav-gocryptfs: mount kho gocryptfs rồi phục vụ plaintext qua WebDAV (lighttpd)
set -eu

TZ=${TZ:-Asia/Ho_Chi_Minh}
export TZ

log() { printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }
die() { log ERROR "$1" >&2; exit 1; }

# ---------- Cấu hình ----------
ENC_PATH=${ENC_PATH:-/encrypted}
DEC_PATH=${DEC_PATH:-/decrypted}
TIMEOUT=${TIMEOUT:-7200}                 # giây; 0 = chạy vô hạn
WEBDAV_USER=${WEBDAV_USER:-admin}
WEBDAV_PORT=${WEBDAV_PORT:-6065}
WEBDAV_READONLY=${WEBDAV_READONLY:-0}    # 1 = chỉ đọc
GOCRYPTFS_MOUNT=${GOCRYPTFS_MOUNT:-1}    # 0 = không mount, chỉ phục vụ DEC_PATH có sẵn
GOCRYPTFS_PASS_FILE=${GOCRYPTFS_PASS_FILE:-/run/secrets/gocryptfs_pass}
WEBDAV_PASS_FILE=${WEBDAV_PASS_FILE:-/run/secrets/webdav_pass}
LIGHTTPD_CONFIG=${LIGHTTPD_CONFIG:-/tmp/lighttpd.conf}

RUN_DIR=/tmp/lighttpd
PASSWD_FILE=$RUN_DIR/webdav.passwd

case $TIMEOUT      in ''|*[!0-9]*) die "TIMEOUT phải là số nguyên >= 0 (hiện: '$TIMEOUT')";; esac
case $WEBDAV_PORT  in ''|*[!0-9]*) die "WEBDAV_PORT phải là số (hiện: '$WEBDAV_PORT')";; esac
case $WEBDAV_USER  in ''|*[!A-Za-z0-9._@-]*) die "WEBDAV_USER chỉ gồm chữ, số, . _ @ -";; esac
case $WEBDAV_READONLY in 1|true|yes) RO=enable;; *) RO=disable;; esac

PASS_FILE=""; TMP_PASS=""; PID_FUSE=""; PID_LIGHTTPD=""; MOUNTED=0

is_mounted() { grep -qs " $DEC_PATH fuse.gocryptfs " /proc/mounts; }

# ---------- Cleanup ----------
cleanup() {
  trap - EXIT TERM INT
  log INFO "Cleaning up..."
  if [ -n "$PID_LIGHTTPD" ] && kill -0 "$PID_LIGHTTPD" 2>/dev/null; then
    log INFO "Stopping lighttpd (PID: $PID_LIGHTTPD)"
    kill "$PID_LIGHTTPD" 2>/dev/null || true
    wait "$PID_LIGHTTPD" 2>/dev/null || true
  fi
  if [ "$MOUNTED" = 1 ] && is_mounted; then
    log INFO "Unmounting $DEC_PATH"
    fusermount -u "$DEC_PATH" 2>/dev/null || fusermount -uz "$DEC_PATH" 2>/dev/null \
      || log ERROR "Failed to unmount $DEC_PATH"
  fi
  if [ -n "$PID_FUSE" ]; then
    kill "$PID_FUSE" 2>/dev/null || true
    wait "$PID_FUSE" 2>/dev/null || true
  fi
  rm -rf "$RUN_DIR" "$LIGHTTPD_CONFIG"
  [ -z "$TMP_PASS" ] || rm -f "$TMP_PASS"
  log INFO "Cleanup completed"
}
trap cleanup EXIT
trap 'log INFO "Received stop signal"; exit 0' TERM INT

mkdir -p "$ENC_PATH" "$DEC_PATH" "$RUN_DIR"
chmod 700 "$RUN_DIR"

# ---------- Mật khẩu gocryptfs ----------
if [ "$GOCRYPTFS_MOUNT" = 1 ]; then
  if [ -f "$GOCRYPTFS_PASS_FILE" ]; then
    log INFO "gocryptfs password: file $GOCRYPTFS_PASS_FILE"
    PASS_FILE=$GOCRYPTFS_PASS_FILE
  elif [ -n "${PASSWD:-}" ]; then
    log WARN "gocryptfs password: biến môi trường PASSWD (kém an toàn, nên dùng secret/file)"
    TMP_PASS=/tmp/pass.tmp
    ( umask 077; printf '%s\n' "$PASSWD" > "$TMP_PASS" )
    PASS_FILE=$TMP_PASS
  else
    die "Không có mật khẩu gocryptfs (thiếu $GOCRYPTFS_PASS_FILE và PASSWD)"
  fi
fi

# ---------- Mật khẩu WebDAV ----------
if [ -n "${WEBDAV_PASS:-}" ]; then
  :
elif [ -f "$WEBDAV_PASS_FILE" ]; then
  WEBDAV_PASS=$(tr -d '\r\n' < "$WEBDAV_PASS_FILE")
elif [ -n "$PASS_FILE" ]; then
  # Tương thích cũ: dùng lại mật khẩu vault (đã lọc ký tự)
  log WARN "WEBDAV_PASS chưa đặt: dùng lại mật khẩu gocryptfs cho WebDAV (nên đặt riêng)"
  WEBDAV_PASS=$(tr -d '\r\n:' < "$PASS_FILE" | tr -dc 'A-Za-z0-9_-')
else
  die "Không có mật khẩu WebDAV (đặt WEBDAV_PASS hoặc WEBDAV_PASS_FILE)"
fi
[ -n "$WEBDAV_PASS" ] || die "Mật khẩu WebDAV rỗng"

( umask 077; printf '%s:%s\n' "$WEBDAV_USER" "$WEBDAV_PASS" > "$PASSWD_FILE" )
unset WEBDAV_PASS PASSWD
chown -R lighttpd:lighttpd "$RUN_DIR"

# ---------- Khởi tạo + mount gocryptfs ----------
if [ "$GOCRYPTFS_MOUNT" = 1 ]; then
  if [ ! -f "$ENC_PATH/gocryptfs.conf" ]; then
    [ -z "$(ls -A "$ENC_PATH")" ] \
      || die "$ENC_PATH không rỗng nhưng không có gocryptfs.conf - từ chối khởi tạo"
    log INFO "Initializing encrypted folder at $ENC_PATH"
    gocryptfs -init -q -passfile "$PASS_FILE" "$ENC_PATH" || die "gocryptfs -init thất bại"
  fi

  fusermount -u "$DEC_PATH" 2>/dev/null || true   # dọn mount cũ bị treo (nếu có)

  log INFO "Mounting gocryptfs: $ENC_PATH -> $DEC_PATH"
  gocryptfs -fg -nosyslog -allow_other -passfile "$PASS_FILE" "$ENC_PATH" "$DEC_PATH" &
  PID_FUSE=$!

  i=0
  until is_mounted; do
    kill -0 "$PID_FUSE" 2>/dev/null || { PID_FUSE=""; die "gocryptfs thoát trước khi mount xong (sai mật khẩu?)"; }
    i=$((i + 1))
    [ "$i" -le 15 ] || die "Quá thời gian chờ mount $DEC_PATH"
    sleep 1
  done
  MOUNTED=1
  chown lighttpd:lighttpd "$DEC_PATH" || log WARN "Không chown được $DEC_PATH"
  chmod 755 "$DEC_PATH" || log WARN "Không chmod được $DEC_PATH"
  log INFO "Mounted $DEC_PATH"
else
  log INFO "GOCRYPTFS_MOUNT=0: chỉ phục vụ $DEC_PATH (không mount gocryptfs)"
fi

# ---------- lighttpd ----------
log INFO "Generating lighttpd config at $LIGHTTPD_CONFIG"
cat > "$LIGHTTPD_CONFIG" <<CONF
server.document-root = "$DEC_PATH"
server.port = $WEBDAV_PORT
server.username = "lighttpd"
server.groupname = "lighttpd"
server.errorlog = ""

# File lớn (video...): stream trực tiếp, không buffer cả file vào /tmp
server.stream-request-body = 2
server.stream-response-body = 2
server.upload-dirs = ( "$RUN_DIR" )

server.modules = ( "mod_webdav", "mod_auth", "mod_authn_file" )
dir-listing.activate = "enable"

webdav.activate = "enable"
webdav.is-readonly = "$RO"
# LOCK/PROPPATCH: macOS Finder và Windows cần để ghi file
webdav.sqlite-db-name = "$RUN_DIR/webdav-locks.db"

auth.backend = "plain"
auth.backend.plain.userfile = "$PASSWD_FILE"
auth.require = ( "/" => (
  "method" => "basic",
  "realm" => "WebDAV",
  "require" => "valid-user"
))
CONF

lighttpd -tt -f "$LIGHTTPD_CONFIG" || die "Cấu hình lighttpd không hợp lệ"

log INFO "Starting lighttpd on port $WEBDAV_PORT (readonly: $RO)"
lighttpd -D -f "$LIGHTTPD_CONFIG" &
PID_LIGHTTPD=$!
sleep 1
kill -0 "$PID_LIGHTTPD" 2>/dev/null || die "lighttpd không khởi động được (xem log phía trên)"
log INFO "lighttpd started (PID: $PID_LIGHTTPD)"

# ---------- Giám sát ----------
START=$(date +%s)
[ "$TIMEOUT" -eq 0 ] && log INFO "Running indefinitely until stopped" || log INFO "Will stop after ${TIMEOUT}s"

while kill -0 "$PID_LIGHTTPD" 2>/dev/null; do
  if [ -n "$PID_FUSE" ] && ! kill -0 "$PID_FUSE" 2>/dev/null; then
    PID_FUSE=""; die "gocryptfs đã dừng bất ngờ"
  fi
  if [ "$TIMEOUT" -gt 0 ] && [ $(( $(date +%s) - START )) -ge "$TIMEOUT" ]; then
    log INFO "Timeout ${TIMEOUT}s reached"
    exit 0
  fi
  sleep 2 &
  wait $! || true
done
die "lighttpd đã dừng bất ngờ"

FROM alpine:3.22

RUN apk add --no-cache fuse tzdata gocryptfs lighttpd lighttpd-mod_webdav lighttpd-mod_auth

ENV ENC_PATH=/encrypted \
    DEC_PATH=/decrypted \
    WEBDAV_PORT=6065 \
    TZ=Asia/Ho_Chi_Minh

COPY --chmod=755 run.sh /run.sh

EXPOSE 6065

# lighttpd còn sống và (nếu dùng gocryptfs trong container) vault đang được mount
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD pidof lighttpd >/dev/null && { [ "${GOCRYPTFS_MOUNT:-1}" = "0" ] || grep -qs " $DEC_PATH fuse.gocryptfs " /proc/mounts; }

ENTRYPOINT ["/run.sh"]

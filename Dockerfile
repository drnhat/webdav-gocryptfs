FROM alpine:3.22
# Dependencies
RUN apk add --no-cache fuse tzdata gocryptfs lighttpd lighttpd-mod_webdav lighttpd-mod_auth

# Copy script
COPY run.sh /run.sh

RUN chmod +x /run.sh

EXPOSE 6065
ENTRYPOINT ["/run.sh"]
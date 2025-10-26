FROM alpine:edge

# Dependencies
RUN apk add --no-cache fuse tzdata gocryptfs

# Copy webdav binary
COPY webdav /usr/local/bin/webdav
COPY run.sh /run.sh

RUN chmod +x /usr/local/bin/webdav /run.sh

EXPOSE 6065
ENTRYPOINT ["/run.sh"]

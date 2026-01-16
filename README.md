# webdav-gocryptfs

Docker image để giải mã (mount) một kho gocryptfs và phục vụ nội dung đã giải mã ra ngoài qua WebDAV (lighttpd + mod_webdav). Mục tiêu: bạn có thể chạy một container để mở truy cập an toàn lên thư mục mã hóa gocryptfs mà không cần cấu hình phức tạp trên host.

Image này chứa:
- gocryptfs để mount kho mã hóa (FUSE)
- lighttpd với mod_webdav và mod_auth để phục vụ WebDAV với Basic Auth
- script entrypoint (/run.sh) thực hiện: tải mật khẩu, khởi tạo (nếu cần), mount gocryptfs, khởi chạy lighttpd, và cleanup khi dừng container

Phiên bản cơ sở: Alpine Linux, image expose cổng 6065.

## Nội dung chính
- Dockerfile (base: alpine, cài đặt fuse, gocryptfs, lighttpd)
- Entrypoint script: /run.sh (thực hiện mount, start webdav, logs, cleanup)

## Tính năng
- Mount kho gocryptfs từ thư mục chứa dữ liệu mã hóa (ENC_PATH) sang thư mục plaintext (DEC_PATH) trong container
- Nếu kho chưa được khởi tạo và thư mục rỗng, script sẽ tự chạy `gocryptfs -init`
- WebDAV với Basic Auth (user:password lưu vào /tmp/webdav.passwd)
- Hỗ trợ lấy mật khẩu từ Docker secret/file (mặc định /run/secrets/gocryptfs_pass) hoặc từ biến môi trường PASSWD (không an toàn — chỉ dùng khi cần)
- Tự động unmount khi container dừng và xóa temporary files
- TIMEOUT (mặc định 7200s) để tự thoát sau một khoảng thời gian; TIMEOUT=0 để chạy vô thời hạn

## Biến môi trường (với giá trị mặc định)
- ENC_PATH=/encrypted  
  Thư mục chứa dữ liệu gocryptfs (trên host mount vào container).
- DEC_PATH=/decrypted  
  Thư mục đích để mount plaintext (được lighttpd phục vụ).
- GOCRYPTFS_PASS_FILE=/run/secrets/gocryptfs_pass  
  File chứa mật khẩu gocryptfs (ưu tiên). Nếu tồn tại, script dùng file này.
- PASSWD (không mặc định)  
  Nếu GOCRYPTFS_PASS_FILE không tồn tại, có thể cung cấp mật khẩu qua biến PASSWD (không an toàn).
- WEBDAV_USER=admin  
  Tên user Basic Auth cho WebDAV.
- WEBDAV_PORT=6065  
  Cổng mà lighttpd lắng nghe (Dockerfile EXPOSE 6065).
- LIGHTTPD_CONFIG=/tmp/lighttpd.conf  
  Đường dẫn config lighttpd được sinh bởi script.
- TIMEOUT=7200  
  Số giây container sẽ chạy trước khi tự thoát; `0` để chạy vô hạn.

Lưu ý xử lý mật khẩu: script đọc password từ file hoặc PASSWD, sau đó "làm sạch" chuỗi bằng:
tr -d '\r\n:' | tr -dc 'A-Za-z0-9_-'
(tức chỉ giữ chữ, số, dấu gạch dưới và gạch nối). Giá trị dùng trong file /tmp/webdav.passwd là `WEBDAV_USER:WEBDAV_PASS`.

## Build image
Từ thư mục chứa Dockerfile:
docker build -t drnhat/webdav-gocryptfs .

## Ví dụ chạy (recommended: dùng Docker secret/file)

1) Tạo thư mục và file mật khẩu trên host:
mkdir -p /srv/encrypted /srv/decrypted
printf '%s' "your-strong-password" > /srv/gocryptfs-pass
chmod 600 /srv/gocryptfs-pass

2) Chạy container và chia sẻ thiết bị FUSE (nếu bạn muốn mount gocryptfs bên trong container):
docker run -d \
  --name webdav-gocryptfs \
  --cap-add SYS_ADMIN \
  --device /dev/fuse \
  --security-opt apparmor:unconfined \
  -p 6065:6065 \
  -v /srv/encrypted:/encrypted:rw \
  -v /srv/decrypted:/decrypted:rw \
  -v /srv/gocryptfs-pass:/run/secrets/gocryptfs_pass:ro \
  -e GOCRYPTFS_PASS_FILE=/run/secrets/gocryptfs_pass \
  -e WEBDAV_PORT=6065 \
  -e WEBDAV_USER=admin \
  drnhat/webdav-gocryptfs

Truy cập WebDAV: http://HOST:6065/ (client WebDAV hoặc trình duyệt với Basic Auth).

Ghi chú:
- Quyền và device: để chạy FUSE trong container, cần chia sẻ /dev/fuse và cấp quyền (SYS_ADMIN) hoặc privileged; điều này có rủi ro bảo mật.
- Nếu không muốn chạy FUSE trong container: mount encrypted repository trên host bằng gocryptfs rồi mount thư mục plaintext vào container (xem phần "Chạy gocryptfs trên host").

## Ví dụ docker-compose
version: "3.7"
services:
  webdav:
    image: drnhat/webdav-gocryptfs
    container_name: webdav-gocryptfs
    cap_add:
      - SYS_ADMIN
    devices:
      - /dev/fuse:/dev/fuse
    security_opt:
      - apparmor:unconfined
    ports:
      - "6065:6065"
    volumes:
      - /srv/encrypted:/encrypted:rw
      - /srv/decrypted:/decrypted:rw
      - /srv/gocryptfs-pass:/run/secrets/gocryptfs_pass:ro
    environment:
      GOCRYPTFS_PASS_FILE: /run/secrets/gocryptfs_pass
      WEBDAV_USER: admin
      WEBDAV_PORT: 6065
      TIMEOUT: 0
    restart: unless-stopped

## Sử dụng gocryptfs trên host thay vì trong container (an toàn hơn)
1. Cài gocryptfs trên host (ví dụ apt install gocryptfs).
2. Tạo và mount:
gocryptfs -init /srv/encrypted
mkdir -p /srv/decrypted
gocryptfs /srv/encrypted /srv/decrypted
3. Chỉ chạy container webdav để phục vụ thư mục plaintext:
docker run -d -p 6065:6065 -v /srv/decrypted:/decrypted:ro -e WEBDAV_PORT=6065 -e WEBDAV_USER=admin drnhat/webdav-gocryptfs

Không cần chia sẻ /dev/fuse hoặc cap-add trong trường hợp này.

## Khởi tạo kho mã hóa (nếu bạn chưa có)
# Cài gocryptfs trên host
gocryptfs -init /srv/encrypted --passfile /path/to/passfile

Hoặc tương tác:
gocryptfs -init /srv/encrypted

## Logs & Debug
- lighttpd log: /var/log/lighttpd.log (script tạo file này)
- gocryptfs log: /var/log/gocryptfs.log (script redirect khi chạy)
- Khi script bắt lỗi, nó in ra chi tiết (lighttpd config, passwd file, quyền thư mục, danh sách modules lighttpd, version) để tiện debug.

Script cũng kiểm tra:
- Port WEBDAV_PORT có sẵn không (dùng netstat). Nếu bị chiếm sẽ exit.
- Mountpoint của DEC_PATH sau khi chạy gocryptfs.
- Nếu lighttpd không khởi động, script sẽ in log và cấu hình để debug.

## Quyền và bảo mật
- Không truyền mật khẩu qua biến môi trường công khai; ưu tiên file/secret (GOCRYPTFS_PASS_FILE).
- Nếu dùng PASSWD env: script tạo file tạm /tmp/pass.tmp (chmod 600) và xóa khi cleanup, nhưng vẫn kém an toàn.
- Nếu mount FUSE trong container: cần cân nhắc rủi ro (capabilities). Nếu có thể, mount trên host thay vì trong container.
- Khi mở ra internet, luôn đặt reverse proxy TLS (nginx/Caddy/Traefik) trước WebDAV.

## Xử lý lỗi thường gặp
- "No password found" — không có file GOCRYPTFS_PASS_FILE và không có PASSWD.
- "Failed to mount" — kiểm tra mật khẩu, cấu trúc kho, và quyền; thử mount trên host để xác minh.
- "Port ... is already in use" — đổi WEBDAV_PORT hoặc dừng service chiếm cổng.
- "device /dev/fuse not found" — host không có FUSE hoặc bạn chưa mount /dev/fuse vào container.

## Cleanup khi container dừng
- Script trap EXIT sẽ:
  - dừng lighttpd và gocryptfs (kill PID)
  - unmount DEC_PATH bằng fusermount -u hoặc umount
  - xóa file tạm mật khẩu (/tmp/pass.tmp nếu dùng PASSWD), /tmp/webdav.passwd và config tạm thời

## Ví dụ thao tác nhanh
- Build:
docker build -t webdav-gocryptfs .
- Chạy (gocryptfs chạy trong container):
docker run --rm -it --cap-add SYS_ADMIN --device /dev/fuse -v /srv/encrypted:/encrypted -v /srv/decrypted:/decrypted -v /srv/gocryptfs-pass:/run/secrets/gocryptfs_pass:ro -e GOCRYPTFS_PASS_FILE=/run/secrets/gocryptfs_pass -e WEBDAV_PORT=6065 webdav-gocryptfs

## License
MIT

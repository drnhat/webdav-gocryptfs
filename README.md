# webdav-gocryptfs

Docker image để mount một kho gocryptfs (FUSE), giải mã nội dung và phục vụ plaintext qua WebDAV (lighttpd + mod_webdav).  
Mục tiêu: chạy một container để phục vụ nội dung đã giải mã an toàn bằng Basic Auth.

Image này bao gồm:
- gocryptfs (FUSE) để mount kho mã hóa
- lighttpd với mod_webdav và mod_auth để phục vụ WebDAV với Basic Auth
- entrypoint script `/run.sh`:
  - đọc mật khẩu (Docker secret/file hoặc env)
  - khởi tạo repository nếu cần (`gocryptfs -init`)
  - mount gocryptfs
  - khởi chạy lighttpd
  - cleanup khi container dừng

Phiên bản cơ sở: Alpine Linux. Image expose cổng 6065.

---

## Nội dung chính
- `Dockerfile` (base: alpine, cài đặt fuse, gocryptfs, lighttpd)
- Entrypoint: `/run.sh` (mount, start webdav, logs, cleanup)

---

## Tính năng chính
- Mount kho gocryptfs từ `ENC_PATH` → `DEC_PATH` và phục vụ `DEC_PATH` qua WebDAV
- Nếu kho chưa khởi tạo và thư mục rỗng, script sẽ chạy `gocryptfs -init`
- WebDAV với Basic Auth (user:password lưu vào `/tmp/webdav.passwd`)
- Lấy mật khẩu từ Docker secret/file (`GOCRYPTFS_PASS_FILE`) hoặc từ biến môi trường `PASSWD` (không an toàn)
- Tự động unmount và xóa file tạm khi container dừng
- TIMEOUT (mặc định 7200s) để tự thoát; `TIMEOUT=0` để chạy vô hạn

---

## Biến môi trường (giá trị mặc định)
- `ENC_PATH=/encrypted`  
  Thư mục chứa dữ liệu gocryptfs (mount từ host vào container).
- `DEC_PATH=/decrypted`  
  Thư mục đích để mount plaintext (được lighttpd phục vụ).
- `GOCRYPTFS_PASS_FILE=/run/secrets/gocryptfs_pass`  
  File chứa mật khẩu gocryptfs (ưu tiên).
- `PASSWD` (không mặc định)  
  Nếu `GOCRYPTFS_PASS_FILE` không tồn tại, có thể cung cấp mật khẩu qua `PASSWD` (không an toàn).
- `WEBDAV_USER=admin`  
  Username cho Basic Auth.
- `WEBDAV_PORT=6065`  
  Port mà lighttpd lắng nghe.
- `LIGHTTPD_CONFIG=/tmp/lighttpd.conf`  
  Đường dẫn config lighttpd do script sinh.
- `TIMEOUT=7200`  
  Số giây container sẽ chạy trước khi tự thoát; `0` để chạy vô hạn.

Lưu ý xử lý mật khẩu: script đọc password từ file hoặc `PASSWD`, sau đó "làm sạch" chuỗi bằng:
```bash
tr -d '\r\n:' | tr -dc 'A-Za-z0-9_-'
```
Chỉ giữ chữ, số, dấu gạch dưới và dấu gạch ngang. File `/tmp/webdav.passwd` có định dạng `WEBDAV_USER:WEBDAV_PASS`.

---

## Build image
Từ thư mục chứa `Dockerfile`:
```bash
docker build -t drnhat/webdav-gocryptfs .
```

---

## Ví dụ chạy (khuyến nghị: dùng Docker secret/file)

1) Chuẩn bị trên host:
```bash
mkdir -p /srv/encrypted /srv/decrypted
printf '%s' "your-strong-password" > /srv/gocryptfs-pass
chmod 600 /srv/gocryptfs-pass
```

2) Chạy container (mount FUSE trong container):
```bash
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
```

Truy cập WebDAV: http://HOST:6065/ (client WebDAV hoặc trình duyệt, dùng Basic Auth).

Ghi chú quan trọng:
- Để mount FUSE trong container cần chia sẻ `/dev/fuse` và cấp capability `SYS_ADMIN` hoặc chạy privileged — có rủi ro bảo mật.
- Nếu không muốn chạy FUSE trong container: mount repository trên host và chia sẻ thư mục plaintext vào container (xem phần bên dưới).

---

## Ví dụ docker-compose
```yaml
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
```

---

## Chạy gocryptfs trên host (an toàn hơn)
Thay vì cấp quyền FUSE trong container, bạn có thể mount trên host và chỉ dùng container để phục vụ plaintext:

1. Cài gocryptfs trên host (VD: `apt install gocryptfs`).
2. Tạo và mount:
```bash
gocryptfs -init /srv/encrypted
mkdir -p /srv/decrypted
gocryptfs /srv/encrypted /srv/decrypted
```
3. Chạy container chỉ để phục vụ `/srv/decrypted`:
```bash
docker run -d -p 6065:6065 -v /srv/decrypted:/decrypted:ro -e WEBDAV_PORT=6065 -e WEBDAV_USER=admin drnhat/webdav-gocryptfs
```
Không cần chia sẻ `/dev/fuse` hoặc cấp `SYS_ADMIN`.

---

## Khởi tạo kho mã hóa (nếu bạn chưa có)
Trên host:
```bash
gocryptfs -init /srv/encrypted --passfile /path/to/passfile
# hoặc tương tác
gocryptfs -init /srv/encrypted
```

---

## Logs & Debug
- lighttpd log: `/var/log/lighttpd.log`
- gocryptfs log: `/var/log/gocryptfs.log`

Script in thông tin debug khi gặp lỗi (cấu hình lighttpd, passwd file, quyền thư mục, danh sách modules lighttpd, version).

Script kiểm tra:
- Port `WEBDAV_PORT` có sẵn (dùng netstat). Nếu bị chiếm sẽ exit.
- Mountpoint của `DEC_PATH` sau khi chạy gocryptfs.
- Nếu lighttpd không khởi động, script in log và config để debug.

---

## Bảo mật & Quyền
- Ưu tiên dùng file/secret (`GOCRYPTFS_PASS_FILE`) thay vì biến môi trường `PASSWD`.
- Nếu dùng `PASSWD`, script tạo file tạm `/tmp/pass.tmp` (chmod 600) và xóa khi cleanup — vẫn kém an toàn.
- Nếu phải chạy FUSE trong container: cân nhắc rủi ro khi cấp capabilities hoặc privileged. Tốt hơn: mount trên host.
- Khi mở ra Internet, luôn đặt reverse proxy TLS (nginx/Caddy/Traefik) trước WebDAV.

---

## Lỗi thường gặp & hướng xử lý
- "No password found" — không có file `GOCRYPTFS_PASS_FILE` và không có `PASSWD`.
- "Failed to mount" — kiểm tra mật khẩu, cấu trúc kho, quyền; thử mount trên host để xác minh.
- "Port ... is already in use" — đổi `WEBDAV_PORT` hoặc dừng service chiếm cổng.
- "device /dev/fuse not found" — host không có FUSE hoặc bạn chưa mount `/dev/fuse` vào container.

---

## Cleanup khi container dừng
`/run.sh` trap `EXIT` sẽ:
- dừng lighttpd và gocryptfs (kill PID)
- unmount `DEC_PATH` bằng `fusermount -u` hoặc `umount`
- xóa file tạm mật khẩu (`/tmp/pass.tmp` nếu dùng `PASSWD`), `/tmp/webdav.passwd` và config tạm thời

---

## Ví dụ thao tác nhanh
- Build:
```bash
docker build -t webdav-gocryptfs .
```
- Chạy (gocryptfs chạy trong container):
```bash
docker run --rm -it \
  --cap-add SYS_ADMIN --device /dev/fuse \
  -v /srv/encrypted:/encrypted \
  -v /srv/decrypted:/decrypted \
  -v /srv/gocryptfs-pass:/run/secrets/gocryptfs_pass:ro \
  -e GOCRYPTFS_PASS_FILE=/run/secrets/gocryptfs_pass \
  drnhat/webdav-gocryptfs
```

---

## License
MIT

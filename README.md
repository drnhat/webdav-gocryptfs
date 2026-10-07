# webdav-gocryptfs

Docker image mount một kho gocryptfs (FUSE), giải mã và phục vụ plaintext qua WebDAV (lighttpd + mod_webdav) với Basic Auth.
Thiết kế cho **chia sẻ nội bộ trong mạng LAN** (không có TLS; đừng mở ra Internet nếu không có reverse proxy TLS).

Image dựa trên Alpine, expose cổng 6065, entrypoint `/run.sh`:
- đọc mật khẩu (Docker secret/file hoặc env)
- khởi tạo kho nếu thư mục mã hóa còn rỗng (`gocryptfs -init`)
- mount gocryptfs, chạy lighttpd (WebDAV)
- unmount và dọn file tạm khi container dừng (`docker stop` được xử lý đúng)

---

## Biến môi trường

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `ENC_PATH` | `/encrypted` | Thư mục chứa dữ liệu mã hóa |
| `DEC_PATH` | `/decrypted` | Điểm mount plaintext, được WebDAV phục vụ |
| `GOCRYPTFS_PASS_FILE` | `/run/secrets/gocryptfs_pass` | File mật khẩu gocryptfs (ưu tiên) |
| `PASSWD` | – | Mật khẩu gocryptfs qua env (kém an toàn) |
| `WEBDAV_USER` | `admin` | Tên đăng nhập (chỉ gồm `A-Za-z0-9._@-`) |
| `WEBDAV_PASS_FILE` | `/run/secrets/webdav_pass` | File mật khẩu WebDAV |
| `WEBDAV_PASS` | – | Mật khẩu WebDAV qua env |
| `WEBDAV_PORT` | `6065` | Cổng lighttpd |
| `WEBDAV_READONLY` | `0` | `1` = chỉ đọc |
| `GOCRYPTFS_MOUNT` | `1` | `0` = không mount gocryptfs, chỉ phục vụ `DEC_PATH` có sẵn |
| `TIMEOUT` | `7200` | Số giây trước khi tự thoát (tự "khóa" kho); `0` = chạy vô hạn |
| `LIGHTTPD_CONFIG` | `/tmp/lighttpd.conf` | Nơi sinh config lighttpd |

**Mật khẩu WebDAV** nên đặt riêng (`WEBDAV_PASS_FILE` hoặc `WEBDAV_PASS`).
Nếu không đặt, script dùng lại mật khẩu gocryptfs (đã lọc, chỉ giữ `A-Za-z0-9_-`) và in cảnh báo — hành vi này chỉ để tương thích bản cũ.

---

## Build

```bash
docker build -t drnhat/webdav-gocryptfs .
```
(Dockerfile dùng `COPY --chmod`, cần BuildKit — mặc định trên Docker hiện đại.)

---

## Chạy (gocryptfs trong container)

```bash
mkdir -p /srv/encrypted
printf '%s' "vault-password" > /srv/gocryptfs-pass && chmod 600 /srv/gocryptfs-pass
printf '%s' "webdav-password" > /srv/webdav-pass   && chmod 600 /srv/webdav-pass

docker run -d \
  --name webdav-gocryptfs \
  --cap-add SYS_ADMIN \
  --device /dev/fuse \
  --security-opt apparmor:unconfined \
  -p 6065:6065 \
  -v /srv/encrypted:/encrypted \
  -v /srv/gocryptfs-pass:/run/secrets/gocryptfs_pass:ro \
  -v /srv/webdav-pass:/run/secrets/webdav_pass:ro \
  -e WEBDAV_USER=admin \
  -e TIMEOUT=0 \
  drnhat/webdav-gocryptfs
```

Không cần mount `/decrypted` từ host: gocryptfs mount ngay trong container (mount bind từ host cũng không thấy được nội dung đã giải mã nếu thiếu mount propagation).

### docker-compose

```yaml
services:
  webdav:
    image: drnhat/webdav-gocryptfs
    container_name: webdav-gocryptfs
    cap_add: [SYS_ADMIN]
    devices: ["/dev/fuse:/dev/fuse"]
    security_opt: ["apparmor:unconfined"]
    ports: ["6065:6065"]
    volumes:
      - /srv/encrypted:/encrypted
      - /srv/gocryptfs-pass:/run/secrets/gocryptfs_pass:ro
      - /srv/webdav-pass:/run/secrets/webdav_pass:ro
    environment:
      WEBDAV_USER: admin
      TIMEOUT: 0
    restart: unless-stopped
```

Truy cập: `http://HOST:6065/` (trình duyệt hoặc client WebDAV, Basic Auth).

> Lưu ý: với `TIMEOUT` mặc định 7200 và `restart: unless-stopped`, container sẽ thoát sau 2 giờ rồi tự khởi động lại. Đặt `TIMEOUT=0` nếu muốn chạy liên tục.

---

## Mount trên host, container chỉ phục vụ WebDAV (an toàn hơn)

Không cần `/dev/fuse` hay `SYS_ADMIN`:

```bash
gocryptfs /srv/encrypted /srv/decrypted      # mount trên host

docker run -d -p 6065:6065 \
  -v /srv/decrypted:/decrypted \
  -v /srv/webdav-pass:/run/secrets/webdav_pass:ro \
  -e GOCRYPTFS_MOUNT=0 \
  drnhat/webdav-gocryptfs
```
Thêm `-e WEBDAV_READONLY=1` (hoặc mount `:ro`) nếu chỉ cần đọc. Trong chế độ này lighttpd chạy bằng user `lighttpd`, nên file trên host phải đọc/ghi được với user đó (hoặc world-readable).

---

## Khởi tạo kho mã hóa

Nên khởi tạo trên host để lưu lại master key:
```bash
gocryptfs -init /srv/encrypted
```
Nếu `ENC_PATH` rỗng, container sẽ tự `gocryptfs -init -q` (không in master key ra log). Nếu `ENC_PATH` không rỗng mà thiếu `gocryptfs.conf`, script dừng với lỗi rõ ràng thay vì đoán.

---

## Log & debug

Mọi log (script, gocryptfs, lighttpd) ra stdout/stderr:
```bash
docker logs -f webdav-gocryptfs
docker inspect --format '{{.State.Health.Status}}' webdav-gocryptfs
```
Script **không** in mật khẩu hay nội dung file passwd ra log khi lỗi.

Lỗi thường gặp:
- `Không có mật khẩu gocryptfs` — thiếu `GOCRYPTFS_PASS_FILE` và `PASSWD`.
- `gocryptfs thoát trước khi mount xong` — sai mật khẩu, sai cấu trúc kho, hoặc thiếu `/dev/fuse`/`SYS_ADMIN`.
- `lighttpd không khởi động được` — xem log lighttpd ngay phía trên (cổng bị chiếm, config lỗi).
- macOS Finder / Windows chỉ đọc được: cần `WEBDAV_READONLY=0` và LOCK (đã bật qua `webdav.sqlite-db-name`).

---

## Bảo mật (LAN)

- Ưu tiên secret/file thay cho biến môi trường.
- Basic Auth chạy qua HTTP thuần: mật khẩu đi trong mạng dạng base64. Chấp nhận được ở LAN tin cậy; nếu mạng có thiết bị lạ, đặt reverse proxy TLS (Caddy/nginx/Traefik).
- Cấp `SYS_ADMIN` + `/dev/fuse` mở rộng bề mặt tấn công; phương án mount trên host an toàn hơn.
- Chỉ publish cổng cho interface LAN nếu cần: `-p 192.168.1.10:6065:6065`.

## License
MIT

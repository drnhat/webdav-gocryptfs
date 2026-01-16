# webdav-gocryptfs

Chạy **gocryptfs** trong Docker để **giải mã thư mục đã mã hoá** và **chia sẻ ra ngoài qua WebDAV**.

Mục tiêu của project:

* Giữ dữ liệu **mã hoá ở trạng thái nghỉ (at rest)** bằng gocryptfs
* Chỉ giải mã **runtime trong container**
* Truy cập dữ liệu đã giải mã thông qua **WebDAV**
* Không để plaintext tồn tại lâu dài trên host

---

## Ý tưởng hoạt động

```
[ Encrypted Folder ] --(gocryptfs)--> [ Decrypted Folder (container) ] --(WebDAV)--> Client
```

* Thư mục mã hoá (`gocryptfs`) được mount vào container
* Container dùng `gocryptfs` để giải mã
* Thư mục đã giải mã được share ra ngoài bằng WebDAV
* Khi container dừng → mount bị huỷ → plaintext biến mất

---

## Yêu cầu

* Docker
* Thư mục đã được khởi tạo bằng `gocryptfs`
* Password gocryptfs

---

## Build image

```bash
docker build -t webdav-gocryptfs .
```

---

## Chạy container (docker run)

Ví dụ:

```bash
docker run -d \
  --name webdav-gocryptfs \
  --privileged \
  -p 8080:8080 \
  -e GOCYPTFS_PASSWORD="your_password_here" \
  -v /path/to/encrypted:/encrypted \
  webdav-gocryptfs
```

### Giải thích:

* `/encrypted` : thư mục **đã mã hoá bằng gocryptfs**
* Password truyền qua biến môi trường `GOCYPTFS_PASSWORD`
* WebDAV mặc định chạy trên port `8080`

---

## docker-compose (khuyến nghị)

```yaml
version: "3.8"

services:
  webdav-gocryptfs:
    image: webdav-gocryptfs
    container_name: webdav-gocryptfs
    privileged: true
    ports:
      - "8080:8080"
    environment:
      GOCYPTFS_PASSWORD: your_password_here
    volumes:
      - /path/to/encrypted:/encrypted
    restart: unless-stopped
```

Chạy:

```bash
docker compose up -d
```

---

## Truy cập WebDAV

* URL:

  ```
  http://<server-ip>:8080
  ```

* Có thể mount từ:

  * macOS Finder
  * Windows Explorer
  * iOS Files
  * Linux (davfs2)
  * NAS / server khác

---

## Bảo mật ⚠️

* **WebDAV không có TLS mặc định**

  * Khuyến nghị đặt container sau **reverse proxy (Caddy / Nginx / Traefik)**
* Password gocryptfs **không nên hardcode**

  * Nên dùng `.env` hoặc Docker secrets
* Không expose WebDAV trực tiếp ra Internet nếu không có TLS + auth

---

## Lưu ý quan trọng

* Thư mục plaintext chỉ tồn tại **trong container**
* Nếu mount sai volume, plaintext **có thể ghi ra host**
* Container cần quyền `--privileged` để mount FUSE

---

## License

MIT License

---

## Tác giả

drnhat

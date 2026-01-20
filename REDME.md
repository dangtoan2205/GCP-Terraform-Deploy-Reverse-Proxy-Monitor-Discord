# Cấp quyền cho file .pem trên Window

```bash
icacls "E:\LAB\GG Cloud\teraform-gcp\keys\id_rsa_lab.pem"
```

# Thu hồi quyền cho file .pem trên Window

```bash
icacls "E:\LAB\GG Cloud\teraform-gcp\keys\id_rsa_lab.pem" /reset
```

# Xóa host key cũ của IP đó trong `known_hosts`

```bash
ssh-keygen -R 34.87.50.68
```

----
# 1. Cài Docker Engine và Docker Compose (plugin)

```bash
sudo bash -euxo pipefail -c '
apt-get update
apt-get remove -y docker docker-engine docker.io containerd runc || true
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker --version
docker compose version
'
sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker $USER
newgrp docker

```

# 2. Triển khai ứng dụng bằng Docker Compose

## 2.1 Clone mã nguồn

```
git clone https://github.com/dangtoan2205/login-form.git
cd login-form
```

## 2.2 Khởi chạy stack

```
docker compose up -d
docker ps
```

## 2.3 Kiểm tra nội bộ trên VM

```
curl -I http://localhost:3000
curl -I http://localhost:5000
```

# 3. Cài Nginx và cấu hình Reverse Proxy

## 3.1 Cài Nginx

```
sudo apt-get update
sudo apt-get install -y nginx
sudo systemctl enable --now nginx
```

## 3.2 Tạo virtual host cho domain

Tạo file site:

```
sudo tee /etc/nginx/sites-enabled/app.onnetdev.site >/dev/null <<'NGINX'
server {
  listen 80;
  server_name app.onnetdev.site;

  location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
NGINX
```

Enable site và reload:

```
sudo nginx -t
sudo systemctl reload nginx
```

# 4. Cấp SSL Let’s Encrypt bằng Certbot (Nginx plugin)

## 4.1 Cài Certbot

```
sudo snap install certbot --classic
```

## 4.2 Cấp chứng chỉ cho domain

```
sudo certbot --nginx -d app.onnetdev.site
```

> Sau khi thành công, chứng chỉ nằm tại:
> - /etc/letsencrypt/live/app.onnetdev.site/fullchain.pem
> - /etc/letsencrypt/live/app.onnetdev.site/privkey.pem

# 5. Cấu hình Nginx HTTPS (443) + Redirect 80→443

Cập nhật file site để có 443:

```
sudo tee /etc/nginx/sites-available/app.onnetdev.site >/dev/null <<'NGINX'
server {
  listen 80;
  server_name app.onnetdev.site;
  return 301 https://$host$request_uri;
}

server {
  listen 443 ssl http2;
  server_name app.onnetdev.site;

  ssl_certificate     /etc/letsencrypt/live/app.onnetdev.site/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/app.onnetdev.site/privkey.pem;
  include /etc/letsencrypt/options-ssl-nginx.conf;
  ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

  location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
NGINX
```

Reload:

```
sudo nginx -t
sudo systemctl reload nginx
```

Kiểm tra listen:

```
sudo ss -lntp | grep -E ':(80|443)\b'
```

# 6. Cấu hình Cloudflare

## 6.1 DNS

- `A` record: `app` → External IP của VM
- (tuỳ chọn) `CNAME` record: `www` → `app.onnetdev.site` (nếu dùng www)

## 6.2 SSL/TLS Mode

Cloudflare → SSL/TLS → Encryption mode:

- Chọn **Full (strict)** (khuyến nghị khi origin có Let’s Encrypt)

## 6.3 Xử lý lỗi Cloudflare 521 (nếu gặp)

Nguyên nhân phổ biến:

- Origin không listen 443 hoặc firewall cloud chưa mở 443.
Cách kiểm tra:

```
sudo ss -lntp | grep -E ':(80|443)\b'
```

> Đảm bảo firewall cloud cho phép inbound TCP 80/443.

# Kiểm tra sau triển khai

> Gia hạn chứng chỉ </br>
> Certbot đã tạo tác vụ tự renew. Kiểm tra:
> ```
> sudo certbot renew --dry-run
> ```




































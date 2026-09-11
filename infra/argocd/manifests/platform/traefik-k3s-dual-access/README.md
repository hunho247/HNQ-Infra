# k3s Traefik: Tunnel on 80, Ingress on 443

Manifest này cấu hình **Traefik mặc định của k3s**:

- expose `web` trên cổng `80` để Cloudflare Tunnel gọi `http://127.0.0.1:80`
- expose `websecure` trên cổng `443` cho HTTPS ingress

Mục tiêu: cho phép chạy song song 2 hướng truy cập:

- Cloudflare Tunnel (`cloudflared` trên host) -> Traefik Ingress
- Truy cập trực tiếp qua public IP/domain -> Traefik Ingress (`443`)

## Ghi chú vận hành

- Manifest này **không** cài thêm ingress controller mới.
- Nếu muốn giữ `80` chỉ cho tunnel, chặn inbound `80` từ Internet bằng firewall.
- Cloudflare Tunnel trỏ về origin HTTP nội bộ:

```yaml
ingress:
  - hostname: app.example.com
    service: http://127.0.0.1:80
  - service: http_status:404
```

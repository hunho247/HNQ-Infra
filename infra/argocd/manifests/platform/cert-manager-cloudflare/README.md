# cert-manager ClusterIssuer (Cloudflare DNS-01)

Mục tiêu:

- Tự động cấp phát và gia hạn TLS certificate cho Ingress.
- Dùng challenge `DNS-01` qua Cloudflare API.

## Chuẩn bị API token secret

Tạo secret `cloudflare-api-token-secret` trong namespace `cert-manager` với key `api-token` bằng hệ thống secrets của bạn (không lưu token trong repo này).

Quyền token tối thiểu:

- `Zone:DNS:Edit`
- `Zone:Zone:Read`

## Issuer names

- Dev: `letsencrypt-dns01-dev`
- Prod: `letsencrypt-dns01-prod`

Ingress dùng cert-manager cần annotation:

```yaml
cert-manager.io/cluster-issuer: letsencrypt-dns01-prod
```

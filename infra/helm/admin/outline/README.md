# Outline

Outline single-node chart cho k3s với local storage hoặc S3-compatible storage.

## Install (example)

```bash
helm upgrade --install outline infra/helm/admin/outline \
  -n admin-workspace-dev --create-namespace \
  -f infra/helm/admin/outline/values-dev.yaml
```

## Required secrets

Tạo `outline-secrets` trong namespace đích với các key cần thiết:

- `SECRET_KEY`
- `UTILS_SECRET`
- `DATABASE_URL`
- `REDIS_URL`
- `REDIS_COLLABORATION_URL`
- `s3AccessKeyId`
- `s3SecretAccessKey`

> Secrets quản lý ngoài repo này (Vault/External Secrets/Secret Manager).

## Notes

- Cần Postgres và Redis reachable từ namespace của Outline.
- Nếu dùng MinIO/S3: set `FILE_STORAGE=s3` và cấu hình `AWS_*` tương ứng.

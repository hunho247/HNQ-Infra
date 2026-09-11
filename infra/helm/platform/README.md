# Platform charts

`infra/helm/platform/` chứa chart các service dùng chung cho nhiều app/tenant.

## Layout

```text
infra/helm/platform/
├── storage/
│   ├── mariadb/
│   ├── minio/
│   ├── opensearch/
│   ├── postgres/
│   └── redis/
└── message/
    ├── push-notify/
    └── push-notify-v2/
```

## Values strategy

Mỗi chart dùng:
- `values.yaml`: base mặc định chung
- `values-dev.yaml`: override cho dev
- `values-prod.yaml`: override cho prod

ArgoCD dùng thứ tự `valueFiles`:
1. `values.yaml`
2. `values-<env>.yaml`

Đảm bảo behavior giữa các môi trường rõ ràng, ít duplication và dễ audit diff.

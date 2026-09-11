# Helm charts

`infra/helm/` chứa các Helm chart nội bộ để triển khai service theo nhóm.

## Layout

```text
infra/helm/
├── admin/        # Internal tools (admin services)
├── cicd/         # ArgoCD, GitLab Runner...
├── clients/      # Client services (multi-tenant)
├── platform/     # Platform shared services (storage/message/...)
├── monitoring/   # Monitoring stack (placeholder)
└── webserver/    # Webserver/ingress related (placeholder)
```

## Khi nào dùng Helm trong GitOps?

- Dùng **Helm** khi cần tái sử dụng templates giữa nhiều tenant/service.
- Tách cấu hình theo `values.yaml` (base) + `values-dev.yaml` / `values-prod.yaml` (override).
- Tránh trộn Helm + Directory trong cùng một ArgoCD Application.

## Best practices (ngắn gọn)

- Namespace nên lấy từ `.Release.Namespace`; set qua ArgoCD `destination.namespace`.
- Chuẩn hoá labels (`app.kubernetes.io/*`) để query dễ.
- Giữ tên resource ổn định (`releaseName`, `fullnameOverride`) để tránh recreate.
- Mọi thay đổi lớn phải verify bằng `helm template` diff trước khi sync.

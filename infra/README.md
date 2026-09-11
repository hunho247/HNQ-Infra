# Infra

Mục tiêu của `infra/`:

- Chuẩn hoá **GitOps** để triển khai nhiều service cho nhiều khách hàng (multi-tenant).
- Tách rõ: **ArgoCD applications**, **Helm charts**, **ops scripts**, **CI helpers**.
- Giữ repo gọn, dễ scale theo app/env mà không đổi behavior đang chạy.

## Folder map

```text
infra/
├── argocd/                # GitOps entrypoint: bootstrap/apps (manifests tuỳ chọn)
├── helm/                  # Helm charts (clients/platform/admin/cicd)
├── scripts/               # ops scripts (backup/restore/maintenance)
└── ci/                    # helper scripts cho CI/CD (tuỳ chọn)
```

> Secrets đã tách sang hệ thống quản lý bí mật riêng (Vault/External Secrets/SOPS repo riêng), không lưu trong repo này.

## Quy ước (multi-tenant)

- **Tenant**: tên khách hàng (vd: `lotus-clinic`, `giaan-clinic`).
- **Env**: `dev` / `prod`.
- **Namespace** theo tenant+env: `<tenant>-<env>` (vd: `lotus-clinic-dev`).
- **Namespace** set bởi ArgoCD Application `destination.namespace`; chart dùng `.Release.Namespace`.
- **ArgoCD Application** theo tenant+env: `<tenant>-<env>`.

## Onboarding nhanh

1) Cài ArgoCD (nếu cluster chưa có): xem `infra/helm/cicd/argocd/README.md`.
2) Bootstrap app-of-apps theo env:
   - dev: `infra/argocd/bootstrap/dev/root-app.yaml`
   - prod: `infra/argocd/bootstrap/prod/root-app.yaml`
3) Thêm app/tenant mới: tạo values phù hợp trong chart tương ứng + thêm `Application` dưới `infra/argocd/apps/<env>/`.

Chi tiết: xem `infra/argocd/README.md`.

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

---

## ⚠️ Cây này là bản CŨ

Cấu trúc mới nằm ở gốc repo — `registry/`, `charts/`, `env/`, `gitops/` — theo
[docs/PLAN.md](../docs/PLAN.md). Thư mục `infra/` giữ lại để tra cứu trong lúc
migrate, **không có CI nào kiểm nó** (`.yamllint.yaml` bỏ qua, `render-all.sh`
không đọc).

**Toàn bộ 13 service đã sang cây mới** (thành 15 ServiceRelease vì
`push-notify-v2` tách API và worker). Những chỗ phải thoả hiệp khi migrate ghi
ở [registry/README.md](../registry/README.md).

Giữ `infra/` cho tới khi cả 15 Application chạy thật và `Synced/Healthy` ở dev
(P4). Sau đó xoá — hai cây cùng mô tả một hệ thống là nguồn nhầm lẫn, không
phải nguồn dự phòng.

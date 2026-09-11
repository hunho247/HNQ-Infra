# MinIO (shared object storage)

MinIO triển khai theo môi trường để dùng chung cho các tenant/service.

## ArgoCD

- Dev app: `infra/argocd/apps/dev/platform/storage-minio.yaml`
- Prod app: `infra/argocd/apps/prod/platform/storage-minio.yaml`

ArgoCD render chart `infra/helm/platform/storage/minio/` với:
- `values.yaml`
- `values-<env>.yaml`

## Notes

- Credentials quản lý ngoài repo này (secret manager/External Secrets/Vault).
- Endpoint trong cluster: `minio.<namespace>.svc.cluster.local:9000`.
- Có thể bật NodePort qua `nodePort.enabled=true`.
  - Dev: `apiNodePort=32090`, `consoleNodePort=32091`.
  - Prod: `apiNodePort=32080`, `consoleNodePort=32081`.

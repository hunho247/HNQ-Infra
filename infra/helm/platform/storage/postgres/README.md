# PostgreSQL

PostgreSQL single-node chart (StatefulSet + Service) cho k3s.

## Install (example)

```bash
helm upgrade --install postgres infra/helm/platform/storage/postgres \
  -n storage-postgres-dev --create-namespace \
  -f infra/helm/platform/storage/postgres/values.yaml \
  -f infra/helm/platform/storage/postgres/values-dev.yaml
```

## Notes

- Password/secret quản lý ngoài repo này.
- Service DNS: `postgres.<namespace>.svc.cluster.local:5432`.

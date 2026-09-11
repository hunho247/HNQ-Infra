# MariaDB

MariaDB single-node chart (StatefulSet + Service) cho k3s.

## Cài đặt (ví dụ)

```bash
helm upgrade --install mariadb infra/helm/platform/storage/mariadb \
  -n storage-mariadb-dev --create-namespace \
  -f infra/helm/platform/storage/mariadb/values.yaml \
  -f infra/helm/platform/storage/mariadb/values-dev.yaml
```

## Notes

- Không commit password plaintext vào repo này.
- Service DNS mặc định: `mariadb.<namespace>.svc.cluster.local:3306`.

# Redis

Redis single-node chart cho k3s (Deployment + Service).

## Install (example)

```bash
helm upgrade --install redis infra/helm/platform/storage/redis \
  -n storage-redis-dev --create-namespace \
  -f infra/helm/platform/storage/redis/values.yaml \
  -f infra/helm/platform/storage/redis/values-dev.yaml
```

## Notes

- Nếu `auth.enabled=true`, password cần có sẵn từ secret manager.
- Service DNS: `redis.<namespace>.svc.cluster.local:6379`.

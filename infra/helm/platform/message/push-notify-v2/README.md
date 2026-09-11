# Push Notify V2

Chart triển khai `push-notify-v2` với 2 deployment:
- `api`: HTTP endpoints
- `worker`: scheduler + job processor

## Deploy (dev)

```bash
helm upgrade --install push-notify-v2 infra/helm/platform/message/push-notify-v2 \
  -n push-notify-v2-dev --create-namespace \
  -f infra/helm/platform/message/push-notify-v2/values.yaml \
  -f infra/helm/platform/message/push-notify-v2/values-dev.yaml
```

## Required Secrets

- `app.secretName` (default: `push-notify-v2-config`) với các key:
  - `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASS`, `INTERNAL_API_KEY`
- `firebase.secretName` (default: `push-notify-v2-firebase`) chứa key `service-account.json`

## Notes

- Base config nằm trong `files/app/config_<env>.yaml`.
- `values.yaml` là base, `values-<env>.yaml` để override theo môi trường.

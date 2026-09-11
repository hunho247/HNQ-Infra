# Push Notify

Chart triển khai `push-notify` + `gorush` cho từng môi trường.

## Deploy (dev)

```bash
helm upgrade --install push-notify infra/helm/platform/message/push-notify \
  -n push-notify-dev --create-namespace \
  -f infra/helm/platform/message/push-notify/values.yaml \
  -f infra/helm/platform/message/push-notify/values-dev.yaml
```

## Notes

- DB credentials và gorush secret quản lý ngoài repo này.
- Dùng `values.yaml` làm base, `values-<env>.yaml` để override.

# OpenSearch (storage)

Single-node OpenSearch cho search trong cluster, có thể bật Ingress để expose qua tunnel domain.

## Deploy (dev)

```bash
helm upgrade --install opensearch infra/helm/platform/storage/opensearch \
  -n storage-opensearch-dev --create-namespace \
  -f infra/helm/platform/storage/opensearch/values.yaml \
  -f infra/helm/platform/storage/opensearch/values-dev.yaml
```

## ArgoCD apps

- Dev: `infra/argocd/apps/dev/platform/storage-opensearch.yaml`
- Prod: `infra/argocd/apps/prod/platform/storage-opensearch.yaml`

## Tunnel domains

- Dev: `https://storage-opensearch-dev.l2cteam.work`
- Prod: `https://storage-opensearch.l2cteam.work`

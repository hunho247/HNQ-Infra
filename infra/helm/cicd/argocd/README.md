# Argo CD for k3s

Helm wrapper that installs the official `argo/argo-cd` chart with defaults tuned for the dev k3s cluster.

## Files
- `Chart.yaml`: pulls the upstream `argo-cd` dependency (alias `argocd`)
- `values-dev.yaml`: dev-friendly defaults (Traefik ingress on `admin-argocd.l2cteam.work`, HTTP `--insecure`, light resources)
- `values-prod.yaml`: prod-oriented defaults (TLS expected, ingress host placeholder, higher replicas/resources)
- `install.sh`: helper script to install/upgrade with the chosen env values

## Deploy (dev)
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm dependency update infra/helm/cicd/argocd

helm upgrade --install argocd infra/helm/cicd/argocd \
  -n argocd -f infra/helm/cicd/argocd/values-dev.yaml --create-namespace
```

Or via helper script (auto dependency update, creates namespace if missing):
```bash
# dev (default)
ENV=dev ./infra/helm/cicd/argocd/install.sh

# prod example (adjust domain/TLS in values-prod.yaml first)
ENV=prod NAMESPACE=argocd RELEASE=argocd ./infra/helm/cicd/argocd/install.sh
```

Access
- Ingress: `https://admin-argocd.l2cteam.work`
- Or port-forward: `kubectl -n argocd port-forward svc/argocd-server 8080:80`
- Admin password (if you leave `argocdServerAdminPassword` empty):  
  `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo`

## Customize
- Update `values-dev.yaml` for your domain/namespace; copy it for prod overrides.
- To pin an admin password, set `argocd.configs.secret.argocdServerAdminPassword` to a bcrypt hash, e.g. `htpasswd -nbBC 10 "" 'StrongPass' | tr -d ':\n'`.
- Register repos/credentials in `argocd.configs.repositories` or `credentialTemplates` so Argo CD can sync your charts.
- Re-enable components (e.g. notifications) by flipping the flags in `values-dev.yaml` if you need them.


<!-- u/p: admin/kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo -->

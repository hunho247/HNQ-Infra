# Cloudflare Tunnel Dev on Worker Nodes

Muc tieu:

- Giu luong prod on dinh tren control-plane (khong thay doi Traefik chinh).
- Dev tunnel da chay san tren worker hosts.
- Dev request di vao `traefik-worker` (chi tren worker), tranh vong qua control-plane.

## Thanh phan

- `traefik-worker-helmchart.yaml`
  - Tao mot Traefik bo sung (`traefik-worker`) dang DaemonSet.
  - Chi schedule tren worker nodes (`node-role.kubernetes.io/control-plane` khong ton tai).
  - Bind truc tiep host network port 80 tren worker de cloudflared host local co the goi `http://127.0.0.1:80`.

## Apply

```bash
kubectl apply -f infra/argocd/manifests/platform/cloudflared-dev-worker/traefik-worker-helmchart.yaml
```

## Verify

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik-worker -o wide
kubectl get ingress -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.ingressClassName,HOSTS:.spec.rules[*].host
```

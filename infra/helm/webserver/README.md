# Webserver / Ingress charts

Nơi đặt chart cho ingress/webserver (Traefik, Caddy, ...).

## Diagram

```mermaid
flowchart LR
  Internet((Internet)) --> LB[EntryPoint]
  LB --> Ingress[Traefik/Caddy]
  Ingress --> Svc[Service]
  Svc --> Pod[Pods]
```

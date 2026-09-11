# CICD charts

Charts phục vụ CI/CD platform (không phải business service).

## Thành phần

- `argocd/`: chart wrapper để cài ArgoCD (xem `infra/helm/cicd/argocd/README.md`).
- `gitlab-runner/`: chart để cài GitLab Runner (xem `infra/helm/cicd/gitlab-runner/README.md`).

## Diagram

```mermaid
flowchart LR
  GitLab[GitLab] --> Runner[GitLab Runner]
  Runner --> K8s[(k3s)]
  Argo[ArgoCD] --> K8s
  GitOps[(hnq-infra)] --> Argo
```

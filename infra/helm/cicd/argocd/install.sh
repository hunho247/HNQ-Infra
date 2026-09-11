#!/usr/bin/env bash
set -euo pipefail

# Helper to install/upgrade Argo CD using the umbrella chart in this folder.
# Usage:
#   ENV=dev ./install.sh
#   ENV=prod NAMESPACE=argocd RELEASE=argocd ./install.sh
# Override the values file directly with VALUES_FILE=... if needed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}"
ENVIRONMENT="${ENV:-dev}"
VALUES_FILE="${VALUES_FILE:-${CHART_DIR}/values-${ENVIRONMENT}.yaml}"
RELEASE="${RELEASE:-argocd}"
NAMESPACE="${NAMESPACE:-argocd}"
EXTRA_HELM_ARGS=${EXTRA_HELM_ARGS:-}

command -v helm >/dev/null 2>&1 || { echo "helm not found in PATH"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found in PATH"; exit 1; }

if [[ ! -f "${VALUES_FILE}" ]]; then
  echo "values file not found: ${VALUES_FILE}"
  exit 1
fi

echo ">>> Adding argo helm repo"
helm repo add argo https://argoproj.github.io/argo-helm 1>/dev/null
helm repo update argo 1>/dev/null

echo ">>> Updating chart dependencies"
helm dependency update "${CHART_DIR}" 1>/dev/null

if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo ">>> Creating namespace ${NAMESPACE}"
  kubectl create namespace "${NAMESPACE}"
fi

echo ">>> Installing/Upgrading release ${RELEASE} in ${NAMESPACE} with ${VALUES_FILE}"
helm upgrade --install "${RELEASE}" "${CHART_DIR}" \
  -n "${NAMESPACE}" \
  -f "${VALUES_FILE}" \
  --create-namespace \
  ${EXTRA_HELM_ARGS}

cat <<EOF
---
Done.
- Check status: kubectl -n ${NAMESPACE} get pods
- Port-forward UI: kubectl -n ${NAMESPACE} port-forward svc/${RELEASE}-server 8080:80
- Initial admin password (if not set): kubectl -n ${NAMESPACE} get secret ${RELEASE}-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
EOF

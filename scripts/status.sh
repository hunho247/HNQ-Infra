#!/usr/bin/env bash
# Bảng service: tag dev ↔ prod ↔ trạng thái ArgoCD.
# Đây là khoảng trống duy nhất mà ArgoCD UI không lấp: "cái gì ở dev đang chờ
# lên prod" (OPERATIONS.md).
#
#   scripts/status.sh [--pending-only]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PENDING_ONLY=0
[ "${1:-}" = "--pending-only" ] && PENDING_ONLY=1

# Một lần gọi API cho tất cả Application, thay vì một lần mỗi service.
APPS="$(kubectl -n argocd get applications.argoproj.io \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}/{.status.health.status}{"\n"}{end}' \
  2>/dev/null || true)"

app_state() {
  local line
  line="$(printf '%s\n' "$APPS" | awk -F'\t' -v n="$1" '$1 == n {print $2}')"
  printf '%s' "${line:--}"
}

printf '%-24s %-12s %-12s %-10s %s\n' SERVICE DEV PROD PENDING ARGOCD
printf '%s\n' "──────────────────────────────────────────────────────────────────────────"

for svc_file in registry/apps/*/service.yaml; do
  name="$(yq -r '.metadata.name' "$svc_file")"
  dir="$(dirname "$svc_file")"
  envs="$(yq -r '.spec.environments[].env' "$svc_file" | tr '\n' ' ')"

  dev_tag="$(yq -r '.image.tag // "-"' "$dir/values-dev.yaml" 2>/dev/null || echo -)"
  prod_tag="-"
  [ -f "$dir/values-prod.yaml" ] && prod_tag="$(yq -r '.image.tag // "-"' "$dir/values-prod.yaml")"

  if [[ " $envs " != *" prod "* ]]; then
    pending="dev-only"
    state="$(app_state "$name-dev")"
  elif [ "$dev_tag" != "$prod_tag" ]; then
    pending="⬆ CHỜ"
    state="$(app_state "$name-prod")"
  else
    pending="-"
    state="$(app_state "$name-prod")"
  fi

  [ $PENDING_ONLY -eq 1 ] && [ "$pending" != "⬆ CHỜ" ] && continue
  printf '%-24s %-12s %-12s %-10s %s\n' "$name" "$dev_tag" "$prod_tag" "$pending" "$state"
done

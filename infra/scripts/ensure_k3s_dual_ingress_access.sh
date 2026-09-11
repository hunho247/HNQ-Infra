#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Ensure k3s Traefik supports:
  1) Cloudflare Tunnel -> Traefik on 80 (localhost origin)
  2) Direct public IP/domain -> Traefik on 443
  3) Optional: block public HTTP on 80 by firewall

Usage:
  ensure_k3s_dual_ingress_access.sh [check|apply] [options]

Commands:
  check                     Print current Traefik and ingress exposure status (default)
  apply                     Run checks and optional host firewall changes

Options:
  --open-firewall           Keep public 443 open and deny public 80 via ufw (80 still works on localhost)
  --domain <host>           Domain for sample curl/cloudflared snippet
  --public-ip <ip>          Public IP for sample curl commands
  --yes                     Skip confirmation prompts
  -h, --help                Show help

Examples:
  bash infra/scripts/ensure_k3s_dual_ingress_access.sh check
  bash infra/scripts/ensure_k3s_dual_ingress_access.sh apply --open-firewall --domain app.example.com
EOF
}

log() {
  echo "[$(date '+%F %T')] $*"
}

warn() {
  echo "[$(date '+%F %T')] WARN: $*" >&2
}

die() {
  echo "[$(date '+%F %T')] ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not found in PATH."
}

run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

confirm() {
  local prompt="$1"
  local answer=""
  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

MODE="${1:-check}"
if [[ "$MODE" == "check" || "$MODE" == "apply" ]]; then
  shift || true
else
  MODE="check"
fi

OPEN_FIREWALL="false"
DOMAIN=""
PUBLIC_IP=""
YES="false"
TRAEFIK_TYPE=""
TRAEFIK_WEB_PORT=""
TRAEFIK_WEBSECURE_PORT=""
TRAEFIK_WEB_NODEPORT=""
TRAEFIK_WEBSECURE_NODEPORT=""
TRAEFIK_EXTERNAL_IPS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --open-firewall)
      OPEN_FIREWALL="true"
      shift
      ;;
    --domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    --public-ip)
      PUBLIC_IP="${2:-}"
      shift 2
      ;;
    --yes)
      YES="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

require_cmd kubectl

kubectl_jsonpath() {
  local jp="$1"
  kubectl -n kube-system get svc traefik -o "jsonpath=${jp}" 2>/dev/null || true
}

check_traefik_service() {
  if ! kubectl -n kube-system get svc traefik >/dev/null 2>&1; then
    die "Service kube-system/traefik not found. Verify Traefik is installed/running."
  fi

  TRAEFIK_TYPE="$(kubectl_jsonpath '{.spec.type}')"
  TRAEFIK_WEB_PORT="$(kubectl_jsonpath '{.spec.ports[?(@.name=="web")].port}')"
  TRAEFIK_WEBSECURE_PORT="$(kubectl_jsonpath '{.spec.ports[?(@.name=="websecure")].port}')"
  TRAEFIK_WEB_NODEPORT="$(kubectl_jsonpath '{.spec.ports[?(@.name=="web")].nodePort}')"
  TRAEFIK_WEBSECURE_NODEPORT="$(kubectl_jsonpath '{.spec.ports[?(@.name=="websecure")].nodePort}')"
  TRAEFIK_EXTERNAL_IPS="$(kubectl_jsonpath '{range .status.loadBalancer.ingress[*]}{.ip}{" "}{.hostname}{" "}{end}')"
  TRAEFIK_EXTERNAL_IPS="${TRAEFIK_EXTERNAL_IPS#"${TRAEFIK_EXTERNAL_IPS%%[![:space:]]*}"}"
  TRAEFIK_EXTERNAL_IPS="${TRAEFIK_EXTERNAL_IPS%"${TRAEFIK_EXTERNAL_IPS##*[![:space:]]}"}"

  log "Traefik service summary:"
  echo "  type: ${TRAEFIK_TYPE:-N/A}"
  echo "  web port: ${TRAEFIK_WEB_PORT:-N/A} (nodePort: ${TRAEFIK_WEB_NODEPORT:-N/A})"
  echo "  websecure port: ${TRAEFIK_WEBSECURE_PORT:-N/A} (nodePort: ${TRAEFIK_WEBSECURE_NODEPORT:-N/A})"
  echo "  external ingress: ${TRAEFIK_EXTERNAL_IPS:-N/A}"

  if [[ "$TRAEFIK_TYPE" != "LoadBalancer" ]]; then
    warn "Traefik service type is '$TRAEFIK_TYPE' (expected LoadBalancer for 80/443 exposure)."
  fi
  if [[ "$TRAEFIK_WEB_PORT" != "80" ]]; then
    warn "Traefik web entrypoint is not mapped to port 80 (required for tunnel origin http://127.0.0.1:80)."
  fi
  if [[ "$TRAEFIK_WEBSECURE_PORT" != "443" ]]; then
    warn "Traefik websecure entrypoint is not mapped to port 443."
  fi
}

check_ingress_inventory() {
  local count
  count="$(kubectl get ingress -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  log "Detected ingress objects: ${count}"
}

show_runtime_snapshot() {
  echo
  kubectl -n kube-system get svc traefik -o wide || true
  echo
  kubectl get ingress -A || true
  echo
  if command -v ss >/dev/null 2>&1; then
    ss -lnt '( sport = :80 or sport = :443 )' || true
  fi
}

open_firewall_if_requested() {
  if [[ "$OPEN_FIREWALL" != "true" ]]; then
    return 0
  fi

  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw not found. Open inbound TCP 443 and block TCP 80 manually on your firewall/provider."
    return 0
  fi

  local ufw_status
  ufw_status="$(run_privileged ufw status 2>/dev/null || true)"
  if ! grep -q "^Status: active" <<<"$ufw_status"; then
    warn "ufw is not active. Skipping ufw rule changes."
    return 0
  fi

  if [[ "$YES" != "true" ]]; then
    if ! confirm "Apply ufw rules: allow 443/tcp and deny 80/tcp?"; then
      warn "Skipped ufw changes by user choice."
      return 0
    fi
  fi

  run_privileged ufw allow 443/tcp >/dev/null
  run_privileged ufw deny 80/tcp >/dev/null
  log "Applied ufw rules: allow 443/tcp, deny 80/tcp."
}

print_cloudflared_snippet() {
  local host="${DOMAIN:-app.example.com}"
  echo
  log "Sample cloudflared ingress snippet (host-level config):"
  cat <<EOF
ingress:
  - hostname: ${host}
    service: http://127.0.0.1:80
  - service: http_status:404
EOF
}

print_verify_commands() {
  local ip="${PUBLIC_IP}"
  local host="${DOMAIN:-app.example.com}"
  if [[ -z "$ip" && -n "$TRAEFIK_EXTERNAL_IPS" ]]; then
    ip="${TRAEFIK_EXTERNAL_IPS%% *}"
  fi
  if [[ -z "$ip" ]]; then
    ip="<PUBLIC_IP>"
  fi

  echo
  log "Verify commands:"
  echo "kubectl -n kube-system get svc traefik -o wide"
  echo "curl -kI -H 'Host: ${host}' https://${ip}/"
  echo "curl -I -H 'Host: ${host}' http://${ip}/    # should fail/blocked"
}

main() {
  check_traefik_service
  check_ingress_inventory
  show_runtime_snapshot

  if [[ "$MODE" == "apply" ]]; then
    open_firewall_if_requested
  fi

  print_cloudflared_snippet
  print_verify_commands
}

main "$@"

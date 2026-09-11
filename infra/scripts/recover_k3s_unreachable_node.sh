#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Recover a k3s node when it becomes NotReady/Unavailable (unreachable taint).

Usage:
  recover_k3s_unreachable_node.sh [check|apply] [options]

Commands:
  check                            Print diagnosis for target node (default)
  apply                            Run recovery workflow with confirmations

Options:
  --node <name>                    Target node name. If omitted, auto-select NotReady node.
  --ssh <user@host>                Optional SSH target to restart services on node host.
  --ssh-port <port>                SSH port (default: 22)
  --wait-seconds <seconds>         Wait time for node to become Ready (default: 180)
  --skip-cordon                    Do not cordon node before recovery
  --no-uncordon                    Keep node cordoned even if recovery succeeds
  --force-delete-terminating-pods  If still NotReady, force delete stuck Terminating pods
  --delete-node-if-still-notready  If still NotReady, delete Node object from cluster
  --reboot-if-still-notready       If still NotReady and --ssh is set, reboot node host
  --yes                            Skip confirmation prompts
  -h, --help                       Show help

Examples:
  bash infra/scripts/recover_k3s_unreachable_node.sh check --node hnq
  bash infra/scripts/recover_k3s_unreachable_node.sh apply --node hnq --ssh root@100.103.136.98
  bash infra/scripts/recover_k3s_unreachable_node.sh apply --node hnq --force-delete-terminating-pods
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

read_tty() {
  local prompt="$1"
  local var_name="$2"
  local answer=""
  read -r -p "$prompt" answer < /dev/tty
  printf -v "$var_name" '%s' "$answer"
}

confirm() {
  local prompt="$1"
  local answer=""

  if [[ "$YES" == "true" ]]; then
    return 0
  fi

  read_tty "$prompt [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

pick_index() {
  local max="$1"
  local value=""
  while true; do
    read_tty "Select [1-${max}]: " value
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= max )); then
      echo "$value"
      return 0
    fi
    warn "Invalid selection: $value"
  done
}

MODE="${1:-check}"
if [[ "$MODE" == "check" || "$MODE" == "apply" ]]; then
  shift || true
else
  MODE="check"
fi

NODE=""
SSH_TARGET=""
SSH_PORT="22"
WAIT_SECONDS="180"
WAIT_INTERVAL="5"
SKIP_CORDON="false"
NO_UNCORDON="false"
FORCE_DELETE_TERMINATING_PODS="false"
DELETE_NODE_IF_STILL_NOTREADY="false"
REBOOT_IF_STILL_NOTREADY="false"
YES="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node)
      NODE="${2:-}"
      shift 2
      ;;
    --ssh)
      SSH_TARGET="${2:-}"
      shift 2
      ;;
    --ssh-port)
      SSH_PORT="${2:-}"
      shift 2
      ;;
    --wait-seconds)
      WAIT_SECONDS="${2:-}"
      shift 2
      ;;
    --skip-cordon)
      SKIP_CORDON="true"
      shift
      ;;
    --no-uncordon)
      NO_UNCORDON="true"
      shift
      ;;
    --force-delete-terminating-pods)
      FORCE_DELETE_TERMINATING_PODS="true"
      shift
      ;;
    --delete-node-if-still-notready)
      DELETE_NODE_IF_STILL_NOTREADY="true"
      shift
      ;;
    --reboot-if-still-notready)
      REBOOT_IF_STILL_NOTREADY="true"
      shift
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

[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "--wait-seconds must be a positive integer."
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "--ssh-port must be a valid port number."

if [[ "$REBOOT_IF_STILL_NOTREADY" == "true" && -z "$SSH_TARGET" ]]; then
  die "--reboot-if-still-notready requires --ssh <user@host>."
fi

require_cmd kubectl
if [[ -n "$SSH_TARGET" ]]; then
  require_cmd ssh
fi

node_exists() {
  kubectl get node "$1" >/dev/null 2>&1
}

resolve_node() {
  local notready_nodes=() idx i

  if [[ -n "$NODE" ]]; then
    node_exists "$NODE" || die "Node '$NODE' not found."
    return 0
  fi

  mapfile -t notready_nodes < <(kubectl get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/ {print $1}')

  if [[ "${#notready_nodes[@]}" -eq 0 ]]; then
    if [[ "$MODE" == "apply" ]]; then
      die "No NotReady nodes found. Use --node to target a specific node."
    fi
    log "All nodes are Ready."
    kubectl get nodes -o wide
    exit 0
  fi

  if [[ "${#notready_nodes[@]}" -eq 1 ]]; then
    NODE="${notready_nodes[0]}"
    return 0
  fi

  echo "Detected NotReady nodes:"
  for i in "${!notready_nodes[@]}"; do
    printf '  [%d] %s\n' "$((i+1))" "${notready_nodes[$i]}"
  done
  idx="$(pick_index "${#notready_nodes[@]}")"
  NODE="${notready_nodes[$((idx-1))]}"
}

READY_STATUS=""
READY_REASON=""
READY_MESSAGE=""
READY_HEARTBEAT=""
LEASE_RENEW_TIME=""
TAINTS=""
NODE_ARGS=""
INTERNAL_IP=""
UNSCHEDULABLE=""
NODE_EXISTS="false"
CORDONED_BY_SCRIPT="false"

refresh_node_state() {
  if ! node_exists "$NODE"; then
    NODE_EXISTS="false"
    READY_STATUS="Deleted"
    READY_REASON=""
    READY_MESSAGE=""
    READY_HEARTBEAT=""
    LEASE_RENEW_TIME=""
    TAINTS=""
    NODE_ARGS=""
    INTERNAL_IP=""
    UNSCHEDULABLE=""
    return 1
  fi

  NODE_EXISTS="true"
  READY_STATUS="$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  READY_REASON="$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)"
  READY_MESSAGE="$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)"
  READY_HEARTBEAT="$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastHeartbeatTime}' 2>/dev/null || true)"
  LEASE_RENEW_TIME="$(kubectl get lease "$NODE" -n kube-node-lease -o jsonpath='{.spec.renewTime}' 2>/dev/null || true)"
  TAINTS="$(kubectl get node "$NODE" -o jsonpath='{range .spec.taints[*]}{.key}={.effect}{" "}{end}' 2>/dev/null || true)"
  NODE_ARGS="$(kubectl get node "$NODE" -o jsonpath='{.metadata.annotations.k3s\.io/node-args}' 2>/dev/null || true)"
  INTERNAL_IP="$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  UNSCHEDULABLE="$(kubectl get node "$NODE" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || true)"

  [[ -n "$READY_STATUS" ]] || READY_STATUS="Unknown"
  [[ -n "$READY_REASON" ]] || READY_REASON="<none>"
  [[ -n "$READY_MESSAGE" ]] || READY_MESSAGE="<none>"
  [[ -n "$READY_HEARTBEAT" ]] || READY_HEARTBEAT="<none>"
  [[ -n "$LEASE_RENEW_TIME" ]] || LEASE_RENEW_TIME="<none>"
  [[ -n "$TAINTS" ]] || TAINTS="<none>"
  [[ -n "$NODE_ARGS" ]] || NODE_ARGS="<none>"
  [[ -n "$INTERNAL_IP" ]] || INTERNAL_IP="<none>"
  [[ -n "$UNSCHEDULABLE" ]] || UNSCHEDULABLE="false"
}

print_diagnosis() {
  echo
  log "Node diagnosis: ${NODE}"
  if [[ "$NODE_EXISTS" != "true" ]]; then
    warn "Node object not found in cluster."
    return 0
  fi

  echo "  Ready status    : $READY_STATUS"
  echo "  Ready reason    : $READY_REASON"
  echo "  Ready message   : $READY_MESSAGE"
  echo "  Last heartbeat  : $READY_HEARTBEAT"
  echo "  Lease renewTime : $LEASE_RENEW_TIME"
  echo "  Internal IP     : $INTERNAL_IP"
  echo "  Unschedulable   : $UNSCHEDULABLE"
  echo "  Taints          : $TAINTS"
  echo "  k3s node args   : $NODE_ARGS"

  if [[ "$READY_STATUS" != "True" ]]; then
    warn "Node is not Ready."
    if [[ "$READY_REASON" == "NodeStatusUnknown" ]]; then
      warn "Direct cause: kubelet/k3s-agent stopped posting node status."
    fi
    if [[ "$TAINTS" == *"node.kubernetes.io/unreachable"* ]]; then
      warn "Node is tainted unreachable, scheduler will avoid this node."
    fi
    if [[ "$NODE_ARGS" == *"tailscale0"* ]]; then
      warn "Node uses --flannel-iface tailscale0. Check tailscaled/network stability."
    fi
  fi
}

cordon_node_if_needed() {
  if [[ "$SKIP_CORDON" == "true" ]]; then
    return 0
  fi

  refresh_node_state || true
  if [[ "$NODE_EXISTS" != "true" ]]; then
    return 0
  fi

  if [[ "$UNSCHEDULABLE" == "true" ]]; then
    log "Node is already cordoned."
    return 0
  fi

  if confirm "Cordon node '$NODE' before recovery?"; then
    kubectl cordon "$NODE"
    CORDONED_BY_SCRIPT="true"
    log "Node '$NODE' cordoned."
  else
    warn "Skipped cordon by user choice."
  fi
}

uncordon_node_if_needed() {
  if [[ "$NO_UNCORDON" == "true" ]]; then
    return 0
  fi

  if [[ "$CORDONED_BY_SCRIPT" != "true" ]]; then
    return 0
  fi

  refresh_node_state || true
  if [[ "$NODE_EXISTS" != "true" || "$READY_STATUS" != "True" ]]; then
    return 0
  fi

  if confirm "Node '$NODE' is Ready. Uncordon now?"; then
    kubectl uncordon "$NODE"
    log "Node '$NODE' uncordoned."
  else
    warn "Node remains cordoned by user choice."
  fi
}

restart_remote_services() {
  if [[ -z "$SSH_TARGET" ]]; then
    warn "--ssh not provided, cannot restart remote services automatically."
    return 1
  fi

  if ! confirm "Restart tailscaled + k3s service on '$SSH_TARGET' via SSH?"; then
    warn "Skipped remote service restart."
    return 1
  fi

  log "Running remote recovery on $SSH_TARGET:$SSH_PORT ..."
  if ! ssh -tt -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "$SSH_TARGET" 'bash -s' <<'EOF'
set -euo pipefail

if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl not found on remote host." >&2
  exit 32
fi

if systemctl cat tailscaled >/dev/null 2>&1; then
  ${SUDO} systemctl restart tailscaled || true
  systemctl is-active tailscaled || true
fi

if systemctl cat k3s-agent >/dev/null 2>&1; then
  ${SUDO} systemctl restart k3s-agent
  systemctl is-active k3s-agent
elif systemctl cat k3s >/dev/null 2>&1; then
  ${SUDO} systemctl restart k3s
  systemctl is-active k3s
else
  echo "k3s service unit not found (k3s-agent/k3s)." >&2
  exit 31
fi
EOF
  then
    warn "SSH recovery failed (network, auth, sudo policy, or service error)."
    return 1
  fi

  log "Remote recovery command completed."
  return 0
}

reboot_remote_host() {
  if [[ -z "$SSH_TARGET" ]]; then
    warn "--ssh not provided, cannot reboot host automatically."
    return 1
  fi

  if ! confirm "Node is still NotReady. Reboot '$SSH_TARGET' now?"; then
    warn "Skipped reboot by user choice."
    return 1
  fi

  log "Sending reboot command to $SSH_TARGET:$SSH_PORT ..."
  ssh -tt -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "$SSH_TARGET" \
    'if command -v sudo >/dev/null 2>&1; then sudo systemctl reboot; else systemctl reboot; fi' || true
  log "Reboot command sent (SSH session may disconnect immediately)."
  return 0
}

wait_for_node_ready() {
  local timeout="$1"
  local deadline=$((SECONDS + timeout))

  while (( SECONDS < deadline )); do
    refresh_node_state || true
    if [[ "$NODE_EXISTS" == "true" && "$READY_STATUS" == "True" ]]; then
      log "Node '$NODE' is Ready."
      return 0
    fi
    log "Waiting for node '$NODE' to become Ready (status=$READY_STATUS reason=$READY_REASON)..."
    sleep "$WAIT_INTERVAL"
  done

  refresh_node_state || true
  return 1
}

force_delete_terminating_pods_on_node() {
  local deleting=() line ns pod

  mapfile -t deleting < <(
    kubectl get pods -A --field-selector "spec.nodeName=${NODE}" \
      -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,DELETING:.metadata.deletionTimestamp' \
      --no-headers 2>/dev/null | awk '$3 != "<none>" && $3 != "" {print $1"\t"$2}'
  )

  if [[ "${#deleting[@]}" -eq 0 ]]; then
    log "No Terminating pods detected on node '$NODE'."
    return 0
  fi

  echo "Terminating pods on $NODE:"
  for line in "${deleting[@]}"; do
    IFS=$'\t' read -r ns pod <<< "$line"
    echo "  - ${ns}/${pod}"
  done

  if ! confirm "Force delete these Terminating pods?"; then
    warn "Skipped force delete pods by user choice."
    return 0
  fi

  for line in "${deleting[@]}"; do
    IFS=$'\t' read -r ns pod <<< "$line"
    kubectl -n "$ns" delete pod "$pod" --grace-period=0 --force --wait=false >/dev/null 2>&1 || \
      warn "Failed to force delete ${ns}/${pod}."
  done

  log "Force delete request sent for Terminating pods on '$NODE'."
}

delete_node_if_requested() {
  if [[ "$DELETE_NODE_IF_STILL_NOTREADY" != "true" ]]; then
    return 0
  fi

  refresh_node_state || true
  if [[ "$NODE_EXISTS" != "true" ]]; then
    log "Node '$NODE' already removed from cluster."
    return 0
  fi

  if [[ "$READY_STATUS" == "True" ]]; then
    warn "Node is already Ready, skipping node deletion."
    return 0
  fi

  if ! confirm "Node still NotReady. Delete node object '$NODE' from cluster?"; then
    warn "Skipped node deletion by user choice."
    return 0
  fi

  kubectl delete node "$NODE"
  log "Deleted node object '$NODE' from cluster."
}

resolve_node
refresh_node_state || true
print_diagnosis

if [[ "$MODE" == "check" ]]; then
  exit 0
fi

if [[ "$NODE_EXISTS" != "true" ]]; then
  die "Node '$NODE' does not exist in cluster."
fi

if [[ "$READY_STATUS" == "True" ]]; then
  log "Node '$NODE' is already Ready. No recovery action required."
  exit 0
fi

cordon_node_if_needed
restart_remote_services || true

if wait_for_node_ready "$WAIT_SECONDS"; then
  refresh_node_state || true
  print_diagnosis
  uncordon_node_if_needed
  exit 0
fi

warn "Node '$NODE' is still NotReady after ${WAIT_SECONDS}s."

if [[ "$REBOOT_IF_STILL_NOTREADY" == "true" ]]; then
  reboot_remote_host || true
  if wait_for_node_ready "$WAIT_SECONDS"; then
    refresh_node_state || true
    print_diagnosis
    uncordon_node_if_needed
    exit 0
  fi
  warn "Node '$NODE' is still NotReady after reboot wait."
fi

if [[ "$FORCE_DELETE_TERMINATING_PODS" == "true" ]]; then
  force_delete_terminating_pods_on_node
fi

delete_node_if_requested
refresh_node_state || true
print_diagnosis

if [[ "$NODE_EXISTS" == "true" && "$READY_STATUS" != "True" ]]; then
  die "Recovery did not bring node '$NODE' to Ready. Check k3s-agent/k3s and network on host."
fi

if [[ "$NODE_EXISTS" != "true" ]]; then
  log "Node object '$NODE' no longer exists in cluster."
fi


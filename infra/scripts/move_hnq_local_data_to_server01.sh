#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Move hostPath-backed dev storage data from node hnq to node server01 using helper pods.

Usage:
  move_hnq_local_data_to_server01.sh [check|sync] [options]

Commands:
  check                           Show source/target size for selected services (default)
  sync                            Copy selected services from source node to target node

Options:
  --source-node <name>            Source node name (default: hnq)
  --target-node <name>            Target node name (default: server01)
  --base-path <path>              Host path base to copy (default: /srv/data/dev/platform/storage)
  --services "a b c"              Services to copy (default: mariadb minio opensearch postgres redis)
  --namespace <ns>                Namespace for helper pods (default: default)
  --image <image>                 Helper image with sh/tar/du (default: busybox:1.36)
  --clear-target                  Delete target service dir before extracting data
  --keep-helpers                  Do not delete helper pods after script exits
  --yes                           Skip confirmation prompts
  -h, --help                      Show help

Examples:
  bash infra/scripts/move_hnq_local_data_to_server01.sh check
  bash infra/scripts/move_hnq_local_data_to_server01.sh sync --clear-target --yes
  bash infra/scripts/move_hnq_local_data_to_server01.sh sync --services "mariadb postgres redis"
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

MODE="${1:-check}"
if [[ "$MODE" == "check" || "$MODE" == "sync" ]]; then
  shift || true
else
  MODE="check"
fi

SOURCE_NODE="hnq"
TARGET_NODE="server01"
BASE_PATH="/srv/data/dev/platform/storage"
SERVICES=(mariadb minio opensearch postgres redis)
HELPER_NAMESPACE="default"
HELPER_IMAGE="busybox:1.36"
CLEAR_TARGET="false"
KEEP_HELPERS="false"
YES="false"
RUN_ID="$(date +%Y%m%d%H%M%S)"
SOURCE_POD="node-data-src-${RUN_ID}"
TARGET_POD="node-data-dst-${RUN_ID}"
TARGET_POD_IP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-node)
      SOURCE_NODE="${2:-}"
      shift 2
      ;;
    --target-node)
      TARGET_NODE="${2:-}"
      shift 2
      ;;
    --base-path)
      BASE_PATH="${2:-}"
      shift 2
      ;;
    --services)
      read -r -a SERVICES <<< "${2:-}"
      shift 2
      ;;
    --namespace)
      HELPER_NAMESPACE="${2:-}"
      shift 2
      ;;
    --image)
      HELPER_IMAGE="${2:-}"
      shift 2
      ;;
    --clear-target)
      CLEAR_TARGET="true"
      shift
      ;;
    --keep-helpers)
      KEEP_HELPERS="true"
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

[[ -n "$SOURCE_NODE" ]] || die "--source-node must not be empty."
[[ -n "$TARGET_NODE" ]] || die "--target-node must not be empty."
[[ -n "$BASE_PATH" ]] || die "--base-path must not be empty."
[[ "${#SERVICES[@]}" -gt 0 ]] || die "--services must not be empty."

cleanup_helpers() {
  if [[ "$KEEP_HELPERS" == "true" ]]; then
    return 0
  fi

  kubectl delete pod "$SOURCE_POD" "$TARGET_POD" -n "$HELPER_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
}

trap cleanup_helpers EXIT

wait_for_pod() {
  local pod_name="$1"
  kubectl wait --for=condition=Ready "pod/${pod_name}" -n "$HELPER_NAMESPACE" --timeout=180s >/dev/null
}

create_helper_pod() {
  local pod_name="$1"
  local node_name="$2"

  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${HELPER_NAMESPACE}
  labels:
    app.kubernetes.io/name: node-data-migrator
    app.kubernetes.io/instance: "${RUN_ID}"
spec:
  restartPolicy: Never
  nodeName: ${node_name}
  containers:
    - name: helper
      image: ${HELPER_IMAGE}
      command: ["sh", "-c", "sleep 3600"]
      securityContext:
        runAsUser: 0
      volumeMounts:
        - name: hostdata
          mountPath: /hostdata
  volumes:
    - name: hostdata
      hostPath:
        path: ${BASE_PATH}
        type: DirectoryOrCreate
EOF

  wait_for_pod "$pod_name"
}

ensure_prereqs() {
  require_cmd kubectl
  kubectl get node "$SOURCE_NODE" >/dev/null 2>&1 || die "Source node '$SOURCE_NODE' not found."
  kubectl get node "$TARGET_NODE" >/dev/null 2>&1 || die "Target node '$TARGET_NODE' not found."
  kubectl get namespace "$HELPER_NAMESPACE" >/dev/null 2>&1 || die "Namespace '$HELPER_NAMESPACE' not found."
}

ensure_helpers() {
  create_helper_pod "$SOURCE_POD" "$SOURCE_NODE"
  create_helper_pod "$TARGET_POD" "$TARGET_NODE"
  TARGET_POD_IP="$(kubectl get pod "$TARGET_POD" -n "$HELPER_NAMESPACE" -o jsonpath='{.status.podIP}')"
  [[ -n "$TARGET_POD_IP" ]] || die "Could not resolve target helper pod IP."
}

print_sizes() {
  local service="$1"
  local source_size=""
  local target_size=""

  source_size="$(
    kubectl exec -n "$HELPER_NAMESPACE" "$SOURCE_POD" -- sh -c \
      "if [ -d /hostdata/$service ]; then du -sh /hostdata/$service | awk '{print \$1}'; else echo MISSING; fi"
  )"
  target_size="$(
    kubectl exec -n "$HELPER_NAMESPACE" "$TARGET_POD" -- sh -c \
      "if [ -d /hostdata/$service ]; then du -sh /hostdata/$service | awk '{print \$1}'; else echo MISSING; fi"
  )"

  printf '%-12s source=%-10s target=%-10s\n' "$service" "$source_size" "$target_size"
}

sync_service() {
  local service="$1"
  local stream_port="19000"
  local recv_pid=""

  kubectl exec -n "$HELPER_NAMESPACE" "$SOURCE_POD" -- sh -c "test -d /hostdata/$service" \
    || die "Source directory missing: ${BASE_PATH}/${service} on node ${SOURCE_NODE}"

  if [[ "$CLEAR_TARGET" == "true" ]]; then
    log "Clearing target directory: ${BASE_PATH}/${service}"
  else
    warn "Target directory will be replaced during sync: ${BASE_PATH}/${service}"
  fi

  kubectl exec -n "$HELPER_NAMESPACE" "$TARGET_POD" -- sh -c "rm -rf /hostdata/$service && mkdir -p /hostdata && rm -f /tmp/${service}.tar"

  log "Start receiver on target helper: ${TARGET_POD_IP}:${stream_port}"
  kubectl exec -n "$HELPER_NAMESPACE" "$TARGET_POD" -- sh -c \
    "nc -l -p ${stream_port} > /tmp/${service}.tar" &
  recv_pid=$!
  sleep 1

  log "Stream source -> target: ${SOURCE_NODE}:${BASE_PATH}/${service} -> ${TARGET_NODE}:${BASE_PATH}/${service}"
  if ! kubectl exec -n "$HELPER_NAMESPACE" "$SOURCE_POD" -- sh -c \
    "tar -C /hostdata -cpf - $service | nc -w 30 ${TARGET_POD_IP} ${stream_port}"; then
    kill "$recv_pid" >/dev/null 2>&1 || true
    wait "$recv_pid" >/dev/null 2>&1 || true
    die "Streaming data for '${service}' failed."
  fi

  wait "$recv_pid"

  log "Validate archive on target: /tmp/${service}.tar"
  kubectl exec -n "$HELPER_NAMESPACE" "$TARGET_POD" -- sh -c "tar -tf /tmp/${service}.tar >/dev/null"

  log "Extract archive on target: ${TARGET_NODE}:${BASE_PATH}/${service}"
  kubectl exec -n "$HELPER_NAMESPACE" "$TARGET_POD" -- sh -c \
    "tar -C /hostdata -xpf /tmp/${service}.tar && rm -f /tmp/${service}.tar"
}

ensure_prereqs
ensure_helpers

echo "Source node : $SOURCE_NODE"
echo "Target node : $TARGET_NODE"
echo "Base path   : $BASE_PATH"
echo "Services    : ${SERVICES[*]}"
echo "Namespace   : $HELPER_NAMESPACE"

if [[ "$MODE" == "check" ]]; then
  echo
  for service in "${SERVICES[@]}"; do
    print_sizes "$service"
  done
  exit 0
fi

echo
for service in "${SERVICES[@]}"; do
  print_sizes "$service"
done
echo

confirm "Start sync from '$SOURCE_NODE' to '$TARGET_NODE'?" || die "Aborted by user."

for service in "${SERVICES[@]}"; do
  sync_service "$service"
done

echo
for service in "${SERVICES[@]}"; do
  print_sizes "$service"
done

log "Sync completed"

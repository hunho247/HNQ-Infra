#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
MinIO backup/restore helper: Docker container -> k3s pod.

Usage:
  minio_docker_to_k3s_backup_restore.sh [backup|restore|list] [options]

Commands:
  backup                  Backup MinIO data directory from Docker container.
  restore                 Restore archive into MinIO data directory in k3s pod.
  list                    List detected MinIO Docker containers and k3s pods.

Options:
  --docker-container <n>  Source Docker container name/id (backup)
  --docker-user <u>       Source Docker MinIO root/access user (optional)
  --docker-password <p>   Source Docker MinIO root/secret password (optional)
  --docker-data-dir <p>   Data dir inside Docker container (default: /data)
  --bucket <name>         Bucket name for bucket-level backup
  --target-bucket <name>  Target bucket name for bucket-level restore on k3s
  --namespace <ns>        Target k3s namespace (restore)
  --pod <name>            Target MinIO pod name (restore)
  --container <name>      Target container name in pod (restore)
  --k3s-data-dir <path>   Data dir inside target k3s pod (default: /data)
  --data-dir <path>       Alias: set both --docker-data-dir and --k3s-data-dir
  --file <path>           Backup file for restore (.tar or .tar.gz)
  --output <path>         Output file or directory for backup
  --compress <mode>       auto|gzip|none (default: auto)
  --bucket-restore-attempts <n>
                          Retry attempts for bucket restore mirror (default: 3)
  --bucket-restore-max-workers <n>
                          Max mc mirror workers for bucket restore (default: 1)
  --bucket-restore-retry-delay <s>
                          Seconds to wait between bucket restore retries (default: 2)
  --clear-destination     Remove current target data dir contents before restore
  --allow-merge-restore   Allow restore without clearing destination (unsafe)
  --allow-live-restore    Restore while MinIO is running (unsafe; old behavior)
  --yes                   Skip restore confirmation
  --non-interactive       Disable prompts (requires enough flags)
  --dry-run               Print resolved settings only
  -h, --help              Show help
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

pick_index_or_exit() {
  local max="$1"
  local value=""
  while true; do
    read_tty "Select [0-${max}] (0 to exit): " value
    if [[ "$value" == "0" ]]; then
      log "Exit by user."
      exit 0
    fi
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= max )); then
      echo "$value"
      return 0
    fi
    warn "Invalid selection: $value"
  done
}

validate_bucket_name() {
  local value="$1"
  [[ -n "$value" ]] || return 1
  [[ "$value" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]
}

read_with_default_tty() {
  local prompt="$1"
  local default_value="$2"
  local var_name="$3"
  local answer=""
  read -r -p "$prompt" answer < /dev/tty
  if [[ -z "$answer" ]]; then
    answer="$default_value"
  fi
  printf -v "$var_name" '%s' "$answer"
}

MODE="${1:-}"
if [[ "$MODE" == "backup" || "$MODE" == "restore" || "$MODE" == "list" ]]; then
  shift
else
  MODE=""
fi

DOCKER_CONTAINER_INPUT=""
DOCKER_CONTAINER_ID=""
DOCKER_CONTAINER_NAME=""
DOCKER_MINIO_USER=""
DOCKER_MINIO_PASSWORD=""
DOCKER_DATA_DIR="/data"
NAMESPACE=""
POD=""
CONTAINER=""
K3S_DATA_DIR="/data"
FILE=""
OUTPUT=""
BUCKET=""
TARGET_BUCKET=""
SOURCE_BUCKET=""
COMPRESS="auto"
BUCKET_RESTORE_ATTEMPTS="3"
BUCKET_RESTORE_MAX_WORKERS="1"
BUCKET_RESTORE_RETRY_DELAY="2"
CLEAR_DESTINATION="false"
YES="false"
NON_INTERACTIVE="false"
DRY_RUN="false"
TRANSFER_MODE=""
HOSTPATH_DIR=""
DOCKER_TRANSFER_MODE=""
DOCKER_HOSTPATH_DIR=""
ALLOW_MERGE_RESTORE="false"
ALLOW_LIVE_RESTORE="false"
RESTORE_CONTROLLER_KIND=""
RESTORE_CONTROLLER_NAME=""
RESTORE_CONTROLLER_REPLICAS=""
RESTORE_CONTROLLER_SCALED_DOWN="false"
RESTORE_HELPER_POD=""
RESTORE_HELPER_MOUNT_DIR="/restore-target"
RESTORE_TARGET_NODE=""
RESTORE_CLEANUP_ACTIVE="false"
ARCHIVE_FORMAT_UUID=""
ARCHIVE_BACKUP_MODE=""
TARGET_MINIO_USER=""
TARGET_MINIO_PASSWORD=""
PORT_FORWARD_PID=""
PORT_FORWARD_PORT=""
RESTORE_TMP_DIR=""
RESTORE_MC_CFG_DIR=""
MC_IMAGE="${MC_IMAGE:-docker.io/minio/mc:RELEASE.2025-08-13T08-35-41Z}"
DOCKER_CANDIDATES=()
K3S_CANDIDATES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --docker-container)
      DOCKER_CONTAINER_INPUT="${2:-}"
      shift 2
      ;;
    --docker-user)
      DOCKER_MINIO_USER="${2:-}"
      shift 2
      ;;
    --docker-password)
      DOCKER_MINIO_PASSWORD="${2:-}"
      shift 2
      ;;
    --docker-data-dir)
      DOCKER_DATA_DIR="${2:-}"
      shift 2
      ;;
    --bucket)
      BUCKET="${2:-}"
      shift 2
      ;;
    --target-bucket)
      TARGET_BUCKET="${2:-}"
      shift 2
      ;;
    --namespace)
      NAMESPACE="${2:-}"
      shift 2
      ;;
    --pod)
      POD="${2:-}"
      shift 2
      ;;
    --container)
      CONTAINER="${2:-}"
      shift 2
      ;;
    --k3s-data-dir)
      K3S_DATA_DIR="${2:-}"
      shift 2
      ;;
    --data-dir)
      DOCKER_DATA_DIR="${2:-}"
      K3S_DATA_DIR="${2:-}"
      shift 2
      ;;
    --file)
      FILE="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT="${2:-}"
      shift 2
      ;;
    --compress)
      COMPRESS="${2:-}"
      shift 2
      ;;
    --bucket-restore-attempts)
      BUCKET_RESTORE_ATTEMPTS="${2:-}"
      shift 2
      ;;
    --bucket-restore-max-workers)
      BUCKET_RESTORE_MAX_WORKERS="${2:-}"
      shift 2
      ;;
    --bucket-restore-retry-delay)
      BUCKET_RESTORE_RETRY_DELAY="${2:-}"
      shift 2
      ;;
    --clear-destination)
      CLEAR_DESTINATION="true"
      shift
      ;;
    --allow-merge-restore)
      ALLOW_MERGE_RESTORE="true"
      shift
      ;;
    --allow-live-restore)
      ALLOW_LIVE_RESTORE="true"
      shift
      ;;
    --yes)
      YES="true"
      shift
      ;;
    --non-interactive)
      NON_INTERACTIVE="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
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

if [[ "$COMPRESS" != "auto" && "$COMPRESS" != "gzip" && "$COMPRESS" != "none" ]]; then
  die "--compress must be one of: auto, gzip, none"
fi
if [[ ! "$BUCKET_RESTORE_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  die "--bucket-restore-attempts must be a positive integer."
fi
if [[ ! "$BUCKET_RESTORE_MAX_WORKERS" =~ ^[1-9][0-9]*$ ]]; then
  die "--bucket-restore-max-workers must be a positive integer."
fi
if [[ ! "$BUCKET_RESTORE_RETRY_DELAY" =~ ^[0-9]+$ ]]; then
  die "--bucket-restore-retry-delay must be a non-negative integer."
fi

choose_mode() {
  if [[ -n "$MODE" ]]; then
    return 0
  fi

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    die "Missing command. Use one of: backup, restore, list"
  fi

  echo "Choose action:"
  echo "  [1] backup"
  echo "  [2] restore"
  echo "  [3] list"
  echo "  [0] exit"
  local idx
  idx="$(pick_index_or_exit 3)"
  case "$idx" in
    1) MODE="backup" ;;
    2) MODE="restore" ;;
    3) MODE="list" ;;
  esac
}

discover_docker_minio_containers() {
  local strict="${1:-true}"
  local raw line id name image status lower_image lower_name

  if ! raw="$(docker ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}' 2>&1)"; then
    if [[ "$strict" == "true" ]]; then
      die "docker ps failed: $raw"
    fi
    warn "docker ps failed: $raw"
    return 1
  fi

  mapfile -t DOCKER_CANDIDATES < <(
    printf '%s\n' "$raw" |
    while IFS=$'\t' read -r id name image status; do
      [[ -n "$id" && -n "$name" && -n "$image" ]] || continue
      lower_image="$(echo "$image" | tr '[:upper:]' '[:lower:]')"
      lower_name="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
      if [[ "$lower_image" == *minio* || "$lower_name" == *minio* ]]; then
        printf '%s\t%s\t%s\t%s\n' "$id" "$name" "$image" "$status"
      fi
    done
  )

  if [[ "${#DOCKER_CANDIDATES[@]}" -eq 0 ]]; then
    if [[ "$strict" == "true" ]]; then
      die "No running MinIO Docker container detected."
    fi
    warn "No running MinIO Docker container detected."
    return 1
  fi

  return 0
}

print_docker_candidates() {
  local i=1 line id name image status
  echo "Detected MinIO Docker containers:"
  for line in "${DOCKER_CANDIDATES[@]}"; do
    IFS=$'\t' read -r id name image status <<< "$line"
    echo "  [$i] id=$id name=$name image=$image status=$status"
    ((i++))
  done
}

resolve_source_container() {
  local line id name image status match_count=0

  if [[ -n "$DOCKER_CONTAINER_INPUT" ]]; then
    for line in "${DOCKER_CANDIDATES[@]}"; do
      IFS=$'\t' read -r id name image status <<< "$line"
      if [[ "$name" == "$DOCKER_CONTAINER_INPUT" || "$id" == "$DOCKER_CONTAINER_INPUT" || "$id" == "$DOCKER_CONTAINER_INPUT"* ]]; then
        DOCKER_CONTAINER_ID="$id"
        DOCKER_CONTAINER_NAME="$name"
        match_count=$((match_count + 1))
      fi
    done

    if [[ "$match_count" -eq 0 ]]; then
      die "Container '$DOCKER_CONTAINER_INPUT' not found among detected MinIO Docker containers."
    fi

    if [[ "$match_count" -gt 1 ]]; then
      die "Container selector '$DOCKER_CONTAINER_INPUT' is ambiguous. Please specify full container id or exact name."
    fi
    return 0
  fi

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ "${#DOCKER_CANDIDATES[@]}" -ne 1 ]]; then
      die "Multiple MinIO Docker containers detected. Use --docker-container in non-interactive mode."
    fi
    IFS=$'\t' read -r DOCKER_CONTAINER_ID DOCKER_CONTAINER_NAME _ _ <<< "${DOCKER_CANDIDATES[0]}"
    return 0
  fi

  print_docker_candidates
  echo "  [0] exit"
  local idx selected
  idx="$(pick_index_or_exit "${#DOCKER_CANDIDATES[@]}")"
  selected="${DOCKER_CANDIDATES[$((idx-1))]}"
  IFS=$'\t' read -r DOCKER_CONTAINER_ID DOCKER_CONTAINER_NAME _ _ <<< "$selected"
}

resolve_docker_minio_credentials() {
  local env_lines="" line
  local root_user="" root_pass="" access_user="" secret_key=""

  if [[ -n "$DOCKER_MINIO_USER" && -n "$DOCKER_MINIO_PASSWORD" ]]; then
    return 0
  fi

  env_lines="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$DOCKER_CONTAINER_ID" 2>/dev/null || true)"
  while IFS= read -r line; do
    case "$line" in
      MINIO_ROOT_USER=*)
        root_user="${line#*=}"
        ;;
      MINIO_ROOT_PASSWORD=*)
        root_pass="${line#*=}"
        ;;
      MINIO_ACCESS_KEY=*)
        access_user="${line#*=}"
        ;;
      MINIO_SECRET_KEY=*)
        secret_key="${line#*=}"
        ;;
    esac
  done <<< "$env_lines"

  if [[ -z "$DOCKER_MINIO_USER" ]]; then
    DOCKER_MINIO_USER="${root_user:-$access_user}"
  fi
  if [[ -z "$DOCKER_MINIO_PASSWORD" ]]; then
    DOCKER_MINIO_PASSWORD="${root_pass:-$secret_key}"
  fi

  if [[ -z "$DOCKER_MINIO_USER" || -z "$DOCKER_MINIO_PASSWORD" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      die "Unable to resolve Docker MinIO credentials from container env. Use --docker-user and --docker-password."
    fi
    if [[ -z "$DOCKER_MINIO_USER" ]]; then
      read_tty "Docker MinIO user: " DOCKER_MINIO_USER
    fi
    if [[ -z "$DOCKER_MINIO_PASSWORD" ]]; then
      read_tty "Docker MinIO password: " DOCKER_MINIO_PASSWORD
    fi
  fi
}

run_mc_on_docker_source() {
  local args=("$@")
  local cfg_dir=""
  local run_user=""
  local rc=0

  run_user="$(id -u):$(id -g)"
  cfg_dir="$(mktemp -d)"
  if docker run --rm --network "container:${DOCKER_CONTAINER_ID}" \
    --user "$run_user" \
    -v "${cfg_dir}:/mc" \
    "$MC_IMAGE" \
    --config-dir /mc \
    alias set src http://127.0.0.1:9000 "$DOCKER_MINIO_USER" "$DOCKER_MINIO_PASSWORD" >/dev/null; then
    :
  else
    rc=$?
    rm -rf "$cfg_dir" || true
    return "$rc"
  fi

  if docker run --rm --network "container:${DOCKER_CONTAINER_ID}" \
    --user "$run_user" \
    -v "${cfg_dir}:/mc" \
    "$MC_IMAGE" \
    --config-dir /mc \
    "${args[@]}"; then
    :
  else
    rc=$?
  fi

  rm -rf "$cfg_dir" || true
  return "$rc"
}

run_mc_on_docker_source_with_mount() {
  local mount_dir="$1"
  shift
  local args=("$@")
  local cfg_dir=""
  local run_user=""
  local rc=0

  run_user="$(id -u):$(id -g)"
  cfg_dir="$(mktemp -d)"
  if docker run --rm --network "container:${DOCKER_CONTAINER_ID}" \
    --user "$run_user" \
    -v "${cfg_dir}:/mc" \
    "$MC_IMAGE" \
    --config-dir /mc \
    alias set src http://127.0.0.1:9000 "$DOCKER_MINIO_USER" "$DOCKER_MINIO_PASSWORD" >/dev/null; then
    :
  else
    rc=$?
    rm -rf "$cfg_dir" || true
    return "$rc"
  fi

  if docker run --rm --network "container:${DOCKER_CONTAINER_ID}" \
    --user "$run_user" \
    -v "${cfg_dir}:/mc" \
    -v "${mount_dir}:/work" \
    "$MC_IMAGE" \
    --config-dir /mc \
    "${args[@]}"; then
    :
  else
    rc=$?
  fi

  rm -rf "$cfg_dir" || true
  return "$rc"
}

list_docker_buckets() {
  local raw=""
  if ! raw="$(run_mc_on_docker_source ls --json src 2>&1)"; then
    die "Unable to list buckets from Docker MinIO source: ${raw}"
  fi

  printf '%s\n' "$raw" \
    | awk '
      /"type":"folder"/ {
        if (match($0, /"key":"[^"]+"/)) {
          key = substr($0, RSTART + 7, RLENGTH - 8)
          sub(/\/$/, "", key)
          print key
        }
      }
    ' \
    | sed '/^$/d'
}

select_source_bucket_for_backup() {
  local buckets=()
  local valid_buckets=()
  local idx selected
  local bucket_raw=""

  resolve_docker_minio_credentials
  bucket_raw="$(list_docker_buckets)"
  mapfile -t buckets < <(printf '%s\n' "$bucket_raw")

  for selected in "${buckets[@]}"; do
    if validate_bucket_name "$selected"; then
      valid_buckets+=("$selected")
    fi
  done
  buckets=("${valid_buckets[@]}")

  if [[ "${#buckets[@]}" -eq 0 ]]; then
    die "No buckets found in Docker MinIO source."
  fi

  if [[ -n "$BUCKET" ]]; then
    for selected in "${buckets[@]}"; do
      if [[ "$selected" == "$BUCKET" ]]; then
        SOURCE_BUCKET="$BUCKET"
        return 0
      fi
    done
    die "Bucket '$BUCKET' not found in Docker MinIO source."
  fi

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    die "--bucket is required for bucket-level backup in non-interactive mode."
  fi

  echo "Buckets in Docker MinIO source:"
  for idx in "${!buckets[@]}"; do
    printf '  [%d] %s\n' "$((idx+1))" "${buckets[$idx]}"
  done
  echo "  [0] exit"
  idx="$(pick_index_or_exit "${#buckets[@]}")"
  SOURCE_BUCKET="${buckets[$((idx-1))]}"
}

read_archive_backup_mode() {
  local archive="$1"
  local mode=""
  mode="$(archive_cat_first_match "$archive" ".backup_mode" "./.backup_mode" 2>/dev/null || true)"
  if [[ -z "$mode" ]]; then
    printf '%s' "raw_data_v1"
  else
    printf '%s' "$mode"
  fi
}

resolve_source_bucket_from_archive() {
  local archive="$1"
  local saved_bucket="" line candidate=""

  saved_bucket="$(archive_cat_first_match "$archive" "source_bucket.txt" "./source_bucket.txt" 2>/dev/null || true)"
  saved_bucket="$(printf '%s' "$saved_bucket" | tr -d '\r\n')"

  if [[ -n "$BUCKET" ]]; then
    SOURCE_BUCKET="$BUCKET"
  elif [[ -n "$saved_bucket" ]]; then
    SOURCE_BUCKET="$saved_bucket"
  else
    if [[ "$archive" == *.gz ]]; then
      while IFS= read -r line; do
        line="${line#./}"
        case "$line" in
          data/*)
            candidate="${line#data/}"
            candidate="${candidate%%/*}"
            if [[ -n "$candidate" ]]; then
              SOURCE_BUCKET="$candidate"
              break
            fi
            ;;
        esac
      done < <(tar tzf "$archive" 2>/dev/null || true)
    else
      while IFS= read -r line; do
        line="${line#./}"
        case "$line" in
          data/*)
            candidate="${line#data/}"
            candidate="${candidate%%/*}"
            if [[ -n "$candidate" ]]; then
              SOURCE_BUCKET="$candidate"
              break
            fi
            ;;
        esac
      done < <(tar tf "$archive" 2>/dev/null || true)
    fi
  fi

  [[ -n "$SOURCE_BUCKET" ]] || die "Unable to resolve source bucket from backup archive."
  validate_bucket_name "$SOURCE_BUCKET" || die "Invalid source bucket name in backup archive: $SOURCE_BUCKET"
}

resolve_target_minio_credentials() {
  local creds=()
  mapfile -t creds < <(exec_in_pod sh -c 'printf "%s\n" "${MINIO_ROOT_USER:-}" "${MINIO_ROOT_PASSWORD:-}"')
  TARGET_MINIO_USER="${creds[0]:-}"
  TARGET_MINIO_PASSWORD="${creds[1]:-}"
  if [[ -z "$TARGET_MINIO_USER" || -z "$TARGET_MINIO_PASSWORD" ]]; then
    die "Unable to resolve target MinIO credentials from pod env."
  fi
}

start_port_forward_to_target_pod() {
  local port="${1:-39000}"
  local try=0

  PORT_FORWARD_PID=""
  PORT_FORWARD_PORT="$port"

  kubectl -n "$NAMESPACE" port-forward "pod/${POD}" "${PORT_FORWARD_PORT}:9000" >/tmp/minio_pf_${PORT_FORWARD_PORT}.log 2>&1 &
  PORT_FORWARD_PID=$!

  for try in $(seq 1 40); do
    if ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
      cat "/tmp/minio_pf_${PORT_FORWARD_PORT}.log" 2>/dev/null || true
      die "Failed to start port-forward to ${NAMESPACE}/${POD}."
    fi
    if bash -lc "exec 3<>/dev/tcp/127.0.0.1/${PORT_FORWARD_PORT}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done

  die "Timeout waiting for port-forward 127.0.0.1:${PORT_FORWARD_PORT}."
}

stop_port_forward_to_target_pod() {
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    PORT_FORWARD_PID=""
  fi
}

discover_minio_pods() {
  local strict="${1:-true}"
  local raw line ns pod phase container image lower_image lower_name lower_container

  if ! raw="$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}{end}' 2>&1)"; then
    if [[ "$strict" == "true" ]]; then
      die "kubectl get pods -A failed: $raw"
    fi
    warn "kubectl get pods -A failed: $raw"
    return 1
  fi

  mapfile -t K3S_CANDIDATES < <(
    printf '%s\n' "$raw" |
    while IFS=$'\t' read -r ns pod phase container image; do
      [[ -n "$ns" && -n "$pod" && -n "$container" && -n "$image" ]] || continue
      [[ "$phase" == "Running" ]] || continue
      lower_image="$(echo "$image" | tr '[:upper:]' '[:lower:]')"
      lower_name="$(echo "$pod" | tr '[:upper:]' '[:lower:]')"
      lower_container="$(echo "$container" | tr '[:upper:]' '[:lower:]')"
      if [[ "$lower_image" == *minio* || "$lower_name" == *minio* || "$lower_container" == *minio* ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$ns" "$pod" "$container" "$image" "$phase"
      fi
    done
  )

  if [[ "${#K3S_CANDIDATES[@]}" -eq 0 ]]; then
    if [[ "$strict" == "true" ]]; then
      die "No MinIO pod detected in cluster."
    fi
    warn "No MinIO pod detected in cluster."
    return 1
  fi

  return 0
}

print_k3s_candidates() {
  local i=1 line ns pod container image phase
  echo "Detected MinIO k3s pods:"
  for line in "${K3S_CANDIDATES[@]}"; do
    IFS=$'\t' read -r ns pod container image phase <<< "$line"
    echo "  [$i] namespace=$ns pod=$pod container=$container phase=$phase image=$image"
    ((i++))
  done
}

resolve_target_from_candidates() {
  local line ns pod container image phase
  local found="false"

  if [[ -n "$POD" && -n "$NAMESPACE" ]]; then
    for line in "${K3S_CANDIDATES[@]}"; do
      IFS=$'\t' read -r ns pod container image phase <<< "$line"
      if [[ "$ns" == "$NAMESPACE" && "$pod" == "$POD" ]]; then
        found="true"
        if [[ -z "$CONTAINER" ]]; then
          CONTAINER="$container"
        fi
        break
      fi
    done
    if [[ "$found" != "true" ]]; then
      die "Pod '$POD' not found in namespace '$NAMESPACE' among running MinIO pods."
    fi
    return 0
  fi

  if [[ -n "$POD" && -z "$NAMESPACE" ]]; then
    local match_count=0
    for line in "${K3S_CANDIDATES[@]}"; do
      IFS=$'\t' read -r ns pod container image phase <<< "$line"
      if [[ "$pod" == "$POD" ]]; then
        NAMESPACE="$ns"
        [[ -z "$CONTAINER" ]] && CONTAINER="$container"
        match_count=$((match_count + 1))
      fi
    done
    if [[ "$match_count" -eq 1 ]]; then
      return 0
    fi
    if [[ "$match_count" -gt 1 ]]; then
      die "Pod name '$POD' exists in multiple namespaces. Use --namespace."
    fi
    die "Pod '$POD' not found among detected MinIO pods."
  fi

  if [[ -n "$NAMESPACE" && -z "$POD" ]]; then
    local ns_matches=()
    for line in "${K3S_CANDIDATES[@]}"; do
      IFS=$'\t' read -r ns pod container image phase <<< "$line"
      if [[ "$ns" == "$NAMESPACE" ]]; then
        ns_matches+=("$line")
      fi
    done

    if [[ "${#ns_matches[@]}" -eq 1 ]]; then
      IFS=$'\t' read -r ns pod container image phase <<< "${ns_matches[0]}"
      POD="$pod"
      [[ -z "$CONTAINER" ]] && CONTAINER="$container"
      return 0
    fi

    if [[ "${#ns_matches[@]}" -eq 0 ]]; then
      die "No MinIO pod found in namespace '$NAMESPACE'."
    fi

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      die "Multiple MinIO pods found in namespace '$NAMESPACE'. Use --pod."
    fi

    echo "Multiple MinIO pods in namespace '$NAMESPACE':"
    local j=1
    for line in "${ns_matches[@]}"; do
      IFS=$'\t' read -r ns pod container image phase <<< "$line"
      echo "  [$j] pod=$pod container=$container phase=$phase image=$image"
      ((j++))
    done
    echo "  [0] exit"
    local idx
    idx="$(pick_index_or_exit "${#ns_matches[@]}")"
    IFS=$'\t' read -r ns pod container image phase <<< "${ns_matches[$((idx-1))]}"
    POD="$pod"
    [[ -z "$CONTAINER" ]] && CONTAINER="$container"
    return 0
  fi

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ "${#K3S_CANDIDATES[@]}" -ne 1 ]]; then
      die "Multiple MinIO pods detected. Use --namespace and --pod in non-interactive mode."
    fi
    IFS=$'\t' read -r NAMESPACE POD detected_container _ _ <<< "${K3S_CANDIDATES[0]}"
    [[ -z "$CONTAINER" ]] && CONTAINER="$detected_container"
    return 0
  fi

  print_k3s_candidates
  echo "  [0] exit"
  local idx selected detected_container
  idx="$(pick_index_or_exit "${#K3S_CANDIDATES[@]}")"
  selected="${K3S_CANDIDATES[$((idx-1))]}"
  IFS=$'\t' read -r NAMESPACE POD detected_container _ _ <<< "$selected"
  [[ -z "$CONTAINER" ]] && CONTAINER="$detected_container"
}

exec_in_pod() {
  local args=("$@")
  local container_flag=()
  if [[ -n "$CONTAINER" ]]; then
    container_flag=(-c "$CONTAINER")
  fi
  kubectl -n "$NAMESPACE" exec "${container_flag[@]}" "$POD" -- "${args[@]}"
}

exec_in_pod_stdin() {
  local args=("$@")
  local container_flag=()
  if [[ -n "$CONTAINER" ]]; then
    container_flag=(-c "$CONTAINER")
  fi
  kubectl -n "$NAMESPACE" exec -i "${container_flag[@]}" "$POD" -- "${args[@]}"
}

resolve_docker_hostpath_data_dir() {
  local target_mount mount_path host_path mount_type mounts_raw

  target_mount="${DOCKER_DATA_DIR%/}"
  [[ -z "$target_mount" ]] && target_mount="/"

  mounts_raw="$(docker inspect --format '{{range .Mounts}}{{printf "%s\t%s\t%s\n" .Destination .Source .Type}}{{end}}' "$DOCKER_CONTAINER_ID" 2>/dev/null || true)"

  while IFS=$'\t' read -r mount_path source mount_type; do
    [[ -n "$mount_path" && -n "$source" ]] || continue
    if [[ "${mount_path%/}" == "$target_mount" || "$mount_path" == "$target_mount" ]]; then
      host_path="$source"
      if [[ -n "$host_path" ]]; then
        printf '%s\n' "$host_path"
        return 0
      fi
      return 1
    fi
  done <<< "$mounts_raw"

  return 1
}

resolve_k3s_hostpath_data_dir() {
  local target_mount volume_name container_name mount_path host_path
  local mounts_raw volumes_raw

  target_mount="${K3S_DATA_DIR%/}"
  [[ -z "$target_mount" ]] && target_mount="/"

  mounts_raw="$(kubectl -n "$NAMESPACE" get pod "$POD" -o go-template='{{range .spec.containers}}{{ $c := .name }}{{range .volumeMounts}}{{printf "%s\t%s\t%s\n" $c .name .mountPath}}{{end}}{{end}}' 2>/dev/null || true)"
  volumes_raw="$(kubectl -n "$NAMESPACE" get pod "$POD" -o go-template='{{range .spec.volumes}}{{printf "%s\t%s\n" .name .hostPath.path}}{{end}}' 2>/dev/null || true)"

  volume_name=""
  while IFS=$'\t' read -r container_name name path; do
    [[ -n "$name" && -n "$path" ]] || continue
    if [[ -n "$CONTAINER" && "$container_name" != "$CONTAINER" ]]; then
      continue
    fi
    if [[ "${path%/}" == "$target_mount" || "$path" == "$target_mount" ]]; then
      volume_name="$name"
      break
    fi
  done <<< "$mounts_raw"

  [[ -n "$volume_name" ]] || return 1

  while IFS=$'\t' read -r name path; do
    [[ -n "$name" ]] || continue
    if [[ "$name" == "$volume_name" ]]; then
      host_path="$path"
      if [[ -n "$host_path" && "$host_path" != "<no value>" ]]; then
        printf '%s\n' "$host_path"
        return 0
      fi
      return 1
    fi
  done <<< "$volumes_raw"

  return 1
}

resolve_docker_backup_transfer_mode() {
  DOCKER_TRANSFER_MODE=""
  DOCKER_HOSTPATH_DIR=""

  if docker exec "$DOCKER_CONTAINER_ID" sh -c 'command -v tar >/dev/null 2>&1' >/dev/null 2>&1; then
    DOCKER_TRANSFER_MODE="container_tar"
    return 0
  fi

  DOCKER_HOSTPATH_DIR="$(resolve_docker_hostpath_data_dir || true)"
  if [[ -n "$DOCKER_HOSTPATH_DIR" && -d "$DOCKER_HOSTPATH_DIR" ]]; then
    DOCKER_TRANSFER_MODE="hostpath"
    return 0
  fi

  die "No supported Docker backup transfer method for container '$DOCKER_CONTAINER_NAME'. Need tar in container or local hostPath access."
}

resolve_restore_transfer_mode() {
  TRANSFER_MODE=""
  HOSTPATH_DIR=""
  local pod_node=""

  HOSTPATH_DIR="$(resolve_k3s_hostpath_data_dir || true)"

  # Safe restore mode (default): stop MinIO first, then restore via hostPath.
  if [[ "$ALLOW_LIVE_RESTORE" != "true" ]]; then
    if [[ -z "$HOSTPATH_DIR" ]]; then
      die "Safe restore requires hostPath-backed data dir, but none was found for $NAMESPACE/$POD:$K3S_DATA_DIR."
    fi

    if [[ -d "$HOSTPATH_DIR" ]]; then
      TRANSFER_MODE="hostpath"
    else
      TRANSFER_MODE="helper_pod"
    fi
    return 0
  fi

  if exec_in_pod sh -c 'command -v tar >/dev/null 2>&1' >/dev/null 2>&1; then
    TRANSFER_MODE="pod_tar"
    return 0
  fi

  if [[ -n "$HOSTPATH_DIR" && -d "$HOSTPATH_DIR" ]]; then
    TRANSFER_MODE="hostpath"
    return 0
  fi

  pod_node="$(kubectl -n "$NAMESPACE" get pod "$POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  if [[ -n "$pod_node" ]]; then
    die "tar command not found in pod '$POD', and hostPath is unavailable locally. Pod is running on node '$pod_node'."
  fi
  die "No supported restore transfer method for pod '$POD'. Need tar in pod or local hostPath access."
}

archive_cat_first_match() {
  local archive="$1"
  shift
  local candidate content

  for candidate in "$@"; do
    if [[ "$archive" == *.gz ]]; then
      content="$(tar xzOf "$archive" "$candidate" 2>/dev/null || true)"
    else
      content="$(tar xOf "$archive" "$candidate" 2>/dev/null || true)"
    fi
    if [[ -n "$content" ]]; then
      printf '%s' "$content"
      return 0
    fi
  done
  return 1
}

read_archive_format_json() {
  local archive="$1"
  archive_cat_first_match "$archive" \
    ".minio.sys/format.json" \
    "./.minio.sys/format.json" \
    "data/.minio.sys/format.json" \
    "./data/.minio.sys/format.json"
}

extract_uuid_from_format_json() {
  local payload="$1"
  printf '%s' "$payload" | tr -d '\n' | sed -n 's/.*"this"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9-]\+\)".*/\1/p'
}

validate_archive_layout() {
  local archive="$1"
  local format_json=""
  format_json="$(read_archive_format_json "$archive" || true)"
  [[ -n "$format_json" ]] || die "Backup archive is missing .minio.sys/format.json. Refusing restore."

  ARCHIVE_FORMAT_UUID="$(extract_uuid_from_format_json "$format_json" || true)"
  [[ -n "$ARCHIVE_FORMAT_UUID" ]] || die "Unable to parse MinIO format UUID from backup archive."
}

resolve_restore_controller() {
  local owner_kind owner_name rs_owner_kind rs_owner_name resource replicas

  owner_kind="$(kubectl -n "$NAMESPACE" get pod "$POD" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
  owner_name="$(kubectl -n "$NAMESPACE" get pod "$POD" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)"

  [[ -n "$owner_kind" && -n "$owner_name" ]] || die "Unable to resolve owner for pod $NAMESPACE/$POD."

  if [[ "$owner_kind" == "ReplicaSet" ]]; then
    rs_owner_kind="$(kubectl -n "$NAMESPACE" get rs "$owner_name" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
    rs_owner_name="$(kubectl -n "$NAMESPACE" get rs "$owner_name" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)"
    if [[ "$rs_owner_kind" == "Deployment" && -n "$rs_owner_name" ]]; then
      owner_kind="$rs_owner_kind"
      owner_name="$rs_owner_name"
    fi
  fi

  case "$owner_kind" in
    Deployment)
      resource="deployment"
      ;;
    StatefulSet)
      resource="statefulset"
      ;;
    *)
      die "Safe restore supports pods managed by Deployment/StatefulSet. Found owner kind: $owner_kind"
      ;;
  esac

  replicas="$(kubectl -n "$NAMESPACE" get "$resource" "$owner_name" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  [[ -n "$replicas" ]] || replicas="1"

  RESTORE_CONTROLLER_KIND="$owner_kind"
  RESTORE_CONTROLLER_NAME="$owner_name"
  RESTORE_CONTROLLER_REPLICAS="$replicas"
}

scale_restore_controller() {
  local replicas="$1"
  local resource=""

  case "$RESTORE_CONTROLLER_KIND" in
    Deployment)
      resource="deployment"
      ;;
    StatefulSet)
      resource="statefulset"
      ;;
    *)
      die "Unsupported restore controller kind: $RESTORE_CONTROLLER_KIND"
      ;;
  esac

  kubectl -n "$NAMESPACE" scale "${resource}/${RESTORE_CONTROLLER_NAME}" --replicas="$replicas" >/dev/null
}

wait_restore_controller_ready() {
  local timeout="${1:-180s}"
  local resource=""

  if [[ -z "$RESTORE_CONTROLLER_KIND" || -z "$RESTORE_CONTROLLER_NAME" ]]; then
    return 0
  fi

  case "$RESTORE_CONTROLLER_KIND" in
    Deployment)
      resource="deployment"
      ;;
    StatefulSet)
      resource="statefulset"
      ;;
    *)
      return 0
      ;;
  esac

  kubectl -n "$NAMESPACE" rollout status "${resource}/${RESTORE_CONTROLLER_NAME}" --timeout="$timeout" >/dev/null
}

start_restore_helper_pod() {
  local helper_pod=""

  [[ -n "$HOSTPATH_DIR" ]] || die "Cannot start restore helper pod: empty HOSTPATH_DIR."
  RESTORE_TARGET_NODE="$(kubectl -n "$NAMESPACE" get pod "$POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  [[ -n "$RESTORE_TARGET_NODE" ]] || die "Cannot resolve node for target pod $NAMESPACE/$POD."

  helper_pod="minio-restore-helper-${RANDOM}-${RANDOM}"
  log "Creating restore helper pod: $helper_pod (node=$RESTORE_TARGET_NODE, hostPath=$HOSTPATH_DIR)"

  cat <<EOF | kubectl -n "$NAMESPACE" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${helper_pod}
spec:
  nodeName: ${RESTORE_TARGET_NODE}
  restartPolicy: Never
  containers:
    - name: helper
      image: busybox:1.36
      command: ["sh","-lc","sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: ${RESTORE_HELPER_MOUNT_DIR}
  volumes:
    - name: data
      hostPath:
        path: ${HOSTPATH_DIR}
        type: DirectoryOrCreate
EOF

  if ! kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/${helper_pod}" --timeout=120s >/dev/null 2>&1; then
    kubectl -n "$NAMESPACE" delete pod "${helper_pod}" --ignore-not-found >/dev/null 2>&1 || true
    die "Restore helper pod failed to become ready: $helper_pod"
  fi

  RESTORE_HELPER_POD="$helper_pod"
}

stop_restore_helper_pod() {
  if [[ -n "$RESTORE_HELPER_POD" ]]; then
    kubectl -n "$NAMESPACE" delete pod "$RESTORE_HELPER_POD" --ignore-not-found >/dev/null 2>&1 || true
    RESTORE_HELPER_POD=""
  fi
}

cleanup_restore_session() {
  local rc=$?
  set +e

  if [[ "$RESTORE_CLEANUP_ACTIVE" != "true" ]]; then
    return $rc
  fi

  if [[ -n "$PORT_FORWARD_PID" ]]; then
    warn "Stopping port-forward on 127.0.0.1:${PORT_FORWARD_PORT}"
    stop_port_forward_to_target_pod
  fi

  if [[ -n "$RESTORE_HELPER_POD" ]]; then
    warn "Cleaning up restore helper pod: $RESTORE_HELPER_POD"
    kubectl -n "$NAMESPACE" delete pod "$RESTORE_HELPER_POD" --ignore-not-found >/dev/null 2>&1 || true
    RESTORE_HELPER_POD=""
  fi

  if [[ -n "$RESTORE_TMP_DIR" && -d "$RESTORE_TMP_DIR" ]]; then
    rm -rf "$RESTORE_TMP_DIR" >/dev/null 2>&1 || true
    RESTORE_TMP_DIR=""
  fi

  if [[ -n "$RESTORE_MC_CFG_DIR" && -d "$RESTORE_MC_CFG_DIR" ]]; then
    rm -rf "$RESTORE_MC_CFG_DIR" >/dev/null 2>&1 || true
    RESTORE_MC_CFG_DIR=""
  fi

  if [[ "$RESTORE_CONTROLLER_SCALED_DOWN" == "true" ]]; then
    warn "Restore was interrupted. Scaling ${RESTORE_CONTROLLER_KIND}/${RESTORE_CONTROLLER_NAME} back to ${RESTORE_CONTROLLER_REPLICAS}."
    scale_restore_controller "$RESTORE_CONTROLLER_REPLICAS" >/dev/null 2>&1 || true
    RESTORE_CONTROLLER_SCALED_DOWN="false"
  fi

  return $rc
}

backup_bucket_action() {
  local timestamp output_dir compress_effective tmp_output size tmp_dir

  select_source_bucket_for_backup
  validate_bucket_name "$SOURCE_BUCKET" || die "Invalid bucket name: $SOURCE_BUCKET"

  timestamp="$(date '+%Y%m%d_%H%M%S')"
  if [[ -z "$OUTPUT" || "$OUTPUT" == */ || -d "$OUTPUT" ]]; then
    output_dir="${OUTPUT:-.}"
    OUTPUT="${output_dir%/}/minio_bucket_${SOURCE_BUCKET}_${DOCKER_CONTAINER_NAME}_${timestamp}.tar.gz"
  fi

  if [[ "$COMPRESS" == "auto" ]]; then
    if [[ "$OUTPUT" == *.gz ]]; then
      compress_effective="gzip"
    else
      compress_effective="none"
    fi
  else
    compress_effective="$COMPRESS"
  fi

  if [[ "$compress_effective" == "gzip" && "$OUTPUT" != *.gz ]]; then
    OUTPUT="${OUTPUT}.gz"
  fi
  if [[ "$compress_effective" == "gzip" ]]; then
    require_cmd gzip
  fi

  mkdir -p "$(dirname "$OUTPUT")"

  log "Bucket backup source:"
  log "  Docker container : $DOCKER_CONTAINER_NAME ($DOCKER_CONTAINER_ID)"
  log "  Bucket           : $SOURCE_BUCKET"
  log "  Output           : $OUTPUT"
  log "  Compress         : $compress_effective"

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  tmp_dir="$(mktemp -d)"
  tmp_output="${OUTPUT}.tmp.$$"
  trap 'rm -f "${tmp_output:-}"; rm -rf "${tmp_dir:-}" || true' EXIT

  mkdir -p "$tmp_dir/data/$SOURCE_BUCKET"
  printf '%s\n' "bucket_mc_v1" > "$tmp_dir/.backup_mode"
  printf '%s\n' "$SOURCE_BUCKET" > "$tmp_dir/source_bucket.txt"

  run_mc_on_docker_source_with_mount "$tmp_dir" mirror --overwrite "src/${SOURCE_BUCKET}" "/work/data/${SOURCE_BUCKET}"

  if [[ "$compress_effective" == "gzip" ]]; then
    tar czf "$tmp_output" -C "$tmp_dir" .
  else
    tar cf "$tmp_output" -C "$tmp_dir" .
  fi

  mv "$tmp_output" "$OUTPUT"
  trap - EXIT
  rm -rf "$tmp_dir"

  size="$(du -h "$OUTPUT" | awk '{print $1}')"
  log "Bucket backup completed: $OUTPUT (${size})"
}

restore_bucket_action() {
  local reply=""
  local target_input=""
  local run_user=""
  local mirror_args=()
  local attempt=1
  local mirror_ok="false"

  resolve_source_bucket_from_archive "$FILE"

  if [[ -z "$TARGET_BUCKET" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      TARGET_BUCKET="$SOURCE_BUCKET"
    else
      read_with_default_tty "Target bucket on k3s [${SOURCE_BUCKET}]: " "$SOURCE_BUCKET" target_input
      TARGET_BUCKET="$target_input"
    fi
  fi

  validate_bucket_name "$TARGET_BUCKET" || die "Invalid target bucket name: $TARGET_BUCKET"

  log "Bucket restore target:"
  log "  Namespace         : $NAMESPACE"
  log "  Pod               : $POD"
  log "  Source bucket     : $SOURCE_BUCKET"
  log "  Target bucket     : $TARGET_BUCKET"
  log "  File              : $FILE"
  log "  Mirror attempts   : $BUCKET_RESTORE_ATTEMPTS"
  log "  Mirror workers    : $BUCKET_RESTORE_MAX_WORKERS"
  log "  Retry delay (sec) : $BUCKET_RESTORE_RETRY_DELAY"

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  if [[ "$YES" != "true" && "$NON_INTERACTIVE" != "true" ]]; then
    read_tty "Restore bucket objects to '$TARGET_BUCKET'? (y/N): " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      die "Aborted by user."
    fi
  fi

  require_cmd docker
  resolve_target_minio_credentials

  RESTORE_CLEANUP_ACTIVE="true"
  trap cleanup_restore_session EXIT

  RESTORE_TMP_DIR="$(mktemp -d)"
  if [[ "$FILE" == *.gz ]]; then
    tar xzf "$FILE" -C "$RESTORE_TMP_DIR"
  else
    tar xf "$FILE" -C "$RESTORE_TMP_DIR"
  fi

  [[ -d "$RESTORE_TMP_DIR/data/$SOURCE_BUCKET" ]] || die "Bucket data not found in archive: data/$SOURCE_BUCKET"

  PORT_FORWARD_PORT="$((39000 + (RANDOM % 1000)))"
  log "Starting port-forward to ${NAMESPACE}/${POD} on 127.0.0.1:${PORT_FORWARD_PORT} ..."
  start_port_forward_to_target_pod "$PORT_FORWARD_PORT"

  run_user="$(id -u):$(id -g)"
  RESTORE_MC_CFG_DIR="$(mktemp -d)"

  docker run --rm --network host \
    --user "$run_user" \
    -v "${RESTORE_MC_CFG_DIR}:/mc" \
    "$MC_IMAGE" \
    --config-dir /mc \
    alias set dst "http://127.0.0.1:${PORT_FORWARD_PORT}" "$TARGET_MINIO_USER" "$TARGET_MINIO_PASSWORD" >/dev/null

  docker run --rm --network host \
    --user "$run_user" \
    -v "${RESTORE_MC_CFG_DIR}:/mc" \
    -v "${RESTORE_TMP_DIR}:/work" \
    "$MC_IMAGE" \
    --config-dir /mc \
    mb --ignore-existing "dst/${TARGET_BUCKET}" >/dev/null

  mirror_args=(
    mirror
    --overwrite
    --retry
    --summary
    --max-workers "$BUCKET_RESTORE_MAX_WORKERS"
    "/work/data/${SOURCE_BUCKET}"
    "dst/${TARGET_BUCKET}"
  )

  while (( attempt <= BUCKET_RESTORE_ATTEMPTS )); do
    log "Mirroring objects (attempt ${attempt}/${BUCKET_RESTORE_ATTEMPTS}) ..."
    if docker run --rm --network host \
      --user "$run_user" \
      -v "${RESTORE_MC_CFG_DIR}:/mc" \
      -v "${RESTORE_TMP_DIR}:/work" \
      "$MC_IMAGE" \
      --config-dir /mc \
      "${mirror_args[@]}"; then
      mirror_ok="true"
      break
    fi

    if (( attempt < BUCKET_RESTORE_ATTEMPTS )); then
      warn "Mirror attempt ${attempt} failed. Restarting port-forward and retrying..."
      stop_port_forward_to_target_pod
      if (( BUCKET_RESTORE_RETRY_DELAY > 0 )); then
        sleep "$BUCKET_RESTORE_RETRY_DELAY"
      fi
      start_port_forward_to_target_pod "$PORT_FORWARD_PORT"
    fi
    attempt=$((attempt + 1))
  done

  if [[ "$mirror_ok" != "true" ]]; then
    cat "/tmp/minio_pf_${PORT_FORWARD_PORT}.log" 2>/dev/null || true
    die "Bucket restore failed after ${BUCKET_RESTORE_ATTEMPTS} attempts."
  fi

  stop_port_forward_to_target_pod
  rm -rf "$RESTORE_MC_CFG_DIR" || true
  RESTORE_MC_CFG_DIR=""
  rm -rf "$RESTORE_TMP_DIR"
  RESTORE_TMP_DIR=""

  RESTORE_CLEANUP_ACTIVE="false"
  trap - EXIT

  log "Bucket restore completed: $SOURCE_BUCKET -> $TARGET_BUCKET"
}

backup_action() {
  local timestamp output_dir compress_effective tmp_output size
  local backup_scope="raw"
  local scope_choice=""

  require_cmd docker
  require_cmd tar
  discover_docker_minio_containers
  resolve_source_container

  if [[ -n "$BUCKET" ]]; then
    backup_scope="bucket"
  elif [[ "$NON_INTERACTIVE" != "true" ]]; then
    echo "Backup scope:"
    echo "  [1] Full raw /data backup"
    echo "  [2] Single bucket backup"
    echo "  [0] exit"
    scope_choice="$(pick_index_or_exit 2)"
    if [[ "$scope_choice" == "2" ]]; then
      backup_scope="bucket"
    fi
  fi

  if [[ "$backup_scope" == "bucket" ]]; then
    backup_bucket_action
    return 0
  fi

  resolve_docker_backup_transfer_mode

  timestamp="$(date '+%Y%m%d_%H%M%S')"

  if [[ -z "$OUTPUT" || "$OUTPUT" == */ || -d "$OUTPUT" ]]; then
    output_dir="${OUTPUT:-.}"
    OUTPUT="${output_dir%/}/minio_docker_${DOCKER_CONTAINER_NAME}_${timestamp}.tar.gz"
  fi

  if [[ "$COMPRESS" == "auto" ]]; then
    if [[ "$OUTPUT" == *.gz ]]; then
      compress_effective="gzip"
    else
      compress_effective="none"
    fi
  else
    compress_effective="$COMPRESS"
  fi

  if [[ "$compress_effective" == "gzip" && "$OUTPUT" != *.gz ]]; then
    OUTPUT="${OUTPUT}.gz"
  fi

  if [[ "$compress_effective" == "gzip" ]]; then
    require_cmd gzip
  fi

  mkdir -p "$(dirname "$OUTPUT")"

  log "Backup source:"
  log "  Docker container : $DOCKER_CONTAINER_NAME ($DOCKER_CONTAINER_ID)"
  log "  Data dir         : $DOCKER_DATA_DIR"
  log "  Output           : $OUTPUT"
  log "  Compress         : $compress_effective"
  log "  Transfer         : $DOCKER_TRANSFER_MODE"
  if [[ "$DOCKER_TRANSFER_MODE" == "hostpath" ]]; then
    log "  Host path        : $DOCKER_HOSTPATH_DIR"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  tmp_output="${OUTPUT}.tmp.$$"
  trap 'rm -f "${tmp_output:-}"' EXIT

  if [[ "$DOCKER_TRANSFER_MODE" == "container_tar" && "$compress_effective" == "gzip" ]]; then
    docker exec "$DOCKER_CONTAINER_ID" sh -c 'set -e; dir="$1"; [ -d "$dir" ] || { echo "Missing data dir: $dir" >&2; exit 1; }; cd "$dir"; tar cf - .' sh "$DOCKER_DATA_DIR" | gzip -c > "$tmp_output"
  elif [[ "$DOCKER_TRANSFER_MODE" == "container_tar" ]]; then
    docker exec "$DOCKER_CONTAINER_ID" sh -c 'set -e; dir="$1"; [ -d "$dir" ] || { echo "Missing data dir: $dir" >&2; exit 1; }; cd "$dir"; tar cf - .' sh "$DOCKER_DATA_DIR" > "$tmp_output"
  elif [[ "$compress_effective" == "gzip" ]]; then
    tar czf "$tmp_output" -C "$DOCKER_HOSTPATH_DIR" .
  else
    tar cf "$tmp_output" -C "$DOCKER_HOSTPATH_DIR" .
  fi

  mv "$tmp_output" "$OUTPUT"
  trap - EXIT

  validate_archive_layout "$OUTPUT"

  size="$(du -h "$OUTPUT" | awk '{print $1}')"
  log "Backup MinIO format UUID: $ARCHIVE_FORMAT_UUID"
  log "Backup completed: $OUTPUT (${size})"
}

restore_action() {
  local reply input_cmd=()
  local safety_choice=""
  local restored_format_json restored_uuid

  require_cmd kubectl
  require_cmd tar
  discover_minio_pods
  resolve_target_from_candidates

  if [[ -z "$FILE" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      die "--file is required for restore in non-interactive mode."
    fi
    read_tty "Backup file path (.tar/.tar.gz): " FILE
  fi

  [[ -f "$FILE" ]] || die "Backup file not found: $FILE"
  ARCHIVE_BACKUP_MODE="$(read_archive_backup_mode "$FILE")"

  if [[ "$ARCHIVE_BACKUP_MODE" == "bucket_mc_v1" ]]; then
    restore_bucket_action
    return 0
  fi

  resolve_restore_transfer_mode

  if [[ "$CLEAR_DESTINATION" != "true" && "$ALLOW_MERGE_RESTORE" != "true" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" || "$YES" == "true" ]]; then
      die "Refusing merge restore. Use --clear-destination (recommended) or --allow-merge-restore (unsafe)."
    fi

    echo "Restore safety mode:"
    echo "  [1] Clear destination before restore (recommended)"
    echo "  [2] Merge restore without clearing (unsafe)"
    echo "  [0] exit"
    safety_choice="$(pick_index_or_exit 2)"
    case "$safety_choice" in
      1)
        CLEAR_DESTINATION="true"
        ;;
      2)
        ALLOW_MERGE_RESTORE="true"
        warn "Proceeding with unsafe merge restore. This can corrupt MinIO metadata."
        ;;
    esac
  fi

  validate_archive_layout "$FILE"

  if [[ "$FILE" == *.gz ]]; then
    require_cmd gzip
    input_cmd=(gzip -dc "$FILE")
  else
    input_cmd=(cat "$FILE")
  fi

  log "Restore target:"
  log "  Namespace         : $NAMESPACE"
  log "  Pod               : $POD"
  log "  Container         : ${CONTAINER:-<default>}"
  log "  Data dir          : $K3S_DATA_DIR"
  log "  File              : $FILE"
  log "  Clear destination : $CLEAR_DESTINATION"
  log "  Allow merge       : $ALLOW_MERGE_RESTORE"
  log "  Live restore      : $ALLOW_LIVE_RESTORE"
  log "  Transfer          : $TRANSFER_MODE"
  log "  Backup format UUID: $ARCHIVE_FORMAT_UUID"
  if [[ "$TRANSFER_MODE" == "hostpath" ]]; then
    log "  Host path         : $HOSTPATH_DIR"
  elif [[ "$TRANSFER_MODE" == "helper_pod" ]]; then
    log "  Host path         : $HOSTPATH_DIR (via helper pod)"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  RESTORE_CLEANUP_ACTIVE="true"
  trap cleanup_restore_session EXIT

  if [[ "$ALLOW_LIVE_RESTORE" != "true" ]]; then
    resolve_restore_controller
    log "Safe restore: scaling ${RESTORE_CONTROLLER_KIND}/${RESTORE_CONTROLLER_NAME} to 0 before restore..."
    scale_restore_controller 0
    RESTORE_CONTROLLER_SCALED_DOWN="true"
    kubectl -n "$NAMESPACE" wait --for=delete "pod/${POD}" --timeout=180s >/dev/null 2>&1 || true

    if [[ "$TRANSFER_MODE" == "helper_pod" ]]; then
      start_restore_helper_pod
    fi
  fi

  if [[ "$YES" != "true" && "$NON_INTERACTIVE" != "true" ]]; then
    read_tty "Restore can overwrite MinIO data. Proceed? (y/N): " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      die "Aborted by user."
    fi
  fi

  if [[ "$TRANSFER_MODE" == "pod_tar" ]]; then
    exec_in_pod sh -c 'mkdir -p "$1"' sh "$K3S_DATA_DIR"
    if [[ "$CLEAR_DESTINATION" == "true" ]]; then
      log "Clearing existing contents in $K3S_DATA_DIR before restore..."
      exec_in_pod sh -c 'set -e; dir="$1"; find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} \;' sh "$K3S_DATA_DIR"
    fi
    "${input_cmd[@]}" | exec_in_pod_stdin sh -c 'set -e; dir="$1"; tar xf - -C "$dir"' sh "$K3S_DATA_DIR"
  elif [[ "$TRANSFER_MODE" == "helper_pod" ]]; then
    if [[ "$CLEAR_DESTINATION" == "true" ]]; then
      log "Clearing existing contents in $HOSTPATH_DIR before restore (helper pod)..."
      kubectl -n "$NAMESPACE" exec "$RESTORE_HELPER_POD" -- sh -c 'set -e; dir="$1"; mkdir -p "$dir"; find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} \;' sh "$RESTORE_HELPER_MOUNT_DIR"
    else
      kubectl -n "$NAMESPACE" exec "$RESTORE_HELPER_POD" -- sh -c 'mkdir -p "$1"' sh "$RESTORE_HELPER_MOUNT_DIR"
    fi
    "${input_cmd[@]}" | kubectl -n "$NAMESPACE" exec -i "$RESTORE_HELPER_POD" -- sh -c 'set -e; dir="$1"; tar xf - -C "$dir"' sh "$RESTORE_HELPER_MOUNT_DIR"
  else
    require_cmd tar
    mkdir -p "$HOSTPATH_DIR"
    if [[ "$CLEAR_DESTINATION" == "true" ]]; then
      log "Clearing existing contents in $HOSTPATH_DIR before restore..."
      find "$HOSTPATH_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} \;
    fi
    if [[ "$FILE" == *.gz ]]; then
      tar xzf "$FILE" -C "$HOSTPATH_DIR"
    else
      tar xf "$FILE" -C "$HOSTPATH_DIR"
    fi
  fi

  if [[ "$TRANSFER_MODE" == "helper_pod" ]]; then
    restored_format_json="$(kubectl -n "$NAMESPACE" exec "$RESTORE_HELPER_POD" -- sh -c 'cat "$1/.minio.sys/format.json" 2>/dev/null || true' sh "$RESTORE_HELPER_MOUNT_DIR")"
  elif [[ "$TRANSFER_MODE" == "hostpath" ]]; then
    restored_format_json="$(cat "$HOSTPATH_DIR/.minio.sys/format.json" 2>/dev/null || true)"
  else
    restored_format_json="$(exec_in_pod sh -c 'cat "$1/.minio.sys/format.json" 2>/dev/null || true' sh "$K3S_DATA_DIR")"
  fi

  [[ -n "$restored_format_json" ]] || die "Restore finished but .minio.sys/format.json not found at destination."
  restored_uuid="$(extract_uuid_from_format_json "$restored_format_json" || true)"
  [[ -n "$restored_uuid" ]] || die "Restore finished but cannot parse destination MinIO format UUID."
  log "Restored MinIO format UUID: $restored_uuid"

  if [[ "$restored_uuid" != "$ARCHIVE_FORMAT_UUID" ]]; then
    die "Destination MinIO format UUID ($restored_uuid) differs from backup ($ARCHIVE_FORMAT_UUID). Restore is inconsistent."
  fi

  if [[ "$RESTORE_CONTROLLER_SCALED_DOWN" == "true" ]]; then
    log "Scaling ${RESTORE_CONTROLLER_KIND}/${RESTORE_CONTROLLER_NAME} back to ${RESTORE_CONTROLLER_REPLICAS}..."
    scale_restore_controller "$RESTORE_CONTROLLER_REPLICAS"
    RESTORE_CONTROLLER_SCALED_DOWN="false"
    wait_restore_controller_ready "180s"
  fi

  stop_restore_helper_pod
  RESTORE_CLEANUP_ACTIVE="false"
  trap - EXIT

  log "Restore completed."
}

list_action() {
  local found="false"

  if command -v docker >/dev/null 2>&1; then
    if discover_docker_minio_containers false; then
      print_docker_candidates
      found="true"
    fi
  else
    warn "docker not found in PATH; skip Docker container discovery."
  fi

  if command -v kubectl >/dev/null 2>&1; then
    if discover_minio_pods false; then
      print_k3s_candidates
      found="true"
    fi
  else
    warn "kubectl not found in PATH; skip k3s pod discovery."
  fi

  if [[ "$found" != "true" ]]; then
    die "No MinIO source/target found."
  fi
}

validate_mode_specific_options() {
  if [[ -n "$BUCKET" ]] && ! validate_bucket_name "$BUCKET"; then
    die "Invalid bucket name: $BUCKET"
  fi
  if [[ -n "$TARGET_BUCKET" ]] && ! validate_bucket_name "$TARGET_BUCKET"; then
    die "Invalid target bucket name: $TARGET_BUCKET"
  fi
  if [[ "$MODE" == "backup" && -n "$FILE" ]]; then
    warn "--file is ignored in backup mode."
  fi
  if [[ "$MODE" == "restore" && -n "$OUTPUT" ]]; then
    warn "--output is ignored in restore mode."
  fi
  if [[ "$MODE" == "backup" && -n "$TARGET_BUCKET" ]]; then
    warn "--target-bucket is ignored in backup mode."
  fi
}

choose_mode
validate_mode_specific_options

if [[ "$MODE" == "list" ]]; then
  list_action
  exit 0
fi

if [[ "$MODE" == "backup" ]]; then
  backup_action
elif [[ "$MODE" == "restore" ]]; then
  restore_action
else
  die "Unsupported command: $MODE"
fi

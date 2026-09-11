#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Unified MinIO backup/restore helper for k3s.

Usage:
  minio_backup_restore.sh [backup|restore|list] [options]

Commands:
  backup                Backup MinIO data directory from selected pod.
  restore               Restore archive into MinIO data directory.
  list                  Only list detected MinIO pods.

Options:
  --namespace <ns>      Namespace of target pod (optional; auto-select if omitted)
  --pod <name>          Pod name of MinIO (optional; auto-select if omitted)
  --container <name>    Container name (optional)
  --bucket <name>       Source bucket for backup/restore (single bucket only)
  --target-bucket <n>   Destination bucket for restore (default: same as source)
  --all-buckets         Not supported (blocked by policy)
  --data-dir <path>     MinIO data dir inside pod (default: /data)
  --file <path>         Backup file for restore (.tar or .tar.gz)
  --output <path>       Output file or directory for backup
  --compress <mode>     auto|gzip|none (default: auto)
  --clear-destination   Remove current data dir contents before restore
  --yes                 Skip restore confirmation
  --non-interactive     Disable prompts (requires enough flags)
  --dry-run             Print resolved settings only
  -h, --help            Show help
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

normalize_bucket_filters() {
  local raw part
  local expanded=()
  local deduped=()
  declare -A seen=()

  for raw in "${BUCKET_FILTERS[@]}"; do
    IFS=',' read -r -a parts <<< "$raw"
    for part in "${parts[@]}"; do
      part="${part#"${part%%[![:space:]]*}"}"
      part="${part%"${part##*[![:space:]]}"}"
      [[ -n "$part" ]] || continue
      expanded+=("$part")
    done
  done

  for part in "${expanded[@]}"; do
    if [[ -z "${seen[$part]:-}" ]]; then
      seen["$part"]=1
      deduped+=("$part")
    fi
  done

  BUCKET_FILTERS=("${deduped[@]}")
}

bucket_in_list() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

join_by_comma() {
  local IFS=', '
  echo "$*"
}

validate_bucket_name() {
  local value="$1"
  [[ -n "$value" ]] || return 1
  [[ "$value" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]
}

MODE="${1:-}"
if [[ "$MODE" == "backup" || "$MODE" == "restore" || "$MODE" == "list" ]]; then
  shift
else
  MODE=""
fi

NAMESPACE=""
POD=""
CONTAINER=""
DATA_DIR="/data"
FILE=""
OUTPUT=""
COMPRESS="auto"
CLEAR_DESTINATION="false"
YES="false"
NON_INTERACTIVE="false"
DRY_RUN="false"
TRANSFER_MODE=""
HOSTPATH_DIR=""
MC_HELPER_POD=""
MC_ENDPOINT=""
MC_USER=""
MC_PASSWORD=""
ALL_BUCKETS="false"
BUCKET_FILTERS=()
SELECTED_BUCKETS=()
SOURCE_BUCKET=""
TARGET_BUCKET=""
RESTORE_TARGET_BUCKET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --bucket)
      BUCKET_FILTERS+=("${2:-}")
      shift 2
      ;;
    --target-bucket)
      RESTORE_TARGET_BUCKET="${2:-}"
      shift 2
      ;;
    --all-buckets)
      ALL_BUCKETS="true"
      shift
      ;;
    --data-dir)
      DATA_DIR="${2:-}"
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
    --clear-destination)
      CLEAR_DESTINATION="true"
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

normalize_bucket_filters

if [[ "$ALL_BUCKETS" == "true" ]]; then
  die "--all-buckets is disabled. Backup/restore now supports single-bucket operations only."
fi

if [[ "${#BUCKET_FILTERS[@]}" -gt 1 ]]; then
  die "Only one --bucket is supported."
fi

require_cmd kubectl

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

discover_minio_pods() {
  local raw line ns pod phase container image lower_image lower_name lower_container
  if ! raw="$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}{end}' 2>&1)"; then
    die "kubectl get pods -A failed: $raw"
  fi

  mapfile -t CANDIDATES < <(
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

  if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
    die "No MinIO pod detected in cluster."
  fi
}

print_candidates() {
  local i=1 line ns pod container image phase
  echo "Detected MinIO pods:"
  for line in "${CANDIDATES[@]}"; do
    IFS=$'\t' read -r ns pod container image phase <<< "$line"
    echo "  [$i] namespace=$ns pod=$pod container=$container phase=$phase image=$image"
    ((i++))
  done
}

resolve_target_from_candidates() {
  local i line ns pod container image phase

  if [[ -n "$POD" && -n "$NAMESPACE" ]]; then
    if [[ -z "$CONTAINER" ]]; then
      for line in "${CANDIDATES[@]}"; do
        IFS=$'\t' read -r ns pod container image phase <<< "$line"
        if [[ "$ns" == "$NAMESPACE" && "$pod" == "$POD" ]]; then
          CONTAINER="$container"
          break
        fi
      done
    fi
    return 0
  fi

  if [[ -n "$POD" && -z "$NAMESPACE" ]]; then
    local match_count=0
    for line in "${CANDIDATES[@]}"; do
      IFS=$'\t' read -r ns pod container image phase <<< "$line"
      if [[ "$pod" == "$POD" ]]; then
        NAMESPACE="$ns"
        [[ -z "$CONTAINER" ]] && CONTAINER="$container"
        ((match_count++))
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
    for line in "${CANDIDATES[@]}"; do
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
    if [[ "${#CANDIDATES[@]}" -ne 1 ]]; then
      die "Multiple MinIO pods detected. Use --namespace and --pod in non-interactive mode."
    fi
    IFS=$'\t' read -r NAMESPACE POD detected_container _ _ <<< "${CANDIDATES[0]}"
    [[ -z "$CONTAINER" ]] && CONTAINER="$detected_container"
    return 0
  fi

  print_candidates
  echo "  [0] exit"
  local idx selected detected_container
  idx="$(pick_index_or_exit "${#CANDIDATES[@]}")"
  selected="${CANDIDATES[$((idx-1))]}"
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

mc_exec_in_pod() {
  local args=("$@")
  if [[ -n "$MC_HELPER_POD" ]]; then
    kubectl -n "$NAMESPACE" exec "$MC_HELPER_POD" -- sh -c 'set -e; mc alias set -q local "$1" "$2" "$3" >/dev/null; shift 3; mc "$@"' sh "$MC_ENDPOINT" "$MC_USER" "$MC_PASSWORD" "${args[@]}"
    return 0
  fi
  exec_in_pod sh -c 'set -e; mc alias set -q local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null; mc "$@"' sh "${args[@]}"
}

mc_exec_in_pod_stdin() {
  local args=("$@")
  if [[ -n "$MC_HELPER_POD" ]]; then
    kubectl -n "$NAMESPACE" exec -i "$MC_HELPER_POD" -- sh -c 'set -e; mc alias set -q local "$1" "$2" "$3" >/dev/null; shift 3; mc "$@"' sh "$MC_ENDPOINT" "$MC_USER" "$MC_PASSWORD" "${args[@]}"
    return 0
  fi
  exec_in_pod_stdin sh -c 'set -e; mc alias set -q local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null; mc "$@"' sh "${args[@]}"
}

start_mc_helper_session() {
  local helper_pod pod_ip
  local cred_lines=()

  if [[ -n "$MC_HELPER_POD" ]]; then
    return 0
  fi

  mapfile -t cred_lines < <(exec_in_pod sh -c 'printf "%s\n" "${MINIO_ROOT_USER:-}" "${MINIO_ROOT_PASSWORD:-}"')
  MC_USER="${cred_lines[0]:-}"
  MC_PASSWORD="${cred_lines[1]:-}"
  if [[ -z "$MC_USER" || -z "$MC_PASSWORD" ]]; then
    die "Unable to read MINIO_ROOT_USER/MINIO_ROOT_PASSWORD from target pod."
  fi

  pod_ip="$(kubectl -n "$NAMESPACE" get pod "$POD" -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
  [[ -n "$pod_ip" ]] || die "Unable to resolve pod IP for $NAMESPACE/$POD."
  MC_ENDPOINT="http://${pod_ip}:9000"

  helper_pod="minio-mc-helper-${RANDOM}-${RANDOM}"
  log "Creating helper pod for mc transfer: $helper_pod"
  kubectl -n "$NAMESPACE" run "$helper_pod" --image=docker.io/minio/mc:RELEASE.2025-04-16T18-13-26Z --restart=Never --command -- sleep 3600 >/dev/null

  if ! kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$helper_pod" --timeout=120s >/dev/null 2>&1; then
    kubectl -n "$NAMESPACE" delete pod "$helper_pod" --ignore-not-found >/dev/null 2>&1 || true
    die "Helper pod failed to become ready: $helper_pod"
  fi

  MC_HELPER_POD="$helper_pod"
}

stop_mc_helper_session() {
  if [[ -n "$MC_HELPER_POD" ]]; then
    log "Removing helper pod: $MC_HELPER_POD"
    kubectl -n "$NAMESPACE" delete pod "$MC_HELPER_POD" --ignore-not-found >/dev/null 2>&1 || true
  fi
  MC_HELPER_POD=""
  MC_ENDPOINT=""
  MC_USER=""
  MC_PASSWORD=""
}

list_buckets_via_mc() {
  mc_exec_in_pod ls --json local | jq -r 'select(.type=="folder") | .key | sub("/$"; "")'
}

list_object_keys_via_mc() {
  local bucket="$1"
  mc_exec_in_pod ls --recursive --json "local/$bucket" | jq -r 'select(.type=="file") | .key'
}

list_backup_buckets_from_archive() {
  local file_path="$1"
  local buckets_raw=""

  if [[ "$file_path" == *.gz ]]; then
    buckets_raw="$(tar xzOf "$file_path" buckets.txt 2>/dev/null || true)"
    if [[ -z "$buckets_raw" ]]; then
      buckets_raw="$(tar xzOf "$file_path" ./buckets.txt 2>/dev/null || true)"
    fi
  else
    buckets_raw="$(tar xOf "$file_path" buckets.txt 2>/dev/null || true)"
    if [[ -z "$buckets_raw" ]]; then
      buckets_raw="$(tar xOf "$file_path" ./buckets.txt 2>/dev/null || true)"
    fi
  fi

  if [[ -n "$buckets_raw" ]]; then
    printf '%s\n' "$buckets_raw" | awk 'NF > 0'
    return 0
  fi

  if [[ "$file_path" == *.gz ]]; then
    tar tzf "$file_path" 2>/dev/null | awk '
      {
        gsub(/^\.\//, "", $0)
        if ($0 ~ /^data\/[^/]+(\/.*)?$/) {
          split($0, p, "/")
          if (p[2] != "" && !seen[p[2]]++) print p[2]
        }
      }
    '
  else
    tar tf "$file_path" 2>/dev/null | awk '
      {
        gsub(/^\.\//, "", $0)
        if ($0 ~ /^data\/[^/]+(\/.*)?$/) {
          split($0, p, "/")
          if (p[2] != "" && !seen[p[2]]++) print p[2]
        }
      }
    '
  fi
}

resolve_backup_bucket_selection() {
  local available=()
  local idx bucket

  SELECTED_BUCKETS=()
  SOURCE_BUCKET=""
  TARGET_BUCKET=""

  if [[ "$TRANSFER_MODE" != "pod_mc_stream" ]]; then
    if [[ "${#BUCKET_FILTERS[@]}" -gt 0 ]]; then
      die "--bucket is only supported when transfer mode is pod_mc_stream."
    fi
    return 0
  fi

  require_cmd jq
  mapfile -t available < <(list_buckets_via_mc)

  if [[ "${#BUCKET_FILTERS[@]}" -gt 0 ]]; then
    bucket="${BUCKET_FILTERS[0]}"
    if ! bucket_in_list "$bucket" "${available[@]}"; then
      die "Bucket '$bucket' not found in MinIO. Available buckets: $(join_by_comma "${available[@]}")"
    fi
    SOURCE_BUCKET="$bucket"
    TARGET_BUCKET="$bucket"
    SELECTED_BUCKETS=("$SOURCE_BUCKET")
    return 0
  fi

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    die "--bucket is required in non-interactive mode. ALL BUCKET is disabled."
  fi

  if [[ "${#available[@]}" -eq 0 ]]; then
    die "No bucket found in MinIO."
  fi

  echo "Buckets in $NAMESPACE/$POD:"
  for idx in "${!available[@]}"; do
    printf '  [%d] %s\n' "$((idx+1))" "${available[$idx]}"
  done
  echo "  [0] exit"
  idx="$(pick_index_or_exit "${#available[@]}")"
  SOURCE_BUCKET="${available[$((idx-1))]}"
  TARGET_BUCKET="$SOURCE_BUCKET"
  SELECTED_BUCKETS=("$SOURCE_BUCKET")
}

resolve_restore_bucket_selection() {
  local file_path="$1"
  local backup_mode="$2"
  local available=()
  local existing=()
  local existing_raw=""
  local idx bucket choice

  SELECTED_BUCKETS=()
  SOURCE_BUCKET=""
  TARGET_BUCKET=""

  if [[ "$backup_mode" != "pod_mc_stream_v1" ]]; then
    if [[ "${#BUCKET_FILTERS[@]}" -gt 0 || -n "$RESTORE_TARGET_BUCKET" ]]; then
      die "--bucket/--target-bucket are only supported when restoring pod_mc_stream backups."
    fi
    return 0
  fi

  require_cmd jq

  mapfile -t available < <(list_backup_buckets_from_archive "$file_path")
  if [[ "${#available[@]}" -eq 0 ]]; then
    die "No bucket found in backup file."
  fi

  if [[ "${#BUCKET_FILTERS[@]}" -gt 0 ]]; then
    bucket="${BUCKET_FILTERS[0]}"
    if ! bucket_in_list "$bucket" "${available[@]}"; then
      die "Bucket '$bucket' not found in backup file. Available buckets: $(join_by_comma "${available[@]}")"
    fi
    SOURCE_BUCKET="$bucket"
  elif [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ "${#available[@]}" -ne 1 ]]; then
      die "--bucket is required in non-interactive restore when backup has multiple buckets."
    fi
    SOURCE_BUCKET="${available[0]}"
  else
    echo "Source buckets in backup file:"
    for idx in "${!available[@]}"; do
      printf '  [%d] %s\n' "$((idx+1))" "${available[$idx]}"
    done
    echo "  [0] exit"
    idx="$(pick_index_or_exit "${#available[@]}")"
    SOURCE_BUCKET="${available[$((idx-1))]}"
  fi

  if [[ -n "$RESTORE_TARGET_BUCKET" ]]; then
    TARGET_BUCKET="$RESTORE_TARGET_BUCKET"
  elif [[ "$NON_INTERACTIVE" == "true" ]]; then
    TARGET_BUCKET="$SOURCE_BUCKET"
  else
    start_mc_helper_session
    if ! existing_raw="$(list_buckets_via_mc)"; then
      die "Unable to list destination buckets from target MinIO."
    fi
    mapfile -t existing < <(printf '%s\n' "$existing_raw" | awk 'NF > 0')
    echo "Choose destination bucket for restore source '$SOURCE_BUCKET':"
    echo "  [1] SAME_AS_SOURCE ($SOURCE_BUCKET)"
    echo "  [2] CREATE_NEW_BUCKET"
    local base=2
    if [[ "${#existing[@]}" -gt 0 ]]; then
      for idx in "${!existing[@]}"; do
        printf '  [%d] EXISTING: %s\n' "$((idx+3))" "${existing[$idx]}"
      done
      base=$(( ${#existing[@]} + 2 ))
    fi
    echo "  [0] exit"
    choice="$(pick_index_or_exit "$base")"
    if [[ "$choice" -eq 1 ]]; then
      TARGET_BUCKET="$SOURCE_BUCKET"
    elif [[ "$choice" -eq 2 ]]; then
      while true; do
        read_tty "New destination bucket name: " TARGET_BUCKET
        if ! validate_bucket_name "$TARGET_BUCKET"; then
          warn "Invalid bucket name '$TARGET_BUCKET'."
          continue
        fi
        break
      done
    else
      TARGET_BUCKET="${existing[$((choice-3))]}"
    fi
  fi

  if ! validate_bucket_name "$TARGET_BUCKET"; then
    die "Invalid target bucket name '$TARGET_BUCKET'."
  fi

  SELECTED_BUCKETS=("$SOURCE_BUCKET")
}

backup_via_mc_stream() {
  local compress_effective="$1"
  local output_file="$2"
  local tmp_dir data_root bucket key dest object_count bucket_count
  local buckets=("${SELECTED_BUCKETS[@]}")

  require_cmd jq
  require_cmd tar
  if [[ "$compress_effective" == "gzip" ]]; then
    require_cmd gzip
  fi

  start_mc_helper_session

  tmp_dir="$(mktemp -d)"
  data_root="${tmp_dir}/data"
  mkdir -p "$data_root"

  bucket_count="${#buckets[@]}"
  object_count=0

  if (( bucket_count > 0 )); then
    printf '%s\n' "${buckets[@]}" > "${tmp_dir}/buckets.txt"
  else
    : > "${tmp_dir}/buckets.txt"
  fi
  echo "pod_mc_stream_v1" > "${tmp_dir}/.backup_mode"

  for bucket in "${buckets[@]}"; do
    [[ -n "$bucket" ]] || continue
    log "Downloading bucket: $bucket"
    mkdir -p "${data_root}/${bucket}"
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      dest="${data_root}/${bucket}/${key}"
      mkdir -p "$(dirname "$dest")"
      mc_exec_in_pod cat "local/${bucket}/${key}" > "$dest"
      object_count=$((object_count + 1))
    done < <(list_object_keys_via_mc "$bucket")
  done

  if [[ "$compress_effective" == "gzip" ]]; then
    tar czf "$output_file" -C "$tmp_dir" .
  else
    tar cf "$output_file" -C "$tmp_dir" .
  fi

  rm -rf "$tmp_dir"
  log "Downloaded ${object_count} object(s) from ${bucket_count} bucket(s) via mc."
}

restore_via_mc_stream() {
  local file_path="$1"
  local clear_destination="$2"
  local tmp_dir backup_data_root bucket_root key object_count
  local source_bucket="$SOURCE_BUCKET"
  local target_bucket="$TARGET_BUCKET"

  require_cmd jq
  require_cmd tar

  start_mc_helper_session

  tmp_dir="$(mktemp -d)"
  if [[ "$file_path" == *.gz ]]; then
    tar xzf "$file_path" -C "$tmp_dir"
  else
    tar xf "$file_path" -C "$tmp_dir"
  fi

  if [[ ! -f "${tmp_dir}/.backup_mode" ]] || [[ "$(cat "${tmp_dir}/.backup_mode")" != "pod_mc_stream_v1" ]]; then
    rm -rf "$tmp_dir"
    die "Backup file is not in pod_mc_stream format. This restore mode only supports backups created by this script when transfer mode is pod_mc_stream."
  fi

  backup_data_root="${tmp_dir}/data"
  [[ -d "$backup_data_root" ]] || {
    rm -rf "$tmp_dir"
    die "Invalid backup format: missing data directory."
  }

  bucket_root="${backup_data_root}/${source_bucket}"
  if [[ ! -d "$bucket_root" ]]; then
    rm -rf "$tmp_dir"
    die "Source bucket '$source_bucket' not found in backup archive."
  fi

  if [[ "$clear_destination" == "true" ]]; then
    log "Removing destination bucket: $target_bucket"
    mc_exec_in_pod rb --force "local/${target_bucket}" >/dev/null
  fi

  object_count=0
  log "Restoring bucket: ${source_bucket} -> ${target_bucket}"
  mc_exec_in_pod mb --ignore-existing "local/${target_bucket}" >/dev/null
  while IFS= read -r -d '' key; do
    key="${key#${bucket_root}/}"
    [[ -n "$key" ]] || continue
    mc_exec_in_pod_stdin pipe "local/${target_bucket}/${key}" < "${bucket_root}/${key}" >/dev/null
    object_count=$((object_count + 1))
  done < <(find "$bucket_root" -type f -print0)

  rm -rf "$tmp_dir"
  log "Uploaded ${object_count} object(s) from '$source_bucket' to '$target_bucket'."
}

detect_backup_mode() {
  local file_path="$1"
  local mode=""
  local candidates=( ".backup_mode" "./.backup_mode" )
  local candidate=""

  for candidate in "${candidates[@]}"; do
    if [[ "$file_path" == *.gz ]]; then
      mode="$(tar xzOf "$file_path" "$candidate" 2>/dev/null | head -n1 || true)"
    else
      mode="$(tar xOf "$file_path" "$candidate" 2>/dev/null | head -n1 || true)"
    fi
    if [[ -n "$mode" ]]; then
      printf '%s\n' "$mode"
      return 0
    fi
  done

  printf 'raw_data_v1\n'
}

resolve_hostpath_data_dir() {
  local target_mount volume_name container_name mount_path host_path
  local mounts_raw volumes_raw

  target_mount="${DATA_DIR%/}"
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

resolve_transfer_mode() {
  TRANSFER_MODE=""
  HOSTPATH_DIR=""
  local pod_node=""

  if [[ "${#BUCKET_FILTERS[@]}" -gt 0 ]]; then
    if exec_in_pod sh -c 'command -v mc >/dev/null 2>&1' >/dev/null 2>&1; then
      TRANSFER_MODE="pod_mc_stream"
      return 0
    fi
    die "--bucket requires pod_mc_stream mode, but mc is not available in target pod."
  fi

  if exec_in_pod sh -c 'command -v tar >/dev/null 2>&1' >/dev/null 2>&1; then
    TRANSFER_MODE="pod_tar"
    return 0
  fi

  HOSTPATH_DIR="$(resolve_hostpath_data_dir || true)"
  if [[ -n "$HOSTPATH_DIR" && -d "$HOSTPATH_DIR" ]]; then
    TRANSFER_MODE="hostpath"
    return 0
  fi

  if exec_in_pod sh -c 'command -v mc >/dev/null 2>&1' >/dev/null 2>&1; then
    TRANSFER_MODE="pod_mc_stream"
    return 0
  fi

  pod_node="$(kubectl -n "$NAMESPACE" get pod "$POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  if [[ -n "$pod_node" ]]; then
    die "tar command not found in pod '$POD' (container: ${CONTAINER:-<default>}), hostPath is unavailable locally, and mc is not available in container. Pod is running on node '$pod_node'."
  fi
  die "No supported transfer method found for pod '$POD' (container: ${CONTAINER:-<default>}). Need one of: tar in pod, local hostPath access, or mc in pod."
}

validate_mode_specific_options() {
  if [[ "$MODE" != "restore" && -n "$RESTORE_TARGET_BUCKET" ]]; then
    die "--target-bucket is only supported for restore."
  fi
  if [[ -n "$RESTORE_TARGET_BUCKET" ]] && ! validate_bucket_name "$RESTORE_TARGET_BUCKET"; then
    die "Invalid --target-bucket name '$RESTORE_TARGET_BUCKET'."
  fi
}

backup_action() {
  local timestamp output_dir compress_effective tmp_output size

  resolve_transfer_mode
  if [[ "$TRANSFER_MODE" == "pod_mc_stream" ]]; then
    resolve_backup_bucket_selection
  elif [[ "${#BUCKET_FILTERS[@]}" -gt 0 ]]; then
    die "--bucket is only supported when transfer mode is pod_mc_stream."
  fi

  timestamp="$(date '+%Y%m%d_%H%M%S')"

  if [[ -z "$OUTPUT" || "$OUTPUT" == */ || -d "$OUTPUT" ]]; then
    output_dir="${OUTPUT:-.}"
    OUTPUT="${output_dir%/}/minio_${NAMESPACE}_${POD}_${timestamp}.tar.gz"
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

  if [[ "$TRANSFER_MODE" == "hostpath" || "$TRANSFER_MODE" == "pod_mc_stream" ]]; then
    require_cmd tar
  fi

  if [[ "$TRANSFER_MODE" == "hostpath" ]]; then
    local pod_node=""
    if [[ ! -d "$HOSTPATH_DIR" ]]; then
      pod_node="$(kubectl -n "$NAMESPACE" get pod "$POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
      if [[ -n "$pod_node" ]]; then
        die "Host path from pod spec is not available locally: $HOSTPATH_DIR (pod node: $pod_node). Run script on that node, or switch to a MinIO image that has tar."
      fi
      die "Host path from pod spec is not available locally: $HOSTPATH_DIR. Run script on the MinIO node, or switch to a MinIO image that has tar."
    fi
  fi

  mkdir -p "$(dirname "$OUTPUT")"

  log "Backup target:"
  log "  Namespace : $NAMESPACE"
  log "  Pod       : $POD"
  log "  Container : ${CONTAINER:-<default>}"
  log "  Data dir  : $DATA_DIR"
  log "  Output    : $OUTPUT"
  log "  Compress  : $compress_effective"
  log "  Transfer  : $TRANSFER_MODE"
  if [[ "$TRANSFER_MODE" == "hostpath" ]]; then
    log "  Host path : $HOSTPATH_DIR"
  elif [[ "$TRANSFER_MODE" == "pod_mc_stream" ]]; then
    log "  Bucket    : ${SOURCE_BUCKET:-<unset>}"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  tmp_output="${OUTPUT}.tmp.$$"
  trap 'rm -f "$tmp_output"; stop_mc_helper_session' EXIT

  if [[ "$TRANSFER_MODE" == "pod_tar" && "$compress_effective" == "gzip" ]]; then
    exec_in_pod sh -c 'set -e; dir="$1"; [ -d "$dir" ] || { echo "Missing data dir: $dir" >&2; exit 1; }; cd "$dir"; tar cf - .' sh "$DATA_DIR" | gzip -c > "$tmp_output"
  elif [[ "$TRANSFER_MODE" == "pod_tar" ]]; then
    exec_in_pod sh -c 'set -e; dir="$1"; [ -d "$dir" ] || { echo "Missing data dir: $dir" >&2; exit 1; }; cd "$dir"; tar cf - .' sh "$DATA_DIR" > "$tmp_output"
  elif [[ "$TRANSFER_MODE" == "pod_mc_stream" ]]; then
    backup_via_mc_stream "$compress_effective" "$tmp_output"
  elif [[ "$compress_effective" == "gzip" ]]; then
    tar czf "$tmp_output" -C "$HOSTPATH_DIR" .
  else
    tar cf "$tmp_output" -C "$HOSTPATH_DIR" .
  fi

  mv "$tmp_output" "$OUTPUT"
  trap - EXIT
  stop_mc_helper_session

  size="$(du -h "$OUTPUT" | awk '{print $1}')"
  log "Backup completed: $OUTPUT (${size})"
}

restore_action() {
  local input_cmd=() reply backup_mode

  resolve_transfer_mode

  if [[ -z "$FILE" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      die "--file is required for restore in non-interactive mode."
    fi
    read_tty "Backup file path (.tar/.tar.gz): " FILE
  fi

  [[ -f "$FILE" ]] || die "Backup file not found: $FILE"

  trap 'stop_mc_helper_session' EXIT

  if [[ "$FILE" == *.gz ]]; then
    require_cmd gzip
    input_cmd=(gzip -dc "$FILE")
  else
    input_cmd=(cat "$FILE")
  fi

  backup_mode="$(detect_backup_mode "$FILE")"
  resolve_restore_bucket_selection "$FILE" "$backup_mode"

  log "Restore target:"
  log "  Namespace         : $NAMESPACE"
  log "  Pod               : $POD"
  log "  Container         : ${CONTAINER:-<default>}"
  log "  Data dir          : $DATA_DIR"
  log "  File              : $FILE"
  log "  Backup mode       : $backup_mode"
  log "  Clear destination : $CLEAR_DESTINATION"
  log "  Transfer          : $TRANSFER_MODE"
  if [[ "$TRANSFER_MODE" == "hostpath" ]]; then
    log "  Host path         : $HOSTPATH_DIR"
  fi
  if [[ "$backup_mode" == "pod_mc_stream_v1" ]]; then
    log "  Source bucket     : ${SOURCE_BUCKET:-<unset>}"
    log "  Target bucket     : ${TARGET_BUCKET:-<unset>}"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  if [[ "$YES" != "true" && "$NON_INTERACTIVE" != "true" ]]; then
    read_tty "Restore can overwrite MinIO data. Proceed? (y/N): " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      die "Aborted by user."
    fi
  fi

  if [[ "$backup_mode" == "pod_mc_stream_v1" ]]; then
    restore_via_mc_stream "$FILE" "$CLEAR_DESTINATION"
  elif [[ "$TRANSFER_MODE" == "pod_tar" ]]; then
    exec_in_pod sh -c 'mkdir -p "$1"' sh "$DATA_DIR"

    if [[ "$CLEAR_DESTINATION" == "true" ]]; then
      log "Clearing existing contents in $DATA_DIR before restore..."
      exec_in_pod sh -c 'set -e; dir="$1"; find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} \;' sh "$DATA_DIR"
    fi

    "${input_cmd[@]}" | exec_in_pod_stdin sh -c 'set -e; dir="$1"; tar xf - -C "$dir"' sh "$DATA_DIR"
  elif [[ "$TRANSFER_MODE" == "pod_mc_stream" ]]; then
    die "Backup file is raw /data archive, but current environment only supports pod_mc_stream transfer. Restore this file from the MinIO node (hostPath available) or from an image with tar in pod."
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
  log "Restore completed."
  trap - EXIT
  stop_mc_helper_session
}

choose_mode
validate_mode_specific_options
discover_minio_pods

if [[ "$MODE" == "list" ]]; then
  print_candidates
  exit 0
fi

resolve_target_from_candidates

if [[ "$MODE" == "backup" ]]; then
  backup_action
elif [[ "$MODE" == "restore" ]]; then
  restore_action
else
  die "Unsupported command: $MODE"
fi

#!/usr/bin/env bash
set -euo pipefail

DEV_BASE="/srv/data/dev/platform/storage"
PROD_BASE="/home/hnq/hnq_data/prod/platform/storage"
DEV_OUTLINE="/srv/data/dev/platform/admin/outline/data"
PROD_OUTLINE="/home/hnq/hnq_data/prod/platform/admin/outline/data"
SERVICES=(mariadb minio opensearch postgres redis)
DRY_RUN=0
INCLUDE_OUTLINE=0
DELETE_EXTRA=0

usage() {
  cat <<'EOF'
Clone storage data from dev to prod on the same host.

Usage:
  clone_dev_to_prod_data.sh [options]

Options:
  --dev-base <path>       Dev storage base (default: /srv/data/dev/platform/storage)
  --prod-base <path>      Prod storage base (default: /home/hnq/hnq_data/prod/platform/storage)
  --services "a b c"      Services to clone (default: mariadb minio opensearch postgres redis)
  --include-outline       Also clone outline data
  --dev-outline <path>    Dev outline path (default: /srv/data/dev/platform/admin/outline/data)
  --prod-outline <path>   Prod outline path (default: /home/hnq/hnq_data/prod/platform/admin/outline/data)
  --delete                Delete files in destination not present in source (rsync --delete)
  --dry-run               Preview only (rsync -n)
  -h, --help              Show help

Examples:
  ./infra/scripts/clone_dev_to_prod_data.sh --dry-run
  ./infra/scripts/clone_dev_to_prod_data.sh --services "minio redis"
  ./infra/scripts/clone_dev_to_prod_data.sh --include-outline
EOF
}

log() {
  echo "[$(date '+%F %T')] $*"
}

warn() {
  echo "[$(date '+%F %T')] WARN: $*" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev-base)
      DEV_BASE="$2"
      shift 2
      ;;
    --prod-base)
      PROD_BASE="$2"
      shift 2
      ;;
    --services)
      read -r -a SERVICES <<< "$2"
      shift 2
      ;;
    --include-outline)
      INCLUDE_OUTLINE=1
      shift
      ;;
    --dev-outline)
      DEV_OUTLINE="$2"
      shift 2
      ;;
    --prod-outline)
      PROD_OUTLINE="$2"
      shift 2
      ;;
    --delete)
      DELETE_EXTRA=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      warn "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

RSYNC_ARGS=( -aHAX --numeric-ids --info=progress2 )
[[ "$DELETE_EXTRA" -eq 1 ]] && RSYNC_ARGS+=( --delete )
[[ "$DRY_RUN" -eq 1 ]] && RSYNC_ARGS+=( -n )

copy_dir() {
  local src="$1"
  local dst="$2"
  local label="$3"

  if [[ ! -d "$src" ]]; then
    warn "Skip ${label}: source not found: ${src}"
    return 0
  fi

  mkdir -p "$dst"
  log "Sync ${label}: ${src} -> ${dst}"
  rsync "${RSYNC_ARGS[@]}" "$src/" "$dst/"
}

log "Start clone dev -> prod"
log "DEV_BASE=${DEV_BASE}"
log "PROD_BASE=${PROD_BASE}"
log "SERVICES=${SERVICES[*]}"
[[ "$DRY_RUN" -eq 1 ]] && log "Mode: DRY-RUN"

for svc in "${SERVICES[@]}"; do
  copy_dir "${DEV_BASE}/${svc}" "${PROD_BASE}/${svc}" "service ${svc}"
done

if [[ "$INCLUDE_OUTLINE" -eq 1 ]]; then
  copy_dir "$DEV_OUTLINE" "$PROD_OUTLINE" "outline"
fi

log "Clone completed"

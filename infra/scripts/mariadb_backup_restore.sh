#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Unified MariaDB backup/restore helper for k3s.

Usage:
  mariadb_backup_restore.sh [backup|restore|list] [options]

Commands:
  backup                Backup one database or all databases.
  restore               Restore backup file into a selected database.
  list                  Only list detected MariaDB pods.

Options:
  --namespace <ns>      Namespace of target pod (optional; auto-select if omitted)
  --pod <name>          Pod name of MariaDB (optional; auto-select if omitted)
  --container <name>    Container name (optional)
  --host <host>         DB host from inside pod (default: 127.0.0.1)
  --port <port>         DB port (default: 3306)
  --user <name>         DB user (prompt if omitted in interactive mode)
  --ask-pass            Prompt for password
  --password <pass>     Password inline (avoid shell history)
  --admin-user <name>   Admin DB user for CREATE/GRANT fallback in restore mode
  --admin-ask-pass      Prompt for admin password when admin user is set
  --admin-password <p>  Admin password inline (avoid shell history)
  --db <name>           Database name (optional; script can prompt/choose)
  --all-databases       Backup all databases (backup mode only)
  --file <path>         SQL file for restore (.sql or .sql.gz)
  --output <path>       Output file or directory for backup
  --compress <mode>     auto|gzip|none (default: auto)
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

read_secret_tty() {
  local prompt="$1"
  local var_name="$2"
  local answer=""
  read -r -s -p "$prompt" answer < /dev/tty
  echo >&2
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

MODE="${1:-}"
if [[ "$MODE" == "backup" || "$MODE" == "restore" || "$MODE" == "list" ]]; then
  shift
else
  MODE=""
fi

NAMESPACE=""
POD=""
CONTAINER=""
HOST="127.0.0.1"
PORT="3306"
USER_NAME=""
ASK_PASS="false"
PASSWORD=""
ADMIN_USER=""
ADMIN_PASSWORD=""
ADMIN_ASK_PASS="false"
DB=""
ALL_DATABASES="false"
FILE=""
OUTPUT=""
COMPRESS="auto"
YES="false"
NON_INTERACTIVE="false"
DRY_RUN="false"
DB_SELECTED_NEW="false"
ADMIN_AUTH_RESOLVED="false"
ADMIN_AUTH_AVAILABLE="false"
ADMIN_EXEC_USER=""
ADMIN_EXEC_PASSWORD=""
ADMIN_EXEC_MODE=""
ADMIN_EXEC_SOURCE=""

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
    --host)
      HOST="${2:-}"
      shift 2
      ;;
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    --user)
      USER_NAME="${2:-}"
      shift 2
      ;;
    --ask-pass)
      ASK_PASS="true"
      shift
      ;;
    --password)
      PASSWORD="${2:-}"
      shift 2
      ;;
    --admin-user)
      ADMIN_USER="${2:-}"
      shift 2
      ;;
    --admin-password)
      ADMIN_PASSWORD="${2:-}"
      shift 2
      ;;
    --admin-ask-pass)
      ADMIN_ASK_PASS="true"
      shift
      ;;
    --db)
      DB="${2:-}"
      shift 2
      ;;
    --all-databases)
      ALL_DATABASES="true"
      shift
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

if [[ "$ALL_DATABASES" == "true" && -n "$DB" ]]; then
  die "Use either --db or --all-databases, not both."
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
  local idx
  idx="$(pick_index 3)"
  case "$idx" in
    1) MODE="backup" ;;
    2) MODE="restore" ;;
    3) MODE="list" ;;
  esac
}

discover_mariadb_pods() {
  local raw line ns pod phase container image lower_image lower_name lower_container
  if ! raw="$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}{end}' 2>&1)"; then
    die "kubectl get pods -A failed: $raw"
  fi

  mapfile -t CANDIDATES < <(
    printf '%s\n' "$raw" |
    while IFS=$'\t' read -r ns pod phase container image; do
      [[ -n "$ns" && -n "$pod" && -n "$container" && -n "$image" ]] || continue
      lower_image="$(echo "$image" | tr '[:upper:]' '[:lower:]')"
      lower_name="$(echo "$pod" | tr '[:upper:]' '[:lower:]')"
      lower_container="$(echo "$container" | tr '[:upper:]' '[:lower:]')"
      if [[ "$lower_image" == *mariadb* || "$lower_name" == *mariadb* || "$lower_container" == *mariadb* ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$ns" "$pod" "$container" "$image" "$phase"
      fi
    done
  )

  if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
    die "No MariaDB pod detected in cluster."
  fi
}

print_candidates() {
  local i=1 line ns pod container image phase
  echo "Detected MariaDB pods:"
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
    die "Pod '$POD' not found among detected MariaDB pods."
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
      die "No MariaDB pod found in namespace '$NAMESPACE'."
    fi

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      die "Multiple MariaDB pods found in namespace '$NAMESPACE'. Use --pod."
    fi

    echo "Multiple MariaDB pods in namespace '$NAMESPACE':"
    local j=1
    for line in "${ns_matches[@]}"; do
      IFS=$'\t' read -r ns pod container image phase <<< "$line"
      echo "  [$j] pod=$pod container=$container phase=$phase image=$image"
      ((j++))
    done
    local idx
    idx="$(pick_index "${#ns_matches[@]}")"
    IFS=$'\t' read -r ns pod container image phase <<< "${ns_matches[$((idx-1))]}"
    POD="$pod"
    [[ -z "$CONTAINER" ]] && CONTAINER="$container"
    return 0
  fi

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ "${#CANDIDATES[@]}" -ne 1 ]]; then
      die "Multiple MariaDB pods detected. Use --namespace and --pod in non-interactive mode."
    fi
    IFS=$'\t' read -r NAMESPACE POD detected_container _ _ <<< "${CANDIDATES[0]}"
    [[ -z "$CONTAINER" ]] && CONTAINER="$detected_container"
    return 0
  fi

  print_candidates
  local idx selected detected_container
  idx="$(pick_index "${#CANDIDATES[@]}")"
  selected="${CANDIDATES[$((idx-1))]}"
  IFS=$'\t' read -r NAMESPACE POD detected_container _ _ <<< "$selected"
  [[ -z "$CONTAINER" ]] && CONTAINER="$detected_container"
}

ensure_credentials() {
  if [[ -z "$USER_NAME" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      die "--user is required in non-interactive mode."
    fi
    read_tty "DB user: " USER_NAME
  fi

  if [[ -z "$PASSWORD" ]]; then
    if [[ "$ASK_PASS" == "true" ]]; then
      read_secret_tty "DB password: " PASSWORD
    elif [[ "$NON_INTERACTIVE" != "true" ]]; then
      read_secret_tty "DB password (press Enter if empty): " PASSWORD
    fi
  fi
}

exec_in_pod() {
  local args=("$@")
  local container_flag=()
  if [[ -n "$CONTAINER" ]]; then
    container_flag=(-c "$CONTAINER")
  fi
  kubectl -n "$NAMESPACE" exec -i "${container_flag[@]}" "$POD" -- "${args[@]}"
}

list_databases() {
  local cmd=(mariadb -h "$HOST" -P "$PORT" -u "$USER_NAME" -N -e "SHOW DATABASES;")
  if [[ -n "$PASSWORD" ]]; then
    cmd=(env "MYSQL_PWD=$PASSWORD" "${cmd[@]}")
  fi

  exec_in_pod "${cmd[@]}"
}

resolve_database() {
  local allow_all="$1"
  local dbs=() db idx

  if [[ -n "$DB" || "$ALL_DATABASES" == "true" ]]; then
    return 0
  fi

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ "$allow_all" == "true" ]]; then
      die "Specify --db or --all-databases in non-interactive mode."
    fi
    die "Specify --db in non-interactive mode."
  fi

  mapfile -t dbs < <(list_databases | awk 'NF > 0')
  if [[ "${#dbs[@]}" -eq 0 ]]; then
    die "No database found or unable to list databases with current credentials."
  fi

  echo "Databases in $NAMESPACE/$POD:"
  if [[ "$allow_all" == "true" ]]; then
    echo "  [1] ALL_DATABASES"
    for idx in "${!dbs[@]}"; do
      printf '  [%d] %s\n' "$((idx+2))" "${dbs[$idx]}"
    done
    idx="$(pick_index "$(( ${#dbs[@]} + 1 ))")"
    if [[ "$idx" -eq 1 ]]; then
      ALL_DATABASES="true"
      return 0
    fi
    DB="${dbs[$((idx-2))]}"
    DB_SELECTED_NEW="false"
    return 0
  fi

  # Restore mode can target an existing DB or create a new one.
  if [[ "$MODE" == "restore" ]]; then
    echo "  [1] CREATE_NEW_DATABASE"
    for idx in "${!dbs[@]}"; do
      printf '  [%d] %s\n' "$((idx+2))" "${dbs[$idx]}"
    done
    idx="$(pick_index "$(( ${#dbs[@]} + 1 ))")"
    if [[ "$idx" -eq 1 ]]; then
      while true; do
        read_tty "New database name: " db
        if [[ -z "$db" ]]; then
          warn "Database name cannot be empty."
          continue
        fi
        if [[ ! "$db" =~ ^[A-Za-z0-9_]+$ ]]; then
          warn "Invalid database name '$db'. Use only letters, numbers, and underscore."
          continue
        fi
        DB="$db"
        DB_SELECTED_NEW="true"
        return 0
      done
    fi
    DB="${dbs[$((idx-2))]}"
    DB_SELECTED_NEW="false"
    return 0
  fi

  for idx in "${!dbs[@]}"; do
    printf '  [%d] %s\n' "$((idx+1))" "${dbs[$idx]}"
  done
  idx="$(pick_index "${#dbs[@]}")"
  DB="${dbs[$((idx-1))]}"
  DB_SELECTED_NEW="false"
}

run_mariadb_sql() {
  local user="$1"
  local pass="$2"
  local sql="$3"
  local db="${4:-}"
  local no_headers="${5:-false}"
  local cmd=(mariadb -h "$HOST" -P "$PORT" -u "$user")

  if [[ "$no_headers" == "true" ]]; then
    cmd+=(-N)
  fi

  if [[ -n "$db" ]]; then
    cmd+=("$db")
  fi
  cmd+=(-e "$sql")

  if [[ -n "$pass" ]]; then
    cmd=(env "MYSQL_PWD=$pass" "${cmd[@]}")
  fi

  exec_in_pod "${cmd[@]}"
}

run_mariadb_sql_transport() {
  local user="$1"
  local pass="$2"
  local sql="$3"
  local db="${4:-}"
  local no_headers="${5:-false}"
  local transport="${6:-tcp}"
  local cmd=(mariadb -u "$user")

  case "$transport" in
    tcp)
      cmd+=(-h "$HOST" -P "$PORT")
      ;;
    socket)
      cmd+=(--protocol=socket)
      ;;
    socket_run)
      cmd+=(--protocol=socket --socket=/run/mysqld/mysqld.sock)
      ;;
    socket_var)
      cmd+=(--protocol=socket --socket=/var/run/mysqld/mysqld.sock)
      ;;
    *)
      die "Unsupported MariaDB transport '$transport'"
      ;;
  esac

  if [[ "$no_headers" == "true" ]]; then
    cmd+=(-N)
  fi

  if [[ -n "$db" ]]; then
    cmd+=("$db")
  fi
  cmd+=(-e "$sql")

  if [[ -n "$pass" ]]; then
    cmd=(env "MYSQL_PWD=$pass" "${cmd[@]}")
  fi

  exec_in_pod "${cmd[@]}"
}

probe_mariadb_identity() {
  local user="$1"
  local pass="$2"
  local mode
  local modes=(tcp socket socket_run socket_var)

  for mode in "${modes[@]}"; do
    if run_mariadb_sql_transport "$user" "$pass" "SELECT 1;" "" "false" "$mode" >/dev/null 2>&1; then
      echo "$mode"
      return 0
    fi
  done

  return 1
}

can_connect_restore_database() {
  local cmd=(mariadb -h "$HOST" -P "$PORT" -u "$USER_NAME" "$DB" -e "SELECT 1;")
  if [[ -n "$PASSWORD" ]]; then
    cmd=(env "MYSQL_PWD=$PASSWORD" "${cmd[@]}")
  fi

  exec_in_pod "${cmd[@]}" >/dev/null 2>&1
}

can_login_restore_user() {
  local cmd=(mariadb -h "$HOST" -P "$PORT" -u "$USER_NAME" -e "SELECT 1;")
  if [[ -n "$PASSWORD" ]]; then
    cmd=(env "MYSQL_PWD=$PASSWORD" "${cmd[@]}")
  fi

  exec_in_pod "${cmd[@]}" >/dev/null 2>&1
}

create_restore_database_with_user() {
  local user="$1"
  local pass="$2"
  local db_escaped sql

  db_escaped="${DB//\`/\`\`}"
  sql="CREATE DATABASE IF NOT EXISTS \`$db_escaped\`;"
  run_mariadb_sql "$user" "$pass" "$sql"
}

fetch_root_password_from_pod_env() {
  exec_in_pod sh -c 'printf "%s" "${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"'
}

prompt_admin_credentials_if_possible() {
  local user_input=""
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    return 1
  fi

  read_tty "Admin DB user for CREATE/GRANT fallback (leave empty to skip): " user_input
  if [[ -z "$user_input" ]]; then
    return 1
  fi

  ADMIN_USER="$user_input"
  if [[ -z "$ADMIN_PASSWORD" ]]; then
    read_secret_tty "Admin DB password (press Enter if empty): " ADMIN_PASSWORD
  fi
  return 0
}

resolve_admin_identity() {
  local mode="" root_password=""

  if [[ "$ADMIN_AUTH_RESOLVED" == "true" ]]; then
    [[ "$ADMIN_AUTH_AVAILABLE" == "true" ]]
    return $?
  fi

  if [[ -n "$ADMIN_USER" && -z "$ADMIN_PASSWORD" ]]; then
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
      if [[ "$ADMIN_ASK_PASS" == "true" ]]; then
        read_secret_tty "Admin DB password: " ADMIN_PASSWORD
      else
        read_secret_tty "Admin DB password (press Enter if empty): " ADMIN_PASSWORD
      fi
    fi
  fi

  if [[ -n "$ADMIN_USER" ]]; then
    if mode="$(probe_mariadb_identity "$ADMIN_USER" "$ADMIN_PASSWORD")"; then
      ADMIN_EXEC_USER="$ADMIN_USER"
      ADMIN_EXEC_PASSWORD="$ADMIN_PASSWORD"
      ADMIN_EXEC_MODE="$mode"
      ADMIN_EXEC_SOURCE="explicit"
      ADMIN_AUTH_AVAILABLE="true"
      ADMIN_AUTH_RESOLVED="true"
      return 0
    fi
    warn "Cannot authenticate admin user '$ADMIN_USER' with provided credentials."
  fi

  root_password="$(fetch_root_password_from_pod_env)"
  if [[ -n "$root_password" ]]; then
    if mode="$(probe_mariadb_identity "root" "$root_password")"; then
      ADMIN_EXEC_USER="root"
      ADMIN_EXEC_PASSWORD="$root_password"
      ADMIN_EXEC_MODE="$mode"
      ADMIN_EXEC_SOURCE="pod_root_env"
      ADMIN_AUTH_AVAILABLE="true"
      ADMIN_AUTH_RESOLVED="true"
      return 0
    fi
    warn "Pod root password exists but root login failed for both TCP and socket transports."
  fi

  if [[ -z "$ADMIN_USER" ]] && prompt_admin_credentials_if_possible; then
    if mode="$(probe_mariadb_identity "$ADMIN_USER" "$ADMIN_PASSWORD")"; then
      ADMIN_EXEC_USER="$ADMIN_USER"
      ADMIN_EXEC_PASSWORD="$ADMIN_PASSWORD"
      ADMIN_EXEC_MODE="$mode"
      ADMIN_EXEC_SOURCE="interactive"
      ADMIN_AUTH_AVAILABLE="true"
      ADMIN_AUTH_RESOLVED="true"
      return 0
    fi
    warn "Cannot authenticate prompted admin user '$ADMIN_USER'."
  fi

  ADMIN_AUTH_AVAILABLE="false"
  ADMIN_AUTH_RESOLVED="true"
  return 1
}

run_admin_sql() {
  local sql="$1"
  local db="${2:-}"
  local no_headers="${3:-false}"

  resolve_admin_identity || return 1
  run_mariadb_sql_transport "$ADMIN_EXEC_USER" "$ADMIN_EXEC_PASSWORD" "$sql" "$db" "$no_headers" "$ADMIN_EXEC_MODE"
}

grant_restore_user_on_database_as_root() {
  local db_escaped user_escaped host_escaped sql host
  local hosts=()

  db_escaped="${DB//\`/\`\`}"
  user_escaped="${USER_NAME//\'/\'\'}"

  mapfile -t hosts < <(
    run_admin_sql "SELECT Host FROM mysql.user WHERE User='${user_escaped}';" "" "true" |
    awk 'NF > 0'
  )

  if [[ "${#hosts[@]}" -eq 0 ]]; then
    warn "No existing MariaDB account found for user '$USER_NAME'. Trying GRANT for host '%'."
    hosts=("%")
  fi

  sql=""
  for host in "${hosts[@]}"; do
    host_escaped="${host//\'/\'\'}"
    sql+="GRANT ALL PRIVILEGES ON \`${db_escaped}\`.* TO '${user_escaped}'@'${host_escaped}'; "
  done
  sql+="FLUSH PRIVILEGES;"

  run_admin_sql "$sql"
}

ensure_database_exists_for_restore() {
  local created_with_restore_user="false"

  if ! can_login_restore_user; then
    die "Cannot authenticate MariaDB user '$USER_NAME'. Verify username/password before restore."
  fi

  if can_connect_restore_database; then
    return 0
  fi

  if create_restore_database_with_user "$USER_NAME" "$PASSWORD" >/dev/null 2>&1; then
    created_with_restore_user="true"
    if can_connect_restore_database; then
      return 0
    fi
  fi

  if ! resolve_admin_identity; then
    if [[ "$DB_SELECTED_NEW" == "true" ]]; then
      die "User '$USER_NAME' cannot create/access '$DB', and no admin credentials are available. Rerun with --admin-user/--admin-password or create DB+GRANT manually."
    fi
    die "User '$USER_NAME' cannot access '$DB', and no admin credentials are available to repair grants. Rerun with --admin-user/--admin-password."
  fi

  if [[ "$created_with_restore_user" != "true" ]]; then
    warn "Using admin credentials (${ADMIN_EXEC_SOURCE}:${ADMIN_EXEC_USER} via ${ADMIN_EXEC_MODE}) to create database '$DB' and grant access to '$USER_NAME'."
  else
    warn "Using admin credentials (${ADMIN_EXEC_SOURCE}:${ADMIN_EXEC_USER} via ${ADMIN_EXEC_MODE}) to grant access on '$DB' for '$USER_NAME'."
  fi

  run_admin_sql "CREATE DATABASE IF NOT EXISTS \`${DB//\`/\`\`}\`;" >/dev/null
  grant_restore_user_on_database_as_root >/dev/null

  if ! can_connect_restore_database; then
    die "Database '$DB' is prepared but user '$USER_NAME' still cannot connect. Verify password and grants for user '$USER_NAME'."
  fi
}

stream_restore_input() {
  local file_path="$1"
  local source_cmd=()

  if [[ "$file_path" == *.gz ]]; then
    source_cmd=(gzip -dc "$file_path")
  else
    source_cmd=(cat "$file_path")
  fi

  "${source_cmd[@]}" | awk '
    {
      lower = tolower($0)
      if (lower ~ /^[[:space:]]*(create|drop)[[:space:]]+database[[:space:]]+/) next
      if (lower ~ /^[[:space:]]*use[[:space:]]+/) next
      if (lower ~ /^[[:space:]]*\/\*![0-9]+[[:space:]]*(create|drop)[[:space:]]+database[[:space:]]+/) next
      if (lower ~ /^[[:space:]]*\/\*![0-9]+[[:space:]]*use[[:space:]]+/) next
      print
    }
  '
}

find_dump_bin() {
  exec_in_pod sh -c 'if command -v mariadb-dump >/dev/null 2>&1; then echo mariadb-dump; elif command -v mysqldump >/dev/null 2>&1; then echo mysqldump; fi'
}

backup_action() {
  local dump_bin scope timestamp output_dir compress_effective tmp_output size
  local dump_scope_args=()
  local cmd=()

  ensure_credentials
  resolve_database "true"

  dump_bin="$(find_dump_bin)"
  if [[ -z "$dump_bin" ]]; then
    die "mariadb-dump/mysqldump not found in pod '$POD'."
  fi

  scope="${DB:-all-databases}"
  timestamp="$(date '+%Y%m%d_%H%M%S')"

  if [[ -z "$OUTPUT" || "$OUTPUT" == */ || -d "$OUTPUT" ]]; then
    output_dir="${OUTPUT:-.}"
    OUTPUT="${output_dir%/}/${scope}_${NAMESPACE}_${POD}_${timestamp}.sql.gz"
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

  if [[ "$ALL_DATABASES" == "true" ]]; then
    dump_scope_args=(--all-databases)
  else
    dump_scope_args=("$DB")
  fi

  cmd=(
    "$dump_bin"
    -h "$HOST"
    -P "$PORT"
    -u "$USER_NAME"
    --single-transaction
    --quick
    --routines
    --events
    --triggers
    "${dump_scope_args[@]}"
  )
  if [[ -n "$PASSWORD" ]]; then
    cmd=(env "MYSQL_PWD=$PASSWORD" "${cmd[@]}")
  fi

  log "Backup target:"
  log "  Namespace : $NAMESPACE"
  log "  Pod       : $POD"
  log "  Container : ${CONTAINER:-<default>}"
  log "  Host      : $HOST"
  log "  Port      : $PORT"
  log "  Scope     : $scope"
  log "  User      : $USER_NAME"
  log "  Output    : $OUTPUT"
  log "  Compress  : $compress_effective"

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  tmp_output="${OUTPUT}.tmp.$$"
  trap 'rm -f "$tmp_output"' EXIT

  if [[ "$compress_effective" == "gzip" ]]; then
    exec_in_pod "${cmd[@]}" | gzip -c > "$tmp_output"
  else
    exec_in_pod "${cmd[@]}" > "$tmp_output"
  fi

  mv "$tmp_output" "$OUTPUT"
  trap - EXIT

  size="$(du -h "$OUTPUT" | awk '{print $1}')"
  log "Backup completed: $OUTPUT (${size})"
}

restore_action() {
  local cmd=() reply

  ensure_credentials
  resolve_database "false"

  if [[ -z "$DB" ]]; then
    die "Database name cannot be empty."
  fi

  if [[ -z "$FILE" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      die "--file is required for restore in non-interactive mode."
    fi
    read_tty "Backup file path (.sql/.sql.gz): " FILE
  fi

  [[ -f "$FILE" ]] || die "Backup file not found: $FILE"

  if [[ "$FILE" == *.gz ]]; then
    require_cmd gzip
  fi

  cmd=(mariadb -h "$HOST" -P "$PORT" -u "$USER_NAME" "$DB")
  if [[ -n "$PASSWORD" ]]; then
    cmd=(env "MYSQL_PWD=$PASSWORD" "${cmd[@]}")
  fi

  log "Restore target:"
  log "  Namespace : $NAMESPACE"
  log "  Pod       : $POD"
  log "  Container : ${CONTAINER:-<default>}"
  log "  Host      : $HOST"
  log "  Port      : $PORT"
  log "  Database  : $DB"
  log "  User      : $USER_NAME"
  log "  File      : $FILE"

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  ensure_database_exists_for_restore

  if [[ "$YES" != "true" && "$NON_INTERACTIVE" != "true" ]]; then
    read_tty "Proceed restore? (y/N): " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      die "Aborted by user."
    fi
  fi

  stream_restore_input "$FILE" | exec_in_pod "${cmd[@]}"
  log "Restore completed."
}

choose_mode
discover_mariadb_pods

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

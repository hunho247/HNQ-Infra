#!/usr/bin/env bash
set -euo pipefail

# =========================
# Server Audit + Report Gen
# Output: Markdown
# =========================

REPORT_DIR="${REPORT_DIR:-$PWD}"
DISK_TEST_DIR="${DISK_TEST_DIR:-/tmp}"
DISK_TEST_SIZE="${DISK_TEST_SIZE:-2G}"     # file size for fio tests
FIO_RUNTIME="${FIO_RUNTIME:-30}"           # seconds (per sample)
FIO_RAMP_TIME="${FIO_RAMP_TIME:-5}"        # seconds (fio warm period)
FIO_ENGINE="${FIO_ENGINE:-libaio}"
CPU_PRIME="${CPU_PRIME:-20000}"            # sysbench cpu prime
SYSBENCH_THREADS="${SYSBENCH_THREADS:-$(nproc 2>/dev/null || echo 1)}"
SYSBENCH_TIME="${SYSBENCH_TIME:-20}"       # seconds
BENCH_WARMUP="${BENCH_WARMUP:-1}"          # number of warm-up runs
BENCH_REPEATS="${BENCH_REPEATS:-3}"        # number of measured runs (median)
PING_COUNT="${PING_COUNT:-20}"             # ICMP packets for ping average
PING_TARGET="${PING_TARGET:-8.8.8.8}"
IPERF_TARGET="${IPERF_TARGET:-iperf.he.net}" # optional
SPEEDTEST_TIMEOUT="${SPEEDTEST_TIMEOUT:-15}" # seconds (for speedtest-cli/sivel)
CPU_MIN_EPS="${CPU_MIN_EPS:-0}"            # if >0 and CPU_EPS < threshold => WARN
RUN_SPEEDTEST="${RUN_SPEEDTEST:-1}"        # 1=run if available, 0=skip
RUN_IPERF="${RUN_IPERF:-1}"                # 1=run if available, 0=skip
RUN_FIO="${RUN_FIO:-1}"                    # 1=run if available, 0=skip
RUN_SYSBENCH="${RUN_SYSBENCH:-1}"          # 1=run if available, 0=skip
SHOW_PROGRESS="${SHOW_PROGRESS:-1}"        # 1=print progress to stderr

# Avoid interactive apt/needrestart hangs
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
export NEEDRESTART_MODE="${NEEDRESTART_MODE:-a}"

TS="$(date +'%Y%m%d_%H%M%S')"
HOST="$(hostname -f 2>/dev/null || hostname)"
MD="$REPORT_DIR/server_report_${HOST}_${TS}.md"
PROGRESS_STEP=0
PROGRESS_TOTAL=10

have() { command -v "$1" >/dev/null 2>&1; }

os_family() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "${ID_LIKE:-$ID}"
  else
    echo "unknown"
  fi
}

install_deps_debian() {
  local pkgs=("$@")
  sudo apt-get update -y >/dev/null
  sudo apt-get install -y "${pkgs[@]}" >/dev/null
}

install_deps_rhel() {
  local pkgs=("$@")
  if have dnf; then
    sudo dnf install -y "${pkgs[@]}" >/dev/null
  else
    sudo yum install -y "${pkgs[@]}" >/dev/null
  fi
}

ensure_tools() {
  local family
  family="$(os_family)"

  local need_pkgs=()
  have jq || need_pkgs+=("jq")
  have sysbench || need_pkgs+=("sysbench")
  have fio || need_pkgs+=("fio")
  have mtr || need_pkgs+=("mtr-tiny" "mtr")
  have iperf3 || need_pkgs+=("iperf3")

  if [ "${#need_pkgs[@]}" -gt 0 ]; then
    echo "==> Installing missing tools: ${need_pkgs[*]}" >&2
    if echo "$family" | grep -qiE "debian|ubuntu"; then
      install_deps_debian "${need_pkgs[@]}" || true
    elif echo "$family" | grep -qiE "rhel|fedora|centos|rocky|almalinux"; then
      install_deps_rhel "${need_pkgs[@]}" || true
    else
      echo "!! Unknown OS family. Please install manually: ${need_pkgs[*]}" >&2
    fi
  fi
}

sec_header() { echo -e "\n## $1\n"; }
kv() { printf -- "- **%s:** %s\n" "$1" "$2"; }

progress_step() {
  local msg="${1:-}"
  [ "$SHOW_PROGRESS" = "1" ] || return 0
  PROGRESS_STEP=$((PROGRESS_STEP + 1))
  printf '[%02d/%02d] %s\n' "$PROGRESS_STEP" "$PROGRESS_TOTAL" "$msg" >&2
}

progress_note() {
  local msg="${1:-}"
  [ "$SHOW_PROGRESS" = "1" ] || return 0
  printf '      %s\n' "$msg" >&2
}

run_cmd() {
  local title="$1"; shift
  progress_note "run: ${title}"
  echo -e "\n### ${title}\n"
  echo '```'
  ( "$@" ) 2>&1 || true
  echo '```'
}

# ---------- helpers to parse metrics ----------
trim() { awk '{$1=$1};1'; }
num_or_na() { [[ -n "${1:-}" ]] && echo "$1" || echo "N/A"; }
is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

to_pos_int() {
  local value="${1:-}" default="${2:-1}"
  if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]; then
    echo "$value"
  else
    echo "$default"
  fi
}

to_nonneg_int() {
  local value="${1:-}" default="${2:-0}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value"
  else
    echo "$default"
  fi
}

fmt0() { awk -v v="$1" 'BEGIN{printf "%.0f", v}'; }
fmt2() { awk -v v="$1" 'BEGIN{printf "%.2f", v}'; }

median_from_values() {
  local values=()
  local value
  for value in "$@"; do
    is_number "$value" && values+=("$value")
  done
  [ "${#values[@]}" -eq 0 ] && return 0

  mapfile -t values < <(printf '%s\n' "${values[@]}" | sort -n)
  local n="${#values[@]}"
  local mid=$((n / 2))
  if (( n % 2 == 1 )); then
    printf "%s" "${values[$mid]}"
  else
    awk -v a="${values[$((mid - 1))]}" -v b="${values[$mid]}" 'BEGIN{printf "%.4f", (a+b)/2}'
  fi
}

bytes_to_mibs() {
  awk -v b="$1" 'BEGIN{printf "%.1f", b/1048576}'
}

# fio output usually has: READ: bw=1234MiB/s ... iops=...
# We'll parse bw (MiB/s) and iops from the last matching READ/WRITE line.
parse_fio_bw_mibs() {
  # $1=READ|WRITE
  awk -v k="$1" '
    BEGIN{last=""}
    $0 ~ k":" && $0 ~ /bw=/ {
      if (match($0, /bw=([0-9.]+)(MiB\/s|MB\/s|KiB\/s|KB\/s|GiB\/s|GB\/s)/, a)) {
        val=a[1]; unit=a[2]
        # normalize to MiB/s-ish (approx)
        if (unit=="GiB/s" || unit=="GB/s") val=val*1024
        else if (unit=="KiB/s" || unit=="KB/s") val=val/1024
        last=val
      }
    }
    END{
      if (last!="") printf "%.1f", last
    }
  '
}

parse_fio_iops() {
  awk '
    BEGIN{last=""}
    /iops=/ {
      if (match($0, /iops=([0-9.]+)(k)?/, a)) {
        val=a[1]
        if (a[2]=="k") val=val*1000
        last=val
      }
    }
    END{
      if (last!="") printf "%.0f", last
    }
  '
}

parse_fio_json_metric() {
  # $1=read|write $2=bw_bytes|iops
  jq -r --arg op "$1" --arg key "$2" '
    [.jobs[][$op][$key] | numbers] | if length > 0 then add else empty end
  ' 2>/dev/null
}

parse_fio_json_p95_ms() {
  # $1=read|write
  jq -r --arg op "$1" '
    [.jobs[][$op].clat_ns.percentile["95.000000"] | numbers]
    | if length > 0 then ((add / length) / 1000000) else empty end
  ' 2>/dev/null
}

run_fio_json() {
  # $1=name $2=rw $3=bs $4=iodepth $5=numjobs
  fio --name="$1" --directory="$DISK_TEST_DIR" --filename=fio_testfile \
    --size="$DISK_TEST_SIZE" --rw="$2" --bs="$3" --ioengine="$FIO_ENGINE" \
    --iodepth="$4" --numjobs="$5" --runtime="$FIO_RUNTIME" --time_based \
    --ramp_time="$FIO_RAMP_TIME" --direct=1 --group_reporting \
    --lat_percentiles=1 --output-format=json 2>/dev/null || true
}

parse_ping_avg_ms() {
  # linux ping summary: rtt min/avg/max/mdev = 0.123/1.234/...
  awk -F'/' '/rtt|round-trip/ {print $5; exit}'
}

parse_sysbench_events_per_sec() {
  awk -F': ' '/events per second:/ {print $2; exit}' | trim
}

parse_sysbench_total_time_s() {
  awk -F': ' '/total time:/ {gsub(/[^0-9.]/, "", $2); print $2; exit}' | trim
}

# speedtest parsing helpers
parse_speedtest_dl() { awk -F': *' '/Download:/ {print $2; exit}' | trim; }
parse_speedtest_ul() { awk -F': *' '/Upload:/ {print $2; exit}' | trim; }
parse_speedtest_ping() { awk -F': *' '/Latency:|Ping:/ {print $2; exit}' | trim; }

parse_speedtest_json_dl_mbps() { jq -r '(.download | numbers) / 1000000' 2>/dev/null; }
parse_speedtest_json_ul_mbps() { jq -r '(.upload | numbers) / 1000000' 2>/dev/null; }
parse_speedtest_json_ping_ms() { jq -r '(.ping | numbers)' 2>/dev/null; }

detect_speedtest_mode() {
  local help_out
  if have speedtest; then
    help_out="$(speedtest --help 2>&1 || true)"
    if echo "$help_out" | grep -q -- '--accept-license'; then
      echo "ookla"
      return
    fi
    if echo "$help_out" | grep -q -- '--json'; then
      echo "sivel-speedtest"
      return
    fi
    echo "unknown-speedtest"
    return
  fi
  if have speedtest-cli; then
    echo "speedtest-cli"
    return
  fi
  echo "none"
}

collect_speedtest_metrics() {
  local mode="$1"
  local st_out="" dl="" ul="" lat="" dln="" uln="" latn=""
  SPEEDTEST_TOOL="$mode"

  case "$mode" in
    ookla)
      st_out="$(speedtest --accept-license --accept-gdpr --format=json 2>/dev/null || true)"
      if have jq && echo "$st_out" | jq -e . >/dev/null 2>&1; then
        dl="$(echo "$st_out" | jq -r '(.download.bandwidth | numbers) * 8 / 1000000' 2>/dev/null || true)"
        ul="$(echo "$st_out" | jq -r '(.upload.bandwidth | numbers) * 8 / 1000000' 2>/dev/null || true)"
        lat="$(echo "$st_out" | jq -r '.ping.latency // empty' 2>/dev/null || true)"
        is_number "$dl" && SPEED_DL="$(fmt2 "$dl") Mbps"
        is_number "$ul" && SPEED_UL="$(fmt2 "$ul") Mbps"
        is_number "$lat" && SPEED_LAT="$(fmt2 "$lat") ms"
      fi
      [ "$SPEED_DL" = "N/A" ] && st_out="$(speedtest --accept-license --accept-gdpr 2>/dev/null || true)"
      [ "$SPEED_DL" = "N/A" ] && dl="$(echo "$st_out" | parse_speedtest_dl)" && [ -n "$dl" ] && SPEED_DL="$dl"
      [ "$SPEED_UL" = "N/A" ] && ul="$(echo "$st_out" | parse_speedtest_ul)" && [ -n "$ul" ] && SPEED_UL="$ul"
      [ "$SPEED_LAT" = "N/A" ] && lat="$(echo "$st_out" | parse_speedtest_ping)" && [ -n "$lat" ] && SPEED_LAT="$lat"
      ;;
    sivel-speedtest)
      if have jq; then
        st_out="$(speedtest --json --timeout "$SPEEDTEST_TIMEOUT" 2>/dev/null || true)"
      else
        st_out=""
      fi
      if [ -n "$st_out" ] && have jq && echo "$st_out" | jq -e . >/dev/null 2>&1; then
        dln="$(echo "$st_out" | parse_speedtest_json_dl_mbps | trim)"
        uln="$(echo "$st_out" | parse_speedtest_json_ul_mbps | trim)"
        latn="$(echo "$st_out" | parse_speedtest_json_ping_ms | trim)"
        is_number "$dln" && SPEED_DL="$(fmt2 "$dln") Mbps"
        is_number "$uln" && SPEED_UL="$(fmt2 "$uln") Mbps"
        is_number "$latn" && SPEED_LAT="$(fmt2 "$latn") ms"
      else
        st_out="$(speedtest --simple --timeout "$SPEEDTEST_TIMEOUT" 2>/dev/null || speedtest --timeout "$SPEEDTEST_TIMEOUT" 2>/dev/null || true)"
        dl="$(echo "$st_out" | parse_speedtest_dl)"
        ul="$(echo "$st_out" | parse_speedtest_ul)"
        lat="$(echo "$st_out" | parse_speedtest_ping)"
        [ -n "$dl" ] && SPEED_DL="$dl"
        [ -n "$ul" ] && SPEED_UL="$ul"
        [ -n "$lat" ] && SPEED_LAT="$lat"
      fi
      ;;
    speedtest-cli)
      if have jq; then
        st_out="$(speedtest-cli --json --timeout "$SPEEDTEST_TIMEOUT" 2>/dev/null || true)"
      else
        st_out=""
      fi
      if [ -n "$st_out" ] && have jq && echo "$st_out" | jq -e . >/dev/null 2>&1; then
        dln="$(echo "$st_out" | parse_speedtest_json_dl_mbps | trim)"
        uln="$(echo "$st_out" | parse_speedtest_json_ul_mbps | trim)"
        latn="$(echo "$st_out" | parse_speedtest_json_ping_ms | trim)"
        is_number "$dln" && SPEED_DL="$(fmt2 "$dln") Mbps"
        is_number "$uln" && SPEED_UL="$(fmt2 "$uln") Mbps"
        is_number "$latn" && SPEED_LAT="$(fmt2 "$latn") ms"
      else
        st_out="$(speedtest-cli --simple --timeout "$SPEEDTEST_TIMEOUT" 2>/dev/null || speedtest-cli --timeout "$SPEEDTEST_TIMEOUT" 2>/dev/null || true)"
        dl="$(echo "$st_out" | parse_speedtest_dl)"
        ul="$(echo "$st_out" | parse_speedtest_ul)"
        lat="$(echo "$st_out" | parse_speedtest_ping)"
        [ -n "$dl" ] && SPEED_DL="$dl"
        [ -n "$ul" ] && SPEED_UL="$ul"
        [ -n "$lat" ] && SPEED_LAT="$lat"
      fi
      ;;
    *)
      SPEEDTEST_TOOL="not-found"
      ;;
  esac

  [ -z "${SPEED_DL:-}" ] && SPEED_DL="N/A"
  [ -z "${SPEED_UL:-}" ] && SPEED_UL="N/A"
  [ -z "${SPEED_LAT:-}" ] && SPEED_LAT="N/A"
  return 0
}

main() {
  progress_step "Checking tools"
  ensure_tools || true

  progress_step "Preparing benchmark config"
  BENCH_WARMUP="$(to_nonneg_int "$BENCH_WARMUP" 1)"
  BENCH_REPEATS="$(to_pos_int "$BENCH_REPEATS" 3)"
  PING_COUNT="$(to_pos_int "$PING_COUNT" 20)"
  FIO_RUNTIME="$(to_pos_int "$FIO_RUNTIME" 30)"
  FIO_RAMP_TIME="$(to_nonneg_int "$FIO_RAMP_TIME" 5)"
  SYSBENCH_THREADS="$(to_pos_int "$SYSBENCH_THREADS" 1)"
  SYSBENCH_TIME="$(to_pos_int "$SYSBENCH_TIME" 20)"
  SPEEDTEST_TIMEOUT="$(to_pos_int "$SPEEDTEST_TIMEOUT" 15)"

  # -------- Collect high-level metrics first (for summary) --------
  CPU_EPS="N/A"; CPU_TIME="N/A"
  MEM_SUMMARY="$(free -h 2>/dev/null | awk '/Mem:/ {print "total="$2", used="$3", free="$4", avail="$7}')"
  DISK_SEQ_W="N/A"; DISK_SEQ_R="N/A"; DISK_RAND_R_IOPS="N/A"; DISK_RAND_W_IOPS="N/A"
  DISK_RAND_R_P95="N/A"; DISK_RAND_W_P95="N/A"
  PING_AVG="N/A"
  SPEED_DL="N/A"; SPEED_UL="N/A"; SPEED_LAT="N/A"
  SPEEDTEST_TOOL="none"
  IPERF_BW="N/A"

  progress_step "Collecting CPU metric"
  if [ "$RUN_SYSBENCH" = "1" ] && have sysbench; then
    local sb_eps_samples=()
    local sb_time_samples=()
    local run SB_OUT SB_EPS SB_TIME SB_EPS_MEDIAN SB_TIME_MEDIAN

    for ((run=1; run<=BENCH_WARMUP; run++)); do
      progress_note "sysbench warmup ${run}/${BENCH_WARMUP}"
      sysbench cpu --threads="$SYSBENCH_THREADS" --time="$SYSBENCH_TIME" \
        --cpu-max-prime="$CPU_PRIME" run >/dev/null 2>&1 || true
    done

    for ((run=1; run<=BENCH_REPEATS; run++)); do
      progress_note "sysbench sample ${run}/${BENCH_REPEATS}"
      SB_OUT="$(sysbench cpu --threads="$SYSBENCH_THREADS" --time="$SYSBENCH_TIME" \
        --cpu-max-prime="$CPU_PRIME" run 2>/dev/null || true)"
      SB_EPS="$(echo "$SB_OUT" | parse_sysbench_events_per_sec | trim)"
      SB_TIME="$(echo "$SB_OUT" | parse_sysbench_total_time_s | trim)"
      is_number "$SB_EPS" && sb_eps_samples+=("$SB_EPS")
      is_number "$SB_TIME" && sb_time_samples+=("$SB_TIME")
    done

    SB_EPS_MEDIAN="$(median_from_values "${sb_eps_samples[@]}")"
    SB_TIME_MEDIAN="$(median_from_values "${sb_time_samples[@]}")"
    is_number "$SB_EPS_MEDIAN" && CPU_EPS="$(fmt2 "$SB_EPS_MEDIAN")"
    is_number "$SB_TIME_MEDIAN" && CPU_TIME="$(fmt2 "$SB_TIME_MEDIAN")s"
  else
    progress_note "skip CPU metric (sysbench missing/disabled)"
  fi

  progress_step "Collecting ping metric"
  PING_OUT="$(ping -c "$PING_COUNT" "${PING_TARGET}" 2>/dev/null || true)"
  PING_AVG="$(echo "$PING_OUT" | parse_ping_avg_ms | trim)"
  [ -z "$PING_AVG" ] && PING_AVG="N/A"

  # Disk metrics (fio) - safe temp file
  progress_step "Collecting disk metrics"
  if [ "$RUN_FIO" = "1" ] && have fio; then
    mkdir -p "$DISK_TEST_DIR" || true

    if have jq; then
      local run out value p95
      local seqw_bw_samples=() seqr_bw_samples=()
      local rr_iops_samples=() rw_iops_samples=()
      local rr_p95_samples=() rw_p95_samples=()
      local seqw_bw_median seqr_bw_median rr_iops_median rw_iops_median rr_p95_median rw_p95_median

      for ((run=1; run<=BENCH_WARMUP; run++)); do
        progress_note "fio seqwrite warmup ${run}/${BENCH_WARMUP}"
        run_fio_json seqwrite write 1M 16 1 >/dev/null
      done
      for ((run=1; run<=BENCH_REPEATS; run++)); do
        progress_note "fio seqwrite sample ${run}/${BENCH_REPEATS}"
        out="$(run_fio_json seqwrite write 1M 16 1)"
        value="$(echo "$out" | parse_fio_json_metric write bw_bytes | trim)"
        is_number "$value" && seqw_bw_samples+=("$value")
      done
      seqw_bw_median="$(median_from_values "${seqw_bw_samples[@]}")"
      is_number "$seqw_bw_median" && DISK_SEQ_W="$(bytes_to_mibs "$seqw_bw_median")"

      for ((run=1; run<=BENCH_WARMUP; run++)); do
        progress_note "fio seqread warmup ${run}/${BENCH_WARMUP}"
        run_fio_json seqread read 1M 16 1 >/dev/null
      done
      for ((run=1; run<=BENCH_REPEATS; run++)); do
        progress_note "fio seqread sample ${run}/${BENCH_REPEATS}"
        out="$(run_fio_json seqread read 1M 16 1)"
        value="$(echo "$out" | parse_fio_json_metric read bw_bytes | trim)"
        is_number "$value" && seqr_bw_samples+=("$value")
      done
      seqr_bw_median="$(median_from_values "${seqr_bw_samples[@]}")"
      is_number "$seqr_bw_median" && DISK_SEQ_R="$(bytes_to_mibs "$seqr_bw_median")"

      for ((run=1; run<=BENCH_WARMUP; run++)); do
        progress_note "fio randread warmup ${run}/${BENCH_WARMUP}"
        run_fio_json randread randread 4k 32 4 >/dev/null
      done
      for ((run=1; run<=BENCH_REPEATS; run++)); do
        progress_note "fio randread sample ${run}/${BENCH_REPEATS}"
        out="$(run_fio_json randread randread 4k 32 4)"
        value="$(echo "$out" | parse_fio_json_metric read iops | trim)"
        p95="$(echo "$out" | parse_fio_json_p95_ms read | trim)"
        is_number "$value" && rr_iops_samples+=("$value")
        is_number "$p95" && rr_p95_samples+=("$p95")
      done
      rr_iops_median="$(median_from_values "${rr_iops_samples[@]}")"
      rr_p95_median="$(median_from_values "${rr_p95_samples[@]}")"
      is_number "$rr_iops_median" && DISK_RAND_R_IOPS="$(fmt0 "$rr_iops_median")"
      is_number "$rr_p95_median" && DISK_RAND_R_P95="$(fmt2 "$rr_p95_median")"

      for ((run=1; run<=BENCH_WARMUP; run++)); do
        progress_note "fio randwrite warmup ${run}/${BENCH_WARMUP}"
        run_fio_json randwrite randwrite 4k 32 4 >/dev/null
      done
      for ((run=1; run<=BENCH_REPEATS; run++)); do
        progress_note "fio randwrite sample ${run}/${BENCH_REPEATS}"
        out="$(run_fio_json randwrite randwrite 4k 32 4)"
        value="$(echo "$out" | parse_fio_json_metric write iops | trim)"
        p95="$(echo "$out" | parse_fio_json_p95_ms write | trim)"
        is_number "$value" && rw_iops_samples+=("$value")
        is_number "$p95" && rw_p95_samples+=("$p95")
      done
      rw_iops_median="$(median_from_values "${rw_iops_samples[@]}")"
      rw_p95_median="$(median_from_values "${rw_p95_samples[@]}")"
      is_number "$rw_iops_median" && DISK_RAND_W_IOPS="$(fmt0 "$rw_iops_median")"
      is_number "$rw_p95_median" && DISK_RAND_W_P95="$(fmt2 "$rw_p95_median")"
    else
      # Fallback if jq is unavailable: keep single-run parsing from fio text output.
      FIO_SEQW="$(fio --name=seqwrite --directory="$DISK_TEST_DIR" --filename=fio_testfile \
        --size="$DISK_TEST_SIZE" --rw=write --bs=1M --ioengine="$FIO_ENGINE" --iodepth=16 --numjobs=1 \
        --runtime="$FIO_RUNTIME" --time_based --ramp_time="$FIO_RAMP_TIME" --direct=1 --group_reporting 2>/dev/null || true)"
      DISK_SEQ_W="$(echo "$FIO_SEQW" | parse_fio_bw_mibs WRITE | trim)"
      [ -z "$DISK_SEQ_W" ] && DISK_SEQ_W="N/A"

      FIO_SEQR="$(fio --name=seqread --directory="$DISK_TEST_DIR" --filename=fio_testfile \
        --size="$DISK_TEST_SIZE" --rw=read --bs=1M --ioengine="$FIO_ENGINE" --iodepth=16 --numjobs=1 \
        --runtime="$FIO_RUNTIME" --time_based --ramp_time="$FIO_RAMP_TIME" --direct=1 --group_reporting 2>/dev/null || true)"
      DISK_SEQ_R="$(echo "$FIO_SEQR" | parse_fio_bw_mibs READ | trim)"
      [ -z "$DISK_SEQ_R" ] && DISK_SEQ_R="N/A"

      FIO_RR="$(fio --name=randread --directory="$DISK_TEST_DIR" --filename=fio_testfile \
        --size="$DISK_TEST_SIZE" --rw=randread --bs=4k --ioengine="$FIO_ENGINE" --iodepth=32 --numjobs=4 \
        --runtime="$FIO_RUNTIME" --time_based --ramp_time="$FIO_RAMP_TIME" --direct=1 --group_reporting 2>/dev/null || true)"
      DISK_RAND_R_IOPS="$(echo "$FIO_RR" | parse_fio_iops | trim)"
      [ -z "$DISK_RAND_R_IOPS" ] && DISK_RAND_R_IOPS="N/A"

      FIO_RW="$(fio --name=randwrite --directory="$DISK_TEST_DIR" --filename=fio_testfile \
        --size="$DISK_TEST_SIZE" --rw=randwrite --bs=4k --ioengine="$FIO_ENGINE" --iodepth=32 --numjobs=4 \
        --runtime="$FIO_RUNTIME" --time_based --ramp_time="$FIO_RAMP_TIME" --direct=1 --group_reporting 2>/dev/null || true)"
      DISK_RAND_W_IOPS="$(echo "$FIO_RW" | parse_fio_iops | trim)"
      [ -z "$DISK_RAND_W_IOPS" ] && DISK_RAND_W_IOPS="N/A"
    fi

    rm -f "${DISK_TEST_DIR}/fio_testfile" || true
  else
    progress_note "skip disk metric (fio missing/disabled)"
  fi

  progress_step "Collecting speedtest metrics"
  if [ "$RUN_SPEEDTEST" = "1" ]; then
    SPEEDTEST_TOOL="$(detect_speedtest_mode)"
    progress_note "speedtest tool: ${SPEEDTEST_TOOL}"
    collect_speedtest_metrics "$SPEEDTEST_TOOL"
  else
    progress_note "skip speedtest metric (disabled)"
  fi

  progress_step "Collecting iperf metrics"
  if [ "$RUN_IPERF" = "1" ] && have iperf3; then
    IP_OUT="$(iperf3 -c "$IPERF_TARGET" -t 15 2>/dev/null || true)"

    IPERF_BW="$(echo "$IP_OUT" | awk '
      /receiver/ && NF>=2 {
        for (i=1;i<=NF;i++) {
          if ($i ~ /Mbits\/sec|Gbits\/sec|Kbits\/sec/) {
            print $(i-1), $i
            exit
          }
        }
      }')"

    [ -z "$IPERF_BW" ] && IPERF_BW="N/A"
  else
    progress_note "skip iperf metric (iperf3 missing/disabled)"
  fi

  progress_step "Scoring metrics"
  # -------- quick scoring (simple thresholds) --------
  # You can tune these thresholds to your expectation / PVS plan.
  NET_SCORE="OK"
  DISK_SCORE="OK"
  CPU_SCORE="OK"

  # ping avg warn if > 50ms (adjust)
  if [[ "$PING_AVG" != "N/A" ]]; then
    awk "BEGIN{exit !($PING_AVG > 50)}" && NET_SCORE="WARN" || true
  fi

  # disk warn if seq read < 200 MiB/s OR rand read iops < 5000 (adjust)
  if [[ "$DISK_SEQ_R" != "N/A" ]]; then
    awk "BEGIN{exit !($DISK_SEQ_R < 200)}" && DISK_SCORE="WARN" || true
  fi
  if [[ "$DISK_RAND_R_IOPS" != "N/A" ]]; then
    awk "BEGIN{exit !($DISK_RAND_R_IOPS < 5000)}" && DISK_SCORE="WARN" || true
  fi

  # cpu warn if CPU_MIN_EPS is set and measured EPS is below threshold.
  if is_number "$CPU_MIN_EPS" && awk "BEGIN{exit !($CPU_MIN_EPS > 0)}"; then
    if [[ "$CPU_EPS" != "N/A" ]]; then
      awk "BEGIN{exit !($CPU_EPS < $CPU_MIN_EPS)}" && CPU_SCORE="WARN" || true
    fi
  fi

  progress_step "Writing markdown report"
  # -------- Write report --------
  {
    echo "# Server Health & Performance Report"
    kv "Host" "$HOST"
    kv "Generated" "$(date -Is)"
    kv "Kernel" "$(uname -r)"
    kv "Uptime" "$(uptime -p 2>/dev/null || uptime)"
    echo "---"

    sec_header "Tổng quan (ngắn gọn)"
    kv "Methodology" "warmup=${BENCH_WARMUP}, repeats=${BENCH_REPEATS} (median), sysbench threads=${SYSBENCH_THREADS}, fio ramp=${FIO_RAMP_TIME}s, ping count=${PING_COUNT}"
    kv "CPU (sysbench median)" "events/sec=$(num_or_na "$CPU_EPS"), total time=$(num_or_na "$CPU_TIME")  → **${CPU_SCORE}**"
    kv "RAM" "${MEM_SUMMARY:-N/A}"
    kv "Disk (fio median)" "seq write=$(num_or_na "$DISK_SEQ_W") MiB/s, seq read=$(num_or_na "$DISK_SEQ_R") MiB/s, rand read=$(num_or_na "$DISK_RAND_R_IOPS") IOPS (p95=$(num_or_na "$DISK_RAND_R_P95") ms), rand write=$(num_or_na "$DISK_RAND_W_IOPS") IOPS (p95=$(num_or_na "$DISK_RAND_W_P95") ms)  → **${DISK_SCORE}**"
    kv "Ping avg" "$(num_or_na "$PING_AVG") ms (count=${PING_COUNT})  → **${NET_SCORE}**"
    kv "Speedtest tool" "$SPEEDTEST_TOOL"
    kv "Speedtest" "download=$(num_or_na "$SPEED_DL"), upload=$(num_or_na "$SPEED_UL"), latency=$(num_or_na "$SPEED_LAT")"
    kv "iperf3" "$(num_or_na "$IPERF_BW")"
    echo ""
    echo "- **Gợi ý đọc nhanh:**"
    echo "  - Disk **WARN** → ưu tiên kiểm tra loại disk (SSD/NVMe), noisy neighbor, hoặc test ngay trên mount thật (vd: /data)."
    echo "  - Net **WARN** → kiểm tra route, bandwidth cap, hoặc test iperf tới endpoint gần khu vực."
    echo "  - CPU **WARN** → có thể oversubscribe / throttling; kiểm tra load và steal time."
    echo "---"

    sec_header "System Info"
    run_cmd "OS Release" bash -lc 'cat /etc/os-release 2>/dev/null || true'
    run_cmd "CPU (lscpu)" bash -lc 'lscpu || true'
    run_cmd "Memory (free -h)" bash -lc 'free -h || true'
    run_cmd "Disk (df -hT)" bash -lc 'df -hT || true'
    run_cmd "Block devices (lsblk)" bash -lc 'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL || true'
    run_cmd "Top processes (cpu/mem)" bash -lc 'ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 15; echo; ps -eo pid,comm,%cpu,%mem --sort=-%mem | head -n 15'

    sec_header "CPU Benchmark"
    if [ "$RUN_SYSBENCH" = "1" ] && have sysbench; then
      kv "CPU config" "threads=${SYSBENCH_THREADS}, time=${SYSBENCH_TIME}s, cpu-max-prime=${CPU_PRIME}, warmup=${BENCH_WARMUP}, repeats=${BENCH_REPEATS}"
      run_cmd "sysbench cpu (single raw run for reference)" bash -lc "sysbench cpu --threads=${SYSBENCH_THREADS} --time=${SYSBENCH_TIME} --cpu-max-prime=${CPU_PRIME} run"
    else
      echo "- **sysbench:** not run (missing or disabled)"
    fi

    sec_header "Memory Quick Test"
    run_cmd "Memory copy/checksum (256MB)" bash -lc 'dd if=/dev/zero bs=1M count=256 2>/dev/null | md5sum || true'

    sec_header "Disk Benchmark (fio - safe temp file)"
    kv "Disk test dir" "$DISK_TEST_DIR"
    kv "Disk test size" "$DISK_TEST_SIZE"
    kv "fio engine" "$FIO_ENGINE"
    kv "fio runtime" "${FIO_RUNTIME}s"
    kv "fio ramp time" "${FIO_RAMP_TIME}s"
    kv "fio samples" "warmup=${BENCH_WARMUP}, repeats=${BENCH_REPEATS} (median)"
    if [ "$RUN_FIO" = "1" ] && have fio; then
      run_cmd "fio: seq write (1M block, single raw run)" bash -lc "fio --name=seqwrite --directory='${DISK_TEST_DIR}' --filename=fio_testfile --size='${DISK_TEST_SIZE}' --rw=write --bs=1M --ioengine='${FIO_ENGINE}' --iodepth=16 --numjobs=1 --runtime=${FIO_RUNTIME} --time_based --ramp_time=${FIO_RAMP_TIME} --direct=1 --group_reporting"
      run_cmd "fio: seq read (1M block, single raw run)" bash -lc "fio --name=seqread  --directory='${DISK_TEST_DIR}' --filename=fio_testfile --size='${DISK_TEST_SIZE}' --rw=read  --bs=1M --ioengine='${FIO_ENGINE}' --iodepth=16 --numjobs=1 --runtime=${FIO_RUNTIME} --time_based --ramp_time=${FIO_RAMP_TIME} --direct=1 --group_reporting"
      run_cmd "fio: rand read (4k block, 4 jobs, single raw run)" bash -lc "fio --name=randread --directory='${DISK_TEST_DIR}' --filename=fio_testfile --size='${DISK_TEST_SIZE}' --rw=randread --bs=4k --ioengine='${FIO_ENGINE}' --iodepth=32 --numjobs=4 --runtime=${FIO_RUNTIME} --time_based --ramp_time=${FIO_RAMP_TIME} --direct=1 --group_reporting"
      run_cmd "fio: rand write (4k block, 4 jobs, single raw run)" bash -lc "fio --name=randwrite --directory='${DISK_TEST_DIR}' --filename=fio_testfile --size='${DISK_TEST_SIZE}' --rw=randwrite --bs=4k --ioengine='${FIO_ENGINE}' --iodepth=32 --numjobs=4 --runtime=${FIO_RUNTIME} --time_based --ramp_time=${FIO_RAMP_TIME} --direct=1 --group_reporting"
      run_cmd "Cleanup fio file" bash -lc "rm -f '${DISK_TEST_DIR}/fio_testfile' && echo 'Removed fio_testfile'"
    else
      echo "- **fio:** not run (missing or disabled)"
    fi

    sec_header "Network Benchmark"
    run_cmd "IP addresses" bash -lc "ip -br addr 2>/dev/null || ifconfig 2>/dev/null || true"
    run_cmd "Default route" bash -lc "ip route | head -n 20 || true"
    run_cmd "DNS resolvers" bash -lc "cat /etc/resolv.conf 2>/dev/null || true"
    run_cmd "Ping (${PING_TARGET})" bash -lc "ping -c ${PING_COUNT} '${PING_TARGET}' || true"

    if [ "$RUN_IPERF" = "1" ] && have iperf3; then
      run_cmd "iperf3 -> ${IPERF_TARGET}" bash -lc "iperf3 -c '${IPERF_TARGET}' -t 15 || true"
    else
      echo "- **iperf3:** not run (missing or disabled)"
    fi

    if [ "$RUN_SPEEDTEST" = "1" ]; then
      case "$SPEEDTEST_TOOL" in
        ookla)
          run_cmd "speedtest (Ookla CLI)" bash -lc "speedtest --accept-license --accept-gdpr || true"
          ;;
        sivel-speedtest)
          run_cmd "speedtest (sivel, json/simple)" bash -lc "speedtest --json --timeout ${SPEEDTEST_TIMEOUT} || speedtest --simple --timeout ${SPEEDTEST_TIMEOUT} || speedtest --timeout ${SPEEDTEST_TIMEOUT} || true"
          ;;
        speedtest-cli)
          run_cmd "speedtest-cli (json/simple)" bash -lc "speedtest-cli --json --timeout ${SPEEDTEST_TIMEOUT} || speedtest-cli --simple --timeout ${SPEEDTEST_TIMEOUT} || speedtest-cli --timeout ${SPEEDTEST_TIMEOUT} || true"
          ;;
        *)
          echo "- **speedtest:** not run (tool not found)."
          ;;
      esac
    else
      echo "- **speedtest:** skipped (disabled)"
    fi

    sec_header "Security & Limits (basic)"
    run_cmd "Open ports (ss -lntup)" bash -lc "ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null || true"
    run_cmd "Ulimits" bash -lc "ulimit -a || true"
    run_cmd "Kernel params (selected)" bash -lc "sysctl vm.swappiness fs.file-max net.core.somaxconn 2>/dev/null || true"
  } > "$MD"

  progress_step "Done"
  echo "✅ Report generated:"
  echo " - Markdown: $MD"
}

main "$@"

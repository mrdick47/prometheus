# Shared helpers for Prometheus start/stop scripts.
# Sourced by the .sh launchers; not meant to be executed directly.
# shellcheck shell=bash

# POSIX host.conf helpers (same directory as this file).
# shellcheck source=hostconf.sh
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/hostconf.sh"

prometheus_script_dir() {
  local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  if [[ "${src}" != /* ]]; then
    src="${PWD}/${src}"
  fi
  (cd -- "$(dirname -- "${src}")" && pwd)
}

# Drive root: directory that contains config/ and scripts/.
# PROMETHEUS_ROOT (if set) wins, so tests can use a temp tree.
prometheus_detect_root() {
  if [[ -n "${PROMETHEUS_ROOT:-}" ]]; then
    (cd -- "${PROMETHEUS_ROOT}" && pwd)
    return
  fi
  local here root
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  root="$(cd -- "${here}/../.." && pwd)"
  printf '%s\n' "${root}"
}

prometheus_log() {
  local level=$1
  shift
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  local line="[${ts}] [${level}] $*"
  printf '%s\n' "${line}" >&2
  if [[ -n "${PROMETHEUS_LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname -- "${PROMETHEUS_LOG_FILE}")"
    printf '%s\n' "${line}" >>"${PROMETHEUS_LOG_FILE}"
  fi
}

prometheus_die() {
  prometheus_log ERROR "$*"
  exit 1
}

# Load KEY=VALUE from config, then let the environment override.
prometheus_load_config() {
  local conf="${PROMETHEUS_ROOT}/config/prometheus.conf"
  if [[ ! -f "${conf}" ]]; then
    prometheus_die "config not found: ${conf}"
  fi
  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    case "${line}" in
      ""|\#*) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"
    if [[ -z "${key}" || "${key}" == "${line}" ]]; then
      continue
    fi
    # Only set when the environment has not already provided a value.
    if ! declare -p "${key}" >/dev/null 2>&1; then
      printf -v "${key}" '%s' "${value}"
    fi
  done <"${conf}"
}

prometheus_apply_defaults() {
  PROMETHEUS_BIND="${PROMETHEUS_BIND:-0.0.0.0}"
  KIWIX_PORT="${KIWIX_PORT:-8080}"
  KIWIX_HEALTH_PATH="${KIWIX_HEALTH_PATH:-/}"
  LLAMAFILE_PORT="${LLAMAFILE_PORT:-8081}"
  LLAMAFILE_HEALTH_PATH="${LLAMAFILE_HEALTH_PATH:-/v1/models}"
  LLAMAFILE_ARGS="${LLAMAFILE_ARGS:---server --nobrowser}"
  RAG_PORT="${RAG_PORT:-8082}"
  RAG_HEALTH_PATH="${RAG_HEALTH_PATH:-/}"
  RAG_SERVER="${RAG_SERVER:-}"
  HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-45}"
  HEALTH_POLL_SEC="${HEALTH_POLL_SEC:-0.5}"
  LIBRARY_DIR="${LIBRARY_DIR:-library}"
  APPS_DIR="${APPS_DIR:-apps}"
  MODELS_DIR="${MODELS_DIR:-models}"
  INDEX_DIR="${INDEX_DIR:-index}"
  RUN_DIR="${RUN_DIR:-run}"
  LOG_DIR="${LOG_DIR:-run/logs}"
  KIWIX_SERVE="${KIWIX_SERVE:-}"
  LLAMAFILE="${LLAMAFILE:-}"
  HIGH_MIN_RAM_GB="${HIGH_MIN_RAM_GB:-32}"
  HIGH_REQUIRES_DISCRETE_GPU="${HIGH_REQUIRES_DISCRETE_GPU:-1}"
  MID_MIN_RAM_GB="${MID_MIN_RAM_GB:-16}"
  MID_GPU_MIN_RAM_GB="${MID_GPU_MIN_RAM_GB:-8}"
  LOW_MIN_RAM_GB="${LOW_MIN_RAM_GB:-8}"
}

prometheus_abs() {
  local p=$1
  if [[ -z "${p}" ]]; then
    printf '%s\n' ""
    return
  fi
  if [[ "${p}" = /* ]]; then
    printf '%s\n' "${p}"
  else
    printf '%s\n' "${PROMETHEUS_ROOT}/${p}"
  fi
}

prometheus_prepare_runtime() {
  LIBRARY_DIR="$(prometheus_abs "${LIBRARY_DIR}")"
  APPS_DIR="$(prometheus_abs "${APPS_DIR}")"
  MODELS_DIR="$(prometheus_abs "${MODELS_DIR}")"
  INDEX_DIR="$(prometheus_abs "${INDEX_DIR}")"
  RUN_DIR="$(prometheus_abs "${RUN_DIR}")"
  LOG_DIR="$(prometheus_abs "${LOG_DIR}")"
  mkdir -p "${RUN_DIR}" "${LOG_DIR}"
  KIWIX_PID_FILE="${RUN_DIR}/kiwix-serve.pid"
  LLAMAFILE_PID_FILE="${RUN_DIR}/llamafile.pid"
  RAG_PID_FILE="${RUN_DIR}/rag.pid"
  PROMETHEUS_LOG_FILE="${LOG_DIR}/prometheus.log"
}

prometheus_os_arch() {
  local uname_s uname_m os arch
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"
  case "${uname_s}" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) os=linux ;;
  esac
  case "${uname_m}" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) arch="${uname_m}" ;;
  esac
  printf '%s-%s\n' "${os}" "${arch}"
}

prometheus_find_exe() {
  # Usage: prometheus_find_exe VARNAME name name.exe ...
  local dest=$1
  shift
  local name cand
  for name in "$@"; do
    for cand in \
      "${APPS_DIR}/${name}" \
      "${APPS_DIR}/$(prometheus_os_arch)/${name}" \
      "${APPS_DIR}/macos/${name}" \
      "${APPS_DIR}/linux/${name}" \
      "${APPS_DIR}/windows/${name}"
    do
      if [[ -e "${cand}" ]]; then
        printf -v "${dest}" '%s' "${cand}"
        return 0
      fi
    done
  done
  return 1
}

prometheus_resolve_kiwix() {
  if [[ -n "${KIWIX_SERVE}" ]]; then
    KIWIX_SERVE="$(prometheus_abs "${KIWIX_SERVE}")"
    if [[ ! -e "${KIWIX_SERVE}" ]]; then
      prometheus_die "KIWIX_SERVE not found: ${KIWIX_SERVE}"
    fi
    return
  fi
  if prometheus_find_exe KIWIX_SERVE kiwix-serve kiwix-serve.exe; then
    return
  fi
  prometheus_die "kiwix-serve not found under ${APPS_DIR} (set KIWIX_SERVE in config or the environment)"
}

prometheus_resolve_llamafile_runtime() {
  if [[ -n "${LLAMAFILE}" ]]; then
    LLAMAFILE="$(prometheus_abs "${LLAMAFILE}")"
    if [[ ! -e "${LLAMAFILE}" ]]; then
      return 1
    fi
    return 0
  fi
  prometheus_find_exe LLAMAFILE llamafile llamafile.exe
}

# List ZIM files into the KIWIX_ZIMS array.
prometheus_list_zims() {
  KIWIX_ZIMS=()
  local f
  if [[ -d "${LIBRARY_DIR}" ]]; then
    while IFS= read -r -d '' f; do
      KIWIX_ZIMS+=("${f}")
    done < <(find "${LIBRARY_DIR}" -maxdepth 1 -type f \( -name '*.zim' -o -name '*.ZIM' \) -print0)
  fi
}

prometheus_url() {
  local port=$1
  local path=$2
  if [[ "${path}" != /* ]]; then
    path="/${path}"
  fi
  printf 'http://127.0.0.1:%s%s\n' "${port}" "${path}"
}

# HTTP GET; success means status 2xx or 3xx.
prometheus_http_ok() {
  local url=$1
  local timeout=${2:-5}
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -m "${timeout}" -o /dev/null "${url}" 2>/dev/null
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -T "${timeout}" -O /dev/null "${url}" 2>/dev/null
    return
  fi
  python3 - "${url}" "${timeout}" <<'PY'
import sys, urllib.request
url, timeout = sys.argv[1], float(sys.argv[2])
try:
    with urllib.request.urlopen(url, timeout=timeout) as r:
        sys.exit(0 if getattr(r, "status", 200) < 400 else 1)
except Exception:
    sys.exit(1)
PY
}

prometheus_wait_healthy() {
  local name=$1
  local port=$2
  local path=$3
  local timeout=$4
  local url
  url="$(prometheus_url "${port}" "${path}")"
  local start now
  start="$(date +%s)"
  while true; do
    if prometheus_http_ok "${url}" 3; then
      prometheus_log INFO "${name} is healthy at ${url}"
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      prometheus_log ERROR "${name} did not become healthy at ${url} within ${timeout}s"
      return 1
    fi
    # HEALTH_POLL_SEC may be fractional; sleep accepts that on bash/coreutils and macOS.
    sleep "${HEALTH_POLL_SEC}"
  done
}

prometheus_pid_running() {
  local pid=$1
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

prometheus_read_pid() {
  local file=$1
  if [[ ! -f "${file}" ]]; then
    return 1
  fi
  local pid
  pid="$(tr -d '[:space:]' <"${file}")"
  if [[ -z "${pid}" ]]; then
    return 1
  fi
  printf '%s\n' "${pid}"
}

prometheus_is_alive() {
  local pid_file=$1
  local port=$2
  local path=$3
  local pid
  if pid="$(prometheus_read_pid "${pid_file}")"; then
    if prometheus_pid_running "${pid}"; then
      return 0
    fi
  fi
  prometheus_http_ok "$(prometheus_url "${port}" "${path}")" 2
}

# Start a command in the background, record its PID, and do not use a
# shell pipeline so the PID is the real process.
prometheus_priority_prefix() {
  PROMETHEUS_PRIORITY_PREFIX=()
  if command -v nice >/dev/null 2>&1 && [[ -n "${HOST_NICE:-}" ]]; then
    PROMETHEUS_PRIORITY_PREFIX+=(nice -n "${HOST_NICE}")
  fi
  if command -v ionice >/dev/null 2>&1 && [[ -n "${HOST_IONICE_CLASS:-}" ]]; then
    if [[ "${HOST_IONICE_CLASS}" != "3" && -n "${HOST_IONICE_CLASSDATA:-}" ]]; then
      PROMETHEUS_PRIORITY_PREFIX+=(ionice -c "${HOST_IONICE_CLASS}" -n "${HOST_IONICE_CLASSDATA}")
    else
      PROMETHEUS_PRIORITY_PREFIX+=(ionice -c "${HOST_IONICE_CLASS}")
    fi
  fi
}

prometheus_spawn() {
  local pid_file=$1
  local log_file=$2
  shift 2
  # Make the binary executable if we own it (llamafile downloads often
  # need this once; ignore failure on noexec or foreign bits).
  if [[ -f "$1" && ! -x "$1" ]]; then
    chmod +x "$1" 2>/dev/null || true
  fi
  if [[ "${PROMETHEUS_SPAWN_NICE:-0}" = "1" ]]; then
    prometheus_priority_prefix
    nohup "${PROMETHEUS_PRIORITY_PREFIX[@]}" "$@" >>"${log_file}" 2>&1 &
  else
    nohup "$@" >>"${log_file}" 2>&1 &
  fi
  local pid=$!
  printf '%s\n' "${pid}" >"${pid_file}"
  printf '%s\n' "${pid}"
}

prometheus_start_library() {
  if prometheus_is_alive "${KIWIX_PID_FILE}" "${KIWIX_PORT}" "${KIWIX_HEALTH_PATH}"; then
    prometheus_log INFO "kiwix-serve is already running"
    return 0
  fi
  prometheus_resolve_kiwix
  prometheus_list_zims
  if [[ ${#KIWIX_ZIMS[@]} -eq 0 ]]; then
    prometheus_die "no .zim files in ${LIBRARY_DIR}; cannot start the library"
  fi
  local log="${LOG_DIR}/kiwix-serve.log"
  prometheus_log INFO "starting kiwix-serve on port ${KIWIX_PORT} with ${#KIWIX_ZIMS[@]} ZIM file(s)"
  prometheus_spawn "${KIWIX_PID_FILE}" "${log}" \
    "${KIWIX_SERVE}" --port "${KIWIX_PORT}" --address "${PROMETHEUS_BIND}" \
    "${KIWIX_ZIMS[@]}" >/dev/null
  if ! prometheus_wait_healthy "kiwix-serve" "${KIWIX_PORT}" "${KIWIX_HEALTH_PATH}" "${HEALTH_TIMEOUT_SEC}"; then
    prometheus_log ERROR "kiwix-serve failed to start; see ${log}"
    return 1
  fi
}

# RAM in whole GiB (1024^3). Returns 0 on failure after printing 0.
prometheus_ram_gb() {
  if [[ -n "${PROMETHEUS_RAM_GB:-}" ]]; then
    printf '%s\n' "${PROMETHEUS_RAM_GB}"
    return
  fi
  local bytes=0
  case "$(uname -s)" in
    Linux)
      local kb
      kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
      if [[ -n "${kb}" ]]; then
        bytes=$((kb * 1024))
      fi
      ;;
    Darwin)
      bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
      ;;
  esac
  if [[ -z "${bytes}" || "${bytes}" -le 0 ]]; then
    printf '0\n'
    return
  fi
  printf '%s\n' $((bytes / 1024 / 1024 / 1024))
}

# Sets PROMETHEUS_HAS_DISCRETE_GPU to 1 or 0, and PROMETHEUS_GPU_NOTE.
prometheus_detect_gpu() {
  if [[ -n "${PROMETHEUS_FORCE_GPU:-}" ]]; then
    PROMETHEUS_HAS_DISCRETE_GPU="${PROMETHEUS_FORCE_GPU}"
    PROMETHEUS_GPU_NOTE="forced (${PROMETHEUS_FORCE_GPU})"
    return
  fi
  PROMETHEUS_HAS_DISCRETE_GPU=0
  PROMETHEUS_GPU_NOTE="none detected"
  case "$(uname -s)" in
    Linux)
      if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        PROMETHEUS_HAS_DISCRETE_GPU=1
        PROMETHEUS_GPU_NOTE="NVIDIA (nvidia-smi)"
        return
      fi
      if command -v lspci >/dev/null 2>&1; then
        local pci
        pci="$(lspci 2>/dev/null | grep -Ei 'VGA|3D|Display' || true)"
        if printf '%s\n' "${pci}" | grep -Ei 'NVIDIA|AMD|ATI|Radeon' >/dev/null; then
          PROMETHEUS_HAS_DISCRETE_GPU=1
          PROMETHEUS_GPU_NOTE="$(printf '%s\n' "${pci}" | grep -Ei 'NVIDIA|AMD|ATI|Radeon' | head -n 1)"
          return
        fi
        if [[ -n "${pci}" ]]; then
          PROMETHEUS_GPU_NOTE="$(printf '%s\n' "${pci}" | head -n 1)"
        fi
      fi
      ;;
    Darwin)
      local sp
      sp="$(system_profiler SPDisplaysDataType 2>/dev/null || true)"
      if printf '%s\n' "${sp}" | grep -Ei 'Chipset Model:.*(Radeon|NVIDIA|GeForce|AMD)' >/dev/null; then
        PROMETHEUS_HAS_DISCRETE_GPU=1
        PROMETHEUS_GPU_NOTE="$(printf '%s\n' "${sp}" | grep -Ei 'Chipset Model:' | head -n 1 | sed 's/^ *//')"
        return
      fi
      # Apple Silicon has a capable integrated/unified GPU. Treat a
      # 32 GB+ Mac as high-eligible (unified memory) and smaller
      # Apple-Silicon Macs as mid-eligible when RAM also qualifies.
      if printf '%s\n' "${sp}" | grep -Ei 'Chipset Model:.*(Apple|M[0-9])' >/dev/null; then
        PROMETHEUS_HAS_DISCRETE_GPU=1
        PROMETHEUS_GPU_NOTE="Apple Silicon unified GPU"
        return
      fi
      if [[ -n "${sp}" ]]; then
        PROMETHEUS_GPU_NOTE="$(printf '%s\n' "${sp}" | grep -Ei 'Chipset Model:' | head -n 1 | sed 's/^ *//')"
      fi
      ;;
  esac
}

prometheus_select_tier() {
  local ram_gb gpu
  ram_gb="$(prometheus_ram_gb)"
  prometheus_detect_gpu
  gpu="${PROMETHEUS_HAS_DISCRETE_GPU}"
  prometheus_log INFO "hardware: RAM=${ram_gb} GiB, gpu=${PROMETHEUS_GPU_NOTE}"

  if [[ "${ram_gb}" -ge "${HIGH_MIN_RAM_GB}" ]]; then
    if [[ "${HIGH_REQUIRES_DISCRETE_GPU}" != "1" || "${gpu}" = "1" ]]; then
      printf 'high\n'
      return
    fi
  fi
  if [[ "${ram_gb}" -ge "${MID_MIN_RAM_GB}" ]]; then
    printf 'mid\n'
    return
  fi
  if [[ "${gpu}" = "1" && "${ram_gb}" -ge "${MID_GPU_MIN_RAM_GB}" ]]; then
    printf 'mid\n'
    return
  fi
  if [[ "${ram_gb}" -ge "${LOW_MIN_RAM_GB}" ]]; then
    printf 'low\n'
    return
  fi
  printf 'none\n'
}

# Find a model for a tier. Sets MODEL_BIN and MODEL_KIND (llamafile|gguf).
prometheus_find_model() {
  local tier=$1
  local dir="${MODELS_DIR}/${tier}"
  MODEL_BIN=""
  MODEL_KIND=""
  if [[ ! -d "${dir}" ]]; then
    return 1
  fi
  local f
  while IFS= read -r -d '' f; do
    MODEL_BIN="${f}"
    MODEL_KIND=llamafile
    return 0
  done < <(find "${dir}" -maxdepth 1 -type f \( -name '*.llamafile' -o -name '*.llamafile.exe' \) -print0)
  while IFS= read -r -d '' f; do
    MODEL_BIN="${f}"
    MODEL_KIND=gguf
    return 0
  done < <(find "${dir}" -maxdepth 1 -type f -name '*.gguf' -print0)
  return 1
}

# Walk preferred, then mid, then low (skipping already tried).
prometheus_resolve_tier_model() {
  local preferred=$1
  local candidate
  local tried=""
  for candidate in "${preferred}" mid low; do
    case " ${tried} " in
      *" ${candidate} "*) continue ;;
    esac
    tried="${tried} ${candidate}"
    if prometheus_find_model "${candidate}"; then
      SELECTED_TIER="${candidate}"
      return 0
    fi
  done
  SELECTED_TIER=""
  MODEL_BIN=""
  MODEL_KIND=""
  return 1
}

prometheus_library_healthy() {
  prometheus_http_ok "$(prometheus_url "${KIWIX_PORT}" "${KIWIX_HEALTH_PATH}")" 3
}

prometheus_start_llamafile() {
  local tier=$1
  if prometheus_is_alive "${LLAMAFILE_PID_FILE}" "${LLAMAFILE_PORT}" "${LLAMAFILE_HEALTH_PATH}"; then
    prometheus_log INFO "llamafile is already running"
    return 0
  fi
  if ! prometheus_resolve_tier_model "${tier}"; then
    prometheus_log ERROR "no llamafile or GGUF found for tier '${tier}' (looked in ${MODELS_DIR}/{${tier},mid,low})"
    return 1
  fi
  local cmd=()
  if [[ "${MODEL_KIND}" = "llamafile" ]]; then
    cmd=("${MODEL_BIN}")
  else
    if ! prometheus_resolve_llamafile_runtime; then
      prometheus_log ERROR "found ${MODEL_BIN} but no llamafile runtime in ${APPS_DIR}"
      return 1
    fi
    cmd=("${LLAMAFILE}" -m "${MODEL_BIN}")
  fi
  # shellcheck disable=SC2206
  local extra=( ${LLAMAFILE_ARGS} )
  local log="${LOG_DIR}/llamafile.log"
  prometheus_log INFO "starting llamafile tier=${SELECTED_TIER} kind=${MODEL_KIND} port=${LLAMAFILE_PORT} model=${MODEL_BIN}"
  PROMETHEUS_SPAWN_NICE=1 prometheus_spawn "${LLAMAFILE_PID_FILE}" "${log}" \
    "${cmd[@]}" "${extra[@]}" --host "${PROMETHEUS_BIND}" --port "${LLAMAFILE_PORT}" >/dev/null
  if ! prometheus_wait_healthy "llamafile" "${LLAMAFILE_PORT}" "${LLAMAFILE_HEALTH_PATH}" "${HEALTH_TIMEOUT_SEC}"; then
    prometheus_log ERROR "llamafile failed to start; see ${log}. The library is unaffected."
    return 1
  fi
}

prometheus_start_rag() {
  if [[ -z "${RAG_SERVER}" ]]; then
    prometheus_log INFO "RAG server not configured; skipping (library and llamafile stay up)"
    return 0
  fi
  if prometheus_is_alive "${RAG_PID_FILE}" "${RAG_PORT}" "${RAG_HEALTH_PATH}"; then
    prometheus_log INFO "RAG server is already running"
    return 0
  fi
  local rag
  rag="$(prometheus_abs "${RAG_SERVER}")"
  if [[ ! -e "${rag}" ]]; then
    prometheus_log ERROR "RAG_SERVER not found: ${rag}; leaving library and llamafile up"
    return 1
  fi
  local log="${LOG_DIR}/rag.log"
  prometheus_log INFO "starting RAG server on port ${RAG_PORT}"
  prometheus_spawn "${RAG_PID_FILE}" "${log}" \
    "${rag}" --port "${RAG_PORT}" --host "${PROMETHEUS_BIND}" >/dev/null
  if ! prometheus_wait_healthy "RAG" "${RAG_PORT}" "${RAG_HEALTH_PATH}" "${HEALTH_TIMEOUT_SEC}"; then
    prometheus_log ERROR "RAG server failed to start; see ${log}. The library and llamafile are unaffected."
    return 1
  fi
}

# Start AI only after the library is healthy. Never stops kiwix on failure.
# Returns 0 if AI is up (RAG may have been skipped or failed).
# Returns 2 if the library is not healthy (AI not attempted).
# Returns 1 if llamafile failed.
prometheus_start_ai() {
  local tier=$1
  if ! prometheus_library_healthy; then
    prometheus_log ERROR "library is not healthy at $(prometheus_url "${KIWIX_PORT}" "${KIWIX_HEALTH_PATH}"); start it first with start-library. AI was not started."
    return 2
  fi
  if ! prometheus_start_llamafile "${tier}"; then
    return 1
  fi
  # RAG is a further add-on. Its failure must not take llamafile or kiwix down.
  prometheus_start_rag || true
  return 0
}

prometheus_stop_pid() {
  local name=$1
  local pid_file=$2
  local pid
  if ! pid="$(prometheus_read_pid "${pid_file}")"; then
    prometheus_log INFO "${name}: no PID file; already stopped"
    rm -f "${pid_file}"
    return 0
  fi
  if ! prometheus_pid_running "${pid}"; then
    prometheus_log INFO "${name}: stale PID ${pid}; removing"
    rm -f "${pid_file}"
    return 0
  fi
  prometheus_log INFO "${name}: stopping PID ${pid}"
  kill "${pid}" 2>/dev/null || true
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    : "${attempt}"
    if ! prometheus_pid_running "${pid}"; then
      rm -f "${pid_file}"
      prometheus_log INFO "${name}: stopped"
      return 0
    fi
    sleep 0.2
  done
  prometheus_log INFO "${name}: still running, sending KILL"
  kill -9 "${pid}" 2>/dev/null || true
  sleep 0.2
  rm -f "${pid_file}"
  if prometheus_pid_running "${pid}"; then
    prometheus_log ERROR "${name}: PID ${pid} survived KILL"
    return 1
  fi
  prometheus_log INFO "${name}: stopped"
  return 0
}

# Idempotent: succeeds when nothing is running.
prometheus_stop_all() {
  local status=0
  prometheus_stop_pid "RAG" "${RAG_PID_FILE}" || status=1
  prometheus_stop_pid "llamafile" "${LLAMAFILE_PID_FILE}" || status=1
  prometheus_stop_pid "kiwix-serve" "${KIWIX_PID_FILE}" || status=1
  if prometheus_library_healthy; then
    prometheus_log ERROR "kiwix-serve still answers HTTP after stop (not started by these scripts, or PID file missing?)"
    status=1
  fi
  if [[ "${status}" -eq 0 ]]; then
    prometheus_log INFO "all Prometheus services are stopped"
  fi
  return "${status}"
}

prometheus_init() {
  PROMETHEUS_ROOT="$(prometheus_detect_root)"
  prometheus_load_config
  prometheus_apply_defaults
  prometheus_prepare_runtime
  hostconf_load
  prometheus_log INFO "drive root: ${PROMETHEUS_ROOT}"
  prometheus_log INFO "host: $(hostconf_hostname) (host.conf section ${HOSTCONF_SECTION})"
}

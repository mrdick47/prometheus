#!/usr/bin/env bash
# Dry-run the Phase 3 launchers against stub HTTP servers (no real
# kiwix-serve, llamafile, ZIMs, or models).
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${TEST_DIR}/.." && pwd)"
STUB_PY="${TEST_DIR}/stubs/fake-http-server.py"
PYTHON="${PYTHON:-python3}"

pass=0
fail=0
status=0
failures=()

log() { printf '%s\n' "$*"; }

assert_eq() {
  local label=$1 expected=$2 actual=$3
  if [[ "${expected}" == "${actual}" ]]; then
    log "  PASS  ${label} (got ${actual})"
    pass=$((pass + 1))
  else
    log "  FAIL  ${label} (expected ${expected}, got ${actual})"
    fail=$((fail + 1))
    failures+=("${label}")
  fi
}

http_ok() {
  local url=$1
  "${PYTHON}" - "${url}" <<'PY'
import sys, urllib.request
url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=3) as r:
        sys.exit(0 if getattr(r, "status", 200) < 400 else 1)
except Exception:
    sys.exit(1)
PY
}

# Unique ports per run so leftover listeners cannot collide.
PORT_BASE=$((18000 + ($$ % 1000)))
export KIWIX_PORT=$((PORT_BASE + 0))
export LLAMAFILE_PORT=$((PORT_BASE + 1))
export RAG_PORT=$((PORT_BASE + 2))
export HEALTH_TIMEOUT_SEC=8
export HEALTH_POLL_SEC=0.2
export PROMETHEUS_BIND=127.0.0.1

WORKDIR=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]]; then
    if [[ -x "${WORKDIR}/scripts/stop.sh" ]]; then
      PROMETHEUS_ROOT="${WORKDIR}" "${WORKDIR}/scripts/stop.sh" >/dev/null 2>&1 || true
    fi
    # Belt and suspenders: anything still holding our ports from this tree.
    if [[ -d "${WORKDIR}/run" ]]; then
      local pidfile pid
      for pidfile in "${WORKDIR}/run"/*.pid; do
        [[ -f "${pidfile}" ]] || continue
        pid="$(tr -d '[:space:]' <"${pidfile}" || true)"
        if [[ -n "${pid}" ]]; then
          kill "${pid}" 2>/dev/null || true
          kill -9 "${pid}" 2>/dev/null || true
        fi
      done
    fi
    rm -rf "${WORKDIR}"
  fi
}
trap cleanup EXIT

write_wrapper() {
  local dest=$1
  local role=$2
  local extra=${3:-}
  cat >"${dest}" <<WRAP
#!/usr/bin/env bash
export STUB_ROLE="${role}"
export STUB_EVENT_LOG="${WORKDIR}/events.log"
${extra}
exec "${PYTHON}" "${STUB_PY}" "\$@"
WRAP
  chmod +x "${dest}"
}

setup_tree() {
  local mode=${1:-full}
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/prometheus-dry-run.XXXXXX")"
  mkdir -p \
    "${WORKDIR}/apps" \
    "${WORKDIR}/library" \
    "${WORKDIR}/models/low" \
    "${WORKDIR}/models/mid" \
    "${WORKDIR}/models/high" \
    "${WORKDIR}/models/embed" \
    "${WORKDIR}/run/logs"
  cp -a "${REPO_ROOT}/scripts" "${WORKDIR}/scripts"
  cp -a "${REPO_ROOT}/config" "${WORKDIR}/config"
  : >"${WORKDIR}/events.log"
  export PROMETHEUS_ROOT="${WORKDIR}"

  write_wrapper "${WORKDIR}/apps/kiwix-serve" "kiwix"

  case "${mode}" in
    full)
      printf 'stub' >"${WORKDIR}/library/dummy.zim"
      write_wrapper "${WORKDIR}/models/low/stub.llamafile" "llamafile"
      ;;
    failing-ai)
      printf 'stub' >"${WORKDIR}/library/dummy.zim"
      write_wrapper "${WORKDIR}/models/low/stub.llamafile" "llamafile" "export STUB_FAIL=1"
      ;;
    hanging-ai)
      printf 'stub' >"${WORKDIR}/library/dummy.zim"
      write_wrapper "${WORKDIR}/models/low/stub.llamafile" "llamafile" "export STUB_HANG=1"
      ;;
    library-only)
      printf 'stub' >"${WORKDIR}/library/dummy.zim"
      ;;
    no-zim)
      write_wrapper "${WORKDIR}/models/low/stub.llamafile" "llamafile"
      ;;
    with-rag-fail)
      printf 'stub' >"${WORKDIR}/library/dummy.zim"
      write_wrapper "${WORKDIR}/models/low/stub.llamafile" "llamafile"
      write_wrapper "${WORKDIR}/apps/rag-server" "rag" "export STUB_FAIL=1"
      # RAG_SERVER is empty in the config file; set it via the environment.
      export RAG_SERVER="${WORKDIR}/apps/rag-server"
      ;;
    *)
      echo "unknown setup mode: ${mode}" >&2
      exit 2
      ;;
  esac
}

teardown_tree() {
  local root="${WORKDIR}"
  if [[ -n "${root}" && -d "${root}" ]]; then
    PROMETHEUS_ROOT="${root}" "${root}/scripts/stop.sh" >/dev/null 2>&1 || true
    local pidfile pid
    if [[ -d "${root}/run" ]]; then
      for pidfile in "${root}/run"/*.pid; do
        [[ -f "${pidfile}" ]] || continue
        pid="$(tr -d '[:space:]' <"${pidfile}" || true)"
        if [[ -n "${pid}" ]]; then
          kill "${pid}" 2>/dev/null || true
          kill -9 "${pid}" 2>/dev/null || true
        fi
      done
    fi
    rm -rf "${root}"
  fi
  WORKDIR=""
  unset RAG_SERVER
  unset PROMETHEUS_ROOT
}

run_script() {
  # usage: run_script DESTVAR script args...
  # Captures exit status into the named variable; does not trip set -e.
  local dest=$1
  shift
  local rc=0
  PROMETHEUS_ROOT="${WORKDIR}" "$@" && rc=0 || rc=$?
  printf -v "${dest}" '%s' "${rc}"
}

# --- tests ---

log "Using ports kiwix=${KIWIX_PORT} llamafile=${LLAMAFILE_PORT} rag=${RAG_PORT}"
log ""

log "1) stop.sh when nothing is running is idempotent"
setup_tree full
run_script status "${WORKDIR}/scripts/stop.sh"
assert_eq "stop exit code with nothing running" 0 "${status}"
assert_eq "library still down" 1 "$(http_ok "http://127.0.0.1:${KIWIX_PORT}/" && echo 0 || echo 1)"
teardown_tree

log "2) start-auto starts kiwix first, then the AI; both become healthy"
setup_tree full
export PROMETHEUS_RAM_GB=8
export PROMETHEUS_FORCE_GPU=0
run_script status "${WORKDIR}/scripts/start-auto.sh"
assert_eq "start-auto exit code (healthy AI)" 0 "${status}"
assert_eq "kiwix healthy after auto start" 0 "$(http_ok "http://127.0.0.1:${KIWIX_PORT}/" && echo 0 || echo 1)"
assert_eq "llamafile healthy after auto start" 0 "$(http_ok "http://127.0.0.1:${LLAMAFILE_PORT}/v1/models" && echo 0 || echo 1)"
# First 'listening' event must be kiwix.
first_listen="$(awk '/ listening / {print $2; exit}' "${WORKDIR}/events.log")"
assert_eq "first listener is kiwix" "kiwix" "${first_listen}"
# And llamafile listening must be recorded after kiwix.
order="$(awk '/ listening / {printf "%s ", $2}' "${WORKDIR}/events.log" | sed 's/ *$//')"
assert_eq "listen order" "kiwix llamafile" "${order}"
run_script status "${WORKDIR}/scripts/stop.sh"
assert_eq "stop after a full start" 0 "${status}"
assert_eq "kiwix down after stop" 1 "$(http_ok "http://127.0.0.1:${KIWIX_PORT}/" && echo 0 || echo 1)"
assert_eq "llamafile down after stop" 1 "$(http_ok "http://127.0.0.1:${LLAMAFILE_PORT}/v1/models" && echo 0 || echo 1)"
teardown_tree
unset PROMETHEUS_RAM_GB PROMETHEUS_FORCE_GPU

log "3) start-auto with a failing AI still leaves the library up and exits 0"
setup_tree failing-ai
export PROMETHEUS_RAM_GB=8
export PROMETHEUS_FORCE_GPU=0
run_script status "${WORKDIR}/scripts/start-auto.sh"
assert_eq "start-auto exit code when AI fails" 0 "${status}"
assert_eq "kiwix healthy after AI failure" 0 "$(http_ok "http://127.0.0.1:${KIWIX_PORT}/" && echo 0 || echo 1)"
assert_eq "llamafile down after AI failure" 1 "$(http_ok "http://127.0.0.1:${LLAMAFILE_PORT}/v1/models" && echo 0 || echo 1)"
run_script status "${WORKDIR}/scripts/stop.sh"
assert_eq "stop after AI failure" 0 "${status}"
teardown_tree
unset PROMETHEUS_RAM_GB PROMETHEUS_FORCE_GPU

log "4) start-auto with no model files stays library-only"
setup_tree library-only
export PROMETHEUS_RAM_GB=8
export PROMETHEUS_FORCE_GPU=0
run_script status "${WORKDIR}/scripts/start-auto.sh"
assert_eq "start-auto exit code with no models" 0 "${status}"
assert_eq "kiwix healthy with no models" 0 "$(http_ok "http://127.0.0.1:${KIWIX_PORT}/" && echo 0 || echo 1)"
assert_eq "llamafile down with no models" 1 "$(http_ok "http://127.0.0.1:${LLAMAFILE_PORT}/v1/models" && echo 0 || echo 1)"
run_script status "${WORKDIR}/scripts/stop.sh"
teardown_tree
unset PROMETHEUS_RAM_GB PROMETHEUS_FORCE_GPU

log "5) start-ai refuses to start when the library is down"
setup_tree full
run_script status "${WORKDIR}/scripts/start-ai.sh" mid
assert_eq "start-ai exit code without library" 2 "${status}"
assert_eq "llamafile not started without library" 1 "$(http_ok "http://127.0.0.1:${LLAMAFILE_PORT}/v1/models" && echo 0 || echo 1)"
assert_eq "kiwix still down" 1 "$(http_ok "http://127.0.0.1:${KIWIX_PORT}/" && echo 0 || echo 1)"
teardown_tree

log "6) manual start-library then start-ai, and a failing RAG does not take them down"
setup_tree with-rag-fail
run_script status "${WORKDIR}/scripts/start-library.sh"
assert_eq "start-library exit code" 0 "${status}"
assert_eq "kiwix healthy after library start" 0 "$(http_ok "http://127.0.0.1:${KIWIX_PORT}/" && echo 0 || echo 1)"
run_script status "${WORKDIR}/scripts/start-ai.sh" low
assert_eq "start-ai exit code despite RAG failure" 0 "${status}"
assert_eq "kiwix still healthy after RAG failure" 0 "$(http_ok "http://127.0.0.1:${KIWIX_PORT}/" && echo 0 || echo 1)"
assert_eq "llamafile healthy after RAG failure" 0 "$(http_ok "http://127.0.0.1:${LLAMAFILE_PORT}/v1/models" && echo 0 || echo 1)"
assert_eq "RAG down after failure" 1 "$(http_ok "http://127.0.0.1:${RAG_PORT}/" && echo 0 || echo 1)"
run_script status "${WORKDIR}/scripts/stop.sh"
assert_eq "final stop" 0 "${status}"
teardown_tree

log "7) stale PID files do not make stop fail"
setup_tree full
mkdir -p "${WORKDIR}/run"
echo "999999" >"${WORKDIR}/run/kiwix-serve.pid"
echo "999998" >"${WORKDIR}/run/llamafile.pid"
run_script status "${WORKDIR}/scripts/stop.sh"
assert_eq "stop with stale PIDs" 0 "${status}"
assert_eq "stale kiwix pid removed" 1 "$([[ -f ${WORKDIR}/run/kiwix-serve.pid ]] && echo 0 || echo 1)"
teardown_tree

log ""
log "Results: ${pass} passed, ${fail} failed"
if [[ "${fail}" -ne 0 ]]; then
  log "Failed checks:"
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
log "All dry-run checks passed."
exit 0

#!/usr/bin/env bash
# Policy, lock, and host.conf dry-run for scripts/update and start-auto.
# No ZIM/map/model downloads, no physical drive, no real crontab.
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
    log "  PASS  ${label}"
    pass=$((pass + 1))
  else
    log "  FAIL  ${label} (expected ${expected}, got ${actual})"
    fail=$((fail + 1))
    failures+=("${label}")
  fi
}
assert_contains() {
  local label=$1 needle=$2 haystack=$3
  if printf '%s\n' "${haystack}" | grep -F -q -- "${needle}"; then
    log "  PASS  ${label}"
    pass=$((pass + 1))
  else
    log "  FAIL  ${label} (missing: ${needle})"
    fail=$((fail + 1))
    failures+=("${label}")
  fi
}

WORKDIR=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]]; then
    if [[ -x "${WORKDIR}/scripts/stop.sh" ]]; then
      PROMETHEUS_ROOT="${WORKDIR}" "${WORKDIR}/scripts/stop.sh" >/dev/null 2>&1 || true
    fi
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
    # Unlock permissions we may have tightened, then delete.
    chmod -R u+w "${WORKDIR}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
  fi
}
trap cleanup EXIT

epoch_at() {
  # epoch_at YYYY-MM-DD HH:MM TZ
  "${PYTHON}" - "$1" "$2" "$3" <<'PY'
import sys
from datetime import datetime
from zoneinfo import ZoneInfo
d, t, tz = sys.argv[1], sys.argv[2], sys.argv[3]
dt = datetime.fromisoformat(f"{d}T{t}:00").replace(tzinfo=ZoneInfo(tz))
print(int(dt.timestamp()))
PY
}

setup_tree() {
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/prometheus-update-dry.XXXXXX")"
  mkdir -p "${WORKDIR}/apps" "${WORKDIR}/library" "${WORKDIR}/models/low" \
    "${WORKDIR}/run/logs"
  cp -a "${REPO_ROOT}/scripts" "${WORKDIR}/scripts"
  cp -a "${REPO_ROOT}/config" "${WORKDIR}/config"
  printf 'stub' >"${WORKDIR}/library/dummy.zim"
  cat >"${WORKDIR}/apps/kiwix-serve" <<WRAP
#!/usr/bin/env bash
export STUB_ROLE=kiwix
exec "${PYTHON}" "${STUB_PY}" "\$@"
WRAP
  chmod +x "${WORKDIR}/apps/kiwix-serve"
  cat >"${WORKDIR}/models/low/stub.llamafile" <<WRAP
#!/usr/bin/env bash
export STUB_ROLE=llamafile
exec "${PYTHON}" "${STUB_PY}" "\$@"
WRAP
  chmod +x "${WORKDIR}/models/low/stub.llamafile"
}

run_update() {
  local dest=$1
  shift
  local rc=0
  local out
  out="$(cd "${WORKDIR}" && "$@" 2>&1)" || rc=$?
  RUN_OUT=${out}
  printf -v "${dest}" '%s' "${rc}"
}

# Unique ports so leftover listeners cannot collide.
PORT_BASE=$((19000 + ($$ % 1000)))
export KIWIX_PORT=$((PORT_BASE + 0))
export LLAMAFILE_PORT=$((PORT_BASE + 1))
export HEALTH_TIMEOUT_SEC=8
export HEALTH_POLL_SEC=0.2
export PROMETHEUS_BIND=127.0.0.1

ZEUS_WEEKDAY=$(epoch_at 2026-11-18 14:00 America/Chicago)   # Wed afternoon CT
ZEUS_WEEKEND=$(epoch_at 2026-11-14 23:00 America/Chicago)   # Sat night CT
DEFAULT_NIGHT=$(epoch_at 2026-11-18 03:00 America/Chicago)  # Wed 03:00 CT

log "1) update --dry-run finds the drive root from its own location"
setup_tree
# Do not set PROMETHEUS_ROOT: the script must walk up from scripts/update.
run_update status "${WORKDIR}/scripts/update" --dry-run
assert_eq "dry-run exit" 0 "${status}"
assert_contains "root from script location" "drive root: ${WORKDIR}" "${RUN_OUT}"
assert_contains "mentions no catalog URLs" "no catalog sources are configured yet" "${RUN_OUT}"
chmod -R u+w "${WORKDIR}" 2>/dev/null || true
rm -rf "${WORKDIR}"; WORKDIR=""

log "2) ZEUS on a weekday afternoon is skipped; a default host at 03:00 is permitted"
setup_tree
run_update status env PROMETHEUS_HOSTNAME=ZEUS PROMETHEUS_NOW="${ZEUS_WEEKDAY}" \
  PROMETHEUS_TEMP_C=40 "${WORKDIR}/scripts/update" --dry-run
assert_eq "ZEUS weekday dry-run exit" 0 "${status}"
assert_contains "ZEUS weekday skipped" "skipped:" "${RUN_OUT}"
run_update status env PROMETHEUS_HOSTNAME=laptop PROMETHEUS_NOW="${DEFAULT_NIGHT}" \
  PROMETHEUS_TEMP_C=40 "${WORKDIR}/scripts/update" --dry-run
assert_eq "default nightly dry-run exit" 0 "${status}"
assert_contains "default nightly permitted" "permitted:" "${RUN_OUT}"
chmod -R u+w "${WORKDIR}" 2>/dev/null || true
rm -rf "${WORKDIR}"; WORKDIR=""

log "3) ZEUS Saturday 23:00 CT is in the weekend-night window"
setup_tree
run_update status env PROMETHEUS_HOSTNAME=ZEUS PROMETHEUS_NOW="${ZEUS_WEEKEND}" \
  PROMETHEUS_TEMP_C=40 "${WORKDIR}/scripts/update" --dry-run
assert_eq "ZEUS weekend dry-run exit" 0 "${status}"
assert_contains "ZEUS weekend permitted" "permitted:" "${RUN_OUT}"
assert_contains "ZEUS section used" "section ZEUS" "${RUN_OUT}"
chmod -R u+w "${WORKDIR}" 2>/dev/null || true
rm -rf "${WORKDIR}"; WORKDIR=""

log "4) heat pause at 80°C, including with --force; --ignore-temp overrides"
setup_tree
run_update status env PROMETHEUS_HOSTNAME=ZEUS PROMETHEUS_NOW="${ZEUS_WEEKEND}" \
  PROMETHEUS_TEMP_C=80 "${WORKDIR}/scripts/update" --dry-run
assert_contains "heat pause" "paused: CPU temperature 80C" "${RUN_OUT}"
run_update status env PROMETHEUS_HOSTNAME=ZEUS PROMETHEUS_NOW="${ZEUS_WEEKEND}" \
  PROMETHEUS_TEMP_C=80 "${WORKDIR}/scripts/update" --dry-run --force
assert_contains "force still honors heat" "paused: CPU temperature 80C" "${RUN_OUT}"
run_update status env PROMETHEUS_HOSTNAME=ZEUS PROMETHEUS_NOW="${ZEUS_WEEKEND}" \
  PROMETHEUS_TEMP_C=80 "${WORKDIR}/scripts/update" --dry-run --force --ignore-temp
assert_contains "ignore-temp permits" "permitted: --force" "${RUN_OUT}"
chmod -R u+w "${WORKDIR}" 2>/dev/null || true
rm -rf "${WORKDIR}"; WORKDIR=""

log "5) lock: a live foreign lock is left alone; a stale one is taken"
setup_tree
mkdir -p "${WORKDIR}/run/update.lock"
cat >"${WORKDIR}/run/update.lock/owner" <<OWN
hostname=other-box
pid=1
started=$(date +%s)
started_iso=now
OWN
date +%s >"${WORKDIR}/run/update.lock/heartbeat"
run_update status env PROMETHEUS_HOSTNAME=laptop PROMETHEUS_NOW="${DEFAULT_NIGHT}" \
  PROMETHEUS_TEMP_C=40 "${WORKDIR}/scripts/update" --force
assert_eq "foreign live lock exit" 0 "${status}"
assert_contains "foreign live lock skipped" "update already running on other-box" "${RUN_OUT}"
assert_eq "foreign live lock kept" 0 "$([[ -d ${WORKDIR}/run/update.lock ]] && echo 0 || echo 1)"

# Stale: other host, heartbeat 7 hours ago (limit 6h).
old=$(( $(date +%s) - 25200 ))
printf '%s\n' "${old}" >"${WORKDIR}/run/update.lock/heartbeat"
printf 'hostname=other-box\npid=1\nstarted=%s\n' "${old}" >"${WORKDIR}/run/update.lock/owner"
run_update status env PROMETHEUS_HOSTNAME=laptop PROMETHEUS_NOW="${DEFAULT_NIGHT}" \
  PROMETHEUS_TEMP_C=40 "${WORKDIR}/scripts/update" --force
assert_eq "stale foreign lock exit" 0 "${status}"
assert_contains "stale foreign lock removed" "removing stale lock from other-box" "${RUN_OUT}"
# The successful run should have released the lock on exit.
assert_eq "lock released after success" 1 "$([[ -d ${WORKDIR}/run/update.lock ]] && echo 0 || echo 1)"
chmod -R u+w "${WORKDIR}" 2>/dev/null || true
rm -rf "${WORKDIR}"; WORKDIR=""

log "6) stale lock on this host with a dead pid is taken"
setup_tree
mkdir -p "${WORKDIR}/run/update.lock"
printf 'hostname=laptop\npid=999999\nstarted=%s\n' "$(date +%s)" >"${WORKDIR}/run/update.lock/owner"
date +%s >"${WORKDIR}/run/update.lock/heartbeat"
run_update status env PROMETHEUS_HOSTNAME=laptop PROMETHEUS_NOW="${DEFAULT_NIGHT}" \
  PROMETHEUS_TEMP_C=40 "${WORKDIR}/scripts/update" --force
assert_eq "dead-pid lock exit" 0 "${status}"
assert_contains "dead-pid lock removed" "removing stale lock from this host (dead pid 999999)" "${RUN_OUT}"
chmod -R u+w "${WORKDIR}" 2>/dev/null || true
rm -rf "${WORKDIR}"; WORKDIR=""

log "7) read-only drive exits 0"
setup_tree
mkdir -p "${WORKDIR}/run"
chmod a-w "${WORKDIR}/run" "${WORKDIR}"
run_update status env PROMETHEUS_HOSTNAME=laptop PROMETHEUS_NOW="${DEFAULT_NIGHT}" \
  PROMETHEUS_TEMP_C=40 "${WORKDIR}/scripts/update" --force
assert_eq "read-only exit" 0 "${status}"
assert_contains "read-only message" "missing or read-only" "${RUN_OUT}"
chmod -R u+w "${WORKDIR}" 2>/dev/null || true
rm -rf "${WORKDIR}"; WORKDIR=""

log "8) temperature unavailable is skipped, not treated as a pause"
setup_tree
# Unset PROMETHEUS_TEMP_C; box may or may not have hwmon. We only assert
# that --dry-run does not crash and mentions either a reading or a skip.
run_update status env -u PROMETHEUS_TEMP_C PROMETHEUS_HOSTNAME=laptop \
  PROMETHEUS_NOW="${DEFAULT_NIGHT}" "${WORKDIR}/scripts/update" --dry-run
assert_eq "no-temp dry-run exit" 0 "${status}"
if printf '%s\n' "${RUN_OUT}" | grep -q 'temperature unavailable (check skipped)'; then
  assert_contains "graceful skip" "temperature unavailable (check skipped)" "${RUN_OUT}"
else
  assert_contains "or a real reading was used" "temperature" "${RUN_OUT}"
fi
chmod -R u+w "${WORKDIR}" 2>/dev/null || true
rm -rf "${WORKDIR}"; WORKDIR=""

log "9) start-auto honors library_only and skip_ai_when_hot"
setup_tree
# library_only on a custom host section.
printf '\n[testhost]\nlibrary_only=1\nskip_ai_when_hot=1\npause_temp_c=75\n' >>"${WORKDIR}/config/host.conf"
export PROMETHEUS_ROOT="${WORKDIR}"
export PROMETHEUS_HOSTNAME=testhost
export PROMETHEUS_RAM_GB=8
export PROMETHEUS_FORCE_GPU=0
rc=0
out="$( "${WORKDIR}/scripts/start-auto.sh" 2>&1 )" || rc=$?
assert_eq "library_only auto exit" 0 "${rc}"
assert_contains "library_only message" "library_only=1" "${out}"
# Library should still be up.
ok=1
"${PYTHON}" - "http://127.0.0.1:${KIWIX_PORT}/" <<'PY' && ok=0 || ok=1
import sys, urllib.request
try:
    urllib.request.urlopen(sys.argv[1], timeout=3)
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
assert_eq "library up under library_only" 0 "${ok}"
ai=1
"${PYTHON}" - "http://127.0.0.1:${LLAMAFILE_PORT}/v1/models" <<'PY' && ai=0 || ai=1
import sys, urllib.request
try:
    urllib.request.urlopen(sys.argv[1], timeout=3)
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
assert_eq "AI down under library_only" 1 "${ai}"
PROMETHEUS_ROOT="${WORKDIR}" "${WORKDIR}/scripts/stop.sh" >/dev/null 2>&1 || true

# Heat skip: same host but library_only off, temp 80.
sed -i 's/library_only=1/library_only=0/' "${WORKDIR}/config/host.conf"
export PROMETHEUS_TEMP_C=80
rc=0
out="$( "${WORKDIR}/scripts/start-auto.sh" 2>&1 )" || rc=$?
assert_eq "hot auto exit" 0 "${rc}"
assert_contains "hot skip AI" "skipping AI, library stays up" "${out}"
ok=1
"${PYTHON}" - "http://127.0.0.1:${KIWIX_PORT}/" <<'PY' && ok=0 || ok=1
import sys, urllib.request
try:
    urllib.request.urlopen(sys.argv[1], timeout=3)
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
assert_eq "library up when AI skipped for heat" 0 "${ok}"
PROMETHEUS_ROOT="${WORKDIR}" "${WORKDIR}/scripts/stop.sh" >/dev/null 2>&1 || true
unset PROMETHEUS_ROOT PROMETHEUS_HOSTNAME PROMETHEUS_RAM_GB PROMETHEUS_FORCE_GPU PROMETHEUS_TEMP_C
chmod -R u+w "${WORKDIR}" 2>/dev/null || true
rm -rf "${WORKDIR}"; WORKDIR=""

log "10) install-schedule --dry-run prints a ZEUS weekend plan and does not touch crontab"
setup_tree
before=$(crontab -l 2>/dev/null || true)
run_update status env PROMETHEUS_HOSTNAME=ZEUS PROMETHEUS_ROOT="${WORKDIR}" \
  "${WORKDIR}/scripts/install-schedule" --dry-run --cron --user ZEUS
assert_eq "install-schedule dry-run exit" 0 "${status}"
assert_contains "ZEUS plan mentions weekend hours" "22,23" "${RUN_OUT}"
after=$(crontab -l 2>/dev/null || true)
assert_eq "crontab unchanged" "${before}" "${after}"
chmod -R u+w "${WORKDIR}" 2>/dev/null || true
rm -rf "${WORKDIR}"; WORKDIR=""

log ""
log "Results: ${pass} passed, ${fail} failed"
if [[ "${fail}" -ne 0 ]]; then
  log "Failed checks:"
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
log "All update dry-run checks passed."
exit 0

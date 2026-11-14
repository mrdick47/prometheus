# POSIX helpers for scripts/update: root detection, logging, locks,
# volume lookup, nice/ionice, GPU hint, and atomic file swap.
# shellcheck shell=sh

update_detect_root() {
  if [ -n "${PROMETHEUS_ROOT:-}" ]; then
    (CDPATH='' cd -- "$PROMETHEUS_ROOT" && pwd)
    return
  fi
  _up_src=$1
  case "$_up_src" in
    /*) ;;
    *) _up_src=$(pwd)/$_up_src ;;
  esac
  _up_dir=$(CDPATH='' cd -- "$(dirname -- "$_up_src")" && pwd)
  # scripts/update -> drive root is parent of scripts/.
  (CDPATH='' cd -- "$_up_dir/.." && pwd)
}

update_log() {
  _up_level=$1
  shift
  _up_ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "")
  _up_line="[${_up_ts}] [${_up_level}] $*"
  printf '%s\n' "$_up_line"
  if [ -n "${UPDATE_LOG_FILE:-}" ]; then
    _up_ldir=$(dirname -- "$UPDATE_LOG_FILE")
    [ -d "$_up_ldir" ] || mkdir -p "$_up_ldir" 2>/dev/null || return 0
    printf '%s\n' "$_up_line" >>"$UPDATE_LOG_FILE" 2>/dev/null || true
  fi
}

# Locate a volume labeled PROMETHEUS. Prints the mount point or nothing.
# Used by the off-drive schedule wrapper when the recorded path is gone.
update_find_labeled_volume() {
  _up_label=${1:-PROMETHEUS}
  if [ -n "${PROMETHEUS_ROOT:-}" ] && [ -d "${PROMETHEUS_ROOT}/scripts" ]; then
    (CDPATH='' cd -- "$PROMETHEUS_ROOT" && pwd)
    return 0
  fi
  if [ -d "/Volumes/$_up_label/scripts" ]; then
    printf '%s\n' "/Volumes/$_up_label"
    return 0
  fi
  if [ -e "/dev/disk/by-label/$_up_label" ] && command -v findmnt >/dev/null 2>&1; then
    _up_mp=$(findmnt -n -o TARGET "/dev/disk/by-label/$_up_label" 2>/dev/null || true)
    if [ -n "$_up_mp" ] && [ -d "$_up_mp/scripts" ]; then
      printf '%s\n' "$_up_mp"
      return 0
    fi
  fi
  if command -v lsblk >/dev/null 2>&1; then
    _up_mp=$(lsblk -o LABEL,MOUNTPOINT -nr 2>/dev/null | awk -v l="$_up_label" '$1==l && $2!=""{print $2; exit}')
    if [ -n "$_up_mp" ] && [ -d "$_up_mp/scripts" ]; then
      printf '%s\n' "$_up_mp"
      return 0
    fi
  fi
  # Common automount locations.
  for _up_cand in \
      "/media/${USER:-user}/$_up_label" \
      "/run/media/${USER:-user}/$_up_label" \
      "/mnt/$_up_label" \
      "/media/$_up_label"
  do
    if [ -d "$_up_cand/scripts" ]; then
      printf '%s\n' "$_up_cand"
      return 0
    fi
  done
  return 1
}

update_is_writable_dir() {
  _up_d=$1
  [ -d "$_up_d" ] && [ -w "$_up_d" ]
}

# 0 if we can create files under the drive's run/ directory (or root).
update_drive_writable() {
  _up_root=$1
  if [ ! -d "$_up_root" ]; then
    return 1
  fi
  _up_try=$_up_root/run
  if [ -d "$_up_try" ]; then
    update_is_writable_dir "$_up_try"
    return $?
  fi
  if mkdir -p "$_up_try" 2>/dev/null && update_is_writable_dir "$_up_try"; then
    return 0
  fi
  update_is_writable_dir "$_up_root"
}

update_lock_dir() {
  printf '%s\n' "${PROMETHEUS_ROOT}/run/update.lock"
}

update_lock_write_owner() {
  _up_lock=$1
  _up_now=$(date +%s 2>/dev/null || printf '0')
  _up_iso=$(date -Iseconds 2>/dev/null || date 2>/dev/null || printf '%s' "$_up_now")
  cat >"$_up_lock/owner" <<OWN
hostname=$(hostconf_hostname)
pid=$$
started=$_up_now
started_iso=$_up_iso
OWN
  printf '%s\n' "$_up_now" >"$_up_lock/heartbeat"
}

update_lock_heartbeat() {
  _up_lock=$(update_lock_dir)
  [ -d "$_up_lock" ] || return 0
  date +%s >"$_up_lock/heartbeat" 2>/dev/null || true
}

update_lock_read_field() {
  _up_file=$1
  _up_field=$2
  [ -f "$_up_file" ] || return 1
  _up_line=$(grep "^${_up_field}=" "$_up_file" 2>/dev/null | tail -n 1) || return 1
  printf '%s\n' "${_up_line#*=}"
}

# Age of the lock in seconds, from heartbeat mtime or started epoch.
update_lock_age_sec() {
  _up_lock=$1
  _up_now=$(date +%s 2>/dev/null || printf '0')
  if [ -f "$_up_lock/heartbeat" ]; then
    _up_hb=$(cat "$_up_lock/heartbeat" 2>/dev/null || printf '0')
    if [ -n "$_up_hb" ] && [ "$_up_hb" -gt 0 ] 2>/dev/null; then
      printf '%s\n' $((_up_now - _up_hb))
      return 0
    fi
  fi
  _up_st=$(update_lock_read_field "$_up_lock/owner" started 2>/dev/null || printf '0')
  if [ -n "$_up_st" ] && [ "$_up_st" -gt 0 ] 2>/dev/null; then
    printf '%s\n' $((_up_now - _up_st))
    return 0
  fi
  # Unknown age: treat as fresh so we do not steal blindly.
  printf '0\n'
}

update_pid_running() {
  _up_pid=$1
  [ -n "$_up_pid" ] || return 1
  kill -0 "$_up_pid" 2>/dev/null
}

# Remove a lock we have decided is stale.
update_lock_force_remove() {
  _up_lock=$1
  rm -f "$_up_lock/owner" "$_up_lock/heartbeat" 2>/dev/null || true
  rmdir "$_up_lock" 2>/dev/null || rm -rf "$_up_lock" 2>/dev/null || true
}

# Acquire run/update.lock. 0 = acquired, 1 = held by someone else,
# 2 = drive missing or read-only (caller should exit cleanly).
update_lock_acquire() {
  _up_root=${PROMETHEUS_ROOT}
  _up_lock=$(update_lock_dir)
  if ! update_drive_writable "$_up_root"; then
    update_log INFO "drive is missing or read-only at ${_up_root}; nothing to do"
    return 2
  fi
  mkdir -p "$(dirname -- "$_up_lock")" 2>/dev/null || true
  _up_tries=0
  while [ "$_up_tries" -lt 2 ]; do
    _up_tries=$((_up_tries + 1))
    if mkdir "$_up_lock" 2>/dev/null; then
      update_lock_write_owner "$_up_lock"
      UPDATE_LOCK_HELD=1
      update_log INFO "acquired update lock on $(hostconf_hostname) pid $$"
      return 0
    fi
    # Lock exists: decide if it is stale.
    _up_host=$(update_lock_read_field "$_up_lock/owner" hostname 2>/dev/null || printf '')
    _up_pid=$(update_lock_read_field "$_up_lock/owner" pid 2>/dev/null || printf '')
    _up_age=$(update_lock_age_sec "$_up_lock")
    _up_stale=${HOST_LOCK_STALE_AFTER_SEC:-21600}
    _up_me=$(hostconf_hostname)
    if [ "$_up_host" = "$_up_me" ] && [ -n "$_up_pid" ] && ! update_pid_running "$_up_pid"; then
      update_log INFO "removing stale lock from this host (dead pid ${_up_pid})"
      update_lock_force_remove "$_up_lock"
      continue
    fi
    if [ "$_up_age" -ge "$_up_stale" ] 2>/dev/null; then
      update_log INFO "removing stale lock from ${_up_host:-unknown} (age ${_up_age}s, limit ${_up_stale}s)"
      update_lock_force_remove "$_up_lock"
      continue
    fi
    update_log INFO "update already running on ${_up_host:-unknown} pid ${_up_pid:-?} (age ${_up_age}s); exiting"
    return 1
  done
  update_log INFO "update already running; exiting"
  return 1
}

update_lock_release() {
  if [ "${UPDATE_LOCK_HELD:-0}" != "1" ]; then
    return 0
  fi
  _up_lock=$(update_lock_dir)
  _up_pid=$(update_lock_read_field "$_up_lock/owner" pid 2>/dev/null || printf '')
  # Only remove a lock we still own.
  if [ "$_up_pid" = "$$" ] || [ -z "$_up_pid" ]; then
    update_lock_force_remove "$_up_lock"
    UPDATE_LOCK_HELD=0
    update_log INFO "released update lock"
  fi
}

# Run a command at low priority when the tools exist (no-op otherwise).
update_low_priority() {
  _up_cmd=$1
  shift
  _up_prefix=
  if command -v nice >/dev/null 2>&1 && [ -n "${HOST_NICE:-}" ]; then
    _up_prefix="nice -n ${HOST_NICE}"
  fi
  if command -v ionice >/dev/null 2>&1 && [ -n "${HOST_IONICE_CLASS:-}" ]; then
    if [ -n "${HOST_IONICE_CLASSDATA:-}" ] && [ "$HOST_IONICE_CLASS" != "3" ]; then
      # class 3 (idle) ignores -n on some versions; only pass -n for best-effort/realtime
      _up_prefix="${_up_prefix} ionice -c ${HOST_IONICE_CLASS} -n ${HOST_IONICE_CLASSDATA}"
    else
      _up_prefix="${_up_prefix} ionice -c ${HOST_IONICE_CLASS}"
    fi
  fi
  # shellcheck disable=SC2086
  $_up_prefix "$_up_cmd" "$@"
}

# Pick gpu or cpu for a heavy re-index, honoring host.conf index_device.
update_index_device() {
  case "${HOST_INDEX_DEVICE:-auto}" in
    gpu|GPU) printf 'gpu\n'; return 0 ;;
    cpu|CPU) printf 'cpu\n'; return 0 ;;
  esac
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    printf 'gpu\n'
    return 0
  fi
  # A present discrete GPU is good enough as a hint; the indexer decides.
  if command -v lspci >/dev/null 2>&1; then
    if lspci 2>/dev/null | grep -Ei 'VGA|3D' | grep -Ei 'NVIDIA|AMD|Radeon' >/dev/null; then
      printf 'gpu\n'
      return 0
    fi
  fi
  printf 'cpu\n'
}

# Atomic replace of $2 with $1, keeping one previous copy at $3.
# All three paths should be on the same volume (same-filesystem rename).
# $1 = incoming file, $2 = destination, $3 = previous backup path.
update_atomic_swap() {
  _up_new=$1
  _up_dest=$2
  _up_prev=$3
  _up_prevdir=$(dirname -- "$_up_prev")
  _up_destdir=$(dirname -- "$_up_dest")
  mkdir -p "$_up_prevdir" "$_up_destdir"
  if [ -e "$_up_dest" ]; then
    # Replace the previous backup with the current good file.
    rm -rf "$_up_prev"
    mv "$_up_dest" "$_up_prev"
  fi
  mv "$_up_new" "$_up_dest"
}

# Record a successful (or no-op) update so hourly cron in the same
# window does not redo the work.
update_stamp_success() {
  _up_file=${PROMETHEUS_ROOT}/run/last-update
  mkdir -p "$(dirname -- "$_up_file")"
  date -Iseconds >"$_up_file" 2>/dev/null || date >"$_up_file"
}

update_today_iso() {
  # Print YYYY-MM-DD in HOST_TIMEZONE (or local). Avoid a heredoc inside
  # $(), which dash rejects.
  _up_tz=${1:-}
  if ! command -v python3 >/dev/null 2>&1; then
    date +%Y-%m-%d
    return
  fi
  _up_out=$(
    PROMETHEUS_NOW=${PROMETHEUS_NOW:-} python3 -c '
import os, sys
from datetime import datetime
try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None
tzname = sys.argv[1] or None
tz = None
if tzname and ZoneInfo is not None:
    try:
        tz = ZoneInfo(tzname)
    except Exception:
        tz = None
raw = os.environ.get("PROMETHEUS_NOW") or ""
if raw:
    try:
        dt = datetime.fromtimestamp(float(raw), tz=tz)
    except Exception:
        dt = datetime.now(tz=tz) if tz else datetime.now()
else:
    dt = datetime.now(tz=tz) if tz else datetime.now()
print(dt.date().isoformat())
' "$_up_tz" 2>/dev/null
  ) || _up_out=
  if [ -n "$_up_out" ]; then
    printf "%s\n" "$_up_out"
  else
    date +%Y-%m-%d
  fi
}

update_already_done_today() {
  _up_file=${PROMETHEUS_ROOT}/run/last-update
  [ -f "$_up_file" ] || return 1
  _up_today=$(update_today_iso "${HOST_TIMEZONE:-}")
  _up_stamp=$(cat "$_up_file")
  case "$_up_stamp" in
    "${_up_today}"*) return 0 ;;
  esac
  return 1
}

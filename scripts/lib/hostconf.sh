# Per-host config loader and policy helpers for Prometheus.
# POSIX sh; safe to source from bash start scripts and from scripts/update.
# shellcheck shell=sh

# Current hostname, short form. PROMETHEUS_HOSTNAME wins (tests / overrides).
hostconf_hostname() {
  if [ -n "${PROMETHEUS_HOSTNAME:-}" ]; then
    printf '%s\n' "${PROMETHEUS_HOSTNAME}"
    return
  fi
  _hc_h=$(hostname 2>/dev/null || uname -n 2>/dev/null || printf 'unknown\n')
  # Strip domain.
  printf '%s\n' "${_hc_h%%.*}"
}

hostconf_lc() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

# True (0) if section name matches the current hostname.
hostconf_section_matches() {
  _hc_sec=$(hostconf_lc "$1")
  _hc_host=$(hostconf_lc "$(hostconf_hostname)")
  _hc_sec_short=${_hc_sec%%.*}
  _hc_host_short=${_hc_host%%.*}
  if [ "$_hc_sec" = "$_hc_host" ] || [ "$_hc_sec_short" = "$_hc_host_short" ]; then
    return 0
  fi
  return 1
}

hostconf_reset_defaults() {
  HOST_SCHEDULE=nightly
  HOST_HOUR=3
  HOST_MINUTE=0
  HOST_TIMEZONE=
  HOST_NICE=19
  HOST_IONICE_CLASS=3
  HOST_IONICE_CLASSDATA=7
  HOST_PAUSE_TEMP_C=75
  HOST_ALLOW_MARKET_HOURS=1
  HOST_ALLOW_DAYS=all
  HOST_NIGHT_START=02:00
  HOST_NIGHT_END=06:00
  HOST_LIBRARY_ONLY=0
  HOST_SKIP_AI_WHEN_HOT=1
  HOST_INDEX_DEVICE=auto
  HOST_LOCK_STALE_AFTER_SEC=21600
  HOST_MARKET_HOURS=09:30-16:00
  HOST_MARKET_HOURS_TZ=America/New_York
  HOST_TEMP_SENSOR=
  HOSTCONF_SECTION=default
}

hostconf_apply_key() {
  # hostconf_apply_key KEY VALUE
  _hc_k=$1
  _hc_v=$2
  case "$_hc_k" in
    schedule) HOST_SCHEDULE=$_hc_v ;;
    hour) HOST_HOUR=$_hc_v ;;
    minute) HOST_MINUTE=$_hc_v ;;
    timezone) HOST_TIMEZONE=$_hc_v ;;
    nice) HOST_NICE=$_hc_v ;;
    ionice_class) HOST_IONICE_CLASS=$_hc_v ;;
    ionice_classdata) HOST_IONICE_CLASSDATA=$_hc_v ;;
    pause_temp_c) HOST_PAUSE_TEMP_C=$_hc_v ;;
    allow_market_hours) HOST_ALLOW_MARKET_HOURS=$_hc_v ;;
    allow_days) HOST_ALLOW_DAYS=$_hc_v ;;
    night_start) HOST_NIGHT_START=$_hc_v ;;
    night_end) HOST_NIGHT_END=$_hc_v ;;
    library_only) HOST_LIBRARY_ONLY=$_hc_v ;;
    skip_ai_when_hot) HOST_SKIP_AI_WHEN_HOT=$_hc_v ;;
    index_device) HOST_INDEX_DEVICE=$_hc_v ;;
    lock_stale_after_sec) HOST_LOCK_STALE_AFTER_SEC=$_hc_v ;;
    market_hours) HOST_MARKET_HOURS=$_hc_v ;;
    market_hours_tz) HOST_MARKET_HOURS_TZ=$_hc_v ;;
    temp_sensor) HOST_TEMP_SENSOR=$_hc_v ;;
  esac
}

# Load [default] then overlay the matching host section from $1 (or
# $PROMETHEUS_ROOT/config/host.conf). Missing file is not an error.
hostconf_load() {
  hostconf_reset_defaults
  HOSTCONF_FILE=${1:-}
  if [ -z "$HOSTCONF_FILE" ]; then
    if [ -n "${PROMETHEUS_ROOT:-}" ]; then
      HOSTCONF_FILE=${PROMETHEUS_ROOT}/config/host.conf
    fi
  fi
  if [ -z "${HOSTCONF_FILE:-}" ] || [ ! -f "$HOSTCONF_FILE" ]; then
    HOSTCONF_SECTION=default
    return 0
  fi

  # Two passes: default keys, then matching host keys.
  _hc_pass=1
  while [ "$_hc_pass" -le 2 ]; do
    _hc_section=
    # IFS= preserves leading whitespace we then strip? we trim simply
    while IFS= read -r _hc_line || [ -n "$_hc_line" ]; do
      # Strip CR
      _hc_line=$(printf '%s' "$_hc_line" | tr -d '\r')
      # Trim leading spaces (POSIX parameter expansion loop)
      while [ "$_hc_line" != "${_hc_line# }" ]; do
        _hc_line=${_hc_line# }
      done
      case "$_hc_line" in
        ""|\#*) continue ;;
        \[*\])
          _hc_section=${_hc_line#\[}
          _hc_section=${_hc_section%\]}
          continue
          ;;
      esac
      _hc_key=${_hc_line%%=*}
      _hc_val=${_hc_line#*=}
      while [ "$_hc_key" != "${_hc_key% }" ]; do
        _hc_key=${_hc_key% }
      done
      if [ "$_hc_pass" -eq 1 ]; then
        if [ -z "$_hc_section" ] || [ "$_hc_section" = "default" ]; then
          hostconf_apply_key "$_hc_key" "$_hc_val"
          HOSTCONF_SECTION=default
        fi
      else
        if [ -n "$_hc_section" ] && [ "$_hc_section" != "default" ] && hostconf_section_matches "$_hc_section"; then
          hostconf_apply_key "$_hc_key" "$_hc_val"
          HOSTCONF_SECTION=$_hc_section
        fi
      fi
    done <"$HOSTCONF_FILE"
    _hc_pass=$((_hc_pass + 1))
  done
  # Exported so POSIX helpers and bash/PowerShell launchers can read them.
  export HOST_SCHEDULE HOST_HOUR HOST_MINUTE HOST_TIMEZONE HOST_NICE     HOST_IONICE_CLASS HOST_IONICE_CLASSDATA HOST_PAUSE_TEMP_C     HOST_ALLOW_MARKET_HOURS HOST_ALLOW_DAYS HOST_NIGHT_START HOST_NIGHT_END     HOST_LIBRARY_ONLY HOST_SKIP_AI_WHEN_HOT HOST_INDEX_DEVICE     HOST_LOCK_STALE_AFTER_SEC HOST_MARKET_HOURS HOST_MARKET_HOURS_TZ     HOST_TEMP_SENSOR HOSTCONF_SECTION HOSTCONF_FILE
  return 0
}

# Echo "HH:MM weekday timezone" for "now". weekday is Mon..Sun.
# PROMETHEUS_NOW may be an epoch seconds value or YYYY-MM-DDTHH:MM[:SS].
# $1 = timezone (empty = local).
hostconf_now_fields() {
  _hc_tz=${1:-}
  _hc_now=${PROMETHEUS_NOW:-}
  if command -v python3 >/dev/null 2>&1; then
    PROMETHEUS_NOW=$_hc_now python3 - "$_hc_tz" <<'PY'
import os, sys
from datetime import datetime
try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None

tzname = sys.argv[1] or None
raw = os.environ.get("PROMETHEUS_NOW") or ""
tz = None
if tzname and ZoneInfo is not None:
    try:
        tz = ZoneInfo(tzname)
    except Exception:
        tz = None

if raw:
    dt = None
    try:
        dt = datetime.fromtimestamp(float(raw), tz=tz)
    except Exception:
        s = raw.replace("Z", "+00:00")
        try:
            dt = datetime.fromisoformat(s)
        except Exception:
            dt = None
        if dt is not None and tz is not None:
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=tz)
            else:
                dt = dt.astimezone(tz)
    if dt is None:
        sys.exit(1)
else:
    dt = datetime.now(tz=tz) if tz is not None else datetime.now()

wd = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")[dt.weekday()]
print(f"{dt.hour:02d}:{dt.minute:02d} {wd} {tzname or 'local'}")
PY
    return $?
  fi
  # Fallback: local date(1) only; cannot honor a named timezone.
  if [ -n "$_hc_now" ]; then
    case "$_hc_now" in
      *[!0-9.]* )
        # Best-effort: not a raw epoch.
        date '+%H:%M %a' 2>/dev/null
        ;;
      *)
        date -d "@${_hc_now%.*}" '+%H:%M %a' 2>/dev/null || date -r "${_hc_now%.*}" '+%H:%M %a' 2>/dev/null
        ;;
    esac
    return 0
  fi
  date '+%H:%M %a'
}

hostconf_strip_leading_zeros() {
  # expr handles 08/09 which POSIX $((08)) may treat as invalid octal.
  # expr exits 1 when the result is 0, so do not use its status to
  # decide whether to print a fallback (that would print "0\n0").
  # shellcheck disable=SC2003
  _hc_n=$(expr "$1" + 0 2>/dev/null) || true
  printf '%s\n' "${_hc_n:-0}"
}

hostconf_hm_to_min() {
  # HH:MM -> minutes from midnight. Prints nothing on bad input.
  _hc_hm=$1
  _hc_h=${_hc_hm%%:*}
  _hc_m=${_hc_hm##*:}
  case "$_hc_h" in *[!0-9]*) return 1 ;; esac
  case "$_hc_m" in *[!0-9]*) return 1 ;; esac
  _hc_h=$(hostconf_strip_leading_zeros "$_hc_h")
  _hc_m=$(hostconf_strip_leading_zeros "$_hc_m")
  printf '%s\n' $((_hc_h * 60 + _hc_m))
}

# 0 if current HH:MM is in [start, end), wrapping across midnight.
hostconf_time_in_window() {
  _hc_nowhm=$1
  _hc_start=$2
  _hc_end=$3
  _hc_nowm=$(hostconf_hm_to_min "$_hc_nowhm") || return 1
  _hc_sm=$(hostconf_hm_to_min "$_hc_start") || return 1
  _hc_em=$(hostconf_hm_to_min "$_hc_end") || return 1
  if [ "$_hc_sm" -eq "$_hc_em" ]; then
    return 0
  fi
  if [ "$_hc_sm" -lt "$_hc_em" ]; then
    if [ "$_hc_nowm" -ge "$_hc_sm" ] && [ "$_hc_nowm" -lt "$_hc_em" ]; then
      return 0
    fi
    return 1
  fi
  # Wraps midnight, e.g. 22:00-06:00.
  if [ "$_hc_nowm" -ge "$_hc_sm" ] || [ "$_hc_nowm" -lt "$_hc_em" ]; then
    return 0
  fi
  return 1
}

hostconf_day_allowed() {
  _hc_wd=$1
  _hc_days=$2
  if [ -z "$_hc_days" ] || [ "$_hc_days" = "all" ]; then
    return 0
  fi
  _hc_wd_lc=$(hostconf_lc "$_hc_wd")
  _hc_oldifs=$IFS
  IFS=,
  # shellcheck disable=SC2086
  set -- $_hc_days
  IFS=$_hc_oldifs
  for _hc_d in "$@"; do
    # trim
    while [ "$_hc_d" != "${_hc_d# }" ]; do _hc_d=${_hc_d# }; done
    while [ "$_hc_d" != "${_hc_d% }" ]; do _hc_d=${_hc_d% }; done
    _hc_d_lc=$(hostconf_lc "$_hc_d")
    # Accept Mon / Monday / weekday numbers 0-6 or 1-7.
    case "$_hc_d_lc" in
      "$_hc_wd_lc") return 0 ;;
      mon|monday) [ "$_hc_wd_lc" = mon ] && return 0 ;;
      tue|tues|tuesday) [ "$_hc_wd_lc" = tue ] && return 0 ;;
      wed|wednesday) [ "$_hc_wd_lc" = wed ] && return 0 ;;
      thu|thur|thurs|thursday) [ "$_hc_wd_lc" = thu ] && return 0 ;;
      fri|friday) [ "$_hc_wd_lc" = fri ] && return 0 ;;
      sat|saturday) [ "$_hc_wd_lc" = sat ] && return 0 ;;
      sun|sunday) [ "$_hc_wd_lc" = sun ] && return 0 ;;
    esac
  done
  return 1
}

# 0 if now falls in US-style market hours (weekdays, range in market tz).
hostconf_in_market_hours() {
  _hc_range=${HOST_MARKET_HOURS:-09:30-16:00}
  _hc_tz=${HOST_MARKET_HOURS_TZ:-America/New_York}
  _hc_fields=$(hostconf_now_fields "$_hc_tz") || return 1
  # fields: HH:MM Weekday tz
  # shellcheck disable=SC2086
  set -- $_hc_fields
  _hc_hm=$1
  _hc_wd=$2
  case $(hostconf_lc "$_hc_wd") in
    mon|tue|wed|thu|fri) ;;
    *) return 1 ;;
  esac
  _hc_start=${_hc_range%%-*}
  _hc_end=${_hc_range##*-}
  hostconf_time_in_window "$_hc_hm" "$_hc_start" "$_hc_end"
}

# 0 if the scheduled update window is open now.
hostconf_in_update_window() {
  _hc_tz=${HOST_TIMEZONE:-}
  _hc_fields=$(hostconf_now_fields "$_hc_tz") || return 1
  # shellcheck disable=SC2086
  set -- $_hc_fields
  _hc_hm=$1
  _hc_wd=$2
  if ! hostconf_day_allowed "$_hc_wd" "${HOST_ALLOW_DAYS:-all}"; then
    return 1
  fi
  if [ -n "${HOST_NIGHT_START:-}" ] && [ -n "${HOST_NIGHT_END:-}" ]; then
    hostconf_time_in_window "$_hc_hm" "$HOST_NIGHT_START" "$HOST_NIGHT_END"
    return $?
  fi
  # Fall back to a 3-hour window starting at hour:minute.
  _hc_start=$(printf '%02d:%02d' "${HOST_HOUR:-3}" "${HOST_MINUTE:-0}")
  _hc_endh=$(( (HOST_HOUR + 3) % 24 ))
  _hc_end=$(printf '%02d:%02d' "$_hc_endh" "${HOST_MINUTE:-0}")
  hostconf_time_in_window "$_hc_hm" "$_hc_start" "$_hc_end"
}

# Read CPU package temperature in whole °C, or empty if unavailable.
# Never fails the caller: missing sensors are a graceful skip.
# PROMETHEUS_TEMP_C, if set, wins (tests / overrides).
hostconf_read_temp_c() {
  if [ -n "${PROMETHEUS_TEMP_C:-}" ]; then
    printf '%s\n' "$PROMETHEUS_TEMP_C"
    return 0
  fi
  _hc_sensor=${HOST_TEMP_SENSOR:-}

  if [ -n "$_hc_sensor" ] && [ -r "$_hc_sensor" ]; then
    _hc_raw=$(cat "$_hc_sensor" 2>/dev/null) || { printf '%s' ""; return 0; }
    if [ -n "$_hc_raw" ]; then
      # hwmon is millidegrees; a raw °C value would be much smaller.
      if [ "$_hc_raw" -gt 1000 ] 2>/dev/null; then
        printf '%s\n' $((_hc_raw / 1000))
      else
        printf '%s\n' "$_hc_raw"
      fi
      return 0
    fi
  fi

  # Linux sysfs: prefer a label matching Package id 0 / Package / Tctl,
  # or a named chip (coretemp-package), else the first temp*_input.
  if [ -d /sys/class/hwmon ]; then
    _hc_found=
    _hc_fallback=
    for _hc_hw in /sys/class/hwmon/hwmon*; do
      [ -d "$_hc_hw" ] || continue
      _hc_name=
      [ -r "$_hc_hw/name" ] && _hc_name=$(cat "$_hc_hw/name" 2>/dev/null)
      for _hc_tin in "$_hc_hw"/temp*_input; do
        [ -r "$_hc_tin" ] || continue
        _hc_base=${_hc_tin%_input}
        _hc_lab=
        [ -r "${_hc_base}_label" ] && _hc_lab=$(cat "${_hc_base}_label" 2>/dev/null)
        _hc_raw=$(cat "$_hc_tin" 2>/dev/null) || continue
        [ -n "$_hc_raw" ] || continue
        _hc_c=$_hc_raw
        if [ "$_hc_raw" -gt 1000 ] 2>/dev/null; then
          _hc_c=$((_hc_raw / 1000))
        fi
        if [ -z "$_hc_fallback" ]; then
          _hc_fallback=$_hc_c
        fi
        case "$_hc_sensor" in
          coretemp-package|"Package id 0")
            case "$_hc_lab" in
              "Package id 0"|Package*) _hc_found=$_hc_c; break ;;
            esac
            ;;
          "")
            case "$_hc_lab" in
              "Package id 0"|Package*|Tctl) _hc_found=$_hc_c; break ;;
            esac
            ;;
          "$_hc_name")
            _hc_found=$_hc_c
            break
            ;;
        esac
      done
      [ -n "$_hc_found" ] && break
    done
    if [ -n "$_hc_found" ]; then
      printf '%s\n' "$_hc_found"
      return 0
    fi
    if [ -n "$_hc_fallback" ]; then
      printf '%s\n' "$_hc_fallback"
      return 0
    fi
  fi

  # macOS: no stable unprivileged sysctl for package temp. Skip.
  # Windows is handled in the PowerShell counterpart.
  printf '%s' ""
  return 0
}

# 0 if temperature is at or above the pause threshold.
# 1 if under the threshold, or if no reading is available (graceful skip).
hostconf_over_temp() {
  _hc_limit=${HOST_PAUSE_TEMP_C:-75}
  _hc_temp=$(hostconf_read_temp_c)
  if [ -z "$_hc_temp" ]; then
    return 1
  fi
  if [ "$_hc_temp" -ge "$_hc_limit" ] 2>/dev/null; then
    return 0
  fi
  return 1
}

# Decide whether a scheduled update may run. Prints a one-line reason
# and returns 0 (yes) or 1 (skip). --force is the caller's job.
hostconf_update_permitted() {
  if [ "${HOST_ALLOW_MARKET_HOURS:-1}" = "0" ] && hostconf_in_market_hours; then
    printf '%s\n' "skipped: inside market hours (${HOST_MARKET_HOURS} ${HOST_MARKET_HOURS_TZ})"
    return 1
  fi
  if ! hostconf_in_update_window; then
    printf '%s\n' "skipped: outside the ${HOST_SCHEDULE} window for host $(hostconf_hostname) (section ${HOSTCONF_SECTION})"
    return 1
  fi
  if hostconf_over_temp; then
    _hc_t=$(hostconf_read_temp_c)
    printf '%s\n' "paused: CPU temperature ${_hc_t}C is at or above ${HOST_PAUSE_TEMP_C}C"
    return 1
  fi
  _hc_t=$(hostconf_read_temp_c)
  if [ -n "$_hc_t" ]; then
    printf '%s\n' "permitted: window open, temperature ${_hc_t}C (limit ${HOST_PAUSE_TEMP_C}C)"
  else
    printf '%s\n' "permitted: window open, temperature unavailable (check skipped)"
  fi
  return 0
}

# 0 if start-auto should attempt the AI add-on.
hostconf_ai_permitted() {
  if [ "${HOST_LIBRARY_ONLY:-0}" = "1" ]; then
    printf '%s\n' "host.conf library_only=1; staying library-only"
    return 1
  fi
  if [ "${HOST_SKIP_AI_WHEN_HOT:-1}" = "1" ] && hostconf_over_temp; then
    _hc_t=$(hostconf_read_temp_c)
    printf '%s\n' "CPU ${_hc_t}C is at or above ${HOST_PAUSE_TEMP_C}C; skipping AI, library stays up"
    return 1
  fi
  return 0
}

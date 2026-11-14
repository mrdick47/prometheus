#!/usr/bin/env bash
# Auto launcher: always start the library first, then the best AI tier.
# AI failure must never take kiwix-serve down.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prometheus.sh
source "${SCRIPT_DIR}/lib/prometheus.sh"

usage() {
  cat <<'USAGE'
Usage: start-auto.sh [--tier low|mid|high]

Start kiwix-serve first and wait until it is healthy. Then detect RAM
and GPU (or use --tier to force a choice), load the biggest llamafile
that should run well, and start it. If no model will run, or the AI
fails, the library stays up and this script still exits 0.

  --tier TIER   Skip detection and try this tier first (still walks
                down mid, then low, if the model file is missing)
  --force       Start the AI even if host.conf says library_only or the
                CPU is at or above the pause temperature
  -h, --help    Show this help

This script is for macOS and Linux. On Windows use start-auto.ps1.
USAGE
}

forced=""
FORCE_AI=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force)
      FORCE_AI=1
      shift
      ;;
    --tier)
      shift
      forced="${1:-}"
      [[ -n "${forced}" ]] || { echo "--tier requires a value" >&2; exit 2; }
      shift
      ;;
    --tier=*)
      forced="${1#--tier=}"
      shift
      ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "${forced}" && "${forced}" != low && "${forced}" != mid && "${forced}" != high ]]; then
  echo "tier must be low, mid, or high (got: ${forced})" >&2
  exit 2
fi

prometheus_init

if ! prometheus_start_library; then
  prometheus_log ERROR "library failed to start; AI will not be attempted"
  exit 1
fi

if [[ "${FORCE_AI:-0}" != "1" ]]; then
  if ! reason=$(hostconf_ai_permitted); then
    prometheus_log INFO "${reason}"
    exit 0
  fi
fi

tier="${forced}"
if [[ -z "${tier}" ]]; then
  tier="$(prometheus_select_tier)"
fi

if [[ "${tier}" = "none" ]]; then
  prometheus_log INFO "hardware is below the low-tier threshold; staying library-only"
  exit 0
fi

prometheus_log INFO "auto launcher will try AI tier: ${tier}"
if prometheus_start_ai "${tier}"; then
  exit 0
fi

prometheus_log INFO "AI unavailable; library remains up at $(prometheus_url "${KIWIX_PORT}" "${KIWIX_HEALTH_PATH}")"
exit 0

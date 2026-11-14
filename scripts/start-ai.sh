#!/usr/bin/env bash
# Start the optional AI (llamafile, then RAG if configured).
# Requires a healthy kiwix-serve; will not start or stop the library.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prometheus.sh
source "${SCRIPT_DIR}/lib/prometheus.sh"

usage() {
  cat <<'USAGE'
Usage: start-ai.sh <low|mid|high>

Start llamafile for the chosen tier, and a RAG helper if RAG_SERVER is
set in config/prometheus.conf. The library must already be healthy;
this script will not start or stop kiwix-serve. If the AI fails, the
library is left running.

  --force       Start even if host.conf says library_only or the CPU
                is at or above the pause temperature
  -h, --help    Show this help

This script is for macOS and Linux. On Windows use start-ai.ps1.
USAGE
}

tier=""
FORCE_AI=0
for arg in "$@"; do
  case "${arg}" in
    -h|--help) usage; exit 0 ;;
    --force) FORCE_AI=1 ;;
    low|mid|high)
      if [[ -n "${tier}" ]]; then
        echo "tier already set to ${tier}" >&2
        exit 2
      fi
      tier="${arg}"
      ;;
    --tier)
      echo "pass the tier as a single argument, e.g. start-ai.sh mid" >&2
      exit 2
      ;;
    --tier=*)
      tier="${arg#--tier=}"
      ;;
    *) echo "unknown argument: ${arg}" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "${tier}" ]]; then
  usage >&2
  exit 2
fi
if [[ "${tier}" != low && "${tier}" != mid && "${tier}" != high ]]; then
  echo "tier must be low, mid, or high (got: ${tier})" >&2
  exit 2
fi

prometheus_init
if [[ "${FORCE_AI}" != "1" ]]; then
  if ! reason=$(hostconf_ai_permitted); then
    prometheus_log INFO "${reason}"
    exit 0
  fi
fi
prometheus_start_ai "${tier}"

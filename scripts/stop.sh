#!/usr/bin/env bash
# Stop RAG (if any), llamafile, then kiwix-serve.
# Idempotent: succeeds when nothing is running.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prometheus.sh
source "${SCRIPT_DIR}/lib/prometheus.sh"

usage() {
  cat <<'USAGE'
Usage: stop.sh

Stop the optional AI first, then kiwix-serve. Uses PID files under
run/ and HTTP health checks. Safe to run when nothing is running
(exits 0 after cleaning stale PID files).

  -h, --help    Show this help

This script is for macOS and Linux. On Windows use stop.ps1.
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: ${arg}" >&2; usage >&2; exit 2 ;;
  esac
done

prometheus_init
prometheus_stop_all

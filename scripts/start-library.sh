#!/usr/bin/env bash
# Start kiwix-serve only. Does not start or depend on the AI.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prometheus.sh
source "${SCRIPT_DIR}/lib/prometheus.sh"

usage() {
  cat <<'USAGE'
Usage: start-library.sh

Start kiwix-serve from the PROMETHEUS drive root and wait until
http://127.0.0.1:8080/ is healthy. Does not start llamafile or RAG.

  -h, --help    Show this help

This script is for macOS and Linux. On Windows use start-library.ps1.
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: ${arg}" >&2; usage >&2; exit 2 ;;
  esac
done

prometheus_init
prometheus_start_library

# Stop RAG (if any), llamafile, then kiwix-serve.
# Idempotent: succeeds when nothing is running.
[CmdletBinding()]
param(
    [switch]$Help
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($Help) {
    @"
Usage: stop.ps1

Stop the optional AI first, then kiwix-serve. Uses PID files under
run\ and HTTP health checks. Safe to run when nothing is running
(exits 0 after cleaning stale PID files).

  -Help    Show this help

If script execution is blocked:
  powershell -ExecutionPolicy Bypass -File .\scripts\stop.ps1
"@
    exit 0
}

. (Join-Path $PSScriptRoot "lib\prometheus.ps1")
Initialize-Prometheus
if (Stop-PrometheusAll) { exit 0 } else { exit 1 }

# Start kiwix-serve only. Does not start or depend on the AI.
[CmdletBinding()]
param(
    [switch]$Help
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($Help) {
    @"
Usage: start-library.ps1

Start kiwix-serve from the PROMETHEUS drive root and wait until
http://127.0.0.1:8080/ is healthy. Does not start llamafile or RAG.

  -Help    Show this help

If script execution is blocked:
  powershell -ExecutionPolicy Bypass -File .\scripts\start-library.ps1
"@
    exit 0
}

. (Join-Path $PSScriptRoot "lib\prometheus.ps1")
Initialize-Prometheus
if (-not (Start-PrometheusLibrary)) { exit 1 }
exit 0

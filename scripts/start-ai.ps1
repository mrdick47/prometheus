# Start the optional AI after the library is healthy. Never stops kiwix.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("low", "mid", "high")]
    [string]$Tier,
    [switch]$Force,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($Help -or -not $Tier) {
    @"
Usage: start-ai.ps1 [-Tier] <low|mid|high>

Start llamafile for the chosen tier, and a RAG helper if RAG_SERVER is
set in config/prometheus.conf. The library must already be healthy;
this script will not start or stop kiwix-serve. If the AI fails, the
library is left running.

  -Force   Start even if host.conf says library_only or the CPU is at
           or above the pause temperature
  -Help    Show this help

If script execution is blocked:
  powershell -ExecutionPolicy Bypass -File .\scripts\start-ai.ps1 -Tier mid
"@
    if ($Help) { exit 0 } else { exit 2 }
}

. (Join-Path $PSScriptRoot "lib\prometheus.ps1")
Initialize-Prometheus
if (-not $Force) {
    $ai = Test-PrometheusAiPermitted
    if (-not $ai.Ok) {
        Write-PrometheusLog -Level INFO -Message $ai.Reason
        exit 0
    }
}
$code = Start-PrometheusAi -Tier $Tier
exit $code

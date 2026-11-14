# Auto launcher: always start the library first, then the best AI tier.
# AI failure must never take kiwix-serve down.
[CmdletBinding()]
param(
    [ValidateSet("low", "mid", "high")]
    [string]$Tier,
    [switch]$Force,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($Help) {
    @"
Usage: start-auto.ps1 [-Tier low|mid|high]

Start kiwix-serve first and wait until it is healthy. Then detect RAM
and GPU (or use -Tier to force a choice), load the biggest llamafile
that should run well, and start it. If no model will run, or the AI
fails, the library stays up and this script still exits 0.

  -Force   Start the AI even if host.conf says library_only or the CPU
           is at or above the pause temperature
  -Help    Show this help

If script execution is blocked:
  powershell -ExecutionPolicy Bypass -File .\scripts\start-auto.ps1
"@
    exit 0
}

. (Join-Path $PSScriptRoot "lib\prometheus.ps1")
Initialize-Prometheus

if (-not (Start-PrometheusLibrary)) {
    Write-PrometheusLog -Level ERROR -Message "library failed to start; AI will not be attempted"
    exit 1
}

if (-not $Force) {
    $ai = Test-PrometheusAiPermitted
    if (-not $ai.Ok) {
        Write-PrometheusLog -Level INFO -Message $ai.Reason
        exit 0
    }
}

$chosen = $Tier
if (-not $chosen) {
    $chosen = Select-PrometheusTier
}

if ($chosen -eq "none") {
    Write-PrometheusLog -Level INFO -Message "hardware is below the low-tier threshold; staying library-only"
    exit 0
}

Write-PrometheusLog -Level INFO -Message "auto launcher will try AI tier: $chosen"
$code = Start-PrometheusAi -Tier $chosen
if ($code -eq 0) { exit 0 }

Write-PrometheusLog -Level INFO -Message ("AI unavailable; library remains up at " + (Get-PrometheusUrl -Port $script:KIWIX_PORT -Path $script:KIWIX_HEALTH_PATH))
exit 0

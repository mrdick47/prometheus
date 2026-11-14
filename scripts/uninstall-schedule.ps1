[CmdletBinding()]
param([switch]$Help)
$ErrorActionPreference = "Stop"
if ($Help) {
    @"
Usage: uninstall-schedule.ps1

Remove the PrometheusUpdate scheduled task and the off-drive wrapper
that install-schedule.ps1 created.
"@
    exit 0
}

Unregister-ScheduledTask -TaskName "PrometheusUpdate" -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
$wrapper = Join-Path $env:LOCALAPPDATA "Prometheus\run-update.ps1"
if (Test-Path -LiteralPath $wrapper) { Remove-Item -LiteralPath $wrapper -Force }
Write-Host "Uninstalled Prometheus scheduled update."

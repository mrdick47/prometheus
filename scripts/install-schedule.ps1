# One-line installer for a per-user Task Scheduler job.
[CmdletBinding()]
param(
    [string]$User,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($Help) {
    @"
Usage: install-schedule.ps1

Install a per-user scheduled task that locates the PROMETHEUS drive
and runs scripts\update.ps1. The schedule comes from config/host.conf
for this hostname (or [default]).

  -User NAME   Override the hostname used to look up host.conf
  -Help        Show this help

Raw schtasks example (nightly at 03:00):
  schtasks /Create /TN "PrometheusUpdate" /SC DAILY /ST 03:00 /TR "powershell -ExecutionPolicy Bypass -File %LOCALAPPDATA%\Prometheus\run-update.ps1"
"@
    exit 0
}

$ScriptDir = $PSScriptRoot
. (Join-Path $ScriptDir "lib\hostconf.ps1")
if ($User) { $env:PROMETHEUS_HOSTNAME = $User }
if ($env:PROMETHEUS_ROOT) {
    $script:PROMETHEUS_ROOT = (Resolve-Path -LiteralPath $env:PROMETHEUS_ROOT).Path
}
else {
    $script:PROMETHEUS_ROOT = Split-Path -Parent $ScriptDir
}
Read-PrometheusHostConf

$stampDir = Join-Path $env:LOCALAPPDATA "Prometheus"
if (-not (Test-Path -LiteralPath $stampDir)) { New-Item -ItemType Directory -Path $stampDir -Force | Out-Null }
$wrapper = Join-Path $stampDir "run-update.ps1"
$src = Join-Path $ScriptDir "run-scheduled-update.ps1"
$rootEscaped = $script:PROMETHEUS_ROOT.Replace("'", "''")
(Get-Content -LiteralPath $src -Raw) -replace '\$RecordedRoot = ""', "`$RecordedRoot = '$rootEscaped'" |
    Set-Content -LiteralPath $wrapper

$taskName = "PrometheusUpdate"
$tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$wrapper`""

# Build triggers from the night window and allow_days.
function Get-HoursInWindow([string]$Start, [string]$End) {
    $s = ([int]$Start.Split(":")[0])
    $e = ([int]$End.Split(":")[0])
    $hours = @()
    for ($h = 0; $h -lt 24; $h++) {
        if ($s -eq $e) { $hours += $h }
        elseif ($s -lt $e) { if ($h -ge $s -and $h -lt $e) { $hours += $h } }
        else { if ($h -ge $s -or $h -lt $e) { $hours += $h } }
    }
    return $hours
}

$minute = [int]$script:HOST_MINUTE
$hours = @(Get-HoursInWindow $script:HOST_NIGHT_START $script:HOST_NIGHT_END)
if ($hours.Count -eq 0) { $hours = @([int]$script:HOST_HOUR) }

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper`""
$triggers = @()
$days = $script:HOST_ALLOW_DAYS
if (-not $days -or $days -eq "all") {
    foreach ($h in $hours) {
        $triggers += New-ScheduledTaskTrigger -Daily -At (Get-Date -Hour $h -Minute $minute -Second 0)
    }
}
else {
    $map = @{ sun = "Sunday"; mon = "Monday"; tue = "Tuesday"; wed = "Wednesday"; thu = "Thursday"; fri = "Friday"; sat = "Saturday" }
    $dayNames = @()
    foreach ($d in $days.Split(",")) {
        $key = $d.Trim().ToLowerInvariant().Substring(0, 3)
        if ($map.ContainsKey($key)) { $dayNames += $map[$key] }
    }
    foreach ($h in $hours) {
        $triggers += New-ScheduledTaskTrigger -Weekly -DaysOfWeek $dayNames -At (Get-Date -Hour $h -Minute $minute -Second 0)
    }
}
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Description "Prometheus drive self-updater" | Out-Null
Write-Host "Installed scheduled task $taskName"
Write-Host "Wrapper: $wrapper"
Write-Host "Host: $(Get-PrometheusHostname) section $($script:HOSTCONF_SECTION) schedule $($script:HOST_SCHEDULE)"
Write-Host "Equivalent:"
Write-Host "  schtasks /Create /TN `"$taskName`" /SC DAILY /ST 0$($script:HOST_HOUR):$('{0:d2}' -f $minute) /TR `"$tr`""

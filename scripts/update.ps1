# Prometheus self-updater (Windows). Lives on the drive and finds the
# drive root from this script's location. Never uses a hardcoded drive
# letter or hostname in the code.
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [switch]$IgnoreTemp,
    [switch]$Download,
    [switch]$Status,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($Help) {
    @"
Usage: update.ps1 [-DryRun] [-Force] [-IgnoreTemp] [-Download] [-Status]

Keep the Prometheus library and indexes current. This script lives on
the drive and locates the drive root from its own path.

  -DryRun        Show policy, lock state, and planned work without writing
  -Force         Ignore the schedule window and market hours
  -IgnoreTemp    With -Force, also skip the temperature pause
  -Download      Permit catalog downloads only if PROMETHEUS_ALLOW_DOWNLOAD=1
  -Status        Print lock and last-update state and exit
  -Help          Show this help

Exits 0 if the drive is missing, read-only, already being updated,
outside the allowed window, or paused for heat.
"@
    exit 0
}

$ScriptDir = $PSScriptRoot
. (Join-Path $ScriptDir "lib\hostconf.ps1")

function Get-UpdateRoot {
    if ($env:PROMETHEUS_ROOT) {
        return (Resolve-Path -LiteralPath $env:PROMETHEUS_ROOT).Path
    }
    return (Split-Path -Parent $ScriptDir)
}

function Write-UpdateLog {
    param([string]$Level, [string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    if ($script:UPDATE_LOG_FILE) {
        $dir = Split-Path -Parent $script:UPDATE_LOG_FILE
        if (-not (Test-Path -LiteralPath $dir)) {
            try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
        }
        try { Add-Content -LiteralPath $script:UPDATE_LOG_FILE -Value $line } catch { }
    }
}

function Get-UpdateLockDir { Join-Path $script:PROMETHEUS_ROOT "run\update.lock" }

function Test-UpdateDriveWritable {
    $run = Join-Path $script:PROMETHEUS_ROOT "run"
    try {
        if (-not (Test-Path -LiteralPath $run)) {
            New-Item -ItemType Directory -Path $run -Force | Out-Null
        }
        $probe = Join-Path $run ".write-probe"
        Set-Content -LiteralPath $probe -Value "ok"
        Remove-Item -LiteralPath $probe -Force
        return $true
    }
    catch {
        return $false
    }
}

function Write-UpdateLockOwner {
    param([string]$LockDir)
    $started = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $body = @(
        "hostname=$(Get-PrometheusHostname)"
        "pid=$PID"
        "started=$started"
        "started_iso=$(Get-Date -Format o)"
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $LockDir "owner") -Value $body
    Set-Content -LiteralPath (Join-Path $LockDir "heartbeat") -Value "$started"
}

function Get-UpdateLockField {
    param([string]$File, [string]$Field)
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    foreach ($line in Get-Content -LiteralPath $File) {
        if ($line.StartsWith("$Field=")) { return $line.Substring($Field.Length + 1) }
    }
    return $null
}

function Get-UpdateLockAgeSec {
    param([string]$LockDir)
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $hbFile = Join-Path $LockDir "heartbeat"
    if (Test-Path -LiteralPath $hbFile) {
        $hb = [int64]((Get-Content -LiteralPath $hbFile -Raw).Trim())
        if ($hb -gt 0) { return ($now - $hb) }
    }
    $st = Get-UpdateLockField -File (Join-Path $LockDir "owner") -Field "started"
    if ($st) { return ($now - [int64]$st) }
    return 0
}

function Test-UpdatePidRunning {
    param([string]$ProcessId)
    if (-not $ProcessId) { return $false }
    try { $null = Get-Process -Id ([int]$ProcessId) -ErrorAction Stop; return $true } catch { return $false }
}

function Remove-UpdateLock {
    param([string]$LockDir)
    if (Test-Path -LiteralPath $LockDir) {
        Remove-Item -LiteralPath $LockDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-UpdateLock {
    $lock = Get-UpdateLockDir
    if (-not (Test-UpdateDriveWritable)) {
        Write-UpdateLog -Level INFO -Message "drive is missing or read-only at $($script:PROMETHEUS_ROOT); nothing to do"
        return 2
    }
    $run = Join-Path $script:PROMETHEUS_ROOT "run"
    if (-not (Test-Path -LiteralPath $run)) { New-Item -ItemType Directory -Path $run -Force | Out-Null }
    for ($try = 0; $try -lt 2; $try++) {
        try {
            $null = New-Item -ItemType Directory -Path $lock -ErrorAction Stop
            Write-UpdateLockOwner -LockDir $lock
            $script:UPDATE_LOCK_HELD = $true
            Write-UpdateLog -Level INFO -Message "acquired update lock on $(Get-PrometheusHostname) pid $PID"
            return 0
        }
        catch { }
        $owner = Join-Path $lock "owner"
        $hostHeld = Get-UpdateLockField -File $owner -Field "hostname"
        $pidHeld = Get-UpdateLockField -File $owner -Field "pid"
        $age = Get-UpdateLockAgeSec -LockDir $lock
        $stale = [int]$script:HOST_LOCK_STALE_AFTER_SEC
        if ($hostHeld -eq (Get-PrometheusHostname) -and $pidHeld -and -not (Test-UpdatePidRunning -ProcessId $pidHeld)) {
            Write-UpdateLog -Level INFO -Message "removing stale lock from this host (dead pid $pidHeld)"
            Remove-UpdateLock -LockDir $lock
            continue
        }
        if ($age -ge $stale) {
            Write-UpdateLog -Level INFO -Message "removing stale lock from ${hostHeld} (age ${age}s, limit ${stale}s)"
            Remove-UpdateLock -LockDir $lock
            continue
        }
        Write-UpdateLog -Level INFO -Message "update already running on ${hostHeld} pid ${pidHeld} (age ${age}s); exiting"
        return 1
    }
    return 1
}

function Release-UpdateLock {
    if (-not $script:UPDATE_LOCK_HELD) { return }
    $lock = Get-UpdateLockDir
    $pidHeld = Get-UpdateLockField -File (Join-Path $lock "owner") -Field "pid"
    if (-not $pidHeld -or $pidHeld -eq "$PID") {
        Remove-UpdateLock -LockDir $lock
        $script:UPDATE_LOCK_HELD = $false
        Write-UpdateLog -Level INFO -Message "released update lock"
    }
}

function Get-UpdateIndexDevice {
    if ($script:HOST_INDEX_DEVICE -and $script:HOST_INDEX_DEVICE -ne "auto") {
        return $script:HOST_INDEX_DEVICE.ToLowerInvariant()
    }
    try {
        $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match "NVIDIA|GeForce|AMD|Radeon" }
        if ($gpu) { return "gpu" }
    }
    catch { }
    return "cpu"
}

function Write-UpdateStatus {
    $lock = Get-UpdateLockDir
    if (Test-Path -LiteralPath $lock) {
        Write-Host "lock: held"
        $owner = Join-Path $lock "owner"
        if (Test-Path -LiteralPath $owner) { Get-Content -LiteralPath $owner }
        Write-Host "lock_age_sec=$(Get-UpdateLockAgeSec -LockDir $lock)"
    }
    else {
        Write-Host "lock: none"
    }
    $stamp = Join-Path $script:PROMETHEUS_ROOT "run\last-update"
    if (Test-Path -LiteralPath $stamp) {
        Write-Host "last_update=$((Get-Content -LiteralPath $stamp -Raw).Trim())"
    }
    else {
        Write-Host "last_update=never"
    }
    $temp = Get-PrometheusTempC
    if ($null -ne $temp) {
        Write-Host "temperature_c=$temp (pause at $($script:HOST_PAUSE_TEMP_C))"
    }
    else {
        Write-Host "temperature_c=unavailable (check skipped)"
    }
    Write-Host "index_device=$(Get-UpdateIndexDevice)"
    $tz = $script:HOST_TIMEZONE; if (-not $tz) { $tz = "local" }
    Write-Host "schedule=$($script:HOST_SCHEDULE) allow_days=$($script:HOST_ALLOW_DAYS) window=$($script:HOST_NIGHT_START)-$($script:HOST_NIGHT_END) tz=$tz"
}

function Test-UpdateAlreadyDoneToday {
    $stamp = Join-Path $script:PROMETHEUS_ROOT "run\last-update"
    if (-not (Test-Path -LiteralPath $stamp)) { return $false }
    $dt = Get-PrometheusNow -TimeZoneName $script:HOST_TIMEZONE
    $text = (Get-Content -LiteralPath $stamp -Raw).Trim()
    return $text.StartsWith($dt.ToString("yyyy-MM-dd"))
}

$script:PROMETHEUS_ROOT = Get-UpdateRoot
$script:UPDATE_LOCK_HELD = $false
$logDir = Join-Path $script:PROMETHEUS_ROOT "run\logs"
try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch { }
$script:UPDATE_LOG_FILE = Join-Path $logDir "update.log"
Read-PrometheusHostConf
Write-UpdateLog -Level INFO -Message "drive root: $($script:PROMETHEUS_ROOT)"
Write-UpdateLog -Level INFO -Message "host: $(Get-PrometheusHostname) (host.conf section $($script:HOSTCONF_SECTION))"

if ($Status) {
    Write-UpdateStatus
    exit 0
}

if ($Force) {
    if (-not $IgnoreTemp -and (Test-PrometheusOverTemp)) {
        $perm = @{ Ok = $false; Reason = "paused: CPU temperature $(Get-PrometheusTempC)C is at or above $($script:HOST_PAUSE_TEMP_C)C" }
    }
    else {
        $t = Get-PrometheusTempC
        $reason = if ($null -ne $t) { "permitted: --force (temperature ${t}C)" } else { "permitted: --force (temperature unavailable)" }
        $perm = @{ Ok = $true; Reason = $reason }
    }
}
else {
    $perm = Get-PrometheusUpdatePermission
}
Write-UpdateLog -Level INFO -Message $perm.Reason

if ($DryRun) {
    Write-UpdateStatus
    Write-Host "policy: $($perm.Reason)"
    $dev = Get-UpdateIndexDevice
    Write-Host "planned: check Kiwix catalog, verify checksums, incremental re-index on $dev, atomic swap with one previous version"
    Write-Host "planned: downloads disabled unless -Download and PROMETHEUS_ALLOW_DOWNLOAD=1 are both set"
    exit 0
}

if (-not $perm.Ok) { exit 0 }

$lockRc = Get-UpdateLock
if ($lockRc -ne 0) { exit 0 }
try {
    if ((Test-UpdateAlreadyDoneToday) -and -not $Force) {
        $stamp = Get-Content -LiteralPath (Join-Path $script:PROMETHEUS_ROOT "run\last-update") -Raw
        Write-UpdateLog -Level INFO -Message "already updated today ($($stamp.Trim())); nothing to do"
        exit 0
    }

    $sources = Join-Path $script:PROMETHEUS_ROOT "config\sources.conf"
    $pending = 0
    if (Test-Path -LiteralPath $sources) {
        $pending = @(Get-Content -LiteralPath $sources | Where-Object { $_ -match '^url=.+' -and $_ -notmatch '^url=\s*$' }).Count
    }
    if ($pending -gt 0) {
        Write-UpdateLog -Level INFO -Message "catalog has $pending source URL(s); downloads are disabled unless -Download and PROMETHEUS_ALLOW_DOWNLOAD=1 are both set. Skipping fetch."
    }
    else {
        Write-UpdateLog -Level INFO -Message "no catalog URLs configured; skipping fetch (library unchanged)"
    }

    $device = Get-UpdateIndexDevice
    $reindex = Join-Path $ScriptDir "reindex.ps1"
    if (Test-Path -LiteralPath $reindex) {
        Write-UpdateLog -Level INFO -Message "running incremental re-index on $device"
        & $reindex -Incremental -Device $device
        if ($LASTEXITCODE -ne 0) {
            Write-UpdateLog -Level ERROR -Message "reindex failed; leaving the previous library and index in place"
            exit 1
        }
    }
    else {
        if ($device -eq "gpu") {
            Write-UpdateLog -Level INFO -Message "no scripts/reindex hook yet; would use the GPU for a heavy re-index"
        }
        else {
            Write-UpdateLog -Level INFO -Message "no scripts/reindex hook yet; would fall back to slow incremental CPU indexing"
        }
    }

    $stampFile = Join-Path $script:PROMETHEUS_ROOT "run\last-update"
    $stampDir = Split-Path -Parent $stampFile
    if (-not (Test-Path -LiteralPath $stampDir)) { New-Item -ItemType Directory -Path $stampDir -Force | Out-Null }
    Set-Content -LiteralPath $stampFile -Value ((Get-Date).ToString("yyyy-MM-ddTHH:mm:ss"))
    Write-UpdateLog -Level INFO -Message "update finished (no payload applied in this build)"
    exit 0
}
finally {
    Release-UpdateLock
}

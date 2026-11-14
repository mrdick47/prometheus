# Per-host config loader and policy helpers (Windows PowerShell).

function Get-PrometheusHostname {
    if ($env:PROMETHEUS_HOSTNAME) { return $env:PROMETHEUS_HOSTNAME }
    $h = [Environment]::MachineName
    if ($h -and $h.Contains(".")) { $h = $h.Split(".")[0] }
    return $h
}

function Test-PrometheusHostSection {
    param([string]$Section)
    $sec = $Section.ToLowerInvariant()
    $hostName = (Get-PrometheusHostname).ToLowerInvariant()
    $secShort = $sec.Split(".")[0]
    $hostShort = $hostName.Split(".")[0]
    return ($sec -eq $hostName -or $secShort -eq $hostShort)
}

function Reset-PrometheusHostDefaults {
    $script:HOST_SCHEDULE = "nightly"
    $script:HOST_HOUR = "3"
    $script:HOST_MINUTE = "0"
    $script:HOST_TIMEZONE = ""
    $script:HOST_NICE = "19"
    $script:HOST_IONICE_CLASS = "3"
    $script:HOST_IONICE_CLASSDATA = "7"
    $script:HOST_PAUSE_TEMP_C = "75"
    $script:HOST_ALLOW_MARKET_HOURS = "1"
    $script:HOST_ALLOW_DAYS = "all"
    $script:HOST_NIGHT_START = "02:00"
    $script:HOST_NIGHT_END = "06:00"
    $script:HOST_LIBRARY_ONLY = "0"
    $script:HOST_SKIP_AI_WHEN_HOT = "1"
    $script:HOST_INDEX_DEVICE = "auto"
    $script:HOST_LOCK_STALE_AFTER_SEC = "21600"
    $script:HOST_MARKET_HOURS = "09:30-16:00"
    $script:HOST_MARKET_HOURS_TZ = "America/New_York"
    $script:HOST_TEMP_SENSOR = ""
    $script:HOSTCONF_SECTION = "default"
}

function Set-PrometheusHostKey {
    param([string]$Key, [string]$Value)
    switch ($Key) {
        "schedule" { $script:HOST_SCHEDULE = $Value }
        "hour" { $script:HOST_HOUR = $Value }
        "minute" { $script:HOST_MINUTE = $Value }
        "timezone" { $script:HOST_TIMEZONE = $Value }
        "nice" { $script:HOST_NICE = $Value }
        "ionice_class" { $script:HOST_IONICE_CLASS = $Value }
        "ionice_classdata" { $script:HOST_IONICE_CLASSDATA = $Value }
        "pause_temp_c" { $script:HOST_PAUSE_TEMP_C = $Value }
        "allow_market_hours" { $script:HOST_ALLOW_MARKET_HOURS = $Value }
        "allow_days" { $script:HOST_ALLOW_DAYS = $Value }
        "night_start" { $script:HOST_NIGHT_START = $Value }
        "night_end" { $script:HOST_NIGHT_END = $Value }
        "library_only" { $script:HOST_LIBRARY_ONLY = $Value }
        "skip_ai_when_hot" { $script:HOST_SKIP_AI_WHEN_HOT = $Value }
        "index_device" { $script:HOST_INDEX_DEVICE = $Value }
        "lock_stale_after_sec" { $script:HOST_LOCK_STALE_AFTER_SEC = $Value }
        "market_hours" { $script:HOST_MARKET_HOURS = $Value }
        "market_hours_tz" { $script:HOST_MARKET_HOURS_TZ = $Value }
        "temp_sensor" { $script:HOST_TEMP_SENSOR = $Value }
    }
}

function Read-PrometheusHostConf {
    param([string]$Path)
    Reset-PrometheusHostDefaults
    if (-not $Path) {
        if ($script:PROMETHEUS_ROOT) {
            $Path = Join-Path $script:PROMETHEUS_ROOT "config\host.conf"
        }
    }
    $script:HOSTCONF_FILE = $Path
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        $script:HOSTCONF_SECTION = "default"
        return
    }
    foreach ($pass in 1..2) {
        $section = ""
        Get-Content -LiteralPath $Path | ForEach-Object {
            $line = $_.Trim()
            if ($line -eq "" -or $line.StartsWith("#")) { return }
            if ($line.StartsWith("[") -and $line.EndsWith("]")) {
                $section = $line.Substring(1, $line.Length - 2)
                return
            }
            $eq = $line.IndexOf("=")
            if ($eq -lt 1) { return }
            $key = $line.Substring(0, $eq).Trim()
            $val = $line.Substring($eq + 1)
            if ($pass -eq 1) {
                if (-not $section -or $section -eq "default") {
                    Set-PrometheusHostKey -Key $key -Value $val
                    $script:HOSTCONF_SECTION = "default"
                }
            }
            else {
                if ($section -and $section -ne "default" -and (Test-PrometheusHostSection -Section $section)) {
                    Set-PrometheusHostKey -Key $key -Value $val
                    $script:HOSTCONF_SECTION = $section
                }
            }
        }
    }
}

function Get-PrometheusNow {
    param([string]$TimeZoneName)
    if ($env:PROMETHEUS_NOW) {
        $raw = $env:PROMETHEUS_NOW
        $dt = $null
        try { $dt = [DateTimeOffset]::FromUnixTimeSeconds([int64][double]$raw).LocalDateTime } catch { }
        if (-not $dt) {
            try { $dt = [datetime]::Parse($raw) } catch { $dt = Get-Date }
        }
    }
    else {
        $dt = Get-Date
    }
    if ($TimeZoneName) {
        try {
            $tz = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneName)
            $dt = [TimeZoneInfo]::ConvertTime($dt, $tz)
        }
        catch {
            try {
                # IANA names on newer Windows / .NET
                $tz = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneName)
                $dt = [TimeZoneInfo]::ConvertTime($dt, $tz)
            }
            catch { }
        }
    }
    return $dt
}

function Convert-PrometheusHmToMin {
    param([string]$Hm)
    $parts = $Hm.Split(":")
    return ([int]$parts[0] * 60) + [int]$parts[1]
}

function Test-PrometheusTimeInWindow {
    param([string]$NowHm, [string]$Start, [string]$End)
    $now = Convert-PrometheusHmToMin $NowHm
    $s = Convert-PrometheusHmToMin $Start
    $e = Convert-PrometheusHmToMin $End
    if ($s -eq $e) { return $true }
    if ($s -lt $e) { return ($now -ge $s -and $now -lt $e) }
    return ($now -ge $s -or $now -lt $e)
}

function Test-PrometheusDayAllowed {
    param([string]$Weekday, [string]$Days)
    if (-not $Days -or $Days -eq "all") { return $true }
    $wd = $Weekday.Substring(0, 3).ToLowerInvariant()
    foreach ($d in $Days.Split(",")) {
        $n = $d.Trim().ToLowerInvariant()
        if ($n.StartsWith($wd) -or $n -eq $wd) { return $true }
    }
    return $false
}

function Test-PrometheusMarketHours {
    $dt = Get-PrometheusNow -TimeZoneName $script:HOST_MARKET_HOURS_TZ
    $wd = $dt.ToString("ddd", [System.Globalization.CultureInfo]::InvariantCulture)
    if ($wd -notin @("Mon", "Tue", "Wed", "Thu", "Fri")) { return $false }
    $range = $script:HOST_MARKET_HOURS
    $start = $range.Split("-")[0]
    $end = $range.Split("-")[1]
    $hm = $dt.ToString("HH:mm")
    return (Test-PrometheusTimeInWindow -NowHm $hm -Start $start -End $end)
}

function Test-PrometheusUpdateWindow {
    $dt = Get-PrometheusNow -TimeZoneName $script:HOST_TIMEZONE
    $wd = $dt.ToString("ddd", [System.Globalization.CultureInfo]::InvariantCulture)
    if (-not (Test-PrometheusDayAllowed -Weekday $wd -Days $script:HOST_ALLOW_DAYS)) {
        return $false
    }
    $hm = $dt.ToString("HH:mm")
    if ($script:HOST_NIGHT_START -and $script:HOST_NIGHT_END) {
        return (Test-PrometheusTimeInWindow -NowHm $hm -Start $script:HOST_NIGHT_START -End $script:HOST_NIGHT_END)
    }
    $start = "{0:d2}:{1:d2}" -f [int]$script:HOST_HOUR, [int]$script:HOST_MINUTE
    $end = "{0:d2}:{1:d2}" -f (([int]$script:HOST_HOUR + 3) % 24), [int]$script:HOST_MINUTE
    return (Test-PrometheusTimeInWindow -NowHm $hm -Start $start -End $end)
}

function Get-PrometheusTempC {
    if ($env:PROMETHEUS_TEMP_C) { return [int]$env:PROMETHEUS_TEMP_C }
    try {
        $zone = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | Select-Object -First 1
        if ($zone -and $zone.CurrentTemperature) {
            return [int](($zone.CurrentTemperature / 10) - 273)
        }
    }
    catch { }
    return $null
}

function Test-PrometheusOverTemp {
    $temp = Get-PrometheusTempC
    if ($null -eq $temp) { return $false }
    return ($temp -ge [int]$script:HOST_PAUSE_TEMP_C)
}

function Get-PrometheusUpdatePermission {
    if ($script:HOST_ALLOW_MARKET_HOURS -eq "0" -and (Test-PrometheusMarketHours)) {
        return @{ Ok = $false; Reason = "skipped: inside market hours ($($script:HOST_MARKET_HOURS) $($script:HOST_MARKET_HOURS_TZ))" }
    }
    if (-not (Test-PrometheusUpdateWindow)) {
        $hostName = Get-PrometheusHostname
        return @{ Ok = $false; Reason = "skipped: outside the $($script:HOST_SCHEDULE) window for host $hostName (section $($script:HOSTCONF_SECTION))" }
    }
    if (Test-PrometheusOverTemp) {
        $t = Get-PrometheusTempC
        return @{ Ok = $false; Reason = "paused: CPU temperature ${t}C is at or above $($script:HOST_PAUSE_TEMP_C)C" }
    }
    $t = Get-PrometheusTempC
    if ($null -ne $t) {
        return @{ Ok = $true; Reason = "permitted: window open, temperature ${t}C (limit $($script:HOST_PAUSE_TEMP_C)C)" }
    }
    return @{ Ok = $true; Reason = "permitted: window open, temperature unavailable (check skipped)" }
}

function Test-PrometheusAiPermitted {
    if ($script:HOST_LIBRARY_ONLY -eq "1") {
        return @{ Ok = $false; Reason = "host.conf library_only=1; staying library-only" }
    }
    if ($script:HOST_SKIP_AI_WHEN_HOT -eq "1" -and (Test-PrometheusOverTemp)) {
        $t = Get-PrometheusTempC
        return @{ Ok = $false; Reason = "CPU ${t}C is at or above $($script:HOST_PAUSE_TEMP_C)C; skipping AI, library stays up" }
    }
    return @{ Ok = $true; Reason = "" }
}

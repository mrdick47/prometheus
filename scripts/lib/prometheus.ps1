# Shared helpers for Prometheus start/stop scripts (Windows PowerShell).
# Dot-sourced by the .ps1 launchers; not meant to be executed directly.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-PrometheusRoot {
    if ($env:PROMETHEUS_ROOT) {
        return (Resolve-Path -LiteralPath $env:PROMETHEUS_ROOT).Path
    }
    $libDir = Split-Path -Parent $PSCommandPath
    $scriptsDir = Split-Path -Parent $libDir
    return (Split-Path -Parent $scriptsDir)
}

function Write-PrometheusLog {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    if ($script:PROMETHEUS_LOG_FILE) {
        $dir = Split-Path -Parent $script:PROMETHEUS_LOG_FILE
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath $script:PROMETHEUS_LOG_FILE -Value $line
    }
}

function Exit-PrometheusError {
    param([string]$Message)
    Write-PrometheusLog -Level ERROR -Message $Message
    exit 1
}

function Read-PrometheusConfig {
    $conf = Join-Path $script:PROMETHEUS_ROOT "config\prometheus.conf"
    if (-not (Test-Path -LiteralPath $conf)) {
        Exit-PrometheusError "config not found: $conf"
    }
    Get-Content -LiteralPath $conf | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { return }
        $eq = $line.IndexOf("=")
        if ($eq -lt 1) { return }
        $key = $line.Substring(0, $eq).Trim()
        $value = $line.Substring($eq + 1)
        if (-not $key) { return }
        $existing = [Environment]::GetEnvironmentVariable($key)
        if ($null -ne $existing -and $existing -ne "") {
            Set-Variable -Name $key -Value $existing -Scope Script
        }
        else {
            Set-Variable -Name $key -Value $value -Scope Script
        }
    }
}

function Set-PrometheusDefaults {
    if (-not (Get-Variable -Name PROMETHEUS_BIND -Scope Script -ErrorAction SilentlyContinue)) { $script:PROMETHEUS_BIND = "0.0.0.0" }
    if (-not $script:PROMETHEUS_BIND) { $script:PROMETHEUS_BIND = "0.0.0.0" }
    if (-not $script:KIWIX_PORT) { $script:KIWIX_PORT = "8080" }
    if (-not $script:KIWIX_HEALTH_PATH) { $script:KIWIX_HEALTH_PATH = "/" }
    if (-not $script:LLAMAFILE_PORT) { $script:LLAMAFILE_PORT = "8081" }
    if (-not $script:LLAMAFILE_HEALTH_PATH) { $script:LLAMAFILE_HEALTH_PATH = "/v1/models" }
    if (-not $script:LLAMAFILE_ARGS) { $script:LLAMAFILE_ARGS = "--server --nobrowser" }
    if (-not (Get-Variable -Name RAG_PORT -Scope Script -ErrorAction SilentlyContinue) -or -not $script:RAG_PORT) { $script:RAG_PORT = "8082" }
    if (-not (Get-Variable -Name RAG_HEALTH_PATH -Scope Script -ErrorAction SilentlyContinue) -or -not $script:RAG_HEALTH_PATH) { $script:RAG_HEALTH_PATH = "/" }
    if (-not (Get-Variable -Name RAG_SERVER -Scope Script -ErrorAction SilentlyContinue)) { $script:RAG_SERVER = "" }
    if (-not $script:HEALTH_TIMEOUT_SEC) { $script:HEALTH_TIMEOUT_SEC = "45" }
    if (-not $script:HEALTH_POLL_SEC) { $script:HEALTH_POLL_SEC = "0.5" }
    if (-not $script:LIBRARY_DIR) { $script:LIBRARY_DIR = "library" }
    if (-not $script:APPS_DIR) { $script:APPS_DIR = "apps" }
    if (-not $script:MODELS_DIR) { $script:MODELS_DIR = "models" }
    if (-not $script:INDEX_DIR) { $script:INDEX_DIR = "index" }
    if (-not $script:RUN_DIR) { $script:RUN_DIR = "run" }
    if (-not $script:LOG_DIR) { $script:LOG_DIR = "run\logs" }
    if (-not (Get-Variable -Name KIWIX_SERVE -Scope Script -ErrorAction SilentlyContinue)) { $script:KIWIX_SERVE = "" }
    if (-not (Get-Variable -Name LLAMAFILE -Scope Script -ErrorAction SilentlyContinue)) { $script:LLAMAFILE = "" }
    if (-not $script:HIGH_MIN_RAM_GB) { $script:HIGH_MIN_RAM_GB = "32" }
    if (-not $script:HIGH_REQUIRES_DISCRETE_GPU) { $script:HIGH_REQUIRES_DISCRETE_GPU = "1" }
    if (-not $script:MID_MIN_RAM_GB) { $script:MID_MIN_RAM_GB = "16" }
    if (-not $script:MID_GPU_MIN_RAM_GB) { $script:MID_GPU_MIN_RAM_GB = "8" }
    if (-not $script:LOW_MIN_RAM_GB) { $script:LOW_MIN_RAM_GB = "8" }
}

function Get-PrometheusAbs {
    param([string]$PathValue)
    if ([string]::IsNullOrEmpty($PathValue)) { return "" }
    if ([System.IO.Path]::IsPathRooted($PathValue)) { return $PathValue }
    return (Join-Path $script:PROMETHEUS_ROOT $PathValue)
}

function Initialize-PrometheusRuntime {
    $script:LIBRARY_DIR = Get-PrometheusAbs $script:LIBRARY_DIR
    $script:APPS_DIR = Get-PrometheusAbs $script:APPS_DIR
    $script:MODELS_DIR = Get-PrometheusAbs $script:MODELS_DIR
    $script:INDEX_DIR = Get-PrometheusAbs $script:INDEX_DIR
    $script:RUN_DIR = Get-PrometheusAbs $script:RUN_DIR
    $script:LOG_DIR = Get-PrometheusAbs $script:LOG_DIR
    foreach ($d in @($script:RUN_DIR, $script:LOG_DIR)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
    $script:KIWIX_PID_FILE = Join-Path $script:RUN_DIR "kiwix-serve.pid"
    $script:LLAMAFILE_PID_FILE = Join-Path $script:RUN_DIR "llamafile.pid"
    $script:RAG_PID_FILE = Join-Path $script:RUN_DIR "rag.pid"
    $script:PROMETHEUS_LOG_FILE = Join-Path $script:LOG_DIR "prometheus.log"
}

function Get-PrometheusOsArch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -eq "AMD64" -or $arch -eq "X64") { $archName = "x86_64" }
    elseif ($arch -eq "ARM64") { $archName = "arm64" }
    else { $archName = $arch }
    return "windows-$archName"
}

function Find-PrometheusExe {
    param([string[]]$Names)
    $osArch = Get-PrometheusOsArch
    foreach ($name in $Names) {
        foreach ($cand in @(
                (Join-Path $script:APPS_DIR $name),
                (Join-Path (Join-Path $script:APPS_DIR $osArch) $name),
                (Join-Path (Join-Path $script:APPS_DIR "windows") $name),
                (Join-Path (Join-Path $script:APPS_DIR "windows-x86_64") $name)
            )) {
            if (Test-Path -LiteralPath $cand) { return $cand }
        }
    }
    return $null
}

function Resolve-KiwixServe {
    if ($script:KIWIX_SERVE) {
        $script:KIWIX_SERVE = Get-PrometheusAbs $script:KIWIX_SERVE
        if (-not (Test-Path -LiteralPath $script:KIWIX_SERVE)) {
            Exit-PrometheusError "KIWIX_SERVE not found: $($script:KIWIX_SERVE)"
        }
        return
    }
    $found = Find-PrometheusExe -Names @("kiwix-serve.exe", "kiwix-serve")
    if (-not $found) {
        Exit-PrometheusError "kiwix-serve not found under $($script:APPS_DIR) (set KIWIX_SERVE in config or the environment)"
    }
    $script:KIWIX_SERVE = $found
}

function Resolve-LlamafileRuntime {
    if ($script:LLAMAFILE) {
        $script:LLAMAFILE = Get-PrometheusAbs $script:LLAMAFILE
        return (Test-Path -LiteralPath $script:LLAMAFILE)
    }
    $found = Find-PrometheusExe -Names @("llamafile.exe", "llamafile")
    if ($found) {
        $script:LLAMAFILE = $found
        return $true
    }
    return $false
}

function Get-PrometheusZims {
    if (-not (Test-Path -LiteralPath $script:LIBRARY_DIR)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:LIBRARY_DIR -File -Filter *.zim)
}

function Get-PrometheusUrl {
    param([string]$Port, [string]$Path)
    if (-not $Path.StartsWith("/")) { $Path = "/$Path" }
    return "http://127.0.0.1:${Port}${Path}"
}

function Test-PrometheusHttpOk {
    param([string]$Url, [int]$TimeoutSec = 5)
    try {
        $handler = $null
        try {
            $handler = New-Object System.Net.Http.HttpClientHandler
            $client = New-Object System.Net.Http.HttpClient($handler)
            $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
            $response = $client.GetAsync($Url).GetAwaiter().GetResult()
            $code = [int]$response.StatusCode
            $client.Dispose()
            return ($code -ge 200 -and $code -lt 400)
        }
        finally {
            if ($handler) { $handler.Dispose() }
        }
    }
    catch {
        try {
            $req = [System.Net.WebRequest]::Create($Url)
            $req.Timeout = $TimeoutSec * 1000
            $req.Method = "GET"
            $resp = $req.GetResponse()
            $resp.Close()
            return $true
        }
        catch {
            return $false
        }
    }
}

function Wait-PrometheusHealthy {
    param([string]$Name, [string]$Port, [string]$Path, [int]$TimeoutSec)
    $url = Get-PrometheusUrl -Port $Port -Path $Path
    $start = Get-Date
    $poll = [double]$script:HEALTH_POLL_SEC
    if ($poll -le 0) { $poll = 0.5 }
    while ($true) {
        if (Test-PrometheusHttpOk -Url $url -TimeoutSec 3) {
            Write-PrometheusLog -Level INFO -Message "$Name is healthy at $url"
            return $true
        }
        if (((Get-Date) - $start).TotalSeconds -ge $TimeoutSec) {
            Write-PrometheusLog -Level ERROR -Message "$Name did not become healthy at $url within ${TimeoutSec}s"
            return $false
        }
        Start-Sleep -Milliseconds ([int]($poll * 1000))
    }
}

function Get-PrometheusPid {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $raw = (Get-Content -LiteralPath $File -Raw).Trim()
    if (-not $raw) { return $null }
    return [int]$raw
}

function Test-PrometheusPidRunning {
    param([int]$ProcessId)
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        return $null -ne $p
    }
    catch {
        return $false
    }
}

function Test-PrometheusAlive {
    param([string]$PidFile, [string]$Port, [string]$Path)
    $procId = Get-PrometheusPid -File $PidFile
    if ($procId -and (Test-PrometheusPidRunning -ProcessId $procId)) {
        return $true
    }
    return (Test-PrometheusHttpOk -Url (Get-PrometheusUrl -Port $Port -Path $Path) -TimeoutSec 2)
}

function Start-PrometheusProcess {
    param([string]$PidFile, [string]$LogFile, [string]$FilePath, [string[]]$Arguments)
    $dir = Split-Path -Parent $LogFile
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $LogFile)) {
        New-Item -ItemType File -Path $LogFile -Force | Out-Null
    }
    $argString = ($Arguments | ForEach-Object {
            if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
        }) -join " "
    $errFile = "$LogFile.err"
    if (-not (Test-Path -LiteralPath $errFile)) {
        New-Item -ItemType File -Path $errFile -Force | Out-Null
    }
    $proc = Start-Process -FilePath $FilePath -ArgumentList $argString -WindowStyle Hidden -PassThru -RedirectStandardOutput $LogFile -RedirectStandardError $errFile
    Set-Content -LiteralPath $PidFile -Value $proc.Id
    return $proc.Id
}

function Start-PrometheusLibrary {
    if (Test-PrometheusAlive -PidFile $script:KIWIX_PID_FILE -Port $script:KIWIX_PORT -Path $script:KIWIX_HEALTH_PATH) {
        Write-PrometheusLog -Level INFO -Message "kiwix-serve is already running"
        return $true
    }
    Resolve-KiwixServe
    $zims = Get-PrometheusZims
    if ($zims.Count -eq 0) {
        Exit-PrometheusError "no .zim files in $($script:LIBRARY_DIR); cannot start the library"
    }
    $log = Join-Path $script:LOG_DIR "kiwix-serve.log"
    Write-PrometheusLog -Level INFO -Message "starting kiwix-serve on port $($script:KIWIX_PORT) with $($zims.Count) ZIM file(s)"
    $args = @("--port", $script:KIWIX_PORT, "--address", $script:PROMETHEUS_BIND) + @($zims.FullName)
    Start-PrometheusProcess -PidFile $script:KIWIX_PID_FILE -LogFile $log -FilePath $script:KIWIX_SERVE -Arguments $args | Out-Null
    if (-not (Wait-PrometheusHealthy -Name "kiwix-serve" -Port $script:KIWIX_PORT -Path $script:KIWIX_HEALTH_PATH -TimeoutSec ([int]$script:HEALTH_TIMEOUT_SEC))) {
        Write-PrometheusLog -Level ERROR -Message "kiwix-serve failed to start; see $log"
        return $false
    }
    return $true
}

function Get-PrometheusRamGb {
    if ($env:PROMETHEUS_RAM_GB) { return [int]$env:PROMETHEUS_RAM_GB }
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    return [int][Math]::Floor($cs.TotalPhysicalMemory / 1GB)
}

function Get-PrometheusGpu {
    if ($env:PROMETHEUS_FORCE_GPU -ne $null -and $env:PROMETHEUS_FORCE_GPU -ne "") {
        $script:PROMETHEUS_HAS_DISCRETE_GPU = [int]$env:PROMETHEUS_FORCE_GPU
        $script:PROMETHEUS_GPU_NOTE = "forced ($($env:PROMETHEUS_FORCE_GPU))"
        return
    }
    $script:PROMETHEUS_HAS_DISCRETE_GPU = 0
    $script:PROMETHEUS_GPU_NOTE = "none detected"
    try {
        $cards = @(Get-CimInstance -ClassName Win32_VideoController)
        foreach ($card in $cards) {
            $name = [string]$card.Name
            if ($name -match 'NVIDIA|GeForce|AMD|Radeon|Intel Arc') {
                $script:PROMETHEUS_HAS_DISCRETE_GPU = 1
                $script:PROMETHEUS_GPU_NOTE = $name
                return
            }
            if ($name) { $script:PROMETHEUS_GPU_NOTE = $name }
        }
    }
    catch {
        $script:PROMETHEUS_GPU_NOTE = "detection failed"
    }
}

function Select-PrometheusTier {
    $ramGb = Get-PrometheusRamGb
    Get-PrometheusGpu
    Write-PrometheusLog -Level INFO -Message "hardware: RAM=${ramGb} GiB, gpu=$($script:PROMETHEUS_GPU_NOTE)"
    if ($ramGb -ge [int]$script:HIGH_MIN_RAM_GB) {
        if ($script:HIGH_REQUIRES_DISCRETE_GPU -ne "1" -or $script:PROMETHEUS_HAS_DISCRETE_GPU -eq 1) {
            return "high"
        }
    }
    if ($ramGb -ge [int]$script:MID_MIN_RAM_GB) { return "mid" }
    if ($script:PROMETHEUS_HAS_DISCRETE_GPU -eq 1 -and $ramGb -ge [int]$script:MID_GPU_MIN_RAM_GB) { return "mid" }
    if ($ramGb -ge [int]$script:LOW_MIN_RAM_GB) { return "low" }
    return "none"
}

function Find-PrometheusModel {
    param([string]$Tier)
    $dir = Join-Path $script:MODELS_DIR $Tier
    $script:MODEL_BIN = $null
    $script:MODEL_KIND = $null
    if (-not (Test-Path -LiteralPath $dir)) { return $false }
    $llama = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -like "*.llamafile" -or $_.Name -like "*.llamafile.exe" })
    if ($llama.Count -gt 0) {
        $script:MODEL_BIN = $llama[0].FullName
        $script:MODEL_KIND = "llamafile"
        return $true
    }
    $gguf = @(Get-ChildItem -LiteralPath $dir -File -Filter *.gguf)
    if ($gguf.Count -gt 0) {
        $script:MODEL_BIN = $gguf[0].FullName
        $script:MODEL_KIND = "gguf"
        return $true
    }
    return $false
}

function Resolve-PrometheusTierModel {
    param([string]$Preferred)
    $order = @($Preferred, "mid", "low") | Select-Object -Unique
    foreach ($candidate in $order) {
        if (Find-PrometheusModel -Tier $candidate) {
            $script:SELECTED_TIER = $candidate
            return $true
        }
    }
    $script:SELECTED_TIER = $null
    $script:MODEL_BIN = $null
    $script:MODEL_KIND = $null
    return $false
}

function Test-PrometheusLibraryHealthy {
    return (Test-PrometheusHttpOk -Url (Get-PrometheusUrl -Port $script:KIWIX_PORT -Path $script:KIWIX_HEALTH_PATH) -TimeoutSec 3)
}

function Start-PrometheusLlamafile {
    param([string]$Tier)
    if (Test-PrometheusAlive -PidFile $script:LLAMAFILE_PID_FILE -Port $script:LLAMAFILE_PORT -Path $script:LLAMAFILE_HEALTH_PATH) {
        Write-PrometheusLog -Level INFO -Message "llamafile is already running"
        return $true
    }
    if (-not (Resolve-PrometheusTierModel -Preferred $Tier)) {
        Write-PrometheusLog -Level ERROR -Message "no llamafile or GGUF found for tier '$Tier' (looked in $($script:MODELS_DIR)\{$Tier,mid,low})"
        return $false
    }
    $filePath = $script:MODEL_BIN
    $extra = @()
    if ($script:MODEL_KIND -eq "gguf") {
        if (-not (Resolve-LlamafileRuntime)) {
            Write-PrometheusLog -Level ERROR -Message "found $($script:MODEL_BIN) but no llamafile runtime in $($script:APPS_DIR)"
            return $false
        }
        $filePath = $script:LLAMAFILE
        $extra = @("-m", $script:MODEL_BIN)
    }
    $argTokens = @()
    if ($script:LLAMAFILE_ARGS) {
        $argTokens = $script:LLAMAFILE_ARGS.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
    }
    $args = $extra + $argTokens + @("--host", $script:PROMETHEUS_BIND, "--port", $script:LLAMAFILE_PORT)
    $log = Join-Path $script:LOG_DIR "llamafile.log"
    Write-PrometheusLog -Level INFO -Message "starting llamafile tier=$($script:SELECTED_TIER) kind=$($script:MODEL_KIND) port=$($script:LLAMAFILE_PORT) model=$($script:MODEL_BIN)"
    Start-PrometheusProcess -PidFile $script:LLAMAFILE_PID_FILE -LogFile $log -FilePath $filePath -Arguments $args | Out-Null
    if (-not (Wait-PrometheusHealthy -Name "llamafile" -Port $script:LLAMAFILE_PORT -Path $script:LLAMAFILE_HEALTH_PATH -TimeoutSec ([int]$script:HEALTH_TIMEOUT_SEC))) {
        Write-PrometheusLog -Level ERROR -Message "llamafile failed to start; see $log. The library is unaffected."
        return $false
    }
    return $true
}

function Start-PrometheusRag {
    if (-not $script:RAG_SERVER) {
        Write-PrometheusLog -Level INFO -Message "RAG server not configured; skipping (library and llamafile stay up)"
        return $true
    }
    if (Test-PrometheusAlive -PidFile $script:RAG_PID_FILE -Port $script:RAG_PORT -Path $script:RAG_HEALTH_PATH) {
        Write-PrometheusLog -Level INFO -Message "RAG server is already running"
        return $true
    }
    $rag = Get-PrometheusAbs $script:RAG_SERVER
    if (-not (Test-Path -LiteralPath $rag)) {
        Write-PrometheusLog -Level ERROR -Message "RAG_SERVER not found: $rag; leaving library and llamafile up"
        return $false
    }
    $log = Join-Path $script:LOG_DIR "rag.log"
    Write-PrometheusLog -Level INFO -Message "starting RAG server on port $($script:RAG_PORT)"
    $args = @("--port", $script:RAG_PORT, "--host", $script:PROMETHEUS_BIND)
    Start-PrometheusProcess -PidFile $script:RAG_PID_FILE -LogFile $log -FilePath $rag -Arguments $args | Out-Null
    if (-not (Wait-PrometheusHealthy -Name "RAG" -Port $script:RAG_PORT -Path $script:RAG_HEALTH_PATH -TimeoutSec ([int]$script:HEALTH_TIMEOUT_SEC))) {
        Write-PrometheusLog -Level ERROR -Message "RAG server failed to start; see $log. The library and llamafile are unaffected."
        return $false
    }
    return $true
}

function Start-PrometheusAi {
    param([string]$Tier)
    if (-not (Test-PrometheusLibraryHealthy)) {
        $url = Get-PrometheusUrl -Port $script:KIWIX_PORT -Path $script:KIWIX_HEALTH_PATH
        Write-PrometheusLog -Level ERROR -Message "library is not healthy at $url; start it first with start-library. AI was not started."
        return 2
    }
    if (-not (Start-PrometheusLlamafile -Tier $Tier)) {
        return 1
    }
    [void](Start-PrometheusRag)
    return 0
}

function Stop-PrometheusPid {
    param([string]$Name, [string]$PidFile)
    $procId = Get-PrometheusPid -File $PidFile
    if (-not $procId) {
        Write-PrometheusLog -Level INFO -Message "${Name}: no PID file; already stopped"
        if (Test-Path -LiteralPath $PidFile) { Remove-Item -LiteralPath $PidFile -Force }
        return $true
    }
    if (-not (Test-PrometheusPidRunning -ProcessId $procId)) {
        Write-PrometheusLog -Level INFO -Message "${Name}: stale PID $procId; removing"
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    Write-PrometheusLog -Level INFO -Message "${Name}: stopping PID $procId"
    try { Stop-Process -Id $procId -ErrorAction Stop } catch { }
    for ($i = 0; $i -lt 10; $i++) {
        if (-not (Test-PrometheusPidRunning -ProcessId $procId)) {
            Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
            Write-PrometheusLog -Level INFO -Message "${Name}: stopped"
            return $true
        }
        Start-Sleep -Milliseconds 200
    }
    Write-PrometheusLog -Level INFO -Message "${Name}: still running, sending KILL"
    try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Milliseconds 200
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    if (Test-PrometheusPidRunning -ProcessId $procId) {
        Write-PrometheusLog -Level ERROR -Message "${Name}: PID $procId survived KILL"
        return $false
    }
    Write-PrometheusLog -Level INFO -Message "${Name}: stopped"
    return $true
}

function Stop-PrometheusAll {
    $ok = $true
    if (-not (Stop-PrometheusPid -Name "RAG" -PidFile $script:RAG_PID_FILE)) { $ok = $false }
    if (-not (Stop-PrometheusPid -Name "llamafile" -PidFile $script:LLAMAFILE_PID_FILE)) { $ok = $false }
    if (-not (Stop-PrometheusPid -Name "kiwix-serve" -PidFile $script:KIWIX_PID_FILE)) { $ok = $false }
    if (Test-PrometheusLibraryHealthy) {
        Write-PrometheusLog -Level ERROR -Message "kiwix-serve still answers HTTP after stop (not started by these scripts, or PID file missing?)"
        $ok = $false
    }
    if ($ok) {
        Write-PrometheusLog -Level INFO -Message "all Prometheus services are stopped"
    }
    return $ok
}

function Initialize-Prometheus {
    $script:PROMETHEUS_ROOT = Get-PrometheusRoot
    Read-PrometheusConfig
    Set-PrometheusDefaults
    Initialize-PrometheusRuntime
    $hostconfLib = Join-Path $script:PROMETHEUS_ROOT "scripts\lib\hostconf.ps1"
    if (Test-Path -LiteralPath $hostconfLib) {
        . $hostconfLib
        Read-PrometheusHostConf
        Write-PrometheusLog -Level INFO -Message "drive root: $($script:PROMETHEUS_ROOT)"
        Write-PrometheusLog -Level INFO -Message "host: $(Get-PrometheusHostname) (host.conf section $($script:HOSTCONF_SECTION))"
    }
    else {
        Write-PrometheusLog -Level INFO -Message "drive root: $($script:PROMETHEUS_ROOT)"
    }
}

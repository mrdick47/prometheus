# Off-drive wrapper installed by install-schedule.ps1. Locates a
# PROMETHEUS volume and runs scripts\update.ps1. Exits 0 if the drive
# is not mounted.
param()
$ErrorActionPreference = "Stop"
$Label = "PROMETHEUS"
# install-schedule.ps1 rewrites the next line.
$RecordedRoot = ""

function Try-RunUpdate([string]$Root) {
    if (-not $Root) { return $false }
    $upd = Join-Path $Root "scripts\update.ps1"
    if (Test-Path -LiteralPath $upd) {
        & $upd @args
        exit $LASTEXITCODE
    }
    return $false
}

if ($env:PROMETHEUS_ROOT) { [void](Try-RunUpdate $env:PROMETHEUS_ROOT) }
if ($RecordedRoot) { [void](Try-RunUpdate $RecordedRoot) }

# Search drive letters for the PROMETHEUS volume label.
Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq $Label } | ForEach-Object {
    if ($_.DriveLetter) {
        [void](Try-RunUpdate "$($_.DriveLetter):\")
    }
}
Get-PSDrive -PSType FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
    $root = $_.Root
    $upd = Join-Path $root "scripts\update.ps1"
    if ((Test-Path -LiteralPath $upd) -and (Test-Path -LiteralPath (Join-Path $root "config\prometheus.conf"))) {
        [void](Try-RunUpdate $root)
    }
}

exit 0

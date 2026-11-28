# Clone finished indexes (and optionally ZIMs) from this drive to another: index.ps1 clone.
# Usage: .\scripts\clone-drive.ps1 --to <target drive root> [--plan] [--with-content] [--layout shared] [source ...]
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $ScriptDir 'index.ps1') clone @args
exit $LASTEXITCODE

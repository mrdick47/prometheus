# Prometheus indexer entry point (Windows). Finds the drive root from its own path.
# Usage: .\scripts\index.ps1 build|update|rebuild|verify|status|remove|query|pause|resume|cancel|jobs <source|all> [options]
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ScriptDir
$Py = $env:PROMETHEUS_PYTHON
if (-not $Py) {
  $venv = Join-Path $Root 'run\venv-index\Scripts\python.exe'
  if (Test-Path $venv) { $Py = $venv }
  elseif (Get-Command python -ErrorAction SilentlyContinue) { $Py = 'python' }
  elseif (Get-Command py -ErrorAction SilentlyContinue) { $Py = 'py' }
  else { Write-Error 'index: Python 3.9+ not found'; exit 2 }
}
$env:PYTHONPATH = if ($env:PYTHONPATH) { "$ScriptDir;$env:PYTHONPATH" } else { $ScriptDir }
& $Py -m prometheus_index @args
exit $LASTEXITCODE

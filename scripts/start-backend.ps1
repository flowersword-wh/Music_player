param(
  [switch]$Install,
  [string]$Proxy = "http://127.0.0.1:7890",
  [int]$Port = 8000
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$backendRoot = Join-Path $projectRoot 'backend'
$venvRoot = Join-Path $backendRoot '.venv'
$pythonPath = Join-Path $venvRoot 'Scripts\python.exe'
$requirementsPath = Join-Path $backendRoot 'requirements.txt'
$databasePath = Join-Path $projectRoot 'cache.db'

if (-not (Test-Path -LiteralPath $backendRoot)) {
  throw "Backend directory not found: $backendRoot"
}

if (-not (Test-Path -LiteralPath $pythonPath)) {
  $pythonCommand = Get-Command py -ErrorAction SilentlyContinue
  if ($null -eq $pythonCommand) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
  }
  if ($null -eq $pythonCommand) {
    throw 'Python 3 is required. Install Python and add it to PATH.'
  }
  Write-Host 'Creating backend virtual environment...'
  & $pythonCommand.Source -m venv $venvRoot
}

if ($Install -or -not (Test-Path -LiteralPath (Join-Path $venvRoot 'Scripts\uvicorn.exe'))) {
  Write-Host 'Installing backend dependencies...'
  & $pythonPath -m pip install -r $requirementsPath
}

$env:MUSIC_PLAYER_DB = $databasePath
$env:BILIBILI_PROXY = $Proxy

Write-Host "Starting Music Player backend on http://127.0.0.1:$Port"
if ($Proxy) {
  Write-Host "Bilibili proxy: $Proxy"
} else {
  Write-Host 'Bilibili proxy: disabled'
}

Push-Location $backendRoot
try {
  & $pythonPath -m uvicorn app:app --host 0.0.0.0 --port $Port
} finally {
  Pop-Location
}

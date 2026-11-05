# Local debug launch (NO install/push). Runs strengthened SimpleTree build.
$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot '..\apps\windows\GitDeck\bin\x64\Debug\net10.0-windows10.0.19041.0\win-x64\GitDeck.exe'
# Also support running from repo root via full relative path used previously
if (-not (Test-Path $exe)) {
  $exe = Join-Path $PSScriptRoot 'apps\windows\GitDeck\bin\x64\Debug\net10.0-windows10.0.19041.0\win-x64\GitDeck.exe'
}
if (-not (Test-Path $exe)) {
  Write-Host "Build missing: $exe" -ForegroundColor Red
  Read-Host 'Press Enter to close'
  exit 1
}
Write-Host "Starting: $exe"
Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe)
Write-Host 'GitDeck launched. You can close this window.'
Start-Sleep -Seconds 2

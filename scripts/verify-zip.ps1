param([string]$Version = "1.0.11")
$ErrorActionPreference = "Stop"
$projectRoot = (Get-Item $PSScriptRoot).Parent.FullName
$zipPath = Join-Path $projectRoot "dist\LocalHub-$Version.zip"
$verifyDir = Join-Path $projectRoot "dist\verify"

if (Test-Path $verifyDir) { Remove-Item $verifyDir -Recurse -Force }
Expand-Archive -Path $zipPath -DestinationPath $verifyDir -Force

Write-Host "`n=== Release icerigi ===" -ForegroundColor Cyan
Get-ChildItem -Recurse $verifyDir | Select-Object FullName, @{N='SizeKB';E={[math]::Round($_.Length/1KB,1)}} | Format-Table -AutoSize

Write-Host "`n=== updater/ klasoru ===" -ForegroundColor Yellow
$updaterDir = Join-Path $verifyDir "updater"
if (Test-Path $updaterDir) {
  Get-ChildItem -Recurse $updaterDir | Select-Object FullName, @{N='SizeKB';E={[math]::Round($_.Length/1KB,1)}} | Format-Table -AutoSize
} else {
  Write-Warning "updater/ klasoru bulunamadi!"
}

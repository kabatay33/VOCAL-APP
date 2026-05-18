param([string]$Version = "1.0.15")
$projectRoot = (Get-Item $PSScriptRoot).Parent.FullName
$zipPath = Join-Path $projectRoot "dist\LocalHub-$Version.zip"
$verifyDir = Join-Path $projectRoot "dist\_verify"

if (Test-Path $verifyDir) { Remove-Item $verifyDir -Recurse -Force }
Expand-Archive -Path $zipPath -DestinationPath $verifyDir -Force

Write-Host "=== Release Icerigi ===" -ForegroundColor Cyan
Get-ChildItem $verifyDir -File | Select-Object Name, @{N='SizeKB';E={[math]::Round($_.Length/1KB,1)}} | Format-Table -AutoSize

Write-Host "`n=== updater/ Klasoru ===" -ForegroundColor Yellow
$updaterDir = Join-Path $verifyDir "updater"
if (Test-Path $updaterDir) {
  Get-ChildItem $updaterDir -Recurse -File | Select-Object FullName, @{N='SizeKB';E={[math]::Round($_.Length/1KB,1)}} | Format-Table -AutoSize
} else {
  Write-Host "updater/ KLASORU YOK!" -ForegroundColor Red
}

Write-Host "`n=== updater/data/app.so ===" -ForegroundColor Green
$appSo = Join-Path $updaterDir "data\app.so"
if (Test-Path $appSo) {
  $f = Get-Item $appSo
  Write-Host "app.so: $([math]::Round($f.Length/1MB,2)) MB - $($f.LastWriteTime)"
} else {
  Write-Host "app.so BULUNAMADI!" -ForegroundColor Red
}

# Temizlik
Remove-Item $verifyDir -Recurse -Force

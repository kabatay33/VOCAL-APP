$ErrorActionPreference = "Stop"
$projectRoot = (Get-Item $PSScriptRoot).Parent.FullName
$releaseDir = Join-Path $projectRoot "flutter_app\build\windows\x64\runner\Release"

# playit.exe
$playitSrc = Join-Path $projectRoot "flutter_app\windows\tunnel_native\playit\playit.exe"
$playitDst = Join-Path $releaseDir "playit.exe"
if (Test-Path $playitSrc) {
    Copy-Item -Path $playitSrc -Destination $playitDst -Force
    Write-Host "playit.exe kopyalandı"
} else {
    Write-Warning "playit.exe bulunamadı"
}

# updater.exe (vocal_updater.exe -> updater.exe)
$updaterSrc = Join-Path $projectRoot "updater\build\windows\x64\runner\Release\vocal_updater.exe"
$updaterDst = Join-Path $releaseDir "updater.exe"
if (Test-Path $updaterSrc) {
    Copy-Item -Path $updaterSrc -Destination $updaterDst -Force
    Write-Host "updater.exe kopyalandı"
} else {
    Write-Warning "updater.exe bulunamadı"
}

# version.txt
Set-Content -Path "$releaseDir\version.txt" -Value "1.0.7+11" -NoNewline
Write-Host "version.txt yazıldı"

# List exe files
Get-ChildItem "$releaseDir\*.exe" | ForEach-Object {
    Write-Host "  $($_.Name): $([math]::Round($_.Length/1MB,2)) MB"
}

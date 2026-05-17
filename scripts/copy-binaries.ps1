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

# updater.exe -> updater/ alt klasörüne kopyala (flutter_windows.dll çakışmasını önle)
$updaterDir = Join-Path $releaseDir "updater"
New-Item -ItemType Directory -Force -Path $updaterDir | Out-Null

# Updater exe
$updaterSrc = Join-Path $projectRoot "updater\build\windows\x64\runner\Release\vocal_updater.exe"
$updaterDst = Join-Path $updaterDir "updater.exe"
if (Test-Path $updaterSrc) {
    Copy-Item -Path $updaterSrc -Destination $updaterDst -Force
    Write-Host "updater.exe kopyalandı"
} else {
    Write-Warning "updater.exe bulunamadı"
}

# Updater'ın tüm bağımlılıklarını kopyala (DLL'ler, data/ klasörü vb.)
$updaterBuildDir = Split-Path $updaterSrc -Parent
Get-ChildItem $updaterBuildDir -File | Where-Object { $_.Name -ne "vocal_updater.exe" } | ForEach-Object {
    $dest = Join-Path $updaterDir $_.Name
    Copy-Item -Path $_.FullName -Destination $dest -Force
}
# data/ klasörünü de kopyala
$dataSrc = Join-Path $updaterBuildDir "data"
if (Test-Path $dataSrc) {
    Copy-Item -Path $dataSrc -Destination "$updaterDir\data" -Recurse -Force
    Write-Host "data/ kopyalandı"
}

Write-Host "Updater klasörü: $updaterDir"
Get-ChildItem $updaterDir -Recurse -File | Select-Object FullName, @{N='SizeKB';E={[math]::Round($_.Length/1KB,1)}} | Format-Table -AutoSize

# version.txt
Set-Content -Path "$releaseDir\version.txt" -Value "1.0.10+14" -NoNewline
Write-Host "version.txt yazıldı"

param([string]$Version = "1.0.13")
$ErrorActionPreference = "Stop"
$projectRoot = (Get-Item $PSScriptRoot).Parent.FullName
$releaseDir = Join-Path $projectRoot 'flutter_app\build\windows\x64\runner\Release'
$updaterBuildDir = Join-Path $projectRoot 'updater\build\windows\x64\runner\Release'
$updaterReleaseDir = Join-Path $releaseDir 'updater'
$distDir = Join-Path $projectRoot 'dist'
$zipOut = Join-Path $distDir "LocalHub-$Version.zip"

New-Item -ItemType Directory -Force -Path $distDir | Out-Null
New-Item -ItemType Directory -Force -Path $updaterReleaseDir | Out-Null

# Updater dosyalarini kopyala
Copy-Item (Join-Path $updaterBuildDir 'vocal_updater.exe') (Join-Path $updaterReleaseDir 'updater.exe') -Force
Copy-Item (Join-Path $updaterBuildDir 'flutter_windows.dll') (Join-Path $updaterReleaseDir 'flutter_windows.dll') -Force
Copy-Item (Join-Path $updaterBuildDir 'icudtl.dat') (Join-Path $updaterReleaseDir 'icudtl.dat') -Force
$dataSrc = Join-Path $updaterBuildDir 'data'
if (Test-Path $dataSrc) {
  Copy-Item $dataSrc "$updaterReleaseDir\data" -Recurse -Force
}

# version.txt
Set-Content -Path "$releaseDir\version.txt" -Value $Version -NoNewline

# playit.exe varsa sil
$playitExe = Join-Path $releaseDir 'playit.exe'
if (Test-Path $playitExe) { Remove-Item $playitExe -Force }

# Zip
if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipOut -Force
$zipSize = [math]::Round((Get-Item $zipOut).Length / 1MB, 2)
Write-Host "Zip hazir: $zipOut ($zipSize MB)"

# GitHub release
$ghArgs = @(
  'release', 'create',
  "v$Version",
  $zipOut,
  '--title', "LocalHub v$Version",
  '--notes', "LocalHub v$Version`n`nYenilikler:`n- Updater GUI duzeltmesi (Radmin VPN kontrolu, otomatik baslatma)`n- Playit.gg tamamen kaldirildi`n- Radmin VPN entegrasyonu (IP bazli sunucu sistemi)`n- Sunucu ekleme: Radmin VPN IP adresi ile"
)
& gh @ghArgs
if ($LASTEXITCODE -ne 0) { Write-Error "gh release create basarisiz" }

Write-Host "`n[OK] Release yayinlandi: v$Version"
Write-Host "  URL: https://github.com/kabatay33/LocalHub/releases/tag/v$Version"

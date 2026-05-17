# VOCAL-APP Release Build & GitHub Publish Script
# Kullanim: .\scripts\build-release.ps1 -Version 1.0.3

param(
  [Parameter(Mandatory=$true)]
  [string]$Version
)

$ErrorActionPreference = "Stop"

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  Write-Error "Gecersiz surum formati. Ornek: 1.0.3"
  exit 1
}

$projectRoot = (Get-Item $PSScriptRoot).Parent.FullName
$flutterDir = Join-Path $projectRoot 'flutter_app'
$updaterDir = Join-Path $projectRoot 'updater'
$releaseDir = Join-Path $flutterDir 'build\windows\x64\runner\Release'
$distDir = Join-Path $projectRoot 'dist'
$zipOut = Join-Path $distDir "VOCAL-APP-$Version.zip"

New-Item -ItemType Directory -Force -Path $distDir | Out-Null

# 1) pubspec.yaml version guncelle
$pubspecPath = Join-Path $flutterDir 'pubspec.yaml'
$pubspec = Get-Content $pubspecPath -Raw -Encoding UTF8
if ($pubspec -match 'version:\s+(\d+\.\d+\.\d+)\+(\d+)') {
  $oldBuild = [int]$Matches[2]
  $newBuild = $oldBuild + 1
  $newVersionLine = "version: $Version+$newBuild"
  $pubspec = $pubspec -replace 'version:\s+\d+\.\d+\.\d+\+\d+', $newVersionLine
  Set-Content -Path $pubspecPath -Value $pubspec -NoNewline -Encoding UTF8
  Write-Host "pubspec.yaml: version $Version+$newBuild olarak guncellendi"
}

# 2) Updater - PowerShell/BAT (Flutter yerine native script)
Write-Host "`nUpdater (PowerShell/BAT) hazirlaniyor..."
$updaterBatSrc = Join-Path $updaterDir 'bin\vocal_updater.bat'
$updaterPs1Src = Join-Path $updaterDir 'bin\vocal_updater.ps1'

if (-not (Test-Path $updaterBatSrc)) { Write-Error "vocal_updater.bat bulunamadi!" }
if (-not (Test-Path $updaterPs1Src)) { Write-Error "vocal_updater.ps1 bulunamadi!" }

# 2.5) Updater dosyalarini GECICI bir dizine yedekle
$updaterTempDir = Join-Path $projectRoot "dist\_updater_staging"
if (Test-Path $updaterTempDir) { Remove-Item $updaterTempDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $updaterTempDir | Out-Null

Copy-Item -Path $updaterBatSrc -Destination (Join-Path $updaterTempDir "updater.bat") -Force
Copy-Item -Path $updaterPs1Src -Destination (Join-Path $updaterTempDir "updater.ps1") -Force
Write-Host "Updater dosyalar� gecici dizine yedeklendi"

# 3) Ana Flutter release build
Write-Host "`nFlutter Windows release build aliniyor..."
Push-Location $flutterDir
try {
  & flutter build windows --release
  if ($LASTEXITCODE -ne 0) {
    Write-Error "Flutter build hatasi"
    exit 1
  }
} finally {
  Pop-Location
}

# 3.5) Updater dosyalarini gecici dizinden release'e kopyala
# Ana app build edildikten sonra updater build klasoru kirletilmis olabilir.
# Gecici yedekten kopyalayarak temiz updater dosyalarini elde ediyoruz.
$updaterReleaseDir = Join-Path $releaseDir "updater"
New-Item -ItemType Directory -Force -Path $updaterReleaseDir | Out-Null

if (Test-Path $updaterTempDir) {
  Get-ChildItem $updaterTempDir -File | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $updaterReleaseDir $_.Name) -Force
  }
  $dataStaging = Join-Path $updaterTempDir "data"
  if (Test-Path $dataStaging) {
    $destDataRelease = Join-Path $updaterReleaseDir "data"
    if (Test-Path $destDataRelease) { Remove-Item $destDataRelease -Recurse -Force }
    Copy-Item -Path $dataStaging -Destination $destDataRelease -Recurse -Force
  }
  Write-Host "Updater dosyarlari gecici dizinden release'e kopyaland� (temiz)"
} else {
  Write-Warning "Gecici updater dizini bulunamadi!"
}

# Temizlik
if (Test-Path $updaterTempDir) { Remove-Item $updaterTempDir -Recurse -Force }

if (-not (Test-Path $releaseDir)) {
  Write-Error "Release klasoru bulunamadi: $releaseDir"
  exit 1
}

# 4) version.txt yaz
Set-Content -Path "$releaseDir\version.txt" -Value "$Version" -NoNewline
Write-Host "version.txt: $Version"

# 4.5) Ana dizindeki updater.exe'yi kaldir (eski sürümden kalmis olabilir)
$rootUpdater = Join-Path $releaseDir "updater.exe"
if (Test-Path $rootUpdater) {
  Remove-Item $rootUpdater -Force
  Write-Host "Ana dizindeki updater.exe kaldirildi"
}

# 5) Zip olustur
Write-Host "`nZip olusturuluyor: $zipOut"
if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipOut -Force
$zipSize = [math]::Round((Get-Item $zipOut).Length / 1MB, 2)
Write-Host "Zip hazir: $zipSize MB"

# 6) GitHub release olustur
Write-Host "`nGitHub Release olusturuluyor: v$Version"
$ghArgs = @(
  'release', 'create',
  "v$Version",
  $zipOut,
  '--title', "VOCAL-APP v$Version",
  '--notes', "VOCAL-APP v$Version"
)

& gh @ghArgs

if ($LASTEXITCODE -ne 0) {
  Write-Error "gh release create basarisiz"
  exit 1
}

Write-Host "`n[OK] Release yayinlandi: v$Version"
Write-Host "  Zip: $zipOut ($zipSize MB)"
Write-Host "  URL: https://github.com/kabatay33/VOCAL-APP/releases/tag/v$Version"

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

# 2) Updater build
Write-Host "`nUpdater build aliniyor..."
$updaterBuildDir = Join-Path $updaterDir 'build\windows\x64\runner\Release'
$updaterNativeAssets = Join-Path $updaterDir 'build\native_assets\windows'
if (-not (Test-Path $updaterNativeAssets)) {
  New-Item -ItemType Directory -Force -Path $updaterNativeAssets | Out-Null
}
Push-Location $updaterDir
try {
  & flutter build windows --release
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "Flutter updater build hatasi (devam ediliyor)"
  }
} finally {
  Pop-Location
}

# Updater build dosyalarini el ile kopyala (CMake install bazen basarisiz oluyor)
# ONCE mevcut data/ klasoru temizlenir (ic ice kopyalama sorununu onlemek icin)
$updaterAppSo = Join-Path $updaterDir 'build\windows\app.so'
$updaterFlutterAssets = Join-Path $updaterDir 'build\flutter_assets'
if (Test-Path $updaterBuildDir) {
  $destData = Join-Path $updaterBuildDir 'data'
  # data/ klasoru varsa temizle (ic ice data/data/ sorununu onlemek icin)
  if (Test-Path $destData) { Remove-Item $destData -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $destData | Out-Null

  if (Test-Path $updaterAppSo) {
    Copy-Item -Path $updaterAppSo -Destination (Join-Path $destData 'app.so') -Force
  }
  if (Test-Path $updaterFlutterAssets) {
    Copy-Item -Path $updaterFlutterAssets -Destination (Join-Path $destData 'flutter_assets') -Recurse -Force
  }
  # icudtl.dat Flutter build'de updaterBuildDir'a kopyalanir
  # (CMake install basarisiz olsa bile bu dosya oradadir)
  Write-Host "Updater build dosyalar� kopyaland� (temiz)"
}

# 2.5) Updater dosyalarini GECICI bir dizine yedekle
# NOT: Ana app build edildikten sonra updater build klasoru kirletilebilir!
# Bu yuzden updater dosyalarini once gecici bir dizine yedekliyoruz.
$updaterTempDir = Join-Path $projectRoot "dist\_updater_staging"
if (Test-Path $updaterTempDir) { Remove-Item $updaterTempDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $updaterTempDir | Out-Null

if (Test-Path $updaterBuildDir) {
  $exeSrc = Join-Path $updaterBuildDir "vocal_updater.exe"
  if (Test-Path $exeSrc) {
    Copy-Item -Path $exeSrc -Destination (Join-Path $updaterTempDir "updater.exe") -Force
  }
  $dllSrc = Join-Path $updaterBuildDir "flutter_windows.dll"
  if (Test-Path $dllSrc) {
    Copy-Item -Path $dllSrc -Destination (Join-Path $updaterTempDir "flutter_windows.dll") -Force
  }
  $icuSrc = Join-Path $updaterBuildDir "icudtl.dat"
  if (Test-Path $icuSrc) {
    Copy-Item -Path $icuSrc -Destination (Join-Path $updaterTempDir "icudtl.dat") -Force
  }
  $dataSrc = Join-Path $updaterBuildDir "data"
  if (Test-Path $dataSrc) {
    $destDataStaging = Join-Path $updaterTempDir "data"
    if (Test-Path $destDataStaging) { Remove-Item $destDataStaging -Recurse -Force }
    Copy-Item -Path $dataSrc -Destination $destDataStaging -Recurse -Force
  }
  Write-Host "Updater dosyalar� gecici dizine yedeklendi"
} else {
  Write-Warning "updater build bulunamad�: $updaterBuildDir"
}

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

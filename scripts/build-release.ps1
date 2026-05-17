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

# 2) Updater build (once, before main app)
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
$updaterAppSo = Join-Path $updaterDir 'build\windows\app.so'
$updaterFlutterAssets = Join-Path $updaterDir 'build\flutter_assets'
if (Test-Path $updaterBuildDir) {
  $destData = Join-Path $updaterBuildDir 'data'
  if (Test-Path $updaterAppSo) {
    if (-not (Test-Path $destData)) { New-Item -ItemType Directory -Force -Path $destData | Out-Null }
    Copy-Item -Path $updaterAppSo -Destination (Join-Path $destData 'app.so') -Force
  }
  if (Test-Path $updaterFlutterAssets) {
    if (-not (Test-Path $destData)) { New-Item -ItemType Directory -Force -Path $destData | Out-Null }
    Copy-Item -Path $updaterFlutterAssets -Destination (Join-Path $destData 'flutter_assets') -Recurse -Force
  }
  Write-Host "Updater build dosyalar� kopyaland�"
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

if (-not (Test-Path $releaseDir)) {
  Write-Error "Release klasoru bulunamadi: $releaseDir"
  exit 1
}

# 4) playit.exe kopyala
$playitSrc = Join-Path $projectRoot "flutter_app\windows\tunnel_native\playit\playit.exe"
$playitDst = Join-Path $releaseDir "playit.exe"
if (Test-Path $playitSrc) {
  Copy-Item -Path $playitSrc -Destination $playitDst -Force
  Write-Host "playit.exe kopyaland�"
} else {
  Write-Warning "playit.exe bulunamad�: $playitSrc"
}

# 5) Updater'� alt klas�re kopyala (DLL ve data �ak���mas�n� �nle)
$updaterReleaseDir = Join-Path $releaseDir "updater"
New-Item -ItemType Directory -Force -Path $updaterReleaseDir | Out-Null

if (Test-Path $updaterBuildDir) {
  Get-ChildItem $updaterBuildDir -File | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $updaterReleaseDir $_.Name) -Force
  }
  $dataSrc = Join-Path $updaterBuildDir "data"
  if (Test-Path $dataSrc) {
    Copy-Item -Path $dataSrc -Destination "$updaterReleaseDir\data" -Recurse -Force
  }
  $exeSrc = Join-Path $updaterReleaseDir "vocal_updater.exe"
  $exeDst = Join-Path $updaterReleaseDir "updater.exe"
  if (Test-Path $exeSrc) {
    if (Test-Path $exeDst) { Remove-Item $exeDst -Force }
    Rename-Item -Path $exeSrc -NewName "updater.exe" -Force
  }
  Write-Host "updater/ klas�r� kopyaland�"
} else {
  Write-Warning "updater build bulunamad�: $updaterBuildDir"
}

# 6) version.txt yaz
Set-Content -Path "$releaseDir\version.txt" -Value "$Version" -NoNewline
Write-Host "version.txt: $Version"

# 7) Zip olustur
Write-Host "`nZip olusturuluyor: $zipOut"
if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipOut -Force
$zipSize = [math]::Round((Get-Item $zipOut).Length / 1MB, 2)
Write-Host "Zip hazir: $zipSize MB"

# 8) GitHub release olustur
Write-Host "`nGitHub Release olusturuluyor: v$Version"
$ghArgs = @(
  'release', 'create',
  "v$Version",
  $zipOut,
  '--title', "VOCAL-APP v$Version",
  '--notes', "VOCAL-APP v$Version`n`nYenilikler:`n- Updater GUI duzeltmesi (ayri klasor, DLL/data carpisma duzeltmesi)`n- Cloudflare kaldirildi, sadece playit.gg`n- Backend hazir olunca splash ekrani`n- Update loop duzeltmesi"
)

& gh @ghArgs

if ($LASTEXITCODE -ne 0) {
  Write-Error "gh release create basarisiz"
  exit 1
}

Write-Host "`n[OK] Release yayinlandi: v$Version"
Write-Host "  Zip: $zipOut ($zipSize MB)"
Write-Host "  URL: https://github.com/kabatay33/VOCAL-APP/releases/tag/v$Version"

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

# 2) Flutter release build
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

# 3) playit.exe kopyala
$playitSrc = Join-Path $projectRoot "flutter_app\windows\tunnel_native\playit\playit.exe"
$playitDst = Join-Path $releaseDir "playit.exe"
if (Test-Path $playitSrc) {
  Copy-Item -Path $playitSrc -Destination $playitDst -Force
  Write-Host "playit.exe kopyalandı"
} else {
  Write-Warning "playit.exe bulunamadı: $playitSrc"
}

# 4) Updater'ı kopyala
$updaterSrc = Join-Path $projectRoot "updater\updater.exe"
$updaterDst = Join-Path $releaseDir "updater.exe"
if (Test-Path $updaterSrc) {
  Copy-Item -Path $updaterSrc -Destination $updaterDst -Force
  Write-Host "updater.exe kopyalandı"
} else {
  Write-Warning "updater.exe bulunamadı: $updaterSrc"
}

# 5) version.txt yaz
Set-Content -Path "$releaseDir\version.txt" -Value "$Version" -NoNewline
Write-Host "version.txt: $Version"

# 6) Zip olustur
Write-Host "`nZip olusturuluyor: $zipOut"
if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipOut -Force
$zipSize = [math]::Round((Get-Item $zipOut).Length / 1MB, 2)
Write-Host "Zip hazir: $zipSize MB"

# 7) GitHub release olustur
Write-Host "`nGitHub Release olusturuluyor: v$Version"
$ghArgs = @(
  'release', 'create',
  "v$Version",
  $zipOut,
  '--title', "VOCAL-APP v$Version",
  '--notes', "VOCAL-APP v$Version`n`nYenilikler:`n- Updater GUI programi (Flutter pencere)`n- Cloudflare kaldirildi, sadece playit.gg`n- Backend hazir olunca splash ekrani`n- Update loop duzeltmesi"
)

& gh @ghArgs

if ($LASTEXITCODE -ne 0) {
  Write-Error "gh release create basarisiz"
  exit 1
}

Write-Host "`n[OK] Release yayinlandi: v$Version"
Write-Host "  Zip: $zipOut ($zipSize MB)"
Write-Host "  URL: https://github.com/kabatay33/VOCAL-APP/releases/tag/v$Version"

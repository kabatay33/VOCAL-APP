# VOCAL-APP yeni surum yayinlama scripti (GitHub Releases).
#
# Kullanim:
#   .\scripts\publish-release.ps1 -Version 1.0.20
#   .\scripts\publish-release.ps1 -Version 1.0.20 -NotesFile .\notes.md
#
# Yaptiklari:
#   1) pubspec.yaml'da version'u gunceller
#   2) Updater (dart compile) build alir -> updater.exe
#   3) Flutter Windows release build alir
#   4) updater.exe'yi Release\updater\ icine kopyalar
#   5) version.txt'i Release\ icine yazar
#   6) Release klasorunu zip'ler -> dist\VOCAL-APP-X.Y.Z.zip
#   7) gh release create ile GitHub'a yayinlar
#
# Onkosullar:
#   - gh CLI (auth login yapilmis veya $env:GH_TOKEN ayarli)
#   - Dart SDK PATH'de
#   - Flutter SDK PATH'de
#   - Repo zaten kabatay33/VOCAL-APP remote'una bagli

param(
  [Parameter(Mandatory=$true)]
  [string]$Version,
  [string]$NotesFile = ""
)

$ErrorActionPreference = "Stop"

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  Write-Error "Gecersiz surum formati. Ornek: 1.0.20"
  exit 1
}

$projectRoot = (Get-Item $PSScriptRoot).Parent.FullName
$flutterDir = Join-Path $projectRoot 'flutter_app'
$updaterDir = Join-Path $projectRoot 'updater'
$releaseDir = Join-Path $flutterDir 'build\windows\x64\runner\Release'
$distDir = Join-Path $projectRoot 'dist'
$zipOut = Join-Path $distDir "VOCAL-APP-$Version.zip"

New-Item -ItemType Directory -Force -Path $distDir | Out-Null

# 1) pubspec.yaml version
Write-Host "[1/7] pubspec.yaml version guncelleniyor..."
$pubspecPath = Join-Path $flutterDir 'pubspec.yaml'
$pubspec = Get-Content $pubspecPath -Raw -Encoding UTF8
if ($pubspec -match 'version:\s+(\d+\.\d+\.\d+)\+(\d+)') {
  $oldBuild = [int]$Matches[2]
  $newBuild = $oldBuild + 1
  $pubspec = $pubspec -replace 'version:\s+\d+\.\d+\.\d+\+\d+', "version: $Version+$newBuild"
  Set-Content -Path $pubspecPath -Value $pubspec -NoNewline -Encoding UTF8
  Write-Host "  pubspec: $Version+$newBuild"
} elseif ($pubspec -match 'version:\s+(\d+\.\d+\.\d+)') {
  $pubspec = $pubspec -replace 'version:\s+\d+\.\d+\.\d+', "version: $Version+1"
  Set-Content -Path $pubspecPath -Value $pubspec -NoNewline -Encoding UTF8
  Write-Host "  pubspec: $Version+1"
}

# 2) Updater build (dart compile exe)
Write-Host "`n[2/7] Updater build aliniyor (dart compile)..."
Push-Location $updaterDir
try {
  & dart pub get 2>&1 | Out-Null
  $updaterOut = Join-Path $updaterDir "build\updater.exe"
  New-Item -ItemType Directory -Force -Path (Split-Path $updaterOut -Parent) | Out-Null
  & dart compile exe lib/vocal_updater.dart -o $updaterOut
  if ($LASTEXITCODE -ne 0) {
    Write-Error "Updater build hatasi"
    exit 1
  }
  Write-Host "  updater.exe: $($(Get-Item $updaterOut).Length / 1MB) MB"
} finally {
  Pop-Location
}

# 3) Flutter build
Write-Host "`n[3/7] Flutter Windows release build aliniyor..."
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

# 4) updater.exe Release\updater\ icine kopyalanir
Write-Host "`n[4/7] updater.exe Release klasorune kopyalaniyor..."
$updaterDest = Join-Path $releaseDir "updater"
if (Test-Path $updaterDest) { Remove-Item $updaterDest -Recurse -Force }
New-Item -ItemType Directory -Path $updaterDest | Out-Null
Copy-Item (Join-Path $updaterDir "build\updater.exe") $updaterDest

# 5) version.txt
Write-Host "`n[5/7] version.txt yaziliyor: $Version"
Set-Content -Path (Join-Path $releaseDir "version.txt") -Value $Version -NoNewline -Encoding ASCII

# 6) Zip
Write-Host "`n[6/7] Zip olusturuluyor..."
if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipOut -Force
$zipSize = (Get-Item $zipOut).Length / 1MB
Write-Host "  $zipOut ($($zipSize.ToString('F2')) MB)"

# 7) gh release create
Write-Host "`n[7/7] GitHub Release olusturuluyor: v$Version"
$ghArgs = @('release', 'create', "v$Version", $zipOut, '--title', "v$Version")
if ($NotesFile -and (Test-Path $NotesFile)) {
  $ghArgs += @('--notes-file', $NotesFile)
} else {
  $ghArgs += @('--notes', "VOCAL-APP $Version - Otomatik guncelleme")
}
& gh @ghArgs
if ($LASTEXITCODE -ne 0) {
  Write-Error "gh release create basarisiz"
  exit 1
}

Write-Host "`n[OK] Release yayinlandi: v$Version"
Write-Host "  Zip: $zipOut"
Write-Host "  URL: https://github.com/kabatay33/VOCAL-APP/releases/tag/v$Version"
Write-Host "`nKullanicilar app actiginda updater.exe otomatik guncelleyecek."

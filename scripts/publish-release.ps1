# Yeni surum yayinlama scripti (GitHub Releases tabanli).
#
# Kullanim:
#   .\scripts\publish-release.ps1 -Version 1.0.1
#   .\scripts\publish-release.ps1 -Version 1.0.2 -NotesFile .\notes.md
#
# Yaptiklari:
#   1) pubspec.yaml'da version'u gunceller (X.Y.Z+N formatinda)
#   2) Flutter Windows release build alir
#   3) build/windows/x64/runner/Release klasorunu zip'ler
#   4) gh release create ile GitHub'a yayinlar (tag v$Version, zip asset)
#
# Onkosullar:
#   - gh CLI yuklu ve auth login yapilmis (veya $env:GH_TOKEN ayarli)
#   - Bu repo zaten kabatay33/VOCAL-APP remote'una bagli
#   - Flutter Windows toolchain hazir

param(
  [Parameter(Mandatory=$true)]
  [string]$Version,
  [string]$NotesFile = ""
)

$ErrorActionPreference = "Stop"

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  Write-Error "Gecersiz surum formati. Ornek: 1.0.1"
  exit 1
}

$projectRoot = (Get-Item $PSScriptRoot).Parent.FullName
$flutterDir = Join-Path $projectRoot 'flutter_app'
$releaseDir = Join-Path $flutterDir 'build\windows\x64\runner\Release'
$distDir = Join-Path $projectRoot 'dist'
$zipOut = Join-Path $distDir "VOCAL-APP-$Version.zip"

New-Item -ItemType Directory -Force -Path $distDir | Out-Null

# 1) pubspec.yaml version
$pubspecPath = Join-Path $flutterDir 'pubspec.yaml'
$pubspec = Get-Content $pubspecPath -Raw -Encoding UTF8
if ($pubspec -match 'version:\s+(\d+\.\d+\.\d+)\+(\d+)') {
  $oldBuild = [int]$Matches[2]
  $newBuild = $oldBuild + 1
  $newVersionLine = "version: $Version+$newBuild"
  $pubspec = $pubspec -replace 'version:\s+\d+\.\d+\.\d+\+\d+', $newVersionLine
  Set-Content -Path $pubspecPath -Value $pubspec -NoNewline -Encoding UTF8
  Write-Host "pubspec.yaml: version $Version+$newBuild olarak guncellendi"
} else {
  Write-Warning "pubspec.yaml'da version bulunamadi, manuel guncelle"
}

# 2) Flutter build
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

# 3) Zip
Write-Host "`nZip olusturuluyor: $zipOut"
if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipOut -Force
$zipSize = (Get-Item $zipOut).Length / 1MB
Write-Host "Zip hazir: $($zipSize.ToString('F2')) MB"

# 4) gh release create
Write-Host "`nGitHub Release olusturuluyor: v$Version"
$ghArgs = @(
  'release', 'create',
  "v$Version",
  $zipOut,
  '--title', "v$Version"
)

if ($NotesFile -and (Test-Path $NotesFile)) {
  $ghArgs += @('--notes-file', $NotesFile)
} else {
  $ghArgs += @('--notes', "VOCAL-APP $Version - Otomatik guncelleme ile dagitildi.")
}

& gh @ghArgs

if ($LASTEXITCODE -ne 0) {
  Write-Error "gh release create basarisiz"
  exit 1
}

Write-Host "`n[OK] Release yayinlandi: v$Version"
Write-Host "  Zip: $zipOut"
Write-Host "  URL: https://github.com/kabatay33/VOCAL-APP/releases/tag/v$Version"
Write-Host "`nKullanicilar app actiginda Yeni surum bulundu diyalogu gorecek."

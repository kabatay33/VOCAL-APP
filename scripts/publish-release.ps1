# Yeni sürüm yayınlama scripti (GitHub Releases tabanlı).
#
# Kullanım:
#   .\scripts\publish-release.ps1 -Version 1.0.1
#   .\scripts\publish-release.ps1 -Version 1.0.2 -NotesFile .\notes.md
#
# Yaptıkları:
#   1) pubspec.yaml'da version'u günceller (X.Y.Z+N formatında)
#   2) Flutter Windows release build alır
#   3) build/windows/x64/runner/Release klasörünü zip'ler
#   4) gh release create ile GitHub'a yayınlar (tag v$Version, zip asset)
#
# Önkoşullar:
#   - gh CLI yüklü ve auth login yapılmış
#   - Bu repo zaten kabatay33/VOCAL-APP remote'una bağlı
#   - Flutter Windows toolchain hazır
#
# NOT: Bu script otomatik git commit yapmaz. Önce kendin git add+commit
# yapıp push etmen tavsiye edilir, sonra bu scripti çalıştır.

param(
  [Parameter(Mandatory=$true)]
  [string]$Version,
  [string]$NotesFile = ""
)

$ErrorActionPreference = "Stop"

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  Write-Error "Geçersiz sürüm formatı. Örnek: 1.0.1"
  exit 1
}

$projectRoot = (Get-Item $PSScriptRoot).Parent.FullName
$flutterDir = Join-Path $projectRoot 'flutter_app'
$releaseDir = Join-Path $flutterDir 'build\windows\x64\runner\Release'
$zipOut = Join-Path $projectRoot "dist\VOCAL-APP-$Version.zip"
$distDir = Join-Path $projectRoot 'dist'

New-Item -ItemType Directory -Force -Path $distDir | Out-Null

# 1) pubspec.yaml version'u güncelle (+N build numarası 1 artırılır)
$pubspecPath = Join-Path $flutterDir 'pubspec.yaml'
$pubspec = Get-Content $pubspecPath -Raw
if ($pubspec -match 'version:\s+(\d+\.\d+\.\d+)\+(\d+)') {
  $oldBuild = [int]$Matches[2]
  $newBuild = $oldBuild + 1
  $newVersionLine = "version: $Version+$newBuild"
  $pubspec = $pubspec -replace 'version:\s+\d+\.\d+\.\d+\+\d+', $newVersionLine
  Set-Content -Path $pubspecPath -Value $pubspec -NoNewline
  Write-Host "pubspec.yaml: version $Version+$newBuild olarak güncellendi"
} else {
  Write-Warning "pubspec.yaml'da version bulunamadı, manuel güncelle"
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
  Write-Error "Release klasörü bulunamadı: $releaseDir"
  exit 1
}

# 3) Zip oluştur
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

Write-Host "`n✓ Release yayinlandi: v$Version"
Write-Host "  Zip: $zipOut"
Write-Host "  URL: https://github.com/kabatay33/VOCAL-APP/releases/tag/v$Version"
Write-Host "`nKullanicilar app actiginda 'Yeni surum bulundu' diyalogu gorecek."

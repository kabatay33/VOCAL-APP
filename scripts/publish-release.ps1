# LocalHub yeni surum yayinlama scripti (GitHub Releases).
#
# Kullanim:
#   .\scripts\publish-release.ps1 -Version 1.0.20
#   .\scripts\publish-release.ps1 -Version 1.0.20 -NotesFile .\notes.md
#
# Yaptiklari:
#   1) pubspec.yaml'da version'u gunceller
#   2) Updater (dart compile) build alir -> updater.exe
#   3) Flutter Windows release build alir
#   4) Backend prod deps'lerini hazirlar (npm install --omit=dev)
#   5) updater.exe + backend + version.txt'i Release\ icine kopyalar
#   6) Release klasorunu zip'ler -> dist\LocalHub-X.Y.Z.zip
#   7) gh release create ile GitHub'a yayinlar
#
# Onkosullar:
#   - gh CLI (auth login yapilmis veya $env:GH_TOKEN ayarli)
#   - Dart SDK PATH'de
#   - Flutter SDK PATH'de
#   - Repo zaten kabatay33/LocalHub remote'una bagli

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
$backendDir = Join-Path $projectRoot 'backend'
$releaseDir = Join-Path $flutterDir 'build\windows\x64\runner\Release'
$distDir = Join-Path $projectRoot 'dist'
$zipOut = Join-Path $distDir "LocalHub-$Version.zip"

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

# --- Code Signing yardimcilari ---
$certPath = Join-Path $projectRoot 'installer\cert\LocalHub.pfx'
$certPassword = "LocalHubDev2026!"
$signtool = $null
$signtoolCandidates = @(
  "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe",
  "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe",
  "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.0.22000.0\x64\signtool.exe",
  "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.0.19041.0\x64\signtool.exe",
  "${env:ProgramFiles(x86)}\Windows Kits\10\App Certification Kit\signtool.exe"
)
$signtool = $signtoolCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$canSign = ($signtool -and (Test-Path $certPath))

function Sign-File($filePath) {
  if (-not $canSign) { return $false }
  $args = @('sign',
    '/f', $certPath,
    '/p', $certPassword,
    '/fd', 'SHA256',
    '/td', 'SHA256',
    '/tr', 'http://timestamp.digicert.com',
    '/d', 'LocalHub',
    $filePath)
  & $signtool @args 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "  Imzalama basarisiz: $filePath (exit $LASTEXITCODE)"
    return $false
  }
  return $true
}

# LocalHub.exe'yi imzala (auto-update zip'inde de imzali olsun)
if ($canSign) {
  Write-Host "  Imzalaniyor: LocalHub.exe"
  if (Sign-File (Join-Path $releaseDir "LocalHub.exe")) {
    Write-Host "  LocalHub.exe imzalandi"
  }
} else {
  if (-not $signtool) { Write-Warning "  signtool.exe bulunamadi" }
  if (-not (Test-Path $certPath)) { Write-Warning "  Sertifika yok: $certPath" }
  Write-Warning "  Code signing atlandi - SmartScreen agresif uyarir"
}

# 4) Backend prod deps + bundle (+ portable Node.js)
Write-Host "`n[4/7] Backend bundle + Node.js hazirlaniyor..."
# 4a) updater.exe Release\updater\ icine
$updaterDest = Join-Path $releaseDir "updater"
if (Test-Path $updaterDest) { Remove-Item $updaterDest -Recurse -Force }
New-Item -ItemType Directory -Path $updaterDest | Out-Null
Copy-Item (Join-Path $updaterDir "build\updater.exe") $updaterDest
Write-Host "  updater.exe OK"

# 4a.5) Portable Node.js — son LTS surumunu cache klasoru icinde tut.
# Kullanici makinesinde Node.js kurulu degilse backend baslamasin diye
# node.exe'yi bundle'a dahil ediyoruz. _findNode() once bunu arar.
$nodeVersion = "v20.18.1" # LTS - stabil
$nodeCacheDir = Join-Path $projectRoot ".cache\node-$nodeVersion-win-x64"
$nodeExeCached = Join-Path $nodeCacheDir "node.exe"
if (-not (Test-Path $nodeExeCached)) {
  Write-Host "  Node.js portable indiriliyor: $nodeVersion..."
  New-Item -ItemType Directory -Force -Path $nodeCacheDir | Out-Null
  $nodeUrl = "https://nodejs.org/dist/$nodeVersion/node-$nodeVersion-win-x64.zip"
  $nodeZip = Join-Path $env:TEMP "node-$nodeVersion-win-x64.zip"
  try {
    Invoke-WebRequest -Uri $nodeUrl -OutFile $nodeZip -UseBasicParsing
    $tempExtract = Join-Path $env:TEMP "node-extract-$([guid]::NewGuid())"
    Expand-Archive -Path $nodeZip -DestinationPath $tempExtract -Force
    $extractedDir = Get-ChildItem $tempExtract -Directory | Select-Object -First 1
    Copy-Item (Join-Path $extractedDir.FullName "node.exe") $nodeExeCached -Force
    Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $nodeZip -Force -ErrorAction SilentlyContinue
    Write-Host "  Node.js cache: $nodeExeCached"
  } catch {
    Write-Warning "  Node.js indirilemedi: $_"
    Write-Warning "  Bundle'da node.exe olmayacak - kullanici Node.js kurmali"
  }
}
if (Test-Path $nodeExeCached) {
  Copy-Item $nodeExeCached (Join-Path $releaseDir "node.exe") -Force
  $nodeSize = (Get-Item (Join-Path $releaseDir "node.exe")).Length / 1MB
  Write-Host "  node.exe bundle edildi ($($nodeSize.ToString('F1')) MB)"
}

# 4b) backend prod deps install + Release\backend\ icine kopyala
Push-Location $backendDir
try {
  # npm ci/install prod deps — node_modules'u prod-only yap
  if (-not (Test-Path "$backendDir\node_modules") -or
      ((Get-Item "$backendDir\package.json").LastWriteTime -gt
       (Get-Item "$backendDir\node_modules").LastWriteTime)) {
    Write-Host "  npm install --omit=dev calistiriliyor..."
    & npm install --omit=dev 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Error "npm install basarisiz"
      exit 1
    }
  }
} finally {
  Pop-Location
}

$backendDest = Join-Path $releaseDir "backend"
if (Test-Path $backendDest) { Remove-Item $backendDest -Recurse -Force }
New-Item -ItemType Directory -Path $backendDest | Out-Null

# Yalniz gerekli olanlar:
Copy-Item "$backendDir\src" "$backendDest\src" -Recurse -Force
Copy-Item "$backendDir\package.json" $backendDest -Force
if (Test-Path "$backendDir\package-lock.json") {
  Copy-Item "$backendDir\package-lock.json" $backendDest -Force
}
Copy-Item "$backendDir\node_modules" "$backendDest\node_modules" -Recurse -Force
# uploads klasoru bos baslat (varsa)
if (-not (Test-Path "$backendDest\uploads")) {
  New-Item -ItemType Directory -Path "$backendDest\uploads" | Out-Null
}
$backendSize = (Get-ChildItem $backendDest -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB
Write-Host "  backend bundle: $($backendSize.ToString('F1')) MB"

# 5) version.txt
Write-Host "`n[5/7] version.txt yaziliyor: $Version"
Set-Content -Path (Join-Path $releaseDir "version.txt") -Value $Version -NoNewline -Encoding ASCII

# 6) Zip (otomatik guncelleme paketi - mevcut kullanicilar icin)
Write-Host "`n[6/8] Zip olusturuluyor..."
if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipOut -Force
$zipSize = (Get-Item $zipOut).Length / 1MB
Write-Host "  $zipOut ($($zipSize.ToString('F2')) MB)"

# 7) Setup installer (yeni kullanicilar icin)
Write-Host "`n[7/8] Setup installer olusturuluyor..."
$isccCandidates = @(
  "${env:LOCALAPPDATA}\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
)
$iscc = $isccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$setupOut = $null
if (-not $iscc) {
  Write-Warning "Inno Setup bulunamadi - installer olusturulmadi. Kurmak icin: winget install JRSoftware.InnoSetup"
} else {
  $issFile = Join-Path $projectRoot 'installer\LocalHub.iss'
  if (-not (Test-Path $issFile)) {
    Write-Warning "installer\LocalHub.iss bulunamadi - installer atlandi"
  } else {
    Push-Location (Split-Path $issFile -Parent)
    try {
      & $iscc "/DAppVersion=$Version" $issFile
      if ($LASTEXITCODE -ne 0) {
        Write-Warning "Inno Setup build hatasi (exit $LASTEXITCODE) - installer olusturulamadi"
      } else {
        $setupOut = Join-Path (Split-Path $issFile -Parent) "Output\LocalHub-Setup-$Version.exe"
        if (Test-Path $setupOut) {
          # Setup.exe'yi signtool ile imzala (Inno Setup'tan ayri)
          if ($canSign) {
            Write-Host "  Setup.exe imzalaniyor..."
            if (Sign-File $setupOut) {
              Write-Host "  Setup.exe imzalandi"
            }
          }
          $setupSize = (Get-Item $setupOut).Length / 1MB
          # dist klasorune kopya
          Copy-Item $setupOut $distDir -Force
          $setupOut = Join-Path $distDir "LocalHub-Setup-$Version.exe"
          Write-Host "  $setupOut ($($setupSize.ToString('F2')) MB)"
        } else {
          Write-Warning "Setup exe bulunamadi: $setupOut"
          $setupOut = $null
        }
      }
    } finally {
      Pop-Location
    }
  }
}

# 8) gh release create — hem zip hem setup yukle
Write-Host "`n[8/8] GitHub Release olusturuluyor: v$Version"
$releaseFiles = @($zipOut)
if ($setupOut -and (Test-Path $setupOut)) {
  $releaseFiles += $setupOut
}
$ghArgs = @('release', 'create', "v$Version") + $releaseFiles + @('--title', "v$Version")
if ($NotesFile -and (Test-Path $NotesFile)) {
  $ghArgs += @('--notes-file', $NotesFile)
} else {
  # gh CLI'in here-string'leri yorumlama sorunundan kacinmak icin temp
  # dosyaya yaz ve --notes-file kullan.
  $tempNotesFile = Join-Path $env:TEMP "LocalHub-notes-$Version.md"
  $defaultNotes = "## LocalHub $Version`n`n" +
    "### Indirme`n" +
    "- **Yeni kurulum:** ``LocalHub-Setup-$Version.exe```n" +
    "- **Mevcut kullanicilar:** otomatik guncellenir (uygulamayi acin)`n`n" +
    "### Windows SmartScreen Uyarisi`n`n" +
    "LocalHub henuz Microsoft tarafindan tanimlanan bir kod imzalama " +
    "sertifikasi ile imzalanmadi (EV sertifika ~``$300/yil). Self-signed " +
    "sertifika ile imzalandi - publisher artik ``LocalHub`` olarak gozukur, " +
    "ama SmartScreen yine de uyari verebilir. Guvenlik acisindan tehlike " +
    "yoktur, kaynak kodu acik: https://github.com/kabatay33/LocalHub`n`n" +
    "**Uyariyi gecmek icin:**`n" +
    "1. ``Daha fazla bilgi`` (More info) baglantisina tikla`n" +
    "2. ``Yine de calistir`` (Run anyway) butonuna bas`n" +
    "3. Kurulum normal sekilde devam eder`n`n" +
    "Bir kez kurulumdan sonra otomatik guncellemeler bu uyariyi tetiklemez."
  Set-Content -Path $tempNotesFile -Value $defaultNotes -Encoding UTF8
  $ghArgs += @('--notes-file', $tempNotesFile)
}
& gh @ghArgs
if ($LASTEXITCODE -ne 0) {
  Write-Error "gh release create basarisiz"
  exit 1
}

Write-Host "`n[OK] Release yayinlandi: v$Version"
Write-Host "  Zip: $zipOut"
if ($setupOut) { Write-Host "  Setup: $setupOut" }
Write-Host "  URL: https://github.com/kabatay33/LocalHub/releases/tag/v$Version"
Write-Host "`nKullanicilar app actiginda otomatik guncelleyecek."

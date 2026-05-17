# VOCAL-APP Updater - PowerShell Version
$ErrorActionPreference = "Stop"

$logFile = Join-Path $PSScriptRoot "updater.log"
function Write-Log($msg) {
    $line = "$(Get-Date) $msg"
    Add-Content -Path $logFile -Value $line
    Write-Host $line
}

# Temizle
if (Test-Path $logFile) { Remove-Item $logFile -Force }

Write-Log "=== VOCAL-APP UPDATER BASLADI ==="
Write-Log "exe: $($MyInvocation.MyCommand.Path)"
Write-Log "cwd: $(Get-Location)"

# 1. Install dir bul
$exeDir = $PSScriptRoot
$installDir = $exeDir

# updater/ alt klasorundeyse ust klasore git
if ($exeDir.EndsWith("\updater") -or $exeDir.EndsWith("/updater")) {
    $installDir = Split-Path $exeDir -Parent
    Write-Log "updater/ alt klasorunde, install dir: $installDir"
}

# discord_clone.exe var mi?
if (-not (Test-Path "$installDir\discord_clone.exe")) {
    Write-Log "discord_clone.exe bulunamadi: $installDir"
}

# 2. Mevcut versiyonu oku
$currentVersion = $null
$versionFile = Join-Path $installDir "version.txt"
if (Test-Path $versionFile) {
    $currentVersion = (Get-Content $versionFile -Raw).Trim()
}
Write-Log "Mevcut surum: $currentVersion"

# 3. Radmin VPN kontrol
$radminRunning = Get-Process "RvRvpnGui" -ErrorAction SilentlyContinue
if ($radminRunning) {
    Write-Log "Radmin VPN zaten calisiyor"
} else {
    $radminPath = "C:\Program Files (x86)\Radmin VPN\RvRvpnGui.exe"
    if (Test-Path $radminPath) {
        Write-Log "Radmin VPN baslatiliyor..."
        Start-Process $radminPath
        Start-Sleep -Seconds 3
    } else {
        Write-Log "Radmin VPN bulunamadi"
    }
}

# 4. GitHub'dan son surumu al
Write-Log "GitHub API cagriliyor..."
try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/kabatay33/VOCAL-APP/releases/latest" -TimeoutSec 10
    $latestVersion = $release.tag_name -replace '^v',''
    Write-Log "Son surum: $latestVersion"

    $zipAsset = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
    if (-not $zipAsset) {
        Write-Log "ZIP dosyasi bulunamadi, mevcut surumle devam"
        Start-Sleep -Seconds 2
        & $installDir\discord_clone.exe
        exit 0
    }

    # 5. Versiyon karsilastirmasi
    if ($currentVersion -and $currentVersion -eq $latestVersion) {
        Write-Log "Uygulama guncel! Surum: $currentVersion"
        Start-Sleep -Seconds 1
        Start-Process "$installDir\discord_clone.exe"
        exit 0
    }

    # 6. Indir
    Write-Log "Indiriliyor: $($zipAsset.name)"
    $zipPath = Join-Path $env:TEMP $zipAsset.name
    Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zipPath -UseBasicParsing
    Write-Log "Indirme tamamlandi"

    # 7. Cikar
    Write-Log "Cikariliyor..."
    $extractDir = Join-Path $env:TEMP "vocal_update_extracted"
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    # 8. discord_clone.exe'yi kapat
    $discordProcess = Get-Process "discord_clone" -ErrorAction SilentlyContinue
    if ($discordProcess) {
        Write-Log "discord_clone.exe kapatiliyor..."
        Stop-Process -Name "discord_clone" -Force
        Start-Sleep -Seconds 2
    }

    # 9. Uygula
    Write-Log "Uygulanuyor..."
    Copy-Item "$extractDir\*" $installDir -Recurse -Force
    Set-Content -Path $versionFile -Value $latestVersion -NoNewline

    # Temizlik
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Log "Guncelleme tamamlandi! Yeni surum: $latestVersion"
    Start-Sleep -Seconds 1
} catch {
    Write-Log "HATA: $_"
    Start-Sleep -Seconds 3
}

# 10. discord_clone.exe baslat
Write-Log "Baslatiliyor: $installDir\discord_clone.exe"
if (Test-Path "$installDir\discord_clone.exe") {
    Start-Process "$installDir\discord_clone.exe"
    Write-Log "discord_clone.exe baslatildi"
} else {
    Write-Log "discord_clone.exe BULUNAMADI"
}

Write-Log "UPDATER TAMAMLANDI"
Start-Sleep -Seconds 2

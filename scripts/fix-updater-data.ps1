$ErrorActionPreference = "Stop"
$updaterBuildDir = "C:\Projects\discord-clone\updater\build\windows\x64\runner\Release"
$destData = Join-Path $updaterBuildDir "data"

# Temizle
if (Test-Path $destData) { Remove-Item $destData -Recurse -Force }
New-Item -ItemType Directory -Force -Path $destData | Out-Null

# app.so
$appSo = "C:\Projects\discord-clone\updater\build\windows\app.so"
if (Test-Path $appSo) {
    Copy-Item $appSo (Join-Path $destData "app.so") -Force
    Write-Host "app.so copied"
} else {
    Write-Error "app.so not found!"
}

# flutter_assets
$flutterAssets = "C:\Projects\discord-clone\updater\build\flutter_assets"
if (Test-Path $flutterAssets) {
    Copy-Item $flutterAssets (Join-Path $destData "flutter_assets") -Recurse -Force
    Write-Host "flutter_assets copied"
} else {
    Write-Error "flutter_assets not found!"
}

# icudtl.dat
$icuPaths = @(
    "C:\Projects\discord-clone\flutter_app\build\windows\x64\runner\Release\icudtl.dat",
    "C:\Users\DUTAMETA\Desktop\flutter\bin\cache\artifacts\engine\windows-x64\icudtl.dat"
)
$icuCopied = $false
foreach ($p in $icuPaths) {
    if (Test-Path $p) {
        Copy-Item $p (Join-Path $updaterBuildDir "icudtl.dat") -Force
        Write-Host "icudtl.dat copied from $p"
        $icuCopied = $true
        break
    }
}
if (-not $icuCopied) {
    Write-Error "icudtl.dat not found!"
}

# Verify
Write-Host "`n=== Updater Build Directory ==="
Get-ChildItem $updaterBuildDir -Recurse | Select-Object FullName, Length | Format-Table -AutoSize

param(
  [Parameter(Mandatory=$true)]
  [string]$Version
)

$projectRoot = (Get-Item $PSScriptRoot).Parent.FullName
$releaseDir = Join-Path $projectRoot "flutter_app\build\windows\x64\runner\Release"
$distDir = Join-Path $projectRoot "dist"
$zipOut = Join-Path $distDir "VOCAL-APP-$Version.zip"

New-Item -ItemType Directory -Force -Path $distDir | Out-Null

# cloudflared.exe'yi kopyala
$cloudflaredSrc = Join-Path $projectRoot "flutter_app\windows\tunnel_native\cloudflared\cloudflared.exe"
$cloudflaredDst = Join-Path $releaseDir "cloudflared.exe"
if (Test-Path $cloudflaredSrc) {
    Copy-Item -Path $cloudflaredSrc -Destination $cloudflaredDst -Force
    Write-Host "cloudflared.exe kopyalandı"
} else {
    Write-Warning "cloudflared.exe bulunamadı: $cloudflaredSrc"
}

# Zip
if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipOut -Force
$size = [math]::Round((Get-Item $zipOut).Length / 1MB, 2)
Write-Host "Zip hazir: $zipOut ($size MB)"

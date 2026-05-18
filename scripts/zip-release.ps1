param(
  [Parameter(Mandatory=$true)]
  [string]$Version
)

$projectRoot = (Get-Item $PSScriptRoot).Parent.FullName
$releaseDir = Join-Path $projectRoot "flutter_app\build\windows\x64\runner\Release"
$distDir = Join-Path $projectRoot "dist"
$zipOut = Join-Path $distDir "LocalHub-$Version.zip"

New-Item -ItemType Directory -Force -Path $distDir | Out-Null

# playit.exe'yi kopyala (varsayÄ±lan tunnel)
$playitSrc = Join-Path $projectRoot "flutter_app\windows\tunnel_native\playit\playit.exe"
$playitDst = Join-Path $releaseDir "playit.exe"
if (Test-Path $playitSrc) {
    Copy-Item -Path $playitSrc -Destination $playitDst -Force
    Write-Host "playit.exe kopyalandÄ±"
} else {
    Write-Warning "playit.exe bulunamadÄ±: $playitSrc"
}

# Zip
if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipOut -Force
$size = [math]::Round((Get-Item $zipOut).Length / 1MB, 2)
Write-Host "Zip hazir: $zipOut ($size MB)"

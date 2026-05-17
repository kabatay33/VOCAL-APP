param([Parameter(Mandatory=$true)] [string]$Version)
$projectRoot = (Get-Item $PSScriptRoot).Parent.FullName
$releaseDir = Join-Path $projectRoot "flutter_app\build\windows\x64\runner\Release"
$distDir = Join-Path $projectRoot "dist"
$zipOut = Join-Path $distDir "VOCAL-APP-$Version.zip"
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipOut -Force
$size = [math]::Round((Get-Item $zipOut).Length / 1MB, 2)
Write-Host "Zip: $zipOut ($size MB)"

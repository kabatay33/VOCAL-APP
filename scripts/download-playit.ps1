$ErrorActionPreference = "Stop"
$outDir = "C:\Projects\discord-clone\flutter_app\windows\tunnel_native\playit"
$outFile = "$outDir\playit.exe"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Write-Host "playit.gg indiriliyor..."
Invoke-WebRequest -Uri "https://github.com/playit-cloud/playit-agent/releases/latest/download/playit-windows-x86_64.exe" -OutFile $outFile -UseBasicParsing
$size = [math]::Round((Get-Item $outFile).Length / 1MB, 2)
Write-Host "OK: $outFile ($size MB)"

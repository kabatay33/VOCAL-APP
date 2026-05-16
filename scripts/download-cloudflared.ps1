$ErrorActionPreference = "Stop"
$outDir = "C:\Projects\discord-clone\flutter_app\windows\tunnel_native\cloudflared"
$outFile = "$outDir\cloudflared.exe"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Write-Host "cloudflared.exe indiriliyor..."
Invoke-WebRequest -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" -OutFile $outFile -UseBasicParsing
$size = [math]::Round((Get-Item $outFile).Length / 1MB, 2)
Write-Host "OK: $outFile ($size MB)"

$exePath = "C:\Projects\discord-clone\updater\build\windows\x64\runner\Release\vocal_updater.exe"
$exeDir = Split-Path $exePath -Parent
Write-Host "=== Release klasoru ==="
Get-ChildItem "$exeDir\*" -Include *.exe,*.dll | Select-Object Name, @{N='SizeKB';E={[math]::Round($_.Length/1KB,1)}} | Format-Table -AutoSize
Write-Host ""
Write-Host "=== data klasoru ==="
if (Test-Path "$exeDir\data") {
    Get-ChildItem "$exeDir\data" -Recurse -File | Select-Object FullName, @{N='SizeKB';E={[math]::Round($_.Length/1KB,1)}} | Format-Table -AutoSize
} else {
    Write-Host "data/ KLASORU YOK!"
}
Write-Host ""
Write-Host "=== flutter_assets ==="
if (Test-Path "$exeDir\data\flutter_assets") {
    Get-ChildItem "$exeDir\data\flutter_assets" -Recurse -File | Select-Object FullName, @{N='SizeKB';E={[math]::Round($_.Length/1KB,1)}} | Format-Table -AutoSize
} else {
    Write-Host "data/flutter_assets/ KLASORU YOK!"
}

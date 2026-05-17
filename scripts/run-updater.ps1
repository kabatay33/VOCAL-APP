$logFile = "C:\Users\DUTAMETA\Desktop\updater_debug.log"
if (Test-Path $logFile) { Remove-Item $logFile -Force }

$p = Start-Process -FilePath "C:\Projects\discord-clone\updater\build\windows\x64\runner\Release\vocal_updater.exe" -PassThru -Wait
Write-Host "Exit code: $($p.ExitCode)"

if (Test-Path $logFile) {
    Write-Host "`n=== LOG ==="
    Get-Content $logFile
} else {
    Write-Host "LOG DOSYASI OLUSMADI"
}

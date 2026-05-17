$exePath = "C:\Projects\discord-clone\updater\build\windows\x64\runner\Release\vocal_updater.exe"
$exeDir = Split-Path $exePath -Parent

Write-Host "=== Updater Debug ===" -ForegroundColor Cyan
Write-Host "Exe: $exePath"
Write-Host "Dir: $exeDir"
Write-Host ""

# Exe'nin yanında gerekli dosyalar var mi?
Write-Host "=== Gerekli dosyalar ===" -ForegroundColor Yellow
$required = @(
    "flutter_windows.dll",
    "data\app.so",
    "data\icudtl.dat",
    "data\flutter_assets\fonts\MaterialIcons-Regular.otf"
)
foreach ($f in $required) {
    $full = Join-Path $exeDir $f
    $exists = Test-Path $full
    $color = if ($exists) { "Green" } else { "Red" }
    Write-Host "  $f : $exists" -ForegroundColor $color
}

Write-Host ""
Write-Host "=== Updater baslatiliyor (10 sn bekle) ===" -ForegroundColor Yellow

# Process'i baslat ve ciktiyi yakala
$job = Start-Job -ScriptBlock {
    param($exe)
    & $exe 2>&1
} -ArgumentList $exePath

Start-Sleep -Seconds 10

if ($job.State -eq "Running") {
    Write-Host "10 sn sonra hala calisiyor (pencere acilmis olabilir)" -ForegroundColor Green
    Stop-Job $job -ErrorAction SilentlyContinue
} else {
    $output = Receive-Job $job -ErrorAction SilentlyContinue
    Write-Host "Cikti:" -ForegroundColor Yellow
    Write-Host $output
}

Remove-Job $job -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== Process kontrolu ===" -ForegroundColor Yellow
Get-Process | Where-Object { $_.ProcessName -match "vocal_updater|flutter" } | Select-Object ProcessName, Id, MainWindowTitle | Format-Table -AutoSize

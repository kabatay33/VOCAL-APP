$exePath = "C:\Projects\discord-clone\updater\build\windows\x64\runner\Release\vocal_updater.exe"
Write-Host "Updater baslatiliyor..."
Write-Host "Exe: $exePath"
Write-Host "Exists: $(Test-Path $exePath)"
Write-Host ""

# stderr/stdout'u yakala
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exePath
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $false

$proc = [System.Diagnostics.Process]::Start($psi)
Write-Host "PID: $($proc.Id)"

# 5 sn bekle, sonra output'u oku
Start-Sleep -Seconds 5

if (-not $proc.HasExited) {
    Write-Host "Hala calisiyor..."
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    Write-Host "STDOUT: $stdout"
    if ($stderr) { Write-Host "STDERR: $stderr" }
    $proc.Kill()
} else {
    Write-Host "Cikis kodu: $($proc.ExitCode)"
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    Write-Host "STDOUT: $stdout"
    if ($stderr) { Write-Host "STDERR: $stderr" }
}

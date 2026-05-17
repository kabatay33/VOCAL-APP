$u = Get-Item 'C:\Projects\discord-clone\updater\build\windows\x64\runner\Release\data\app.so'
$r = Get-Item 'C:\Projects\discord-clone\updater\build\windows\x64\runner\Release\app.so'
Write-Host "data/app.so: $($u.Length) bytes ($([math]::Round($u.Length/1MB,2)) MB) - $($u.LastWriteTime)"
Write-Host "root/app.so: $($r.Length) bytes ($([math]::Round($r.Length/1MB,2)) MB) - $($r.LastWriteTime)"

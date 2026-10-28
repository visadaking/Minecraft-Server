# stop.ps1 - sends "stop" over RCON (Linux + Windows)
$root = $PSScriptRoot
. (Join-Path $root 'rcon.ps1')
$password = ''
$port = 0
foreach ($line in Get-Content (Join-Path $root 'server.properties') -Encoding UTF8) {
    if ($line -match '^\s*rcon\.password\s*=\s*(.*)$') { $password = $Matches[1].Trim() }
    if ($line -match '^\s*rcon\.port\s*=\s*(\d+)') { $port = [int]$Matches[1] }
}
if (-not $port) { $port = 25575 }
Invoke-Rcon -Command 'stop' -Password $password -Port $port | Out-Null

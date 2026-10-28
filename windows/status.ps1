#Requires -Version 5.1
<#
    Prints a short startup status block for start.bat.

    Shows whether the playit.gg tunnel, Discord feed, control panel, backups
    and TPS monitor are running. Read-only: it starts nothing and stops nothing.
#>
[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = 'SilentlyContinue'
$root = $PSScriptRoot

function Test-TcpPort {
    param([int]$Port, [string]$Target = '127.0.0.1', [int]$TimeoutMs = 700)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Target, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Test-ScriptRunning {
    param([string]$Name)
    $pattern = '-File\s+"?[^"\r\n]*' + [regex]::Escape($Name)
    return [bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $pattern } |
        Select-Object -First 1)
}

function Get-Setting {
    param([string]$Name, [string]$Default = '')
    $path = Join-Path $root 'gui.txt'
    if (-not (Test-Path $path)) { return $Default }
    $pattern = '^\s*' + [regex]::Escape($Name) + '\s*=\s*(.*)$'
    foreach ($line in Get-Content -Path $path -Encoding UTF8) {
        if ($line -match $pattern) { return $Matches[1].Trim() }
    }
    return $Default
}

function Get-LanAddress {
    # Only the physical home adapter counts. Never show the panel URL on a VPN,
    # Hyper-V, loopback, or link-local address, even if that adapter owns the
    # default route.
    $vpnPattern = 'VPN|WireGuard|TAP|Tunnel|Hyper-V|Virtual|Loopback'
    $preferred = '10.0.0.15'

    try {
        $ip = Get-NetIPAddress -IPAddress $preferred -AddressFamily IPv4 -ErrorAction Stop |
            Select-Object -First 1
        if ($ip) {
            $adapter = Get-NetAdapter -InterfaceIndex $ip.InterfaceIndex -ErrorAction Stop
            if ($adapter -and $adapter.Status -eq 'Up' -and -not $adapter.Virtual -and
                $adapter.InterfaceDescription -notmatch $vpnPattern) {
                return $preferred
            }
        }
    } catch { }

    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.Status -eq 'Up' -and -not $_.Virtual -and
            $_.InterfaceDescription -notmatch $vpnPattern
        })
        foreach ($adapter in $adapters) {
            $ip = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
                Select-Object -First 1
            if ($ip) { return $ip.IPAddress }
        }
    } catch { }

    return '127.0.0.1'
}

$panelPort = 8787
try { $panelPort = [int](Get-Setting 'port' '8787') } catch { }
$lanAddress = Get-LanAddress
$panelUp = Test-TcpPort -Port $panelPort -Target $lanAddress
$panelUrl = 'http://' + $lanAddress + ':' + $panelPort

$playitUp = [bool](Get-Process -Name 'playitd', 'playit', 'playitd-tray', 'playitd-service' -ErrorAction SilentlyContinue)
$feedUp = Test-ScriptRunning 'discord-status.ps1'
$feedMarker = Test-Path (Join-Path $root 'logs\feed-stopped.flag')
$backupUp = Test-ScriptRunning 'backup-loop.ps1'
$monitorUp = Test-ScriptRunning 'tps-monitor.ps1'

$discordConfigured = $false
try {
    . (Join-Path $root 'discord\discord.ps1')
    $discordConfigured = [bool](Test-DiscordConfig (Get-DiscordConfig -Root (Join-Path $root 'discord')))
} catch { }

if ($feedMarker -and -not $feedUp) {
    $feedState = 'stopped by hand'
    $feedTone = 'warn'
} elseif ($feedUp) {
    $feedState = 'running'
    $feedTone = 'ok'
} elseif (-not $discordConfigured) {
    $feedState = 'not configured'
    $feedTone = 'warn'
} else {
    $feedState = 'not running'
    $feedTone = 'bad'
}

$rows = @(
    [pscustomobject]@{ Label = 'playit.gg';   State = $(if ($playitUp) { 'running' } else { 'not running' }); Tone = $(if ($playitUp) { 'ok' } else { 'bad' });  Detail = '' },
    [pscustomobject]@{ Label = 'discord bot'; State = $feedState; Tone = $feedTone; Detail = '' },
    [pscustomobject]@{ Label = 'panel';       State = $(if ($panelUp) { 'running' } else { 'not running' }); Tone = $(if ($panelUp) { 'ok' } else { 'bad' });  Detail = $panelUrl },
    [pscustomobject]@{ Label = 'backups';     State = $(if ($backupUp) { 'running' } else { 'not running' }); Tone = $(if ($backupUp) { 'ok' } else { 'warn' }); Detail = '' },
    [pscustomobject]@{ Label = 'tps monitor'; State = $(if ($monitorUp) { 'running' } else { 'not running' }); Tone = $(if ($monitorUp) { 'ok' } else { 'warn' }); Detail = '' }
)

if ($Json) {
    [pscustomobject]@{
        playit      = $playitUp
        discord     = $feedState
        panel       = $panelUp
        panelUrl    = $panelUrl
        backups     = $backupUp
        tpsMonitor  = $monitorUp
    } | ConvertTo-Json -Compress
    exit 0
}

foreach ($row in $rows) {
    $color = switch ($row.Tone) {
        'ok' { 'Green' }
        'warn' { 'Yellow' }
        'bad' { 'Red' }
        default { 'Gray' }
    }
    Write-Host ('  {0,-14}' -f $row.Label) -NoNewline
    Write-Host ('{0,-14}' -f $row.State) -NoNewline -ForegroundColor $color
    if ($row.Detail) { Write-Host $row.Detail -ForegroundColor DarkGray } else { Write-Host '' }
}

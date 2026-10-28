#Requires -Version 5.1
<#
    Watches the server TPS over a single, persistent RCON connection and warns
    players in-game every time the TPS goes bad.

    TPS is measured from the world game time (which advances once per server
    tick), so it reflects how fast the server is actually ticking, including
    chunk generation stutter and GC pauses.

    A warning is sent when TPS stays below the threshold for -Consecutive
    samples, and again every -CooldownSeconds while it stays bad, so each lag
    episode is announced. A green "back to normal" message follows recovery.

    Started minimized by start.bat. Exits by itself a few minutes after the
    server stops. Only one instance can run at a time.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File .\tps-monitor.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File .\tps-monitor.ps1 -Threshold 17 -Consecutive 3
        powershell -NoProfile -ExecutionPolicy Bypass -File .\tps-monitor.ps1 -TestAlert
#>
[CmdletBinding()]
param(
    [int]$IntervalSeconds = 10,
    [double]$Threshold = 18,
    [int]$Consecutive = 3,
    [int]$CooldownSeconds = 60,
    [switch]$TestAlert
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
. (Join-Path $root 'rcon.ps1')
. (Join-Path $root 'discord\discord.ps1')

$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir 'tps-monitor.log'

# Optional: the same Discord bot/webhook the status feed uses. If it is not
# configured the monitor still warns in-game, it just skips Discord. The file is
# re-read before each alert, so pasting a token mid-run works without a restart.
$script:discord = $null
$script:discordDisabled = $false
try {
    $script:discord = Get-DiscordConfig -Root (Join-Path $root 'discord')
} catch { }

function Write-MonitorLog {
    param([string]$Message)
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
}

function Get-ServerProperty {
    param([string]$Name, [string]$Default = '')
    $path = Join-Path $root 'server.properties'
    if (-not (Test-Path $path)) { return $Default }
    $pattern = '^\s*' + [regex]::Escape($Name) + '\s*=\s*(.*)$'
    foreach ($line in Get-Content -Path $path -Encoding UTF8) {
        if ($line -match $pattern) { return $Matches[1].Trim() }
    }
    return $Default
}

function Test-ServerListening {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(800)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Send-DiscordEmbed {
    param($Embed)
    if ($script:discordDisabled) { return }
    if (-not (Test-DiscordConfig $script:discord)) {
        try { $script:discord = Get-DiscordConfig -Root (Join-Path $root 'discord') } catch { }
    }
    if (-not (Test-DiscordConfig $script:discord)) { return }
    try {
        $payload = [ordered]@{
            embeds           = @($Embed)
            allowed_mentions = @{ parse = @() }
        }
        if ($script:discord.Mode -ne 'bot') { $payload.username = 'server' }
        $json = $payload | ConvertTo-Json -Depth 12 -Compress
        Send-DiscordMessage -Config $script:discord -Json $json | Out-Null
    } catch {
        Write-MonitorLog ('Discord alert failed: ' + $_.Exception.Message)
    }
}

function Send-LagAlert {
    param([double]$Tps, [double]$Mspt, [int]$Players)
    $detail = '{0:0.0}' -f $Tps
    if ($Mspt -gt 0) { $detail += ', ' + ('{0:0} ms/tick' -f $Mspt) }

    $chat = [ordered]@{
        text  = ('[Lag warning] Server TPS is {0} ({1} player(s) online). The server is struggling to keep up.' -f $detail, $Players)
        color = 'red'
        bold  = $true
    } | ConvertTo-Json -Depth 4 -Compress
    $bar = [ordered]@{
        text  = ('LAG: TPS {0:0.0}' -f $Tps)
        color = 'red'
        bold  = $true
    } | ConvertTo-Json -Depth 4 -Compress

    try {
        Invoke-RconSession -Session $script:session -Command ('tellraw @a ' + $chat) | Out-Null
        Invoke-RconSession -Session $script:session -Command ('title @a actionbar ' + $bar) | Out-Null
        Invoke-RconSession -Session $script:session -Command 'playsound minecraft:block.note_block.anvil_land master @a 0 0 0 1 1 1' | Out-Null
    } catch {
        Write-MonitorLog ('Could not send the in-game warning: ' + $_.Exception.Message)
    }

    Send-DiscordEmbed ([ordered]@{
        title       = 'lagging'
        description = ('tps {0:0.0}' -f $Tps)
        color       = 15105570
        timestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    })

    Write-MonitorLog ('ALERT: TPS {0:0.0}, {1:0} ms/tick, {2} player(s).' -f $Tps, $Mspt, $Players)
    try { [console]::Beep(880, 250) } catch { }
}

function Send-Recovery {
    param([double]$Tps)
    $payload = [ordered]@{
        text  = ('[Lag] TPS is back to normal ({0:0.0}).' -f $Tps)
        color = 'green'
    } | ConvertTo-Json -Depth 4 -Compress
    try {
        Invoke-RconSession -Session $script:session -Command ('tellraw @a ' + $payload) | Out-Null
        Invoke-RconSession -Session $script:session -Command ('title @a actionbar ' + $payload) | Out-Null
    } catch { }

    Send-DiscordEmbed ([ordered]@{
        title       = 'back to normal'
        description = ('tps {0:0.0}' -f $Tps)
        color       = 5763719
        timestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    })

    Write-MonitorLog ('Recovered: TPS {0:0.0}.' -f $Tps)
}

$script:rconPort = 25575
try { $script:rconPort = [int](Get-ServerProperty 'rcon.port' '25575') } catch { }
$script:rconPassword = Get-ServerProperty 'rcon.password' ''
$gamePort = 25565
try { $gamePort = [int](Get-ServerProperty 'server-port' '25565') } catch { }
$script:session = $null

if ([string]::IsNullOrWhiteSpace($script:rconPassword)) {
    Write-MonitorLog 'RCON password is not configured; TPS monitoring cannot run.'
    exit 1
}

if ($TestAlert) {
    $script:discordDisabled = $true   # a manual in-game test should not ping Discord
    try {
        $script:session = Connect-Rcon -Password $script:rconPassword -Port $script:rconPort -TimeoutMs 15000
        Write-MonitorLog 'Sending a test warning (manual run).'
        Send-LagAlert -Tps $Threshold -Mspt 50 -Players 0
    } finally {
        if ($script:session) { Close-RconSession $script:session }
    }
    exit 0
}

$mutex = New-Object System.Threading.Mutex($false, 'MinecraftTpsMonitorMutex')
$hasMutex = $false
try {
    $hasMutex = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $hasMutex = $true
}
if (-not $hasMutex) { exit 0 }

try {
    Write-MonitorLog ('TPS monitor started (sample {0}s, warn below {1} TPS after {2} samples, repeat every {3}s).' -f $IntervalSeconds, $Threshold, $Consecutive, $CooldownSeconds)

    $lastTicks = $null
    $lastSample = $null
    $lowStreak = 0
    $healthyStreak = 0
    $lastAlertAt = $null
    $alerted = $false
    $downSeconds = 0
    $failures = 0
    $lastStatusLog = Get-Date

    while ($true) {
        if (-not (Test-ServerListening $gamePort)) {
            $downSeconds += $IntervalSeconds
            $lastTicks = $null
            $lastSample = $null
            $lowStreak = 0
            $alerted = $false
            if ($script:session) { Close-RconSession $script:session; $script:session = $null }
            if ($downSeconds -ge 180) {
                Write-MonitorLog 'Server has been offline for 3 minutes; stopping the TPS monitor.'
                break
            }
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }
        $downSeconds = 0

        if (-not $script:session) {
            try {
                $script:session = Connect-Rcon -Password $script:rconPassword -Port $script:rconPort -TimeoutMs 15000
                Write-MonitorLog 'Connected to the server via RCON.'
            } catch {
                Write-MonitorLog ('Cannot connect to RCON: ' + $_.Exception.Message)
                Start-Sleep -Seconds $IntervalSeconds
                continue
            }
        }

        try {
            $online = Invoke-RconSession -Session $script:session -Command 'list'
            $failures = 0
        } catch {
            $failures++
            Write-MonitorLog ('RCON error: ' + $_.Exception.Message)
            Close-RconSession $script:session
            $script:session = $null
            if ($failures -ge 10) {
                Write-MonitorLog 'Too many RCON failures; stopping the TPS monitor.'
                break
            }
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }

        $players = 0
        if ($online -match 'There are (\d+) of a max') { $players = [int]$Matches[1] }

        # The server pauses itself when empty (pause-when-empty-seconds), so
        # game time stands still. That is not lag - skip those samples.
        if ($players -le 0) {
            if ($lastTicks -ne $null) { Write-MonitorLog 'Server is empty; pausing TPS checks.' }
            $lastTicks = $null
            $lastSample = $null
            $lowStreak = 0
            $healthyStreak = 0
            $alerted = $false
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }

        $now = Get-Date
        if ($null -eq $lastTicks) {
            # Drop any gap (server unpaused, player joined) and start fresh.
            try {
                $raw = Invoke-RconSession -Session $script:session -Command 'time query gametime'
                if ($raw -match 'game time is (\d+)') { $lastTicks = [double]$Matches[1] }
                $lastSample = $now
            } catch { }
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }

        Start-Sleep -Seconds $IntervalSeconds
        $now = Get-Date

        try {
            $raw = Invoke-RconSession -Session $script:session -Command 'time query gametime'
        } catch {
            Write-MonitorLog ('Game time query failed: ' + $_.Exception.Message)
            Close-RconSession $script:session
            $script:session = $null
            $failures++
            continue
        }
        if ($raw -notmatch 'game time is (\d+)') {
            Write-MonitorLog ('Unexpected game time answer: ' + $raw)
            continue
        }

        $ticks = [double]$Matches[1]
        $elapsed = ($now - $lastSample).TotalSeconds
        $delta = $ticks - $lastTicks
        $lastTicks = $ticks
        $lastSample = $now

        if ($elapsed -le 0 -or $delta -lt 0) { continue }

        $tps = $delta / $elapsed
        if ($tps -gt 20) { $tps = 20 }

        $mspt = 0.0
        try {
            $tickInfo = Invoke-RconSession -Session $script:session -Command 'tick query'
            if ($tickInfo -match 'Average time per tick:\s*([\d.,]+)\s*ms') {
                $mspt = [double](($Matches[1]) -replace ',', '.')
            }
        } catch { }

        if ($tps -lt $Threshold) {
            $lowStreak++
            $healthyStreak = 0
        } else {
            $healthyStreak++
            if ($tps -ge 19) { $lowStreak = 0 }
        }

        # Log a status line at most every 10 minutes unless something is wrong.
        if ($tps -lt $Threshold -or ($now - $lastStatusLog).TotalMinutes -ge 10) {
            $msg = 'TPS {0:0.0} ({1} player(s), {2:0.0} ms/tick).' -f $tps, $players, $mspt
            if ($tps -lt $Threshold) { $msg += (' Low streak {0}/{1}.' -f $lowStreak, $Consecutive) }
            Write-MonitorLog $msg
            $lastStatusLog = $now
        }

        if ($lowStreak -ge $Consecutive) {
            if ($null -eq $lastAlertAt -or ($now - $lastAlertAt).TotalSeconds -ge $CooldownSeconds) {
                Send-LagAlert -Tps $tps -Mspt $mspt -Players $players
                $lastAlertAt = $now
                $alerted = $true
            }
        } elseif ($alerted -and $healthyStreak -ge 2) {
            Send-Recovery -Tps $tps
            $alerted = $false
            $lowStreak = 0
            $lastAlertAt = $null
        }
    }
}
finally {
    if ($script:session) { Close-RconSession $script:session }
    if ($hasMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}


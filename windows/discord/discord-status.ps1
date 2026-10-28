#Requires -Version 5.1
<#
    Discord status feed for the Minecraft server.

    Posts to a channel webhook (see discord-webhook.txt):
      - "server online" / "server offline" announcements
      - a live status message (players, TPS, uptime) that is edited in place
      - optional player join/leave lines

    Started minimized by start.bat. Exits a few minutes after the server stops.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File .\discord-status.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File .\discord-status.ps1 -Test
#>
[CmdletBinding()]
param(
    [int]$PollSeconds = 15,
    [double]$UpdateMinutes = 5,
    [string]$ServerAddress = '',
    [switch]$NoPlayerAnnouncements,
    [switch]$Test,
    [string]$WebhookUrl = ''
)

$ErrorActionPreference = 'Continue'
$discordDir = $PSScriptRoot
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'rcon.ps1')
. (Join-Path $discordDir 'discord.ps1')

$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir 'discord-status.log'
$statePath = Join-Path $logDir 'discord-status.json'

function Write-StatusLog {
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

function Format-Uptime {
    param([datetime]$Since)
    $span = (Get-Date) - $Since
    if ($span.TotalMinutes -lt 1) { return 'just started' }
    if ($span.TotalHours -lt 1) { return ('{0}m' -f [int]$span.TotalMinutes) }
    if ($span.TotalDays -lt 1) { return ('{0}h {1}m' -f [int]$span.TotalHours, $span.Minutes) }
    return ('{0}d {1}h' -f [int]$span.TotalDays, $span.Hours)
}

function Save-State {
    try { $script:state | ConvertTo-Json -Depth 6 | Set-Content -Path $statePath -Encoding UTF8 } catch { }
}

function Load-State {
    $fresh = [pscustomobject]@{
        online      = $null
        onlineSince = $null
        offlineAt   = $null
        players     = @()
        boardId     = $null
    }
    if (-not (Test-Path $statePath)) { return $fresh }
    try {
        $loaded = Get-Content -Path $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($loaded.PSObject.Properties.Name -contains 'online') { $fresh.online = $loaded.online }
        if ($loaded.PSObject.Properties.Name -contains 'onlineSince') { $fresh.onlineSince = $loaded.onlineSince }
        if ($loaded.PSObject.Properties.Name -contains 'offlineAt') { $fresh.offlineAt = $loaded.offlineAt }
        if ($loaded.PSObject.Properties.Name -contains 'players') { $fresh.players = @($loaded.players) }
        if ($loaded.PSObject.Properties.Name -contains 'boardId') { $fresh.boardId = $loaded.boardId }
    } catch { }
    return $fresh
}

function Get-StatusEmbed {
    param([bool]$Online, [int]$Players, [int]$MaxPlayers, [string]$TpsText, [string]$UptimeText)

    $lines = New-Object System.Collections.Generic.List[string]
    if ($Online) {
        $lines.Add(('{0}/{1} online' -f $Players, $MaxPlayers))
        if (-not [string]::IsNullOrWhiteSpace($TpsText) -and $TpsText -ne '-') {
            $lines.Add('tps ' + $TpsText)
        }
    } else {
        $lines.Add('server is down')
    }
    if (-not [string]::IsNullOrWhiteSpace($ServerAddress)) { $lines.Add($ServerAddress) }

    $embed = [ordered]@{
        title       = $(if ($Online) { 'server on' } else { 'server off' })
        description = ($lines -join "`n")
        color       = $(if ($Online) { 5763719 } else { 15548997 })
        timestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    }
    return $embed
}

function Send-DiscordPost {
    param([string]$Content, $Embed)
    $payload = [ordered]@{ allowed_mentions = @{ parse = @() } }
    if ($script:discord.Mode -ne 'bot') { $payload.username = 'server' }
    if ($Embed) { $payload.embeds = @($Embed) }
    if ($Content) { $payload.content = $Content }
    $json = $payload | ConvertTo-Json -Depth 12 -Compress
    return Send-DiscordMessage -Config $script:discord -Json $json
}

function Update-StatusBoard {
    param([bool]$Online, [int]$Players, [int]$MaxPlayers, [string]$TpsText, [string]$UptimeText)

    $embed = Get-StatusEmbed -Online $Online -Players $Players -MaxPlayers $MaxPlayers -TpsText $TpsText -UptimeText $UptimeText
    $json = ([ordered]@{ embeds = @($embed); allowed_mentions = @{ parse = @() } }) | ConvertTo-Json -Depth 12 -Compress

    if ($script:state.boardId) {
        try {
            Edit-DiscordMessage -Config $script:discord -MessageId $script:state.boardId -Json $json | Out-Null
            return
        } catch {
            Write-StatusLog ('Could not edit the status message (' + $_.Exception.Message + '); posting a new one.')
            $script:state.boardId = $null
        }
    }

    try {
        $response = Send-DiscordMessage -Config $script:discord -Json $json
        if ($response -and $response.id) {
            $script:state.boardId = [string]$response.id
            Save-State
        }
    } catch {
        Write-StatusLog ('Could not post the status message: ' + $_.Exception.Message)
    }
}

function Get-PlayerList {
    param([string]$RconOutput)
    $names = @()
    if ($RconOutput -match 'There are (\d+) of a max of (\d+) players online:?\s*(.*)$') {
        $count = [int]$Matches[1]
        $max = [int]$Matches[2]
        $rest = $Matches[3].Trim()
        if ($rest.Length -gt 0) { $names = @($rest -split ',\s*' | Where-Object { $_.Length -gt 0 }) }
        return [pscustomobject]@{ Count = $count; Max = $max; Names = $names }
    }
    return $null
}

# ---------------------------------------------------------------- credentials
$script:discord = Get-DiscordConfig -Root $discordDir
if (-not [string]::IsNullOrWhiteSpace($WebhookUrl)) {
    # Allows a webhook to be passed in for testing without editing the file.
    $script:discord.Mode = 'webhook'
    $script:discord.WebhookUrl = $WebhookUrl
}
if (-not (Test-DiscordConfig $script:discord)) {
    Write-StatusLog 'No Discord bot token or webhook configured; see discord-bot.txt / discord-webhook.txt. Status feed not started.'
    exit 1
}
Write-StatusLog ('Using Discord ' + $script:discord.Mode + ' transport.')

# The public playit.gg address is optional; it is shown in the status messages.
if ([string]::IsNullOrWhiteSpace($ServerAddress)) {
    $ServerAddress = Get-DiscordFileValue -Path (Join-Path $discordDir 'public-address.txt')
}
if ($null -eq $ServerAddress) { $ServerAddress = '' }

if ($Test) {
    $embed = [ordered]@{
        title       = 'test'
        description = 'discord works'
        color       = 5763719
        timestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    }
    try {
        $response = Send-DiscordPost -Embed $embed
        Write-StatusLog ('Test message posted (id ' + $response.id + ').')
        Write-Host ('Test message posted to Discord (id ' + $response.id + ').')
        exit 0
    } catch {
        Write-StatusLog ('Test message failed: ' + $_.Exception.Message)
        Write-Host ('Test message failed: ' + $_.Exception.Message)
        exit 1
    }
}

$mutex = New-Object System.Threading.Mutex($false, 'MinecraftDiscordStatusMutex')
$hasMutex = $false
try { $hasMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $hasMutex = $true }
if (-not $hasMutex) { exit 0 }

try {
    $script:state = Load-State
    $script:rconPort = 25575
    try { $script:rconPort = [int](Get-ServerProperty 'rcon.port' '25575') } catch { }
    $script:rconPassword = Get-ServerProperty 'rcon.password' ''
    $gamePort = 25565
    try { $gamePort = [int](Get-ServerProperty 'server-port' '25565') } catch { }
    $maxPlayers = 20
    try { $maxPlayers = [int](Get-ServerProperty 'max-players' '20') } catch { }

    Write-StatusLog ('Discord status feed started (poll {0}s, status message every {1} min).' -f $PollSeconds, $UpdateMinutes)

    $session = $null
    $lastTick = $null
    $lastTickAt = $null
    $tps = $null
    $lastBoardUpdate = [datetime]::MinValue
    $boardDirty = $true
    $downSeconds = 0
    $feedStartedAt = Get-Date
    $graceSeconds = 120
    $playersSeeded = $false

    while ($true) {
        $up = Test-ServerListening $gamePort
        $players = 0
        $names = @()
        $max = $maxPlayers
        $listOk = $false

        # A server process that started after the saved "online since" time is a
        # fresh boot (for example after a crash), so announce it even though the
        # state file still says online.
        if ($up -and $script:state.online -eq $true) {
            try {
                $java = Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction Stop |
                    Where-Object { $_.CommandLine -match 'server\.jar' } | Select-Object -First 1
                $procStart = $java.CreationDate
                $savedSince = $null
                if ($script:state.onlineSince) {
                    try { $savedSince = [datetime]::Parse($script:state.onlineSince) } catch { $savedSince = $null }
                }
                if ($java -and (-not $savedSince -or $procStart -gt $savedSince)) {
                    $script:state.online = $null
                    $script:state.onlineSince = $null
                    $script:state.players = @()
                    $playersSeeded = $false
                    Save-State
                }
            } catch { }
        }

        if ($up -and -not $session) {
            try {
                $session = Connect-Rcon -Password $script:rconPassword -Port $script:rconPort -TimeoutMs 10000
            } catch {
                $session = $null
            }
        }

        if ($up -and $session) {
            try {
                $listOutput = Invoke-RconSession -Session $session -Command 'list' -TimeoutMs 10000
                $parsed = Get-PlayerList -RconOutput $listOutput
                if ($parsed) { $players = $parsed.Count; $names = $parsed.Names; $max = $parsed.Max; $listOk = $true }
            } catch {
                Write-StatusLog ('RCON error: ' + $_.Exception.Message)
                Close-RconSession $session
                $session = $null
            }
        }

        if ($up -and $session) {
            try {
                $gtRaw = Invoke-RconSession -Session $session -Command 'time query gametime' -TimeoutMs 10000
                if ($gtRaw -match 'game time is (\d+)') {
                    $gt = [double]$Matches[1]
                    $now = Get-Date
                    if ($null -ne $lastTick -and $players -gt 0) {
                        $elapsed = ($now - $lastTickAt).TotalSeconds
                        $delta = $gt - $lastTick
                        if ($elapsed -gt 0 -and $delta -ge 0) {
                            $tps = $delta / $elapsed
                            if ($tps -gt 20) { $tps = 20 }
                        }
                    }
                    $lastTick = $gt
                    $lastTickAt = $now
                }
            } catch {
                Write-StatusLog ('Game time query failed: ' + $_.Exception.Message)
                Close-RconSession $session
                $session = $null
            }
        }

        if (-not $up) {
            $lastTick = $null
            $lastTickAt = $null
            $tps = $null
        }

        # Uptime is needed by the state-change embeds below, so work it out first.
        $since = $null
        if ($script:state.onlineSince) {
            try { $since = [datetime]::Parse($script:state.onlineSince) } catch { $since = $null }
        }
        $uptimeText = $(if ($up -and $since) { Format-Uptime -Since $since } else { '—' })
        $tpsText = $(if (-not $up) { '—' } elseif ($players -le 0) { 'idle' } elseif ($null -ne $tps) { '{0:0.0}' -f $tps } else { '—' })

        # ------------------------------------------------------ state changes
        if ($up -and $script:state.online -ne $true) {
            $restarted = $false
            if ($script:state.offlineAt) {
                try {
                    $downSince = [datetime]::Parse($script:state.offlineAt)
                    $downSeconds = ((Get-Date) - $downSince).TotalSeconds
                    if ($downSeconds -ge 0 -and $downSeconds -lt 600) { $restarted = $true }
                } catch { }
            }

            $script:state.online = $true
            $script:state.onlineSince = (Get-Date).ToString('o')
            $script:state.offlineAt = $null
            $script:state.players = @()
            Save-State
            $boardDirty = $true

            $description = ''
            if (-not [string]::IsNullOrWhiteSpace($ServerAddress)) { $description = $ServerAddress }
            $onlineEmbed = [ordered]@{
                title       = $(if ($restarted) { 'server restarted' } else { 'server on' })
                description = $description
                color       = 5763719
                timestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            }
            try {
                Send-DiscordPost -Embed $onlineEmbed | Out-Null
                Write-StatusLog 'Posted: server online.'
            } catch {
                Write-StatusLog ('Could not post the online message: ' + $_.Exception.Message)
            }
        } elseif ((-not $up) -and $script:state.online -ne $false) {
            # When the feed starts together with the server, it can take a while
            # before the port opens. Do not announce "offline" during that gap.
            $announceOffline = $true
            if ($script:state.online -eq $true -and ((Get-Date) - $feedStartedAt).TotalSeconds -lt $graceSeconds) {
                $announceOffline = $false
            }

            $script:state.online = $false
            $script:state.onlineSince = $null
            $script:state.offlineAt = (Get-Date).ToString('o')
            $script:state.players = @()
            $playersSeeded = $false
            Save-State
            $boardDirty = $true

            $offlineEmbed = [ordered]@{
                title       = 'server off'
                color       = 15548997
                timestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            }
            if (-not $announceOffline) {
                Write-StatusLog 'Server is not listening yet (startup grace); not announcing offline.'
            } else {
                try {
                    Send-DiscordPost -Embed $offlineEmbed | Out-Null
                    Write-StatusLog 'Posted: server offline.'
                } catch {
                    Write-StatusLog ('Could not post the offline message: ' + $_.Exception.Message)
                }
            }
        }

        # --------------------------------------------------- player join/leave
        if ($up -and $session -and $listOk -and -not $NoPlayerAnnouncements) {
            if (-not $playersSeeded) {
                # The feed just (re)started. Treat the current player list as the
                # baseline so restarting the bot never looks like everyone joined.
                $script:state.players = @($names)
                Save-State
                $playersSeeded = $true
                Write-StatusLog ('Player baseline set ({0} online); not announcing joins for the restart.' -f $names.Count)
            } else {
                $previous = @($script:state.players)
                $joined = @($names | Where-Object { $previous -notcontains $_ })
                $left = @($previous | Where-Object { $names -notcontains $_ })
                $changed = $false

                foreach ($name in $joined) {
                    try {
                        Send-DiscordPost -Content ('{0} joined' -f $name) | Out-Null
                        Write-StatusLog ('Posted: {0} joined.' -f $name)
                    } catch { Write-StatusLog ('Join announcement failed: ' + $_.Exception.Message) }
                    $changed = $true
                }
                foreach ($name in $left) {
                    try {
                        Send-DiscordPost -Content ('{0} left' -f $name) | Out-Null
                        Write-StatusLog ('Posted: {0} left.' -f $name)
                    } catch { Write-StatusLog ('Leave announcement failed: ' + $_.Exception.Message) }
                    $changed = $true
                }

                if ($changed -or (@($script:state.players).Count -ne $names.Count)) {
                    $script:state.players = @($names)
                    Save-State
                }
            }
        }

        # ------------------------------------------------------- status message
        $due = ((Get-Date) - $lastBoardUpdate).TotalMinutes -ge $UpdateMinutes
        if ($boardDirty -or $due) {
            Update-StatusBoard -Online $up -Players $players -MaxPlayers $max -TpsText $tpsText -UptimeText $uptimeText
            $lastBoardUpdate = Get-Date
            $boardDirty = $false
        }

        if (-not $up) {
            $downSeconds += $PollSeconds
            if ($downSeconds -ge 300) {
                Write-StatusLog 'Server has been offline for 5 minutes; stopping the Discord feed.'
                break
            }
        } else {
            $downSeconds = 0
        }

        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    if ($session) { Close-RconSession $session }
    if ($hasMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

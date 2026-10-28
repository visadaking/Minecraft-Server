#Requires -Version 5.1
<#
    Two-way chat bridge between the Minecraft server and Discord.

    Minecraft -> Discord: tails logs\latest.log for vanilla chat lines
      (<Name> message) and posts them with the player name as the webhook
      username, so they show up in the channel like normal chat.

    Discord -> Minecraft: polls new channel messages with the bot API
      (discord-bot.txt) and forwards them in-game over RCON with
      tellraw @a. The bot's own messages, the status feed messages and
      webhook messages (which include the forwarded chat) are skipped so
      nothing loops.

    State (log position, last Discord message id) lives in logs\.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File discord-chat.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File discord-chat.ps1 -Test
#>
[CmdletBinding()]
param(
    [int]$PollSeconds = 3,
    [switch]$Test
)

$ErrorActionPreference = 'Continue'
$discordDir = $PSScriptRoot
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'rcon.ps1')
. (Join-Path $discordDir 'discord.ps1')

$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir 'discord-chat.log'
$statePath = Join-Path $logDir 'discord-chat-state.json'
$mcLogPath = Join-Path $logDir 'latest.log'

function Write-ChatLog {
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

function Test-GamePortListening {
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

function ConvertTo-SnowflakeNumber {
    # Discord snowflake ids compare fine as unsigned 64-bit numbers.
    param([string]$Value)
    $n = [UInt64]0
    if ([UInt64]::TryParse($Value, [ref]$n)) { return $n }
    return [UInt64]0
}

function Save-State {
    try { $script:state | ConvertTo-Json -Depth 4 | Set-Content -Path $statePath -Encoding UTF8 } catch { }
}

function Load-State {
    $fresh = [pscustomobject]@{
        logPosition = @{}   # path -> length
        lastMessageId = ''
    }
    if (-not (Test-Path $statePath)) { return $fresh }
    try {
        $loaded = Get-Content -Path $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($loaded.logPosition -and $loaded.logPosition.PSObject.Properties) {
            foreach ($p in $loaded.logPosition.PSObject.Properties) {
                $fresh.logPosition[$p.Name] = [int64]$p.Value
            }
        }
        if ($loaded.lastMessageId) { $fresh.lastMessageId = [string]$loaded.lastMessageId }
    } catch { }
    return $fresh
}

# ---------------------------------------------------------------- credentials
$script:discord = Get-DiscordConfig -Root $discordDir
if (-not (Test-DiscordConfig $script:discord)) {
    Write-ChatLog 'No Discord bot token or webhook configured; see discord-bot.txt / discord-webhook.txt. Chat bridge not started.'
    exit 1
}

$webhookUrl = Get-DiscordFileValue -Path (Join-Path $discordDir 'discord-webhook.txt')
if ([string]::IsNullOrWhiteSpace($webhookUrl) -and $script:discord.Mode -eq 'webhook') {
    $webhookUrl = $script:discord.WebhookUrl
}

$script:botUserId = ''
if ($script:discord.Mode -eq 'bot') {
    try {
        $me = Invoke-DiscordHttpRequest -Url ($script:discord.ApiBase.TrimEnd('/') + '/users/@me') -Method 'GET' -Headers @{ 'Authorization' = 'Bot ' + $script:discord.BotToken }
        if ($me -and $me.id) { $script:botUserId = [string]$me.id }
    } catch {
        Write-ChatLog ('Could not identify the bot user: ' + $_.Exception.Message)
    }
}

$script:rconPort = 25575
try { $script:rconPort = [int](Get-ServerProperty 'rcon.port' '25575') } catch { }
$script:rconPassword = Get-ServerProperty 'rcon.password' ''
$gamePort = 25565
try { $gamePort = [int](Get-ServerProperty 'server-port' '25565') } catch { }

function Post-MinecraftChatToDiscord {
    param([string]$Player, [string]$Message)

    $player = ($Player -replace '[\r\n]', ' ').Trim()
    if ($player.Length -gt 32) { $player = $player.Substring(0, 32) }
    if ($Message.Length -gt 2000) { $Message = $Message.Substring(0, 2000) }

    $payload = [ordered]@{
        content          = $Message
        username         = $Player
        allowed_mentions = @{ parse = @() }
    }
    $json = $payload | ConvertTo-Json -Compress

    if ($webhookUrl) {
        # Webhook mode: the player name is used as the display name.
        try {
            $text = [MinecraftNet.BoundHttp]::Send($webhookUrl, 'POST', 'application/json; charset=utf-8',
                'MinecraftStatus (Minecraft server, 1.0)', '', [Text.Encoding]::UTF8.GetBytes($json),
                (Get-DiscordBindAddress), 20000)
            return $true
        } catch {
            Write-ChatLog ('Could not post chat via webhook: ' + $_.Exception.Message)
            return $false
        }
    }

    if ($script:discord.Mode -eq 'bot') {
        try {
            Send-DiscordMessage -Config $script:discord -Json $json | Out-Null
            return $true
        } catch {
            Write-ChatLog ('Could not post chat via bot: ' + $_.Exception.Message)
            return $false
        }
    }
    return $false
}

function Get-NewChannelMessages {
    if ($script:discord.Mode -ne 'bot') { return @() }
    $url = $script:discord.ApiBase.TrimEnd('/') + '/channels/' + $script:discord.ChannelId + '/messages?limit=20'
    if ($script:state.lastMessageId) { $url += '&after=' + $script:state.lastMessageId }
    try {
        $messages = Invoke-DiscordHttpRequest -Url $url -Method 'GET' -Headers @{ 'Authorization' = 'Bot ' + $script:discord.BotToken }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -notmatch 'HTTP 429') { Write-ChatLog ('Could not read channel messages: ' + $msg) }
        return @()
    }
    if (-not $messages) { return @() }
    # Discord returns newest first; forward in the order they were sent.
    return @($messages | Sort-Object { ConvertTo-SnowflakeNumber $_.id })
}

function Send-ChatToMinecraft {
    param($Message)

    # Skip messages that originally came from Minecraft or the feed itself.
    if ($script:botUserId -and [string]$Message.author.id -eq $script:botUserId) { return $true }
    if ($Message.author.PSObject.Properties.Name -contains 'webhook_id' -and $Message.author.webhook_id) { return $true }
    $text = [string]$Message.content
    if ([string]::IsNullOrWhiteSpace($text)) { return $true }

    $name = $(if ($Message.member -and $Message.member.nick) { $Message.member.nick } else { $Message.author.username })
    $name = ($name -replace '[\r\n]', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'discord' }
    if ($text.Length -gt 240) { $text = $text.Substring(0, 240) + ' ...' }

    $inGame = @{ text = ('[discord] ' + $name + ': ' + $text) } | ConvertTo-Json -Compress
    try {
        Invoke-RconSession -Session $script:rconSession -Command ('tellraw @a ' + $inGame) -TimeoutMs 10000 | Out-Null
        return $true
    } catch {
        Write-ChatLog ('RCON send failed: ' + $_.Exception.Message)
        throw
    }
}

# ------------------------------------------------------------------- test mode
if ($Test) {
    $transportText = $script:discord.Mode + $(if ($webhookUrl) { ' (+ webhook)' } else { '' })
    Write-Host ('Transport: ' + $transportText)
    Write-Host ('Bot user id: ' + $(if ($script:botUserId) { $script:botUserId } else { 'unknown' }))
    if ($script:discord.Mode -ne 'bot') {
        Write-Host 'Bot mode is required for Discord -> Minecraft (discord-bot.txt needs token and channel).'
    }
    if ([string]::IsNullOrWhiteSpace($script:rconPassword)) {
        Write-Host 'rcon.password is empty in server.properties; forwarding into the game will not work.'
    } else {
        Write-Host 'rcon.password is configured.'
    }
    return
}

$mutex = New-Object System.Threading.Mutex($false, 'MinecraftDiscordChatMutex')
$hasMutex = $false
try { $hasMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $hasMutex = $true }
if (-not $hasMutex) { exit 0 }

try {
    $script:state = Load-State
    $script:rconSession = $null
    $chatDownSeconds = 0

    Write-ChatLog ('Chat bridge started (poll {0}s, transport {1}).' -f $PollSeconds, $script:discord.Mode)

    while ($true) {
        $up = Test-GamePortListening -Port $gamePort

        # ------------------------------------------------ Minecraft -> Discord
        if (Test-Path $mcLogPath) {
            $logKey = $mcLogPath.ToLowerInvariant()
            try { $item = Get-Item $mcLogPath -ErrorAction Stop } catch { $item = $null }
            if ($item) {
                $position = [int64]0
                if ($script:state.logPosition.ContainsKey($logKey)) { $position = [int64]$script:state.logPosition[$logKey] }
                if ($item.Length -lt $position) { $position = 0 }   # latest.log was truncated (restart)
                if ($item.Length -gt $position) {
                    try {
                        $fs = [IO.File]::Open($mcLogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                        try {
                            $fs.Seek($position, [IO.SeekOrigin]::Begin) | Out-Null
                            $reader = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                            try { $text = $reader.ReadToEnd() } finally { $reader.Close() }
                        } finally {
                            $fs.Close()
                        }
                        foreach ($line in ($text -split "`r?`n")) {
                            if ($line -notmatch 'INFO\]: <([^>]{1,32})> (.*)$') { continue }
                            $player = $Matches[1]
                            $message = $Matches[2]
                            if ([string]::IsNullOrWhiteSpace($message)) { continue }
                            if ($player -eq 'Server') { continue }     # /say broadcasts, not player chat
                            if (Post-MinecraftChatToDiscord -Player $player -Message $message) {
                                Write-ChatLog ('Posted to Discord: <{0}> {1}' -f $player, $message)
                            }
                        }
                        $position = $item.Length
                    } catch {
                        # The log can be briefly locked while Minecraft writes it.
                    }
                    $script:state.logPosition[$logKey] = $position
                    Save-State
                }
            }
        }

        # ------------------------------------------------ Discord -> Minecraft
        if ($script:discord.Mode -eq 'bot' -and -not [string]::IsNullOrWhiteSpace($script:rconPassword)) {
            if ($up) {
                if ($script:discord.Mode -eq 'bot' -and [string]::IsNullOrWhiteSpace($script:botUserId)) {
                    # Retry once in a while until the bot identity is known; it is
                    # needed to skip the feed's own posts.
                    try {
                        $me = Invoke-DiscordHttpRequest -Url ($script:discord.ApiBase.TrimEnd('/') + '/users/@me') -Method 'GET' -Headers @{ 'Authorization' = 'Bot ' + $script:discord.BotToken }
                        if ($me -and $me.id) { $script:botUserId = [string]$me.id }
                    } catch { }
                }
                if (-not $script:rconSession) {
                    try {
                        $script:rconSession = Connect-Rcon -Password $script:rconPassword -Port $script:rconPort -TimeoutMs 10000
                    } catch {
                        $script:rconSession = $null
                    }
                }
                if ($script:rconSession) {
                    $messages = @(Get-NewChannelMessages)
                    if ($messages.Count -gt 0 -and -not $script:state.lastMessageId) {
                        # First run: remember the newest message without forwarding old chat.
                        $newest = @($messages | Sort-Object { ConvertTo-SnowflakeNumber $_.id } | Select-Object -Last 1)
                        if ($newest) {
                            $script:state.lastMessageId = [string]$newest.id
                            Save-State
                            $messages = @()
                        }
                    }
                    foreach ($message in $messages) {
                        $sent = $false
                        try {
                            $sent = Send-ChatToMinecraft -Message $message
                        } catch {
                            try { Close-RconSession $script:rconSession } catch { }
                            $script:rconSession = $null
                            break
                        }
                        if ($sent) {
                            $script:state.lastMessageId = [string]$message.id
                            Save-State
                            $name = $(if ($message.member -and $message.member.nick) { $message.member.nick } else { $message.author.username })
                            Write-ChatLog ('Forwarded to game: {0}: {1}' -f $name, ([string]$message.content))
                        }
                    }
                }
            } elseif ($script:rconSession) {
                try { Close-RconSession $script:rconSession } catch { }
                $script:rconSession = $null
            }
        } else {
            if ($script:rconSession -and $script:discord.Mode -eq 'bot') {
                try { Close-RconSession $script:rconSession } catch { }
                $script:rconSession = $null
            }
        }

        # The bridge goes down with the stack: after 5 minutes offline stop,
        # just like the feed, the panel, the TPS monitor and the backup loop.
        if ($up) {
            $chatDownSeconds = 0
        } else {
            $chatDownSeconds += $PollSeconds
            if ($chatDownSeconds -ge 300) {
                Write-ChatLog 'Server has been offline for 5 minutes; stopping the chat bridge.'
                break
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    if ($script:rconSession) { Close-RconSession $script:rconSession }
    if ($hasMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
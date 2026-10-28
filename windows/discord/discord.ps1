#Requires -Version 5.1
<#
    Shared Discord transport used by discord-status.ps1 and tps-monitor.ps1.

    Two ways to connect, picked automatically from files in the same folder
    as this script (the discord folder):
      * discord-bot.txt      - bot token + channel id (Bot API over HTTPS)
      * discord-webhook.txt  - a channel webhook URL (no bot needed)

    If both are filled in, the bot is used.

    All requests are source-bound to the home LAN address. If that address is
    not on the physical Ethernet adapter, the request fails instead of silently
    leaking through a VPN or a Hyper-V/virtual adapter.
#>

$script:DiscordBindAddress = '10.0.0.15'

function Get-DiscordBindAddress {
    $address = $script:DiscordBindAddress
    try {
        $ip = Get-NetIPAddress -IPAddress $address -AddressFamily IPv4 -ErrorAction Stop |
            Select-Object -First 1
        if (-not $ip) { throw 'the address is not assigned' }
        $adapter = Get-NetAdapter -InterfaceIndex $ip.InterfaceIndex -ErrorAction Stop
        if (-not $adapter -or $adapter.Status -ne 'Up') { throw 'the adapter is not up' }
        if ($adapter.Virtual) { throw 'the address is on a virtual adapter' }
        if ($adapter.InterfaceDescription -match 'VPN|WireGuard|TAP|Tunnel|Hyper-V|Virtual') {
            throw ('the address is on ' + $adapter.InterfaceDescription)
        }
        return $address
    } catch {
        throw ('Refusing to send Discord traffic: ' + $address +
            ' is not live on the physical Ethernet adapter (' + $_.Exception.Message +
            '). The feed will not fall back to a VPN or virtual interface.')
    }
}

function Initialize-DiscordHttp {
    if ('MinecraftNet.BoundHttp' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Text;

namespace MinecraftNet
{
    public static class BoundHttp
    {
        public static string Send(
            string url,
            string method,
            string contentType,
            string userAgent,
            string headerBlock,
            byte[] body,
            string bindAddress,
            int timeoutMs)
        {
            IPAddress bindIp = IPAddress.Parse(bindAddress);
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = method;
            request.UserAgent = userAgent;
            request.Timeout = timeoutMs;
            request.ReadWriteTimeout = timeoutMs;
            request.AllowAutoRedirect = true;
            request.KeepAlive = false;
            request.ServicePoint.BindIPEndPointDelegate =
                delegate(ServicePoint servicePoint, IPEndPoint remoteEndPoint, int retryCount)
                {
                    return new IPEndPoint(bindIp, 0);
                };

            if (!string.IsNullOrEmpty(contentType))
            {
                request.ContentType = contentType;
            }

            if (!string.IsNullOrEmpty(headerBlock))
            {
                string[] lines = headerBlock.Split(new string[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries);
                foreach (string line in lines)
                {
                    int colon = line.IndexOf(':');
                    if (colon <= 0) { continue; }
                    string name = line.Substring(0, colon).Trim();
                    string value = line.Substring(colon + 1).Trim();
                    if (name.Equals("User-Agent", StringComparison.OrdinalIgnoreCase)) { continue; }
                    request.Headers[name] = value;
                }
            }

            if (body != null)
            {
                request.ContentLength = body.Length;
                using (Stream stream = request.GetRequestStream())
                {
                    stream.Write(body, 0, body.Length);
                }
            }

            try
            {
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                {
                    return reader.ReadToEnd();
                }
            }
            catch (WebException ex)
            {
                HttpWebResponse response = ex.Response as HttpWebResponse;
                if (response != null)
                {
                    using (response)
                    using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                    {
                        string text = reader.ReadToEnd();
                        throw new Exception("Discord HTTP " + (int)response.StatusCode + ": " + text);
                    }
                }
                throw;
            }
        }
    }
}
'@
}

function Invoke-DiscordHttpRequest {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Headers = @{},
        [byte[]]$Body = $null
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Initialize-DiscordHttp
    $bindAddress = Get-DiscordBindAddress

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Headers.Keys) {
        if ($key -eq 'User-Agent') { continue }
        $lines.Add($key + ': ' + $Headers[$key])
    }

    $text = [MinecraftNet.BoundHttp]::Send(
        $Url,
        $Method,
        'application/json; charset=utf-8',
        'MinecraftStatus (Minecraft server, 1.0)',
        ($lines -join "`r`n"),
        $Body,
        $bindAddress,
        20000)

    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

function Get-DiscordFileValue {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return '' }
    foreach ($line in Get-Content -Path $Path -Encoding UTF8) {
        $text = $line.Trim()
        if ($text.Length -gt 0 -and -not $text.StartsWith('#')) { return $text }
    }
    return ''
}

function Get-DiscordFileKey {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path $Path)) { return '' }
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*=\s*(.+)$'
    foreach ($line in Get-Content -Path $Path -Encoding UTF8) {
        $text = $line.Trim()
        if ($text.Length -eq 0 -or $text.StartsWith('#')) { continue }
        if ($text -match $pattern) { return $Matches[1].Trim() }
    }
    return ''
}

function Get-DiscordConfig {
    param([Parameter(Mandatory)][string]$Root)

    $config = [pscustomobject]@{
        Mode       = 'none'
        WebhookUrl = ''
        BotToken   = ''
        ChannelId  = ''
        ApiBase    = 'https://discord.com/api/v10'
    }

    $botPath = Join-Path $Root 'discord-bot.txt'
    $token = Get-DiscordFileKey -Path $botPath -Key 'token'
    $channel = Get-DiscordFileKey -Path $botPath -Key 'channel'
    if ($token -and $channel) {
        $config.Mode = 'bot'
        $config.BotToken = $token
        $config.ChannelId = $channel
        return $config
    }

    $webhook = Get-DiscordFileValue -Path (Join-Path $Root 'discord-webhook.txt')
    if ($webhook) {
        $config.Mode = 'webhook'
        $config.WebhookUrl = $webhook
    }

    return $config
}

function Test-DiscordConfig {
    param($Config)
    if ($null -eq $Config) { return $false }
    if ($Config.Mode -eq 'bot') { return [bool]($Config.BotToken -and $Config.ChannelId) }
    if ($Config.Mode -eq 'webhook') { return [bool]$Config.WebhookUrl }
    return $false
}

function Invoke-DiscordRequest {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][ValidateSet('POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory)][string]$Json,
        [string]$MessageId = ''
    )

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    $headers = @{ 'User-Agent' = 'MinecraftStatus (Minecraft server, 1.0)' }
    $body = [Text.Encoding]::UTF8.GetBytes($Json)

    if ($Config.Mode -eq 'bot') {
        $headers['Authorization'] = 'Bot ' + $Config.BotToken
        if ($Method -eq 'POST') {
            $url = $Config.ApiBase.TrimEnd('/') + '/channels/' + $Config.ChannelId + '/messages'
        } else {
            $url = $Config.ApiBase.TrimEnd('/') + '/channels/' + $Config.ChannelId + '/messages/' + $MessageId
        }
    } else {
        $url = $Config.WebhookUrl
        if ($Method -eq 'POST') {
            if ($url.Contains('?')) { $url += '&wait=true' } else { $url += '?wait=true' }
        } else {
            $url = $url.TrimEnd('/') + '/messages/' + $MessageId
        }
    }

    return Invoke-DiscordHttpRequest -Url $url -Method $Method -Headers $headers -Body $body
}

function Send-DiscordMessage {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Json
    )
    return Invoke-DiscordRequest -Config $Config -Method POST -Json $Json
}

function Edit-DiscordMessage {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$MessageId,
        [Parameter(Mandatory)][string]$Json
    )
    return Invoke-DiscordRequest -Config $Config -Method PATCH -Json $Json -MessageId $MessageId
}

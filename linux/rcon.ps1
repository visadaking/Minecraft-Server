#Requires -Version 5.1
<#
    Minimal Source RCON client used by backup.ps1 and tps-monitor.ps1.
    Protocol: https://developer.valvesoftware.com/wiki/Source_RCON_Protocol

    Invoke-Rcon           - one command on a fresh connection (simple, used by backups)
    Connect-Rcon          - open and authenticate a reusable session
    Invoke-RconSession    - run a command on an open session (no reconnect per query)
    Close-RconSession     - close a session
#>

function Read-RconExact {
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][int]$Count
    )
    $buffer = New-Object byte[] $Count
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Stream.Read($buffer, $offset, $Count - $offset)
        if ($read -le 0) { throw 'RCON connection closed unexpectedly.' }
        $offset += $read
    }
    return ,$buffer
}

function Send-RconPacket {
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][int]$Type,
        [string]$Body = ''
    )
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $size = 4 + 4 + $bodyBytes.Length + 2
    $buffer = New-Object byte[] (4 + $size)
    [BitConverter]::GetBytes([int]$size).CopyTo($buffer, 0)
    [BitConverter]::GetBytes([int]$Id).CopyTo($buffer, 4)
    [BitConverter]::GetBytes([int]$Type).CopyTo($buffer, 8)
    if ($bodyBytes.Length -gt 0) { $bodyBytes.CopyTo($buffer, 12) }
    $Stream.Write($buffer, 0, $buffer.Length)
    $Stream.Flush()
}

function Read-RconPacket {
    param([Parameter(Mandatory)][System.IO.Stream]$Stream)
    $sizeBytes = Read-RconExact -Stream $Stream -Count 4
    $size = [BitConverter]::ToInt32($sizeBytes, 0)
    if ($size -lt 10 -or $size -gt 1048576) { throw "Invalid RCON packet size: $size" }
    $payload = Read-RconExact -Stream $Stream -Count $size
    $id = [BitConverter]::ToInt32($payload, 0)
    $type = [BitConverter]::ToInt32($payload, 4)
    $bodyLength = $size - 10
    $body = ''
    if ($bodyLength -gt 0) { $body = [Text.Encoding]::UTF8.GetString($payload, 8, $bodyLength) }
    return [pscustomobject]@{ Id = $id; Type = $type; Body = $body }
}

function Connect-Rcon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Password,
        [int]$Port = 25575,
        [string]$ServerAddress = '127.0.0.1',
        [int]$TimeoutMs = 15000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect($ServerAddress, $Port)
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs

        Send-RconPacket -Stream $stream -Id 1 -Type 3 -Body $Password
        $auth = Read-RconPacket -Stream $stream
        if ($auth.Id -eq -1 -or $auth.Type -ne 2) {
            throw 'RCON authentication failed. Check rcon.password in server.properties.'
        }

        return [pscustomobject]@{ Client = $client; Stream = $stream; NextId = 2 }
    } catch {
        try { $client.Close() } catch { }
        throw
    }
}

function Invoke-RconSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutMs = 15000
    )

    $id = [int]$Session.NextId
    $Session.NextId = $id + 1

    $Session.Stream.ReadTimeout = $TimeoutMs
    Send-RconPacket -Stream $Session.Stream -Id $id -Type 2 -Body $Command
    $response = Read-RconPacket -Stream $Session.Stream

    # Vanilla may split long command output across several packets and
    # terminates the answer with an empty one. Drain those quickly.
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($response.Body)) { $lines.Add($response.Body) }
    $Session.Stream.ReadTimeout = 600
    try {
        while ($true) {
            try {
                $more = Read-RconPacket -Stream $Session.Stream
            } catch {
                break
            }
            if ([string]::IsNullOrEmpty($more.Body)) { break }
            $lines.Add($more.Body)
        }
    } finally {
        $Session.Stream.ReadTimeout = $TimeoutMs
    }
    return ($lines -join "`n")
}

function Close-RconSession {
    param([Parameter(Mandatory)]$Session)
    try { $Session.Stream.Dispose() } catch { }
    try { $Session.Client.Close() } catch { }
}

function Invoke-Rcon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Password,
        [int]$Port = 25575,
        [string]$ServerAddress = '127.0.0.1',
        [int]$TimeoutMs = 120000
    )

    $session = Connect-Rcon -Password $Password -Port $Port -ServerAddress $ServerAddress -TimeoutMs $TimeoutMs
    try {
        return (Invoke-RconSession -Session $session -Command $Command -TimeoutMs $TimeoutMs)
    } finally {
        Close-RconSession $session
    }
}

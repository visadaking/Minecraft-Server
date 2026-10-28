#Requires -Version 5.1
<#
    # server panel - a small web UI for the Minecraft server.

    Runs on the same Windows machine as the Minecraft server (RCON stays local)
    and serves a dashboard over HTTP so it can be opened from another computer,
    for example a Linux desktop:  http://<server-ip>:8787

    Settings live in gui.txt (bind address, port, password).

    Started minimized by start.bat.
#>
[CmdletBinding()]
param(
    # Testing aid: keep the panel open even when the server is offline.
    [switch]$NoOfflineExit
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$discordDir = Join-Path $root 'discord'
. (Join-Path $root 'rcon.ps1')
. (Join-Path $discordDir 'discord.ps1')

$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir 'gui.log'

function Write-GuiLog {
    param([string]$Message)
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
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

function Test-Port {
    param([int]$Port, [string]$Target = '127.0.0.1', [int]$TimeoutMs = 800)
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

function Get-PrimaryLanAddress {
    # The panel is a LAN-only service. It must never bind a VPN, Hyper-V,
    # loopback, or link-local address, even if that adapter happens to own the
    # current default route.
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

    return $null
}

function Format-Span {
    param([TimeSpan]$Span)
    if ($Span.TotalMinutes -lt 1) { return 'just started' }
    if ($Span.TotalHours -lt 1) { return ('{0}m' -f [int]$Span.TotalMinutes) }
    if ($Span.TotalDays -lt 1) { return ('{0}h {1}m' -f [int]$Span.TotalHours, $Span.Minutes) }
    return ('{0}d {1}h' -f [int]$Span.TotalDays, $Span.Hours)
}

function Get-ScriptProcesses {
    param([string]$ScriptName)
    $me = $PID
    $pattern = '-File\s+"?[^"\r\n]*' + [regex]::Escape($ScriptName)
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -match $pattern })
}

function Start-ChildScript {
    param([string]$ScriptName, [string[]]$Arguments)
    $path = $ScriptName
    if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $root $path }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path) + $Arguments
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WorkingDirectory $root -WindowStyle Hidden | Out-Null
}

function Get-MinecraftProcess {
    param([int]$CacheSeconds = 4)
    $now = Get-Date
    if ($script:procCacheSet -and ($now - $script:procCacheAt).TotalSeconds -lt $CacheSeconds) {
        return $script:procCache
    }
    $java = Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'server\.jar' } | Select-Object -First 1
    $script:procCache = $java
    $script:procCacheAt = $now
    $script:procCacheSet = $true
    return $java
}

# ------------------------------------------------------------ server control
$script:editableProps = @(
    'motd', 'max-players', 'difficulty', 'gamemode', 'view-distance',
    'simulation-distance', 'online-mode', 'pvp', 'allow-flight', 'white-list',
    'enforce-whitelist'
)

function Invoke-ServerAction {
    param([string]$Action)

    if ($Action -notin @('start', 'stop', 'restart')) {
        return @{ ok = $false; message = 'Unknown action.' }
    }

    $online = Test-Port -Port $script:gamePort
    $proc = Get-MinecraftProcess
    if ($Action -eq 'start' -and $proc) {
        return @{ ok = $true; message = 'The server is already starting or running. Give it a moment.' }
    }
    if ($Action -eq 'start' -and $online) {
        return @{ ok = $true; message = 'The server is already running.' }
    }
    if ($Action -eq 'restart' -and $proc -and -not $online) {
        return @{ ok = $false; message = 'The server is still starting or shutting down. Wait for it to settle, then restart.' }
    }
    if ($Action -eq 'stop' -and -not $online) {
        if ($proc) { return @{ ok = $true; message = 'The server is still shutting down.' } }
        return @{ ok = $true; message = 'The server is already stopped.' }
    }

    Start-ChildScript -ScriptName 'server-control.ps1' -Arguments @('-Action', $Action)
    $script:procCacheSet = $false
    $script:statusCacheAt = $null
    Write-GuiLog ('Server action requested from the panel: ' + $Action)

    $message = $(if ($Action -eq 'start') { 'Starting the server. It takes about a minute to come up.' }
        elseif ($Action -eq 'stop') { 'Stopping the server cleanly. The world is saved first.' }
        else { 'Restarting: the server stops, saves, then starts again.' })
    return @{ ok = $true; message = $message }
}

function Invoke-ServerCommand {
    param([string]$CommandText)

    $CommandText = ([string]$CommandText).Trim()
    if ([string]::IsNullOrWhiteSpace($CommandText)) {
        return @{ ok = $false; message = 'Type a command first.' }
    }
    if (-not (Test-Port -Port $script:gamePort)) {
        return @{ ok = $false; message = 'The server is offline. Start it first.' }
    }

    try {
        if (-not $script:session) {
            $script:session = Connect-Rcon -Password $script:rconPassword -Port $script:rconPort -TimeoutMs 5000
        }
        $output = Invoke-RconSession -Session $script:session -Command $CommandText -TimeoutMs 10000
        Write-GuiLog ('Console command: ' + $CommandText)
        $script:statusCacheAt = $null
        return @{ ok = $true; command = $CommandText; message = (([string]$output).Trim()) }
    } catch {
        if ($script:session) { Close-RconSession $script:session; $script:session = $null }
        return @{ ok = $false; message = $_.Exception.Message }
    }
}

function Get-ServerProperties {
    $values = [ordered]@{}
    foreach ($key in $script:editableProps) {
        $values[$key] = Get-ServerProperty $key ''
    }
    return $values
}

function Get-PropertiesSnapshot {
    $now = Get-Date
    if ($script:propsCache -and $null -ne $script:propsCacheAt -and
        ($now - $script:propsCacheAt).TotalSeconds -lt 5) {
        return $script:propsCache
    }
    $script:propsCache = Get-ServerProperties
    $script:propsCacheAt = $now
    return $script:propsCache
}

function Get-FeedState {
    $path = Join-Path $logDir 'discord-status.json'
    $now = Get-Date
    if ($null -eq $script:feedStateCacheAt -or
        ($now - $script:feedStateCacheAt).TotalSeconds -ge 5) {
        $script:feedStateCache = $null
        if (Test-Path $path) {
            try { $script:feedStateCache = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        }
        $script:feedStateCacheAt = $now
    }
    return $script:feedStateCache
}

function Get-CpuInfo {
    if ($script:cpuInfo) { return $script:cpuInfo }
    $info = @{ name = 'CPU'; cores = $null; threads = $null; maxClock = $null }
    try {
        $p = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($p) {
            $info.name = [string]$p.Name
            $info.cores = [int]$p.NumberOfCores
            $info.threads = [int]$p.NumberOfLogicalProcessors
            $info.maxClock = [int]$p.MaxClockSpeed
        }
    } catch { }
    $script:cpuInfo = $info
    return $info
}

function Initialize-HardwareMonitor {
    if ($script:hwTried) { return $script:hwComputer }
    $script:hwTried = $true
    $lib = Join-Path $root 'tools\LibreHardwareMonitor\LibreHardwareMonitorLib.dll'
    if (-not (Test-Path $lib)) { return $null }
    try {
        Add-Type -Path $lib
        $computer = New-Object LibreHardwareMonitor.Hardware.Computer
        $computer.IsCpuEnabled = $true
        $computer.IsMotherboardEnabled = $true
        $computer.IsGpuEnabled = $true
        $computer.IsMemoryEnabled = $true
        $computer.IsStorageEnabled = $false
        $computer.Open()
        $script:hwComputer = $computer
        Write-GuiLog 'Hardware monitor loaded.'
    } catch {
        Write-GuiLog ('Hardware monitor unavailable: ' + $_.Exception.Message)
        $script:hwComputer = $null
    }
    return $script:hwComputer
}

function Get-SensorMap {
    param($Hardware)
    $map = @{}
    foreach ($s in $Hardware.Sensors) {
        if ($null -ne $s.Value) {
            $map[$s.SensorType.ToString() + '|' + $s.Name] = [double]$s.Value
        }
    }
    return $map
}

function Get-HardwareInfo {
    $now = Get-Date
    if ($null -ne $script:hwCache -and $null -ne $script:hwCacheAt -and
        ($now - $script:hwCacheAt).TotalSeconds -lt 12) {
        return $script:hwCache
    }

    $cpuInfo = Get-CpuInfo
    $cpu = [ordered]@{
        name      = $cpuInfo.name
        load      = $null
        temp      = $null
        clock     = $null
        cores     = $cpuInfo.cores
        threads   = $cpuInfo.threads
        baseClock = $cpuInfo.maxClock
    }
    $gpu = [ordered]@{
        name       = ''
        load       = $null
        temp       = $null
        hotspot    = $null
        fanRpm     = $null
        fanPercent = $null
        memUsedMB  = $null
        memTotalMB = $null
        clock      = $null
    }
    $fans = New-Object System.Collections.Generic.List[object]
    $temps = New-Object System.Collections.Generic.List[object]

    $isAdmin = $false
    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }

    $computer = Initialize-HardwareMonitor
    if ($computer) {
        try {
            foreach ($hw in $computer.Hardware) {
                try { $hw.Update() } catch { }
                $type = $hw.HardwareType.ToString()
                $map = Get-SensorMap -Hardware $hw

                if ($type -eq 'Cpu') {
                    if ($map.ContainsKey('Load|CPU Total')) { $cpu.load = $map['Load|CPU Total'] }
                    if ($map.ContainsKey('Temperature|CPU Package')) { $cpu.temp = $map['Temperature|CPU Package'] }
                    elseif ($map.ContainsKey('Temperature|Core Average')) { $cpu.temp = $map['Temperature|Core Average'] }
                    if ($map.ContainsKey('Clock|P-Core #1')) { $cpu.clock = $map['Clock|P-Core #1'] }
                    if ($null -ne $cpu.temp) {
                        $temps.Add([ordered]@{ label = 'cpu'; value = [math]::Round($cpu.temp, 1) })
                    }
                } elseif ($type -like 'Gpu*') {
                    $gpu.name = $hw.Name
                    if ($map.ContainsKey('Load|GPU Core')) { $gpu.load = $map['Load|GPU Core'] }
                    if ($map.ContainsKey('Temperature|GPU Core')) { $gpu.temp = $map['Temperature|GPU Core'] }
                    if ($map.ContainsKey('Temperature|GPU Hot Spot')) { $gpu.hotspot = $map['Temperature|GPU Hot Spot'] }
                    if ($map.ContainsKey('Fan|GPU Fan')) { $gpu.fanRpm = $map['Fan|GPU Fan'] }
                    if ($map.ContainsKey('Control|GPU Fan')) { $gpu.fanPercent = $map['Control|GPU Fan'] }
                    if ($map.ContainsKey('SmallData|GPU Memory Used')) { $gpu.memUsedMB = $map['SmallData|GPU Memory Used'] }
                    if ($map.ContainsKey('SmallData|GPU Memory Total')) { $gpu.memTotalMB = $map['SmallData|GPU Memory Total'] }
                    if ($map.ContainsKey('Clock|GPU Core')) { $gpu.clock = $map['Clock|GPU Core'] }
                    if ($null -ne $gpu.temp) {
                        $temps.Add([ordered]@{ label = 'gpu'; value = [math]::Round($gpu.temp, 1) })
                    }
                    if ($null -ne $gpu.hotspot) {
                        $temps.Add([ordered]@{ label = 'hotspot'; value = [math]::Round($gpu.hotspot, 1) })
                    }
                    if ($null -ne $gpu.fanRpm -or $null -ne $gpu.fanPercent) {
                        $fans.Add([ordered]@{ label = 'gpu'; rpm = $gpu.fanRpm; percent = $gpu.fanPercent })
                    }
                }

                # Motherboard/CPU fan headers, when the driver can see them.
                if ($type -notlike 'Gpu*') {
                    foreach ($s in $hw.Sensors) {
                        if ($s.SensorType.ToString() -ne 'Fan' -or $null -eq $s.Value) { continue }
                        $percent = $null
                        $ctrlKey = 'Control|' + $s.Name
                        if ($map.ContainsKey($ctrlKey)) { $percent = $map[$ctrlKey] }
                        $label = [string]$s.Name
                        $fans.Add([ordered]@{ label = $label.ToLowerInvariant(); rpm = [double]$s.Value; percent = $percent })
                    }
                }

                # Board sensors often live on a sub-device (Super I/O chip).
                foreach ($sub in $hw.SubHardware) {
                    try { $sub.Update() } catch { }
                    $subMap = Get-SensorMap -Hardware $sub
                    foreach ($s in $sub.Sensors) {
                        $sensorType = $s.SensorType.ToString()
                        if ($null -eq $s.Value) { continue }
                        if ($sensorType -eq 'Fan') {
                            $percent = $null
                            $ctrlKey = 'Control|' + $s.Name
                            if ($subMap.ContainsKey($ctrlKey)) { $percent = $subMap[$ctrlKey] }
                            $fans.Add([ordered]@{
                                label   = ([string]$s.Name).ToLowerInvariant()
                                rpm     = [double]$s.Value
                                percent = $percent
                            })
                        } elseif ($sensorType -eq 'Temperature' -and $type -eq 'Motherboard') {
                            $temps.Add([ordered]@{
                                label = ([string]$s.Name).ToLowerInvariant()
                                value = [math]::Round([double]$s.Value, 1)
                            })
                        }
                    }
                }
            }
        } catch {
            Write-GuiLog ('Hardware read failed: ' + $_.Exception.Message)
        }
    } else {
        # The library is optional. Fall back to WMI and nvidia-smi.
        try {
            $p = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
            if ($p -and $null -ne $p.LoadPercentage) { $cpu.load = [double]$p.LoadPercentage }
        } catch { }

        try {
            $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
            if (Test-Path $smi) {
                $line = (& $smi --query-gpu=name,temperature.gpu,fan.speed,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
                if ($line) {
                    $parts = @($line -split ',' | ForEach-Object { $_.Trim() })
                    if ($parts.Count -ge 6) {
                        $gpu.name = $parts[0]
                        if ($parts[1] -match '^\d+$') { $gpu.temp = [double]$parts[1] }
                        if ($parts[2] -match '^\d+$') { $gpu.fanPercent = [double]$parts[2] }
                        if ($parts[3] -match '^\d+$') { $gpu.load = [double]$parts[3] }
                        if ($parts[4] -match '^\d+$') { $gpu.memUsedMB = [double]$parts[4] }
                        if ($parts[5] -match '^\d+$') { $gpu.memTotalMB = [double]$parts[5] }
                    }
                }
            }
        } catch { }
    }

    if ($null -eq $script:acpiCacheAt -or ($now - $script:acpiCacheAt).TotalSeconds -ge 30) {
        $zoneValues = @()
        try {
            $zones = @(Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop)
            foreach ($z in $zones) {
                $raw = [double]$z.HighPrecisionTemperature
                if ($raw -le 0) { continue }
                $celsius = ($raw / 10) - 273.15
                if ($celsius -gt 0 -and $celsius -lt 120) {
                    $zoneValues += [math]::Round($celsius, 1)
                }
            }
        } catch { }
        $script:acpiCache = $zoneValues
        $script:acpiCacheAt = $now
    }
    $zoneIndex = 0
    foreach ($celsius in @($script:acpiCache)) {
        $zoneIndex++
        $temps.Add([ordered]@{ label = ('acpi ' + $zoneIndex); value = $celsius })
    }

    $seen = @{}
    $tempList = @()
    foreach ($t in $temps) {
        if (-not $seen.ContainsKey($t.label)) {
            $seen[$t.label] = $true
            $tempList += $t
        }
    }

    $seenFans = @{}
    $fanList = @()
    foreach ($f in $fans) {
        $key = [string]$f.label
        if (-not $seenFans.ContainsKey($key)) {
            $seenFans[$key] = $true
            $fanList += $f
        }
    }

    $result = [ordered]@{
        cpu    = $cpu
        gpu    = $gpu
        memory = @{
            usedMB  = $script:ramUsedMB
            totalMB = $script:ramTotalMB
            percent = $(if ($script:ramTotalMB -gt 0) { [math]::Round(($script:ramUsedMB / $script:ramTotalMB) * 100, 1) } else { $null })
        }
        fans   = @($fanList)
        temps  = @($tempList)
        admin  = $isAdmin
    }

    $script:hwCache = $result
    $script:hwCacheAt = $now
    return $result
}

function Save-ServerProperties {
    param($Data)

    if ($null -eq $Data) { return @{ ok = $false; message = 'Nothing to save.' } }

    $path = Join-Path $root 'server.properties'
    if (-not (Test-Path $path)) { return @{ ok = $false; message = 'server.properties was not found.' } }

    $lines = @(Get-Content -Path $path -Encoding UTF8)
    $changed = 0

    foreach ($key in $script:editableProps) {
        if (-not ($Data.PSObject.Properties.Name -contains $key)) { continue }
        $value = [string]$Data.$key
        if ($value -match '[\r\n]') {
            return @{ ok = $false; message = ('The value for ' + $key + ' cannot contain line breaks.') }
        }
        $value = $value.Trim()

        $pattern = '^\s*' + [regex]::Escape($key) + '\s*='
        $newLine = $key + '=' + $value
        $found = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $pattern) {
                if ($lines[$i] -ne $newLine) { $lines[$i] = $newLine; $changed++ }
                $found = $true
                break
            }
        }
        if (-not $found) {
            $lines += $newLine
            $changed++
        }
    }

    if ($changed -gt 0) {
        try {
            [IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))
        } catch {
            return @{ ok = $false; message = ('Could not write server.properties: ' + $_.Exception.Message) }
        }
        $script:difficulty = Get-ServerProperty 'difficulty' '?'
        $script:viewDistance = Get-ServerProperty 'view-distance' '?'
        $script:simDistance = Get-ServerProperty 'simulation-distance' '?'
        $script:onlineMode = Get-ServerProperty 'online-mode' '?'
        $script:maxPlayers = 20
        try { $script:maxPlayers = [int](Get-ServerProperty 'max-players' '20') } catch { }
        $script:propsCache = $null
        $script:propsCacheAt = $null
        $script:statusCacheAt = $null
        Write-GuiLog ('server.properties updated (' + $changed + ' values) from the panel.')
    }

    $online = Test-Port -Port $script:gamePort
    $message = $(if ($changed -eq 0) { 'Nothing changed.' }
        elseif ($online) { 'Saved. Restart the server to apply the changes.' }
        else { 'Saved. The changes apply the next time the server starts.' })
    return @{ ok = $true; message = $message }
}

function Start-BackupNow {
    Start-ChildScript -ScriptName 'backup.ps1' -Arguments @('-Keep', '7')
    Write-GuiLog 'Backup requested from the panel.'
    return @{ ok = $true; message = 'Backup started. It appears under Latest backups when it finishes.' }
}

function Get-DiscordInfo {
    $botPath = Join-Path $discordDir 'discord-bot.txt'
    $webhookPath = Join-Path $discordDir 'discord-webhook.txt'
    $token = Get-DiscordFileKey -Path $botPath -Key 'token'
    $channel = Get-DiscordFileKey -Path $botPath -Key 'channel'
    $webhook = Get-DiscordFileValue -Path $webhookPath
    $config = Get-DiscordConfig -Root $discordDir

    # A bot token starts with the base64 of the bot user id, which is also the
    # application id Discord needs for the "add this bot" link.
    $invite = ''
    if ($token.Length -gt 20) {
        try {
            $b64 = ($token -split '\.')[0].Replace('-', '+').Replace('_', '/')
            while ($b64.Length % 4) { $b64 += '=' }
            $appId = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
            if ($appId -match '^\d{17,20}$') {
                $invite = 'https://discord.com/oauth2/authorize?client_id=' + $appId + '&scope=bot&permissions=69632'
            }
        } catch { }
    }

    [pscustomobject]@{
        mode         = $config.Mode
        configured   = (Test-DiscordConfig $config)
        tokenTail    = $(if ($token.Length -ge 4) { $token.Substring($token.Length - 4) } else { '' })
        channel      = $channel
        webhookSaved = [bool]$webhook
        address      = $(Get-DiscordFileValue -Path (Join-Path $discordDir 'public-address.txt'))
        invite       = $invite
    }
}

function Get-ServerStatus {
    $statusNow = Get-Date
    if ($script:statusCache -and $null -ne $script:statusCacheAt -and
        ($statusNow - $script:statusCacheAt).TotalSeconds -lt 3) {
        return $script:statusCache
    }

    $online = Test-Port -Port $script:gamePort
    $serverProc = Get-MinecraftProcess
    $starting = [bool](-not $online -and $serverProc)
    $players = $null
    $names = @()
    $max = $script:maxPlayers
    $rconOk = $false
    $mspt = $null

    if ($online) {
        if (-not $script:session) {
            try {
                $script:session = Connect-Rcon -Password $script:rconPassword -Port $script:rconPort -TimeoutMs 5000
            } catch {
                $script:session = $null
            }
        }
        if ($script:session) {
            try {
                $list = Invoke-RconSession -Session $script:session -Command 'list' -TimeoutMs 5000
                if ($list -match 'There are (\d+) of a max of (\d+) players online:?\s*(.*)$') {
                    $players = [int]$Matches[1]
                    $max = [int]$Matches[2]
                    $rest = $Matches[3].Trim()
                    if ($rest.Length -gt 0) { $names = @($rest -split ',\s*' | Where-Object { $_.Length -gt 0 }) }
                    $rconOk = $true
                }

                $now = Get-Date
                $gtRaw = Invoke-RconSession -Session $script:session -Command 'time query gametime' -TimeoutMs 5000
                if ($players -gt 0 -and $gtRaw -match 'game time is (\d+)') {
                    $gt = [double]$Matches[1]
                    if ($null -eq $script:tpsBaseGt) {
                        $script:tpsBaseGt = $gt
                        $script:tpsBaseAt = $now
                    } else {
                        $elapsed = ($now - $script:tpsBaseAt).TotalSeconds
                        if ($elapsed -ge 4) {
                            $value = ($gt - $script:tpsBaseGt) / $elapsed
                            if ($value -gt 20) { $value = 20 }
                            if ($value -lt 0) { $value = 0 }
                            $script:tpsValue = [math]::Round($value, 1)
                            $script:tpsBaseGt = $gt
                            $script:tpsBaseAt = $now
                        }
                    }
                } else {
                    $script:tpsBaseGt = $null
                    $script:tpsValue = $null
                }

                try {
                    $tick = Invoke-RconSession -Session $script:session -Command 'tick query' -TimeoutMs 5000
                    if ($tick -match 'Average time per tick:\s*([\d.,]+)\s*ms') {
                        $mspt = [math]::Round([double](($Matches[1]) -replace ',', '.'), 1)
                    }
                } catch { }
            } catch {
                Close-RconSession $script:session
                $script:session = $null
                $script:tpsValue = $null
                $script:tpsBaseGt = $null
            }
        }
    } else {
        if ($script:session) { Close-RconSession $script:session; $script:session = $null }
        $script:tpsValue = $null
        $script:tpsBaseGt = $null
    }

    $uptimeSeconds = $null
    $uptimeText = '--'
    $javaInfo = @{ cpu = $null; memMB = $null; threads = $null }
    if ($online) {
        # Looking the java process up through WMI is the expensive part, so it
        # is refreshed every 20 s; CPU/memory still update on every request.
        if ($null -eq $script:javaCacheAt -or ((Get-Date) - $script:javaCacheAt).TotalSeconds -ge 20) {
            $java = Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match 'server\.jar' } | Select-Object -First 1
            $script:javaPid = $(if ($java) { $java.ProcessId } else { $null })
            $script:javaStart = $(if ($java) { $java.CreationDate } else { $null })
            $script:javaCacheAt = Get-Date
        }
        if ($script:javaPid -and $script:javaStart) {
            $span = (Get-Date) - $script:javaStart
            $uptimeSeconds = [int]$span.TotalSeconds
            $uptimeText = Format-Span -Span $span

            try {
                $proc = Get-Process -Id $script:javaPid -ErrorAction Stop
                $javaInfo.memMB = [math]::Round($proc.WorkingSet64 / 1MB)
                $javaInfo.threads = $proc.Threads.Count

                $cpuNow = $proc.TotalProcessorTime.TotalSeconds
                $cpuAt = Get-Date
                if ($null -ne $script:lastCpuAt -and ($cpuAt - $script:lastCpuAt).TotalSeconds -ge 0.5) {
                    $cores = [Environment]::ProcessorCount
                    $percent = (($cpuNow - $script:lastCpuSeconds) / (($cpuAt - $script:lastCpuAt).TotalSeconds * $cores)) * 100
                    if ($percent -lt 0) { $percent = 0 }
                    if ($percent -gt 100) { $percent = 100 }
                    $javaInfo.cpu = [math]::Round($percent, 1)
                }
                $script:lastCpuSeconds = $cpuNow
                $script:lastCpuAt = $cpuAt
            } catch {
                $script:javaPid = $null
                $script:javaCacheAt = $null
            }
        }
    } else {
        $script:lastCpuAt = $null
        $script:lastCpuSeconds = $null
        $script:javaPid = $null
        $script:javaStart = $null
        $script:javaCacheAt = $null
    }

    $nowSystem = Get-Date
    if ($null -eq $script:systemCacheAt -or ($nowSystem - $script:systemCacheAt).TotalSeconds -ge 10) {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $script:ramTotalMB = [int]($os.TotalVisibleMemorySize / 1024)
            $script:ramUsedMB = $script:ramTotalMB - [int]($os.FreePhysicalMemory / 1024)
        } catch { }
        try {
            $drive = New-Object System.IO.DriveInfo((Get-Item $root).Root.FullName)
            $script:diskTotalGB = [math]::Round($drive.TotalSize / 1GB, 1)
            $script:diskFreeGB = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
        } catch { }
        $script:systemCacheAt = $nowSystem
    }

    $diskFreePct = $null
    if ($script:diskTotalGB -gt 0) {
        $diskFreePct = [math]::Round(($script:diskFreeGB / $script:diskTotalGB) * 100)
    }

    if ($null -eq $script:filesCacheAt -or ($nowSystem - $script:filesCacheAt).TotalSeconds -ge 60) {
        try {
            $bytes = 0
            Get-ChildItem -Path $root -Directory -ErrorAction Stop |
                Where-Object { $_.Name -match '^world' } |
                ForEach-Object {
                    $sum = (Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum).Sum
                    if ($sum) { $bytes += $sum }
                }
            $script:worldMB = [math]::Round($bytes / 1MB, 1)
        } catch { $script:worldMB = $null }

        try {
            $zips = @(Get-ChildItem (Join-Path $root 'backups') -Filter 'backup-*.zip' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
            $script:backupCount = $zips.Count
            $script:backupTotalMB = [math]::Round((($zips | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
            $script:backupList = @($zips | Select-Object -First 4 | ForEach-Object {
                @{ name = $_.Name; mb = [math]::Round($_.Length / 1MB, 1); time = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
            })
        } catch { }
        $script:filesCacheAt = $nowSystem
    }

    if ($null -eq $script:logCacheAt -or ($nowSystem - $script:logCacheAt).TotalSeconds -ge 10) {
        $warnCount = 0
        $errorCount = 0
        $scanned = 0
        $latest = Join-Path $logDir 'latest.log'
        if (Test-Path $latest) {
            try {
                $tail = @(Get-Content -Path $latest -Tail 400 -Encoding UTF8 -ErrorAction Stop)
                $scanned = $tail.Count
                # Only count the current boot. A failed duplicate start leaves
                # scary-looking errors at the top of latest.log that are stale.
                $lastDone = -1
                $lastStarting = -1
                for ($i = 0; $i -lt $tail.Count; $i++) {
                    if ($tail[$i] -match '\[Server thread/INFO\]: Done \(') { $lastDone = $i }
                    elseif ($tail[$i] -match 'Starting minecraft server version') { $lastStarting = $i }
                }
                $startAt = 0
                if ($lastDone -ge 0) { $startAt = $lastDone }
                elseif ($lastStarting -ge 0) { $startAt = $lastStarting }
                for ($i = $startAt; $i -lt $tail.Count; $i++) {
                    $line = $tail[$i]
                    if ($line -match '/(ERROR|FATAL)\]') {
                        $errorCount++
                    } elseif ($line -match '/WARN\]') {
                        # Vanilla emits this when a client drops twice. It is
                        # harmless and should not make the panel look broken.
                        if ($line -notmatch 'handleDisconnection\(\) called twice') { $warnCount++ }
                    }
                }
            } catch { }
        }
        $script:logWarn = $warnCount
        $script:logError = $errorCount
        $script:logScan = $scanned
        $script:logCacheAt = $nowSystem
    }

    # Enumerating powershell processes through WMI is also slow, so the
    # service state is reused for a few seconds.
    if ($null -eq $script:svcCacheAt -or ($nowSystem - $script:svcCacheAt).TotalSeconds -ge 5) {
        $script:feedProcs = @(Get-ScriptProcesses -ScriptName 'discord-status.ps1')
        $script:monitorProcs = @(Get-ScriptProcesses -ScriptName 'tps-monitor.ps1')
        $script:svcCacheAt = $nowSystem
    }
    $feed = @($script:feedProcs)
    $monitor = @($script:monitorProcs)
    $discord = Get-DiscordInfo
    $feedState = Get-FeedState
    $feedPlayers = @()
    if ($feedState -and $feedState.PSObject.Properties.Name -contains 'players') {
        $feedPlayers = @($feedState.players)
    }
    $feedStopped = Test-Path (Join-Path $logDir 'feed-stopped.flag')

    $status = [pscustomobject]@{
        online        = $online
        starting      = $starting
        process       = @{
            running = [bool]$serverProc
            pid     = $(if ($serverProc) { [int]$serverProc.ProcessId } else { $null })
            started = $(if ($serverProc) { $serverProc.CreationDate.ToString('yyyy-MM-dd HH:mm:ss') } else { $null })
        }
        players       = $players
        playerNames   = $names
        maxPlayers    = $max
        tps           = $(if ($online -and $players -gt 0) { $script:tpsValue } else { $null })
        mspt          = $mspt
        rcon          = $rconOk
        uptime        = $uptimeText
        uptimeSeconds = $uptimeSeconds
        address       = $discord.address
        java          = $javaInfo
        system        = @{
            ramUsedMB  = $script:ramUsedMB
            ramTotalMB = $script:ramTotalMB
            diskFreeGB = $script:diskFreeGB
            diskTotalGB = $script:diskTotalGB
            diskFreePct = $diskFreePct
        }
        hardware      = Get-HardwareInfo
        world         = @{
            sizeMB      = $script:worldMB
            difficulty  = $script:difficulty
            view        = $script:viewDistance
            sim         = $script:simDistance
            onlineMode  = $script:onlineMode
        }
        backups       = @{ count = $script:backupCount; totalMB = $script:backupTotalMB; latest = @($script:backupList) }
        log           = @{ warn = $script:logWarn; error = $script:logError; scanned = $script:logScan }
        discord       = $discord
        properties    = Get-PropertiesSnapshot
        feed          = @{
            running    = ($feed.Count -gt 0)
            pids       = @($feed | ForEach-Object { $_.ProcessId })
            online     = $(if ($feedState) { $feedState.online } else { $null })
            players    = $feedPlayers.Count
            manualStop = $feedStopped
        }
        monitor       = @{ running = ($monitor.Count -gt 0); pids = @($monitor | ForEach-Object { $_.ProcessId }) }
        panel         = @{
            bind     = $script:bind
            port     = $script:port
            url      = $script:primaryUrl
            urls     = $script:urls
            password = [bool]$script:password
        }
    }

    $script:statusCache = $status
    $script:statusCacheAt = Get-Date
    return $status
}

function Save-DiscordSettings {
    param($Data)

    if ($null -eq $Data) { return @{ ok = $false; message = 'Nothing to save.' } }

    $botPath = Join-Path $discordDir 'discord-bot.txt'
    $webhookPath = Join-Path $discordDir 'discord-webhook.txt'
    $addressPath = Join-Path $discordDir 'public-address.txt'

    $token = [string]$Data.botToken
    $channel = [string]$Data.channel
    $webhook = [string]$Data.webhook
    $address = [string]$Data.address

    if ($Data.PSObject.Properties.Name -contains 'clearToken' -and $Data.clearToken) { $token = '' }
    if ($Data.PSObject.Properties.Name -contains 'clearWebhook' -and $Data.clearWebhook) { $webhook = '' }

    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = Get-DiscordFileKey -Path $botPath -Key 'token'
    }
    if ([string]::IsNullOrWhiteSpace($channel)) {
        $channel = Get-DiscordFileKey -Path $botPath -Key 'channel'
    }
    if ([string]::IsNullOrWhiteSpace($webhook)) {
        $webhook = Get-DiscordFileValue -Path $webhookPath
    }

    $token = $token.Trim()
    $channel = $channel.Trim()
    $webhook = $webhook.Trim()
    $address = $address.Trim()

    # Accept a full channel link and pull the ID out of it.
    if ($channel -match '/channels/[^/]+/(\d{10,25})') { $channel = $Matches[1] }
    if ($channel -and $channel -notmatch '^\d{10,25}$') {
        return @{ ok = $false; message = 'Channel ID should be a number (right-click the channel > Copy Channel ID).' }
    }
    if ($token -and -not $channel) {
        return @{ ok = $false; message = 'A bot token also needs the channel ID.' }
    }
    if ($webhook -and $webhook -notmatch '^https?://') {
        return @{ ok = $false; message = 'The webhook must be an http(s) URL, or leave it blank.' }
    }

    $botLines = @(
        '# Bot-token setup for the Discord status feed.',
        '# token   = bot token from the Discord Developer Portal',
        '# channel = channel ID where the feed posts',
        '# Managed by the control panel (gui-server.ps1).',
        '',
        ('token=' + $token),
        ('channel=' + $channel)
    )
    [IO.File]::WriteAllLines($botPath, $botLines, (New-Object System.Text.UTF8Encoding($false)))

    $webhookLines = @(
        '# Channel webhook URL (used only when no bot token is set).',
        '# Managed by the control panel (gui-server.ps1).',
        '',
        $webhook
    )
    [IO.File]::WriteAllLines($webhookPath, $webhookLines, (New-Object System.Text.UTF8Encoding($false)))

    $addressLines = @(
        '# Public server address shown in the Discord messages.',
        '# Managed by the control panel (gui-server.ps1).',
        '',
        $address
    )
    [IO.File]::WriteAllLines($addressPath, $addressLines, (New-Object System.Text.UTF8Encoding($false)))

    Write-GuiLog 'Discord settings saved from the control panel.'

    $mode = 'none'
    if ($token -and $channel) { $mode = 'bot' } elseif ($webhook) { $mode = 'webhook' }

    $message = 'Saved.'
    if ($mode -eq 'none') { $message = 'Saved, but the feed has nothing to post with yet.' }
    elseif ($mode -eq 'bot') { $message = 'Saved. The feed will use the bot in channel ' + $channel + '.' }
    else { $message = 'Saved. The feed will use the webhook.' }

    return @{ ok = $true; message = $message }
}

function Invoke-DiscordTest {
    $info = Get-DiscordInfo
    if (-not $info.configured) {
        return @{ ok = $false; message = 'Save a bot token + channel (or a webhook) first.' }
    }
    Write-GuiLog 'Sending a test message from the control panel.'
    try {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $discordDir 'discord-status.ps1') -Test 2>&1
        $code = $LASTEXITCODE
        $text = (@($output) -join ' ').Trim()
        if ($code -eq 0) {
            return @{ ok = $true; message = ($(if ($text) { $text } else { 'Test message sent.' })) }
        }
        if ($text -match '403') {
            $text += ' The bot is not in that Discord server, or it cannot see the channel. Use "Add the bot to my Discord" above.'
        }
        return @{ ok = $false; message = ('Test failed: ' + $text) }
    } catch {
        return @{ ok = $false; message = ('Test failed: ' + $_.Exception.Message) }
    }
}

function Invoke-DiscordCheck {
    $botPath = Join-Path $discordDir 'discord-bot.txt'
    $token = Get-DiscordFileKey -Path $botPath -Key 'token'
    $channel = Get-DiscordFileKey -Path $botPath -Key 'channel'

    if ([string]::IsNullOrWhiteSpace($token)) {
        return @{ ok = $false; message = 'No bot token saved. Paste one above, or use a webhook instead.' }
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ Authorization = 'Bot ' + $token }

    try {
        $me = Invoke-DiscordHttpRequest -Url 'https://discord.com/api/v10/users/@me' -Headers $headers -Method Get
    } catch {
        return @{ ok = $false; message = 'Discord rejected the bot token. Copy it again from the Bot page and save.' }
    }

    $guilds = @()
    try {
        $guilds = @(Invoke-DiscordHttpRequest -Url 'https://discord.com/api/v10/users/@me/guilds' -Headers $headers -Method Get |
            Where-Object { $_.id })
    } catch { }

    if ($guilds.Count -eq 0) {
        return @{
            ok     = $false
            invite = (Get-DiscordInfo).invite
            message = ('The token works (bot ' + $me.username + '), but the bot is not in any Discord server. Click "Add the bot to my Discord", choose your server, then check again.')
        }
    }

    if ([string]::IsNullOrWhiteSpace($channel)) {
        return @{ ok = $false; message = 'The bot is in a server, but no channel ID is saved.' }
    }

    try {
        $ch = Invoke-DiscordHttpRequest -Url ('https://discord.com/api/v10/channels/' + $channel) -Headers $headers -Method Get
    } catch {
        $available = @()
        foreach ($g in $guilds) {
            try {
                $channels = @(Invoke-DiscordHttpRequest -Url ('https://discord.com/api/v10/guilds/' + $g.id + '/channels') -Headers $headers -Method Get |
                    Where-Object { $_.type -eq 0 })
                foreach ($c in $channels) { $available += ('#' + $c.name + ' = ' + $c.id) }
            } catch { }
        }
        $hint = ''
        if ($available.Count -gt 0) {
            $hint = ' Text channels the bot can see: ' + (($available | Select-Object -First 6) -join ', ') + '.'
        }
        return @{
            ok     = $false
            invite = (Get-DiscordInfo).invite
            message = ('The bot cannot see channel ' + $channel + '.' + $hint)
        }
    }

    return @{ ok = $true; message = ('Bot ' + $me.username + ' can post in #' + $ch.name + '. Servers: ' + $guilds.Count + '.') }
}

function Set-ServiceState {
    param([string]$Service, [string]$Action)

    $scriptName = $(if ($Service -eq 'feed') { 'discord\discord-status.ps1' } else { 'tps-monitor.ps1' })
    $processName = $(if ($Service -eq 'feed') { 'discord-status.ps1' } else { 'tps-monitor.ps1' })
    $label = $(if ($Service -eq 'feed') { 'Discord feed' } else { 'TPS monitor' })
    $serviceArgs = $(if ($Service -eq 'feed') {
        @('-PollSeconds', '15', '-UpdateMinutes', '5')
    } else {
        @('-IntervalSeconds', '10', '-Threshold', '18', '-Consecutive', '3', '-CooldownSeconds', '60')
    })

    $running = @(Get-ScriptProcesses -ScriptName $processName)
    $feedMarker = Join-Path $logDir 'feed-stopped.flag'

    if ($Service -eq 'feed') {
        if ($Action -eq 'stop') {
            try { New-Item -ItemType File -Path $feedMarker -Force | Out-Null } catch { }
        } else {
            try { Remove-Item -Path $feedMarker -Force -ErrorAction SilentlyContinue } catch { }
        }
    }

    if ($Action -eq 'stop' -or $Action -eq 'restart') {
        foreach ($proc in $running) {
            try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop } catch { }
        }
        if ($running.Count -gt 0) { Write-GuiLog ('Stopped ' + $label + '.') }
        $running = @()
        if ($Action -eq 'stop') {
            return @{ ok = $true; message = ($label + ' stopped.'); running = $false }
        }
        Start-Sleep -Milliseconds 800
    }

    if ($Action -eq 'start' -or $Action -eq 'restart') {
        if ($running.Count -gt 0) {
            return @{ ok = $true; message = ($label + ' is already running.'); running = $true }
        }
        Start-ChildScript -ScriptName $scriptName -Arguments $serviceArgs
        Write-GuiLog ('Started ' + $label + '.')
        return @{ ok = $true; message = ($label + ' started.'); running = $true }
    }

    return @{ ok = $false; message = 'Unknown action.' }
}

function Ensure-DiscordFeed {
    $marker = Join-Path $logDir 'feed-stopped.flag'
    $online = Test-Port -Port $script:gamePort

    # The stop button is honored until the server next goes offline. That way a
    # manual stop does not fight the watchdog, but a fresh boot always gets a feed.
    if (-not $online) {
        if (Test-Path $marker) {
            try { Remove-Item -Path $marker -Force -ErrorAction Stop } catch { }
        }
        return $false
    }

    if (Test-Path $marker) { return $true }

    $config = Get-DiscordConfig -Root $discordDir
    if (-not (Test-DiscordConfig $config)) { return $true }

    $running = @(Get-ScriptProcesses -ScriptName 'discord-status.ps1')
    if ($running.Count -eq 0) {
        Start-ChildScript -ScriptName 'discord\discord-status.ps1' -Arguments @('-PollSeconds', '15', '-UpdateMinutes', '5')
        Write-GuiLog 'Server is online and the Discord feed was not running; started it.'
        $script:svcCacheAt = $null
        $script:statusCacheAt = $null
    }
    return $true
}

function Get-LogTail {
    param([string]$Which, [int]$Lines)
    $allowed = @{
        'server'         = 'latest.log'
        'discord-status' = 'discord-status.log'
        'tps-monitor'    = 'tps-monitor.log'
        'gui'            = 'gui.log'
    }
    if (-not $allowed.ContainsKey($Which)) { return 'Unknown log.' }
    $path = Join-Path $logDir $allowed[$Which]
    if (-not (Test-Path $path)) { return '(no entries yet)' }
    if ($Lines -lt 10) { $Lines = 10 }
    if ($Lines -gt 400) { $Lines = 400 }
    try { return ((Get-Content -Path $path -Tail $Lines -Encoding UTF8) -join "`n") } catch { return '(could not read the log)' }
}

# ------------------------------------------------------------------- settings
$bindSetting = (Get-Setting 'bind' 'lan').ToLowerInvariant()
$script:bindMode = $bindSetting
if ($bindSetting -eq 'lan') {
    $lanAddress = Get-PrimaryLanAddress
    if ($lanAddress) {
        # Bind the real network card only. localhost and the extra Hyper-V/WSL
        # and VPN adapters then have nothing listening on this port at all.
        $script:bind = $lanAddress
    } else {
        Write-GuiLog 'No physical LAN address was found; refusing to bind localhost or a VPN adapter. The panel will not start.'
        Write-Host 'No physical LAN address was found. Connect the Ethernet cable, then start the server again.'
        exit 1
    }
} else {
    $script:bind = $bindSetting
}
$script:port = 8787
try { $script:port = [int](Get-Setting 'port' '8787') } catch { $script:port = 8787 }
$script:password = Get-Setting 'password' ''

$loopbackOnly = ($script:bind -eq '127.0.0.1' -or $script:bind -eq 'localhost' -or $script:bind -eq '::1')
if (-not $loopbackOnly -and [string]::IsNullOrWhiteSpace($script:password)) {
    # No password: anyone on the LAN can open the panel. That is the intended
    # setup here, so only note it in the log instead of refusing to start.
    Write-GuiLog ('Panel has no password and listens on ' + $script:bind + ' (LAN access). Do not forward port ' + $script:port + ' on the router.')
}

$script:gamePort = 25565
try { $script:gamePort = [int](Get-ServerProperty 'server-port' '25565') } catch { }
$script:maxPlayers = 20
try { $script:maxPlayers = [int](Get-ServerProperty 'max-players' '20') } catch { }
$script:rconPort = 25575
try { $script:rconPort = [int](Get-ServerProperty 'rcon.port' '25575') } catch { }
$script:rconPassword = Get-ServerProperty 'rcon.password' ''

$script:session = $null
$script:tpsValue = $null
$script:tpsBaseGt = $null
$script:tpsBaseAt = $null
$script:lastCpuAt = $null
$script:lastCpuSeconds = $null
$script:systemCacheAt = $null
$script:filesCacheAt = $null
$script:logCacheAt = $null
$script:worldMB = $null
$script:backupList = @()
$script:backupCount = 0
$script:backupTotalMB = $null
$script:logWarn = 0
$script:logError = 0
$script:logScan = 0
$script:hwTried = $false
$script:hwComputer = $null
$script:hwCache = $null
$script:hwCacheAt = $null
$script:cpuInfo = $null
$script:acpiCache = @()
$script:acpiCacheAt = $null
$script:procCache = $null
$script:procCacheAt = $null
$script:procCacheSet = $false
$script:serverOfflineSince = $null

$script:difficulty = Get-ServerProperty 'difficulty' '?'
$script:viewDistance = Get-ServerProperty 'view-distance' '?'
$script:simDistance = Get-ServerProperty 'simulation-distance' '?'
$script:onlineMode = Get-ServerProperty 'online-mode' '?'

# ------------------------------------------------------------------- listeners
$ip = $null
if ($script:bind -eq '0.0.0.0' -or $script:bind -eq '*') {
    $ip = [System.Net.IPAddress]::Any
} elseif ($loopbackOnly) {
    $ip = [System.Net.IPAddress]::Loopback
} else {
    if (-not [System.Net.IPAddress]::TryParse($script:bind, [ref]$ip)) {
        Write-GuiLog ('Invalid bind address: ' + $script:bind)
        Write-Host ('Invalid bind address in gui.txt: ' + $script:bind)
        exit 1
    }
}

$listener = New-Object System.Net.Sockets.TcpListener($ip, $script:port)
try {
    $listener.Start()
} catch {
    Write-GuiLog ('Cannot listen on port ' + $script:port + ': ' + $_.Exception.Message)
    Write-Host ('Cannot listen on port ' + $script:port + ': ' + $_.Exception.Message)
    exit 1
}

$addresses = @()
if ($ip.Equals([System.Net.IPAddress]::Any)) {
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
        Select-Object -ExpandProperty IPAddress)

    # Put the address that carries the default route first: that is the one a
    # Linux desktop on the same network can actually reach.
    $primaryIp = $null
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric | Select-Object -First 1
        if ($route) {
            $primaryIp = (Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Select-Object -First 1).IPAddress
        }
    } catch { }
    if ($primaryIp -and ($addresses -contains $primaryIp)) {
        # Show only the address that actually carries the default route. Extra
        # adapters (Hyper-V, WSL, VPN) are not reachable from the phone or the
        # Linux desktop, so do not advertise them.
        $addresses = @($primaryIp)
    }
    if ($addresses.Count -eq 0) {
        # No usable LAN address even though we bound: do not advertise a
        # localhost URL, the panel is LAN-only on purpose.
        Write-GuiLog 'No LAN address for the URL list; the panel stays LAN-only.'
        exit 1
    }
} else {
    $addresses = @($ip.ToString())
}
$script:urls = @($addresses | ForEach-Object { 'http://' + $_ + ':' + $script:port })
$script:primaryUrl = $script:urls[0]

Write-GuiLog ('Control panel listening on ' + $script:bind + ':' + $script:port + '. URLs: ' + ($script:urls -join ', '))
Write-Host ('server panel: ' + ($script:urls -join '  '))

# ------------------------------------------------------------------------ html
$html = @'
<!doctype html>
<html lang="en" data-theme="storm">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#24283b">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<script>
  (function () {
    var theme = 'storm';
    try {
      if (localStorage.getItem('mcpanel.theme') === 'night') { theme = 'night'; }
    } catch (error) {}
    document.documentElement.setAttribute('data-theme', theme);
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) { meta.setAttribute('content', theme === 'night' ? '#1a1b26' : '#24283b'); }
  })();
</script>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 36 36'%3E%3Cpath d='M18 3 33 10.5v15L18 33 3 25.5v-15Z' fill='%2324283b'/%3E%3Cpath d='M18 5.4 30.6 11.4 18 17.4 5.4 11.4Z' fill='%239ece6a'/%3E%3Cpath d='M5.4 11.4 18 17.4v12.9L5.4 24.3Z' fill='%237aa2f7'/%3E%3Cpath d='M30.6 11.4 18 17.4v12.9l12.6-6Z' fill='%23bb9af7'/%3E%3C/svg%3E">
<title>minecraft server</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #24283b;
    --bg-deep: #1f2335;
    --panel: #292e42;
    --panel-raised: #2f334d;
    --line: #3b4261;
    --line-soft: #2f3450;
    --ink: #c0caf5;
    --ink-soft: #a9b1d6;
    --mute: #737aa2;
    --faint: #565f89;
    --moss: #9ece6a;
    --moss-bright: #b4e87b;
    --moss-dim: #526b3d;
    --sky: #7aa2f7;
    --violet: #bb9af7;
    --amber: #e0af68;
    --rust: #f7768e;
    --track: #343a54;
    --term: #1b1e2d;
    --display: "Bahnschrift", "DIN Alternate", "Segoe UI Variable Display", "Segoe UI", sans-serif;
    --body: "Segoe UI Variable Text", "Segoe UI", system-ui, -apple-system, sans-serif;
    --mono: "Cascadia Mono", "SFMono-Regular", Consolas, "Liberation Mono", monospace;
  }

  html[data-theme="night"] {
    --bg: #1a1b26;
    --bg-deep: #16161e;
    --panel: #1f2335;
    --panel-raised: #292e42;
    --line: #3b4261;
    --line-soft: #282c40;
    --track: #2a2f45;
    --term: #15161e;
  }

  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body {
    margin: 0;
    background:
      radial-gradient(900px 480px at 82% -12%, rgba(122, 162, 247, .075), transparent 62%),
      linear-gradient(rgba(192, 202, 245, .022) 1px, transparent 1px),
      linear-gradient(90deg, rgba(192, 202, 245, .022) 1px, transparent 1px),
      var(--bg);
    background-size: auto, 76px 76px, 76px 76px, auto;
    color: var(--ink);
    font: 14px/1.55 var(--body);
    -webkit-font-smoothing: antialiased;
    text-rendering: optimizeLegibility;
  }
  ::selection { background: var(--moss); color: #1a1b26; }
  * { scrollbar-width: thin; scrollbar-color: #3b4261 transparent; }
  button, input, select { font: inherit; }
  a { color: inherit; }

  .shell {
    display: grid;
    grid-template-columns: 226px minmax(0, 1fr);
    min-height: 100vh;
  }

  .rail {
    position: sticky;
    top: 0;
    height: 100vh;
    padding: 28px 24px 24px;
    border-right: 1px solid var(--line);
    background:
      linear-gradient(180deg, rgba(122, 162, 247, .055), transparent 34%),
      var(--bg-deep);
    display: flex;
    flex-direction: column;
    z-index: 10;
  }

  .brand {
    display: flex;
    align-items: center;
    gap: 11px;
    text-decoration: none;
    margin-bottom: 44px;
  }
  .brand svg { width: 32px; height: 32px; flex: 0 0 32px; }
  .brand b {
    display: block;
    font: 500 15px/1.1 var(--display);
    letter-spacing: .01em;
  }
  .brand em {
    display: block;
    margin-top: 3px;
    font: 9px/1 var(--mono);
    font-style: normal;
    letter-spacing: .16em;
    text-transform: uppercase;
    color: var(--faint);
  }

  .nav { display: flex; flex-direction: column; }
  .nav a {
    position: relative;
    display: flex;
    align-items: baseline;
    gap: 10px;
    padding: 9px 0;
    color: var(--mute);
    text-decoration: none;
    font-size: 12.5px;
    transition: color .15s;
  }
  .nav a span {
    width: 16px;
    font: 9px/1 var(--mono);
    color: var(--faint);
    letter-spacing: .06em;
  }
  .nav a:hover { color: var(--ink); }
  .nav a.active { color: var(--ink); }
  .nav a.active span { color: var(--moss); }
  .nav a.active::before {
    content: "";
    position: absolute;
    left: -24px;
    top: 50%;
    width: 2px;
    height: 15px;
    background: var(--moss);
    transform: translateY(-50%);
  }

  .rail-foot { margin-top: auto; padding-top: 26px; }
  .rail-state {
    display: flex;
    align-items: center;
    gap: 8px;
    font: 10px var(--mono);
    letter-spacing: .08em;
    text-transform: uppercase;
    color: var(--ink-soft);
  }
  .rail-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--faint);
    flex: 0 0 6px;
  }
  .rail-dot.on { background: var(--moss); }
  .rail-dot.wait { background: var(--amber); }
  .rail-url {
    margin: 10px 0 0;
    font: 10px/1.6 var(--mono);
    color: var(--faint);
    word-break: break-all;
  }
  .rail-note {
    margin: 18px 0 0;
    padding-top: 14px;
    border-top: 1px solid var(--line-soft);
    font-size: 10.5px;
    line-height: 1.5;
    color: var(--faint);
  }

  main {
    min-width: 0;
    padding: 24px 34px 44px;
    max-width: 1380px;
  }

  .topline {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 20px;
    margin-bottom: 42px;
    font: 9.5px var(--mono);
    text-transform: uppercase;
    letter-spacing: .15em;
    color: var(--faint);
  }
  .topline-left { display: flex; align-items: center; gap: 9px; }
  .topline-left i { width: 14px; height: 1px; background: var(--line); }
  .topline-left b { color: var(--ink-soft); font-weight: 400; }
  .topline-right { display: flex; align-items: center; gap: 18px; }
  .clock { color: var(--mute); font-variant-numeric: tabular-nums; }

  .conn { display: inline-flex; align-items: center; gap: 7px; color: var(--faint); }
  .conn::before {
    content: "";
    width: 5px;
    height: 5px;
    border-radius: 50%;
    background: currentColor;
  }
  .conn.live { color: var(--moss); }
  .conn.down { color: var(--rust); }

  .theme-btn {
    appearance: none;
    display: inline-flex;
    align-items: center;
    gap: 7px;
    padding: 0;
    border: 0;
    background: none;
    color: var(--faint);
    font: 9.5px var(--mono);
    letter-spacing: .15em;
    text-transform: uppercase;
    cursor: pointer;
    transition: color .15s;
  }
  .theme-btn::before {
    content: "";
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: conic-gradient(var(--violet) 0 50%, var(--sky) 50% 100%);
    box-shadow: 0 0 0 1px rgba(192, 202, 245, .14);
  }
  .theme-btn:hover { color: var(--ink-soft); }
  .theme-btn:focus-visible { outline: 1px solid var(--violet); outline-offset: 4px; }

  .hero {
    display: grid;
    grid-template-columns: minmax(0, 1fr) 330px;
    gap: 54px;
    align-items: end;
    padding-bottom: 34px;
    border-bottom: 1px solid var(--line);
  }
  .eyebrow {
    display: flex;
    align-items: center;
    gap: 9px;
    font: 9.5px var(--mono);
    letter-spacing: .16em;
    text-transform: uppercase;
    color: var(--mute);
  }
  .signal { display: inline-flex; align-items: flex-end; gap: 2px; height: 9px; }
  .signal i { display: block; width: 2px; background: var(--moss); }
  .signal i:nth-child(1) { height: 3px; opacity: .5; }
  .signal i:nth-child(2) { height: 6px; opacity: .75; }
  .signal i:nth-child(3) { height: 9px; }
  .status {
    margin: 14px 0 12px;
    font: 500 clamp(58px, 8.4vw, 104px)/.86 var(--display);
    letter-spacing: -.035em;
    text-transform: uppercase;
    font-variant-numeric: tabular-nums;
  }
  .status.on { color: var(--moss); }
  .status.off { color: #7f89b3; }
  .status.wait { color: var(--amber); }
  .hero-line {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 10px;
    font: 11px var(--mono);
    color: var(--mute);
  }
  .hero-line .sep { width: 18px; height: 1px; background: var(--line); }

  .hero-actions {
    padding-left: 28px;
    border-left: 1px solid var(--line);
    align-self: stretch;
    display: flex;
    flex-direction: column;
    justify-content: flex-end;
  }
  .micro {
    font: 9px var(--mono);
    letter-spacing: .16em;
    text-transform: uppercase;
    color: var(--faint);
  }
  .controls { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 10px; }
  .hero-actions-foot {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    margin-top: 16px;
    padding-top: 14px;
    border-top: 1px solid var(--line-soft);
  }

  .btn {
    appearance: none;
    border: 1px solid var(--line);
    background: var(--panel);
    color: var(--ink-soft);
    padding: 9px 14px;
    border-radius: 2px;
    cursor: pointer;
    font: 11.5px var(--body);
    transition: background .15s, border-color .15s, color .15s;
  }
  .btn:hover { background: var(--panel-raised); border-color: #4b5680; color: var(--ink); }
  .btn:focus-visible { outline: 1px solid var(--moss); outline-offset: 2px; }
  .btn:disabled { opacity: .42; cursor: default; }
  .btn.primary { background: var(--moss); border-color: var(--moss); color: #1a1b26; font-weight: 600; }
  .btn.primary:hover { background: var(--moss-bright); border-color: var(--moss-bright); color: #1a1b26; }
  .btn.danger { color: #f1a7b5; border-color: #543047; background: transparent; }
  .btn.danger:hover { color: #f7bfc9; background: #352034; border-color: #7a4257; }
  .btn.quiet { background: transparent; border-color: transparent; color: var(--mute); padding-left: 0; padding-right: 0; }
  .btn.quiet:hover { color: var(--ink); background: transparent; }
  .btn.small { padding: 6px 10px; font-size: 10.5px; }

  .stats {
    display: grid;
    grid-template-columns: repeat(6, minmax(0, 1fr));
    border-bottom: 1px solid var(--line);
    margin-bottom: 56px;
  }
  .stat { min-width: 0; padding: 20px 18px 18px; border-left: 1px solid var(--line-soft); }
  .stat:first-child { border-left: 0; padding-left: 0; }
  .stat > span {
    display: block;
    font: 8.5px var(--mono);
    letter-spacing: .14em;
    text-transform: uppercase;
    color: var(--faint);
  }
  .stat b {
    display: block;
    margin-top: 7px;
    font: 500 25px/1.2 var(--display);
    letter-spacing: -.01em;
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .stat b.warm { color: var(--amber); }
  .stat b.hot { color: var(--rust); }
  .stat small {
    display: block;
    margin-top: 2px;
    font-size: 10.5px;
    line-height: 1.35;
    color: var(--mute);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .alert {
    border-left: 2px solid var(--rust);
    background: #2e2233;
    padding: 10px 14px;
    margin: 0 0 26px;
    font: 11px/1.6 var(--mono);
    color: #f0b0bd;
  }
  .alert.warn { border-color: var(--amber); background: #2b2839; color: #e8c992; }
  .hidden { display: none !important; }

  .section { padding-bottom: 58px; scroll-margin-top: 20px; }
  .section-head {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    gap: 24px;
    margin-bottom: 20px;
    padding-bottom: 11px;
    border-bottom: 1px solid var(--line);
  }
  .section-title { display: flex; align-items: baseline; gap: 12px; min-width: 0; }
  .no { font: 9px var(--mono); letter-spacing: .12em; color: var(--faint); flex: 0 0 auto; }
  h2 {
    margin: 0;
    font: 500 19px/1.2 var(--display);
    letter-spacing: .005em;
    color: var(--ink);
  }
  .section-meta {
    display: flex;
    align-items: center;
    gap: 16px;
    min-width: 0;
    font: 10px var(--mono);
    color: var(--mute);
  }
  .section-meta .names {
    max-width: 48ch;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .live {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font: 8.5px var(--mono);
    letter-spacing: .14em;
    text-transform: uppercase;
    color: var(--moss);
    white-space: nowrap;
  }
  .live i { width: 5px; height: 5px; border-radius: 50%; background: var(--moss); }

  .rig {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1px;
    background: var(--line);
    border: 1px solid var(--line);
  }
  .device { background: var(--panel); padding: 21px 22px 16px; min-width: 0; }
  .device-head { display: flex; align-items: flex-start; gap: 11px; min-width: 0; }
  .tag {
    flex: 0 0 auto;
    padding: 3px 6px 2px;
    border: 1px solid var(--line);
    font: 8.5px var(--mono);
    letter-spacing: .13em;
    text-transform: uppercase;
    color: var(--moss);
  }
  .tag.cool { color: var(--sky); }
  .device-head > div { min-width: 0; }
  .device-head h3 {
    margin: 0;
    font: 500 14px/1.3 var(--body);
    color: var(--ink);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .device-head p {
    margin: 3px 0 0;
    font: 8.5px var(--mono);
    letter-spacing: .1em;
    text-transform: uppercase;
    color: var(--faint);
  }
  .health {
    margin-left: auto;
    flex: 0 0 auto;
    font: 8.5px var(--mono);
    letter-spacing: .12em;
    text-transform: uppercase;
    color: var(--moss);
  }
  .health.warm { color: var(--amber); }
  .health.hot { color: var(--rust); }
  .health.na { color: var(--faint); }

  .device-read {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    gap: 18px;
    margin: 26px 0 17px;
    min-width: 0;
  }
  .read-main { display: flex; align-items: baseline; flex-wrap: wrap; min-width: 0; }
  .read-num {
    font: 500 54px/.9 var(--display);
    letter-spacing: -.035em;
    font-variant-numeric: tabular-nums;
  }
  .read-unit { margin-left: 3px; font: 300 17px var(--display); color: var(--mute); }
  .read-label {
    width: 100%;
    margin-top: 7px;
    font: 8.5px var(--mono);
    letter-spacing: .13em;
    text-transform: uppercase;
    color: var(--faint);
  }
  .read-side { display: flex; gap: 22px; margin: 0; min-width: 0; }
  .read-side div { min-width: 0; }
  .read-side dt {
    font: 8px var(--mono);
    letter-spacing: .11em;
    text-transform: uppercase;
    color: var(--faint);
  }
  .read-side dd {
    margin: 4px 0 0;
    font: 500 15px/1.2 var(--display);
    color: var(--ink-soft);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }
  .read-note { display: block; margin-top: 2px; font: 8px var(--mono); color: var(--faint); }

  .level { height: 4px; background: var(--track); overflow: hidden; }
  .level i {
    display: block;
    width: 0;
    height: 100%;
    background: var(--moss);
    transition: width .55s cubic-bezier(.2, .7, .2, 1), background .3s;
  }
  .level i.warm { background: var(--amber); }
  .level i.hot { background: var(--rust); }
  .ticks {
    display: flex;
    justify-content: space-between;
    margin-top: 5px;
    font: 8px var(--mono);
    color: #4c557d;
  }

  .spark-wrap { margin-top: 18px; padding-top: 10px; border-top: 1px solid var(--line-soft); }
  .spark-top {
    display: flex;
    justify-content: space-between;
    gap: 10px;
    font: 8.5px var(--mono);
    letter-spacing: .1em;
    text-transform: uppercase;
    color: var(--faint);
  }
  .spark-top b { color: var(--mute); font-weight: 400; font-variant-numeric: tabular-nums; }
  .spark { display: block; width: 100%; height: 44px; margin-top: 3px; overflow: visible; }
  .spark .line { fill: none; stroke-width: 1.5; stroke-linejoin: round; stroke-linecap: round; vector-effect: non-scaling-stroke; }
  .spark .line.cpu { stroke: var(--moss); }
  .spark .line.gpu { stroke: var(--sky); }

  .memory {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1px;
    background: var(--line);
    border: 1px solid var(--line);
    border-top: 0;
  }
  .mem { background: var(--panel); padding: 15px 22px 14px; min-width: 0; }
  .mem-top { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; }
  .mem-top span {
    font: 8.5px var(--mono);
    letter-spacing: .13em;
    text-transform: uppercase;
    color: var(--faint);
  }
  .mem-top b { font: 500 13px var(--display); color: var(--ink-soft); font-variant-numeric: tabular-nums; }
  .mem-track { height: 3px; margin-top: 10px; background: var(--track); overflow: hidden; }
  .mem-track i { display: block; width: 0; height: 100%; background: var(--moss); transition: width .55s ease; }
  .mem.gpu-mem .mem-track i { background: var(--sky); }
  .mem-foot {
    display: flex;
    justify-content: space-between;
    gap: 12px;
    margin-top: 6px;
    font: 8.5px var(--mono);
    color: var(--faint);
    white-space: nowrap;
    overflow: hidden;
  }
  .mem-foot span { overflow: hidden; text-overflow: ellipsis; }

  .sensor-row {
    display: flex;
    align-items: flex-start;
    gap: 18px;
    padding-top: 15px;
    min-width: 0;
  }
  .sensor-row > .micro { padding-top: 5px; flex: 0 0 auto; }
  .sensors { display: flex; flex-wrap: wrap; gap: 5px; min-width: 0; }
  .sensor {
    display: inline-flex;
    align-items: baseline;
    gap: 6px;
    padding: 4px 8px;
    border: 1px solid var(--line);
    background: var(--panel);
    font: 9.5px var(--mono);
    color: var(--mute);
    white-space: nowrap;
  }
  .sensor b { color: var(--ink-soft); font-weight: 400; font-variant-numeric: tabular-nums; }
  .sensor em { font-style: normal; color: var(--faint); }
  .sensor .fan {
    align-self: center;
    width: 11px;
    height: 11px;
    color: var(--sky);
    animation: spin 1.35s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
  .sensor-row .empty { padding-top: 3px; }

  .hint {
    margin: 13px 0 0;
    max-width: 88ch;
    font-size: 10.5px;
    line-height: 1.6;
    color: var(--faint);
  }

  .split {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
    gap: 24px;
    margin-bottom: 58px;
    scroll-margin-top: 20px;
  }
  .card { background: var(--panel); border: 1px solid var(--line); padding: 21px 22px; min-width: 0; }
  .card-head {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    gap: 18px;
    margin-bottom: 16px;
    padding-bottom: 11px;
    border-bottom: 1px solid var(--line);
  }
  .card-head .section-title { min-width: 0; }
  .card-head h2 { font-size: 16px; }
  .meta { font: 8.5px var(--mono); letter-spacing: .12em; text-transform: uppercase; color: var(--faint); }

  .people { display: flex; flex-wrap: wrap; gap: 6px; min-height: 34px; align-items: flex-start; }
  .person {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 3px 9px 3px 3px;
    border: 1px solid var(--line);
    font-size: 11.5px;
    color: var(--ink-soft);
  }
  .person i {
    width: 23px;
    height: 23px;
    display: grid;
    place-items: center;
    background: #2e3552;
    border: 1px solid #3b4261;
    color: var(--moss);
    font: 9px var(--mono);
    font-style: normal;
    text-transform: uppercase;
  }
  .empty {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    font-size: 11px;
    color: var(--faint);
  }
  .empty::before {
    content: "";
    width: 5px;
    height: 5px;
    border: 1px solid var(--faint);
    transform: rotate(45deg);
  }

  .backups { display: flex; flex-direction: column; }
  .backup-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) 58px 102px;
    gap: 10px;
    align-items: baseline;
    padding: 6px 0;
    border-bottom: 1px solid var(--line-soft);
    font: 10px var(--mono);
    color: var(--mute);
  }
  .backup-row:first-child { padding-top: 0; }
  .backup-row .name { color: var(--ink-soft); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .backup-row .size { text-align: right; font-variant-numeric: tabular-nums; }
  .backup-row .time { text-align: right; color: var(--faint); font-variant-numeric: tabular-nums; }
  .backup-foot { margin-top: 10px; font: 8.5px var(--mono); color: var(--faint); }
  .card-foot {
    margin: 15px 0 0;
    padding-top: 11px;
    border-top: 1px solid var(--line-soft);
    font: 8.5px var(--mono);
    letter-spacing: .1em;
    text-transform: uppercase;
    color: var(--faint);
  }

  .console { padding: 0; margin-bottom: 58px; scroll-margin-top: 20px; }
  .console-head { align-items: flex-end; margin: 0; padding: 18px 22px 0; border-bottom: 0; }
  .tabs { display: flex; gap: 17px; min-width: 0; overflow-x: auto; }
  .tabs button {
    appearance: none;
    background: none;
    border: 0;
    border-bottom: 1px solid transparent;
    padding: 6px 0;
    margin-bottom: -1px;
    color: var(--faint);
    font: 8.5px var(--mono);
    letter-spacing: .12em;
    text-transform: uppercase;
    cursor: pointer;
    white-space: nowrap;
  }
  .tabs button:hover { color: var(--ink-soft); }
  .tabs button.active { color: var(--ink); border-color: var(--moss); }
  .console-tools {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 14px;
    padding: 9px 22px;
    border-top: 1px solid var(--line);
    border-bottom: 1px solid var(--line);
    background: var(--bg-deep);
  }
  .input-line {
    width: 270px;
    max-width: 100%;
    border: 0;
    border-bottom: 1px solid var(--line);
    background: transparent;
    padding: 4px 0;
    color: var(--ink);
    font: 10.5px var(--mono);
  }
  .input-line::placeholder { color: var(--faint); }
  .input-line:focus { outline: 0; border-color: var(--moss); }
  .switch {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    font: 8.5px var(--mono);
    letter-spacing: .1em;
    text-transform: uppercase;
    color: var(--mute);
    cursor: pointer;
    white-space: nowrap;
  }
  .switch input {
    appearance: none;
    position: relative;
    width: 24px;
    height: 13px;
    margin: 0;
    border: 1px solid var(--line);
    background: var(--bg-deep);
    cursor: pointer;
  }
  .switch input::after {
    content: "";
    position: absolute;
    top: 2px;
    left: 2px;
    width: 7px;
    height: 7px;
    background: var(--faint);
    transition: left .15s, background .15s;
  }
  .switch input:checked { border-color: #4f6b3b; background: #223026; }
  .switch input:checked::after { left: 13px; background: var(--moss); }
  .log-hint { margin-left: auto; font: 8.5px var(--mono); color: var(--faint); }

  .term {
    margin: 0;
    height: 286px;
    overflow: auto;
    padding: 14px 22px;
    background: var(--term);
    color: #bac4ea;
    font: 11px/1.7 var(--mono);
    white-space: pre-wrap;
    word-break: break-word;
    border: 0;
  }
  .term .err { color: #f7768e; }

  .cmd {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 9px 22px;
    border-top: 1px solid var(--line);
    background: var(--panel);
  }
  .prompt { font: 11px var(--mono); color: var(--moss); }
  .cmd input {
    flex: 1;
    min-width: 0;
    border: 0;
    background: transparent;
    color: var(--ink);
    font: 11px var(--mono);
    padding: 4px 0;
  }
  .cmd input::placeholder { color: var(--faint); }
  .cmd input:focus { outline: 0; }
  .cmd button {
    appearance: none;
    border: 1px solid var(--line);
    background: var(--panel-raised);
    color: var(--ink-soft);
    font: 9px var(--mono);
    letter-spacing: .1em;
    text-transform: uppercase;
    padding: 5px 10px;
    cursor: pointer;
  }
  .cmd button:hover { border-color: #4b5680; color: var(--ink); }
  .cmd-out {
    margin: 0;
    max-height: 92px;
    min-height: 34px;
    overflow: auto;
    padding: 9px 22px;
    border-top: 1px solid var(--line-soft);
    background: var(--bg-deep);
    color: var(--mute);
    font: 10px/1.65 var(--mono);
    white-space: pre-wrap;
  }

  .setup { padding-bottom: 26px; scroll-margin-top: 20px; }
  .drawer { border-top: 1px solid var(--line); }
  .drawer:last-of-type { border-bottom: 1px solid var(--line); }
  .drawer summary {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 15px 0;
    cursor: pointer;
    list-style: none;
  }
  .drawer summary::-webkit-details-marker { display: none; }
  .drawer summary .no { width: 20px; }
  .drawer summary .label { min-width: 0; }
  .drawer summary b {
    display: block;
    font: 500 13.5px/1.3 var(--body);
    color: var(--ink-soft);
  }
  .drawer summary small {
    display: block;
    margin-top: 2px;
    font-size: 10.5px;
    color: var(--faint);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .chev {
    margin-left: auto;
    width: 7px;
    height: 7px;
    flex: 0 0 7px;
    border-right: 1px solid var(--mute);
    border-bottom: 1px solid var(--mute);
    transform: rotate(45deg);
    transition: transform .18s;
  }
  .drawer[open] .chev { transform: rotate(-135deg); }
  .drawer-body { padding: 6px 0 28px 36px; }
  .drawer-body > .note { margin: 0 0 16px; }
  .note { font-size: 11px; line-height: 1.6; color: var(--mute); }

  form { display: grid; gap: 17px; max-width: 790px; }
  label {
    display: grid;
    gap: 6px;
    font: 8.5px var(--mono);
    letter-spacing: .11em;
    text-transform: uppercase;
    color: var(--faint);
  }
  input[type=text], input[type=password], input[type=number], select, input:not([type]) {
    width: 100%;
    border: 1px solid var(--line);
    border-radius: 0;
    background: var(--bg-deep);
    padding: 8px 10px;
    color: var(--ink);
    font: 11.5px var(--body);
    letter-spacing: 0;
    text-transform: none;
  }
  input:focus, select:focus {
    outline: 0;
    border-color: #5b78b8;
    box-shadow: inset 0 0 0 1px #5b78b8;
  }
  select { cursor: pointer; }
  .two { display: grid; grid-template-columns: 1fr 1fr; gap: 17px; }
  .row { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
  .row .note { margin: 0; }
  .btnlink {
    display: inline-flex;
    align-items: center;
    padding: 8px 12px;
    border: 1px solid var(--line);
    color: var(--ink-soft);
    text-decoration: none;
    font-size: 11px;
  }
  .btnlink:hover { border-color: #4b5680; color: var(--ink); }

  .service {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 20px;
    padding: 14px 0;
    border-top: 1px solid var(--line-soft);
  }
  .service:first-child { border-top: 0; padding-top: 0; }
  .service-name { display: flex; align-items: center; font-size: 12px; color: var(--ink-soft); }
  .dot { width: 5px; height: 5px; border-radius: 50%; background: var(--faint); display: inline-block; margin-right: 8px; }
  .dot.on { background: var(--moss); }
  .service-state { margin: 4px 0 0 13px; font-size: 10.5px; color: var(--faint); }
  .service-actions { display: flex; flex-wrap: wrap; gap: 5px; justify-content: flex-end; }

  .toast {
    position: fixed;
    right: 22px;
    bottom: 22px;
    z-index: 30;
    max-width: 390px;
    padding: 11px 14px;
    background: var(--bg-deep);
    border: 1px solid var(--line);
    border-left: 2px solid var(--moss);
    font: 10.5px/1.6 var(--mono);
    color: var(--ink-soft);
    box-shadow: 0 14px 40px rgba(0, 0, 0, .38);
    opacity: 0;
    transform: translateY(6px);
    transition: opacity .16s, transform .16s;
    pointer-events: none;
  }
  .toast.show { opacity: 1; transform: none; }
  .toast.bad { border-left-color: var(--rust); }

  footer {
    display: flex;
    justify-content: space-between;
    gap: 18px;
    padding-top: 16px;
    border-top: 1px solid var(--line);
    font: 8.5px/1.6 var(--mono);
    letter-spacing: .08em;
    text-transform: uppercase;
    color: var(--faint);
  }

  @keyframes rise {
    from { opacity: 0; transform: translateY(5px); }
    to { opacity: 1; transform: none; }
  }
  .hero, .stats, .section, .split, .console, .setup {
    animation: rise .45s ease both;
  }
  .stats { animation-delay: .04s; }
  .section { animation-delay: .08s; }

  @media (max-width: 1120px) {
    .hero { grid-template-columns: minmax(0, 1fr) 290px; gap: 34px; }
    .stats { grid-template-columns: repeat(3, minmax(0, 1fr)); }
    .stat:nth-child(3n+1) { border-left: 0; padding-left: 0; }
    .stat:nth-child(n+4) { border-top: 1px solid var(--line-soft); }
    .rig { grid-template-columns: 1fr; }
  }

  @media (max-width: 900px) {
    .shell { display: block; }
    .rail {
      position: sticky;
      height: auto;
      padding: 13px 18px;
      border-right: 0;
      border-bottom: 1px solid var(--line);
      flex-direction: row;
      align-items: center;
      gap: 18px;
      overflow-x: auto;
    }
    .brand { margin: 0; flex: 0 0 auto; }
    .brand em { display: none; }
    .brand svg { width: 26px; height: 26px; }
    .nav { flex-direction: row; margin-left: auto; gap: 4px; }
    .nav a { padding: 7px 8px; font-size: 11.5px; white-space: nowrap; }
    .nav a span, .nav a.active::before { display: none; }
    .rail-foot { display: none; }
    main { padding: 20px 20px 38px; }
    .topline { margin-bottom: 30px; }
    .hero { grid-template-columns: 1fr; gap: 28px; }
    .hero-actions { padding-left: 0; border-left: 0; padding-top: 22px; border-top: 1px solid var(--line); }
    .status { font-size: clamp(56px, 14vw, 88px); }
    .split { grid-template-columns: 1fr; gap: 18px; }
    .console-head { flex-wrap: wrap; gap: 10px; }
    .tabs { width: 100%; }
    .drawer-body { padding-left: 0; }
  }

  @media (max-width: 620px) {
    main { padding: 16px 14px 32px; }
    .rail { padding: 11px 14px; }
    .brand b { font-size: 13px; }
    .brand svg { width: 23px; height: 23px; }
    .nav a { padding: 7px 5px; font-size: 10.5px; }
    .brand span { display: none; }
    .brand { margin-right: 2px; }
    .nav { gap: 2px; }
    .topline-right { gap: 12px; }
    .topline-right .clock { display: none; }
    .theme-prefix { display: none; }
    .stats { grid-template-columns: 1fr 1fr; }
    .stat { padding: 15px 13px 14px; }
    .stat:nth-child(3n+1) { padding-left: 13px; border-left: 1px solid var(--line-soft); }
    .stat:nth-child(odd) { padding-left: 0; border-left: 0; }
    .stat:nth-child(n+3) { border-top: 1px solid var(--line-soft); }
    .stat b { font-size: 21px; }
    .hero { gap: 22px; }
    .hero-line { font-size: 10px; }
    .controls { width: 100%; }
    .controls .btn { flex: 1; }
    .device { padding: 17px 15px 14px; }
    .device-read { gap: 10px; margin-top: 22px; }
    .read-num { font-size: 44px; }
    .read-side { gap: 14px; flex-wrap: wrap; }
    .read-side dd { font-size: 13px; }
    .memory { grid-template-columns: 1fr; }
    .sensor-row { gap: 8px; flex-direction: column; }
    .console-tools { padding: 9px 14px; gap: 10px; }
    .input-line { width: 100%; }
    .log-hint { display: none; }
    .term { padding: 12px 14px; height: 260px; font-size: 10px; }
    .cmd { padding: 9px 14px; }
    .cmd-out { padding: 9px 14px; }
    .console-head { padding: 16px 14px 0; }
    .card { padding: 17px 15px; }
    .backup-row { grid-template-columns: minmax(0, 1fr) 48px 86px; }
    .drawer summary { gap: 10px; }
    .drawer summary small { white-space: normal; }
    .two { grid-template-columns: 1fr; }
    .service { flex-direction: column; gap: 10px; }
    .service-actions { justify-content: flex-start; }
    footer { flex-direction: column; gap: 5px; }
    .toast { left: 14px; right: 14px; bottom: 14px; max-width: none; }
  }

  @media (prefers-reduced-motion: reduce) {
    * { animation-duration: .001ms !important; animation-iteration-count: 1 !important; transition-duration: .001ms !important; scroll-behavior: auto !important; }
  }
</style>
</head>
<body>
<div class="shell">
  <aside class="rail">
    <a class="brand" href="#overview" aria-label="back to the top">
      <svg viewBox="0 0 36 36" aria-hidden="true">
        <path d="M18 3 33 10.5v15L18 33 3 25.5v-15Z" fill="#24283b"/>
        <path d="M18 5.4 30.6 11.4 18 17.4 5.4 11.4Z" fill="#9ece6a"/>
        <path d="M5.4 11.4 18 17.4v12.9L5.4 24.3Z" fill="#7aa2f7"/>
        <path d="M30.6 11.4 18 17.4v12.9l12.6-6Z" fill="#bb9af7"/>
      </svg>
      <span><b>minecraft</b><em>server console</em></span>
    </a>

    <nav class="nav" aria-label="sections">
      <a href="#overview" data-label="overview" class="active"><span>01</span>overview</a>
      <a href="#machine" data-label="machine"><span>02</span>the machine</a>
      <a href="#people" data-label="company"><span>03</span>company</a>
      <a href="#console" data-label="console"><span>04</span>console</a>
      <a href="#setup" data-label="setup"><span>05</span>setup</a>
    </nav>

    <div class="rail-foot">
      <div class="rail-state"><i class="rail-dot" id="railDot"></i><span id="railState">checking</span></div>
      <p class="rail-url" id="panelUrl">http://10.0.0.15:8787</p>
      <p class="rail-note">home network only. do not forward this port or expose it through the tunnel.</p>
    </div>
  </aside>

  <main>
    <div class="topline">
      <div class="topline-left"><span>server room</span><i></i><b id="crumbSection">overview</b></div>
      <div class="topline-right">
        <button class="theme-btn" id="themeBtn" type="button" title="Tokyo Night Storm - switch to classic">
          <span class="theme-prefix">theme&nbsp;</span><span id="themeLabel">storm</span>
        </button>
        <span class="clock" id="clock">--:--</span>
        <span class="conn" id="conn">connecting</span>
      </div>
    </div>

    <div id="alert" class="alert hidden"></div>

    <section class="hero" id="overview">
      <div>
        <div class="eyebrow"><span class="signal"><i></i><i></i><i></i></span>dedicated server</div>
        <h1 class="status off" id="srv">Offline</h1>
        <div class="hero-line">
          <span id="addr">port 25565 &middot; this machine</span>
          <span class="sep"></span>
          <span id="heroNote">waiting for the world</span>
        </div>
      </div>
      <div class="hero-actions">
        <span class="micro">power</span>
        <div class="controls">
          <button id="srvStart" class="btn primary">start</button>
          <button id="srvRestart" class="btn">restart</button>
          <button id="srvStop" class="btn danger">stop</button>
        </div>
        <div class="hero-actions-foot">
          <button id="backupNow" class="btn quiet">backup now</button>
          <span class="micro">local snapshots</span>
        </div>
      </div>
    </section>

    <section class="stats" aria-label="server vitals">
      <div class="stat"><span>players</span><b id="players">--</b><small id="playersNote">offline</small></div>
      <div class="stat"><span>ticks / second</span><b id="tps">--</b><small id="mspt">--</small></div>
      <div class="stat"><span>uptime</span><b id="uptime">--</b><small>since boot</small></div>
      <div class="stat"><span>java cpu</span><b id="cpu">--</b><small id="threads"></small></div>
      <div class="stat"><span>world</span><b id="world">--</b><small id="worldNote"></small></div>
      <div class="stat"><span>disk free</span><b id="disk">--</b><small id="diskNote"></small></div>
    </section>

    <section class="section" id="machine">
      <div class="section-head">
        <div class="section-title"><span class="no">02</span><h2>the machine</h2></div>
        <div class="section-meta">
          <span class="names" id="pcNames">reading sensors</span>
          <span class="live"><i></i>live</span>
        </div>
      </div>

      <div class="rig">
        <article class="device">
          <div class="device-head">
            <span class="tag">cpu</span>
            <div>
              <h3 id="cpuName">processor</h3>
              <p id="cpuCores">&mdash;</p>
            </div>
            <span class="health" id="cpuHealth">no data</span>
          </div>
          <div class="device-read">
            <div class="read-main">
              <span class="read-num" id="cpuLoad">--</span><span class="read-unit">%</span>
              <span class="read-label">utilisation</span>
            </div>
            <dl class="read-side">
              <div><dt>temp</dt><dd id="cpuTemp">&mdash;</dd><small class="read-note" id="cpuTempNote"></small></div>
              <div><dt>clock</dt><dd id="cpuClock">&mdash;</dd></div>
            </dl>
          </div>
          <div class="level"><i id="cpuLoadBar"></i></div>
          <div class="ticks"><span>0</span><span>25</span><span>50</span><span>75</span><span>100</span></div>
          <div class="spark-wrap">
            <div class="spark-top"><span>load &middot; last 60 s</span><b id="cpuSparkNow">--</b></div>
            <svg class="spark" viewBox="0 0 240 56" preserveAspectRatio="none" aria-hidden="true">
              <defs><linearGradient id="cpuFill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" style="stop-color: var(--moss)" stop-opacity=".28"></stop><stop offset="1" style="stop-color: var(--moss)" stop-opacity="0"></stop></linearGradient></defs>
              <path id="cpuArea" fill="url(#cpuFill)" d=""></path>
              <polyline id="cpuLine" class="line cpu" points=""></polyline>
            </svg>
          </div>
        </article>

        <article class="device">
          <div class="device-head">
            <span class="tag cool">gpu</span>
            <div>
              <h3 id="gpuName">graphics</h3>
              <p>display adapter</p>
            </div>
            <span class="health" id="gpuHealth">no data</span>
          </div>
          <div class="device-read">
            <div class="read-main">
              <span class="read-num" id="gpuLoad">--</span><span class="read-unit">%</span>
              <span class="read-label">utilisation</span>
            </div>
            <dl class="read-side">
              <div><dt>temp</dt><dd id="gpuTemp">&mdash;</dd><small class="read-note" id="gpuTempNote"></small></div>
              <div><dt>clock</dt><dd id="gpuClock">&mdash;</dd></div>
              <div><dt>fan</dt><dd id="gpuFan">&mdash;</dd></div>
            </dl>
          </div>
          <div class="level"><i id="gpuLoadBar"></i></div>
          <div class="ticks"><span>0</span><span>25</span><span>50</span><span>75</span><span>100</span></div>
          <div class="spark-wrap">
            <div class="spark-top"><span>load &middot; last 60 s</span><b id="gpuSparkNow">--</b></div>
            <svg class="spark" viewBox="0 0 240 56" preserveAspectRatio="none" aria-hidden="true">
              <defs><linearGradient id="gpuFill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" style="stop-color: var(--sky)" stop-opacity=".26"></stop><stop offset="1" style="stop-color: var(--sky)" stop-opacity="0"></stop></linearGradient></defs>
              <path id="gpuArea" fill="url(#gpuFill)" d=""></path>
              <polyline id="gpuLine" class="line gpu" points=""></polyline>
            </svg>
          </div>
        </article>
      </div>

      <div class="memory">
        <div class="mem">
          <div class="mem-top"><span>system memory</span><b id="ramPct">--</b></div>
          <div class="mem-track"><i id="ramFill"></i></div>
          <div class="mem-foot"><span id="ramDetail">--</span><span id="ramTotal"></span></div>
        </div>
        <div class="mem gpu-mem">
          <div class="mem-top"><span>gpu memory</span><b id="vramPct">--</b></div>
          <div class="mem-track"><i id="vramFill"></i></div>
          <div class="mem-foot"><span id="vramDetail">--</span><span id="vramTotal"></span></div>
        </div>
      </div>

      <div class="sensor-row">
        <span class="micro">fans &amp; thermals</span>
        <div class="sensors" id="pcSensors"></div>
      </div>
      <p class="hint" id="pcHint"></p>
    </section>

    <div class="split" id="people">
      <section class="card">
        <div class="card-head">
          <div class="section-title"><span class="no">03</span><h2>company</h2></div>
          <span class="meta" id="peopleCount">--</span>
        </div>
        <div class="people" id="playerList"></div>
        <p class="card-foot" id="peopleNote">max players &middot; whitelist &middot; difficulty</p>
      </section>

      <section class="card">
        <div class="card-head">
          <div class="section-title"><span class="no">04</span><h2>backups</h2></div>
          <span class="meta">local zip</span>
        </div>
        <div class="backups" id="backups"></div>
      </section>
    </div>

    <section class="card console" id="console">
      <div class="card-head console-head">
        <div class="section-title"><span class="no">05</span><h2>console</h2></div>
        <div class="tabs">
          <button data-log="server" class="active">server</button>
          <button data-log="discord-status">discord</button>
          <button data-log="tps-monitor">tps</button>
          <button data-log="gui">panel</button>
        </div>
      </div>
      <div class="console-tools">
        <input id="logFilter" class="input-line" placeholder="filter lines &mdash; warn, error, a player name" autocapitalize="none" autocorrect="off" spellcheck="false">
        <label class="switch"><input type="checkbox" id="onlyIssues">issues only</label>
        <span class="log-hint" id="logHint">last 200 lines</span>
      </div>
      <pre id="log" class="term">loading...</pre>
      <div class="cmd">
        <span class="prompt">&gt;</span>
        <input id="cmdInput" placeholder="type a server command" autocapitalize="none" autocorrect="off" spellcheck="false">
        <button id="cmdSend">run</button>
      </div>
      <pre id="cmdOut" class="cmd-out">output appears here</pre>
    </section>

    <section class="setup" id="setup">
      <div class="section-head">
        <div class="section-title"><span class="no">06</span><h2>setup</h2></div>
        <span class="meta">server.properties &middot; discord &middot; services</span>
      </div>

      <details class="drawer">
        <summary>
          <span class="no">a</span>
          <span class="label"><b>server settings</b><small>motd, difficulty, distances, whitelist</small></span>
          <span class="chev"></span>
        </summary>
        <div class="drawer-body">
          <form id="props">
            <label>motd &mdash; the text in the server list
              <input id="p-motd" type="text" autocapitalize="none" spellcheck="false">
            </label>
            <div class="two">
              <label>max players
                <input id="p-max-players" type="number" min="1" max="200" inputmode="numeric">
              </label>
              <label>difficulty
                <select id="p-difficulty"><option>peaceful</option><option>easy</option><option>normal</option><option>hard</option></select>
              </label>
            </div>
            <div class="two">
              <label>gamemode
                <select id="p-gamemode"><option>survival</option><option>creative</option><option>adventure</option><option>spectator</option></select>
              </label>
              <label>view distance
                <input id="p-view-distance" type="number" min="2" max="32" inputmode="numeric">
              </label>
            </div>
            <div class="two">
              <label>simulation distance
                <input id="p-simulation-distance" type="number" min="2" max="32" inputmode="numeric">
              </label>
              <label>online mode
                <select id="p-online-mode"><option value="true">true &mdash; licensed accounts only</option><option value="false">false &mdash; allow cracked launchers</option></select>
              </label>
            </div>
            <div class="two">
              <label>pvp
                <select id="p-pvp"><option value="true">on</option><option value="false">off</option></select>
              </label>
              <label>allow flight
                <select id="p-allow-flight"><option value="false">off</option><option value="true">on</option></select>
              </label>
            </div>
            <div class="two">
              <label>whitelist
                <select id="p-white-list"><option value="false">off</option><option value="true">on</option></select>
              </label>
              <label>enforce whitelist
                <select id="p-enforce-whitelist"><option value="false">off</option><option value="true">on</option></select>
              </label>
            </div>
            <div class="row">
              <button type="submit" class="btn primary">save settings</button>
              <span class="note">written to server.properties &middot; restart to apply</span>
            </div>
          </form>
        </div>
      </details>

      <details class="drawer">
        <summary>
          <span class="no">b</span>
          <span class="label"><b>discord connection</b><small>bot or webhook &middot; join and leave messages</small></span>
          <span class="chev"></span>
        </summary>
        <div class="drawer-body">
          <div class="note" id="discordState" style="margin-bottom:14px">--</div>
          <div class="row" style="margin-bottom:14px">
            <a id="inviteBot" class="btnlink" href="#" target="_blank" rel="noreferrer" style="display:none">add the bot to discord</a>
            <button type="button" id="checkBtn" class="btn">check connection</button>
          </div>
          <div class="note" id="checkResult" style="margin-bottom:16px"></div>
          <form id="cfg">
            <div class="two">
              <label>bot token
                <input id="token" type="password" autocomplete="off" spellcheck="false">
              </label>
              <label>channel id
                <input id="channel" type="text" inputmode="numeric" autocomplete="off" placeholder="right-click channel &gt; copy channel id">
              </label>
            </div>
            <label>webhook url &mdash; alternative to a bot
              <input id="webhook" type="password" autocomplete="off" spellcheck="false">
            </label>
            <label>public server address &mdash; optional
              <input id="address" type="text" autocomplete="off" placeholder="something.playit.gg:12345">
            </label>
            <div class="row">
              <button type="submit" class="btn primary">save</button>
              <button type="button" id="testBtn" class="btn">send test message</button>
              <button type="button" id="clearToken" class="btn danger">remove bot token</button>
              <button type="button" id="clearWebhook" class="btn danger">remove webhook</button>
            </div>
            <span class="note">saved values stay hidden. leave a field blank to keep what is stored.</span>
          </form>
        </div>
      </details>

      <details class="drawer">
        <summary>
          <span class="no">c</span>
          <span class="label"><b>services</b><small>discord feed and tps alerts</small></span>
          <span class="chev"></span>
        </summary>
        <div class="drawer-body">
          <div class="service">
            <div>
              <div class="service-name"><span class="dot" id="feedDot"></span>discord feed</div>
              <div class="service-state" id="feedState">--</div>
            </div>
            <div class="service-actions">
              <button data-svc="feed" data-action="start" class="btn small primary">start</button>
              <button data-svc="feed" data-action="restart" class="btn small">restart</button>
              <button data-svc="feed" data-action="stop" class="btn small danger">stop</button>
            </div>
          </div>
          <div class="service">
            <div>
              <div class="service-name"><span class="dot" id="monDot"></span>tps alerts</div>
              <div class="service-state" id="monState">--</div>
            </div>
            <div class="service-actions">
              <button data-svc="monitor" data-action="start" class="btn small primary">start</button>
              <button data-svc="monitor" data-action="restart" class="btn small">restart</button>
              <button data-svc="monitor" data-action="stop" class="btn small danger">stop</button>
            </div>
          </div>
          <p class="note" style="margin-top:12px">the panel keeps the feed running whenever the server is on. stopping it here keeps it off until the next server boot.</p>
        </div>
      </details>
    </section>

    <footer>
      <span>home network only &middot; panel closes shortly after the server stops</span>
      <span id="footClock">--</span>
    </footer>
  </main>
</div>

<div id="toast" class="toast"></div>

<script>
  var logWhich = 'server';
  var logRaw = '';
  var toastTimer = null;
  var refreshing = false;
  var histCpu = [];
  var histGpu = [];

  function el(id) { return document.getElementById(id); }
  function isNum(v) { return typeof v === 'number' && isFinite(v); }
  function clampPct(v) { return Math.max(0, Math.min(100, v)); }

  function setText(id, text) {
    var node = el(id);
    if (node) { node.textContent = text; }
  }

  function applyTheme(theme, save) {
    var night = theme === 'night';
    var value = night ? 'night' : 'storm';
    document.documentElement.setAttribute('data-theme', value);
    if (save) {
      try { localStorage.setItem('mcpanel.theme', value); } catch (error) {}
    }
    setText('themeLabel', value);
    var button = el('themeBtn');
    if (button) {
      button.title = night ? 'Tokyo Night classic - switch to Storm' : 'Tokyo Night Storm - switch to classic';
      button.setAttribute('aria-label', button.title);
    }
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) { meta.setAttribute('content', night ? '#1a1b26' : '#24283b'); }
  }

  function toast(message, bad) {
    var t = el('toast');
    t.textContent = message;
    t.className = 'toast show' + (bad ? ' bad' : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.className = 'toast'; }, bad ? 9000 : 4500);
  }

  function api(path, options) {
    var opts = options || {};
    opts.headers = { 'Content-Type': 'application/json' };
    return fetch(path, opts).then(function (res) {
      if (!res.ok) { throw new Error('HTTP ' + res.status); }
      return res.json();
    });
  }

  function setDot(id, on) {
    var d = el(id);
    if (d) { d.className = on ? 'dot on' : 'dot'; }
  }

  function fmtMB(mb) {
    if (mb === null || mb === undefined) { return '--'; }
    if (mb >= 1024) { return (mb / 1024).toFixed(1) + ' GB'; }
    return Math.round(mb) + ' MB';
  }

  function clockText() {
    var d = new Date();
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }

  function tickClock() {
    setText('clock', clockText());
    var d = new Date();
    setText('footClock', d.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' }) + ' \u00b7 ' + clockText());
  }

  function tint(id, level) {
    var node = el(id);
    if (!node) { return; }
    node.classList.remove('warm', 'hot');
    if (level) { node.classList.add(level); }
  }

  function paintConn(ok) {
    var c = el('conn');
    c.textContent = ok ? 'live' : 'no link';
    c.className = 'conn ' + (ok ? 'live' : 'down');
  }

  function paintBanner(s) {
    var lg = s.log || {};
    var sys = s.system || {};
    var problems = [];
    if (lg.error > 0) {
      problems.push(lg.error + ' error line' + (lg.error === 1 ? '' : 's') + ' in the current server log');
    }
    if (sys.diskFreePct !== null && sys.diskFreePct !== undefined && sys.diskFreePct < 10) {
      problems.push('disk is only ' + sys.diskFreePct + '% free');
    }
    var banner = el('alert');
    if (problems.length) {
      banner.className = 'alert';
      banner.textContent = problems.join(' \u00b7 ') + '. check the console below.';
    } else if (lg.warn > 0) {
      banner.className = 'alert warn';
      banner.textContent = lg.warn + ' warning line' + (lg.warn === 1 ? '' : 's') + ' in the current server log. no errors.';
    } else {
      banner.className = 'alert hidden';
      banner.textContent = '';
    }
  }

  function paintStatus(s) {
    var state = s.online ? 'Online' : (s.starting ? 'Starting' : 'Offline');
    var srv = el('srv');
    srv.textContent = state;
    srv.className = 'status ' + (s.online ? 'on' : (s.starting ? 'wait' : 'off'));
    setText('heroNote', s.online ? 'world is running' : (s.starting ? 'loading the world' : 'no listener on 25565'));
    setText('addr', s.address || 'port 25565 \u00b7 this machine');

    var railState = el('railState');
    railState.textContent = state.toLowerCase();
    var railDot = el('railDot');
    railDot.className = 'rail-dot' + (s.online ? ' on' : (s.starting ? ' wait' : ''));

    if (s.online && s.players !== null) {
      setText('players', s.players + ' / ' + s.maxPlayers);
      setText('playersNote', s.rcon ? 'from the server' : 'rcon not answering');
    } else if (s.starting) {
      setText('players', '--');
      setText('playersNote', 'server is starting');
    } else {
      setText('players', '--');
      setText('playersNote', 'offline');
    }

    if (!s.online) {
      setText('tps', '--');
      setText('mspt', '--');
    } else if (s.tps === null || s.tps === undefined) {
      setText('tps', 'idle');
      setText('mspt', 'no players');
    } else {
      setText('tps', s.tps.toFixed(1));
      setText('mspt', (s.mspt === null || s.mspt === undefined) ? 'no tick sample' : (s.mspt + ' ms / tick'));
    }

    setText('uptime', s.online ? s.uptime : '--');

    var j = s.java || {};
    setText('cpu', (j.cpu === null || j.cpu === undefined) ? '--' : j.cpu.toFixed(1) + '%');
    tint('cpu', j.cpu > 85 ? 'hot' : (j.cpu > 60 ? 'warm' : null));
    setText('threads', j.threads ? (j.threads + ' threads') : '');
    setText('jmem', fmtMB(j.memMB));

    var sys = s.system || {};
    if (sys.diskTotalGB) {
      setText('disk', sys.diskFreeGB.toFixed(1) + ' GB');
      setText('diskNote', sys.diskFreePct + '% of ' + sys.diskTotalGB.toFixed(1) + ' GB');
      tint('disk', sys.diskFreePct < 8 ? 'hot' : (sys.diskFreePct < 15 ? 'warm' : null));
    } else {
      setText('disk', '--');
      setText('diskNote', '');
    }

    var props = s.properties || {};
    var w = s.world || {};
    setText('world', fmtMB(w.sizeMB));
    var bits = [];
    if (props.difficulty || (w.difficulty && w.difficulty !== '?')) { bits.push('difficulty ' + (props.difficulty || w.difficulty)); }
    if (props['view-distance'] || (w.view && w.view !== '?')) { bits.push('view ' + (props['view-distance'] || w.view)); }
    setText('worldNote', bits.join(' \u00b7 '));
  }

  function emptyNote(text) {
    var span = document.createElement('span');
    span.className = 'empty';
    span.textContent = text;
    return span;
  }

  function paintPlayers(s) {
    var box = el('playerList');
    box.textContent = '';
    var props = s.properties || {};
    var bits = [];
    if (s.maxPlayers) { bits.push('max ' + s.maxPlayers); }
    if (props['white-list'] !== undefined) { bits.push('whitelist ' + (props['white-list'] === 'true' ? 'on' : 'off')); }
    if (props.difficulty) { bits.push(props.difficulty); }
    setText('peopleNote', bits.join(' \u00b7 '));
    if (!s.online) {
      setText('peopleCount', 'offline');
      box.appendChild(emptyNote('offline'));
      return;
    }
    var count = (s.playerNames && s.playerNames.length) ? s.playerNames.length : (s.players || 0);
    setText('peopleCount', count + ' online');
    if (s.playerNames && s.playerNames.length) {
      s.playerNames.forEach(function (name) {
        var person = document.createElement('span');
        person.className = 'person';
        var initial = document.createElement('i');
        initial.textContent = name.charAt(0);
        var label = document.createElement('span');
        label.textContent = name;
        person.appendChild(initial);
        person.appendChild(label);
        box.appendChild(person);
      });
    } else {
      box.appendChild(emptyNote('nobody is on the server'));
    }
  }

  function paintBackups(s) {
    var box = el('backups');
    box.textContent = '';
    var bk = s.backups || {};
    var latest = bk.latest || [];
    if (!latest.length) {
      box.appendChild(emptyNote('no backups yet'));
      return;
    }
    latest.forEach(function (b) {
      var row = document.createElement('div');
      row.className = 'backup-row';
      var name = document.createElement('span');
      name.className = 'name';
      name.textContent = b.name;
      var size = document.createElement('span');
      size.className = 'size';
      size.textContent = b.mb + ' MB';
      var time = document.createElement('span');
      time.className = 'time';
      time.textContent = b.time;
      row.appendChild(name);
      row.appendChild(size);
      row.appendChild(time);
      box.appendChild(row);
    });
    var foot = document.createElement('div');
    foot.className = 'backup-foot';
    foot.textContent = bk.count + ' backup' + (bk.count === 1 ? '' : 's') + ' \u00b7 ' + fmtMB(bk.totalMB) + ' total';
    box.appendChild(foot);
  }

  function paintSettings(s) {
    var p = s.properties;
    if (!p) { return; }
    if (el('props').getAttribute('data-dirty') === '1') { return; }
    Object.keys(p).forEach(function (key) {
      var field = el('p-' + key);
      if (field && document.activeElement !== field) { field.value = p[key]; }
    });
  }

  function paintFeedState(s) {
    var fs = s.feed || {};
    var text;
    if (fs.running) {
      text = 'running';
      if (fs.online === true) { text += ' \u00b7 server shown as on'; }
      else if (fs.online === false) { text += ' \u00b7 server shown as off'; }
      if (fs.players) { text += ' \u00b7 ' + fs.players + ' player' + (fs.players === 1 ? '' : 's') + ' tracked'; }
      if (fs.pids && fs.pids.length) { text += ' (pid ' + fs.pids.join(', ') + ')'; }
    } else if (fs.manualStop) {
      text = 'stopped by hand \u00b7 starts again on the next server boot';
    } else if (s.online) {
      text = 'not running \u00b7 starting automatically';
    } else {
      text = 'stopped';
    }
    setText('feedState', text);
  }

  function shortName(value, type) {
    if (!value) { return ''; }
    var text = value.replace(/\(R\)/g, '').replace(/\(TM\)/g, '').replace(/\s+/g, ' ').trim();
    if (type === 'cpu') {
      text = text.replace(/^\d+(st|nd|rd|th) Gen Intel Core /i, 'Intel ');
      text = text.replace(/\s+CPU(\s+@.*)?$/i, '');
    } else {
      text = text.replace(/^NVIDIA GeForce /i, '');
      text = text.replace(/^AMD Radeon /i, 'Radeon ');
    }
    return text;
  }

  function setBar(id, value, tone) {
    var bar = el(id);
    if (!bar) { return; }
    var pct = isNum(value) ? clampPct(value) : 0;
    bar.style.width = pct + '%';
    bar.className = tone || '';
  }

  function setHealth(id, temp, load) {
    var node = el(id);
    if (!node) { return; }
    var tone = '';
    var text = 'nominal';
    if (isNum(temp)) {
      if (temp >= 85) { tone = 'hot'; text = 'hot'; }
      else if (temp >= 72) { tone = 'warm'; text = 'warm'; }
    } else if (isNum(load)) {
      if (load >= 92) { tone = 'hot'; text = 'busy'; }
      else if (load >= 75) { tone = 'warm'; text = 'busy'; }
    } else {
      tone = 'na';
      text = 'no data';
    }
    node.className = 'health' + (tone ? ' ' + tone : '');
    node.textContent = text;
  }

  function addSensor(label, value, sub, fanRpm) {
    var box = el('pcSensors');
    var chip = document.createElement('span');
    chip.className = 'sensor';
    if (fanRpm) {
      var icon = document.createElement('span');
      icon.className = 'fan';
      icon.innerHTML = '<svg viewBox="0 0 24 24" width="11" height="11" aria-hidden="true"><g fill="currentColor"><ellipse cx="12" cy="7" rx="2.2" ry="4.2"></ellipse><ellipse cx="12" cy="7" rx="2.2" ry="4.2" transform="rotate(120 12 12)"></ellipse><ellipse cx="12" cy="7" rx="2.2" ry="4.2" transform="rotate(240 12 12)"></ellipse><circle cx="12" cy="12" r="1.7" fill="var(--panel)"></circle></g></svg>';
      icon.style.animationDuration = Math.max(0.35, Math.min(2.2, 900 / Math.max(150, fanRpm))) + 's';
      chip.appendChild(icon);
    }
    var name = document.createElement('span');
    name.textContent = label;
    chip.appendChild(name);
    var strong = document.createElement('b');
    strong.textContent = value;
    chip.appendChild(strong);
    if (sub) {
      var extra = document.createElement('em');
      extra.textContent = sub;
      chip.appendChild(extra);
    }
    box.appendChild(chip);
  }

  function drawSpark(prefix, values) {
    var line = el(prefix + 'Line');
    var area = el(prefix + 'Area');
    var pts = [];
    var step = values.length > 1 ? 240 / (values.length - 1) : 240;
    for (var i = 0; i < values.length; i++) {
      if (!isNum(values[i])) { continue; }
      var x = (i * step).toFixed(1);
      var y = (54 - clampPct(values[i]) / 100 * 50).toFixed(1);
      pts.push(x + ',' + y);
    }
    line.setAttribute('points', pts.join(' '));
    if (pts.length > 0) {
      area.setAttribute('d', 'M' + pts.join(' L') + ' L240,56 L0,56 Z');
    } else {
      area.setAttribute('d', '');
    }
  }

  function pushHistory(arr, value) {
    arr.push(isNum(value) ? clampPct(value) : null);
    if (arr.length > 24) { arr.shift(); }
  }

  function paintPC(hw) {
    var box = el('pcSensors');
    box.textContent = '';

    if (!hw) {
      setText('pcNames', 'sensor data unavailable');
      setText('cpuName', 'processor');
      setText('cpuCores', '\u2014');
      setText('gpuName', 'graphics');
      setText('cpuLoad', '--');
      setText('gpuLoad', '--');
      setText('cpuTemp', '\u2014');
      setText('gpuTemp', '\u2014');
      setText('cpuClock', '\u2014');
      setText('gpuClock', '\u2014');
      setText('gpuFan', '\u2014');
      setText('ramPct', '--');
      setText('ramDetail', '--');
      setText('ramTotal', '');
      setText('vramPct', '--');
      setText('vramDetail', '--');
      setText('vramTotal', '');
      setBar('cpuLoadBar', null);
      setBar('gpuLoadBar', null);
      setBar('ramFill', null);
      setBar('vramFill', null);
      setHealth('cpuHealth', null, null);
      setHealth('gpuHealth', null, null);
      setText('pcHint', 'the sensor library was not loaded.');
      return;
    }

    var cpu = hw.cpu || {};
    var gpu = hw.gpu || {};
    var mem = hw.memory || {};

    var cpuShort = shortName(cpu.name, 'cpu');
    var gpuShort = shortName(gpu.name, 'gpu');
    var names = [cpuShort, gpuShort].filter(Boolean);
    setText('pcNames', names.length ? names.join('  \u00b7  ') : 'this computer');
    el('pcNames').title = [cpu.name, gpu.name].filter(Boolean).join(' / ');

    setText('cpuName', cpuShort || cpu.name || 'processor');
    el('cpuName').title = cpu.name || '';
    var cores = [];
    if (cpu.cores) { cores.push(cpu.cores + ' cores'); }
    if (cpu.threads) { cores.push(cpu.threads + ' threads'); }
    setText('cpuCores', cores.length ? cores.join(' / ') : '\u2014');

    setText('cpuLoad', isNum(cpu.load) ? Math.round(cpu.load) : '--');
    setBar('cpuLoadBar', cpu.load, isNum(cpu.load) ? (cpu.load >= 90 ? 'hot' : (cpu.load >= 70 ? 'warm' : '')) : '');
    setText('cpuTemp', isNum(cpu.temp) ? cpu.temp.toFixed(1) + '\u00b0' : '\u2014');
    setText('cpuTempNote', isNum(cpu.temp) ? '' : 'needs admin');
    setText('cpuClock', isNum(cpu.clock) ? (cpu.clock / 1000).toFixed(2) + ' GHz' : (isNum(cpu.baseClock) ? (cpu.baseClock / 1000).toFixed(2) + ' GHz' : '\u2014'));
    setHealth('cpuHealth', cpu.temp, cpu.load);

    setText('gpuName', gpuShort || gpu.name || 'graphics');
    el('gpuName').title = gpu.name || '';
    setText('gpuLoad', isNum(gpu.load) ? Math.round(gpu.load) : '--');
    setBar('gpuLoadBar', gpu.load, isNum(gpu.load) ? (gpu.load >= 90 ? 'hot' : (gpu.load >= 70 ? 'warm' : '')) : '');
    setText('gpuTemp', isNum(gpu.temp) ? gpu.temp.toFixed(1) + '\u00b0' : '\u2014');
    setText('gpuTempNote', isNum(gpu.temp) ? '' : 'unavailable');
    setText('gpuClock', isNum(gpu.clock) ? (gpu.clock / 1000).toFixed(2) + ' GHz' : '\u2014');
    setText('gpuFan', isNum(gpu.fanRpm) ? Math.round(gpu.fanRpm) + ' rpm' : '\u2014');
    setHealth('gpuHealth', gpu.temp, gpu.load);

    var ramPct = isNum(mem.percent) ? mem.percent :
      (isNum(mem.usedMB) && isNum(mem.totalMB) && mem.totalMB > 0 ? mem.usedMB / mem.totalMB * 100 : null);
    setText('ramPct', isNum(ramPct) ? Math.round(ramPct) + '%' : '--');
    setBar('ramFill', ramPct);
    setText('ramDetail', isNum(mem.usedMB) ? fmtMB(mem.usedMB) + ' used' : '--');
    setText('ramTotal', isNum(mem.totalMB) ? 'of ' + fmtMB(mem.totalMB) : '');

    var vramPct = (isNum(gpu.memUsedMB) && isNum(gpu.memTotalMB) && gpu.memTotalMB > 0) ? (gpu.memUsedMB / gpu.memTotalMB * 100) : null;
    setText('vramPct', isNum(vramPct) ? Math.round(vramPct) + '%' : '--');
    setBar('vramFill', vramPct);
    setText('vramDetail', isNum(gpu.memUsedMB) ? fmtMB(gpu.memUsedMB) + ' used' : '--');
    setText('vramTotal', isNum(gpu.memTotalMB) ? 'of ' + fmtMB(gpu.memTotalMB) : '');

    (hw.fans || []).forEach(function (fan) {
      var label = fan.label || 'fan';
      var value = isNum(fan.rpm) ? Math.round(fan.rpm) + ' rpm' : '--';
      var sub = isNum(fan.percent) ? Math.round(fan.percent) + '%' : '';
      addSensor(label, value, sub, isNum(fan.rpm) ? fan.rpm : 900);
    });
    (hw.temps || []).forEach(function (temp) {
      if (!isNum(temp.value)) { return; }
      if (temp.label === 'cpu' || temp.label === 'gpu') { return; }
      addSensor(temp.label || 'temp', temp.value.toFixed(1) + '\u00b0C');
    });
    if (!box.children.length) {
      box.appendChild(emptyNote('no extra sensors exposed by this board'));
    }

    pushHistory(histCpu, cpu.load);
    pushHistory(histGpu, gpu.load);
    drawSpark('cpu', histCpu);
    drawSpark('gpu', histGpu);
    setText('cpuSparkNow', isNum(cpu.load) ? Math.round(cpu.load) + '%' : '--');
    setText('gpuSparkNow', isNum(gpu.load) ? Math.round(gpu.load) + '%' : '--');

    var hints = [];
    if (hw.admin === false) {
      hints.push('cpu package temperature and motherboard fan headers need administrator access; gpu sensors are live.');
    }
    if (!hw.fans || !hw.fans.length) {
      hints.push('no fan rpm is exposed to windows on this board.');
    }
    setText('pcHint', hints.join('  \u00b7  '));
  }

  function paintDiscord(s) {
    var d = s.discord || {};
    var parts = [];
    if (d.mode === 'bot') { parts.push('bot saved (****' + d.tokenTail + ') \u00b7 channel ' + d.channel); }
    else if (d.mode === 'webhook') { parts.push('webhook saved'); }
    else { parts.push('not configured \u2014 add a bot token or a webhook below'); }
    if (d.address) { parts.push('address ' + d.address); }
    setText('discordState', parts.join('  \u00b7  '));

    if (d.invite && d.mode === 'bot') {
      el('inviteBot').href = d.invite;
      el('inviteBot').style.display = '';
    } else {
      el('inviteBot').style.display = 'none';
    }

    if (document.activeElement !== el('channel')) { el('channel').value = d.channel || ''; }
    if (document.activeElement !== el('address')) { el('address').value = d.address || ''; }
    el('token').placeholder = d.tokenTail ? 'saved (****' + d.tokenTail + ') \u2014 leave blank to keep' : 'paste the bot token';
    el('webhook').placeholder = d.webhookSaved ? 'saved \u2014 leave blank to keep' : 'https://discord.com/api/webhooks/...';
  }

  function paintServices(s) {
    setDot('feedDot', s.feed.running);
    setDot('monDot', s.monitor.running);
    paintFeedState(s);
    setText('monState', s.monitor.running ? ('running' + (s.monitor.pids.length ? ' (pid ' + s.monitor.pids.join(', ') + ')' : '')) : 'stopped');
  }

  function refresh() {
    if (refreshing) { return; }
    refreshing = true;
    api('/api/status').then(function (s) {
      paintConn(true);
      paintBanner(s);
      paintStatus(s);
      paintPlayers(s);
      paintPC(s.hardware);
      paintBackups(s);
      paintSettings(s);
      paintDiscord(s);
      paintServices(s);
      var urls = (s.panel && s.panel.urls) || [];
      if (urls.length) {
        setText('panelUrl', urls[0]);
        el('panelUrl').title = urls.join('  ');
      }
      el('srvStart').disabled = !!(s.online || s.starting);
      el('srvStop').disabled = !s.online;
    }).catch(function () {
      paintConn(false);
    }).then(function () { refreshing = false; });
  }

  function paintLog() {
    var pre = el('log');
    var atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 40;
    var text = logRaw;
    var needle = el('logFilter').value.trim().toLowerCase();
    var only = el('onlyIssues').checked;

    if (needle || only) {
      var out = [];
      var rows = text.split('\n');
      for (var i = 0; i < rows.length; i++) {
        var line = rows[i];
        if (needle && line.toLowerCase().indexOf(needle) === -1) { continue; }
        if (only && !/\/(warn|error|fatal)\]|exception|caused by|severe/i.test(line)) { continue; }
        out.push(line);
      }
      text = out.length ? out.join('\n') : '(nothing in the last 200 lines matches)';
    }

    pre.textContent = text;
    if (atBottom) { pre.scrollTop = pre.scrollHeight; }
  }

  function loadLog() {
    api('/api/logs?which=' + encodeURIComponent(logWhich) + '&lines=200').then(function (r) {
      logRaw = r.text || '';
      paintLog();
      setText('logHint', 'last 200 lines');
    }).catch(function () { el('log').textContent = 'could not load the log.'; });
  }

  el('logFilter').addEventListener('input', paintLog);
  el('onlyIssues').addEventListener('change', paintLog);

  el('cfg').addEventListener('submit', function (ev) {
    ev.preventDefault();
    var body = {
      botToken: el('token').value.trim(),
      channel: el('channel').value.trim(),
      webhook: el('webhook').value.trim(),
      address: el('address').value.trim()
    };
    api('/api/config', { method: 'POST', body: JSON.stringify(body) }).then(function (r) {
      toast(r.message, !r.ok);
      if (r.ok) { el('token').value = ''; el('webhook').value = ''; refresh(); }
    }).catch(function (e) { toast('save failed: ' + e.message, true); });
  });

  el('testBtn').addEventListener('click', function () {
    var btn = el('testBtn');
    btn.disabled = true;
    btn.textContent = 'sending...';
    api('/api/test', { method: 'POST', body: '{}' }).then(function (r) {
      toast(r.message, !r.ok);
    }).catch(function (e) {
      toast('test failed: ' + e.message, true);
    }).then(function () {
      btn.disabled = false;
      btn.textContent = 'send test message';
    });
  });

  el('clearToken').addEventListener('click', function () {
    if (!confirm('remove the saved bot token?')) { return; }
    api('/api/config', { method: 'POST', body: JSON.stringify({ clearToken: true }) }).then(function (r) {
      toast(r.message, !r.ok); refresh();
    });
  });

  el('clearWebhook').addEventListener('click', function () {
    if (!confirm('remove the saved webhook?')) { return; }
    api('/api/config', { method: 'POST', body: JSON.stringify({ clearWebhook: true }) }).then(function (r) {
      toast(r.message, !r.ok); refresh();
    });
  });

  Array.prototype.forEach.call(document.querySelectorAll('button[data-svc]'), function (btn) {
    btn.addEventListener('click', function () {
      var svc = btn.getAttribute('data-svc');
      var action = btn.getAttribute('data-action');
      api('/api/' + svc, { method: 'POST', body: JSON.stringify({ action: action }) }).then(function (r) {
        toast(r.message, !r.ok); refresh();
      }).catch(function (e) { toast(e.message, true); });
    });
  });

  Array.prototype.forEach.call(document.querySelectorAll('button[data-log]'), function (btn) {
    btn.addEventListener('click', function () {
      logWhich = btn.getAttribute('data-log');
      Array.prototype.forEach.call(document.querySelectorAll('button[data-log]'), function (b) { b.className = ''; });
      btn.className = 'active';
      el('log').textContent = 'loading...';
      loadLog();
    });
  });

  function serverAction(action, confirmText) {
    if (confirmText && !confirm(confirmText)) { return; }
    api('/api/server', { method: 'POST', body: JSON.stringify({ action: action }) }).then(function (r) {
      toast(r.message, !r.ok);
      setTimeout(refresh, 1500);
    }).catch(function (e) { toast(e.message, true); });
  }

  el('srvStart').addEventListener('click', function () { serverAction('start'); });
  el('srvRestart').addEventListener('click', function () { serverAction('restart', 'restart the minecraft server now?'); });
  el('srvStop').addEventListener('click', function () { serverAction('stop', 'stop the minecraft server? the world is saved first.'); });

  el('backupNow').addEventListener('click', function () {
    api('/api/backup', { method: 'POST', body: '{}' }).then(function (r) {
      toast(r.message, !r.ok);
    }).catch(function (e) { toast(e.message, true); });
  });

  function runCommand() {
    var text = el('cmdInput').value.trim();
    if (!text) { return; }
    el('cmdInput').value = '';
    api('/api/command', { method: 'POST', body: JSON.stringify({ command: text }) }).then(function (r) {
      var out = '> ' + text + '\n' + (r.ok ? (r.message || '(no output)') : ('error: ' + r.message));
      var box = el('cmdOut');
      box.textContent = (box.textContent === 'output appears here') ? out : (box.textContent + '\n\n' + out);
      box.scrollTop = box.scrollHeight;
    }).catch(function (e) { toast('command failed: ' + e.message, true); });
  }

  el('cmdSend').addEventListener('click', runCommand);
  el('cmdInput').addEventListener('keydown', function (ev) {
    if (ev.key === 'Enter') { ev.preventDefault(); runCommand(); }
  });

  function loadProps() {
    if (el('props').getAttribute('data-dirty') === '1') { return; }
    api('/api/properties').then(function (p) {
      Object.keys(p).forEach(function (key) {
        var field = el('p-' + key);
        if (field && document.activeElement !== field) { field.value = p[key]; }
      });
    }).catch(function () { });
  }

  ['input', 'change'].forEach(function (evt) {
    el('props').addEventListener(evt, function () {
      el('props').setAttribute('data-dirty', '1');
    });
  });

  el('props').addEventListener('submit', function (ev) {
    ev.preventDefault();
    var keys = ['motd', 'max-players', 'difficulty', 'gamemode', 'view-distance', 'simulation-distance', 'online-mode', 'pvp', 'allow-flight', 'white-list', 'enforce-whitelist'];
    var body = {};
    keys.forEach(function (key) {
      var field = el('p-' + key);
      if (field) { body[key] = field.value; }
    });
    api('/api/properties', { method: 'POST', body: JSON.stringify(body) }).then(function (r) {
      toast(r.message, !r.ok);
      if (r.ok) {
        el('props').setAttribute('data-dirty', '0');
        loadProps();
      }
      refresh();
    }).catch(function (e) { toast('save failed: ' + e.message, true); });
  });

  el('checkBtn').addEventListener('click', function () {
    var btn = el('checkBtn');
    btn.disabled = true;
    btn.textContent = 'checking...';
    api('/api/discord-check').then(function (r) {
      el('checkResult').className = 'note' + (r.ok ? '' : ' err');
      el('checkResult').textContent = r.message;
      if (r.invite) {
        el('inviteBot').href = r.invite;
        el('inviteBot').style.display = '';
      }
    }).catch(function (e) {
      el('checkResult').className = 'note err';
      el('checkResult').textContent = 'check failed: ' + e.message;
    }).then(function () {
      btn.disabled = false;
      btn.textContent = 'check connection';
    });
  });

  (function () {
    var links = [].slice.call(document.querySelectorAll('.nav a'));
    var byId = {};
    links.forEach(function (link) {
      var id = link.getAttribute('href').slice(1);
      byId[id] = link;
    });
    function activate(id) {
      links.forEach(function (link) { link.className = ''; });
      if (byId[id]) {
        byId[id].className = 'active';
        setText('crumbSection', byId[id].getAttribute('data-label'));
      }
    }
    if ('IntersectionObserver' in window) {
      var observer = new IntersectionObserver(function (entries) {
        var best = null;
        entries.forEach(function (entry) {
          if (entry.isIntersecting && (!best || entry.intersectionRatio > best.intersectionRatio)) { best = entry; }
        });
        if (best) { activate(best.target.id); }
      }, { rootMargin: '-15% 0px -65% 0px', threshold: [0, .2, .6] });
      Object.keys(byId).forEach(function (id) {
        var section = el(id);
        if (section) { observer.observe(section); }
      });
    }
    links.forEach(function (link) {
      link.addEventListener('click', function () {
        activate(link.getAttribute('href').slice(1));
      });
    });
  })();

  applyTheme(document.documentElement.getAttribute('data-theme') === 'night' ? 'night' : 'storm', false);

  el('themeBtn').addEventListener('click', function () {
    var next = document.documentElement.getAttribute('data-theme') === 'night' ? 'storm' : 'night';
    applyTheme(next, true);
  });

  window.addEventListener('storage', function (event) {
    if (event.key === 'mcpanel.theme') {
      applyTheme(event.newValue === 'night' ? 'night' : 'storm', false);
    }
  });

  tickClock();
  setInterval(tickClock, 15000);
  refresh();
  loadLog();
  loadProps();
  setInterval(refresh, 2500);
  setInterval(function () { if (!document.hidden) { loadLog(); } }, 5000);
</script>
<script>
  (function () {
    var h = location.hostname;
    if (h === 'localhost' || h === '127.0.0.1') {
      var n = document.createElement('div');
      n.style.cssText = 'position:fixed;left:0;right:0;top:0;z-index:9999;background:#e0af68;color:#1f2335;font:600 13px system-ui;padding:10px;text-align:center';
      n.textContent = 'localhost only works on the server PC - on other devices open http://10.0.0.15:8787';
      document.body.appendChild(n);
    }
  })();
</script>
</body>
</html>
'@

# --------------------------------------------------------------------- serving
function Send-Response {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$Status,
        [string]$ContentType,
        [byte[]]$Body,
        [hashtable]$ExtraHeaders
    )
    $reasons = @{ 200 = 'OK'; 302 = 'Found'; 303 = 'See Other'; 400 = 'Bad Request'; 401 = 'Unauthorized'; 404 = 'Not Found'; 405 = 'Method Not Allowed'; 500 = 'Internal Server Error' }
    $reason = $reasons[$Status]
    if (-not $reason) { $reason = 'OK' }

    $head = 'HTTP/1.1 ' + $Status + ' ' + $reason + "`r`n"
    $head += 'Content-Type: ' + $ContentType + "`r`n"
    $head += 'Content-Length: ' + $Body.Length + "`r`n"
    $head += "Connection: close`r`n"
    $head += "Cache-Control: no-store`r`n"
    if ($ExtraHeaders) {
        foreach ($key in $ExtraHeaders.Keys) {
            $head += $key + ': ' + $ExtraHeaders[$key] + "`r`n"
        }
    }
    $head += "`r`n"

    $bytes = [Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($bytes, 0, $bytes.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Json-Result {
    param($Data, [int]$Status = 200)
    return @{
        Status  = $Status
        Type    = 'application/json; charset=utf-8'
        Body    = [Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json -Depth 8 -Compress))
        Headers = @{}
    }
}

function Text-Result {
    param([string]$Text, [int]$Status = 200, [string]$Type = 'text/plain; charset=utf-8')
    return @{
        Status  = $Status
        Type    = $Type
        Body    = [Text.Encoding]::UTF8.GetBytes($Text)
        Headers = @{}
    }
}

function Invoke-Route {
    param([string]$Method, [string]$Target, [hashtable]$Headers, [string]$Body)

    $pathOnly = $Target
    $query = @{}
    $qIndex = $Target.IndexOf('?')
    if ($qIndex -ge 0) {
        $pathOnly = $Target.Substring(0, $qIndex)
        $queryString = $Target.Substring($qIndex + 1)
        foreach ($pair in $queryString.Split('&')) {
            if (-not $pair) { continue }
            $kv = $pair.Split('=', 2)
            $key = [Uri]::UnescapeDataString($kv[0])
            $value = ''
            if ($kv.Count -eq 2) { $value = [Uri]::UnescapeDataString($kv[1]) }
            $query[$key] = $value
        }
    }
    $pathOnly = $pathOnly.TrimEnd('/')
    if ($pathOnly -eq '') { $pathOnly = '/' }

    $data = $null
    if ($Method -eq 'POST' -and -not [string]::IsNullOrWhiteSpace($Body)) {
        try { $data = $Body | ConvertFrom-Json } catch {
            return (Json-Result @{ ok = $false; message = 'Invalid JSON body.' } 400)
        }
    }

    switch -Regex ($Method + ' ' + $pathOnly) {
        '^GET /$' {
            return (Text-Result $html 200 'text/html; charset=utf-8')
        }
        '^GET /api/status$' {
            try {
                return (Json-Result (Get-ServerStatus))
            } catch {
                Write-GuiLog ('Status error: ' + $_.Exception.Message)
                return (Json-Result @{ ok = $false; message = $_.Exception.Message } 500)
            }
        }
        '^GET /api/logs$' {
            $which = $query['which']
            $lines = 150
            if ($query['lines']) { [void][int]::TryParse($query['lines'], [ref]$lines) }
            return (Json-Result @{ ok = $true; text = (Get-LogTail -Which $which -Lines $lines) })
        }
        '^POST /api/server$' {
            $action = 'start'
            if ($data -and $data.action) { $action = [string]$data.action }
            return (Json-Result (Invoke-ServerAction -Action $action))
        }
        '^POST /api/command$' {
            $commandText = ''
            if ($data -and $data.command) { $commandText = [string]$data.command }
            return (Json-Result (Invoke-ServerCommand -CommandText $commandText))
        }
        '^GET /api/properties$' {
            return (Json-Result (Get-ServerProperties))
        }
        '^POST /api/properties$' {
            return (Json-Result (Save-ServerProperties -Data $data))
        }
        '^POST /api/backup$' {
            return (Json-Result (Start-BackupNow))
        }
        '^POST /api/config$' {
            $out = Save-DiscordSettings -Data $data
            $script:statusCacheAt = $null
            return (Json-Result $out)
        }
        '^POST /api/test$' {
            return (Json-Result (Invoke-DiscordTest))
        }
        '^GET /api/discord-check$' {
            return (Json-Result (Invoke-DiscordCheck))
        }
        '^POST /api/feed$' {
            $action = 'start'
            if ($data -and $data.action) { $action = [string]$data.action }
            $out = Set-ServiceState -Service 'feed' -Action $action
            $script:statusCacheAt = $null
            $script:svcCacheAt = $null
            return (Json-Result $out)
        }
        '^POST /api/monitor$' {
            $action = 'start'
            if ($data -and $data.action) { $action = [string]$data.action }
            $out = Set-ServiceState -Service 'monitor' -Action $action
            $script:statusCacheAt = $null
            $script:svcCacheAt = $null
            return (Json-Result $out)
        }
        default {
            return (Json-Result @{ ok = $false; message = 'Not found.' } 404)
        }
    }
}

# ------------------------------------------------------------------- sign in
$script:cookieName = 'panel_session'
$script:cookieToken = ''
if (-not [string]::IsNullOrWhiteSpace($script:password)) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('panel|' + $script:password))
    } finally {
        $sha.Dispose()
    }
    $script:cookieToken = (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function ConvertFrom-QueryString {
    param([string]$Target)
    $result = @{}
    $index = $Target.IndexOf('?')
    if ($index -lt 0) { return $result }
    foreach ($pair in $Target.Substring($index + 1).Split('&')) {
        if (-not $pair) { continue }
        $kv = $pair.Split('=', 2)
        $key = [Uri]::UnescapeDataString($kv[0].Replace('+', ' '))
        $value = ''
        if ($kv.Count -eq 2) { $value = [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
        $result[$key] = $value
    }
    return $result
}

function ConvertFrom-FormBody {
    param([string]$Body)
    $result = @{}
    if ([string]::IsNullOrWhiteSpace($Body)) { return $result }
    foreach ($pair in $Body.Split('&')) {
        if (-not $pair) { continue }
        $kv = $pair.Split('=', 2)
        $key = [Uri]::UnescapeDataString($kv[0].Replace('+', ' '))
        $value = ''
        if ($kv.Count -eq 2) { $value = [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
        $result[$key] = $value
    }
    return $result
}

function Get-CookieValue {
    param([hashtable]$Headers, [string]$Name)
    if (-not $Headers -or -not $Headers.ContainsKey('cookie')) { return '' }
    foreach ($part in $Headers['cookie'].Split(';')) {
        $kv = $part.Split('=', 2)
        if ($kv.Count -eq 2 -and $kv[0].Trim() -eq $Name) { return $kv[1].Trim() }
    }
    return ''
}

function Test-PanelAuthorized {
    param([hashtable]$Headers, [hashtable]$Query)
    if ([string]::IsNullOrWhiteSpace($script:password)) { return $true }

    $authHeader = $Headers['authorization']
    if ($authHeader -match '^Basic\s+(.+)$') {
        try {
            $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
            $colon = $decoded.IndexOf(':')
            $supplied = $(if ($colon -ge 0) { $decoded.Substring($colon + 1) } else { $decoded })
            if ($supplied.Trim() -ceq $script:password) { return $true }
        } catch { }
    }

    if ((Get-CookieValue -Headers $Headers -Name $script:cookieName) -ceq $script:cookieToken) { return $true }

    if ($Query -and $Query.ContainsKey('p') -and $Query['p'] -ceq $script:password) { return $true }

    return $false
}

function New-LoginResult {
    param([string]$ErrorText = '', [int]$Status = 200)

    $note = ''
    if ($ErrorText) {
        $note = '<p class="err">' + [System.Net.WebUtility]::HtmlEncode($ErrorText) + '</p>'
    }

    $template = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0e1015">
<title>server panel - sign in</title>
<style>
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #0b0e14; color: #e7e9ee; font: 15px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; padding: 20px; }
  form { width: 100%; max-width: 360px; background: #151922; border: 1px solid #232a38; border-radius: 16px; padding: 24px; display: grid; gap: 14px; }
  h1 { font-size: 18px; margin: 0; }
  p { margin: 0; font-size: 13px; color: #8b94a7; }
  .err { color: #ff8e8e; }
  label { display: grid; gap: 6px; font-size: 13px; color: #aeb7c8; }
  input { width: 100%; padding: 12px; border-radius: 10px; border: 1px solid #2a3242; background: #0e121a; color: #e7e9ee; font: inherit; font-size: 16px; }
  input:focus { outline: none; border-color: #5865f2; box-shadow: 0 0 0 3px rgba(88,101,242,.18); }
  button { padding: 12px; border-radius: 10px; border: 0; background: #5865f2; color: #fff; font: inherit; font-weight: 600; }
</style>
</head>
<body>
<form method="post" action="/login">
  <h1>server panel</h1>
  <p>Enter the panel password from gui.txt on the server.</p>
  __ERROR__
  <label>Password
    <input type="password" name="password" autofocus autocomplete="current-password" autocapitalize="none" autocorrect="off" spellcheck="false">
  </label>
  <button type="submit">Open panel</button>
</form>
<script>
  (function () {
    var h = location.hostname;
    if (h === 'localhost' || h === '127.0.0.1') {
      var n = document.createElement('div');
      n.style.cssText = 'position:fixed;left:0;right:0;top:0;z-index:9999;background:#e0af68;color:#1f2335;font:600 13px system-ui;padding:10px;text-align:center';
      n.textContent = 'localhost only works on the server PC - on other devices open http://10.0.0.15:8787';
      document.body.appendChild(n);
    }
  })();
</script>
</body>
</html>
'@

    $page = $template.Replace('__ERROR__', $note)
    return (Text-Result $page $Status 'text/html; charset=utf-8')
}

function New-SignInResult {
    return @{
        Status  = 303
        Type    = 'text/plain; charset=utf-8'
        Body    = [Text.Encoding]::UTF8.GetBytes('Signed in. Redirecting to the panel.')
        Headers = @{
            Location     = '/'
            'Set-Cookie' = ($script:cookieName + '=' + $script:cookieToken + '; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax')
        }
    }
}

$running = $true
$lastWatchdogAt = [datetime]::MinValue
try {
    while ($running) {
        $client = $null
        while ($running -and -not $client) {
            try {
                if ($listener.Pending()) {
                    $client = $listener.AcceptTcpClient()
                } else {
                    if (((Get-Date) - $lastWatchdogAt).TotalSeconds -ge 15) {
                        $lastWatchdogAt = Get-Date
                        $online = $false
                        try { $online = Ensure-DiscordFeed } catch { Write-GuiLog ('Feed watchdog error: ' + $_.Exception.Message) }
                        $runningProc = Get-MinecraftProcess
                        if ($online -or $runningProc) {
                            $script:serverOfflineSince = $null
                        } elseif ($null -eq $script:serverOfflineSince) {
                            $script:serverOfflineSince = Get-Date
                            Write-GuiLog 'The server is offline; the panel will close in 60 seconds unless it comes back.'
                        } elseif (-not $NoOfflineExit -and ((Get-Date) - $script:serverOfflineSince).TotalSeconds -ge 60) {
                            Write-GuiLog 'The server has been offline for 60 seconds; closing the panel.'
                            $running = $false
                        }
                    }
                    Start-Sleep -Milliseconds 250
                }
            } catch {
                Write-GuiLog ('Accept failed: ' + $_.Exception.Message)
                Start-Sleep -Seconds 1
            }
        }
        if (-not $client) { continue }

        $remote = '?'
        $requestAt = Get-Date
        try {
            $client.ReceiveTimeout = 10000
            $client.SendTimeout = 10000
            try { $remote = $client.Client.RemoteEndPoint.ToString() } catch { }
            $stream = $client.GetStream()

            $raw = New-Object System.Collections.Generic.List[byte]
            $buffer = New-Object byte[] 8192
            $headerEnd = -1
            while ($headerEnd -lt 0 -and $raw.Count -lt 65536) {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                for ($i = 0; $i -lt $read; $i++) { $raw.Add($buffer[$i]) }
                $text = [Text.Encoding]::ASCII.GetString($raw.ToArray())
                $headerEnd = $text.IndexOf("`r`n`r`n")
            }
            if ($headerEnd -lt 0) {
                if ($raw.Count -gt 0) {
                    $preview = [Text.Encoding]::ASCII.GetString($raw.ToArray(), 0, [Math]::Min($raw.Count, 60))
                    $preview = ($preview -replace '[^\x20-\x7e]', '.')
                    Write-GuiLog ('Unreadable request from ' + $remote + ' (' + $raw.Count + ' bytes): ' + $preview)
                }
                continue
            }

            $allText = [Text.Encoding]::ASCII.GetString($raw.ToArray())
            $headerPart = $allText.Substring(0, $headerEnd)
            $bodyStart = $headerEnd + 4
            $preRead = $raw.Count - $bodyStart

            $lines = $headerPart -split "`r`n"
            $requestLine = $lines[0] -split ' '
            if ($requestLine.Count -lt 2) { continue }
            $method = $requestLine[0].ToUpperInvariant()
            $target = $requestLine[1]

            $headers = @{}
            for ($i = 1; $i -lt $lines.Count; $i++) {
                $idx = $lines[$i].IndexOf(':')
                if ($idx -gt 0) {
                    $headers[$lines[$i].Substring(0, $idx).Trim().ToLowerInvariant()] = $lines[$i].Substring($idx + 1).Trim()
                }
            }

            $contentLength = 0
            if ($headers.ContainsKey('content-length')) {
                [void][int]::TryParse($headers['content-length'], [ref]$contentLength)
            }
            if ($contentLength -gt 1048576) { $contentLength = 0 }

            $bodyText = ''
            if ($contentLength -gt 0) {
                $bodyBytes = New-Object byte[] $contentLength
                $copied = [Math]::Min($preRead, $contentLength)
                for ($i = 0; $i -lt $copied; $i++) {
                    $bodyBytes[$i] = $raw[$bodyStart + $i]
                }
                while ($copied -lt $contentLength) {
                    $read = $stream.Read($bodyBytes, $copied, $contentLength - $copied)
                    if ($read -le 0) { break }
                    $copied += $read
                }
                $bodyText = [Text.Encoding]::UTF8.GetString($bodyBytes, 0, $copied)
            }

            $pathOnly = $target
            $qAt = $pathOnly.IndexOf('?')
            if ($qAt -ge 0) { $pathOnly = $pathOnly.Substring(0, $qAt) }
            $pathOnly = $pathOnly.TrimEnd('/')
            if ($pathOnly -eq '') { $pathOnly = '/' }

            $query = ConvertFrom-QueryString $target
            $authorized = Test-PanelAuthorized -Headers $headers -Query $query
            $result = $null

            if ($method -eq 'POST' -and $pathOnly -eq '/login') {
                $form = ConvertFrom-FormBody $bodyText
                $given = ''
                if ($form.ContainsKey('password')) { $given = ([string]$form['password']).Trim() }
                if ([string]::IsNullOrWhiteSpace($script:password) -or $given -ceq $script:password) {
                    $result = New-SignInResult
                } else {
                    Write-GuiLog ('Failed sign-in from ' + $remote)
                    $result = New-LoginResult -ErrorText 'Wrong password. Try again.' -Status 200
                }
            }
            elseif ($authorized -and $method -eq 'GET' -and $pathOnly -eq '/' -and $query.ContainsKey('p') -and $query['p'] -ceq $script:password) {
                # Bookmarkable one-tap link for phones: http://<ip>:8787/?p=<password>
                $result = New-SignInResult
            }
            elseif (-not $authorized) {
                if ($method -eq 'GET' -and $pathOnly -eq '/') {
                    $result = New-LoginResult
                } else {
                    $result = Text-Result 'Authentication required.' 401
                    $result.Headers['WWW-Authenticate'] = 'Basic realm="server panel", charset="UTF-8"'
                }
            }
            else {
                $result = Invoke-Route -Method $method -Target $target -Headers $headers -Body $bodyText
            }

            if ($method -eq 'HEAD') {
                $result.Body = New-Object byte[] 0
            }
            Send-Response -Stream $stream -Status $result.Status -ContentType $result.Type -Body $result.Body -ExtraHeaders $result.Headers

            $elapsed = [int]((Get-Date) - $requestAt).TotalMilliseconds
            $logPath = $target
            $qAt = $logPath.IndexOf('?')
            if ($qAt -ge 0) { $logPath = $logPath.Substring(0, $qAt) }
            if ($logPath -ne '/api/status' -or $result.Status -ne 200 -or $elapsed -gt 3000) {
                Write-GuiLog ('{0} {1} {2} -> {3} ({4} ms)' -f $remote, $method, $target, $result.Status, $elapsed)
            }
        } catch {
            Write-GuiLog ('Request error: ' + $_.Exception.Message)
        } finally {
            try { $client.Close() } catch { }
        }
    }
}
catch {
    Write-GuiLog ('FATAL: ' + $_.Exception.ToString())
    Write-Host ('Panel stopped: ' + $_.Exception.Message)
}
finally {
    try { $listener.Stop() } catch { }
    if ($script:session) { Close-RconSession $script:session }
    if ($script:hwComputer) {
        try { $script:hwComputer.Close() } catch { }
        $script:hwComputer = $null
    }
}

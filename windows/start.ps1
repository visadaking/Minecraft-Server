#Requires -Version 5.1
<#
    Starts the Minecraft server and its helpers.

    Two modes:
      * Interactive (default): starts the server in this PowerShell window.
        This is a manual fallback; closing the window stops Java.
      * Background (-Background): runs as the SYSTEM scheduled task
        "MinecraftServer-Stack". Java, the panel, the Discord feed, backups and
        the TPS monitor run in session 0, so a Windows logoff (including the
        broken F5 BIG-IP Edge Client) cannot kill the server.

    In background mode there is no visible Java console. The live log is in
    logs\latest.log and the panel has a full RCON console. start.bat opens a
    PowerShell window that tails that log; closing it does not stop the server.
#>
[CmdletBinding()]
param(
    [switch]$Background
)

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$script:Background = [bool]$Background
$script:LogDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
$script:HostLog = Join-Path $script:LogDir 'host.log'
$script:StatePath = Join-Path $script:LogDir 'stack-state.json'
$script:StopFlag = Join-Path $script:LogDir 'stack-stop.flag'

# Power-outage / reboot safety: when Windows starts and the user logs in, the
# whole stack comes back up hidden. A manual Run-key entry needs no admin.
# (Re-written on every manual start so it always points at this folder.)
if (-not $script:Background) {
    try {
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if (-not (Test-Path $runKey)) { New-Item -Path $runKey -Force | Out-Null }
        $runValue = '"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Root + '\start.ps1" -Background'
        if ((Get-ItemProperty -Path $runKey -Name 'MinecraftServerStack' -ErrorAction SilentlyContinue).'MinecraftServerStack' -ne $runValue) {
            Set-ItemProperty -Path $runKey -Name 'MinecraftServerStack' -Value $runValue
            Write-Host 'Auto-start at logon registered (power-outage safety).' -ForegroundColor DarkGray
        }
    } catch { }
}

if ($script:Background) {
    try { Start-Transcript -Path $script:HostLog -Append | Out-Null } catch { }
} else {
    try { $Host.UI.RawUI.WindowTitle = 'Minecraft Server' } catch { }
}

function Save-StackState {
    param(
        [string]$Status,
        [int]$ExitCode = 0,
        [int]$JavaPid = 0
    )
    $state = [ordered]@{
        status     = $Status
        background = $script:Background
        task       = 'MinecraftServer-Stack'
        hostPid    = $PID
        javaPid    = $JavaPid
        exitCode   = $ExitCode
        updatedAt  = (Get-Date).ToString('o')
    }
    try { $state | ConvertTo-Json | Set-Content -Path $script:StatePath -Encoding UTF8 } catch { }
}

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

function Get-LanAddress {
    # Only the physical home adapter counts. Never return a VPN, Hyper-V,
    # loopback, or link-local address, even if it owns the default route.
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

function Wait-ForLanAddress {
    param([int]$Seconds = 180)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ($true) {
        $lan = Get-LanAddress
        if ($lan) { return $lan }
        if (-not $script:Background -or (Get-Date) -ge $deadline) { return $null }
        Start-Sleep -Seconds 5
    }
}

function Get-VpnAdapter {
    try {
        @(Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.Status -eq 'Up' -and
            ($_.InterfaceDescription -match 'VPN|WireGuard|TAP|Tunnel' -or $_.Name -match 'VPN|WireGuard|TAP|Tunnel')
        })
    } catch {
        @()
    }
}

function Test-DefaultRouteIsVpn {
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric | Select-Object -First 1
        if (-not $route) { return $false }
        $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop
        return [bool]($adapter -and $adapter.InterfaceDescription -match 'VPN|WireGuard|TAP|Tunnel')
    } catch {
        return $false
    }
}

function Get-MinecraftProcess {
    Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'server\.jar' } | Select-Object -First 1
}

function Stop-WithMessage {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Red
    Write-Host ''
    Save-StackState -Status 'failed' -ExitCode 1
    if ($script:Background) { exit 1 }
    Read-Host 'Press Enter to close'
    exit 1
}

function Start-Helper {
    param([string]$Title, [string]$ScriptPath, [string[]]$ScriptArgs)
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ScriptArgs
    # Helpers must never show a window: only the server console may be visible.
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WorkingDirectory $Root -WindowStyle Hidden | Out-Null
}

function Test-ScriptRunning {
    param([string]$Name)
    $pattern = '-File\s+"?[^"\r\n]*' + [regex]::Escape($Name)
    return [bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $pattern } |
        Select-Object -First 1)
}

function Remove-StaleHelpers {
    # When the stack moves from a user-session start to the SYSTEM task, the
    # old panel/feed/TPS/backup processes are still running. They would die on
    # the next logoff, so stop them and let the SYSTEM task start fresh copies.
    $helperNames = @('gui-server.ps1', 'discord-status.ps1', 'discord-chat.ps1', 'tps-monitor.ps1', 'backup-loop.ps1', 'update-server.ps1')
    $pattern = ($helperNames | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $pattern })
    foreach ($p in $procs) {
        Write-Host ('Stopping old helper PID ' + $p.ProcessId + ' before starting the background copies.') -ForegroundColor DarkGray
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { }
    }
}

function Start-AllHelpers {
    param([string]$LanAddress)

    if ($script:Background) {
        Remove-StaleHelpers
        Start-Sleep -Seconds 3
    }

    if (-not (Test-ScriptRunning 'backup-loop.ps1')) {
        Start-Helper -Title 'Backups' -ScriptPath (Join-Path $Root 'backup-loop.ps1') -ScriptArgs @('-IntervalHours', '2', '-Keep', '5')
    }
    if (-not (Test-ScriptRunning 'tps-monitor.ps1')) {
        Start-Helper -Title 'TPS Monitor' -ScriptPath (Join-Path $Root 'tps-monitor.ps1') -ScriptArgs @('-IntervalSeconds', '10', '-Threshold', '18', '-Consecutive', '3', '-CooldownSeconds', '60')
    }
    if ($LanAddress -and -not (Test-TcpPort -Port 8787 -Target $LanAddress)) {
        Start-Helper -Title 'Server Panel' -ScriptPath (Join-Path $Root 'gui-server.ps1') -ScriptArgs @()
    }
    if (-not (Test-ScriptRunning 'discord-status.ps1')) {
        Start-Helper -Title 'Discord' -ScriptPath (Join-Path $Root 'discord\discord-status.ps1') -ScriptArgs @('-PollSeconds', '15', '-UpdateMinutes', '5')
    }
    if (-not (Test-ScriptRunning 'discord-chat.ps1')) {
        Start-Helper -Title 'Discord Chat' -ScriptPath (Join-Path $Root 'discord\discord-chat.ps1') -ScriptArgs @('-PollSeconds', '3')
    }
    if (-not (Test-ScriptRunning 'update-server.ps1')) {
        Start-Helper -Title 'Auto Update' -ScriptPath (Join-Path $Root 'update-server.ps1') -ScriptArgs @('-Watch', '-CheckMinutes', '60')
    }
}

function Get-ServerJarVersion {
    # Reads the version id from version.json inside server.jar.
    $jarPath = Join-Path $Root 'server.jar'
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($jarPath)
        try {
            $entry = $zip.GetEntry('version.json')
            if (-not $entry) { return '' }
            $reader = New-Object IO.StreamReader($entry.Open())
            try { $raw = $reader.ReadToEnd() } finally { $reader.Close() }
            return [string] (($raw | ConvertFrom-Json).id)
        } finally { $zip.Dispose() }
    } catch {
        return ''
    }
}

function Send-DiscordAnnouncement {
    param([string]$Text)
    try {
        . (Join-Path $Root 'discord\discord.ps1')
        $config = Get-DiscordConfig -Root (Join-Path $Root 'discord')
        if (-not (Test-DiscordConfig -Config $config)) { return }
        $json = @{ content = $Text } | ConvertTo-Json -Compress
        Send-DiscordMessage -Config $config -Json $json | Out-Null
    } catch { }
}

function Announce-ServerVersionChange {
    # Announce on Discord whenever server.jar changed since the last start.
    $versionFile = Join-Path $Root 'logs\last-server-version.txt'
    $newVersion = Get-ServerJarVersion
    if (-not $newVersion) { return }
    $oldVersion = ''
    if (Test-Path $versionFile) {
        $oldVersion = (Get-Content $versionFile -Raw -ErrorAction SilentlyContinue)
        if ($oldVersion) { $oldVersion = $oldVersion.Trim() }
    }
    if ($oldVersion -and $oldVersion -ne $newVersion) {
        Write-Host ('Announcing the updated server version to Discord (' + $newVersion + ')...') -ForegroundColor DarkGray
        Send-DiscordAnnouncement -Text ('server updated to ' + $newVersion + ' (was ' + $oldVersion + ') - update your game to join')
    }
    try { Set-Content -Path $versionFile -Value $newVersion -Encoding UTF8 } catch { }
}

if (-not (Test-Path (Join-Path $Root 'server.jar'))) {
    Stop-WithMessage ('ERROR: server.jar was not found in ' + $Root)
}

# A manual start should always mean "run", not "stay stopped" from an earlier
# panel stop request.
if (Test-Path $script:StopFlag) {
    Remove-Item -Path $script:StopFlag -Force -ErrorAction SilentlyContinue
}

$existing = Get-MinecraftProcess
if ($existing) {
    Stop-WithMessage ('ERROR: a Minecraft server is already running (PID ' + $existing.ProcessId + '). Close that window first, or use the panel to stop it.')
}
if (Test-TcpPort -Port 25565) {
    Stop-WithMessage 'ERROR: port 25565 is already in use. Close the other server first.'
}

Save-StackState -Status 'starting'

# At boot the Ethernet adapter and DHCP can take a while. Do not fall back to a
# VPN or loopback address; wait for the real LAN card.
$lanAddress = Wait-ForLanAddress -Seconds $(if ($script:Background) { 180 } else { 0 })
if (-not $lanAddress) {
    Write-Host 'WARNING: no physical Ethernet address was found.' -ForegroundColor Yellow
    Write-Host 'The panel and playit.gg will not start until the LAN card is up.' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- playit.gg
$playit = 'C:\Program Files\playit_gg\bin\playit.exe'
$playitTray = 'C:\Program Files\playit_gg\bin\playitd-tray.exe'
$vpnAdapters = @(Get-VpnAdapter)
$defaultIsVpn = Test-DefaultRouteIsVpn

if (-not $lanAddress) {
    Write-Host 'playit.gg will not be started without a physical LAN address.' -ForegroundColor Yellow
    if (Test-Path $playit) { & $playit stop *> $null }
} elseif ($defaultIsVpn) {
    $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric | Select-Object -First 1
    $defaultName = $(if ($defaultRoute) { (Get-NetAdapter -InterfaceIndex $defaultRoute.InterfaceIndex -ErrorAction SilentlyContinue).InterfaceDescription } else { 'unknown' })
    Write-Host ('WARNING: the default route is on a VPN adapter (' + $defaultName + ').') -ForegroundColor Yellow
    Write-Host 'playit.gg will not be started through it. Disconnect the VPN and restart the tunnel.' -ForegroundColor Yellow
    if (Test-Path $playit) { & $playit stop *> $null }
} elseif (Test-Path $playit) {
    if ($vpnAdapters.Count -gt 0) {
        Write-Host ('NOTE: a VPN adapter is present (' + (($vpnAdapters | ForEach-Object { $_.InterfaceDescription }) -join ', ') + ').') -ForegroundColor DarkGray
        Write-Host 'playit.gg is pinned to Ethernet by the firewall and will not use the VPN.' -ForegroundColor DarkGray
    }
    if (-not $script:Background) {
        $tray = Get-Process -Name 'playitd-tray' -ErrorAction SilentlyContinue
        if (-not $tray -and (Test-Path $playitTray)) {
            Start-Process -FilePath $playitTray -WindowStyle Minimized
            Start-Sleep -Seconds 2
        }
    }
    & $playit status *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Starting the playit.gg tunnel...' -ForegroundColor DarkGray
        & $playit start *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'WARNING: playit.gg could not be started. Open the Playit app manually.' -ForegroundColor Yellow
        }
    }
} else {
    Write-Host ('WARNING: playit.gg was not found at ' + $playit + '.') -ForegroundColor Yellow
}

# ------------------------------------------------------------ pre-start backup
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'backup.ps1') -Keep 5 -MinIntervalHours 2
Write-Host ''

# ---------------------------------------------------------------- helpers
Start-AllHelpers -LanAddress $lanAddress

Start-Sleep -Seconds 2
Write-Host '============================================================' -ForegroundColor DarkGray
Write-Host ' Minecraft server' -ForegroundColor White
Write-Host '============================================================' -ForegroundColor DarkGray
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'status.ps1')
Write-Host '============================================================' -ForegroundColor DarkGray
Write-Host ('  mode   ' + $(if ($script:Background) { 'background task (survives logoff)' } else { 'interactive window' })) -ForegroundColor DarkGray
Write-Host ('  world  ' + (Join-Path $Root 'world')) -ForegroundColor DarkGray
Write-Host ('  java   ' + $(if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\java.exe' } else { 'java from PATH' })) -ForegroundColor DarkGray
Write-Host '  type "stop" in the panel console to shut down cleanly' -ForegroundColor DarkGray
Write-Host '  backups every 3 hours - logs are in logs\' -ForegroundColor DarkGray
Write-Host '============================================================' -ForegroundColor DarkGray
Write-Host ''

# Announce a version change on Discord (only starts once Java is about to run;
# a failed start never claims an update went live).
Announce-ServerVersionChange

$java = 'C:\Program Files\Eclipse Adoptium\jdk-25.0.4.101-hotspot\bin\java.exe'
if (-not (Test-Path $java)) {
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
        $java = Join-Path $env:JAVA_HOME 'bin\java.exe'
    } else {
        $java = 'java'
    }
}

$javaArgs = @(
    '-Xms6G', '-Xmx6G',
    '-XX:+UseG1GC', '-XX:+ParallelRefProcEnabled', '-XX:MaxGCPauseMillis=200',
    '-XX:+UnlockExperimentalVMOptions', '-XX:+DisableExplicitGC', '-XX:+AlwaysPreTouch',
    '-XX:G1NewSizePercent=30', '-XX:G1MaxNewSizePercent=40', '-XX:G1HeapRegionSize=8M',
    '-XX:G1ReservePercent=20', '-XX:G1HeapWastePercent=5', '-XX:G1MixedGCCountTarget=4',
    '-XX:InitiatingHeapOccupancyPercent=15', '-XX:G1MixedGCLiveThresholdPercent=90',
    '-XX:G1RSetUpdatingPauseTimePercent=5', '-XX:SurvivorRatio=32', '-XX:+PerfDisableSharedMem',
    '-XX:MaxTenuringThreshold=1', '-Dusing.aikars.flags=https://mcflags.emc.gs', '-Daikars.new.flags=true',
    '--enable-native-access=ALL-UNNAMED', '--sun-misc-unsafe-memory-access=allow',
    '-jar', 'server.jar', 'nogui'
)

while ($true) {
    if (Test-Path $script:StopFlag) {
        Write-Host 'Stop requested before the next start; not starting Java.' -ForegroundColor Yellow
        Save-StackState -Status 'stopped'
        break
    }

    $startedAt = Get-Date
    $exitCode = 0
    $javaPid = 0

    if ($script:Background) {
        $stdout = Join-Path $script:LogDir 'java-stdout.log'
        $stderr = Join-Path $script:LogDir 'java-stderr.log'
        try {
            Set-Content -Path $stdout -Value '' -Encoding UTF8
            Set-Content -Path $stderr -Value '' -Encoding UTF8
            $proc = Start-Process -FilePath $java -ArgumentList $javaArgs -WorkingDirectory $Root `
                -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            $javaPid = $proc.Id
            Save-StackState -Status 'online' -JavaPid $javaPid
            $proc.WaitForExit()
            $exitCode = $proc.ExitCode
        } catch {
            Write-Host ('Could not start Java: ' + $_.Exception.Message) -ForegroundColor Red
            $exitCode = 1
        }
    } else {
        & $java @javaArgs
        $exitCode = $LASTEXITCODE
    }

    $ran = ((Get-Date) - $startedAt).TotalSeconds
    $portOpen = Test-TcpPort -Port 25565
    Save-StackState -Status 'stopped' -ExitCode $exitCode -JavaPid $javaPid

    if ($exitCode -eq 0) {
        Write-Host ''
        Write-Host 'Server stopped cleanly. Saving a final backup...' -ForegroundColor Green
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'backup.ps1') -Keep 5
        Write-Host ''
        Write-Host 'The background task is done. The panel will close itself shortly.' -ForegroundColor DarkGray
        if (-not $script:Background) { Read-Host 'Done. Press Enter to close' }
        break
    }

    Write-Host ''
    Write-Host ('Server stopped unexpectedly (exit code ' + $exitCode + ').') -ForegroundColor Red
    if ($ran -lt 20 -and -not $portOpen) {
        Write-Host 'It never opened the game port, so this was probably a startup problem.' -ForegroundColor Yellow
        Write-Host 'Not restarting automatically. Check logs\latest.log and logs\java-stderr.log, then start again.' -ForegroundColor Yellow
        Write-Host ''
        Save-StackState -Status 'failed' -ExitCode $exitCode -JavaPid $javaPid
        if (-not $script:Background) { Read-Host 'Press Enter to close' }
        break
    }

    if (Test-Path $script:StopFlag) {
        Write-Host 'Stop requested; not restarting.' -ForegroundColor Yellow
        Save-StackState -Status 'stopped' -ExitCode $exitCode -JavaPid $javaPid
        break
    }

    Write-Host 'Restarting in 10 seconds. Use the panel or start.bat to stop it.' -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    # The helpers may have stopped while the server was down; bring them back.
    Start-AllHelpers -LanAddress $lanAddress
}

if ($script:Background) {
    try { Stop-Transcript | Out-Null } catch { }
}

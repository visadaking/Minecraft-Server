#Requires -Version 5.1
<#
    Creates a consistent zip backup of the world and server configuration.

    - If the server is stopped: copies the files directly (cold backup).
    - If the server is running: uses RCON to run "save-off" and
      "save-all flush", copies the files, then runs "save-on".
      This needs enable-rcon=true in server.properties (already configured).

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File .\backup.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File .\backup.ps1 -Keep 10
        powershell -NoProfile -ExecutionPolicy Bypass -File .\backup.ps1 -MinIntervalHours 6
#>
[CmdletBinding()]
param(
    [string]$Destination = '',
    [int]$Keep = 5,
    [double]$MinIntervalHours = 0,
    [string]$Tag = '',
    [switch]$AllowUnsafeLive
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Destination)) { $Destination = Join-Path $root 'backups' }
if ($Keep -lt 1) { $Keep = 1 }

Add-Type -AssemblyName System.IO.Compression.FileSystem
. (Join-Path $root 'rcon.ps1')

New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$script:LogFile = Join-Path $Destination 'backup.log'

function Write-BackupLog {
    param([string]$Message)
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message
    Write-Host $line
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch { }
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

# Be gentle with the CPU while copying/compressing, especially in live mode.
try { (Get-Process -Id $PID).PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }

$port = 25565
try { $port = [int](Get-ServerProperty 'server-port' '25565') } catch { }
$rconEnabled = (Get-ServerProperty 'enable-rcon' 'false') -eq 'true'
$rconPort = 25575
try { $rconPort = [int](Get-ServerProperty 'rcon.port' '25575') } catch { }
$rconPassword = Get-ServerProperty 'rcon.password' ''
$serverRunning = Test-ServerListening $port

if ($MinIntervalHours -gt 0 -and (Test-Path $Destination)) {
    $latest = Get-ChildItem -Path $Destination -Filter 'backup-*.zip' |
        Where-Object { $_.Name -match '^backup-\d{8}-\d{6}\.zip$' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest -and ((Get-Date) - $latest.LastWriteTime).TotalHours -lt $MinIntervalHours) {
        Write-BackupLog ("Skipping backup: newest one is {0:0.0} hours old ({1})." -f ((Get-Date) - $latest.LastWriteTime).TotalHours, $latest.Name)
        exit 0
    }
}

if ($serverRunning -and (-not $rconEnabled -or [string]::IsNullOrWhiteSpace($rconPassword)) -and -not $AllowUnsafeLive) {
    Write-BackupLog 'Server is running but RCON is disabled. Refusing an inconsistent live backup. Stop the server or enable RCON.'
    exit 2
}

# Only one backup at a time (start.bat and backup-loop.ps1 can overlap).
$mutex = New-Object System.Threading.Mutex($false, 'MinecraftBackupMutex')
$hasMutex = $false
try {
    $hasMutex = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $hasMutex = $true
}
if (-not $hasMutex) {
    Write-BackupLog 'Another backup is already running; skipping this one.'
    exit 0
}

$live = $false
$mode = if ($serverRunning) { 'live' } else { 'cold' }

try {
    if ($serverRunning -and $rconEnabled -and -not [string]::IsNullOrWhiteSpace($rconPassword)) {
        try {
            # Reset any stuck "save-off" from an interrupted earlier run, then pause saving.
            Invoke-Rcon -Command 'save-on' -Password $rconPassword -Port $rconPort | Out-Null
            Invoke-Rcon -Command 'save-off' -Password $rconPassword -Port $rconPort | Out-Null
            $live = $true
            $saveOutput = Invoke-Rcon -Command 'save-all flush' -Password $rconPassword -Port $rconPort
            Write-BackupLog ("Live backup: saving paused and flushed. Server said: {0}" -f $saveOutput)
        } catch {
            Write-BackupLog ("RCON error: {0}" -f $_.Exception.Message)
            if ($live) {
                try { Invoke-Rcon -Command 'save-on' -Password $rconPassword -Port $rconPort | Out-Null } catch { }
                $live = $false
            }
            if (-not $AllowUnsafeLive) { return }
            $mode = 'unsafe-live'
        }
    } elseif ($serverRunning) {
        Write-BackupLog 'WARNING: live backup without save-off. Files may be inconsistent.'
        $mode = 'unsafe-live'
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("mcbackup-" + $stamp + "-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $name = if ([string]::IsNullOrWhiteSpace($Tag)) { "backup-" + $stamp + ".zip" } else { "backup-$Tag-$stamp.zip" }
    $zipPath = Join-Path $Destination $name

    Write-BackupLog ("Backing up server (everything) to {0} ({1}) ..." -f $zipPath, $mode)

    try {
        New-Item -ItemType Directory -Path (Join-Path $tmp 'world') -Force | Out-Null

        & Copy-Item -Path (Join-Path $root 'world') -Destination (Join-Path $tmp 'world') -Recurse -Force
        # A stale session.lock must not ship in the archive.
        $lock = Join-Path -Path (Join-Path $tmp 'world') -ChildPath 'session.lock'
        if (Test-Path $lock) { Remove-Item -Path $lock -Force -ErrorAction SilentlyContinue }

        # Everything needed for a full restore: settings, security files and
        # the whole stack's scripts (world first, it is the big one).
        foreach ($file in 'server.properties', 'ops.json', 'whitelist.json', 'banned-players.json', 'banned-ips.json', 'usercache.json', 'eula.txt',
            'start.bat', 'start.ps1', 'server-console.ps1', 'server-control.ps1', 'backup.ps1', 'backup-loop.ps1',
            'tps-monitor.ps1', 'status.ps1', 'rcon.ps1', 'gui-server.ps1') {
            $source = Join-Path $root $file
            if (Test-Path $source) { Copy-Item -Path $source -Destination $tmp -Force }
        }
        if (Test-Path (Join-Path $root 'discord')) {
            Copy-Item -Path (Join-Path $root 'discord') -Destination $tmp -Recurse -Force
        }

        [IO.Compression.ZipFile]::CreateFromDirectory($tmp, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
    }
    finally {
        if (Test-Path $tmp) { Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $sizeMb = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Write-BackupLog ("Backup created: {0} ({1} MB, {2})" -f $zipPath, $sizeMb, $mode)

    # Rotate only plain backups. Tagged backups (for example preupdate) are
    # kept forever so there is always a known-good restore point.
    $isPlain = '^backup-\d{8}-\d{6}\.zip$'
    $old = Get-ChildItem -Path $Destination -Filter 'backup-*.zip' |
        Where-Object { $_.Name -match $isPlain } |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep
    foreach ($item in $old) {
        Remove-Item -Path $item.FullName -Force
        Write-BackupLog ("Removed old backup: {0}" -f $item.Name)
    }
}
finally {
    if ($live) {
        try {
            Invoke-Rcon -Command 'save-on' -Password $rconPassword -Port $rconPort | Out-Null
            Write-BackupLog 'Server saving re-enabled.'
        } catch {
            Write-BackupLog ("WARNING: could not re-enable saving: {0}" -f $_.Exception.Message)
        }
    }
    if ($hasMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

#Requires -Version 5.1
<#
    Starts, stops or restarts the Minecraft server on request from the panel.

    The real server runs as the SYSTEM scheduled task "MinecraftServer-Stack"
    (see setup-background-server.ps1). That task is independent of the Windows
    user session, so opening the F5 BIG-IP Edge Client -- which logs the user
    off -- cannot kill Java, the panel, the Discord feed, backups or the TPS
    monitor.

    The panel launches this script detached so the browser gets an immediate
    answer instead of waiting a minute for the server to boot. Progress goes to
    logs\server-control.log.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('start', 'stop', 'restart')][string]$Action,
    [int]$StopWaitSeconds = 120,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir 'server-control.log'
$taskName = 'MinecraftServer-Stack'
$stopFlag = Join-Path $logDir 'stack-stop.flag'

function Write-ControlLog {
    param([string]$Message)
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message
    try { Add-Content -Path $logPath -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

function Get-ServerProp {
    param([string]$Name, [string]$Default = '')
    $path = Join-Path $root 'server.properties'
    if (-not (Test-Path $path)) { return $Default }
    $pattern = '^\s*' + [regex]::Escape($Name) + '\s*=\s*(.*)$'
    foreach ($line in Get-Content -Path $path -Encoding UTF8) {
        if ($line -match $pattern) { return $Matches[1].Trim() }
    }
    return $Default
}

function Test-GamePort {
    $port = 25565
    try { $port = [int](Get-ServerProp 'server-port' '25565') } catch { }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(700)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Get-ServerProcess {
    Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'server\.jar' } | Select-Object -First 1
}

function Wait-ServerProcessExit {
    param([int]$Seconds = 60)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-ServerProcess)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return [bool](-not (Get-ServerProcess))
}

function Get-StackTask {
    try {
        Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    } catch {
        $null
    }
}

function Test-StackTaskRunning {
    $task = Get-StackTask
    return [bool]($task -and $task.State -eq 'Running')
}

function Start-StackTask {
    $task = Get-StackTask
    if (-not $task) {
        Write-ControlLog ('ERROR: scheduled task "' + $taskName + '" was not found. Run setup-background-server.ps1 as administrator first.')
        return $false
    }
    if ($task.State -eq 'Running') {
        Write-ControlLog ('The background stack task is already running (state ' + $task.State + ').')
        return $true
    }
    try {
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        Write-ControlLog ('Started background task "' + $taskName + '".')
        Start-Sleep -Seconds 2
        return $true
    } catch {
        Write-ControlLog ('ERROR: could not start "' + $taskName + '": ' + $_.Exception.Message)
        return $false
    }
}

function Wait-StackTaskReady {
    param([int]$Seconds = 180)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-StackTaskRunning)) { return $true }
        Start-Sleep -Seconds 2
    }
    return [bool](-not (Test-StackTaskRunning))
}

function Set-StackStopFlag {
    try {
        Set-Content -Path $stopFlag -Value (Get-Date).ToString('o') -Encoding UTF8
    } catch { }
}

function Clear-StackStopFlag {
    if (Test-Path $stopFlag) {
        try { Remove-Item -Path $stopFlag -Force -ErrorAction Stop } catch { }
    }
}

function Start-GameServer {
    $proc = Get-ServerProcess
    if ($proc) {
        Write-ControlLog ('Start requested, but a server process is still running (PID ' + $proc.ProcessId + '). Not starting a second copy.')
        return $false
    }
    $online = Test-GamePort
    if ($online) {
        Write-ControlLog 'Start requested, but the server is already running.'
        return $true
    }
    if (Test-StackTaskRunning) {
        Write-ControlLog 'Start requested, but the background stack task is already running. Waiting for Java.'
        return $true
    }

    Clear-StackStopFlag

    # The one-time SYSTEM task setup may not have been run yet. Keep the panel
    # Start/Restart buttons working by starting the normal interactive host in
    # the background instead of failing.
    if (-not (Get-StackTask)) {
        Write-ControlLog 'Background task is not installed; starting start.ps1 in the user session.'
        if ($DryRun) {
            Write-ControlLog 'DRY RUN: would start start.ps1.'
            return $true
        }
        $startScript = Join-Path $root 'start.ps1'
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startScript, '-Background'
        ) -WorkingDirectory $root -WindowStyle Hidden | Out-Null
        return $true
    }

    Write-ControlLog 'Starting the Minecraft server in the background task.'
    if ($DryRun) {
        Write-ControlLog ('DRY RUN: would start scheduled task "' + $taskName + '".')
        return $true
    }
    if (-not (Start-StackTask)) { return $false }
    return $true
}

function Stop-GameServer {
    param([string]$Reason = 'stop')

    if (-not (Test-GamePort)) {
        $proc = Get-ServerProcess
        if ($proc) {
            Write-ControlLog ('The game port is closed, but PID ' + $proc.ProcessId + ' is still shutting down. Waiting...')
            if (-not (Wait-ServerProcessExit -Seconds 60)) {
                Write-ControlLog 'WARNING: the old server process is still holding the world; not starting another one.'
                return $false
            }
            Write-ControlLog 'Server process exited.'
        }
        if (Test-StackTaskRunning) {
            Write-ControlLog 'The server is offline, but the background task is still running; asking it not to restart Java.'
            Set-StackStopFlag
            if (-not (Wait-StackTaskReady -Seconds 90)) {
                Write-ControlLog 'WARNING: the background task is still running. It should exit on its own; check logs\host.log.'
                return $false
            }
            Write-ControlLog 'Background task stopped.'
        } else {
            Write-ControlLog 'Stop requested, but the server is already offline.'
        }
        return $true
    }

    $password = Get-ServerProp 'rcon.password' ''
    $port = 25575
    try { $port = [int](Get-ServerProp 'rcon.port' '25575') } catch { }
    if ([string]::IsNullOrWhiteSpace($password)) {
        Write-ControlLog 'ERROR: rcon.password is empty, cannot stop the server cleanly.'
        return $false
    }

    if ($DryRun) {
        Write-ControlLog 'DRY RUN: would send "stop" over RCON and wait for the port to close.'
        return $true
    }

    # If the server dies while shutting down, the host must not restart it.
    Set-StackStopFlag

    . (Join-Path $root 'rcon.ps1')

    Write-ControlLog 'Sending "stop" over RCON (the server saves the world first).'
    try {
        $session = Connect-Rcon -Password $password -Port $port -TimeoutMs 10000
        try {
            # Tell anyone who is playing why the server is about to disappear.
            $notice = $(if ($Reason -eq 'restart') { 'server restarting' } else { 'server stopping' })
            try {
                Invoke-RconSession -Session $session -Command ('say ' + $notice) -TimeoutMs 5000 | Out-Null
            } catch { }

            # The server usually drops the connection instead of answering, so
            # a failure here is not an error.
            Invoke-RconSession -Session $session -Command 'stop' -TimeoutMs 10000 | Out-Null
        } finally {
            Close-RconSession $session
        }
    } catch {
        Write-ControlLog ('RCON stop warning: ' + $_.Exception.Message)
    }

    $deadline = (Get-Date).AddSeconds($StopWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-GamePort)) {
            Write-ControlLog 'Server stopped.'
            if (-not (Wait-ServerProcessExit -Seconds 60)) {
                Write-ControlLog 'WARNING: the old server process is still holding the world; not starting another one.'
                return $false
            }
            Write-ControlLog 'Server process exited.'
            if (Test-StackTaskRunning) {
                Write-ControlLog 'Waiting for the background task to finish its final backup...'
                if (-not (Wait-StackTaskReady -Seconds 180)) {
                    Write-ControlLog 'WARNING: the background task is still running after the final backup window.'
                    return $false
                }
            }
            return $true
        }
        Start-Sleep -Seconds 2
    }

    Write-ControlLog ('WARNING: the server did not stop within ' + $StopWaitSeconds + ' seconds.')
    # The server is still up; a later crash should be allowed to restart it.
    Clear-StackStopFlag
    return $false
}

switch ($Action) {
    'start' { Start-GameServer | Out-Null }
    'stop' { Stop-GameServer | Out-Null }
    'restart' {
        Write-ControlLog 'Restart requested.'
        if (Stop-GameServer -Reason restart) {
            if (-not (Wait-StackTaskReady -Seconds 180)) {
                Write-ControlLog 'Restart cancelled: the old background task did not finish.'
                return
            }
            Clear-StackStopFlag
            Start-Sleep -Seconds 2
            Write-ControlLog 'Starting the fresh background task...'
            Start-GameServer | Out-Null
        } else {
            Write-ControlLog 'Restart cancelled: the old server did not shut down cleanly.'
        }
    }
}

Write-ControlLog ('Action "' + $Action + '" finished.')

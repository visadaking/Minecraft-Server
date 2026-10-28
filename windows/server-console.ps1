#Requires -Version 5.1
<#
    Visible PowerShell console for the background Minecraft server.

    start.bat opens this window. It starts the SYSTEM scheduled task (if it is
    not already running), prints the startup status, then tails the live server
    log. Closing this window does not stop the server: Java, the panel, the
    Discord feed, backups and the TPS monitor run in the background task.

    Commands are available in the panel console:
        http://10.0.0.15:8787  ->  console
#>
[CmdletBinding()]
param(
    [switch]$NoStart,
    [switch]$NoTail
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$taskName = 'MinecraftServer-Stack'
$stopFlag = Join-Path $root 'logs\stack-stop.flag'
$panelUrl = 'http://10.0.0.15:8787'

try { $Host.UI.RawUI.WindowTitle = 'Minecraft Server' } catch { }

function Test-Admin {
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-StackTask {
    try { Get-ScheduledTask -TaskName $taskName -ErrorAction Stop } catch { $null }
}

function Start-StackTaskFromConsole {
    $task = Get-StackTask
    if (-not $task) {
        Write-Host ''
        Write-Host ('The background task "' + $taskName + '" is not installed.') -ForegroundColor Red
        Write-Host 'Run setup-background-server.ps1 as administrator once, then try again.' -ForegroundColor Yellow
        return $false
    }
    if ($task.State -eq 'Running') {
        Write-Host ('  background task  already running') -ForegroundColor DarkGray
        return $true
    }

    if (Test-Path $stopFlag) {
        Remove-Item -Path $stopFlag -Force -ErrorAction SilentlyContinue
    }

    try {
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        Write-Host ('  background task  started') -ForegroundColor Green
        return $true
    } catch {
        Write-Host ('  background task  start needs Windows approval') -ForegroundColor Yellow
        $cmd = "Start-ScheduledTask -TaskName '" + $taskName + "'"
        try {
            $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList @(
                '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd
            )
            if ($p.ExitCode -eq 0) {
                Write-Host ('  background task  started') -ForegroundColor Green
                return $true
            }
        } catch { }
        Write-Host ('  background task  could not start: ' + $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

function Get-StatusJson {
    try {
        $raw = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'status.ps1') -Json 2>$null
        if ($raw) { return ($raw | ConvertFrom-Json) }
    } catch { }
    return $null
}

function Get-JavaProcess {
    Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'server\.jar' } | Select-Object -First 1
}

function Show-LiveLog {
    # Tails logs\latest.log in this window. Used both when this window started
    # the server and when the server is already running in the background.
    $logPath = Join-Path $root 'logs\latest.log'
    if (-not (Test-Path $logPath)) { $logPath = Join-Path $root 'logs\host.log' }

    if (Test-Path $logPath) {
        $tail = @(Get-Content -Path $logPath -Tail 40 -ErrorAction SilentlyContinue)
        foreach ($line in $tail) { Write-Host $line }
        $position = (Get-Item $logPath).Length
    } else {
        $position = 0
    }
    $lastSize = $position
    $missingNotice = $false

    try {
        while ($true) {
            Start-Sleep -Milliseconds 700

            if (-not (Test-Path $logPath)) {
                if (-not $missingNotice) {
                    Write-Host ('Waiting for ' + $logPath + ' ...') -ForegroundColor DarkGray
                    $missingNotice = $true
                }
                continue
            }
            $missingNotice = $false

            try {
                $item = Get-Item $logPath -ErrorAction Stop
            } catch {
                continue
            }

            # latest.log is truncated when Minecraft restarts.
            if ($item.Length -lt $lastSize) {
                $position = 0
                Write-Host ''
                Write-Host '--- new server session --------------------------------------' -ForegroundColor DarkGray
            }
            $lastSize = $item.Length

            if ($item.Length -le $position) { continue }

            try {
                $fs = [IO.File]::Open($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    $fs.Seek($position, [IO.SeekOrigin]::Begin) | Out-Null
                    $reader = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                    try { $text = $reader.ReadToEnd() } finally { $reader.Close() }
                } finally {
                    $fs.Close()
                }
                if ($text) { [Console]::Write($text) }
                $position = $item.Length
            } catch {
                # The file can be briefly locked while Minecraft rotates it.
            }
        }
    } finally {
        Write-Host ''
    }
}

# The one-time SYSTEM task setup may not have been run yet. Keep start.bat
# usable: if the server is already running, point at the panel console;
# otherwise fall back to the normal interactive server console in this window.
$stackTask = Get-StackTask
if (-not $stackTask) {
    $java = Get-JavaProcess
    if ($java) {
        Write-Host ''
        Write-Host ('The server is already running in the background (PID ' + $java.ProcessId + ').') -ForegroundColor Green
        Write-Host 'Commands: the panel console at http://10.0.0.15:8787' -ForegroundColor DarkGray
        Write-Host 'Closing this window does not stop the server.' -ForegroundColor DarkGray
        Write-Host ''
        Show-LiveLog
        exit 0
    }
    Write-Host ''
    Write-Host 'Starting the server in this window...' -ForegroundColor Yellow
    Write-Host 'Closing this window stops the server.' -ForegroundColor DarkGray
    Write-Host ''
    & (Join-Path $root 'start.ps1')
    exit $LASTEXITCODE
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor DarkGray
Write-Host ' Minecraft server' -ForegroundColor White
Write-Host '============================================================' -ForegroundColor DarkGray

if (-not $NoStart) {
    if (-not (Start-StackTaskFromConsole)) {
        Write-Host ''
        Write-Host 'The server was not started. Fix the error above, then run start.bat again.' -ForegroundColor Yellow
        Read-Host 'Press Enter to close'
        exit 1
    }
}

$components = @(
    [pscustomobject]@{ Key = 'playit';     Label = 'playit.gg';   DetailKey = '' },
    [pscustomobject]@{ Key = 'discord';    Label = 'discord bot'; DetailKey = '' },
    [pscustomobject]@{ Key = 'panel';      Label = 'panel';       DetailKey = 'panelUrl' },
    [pscustomobject]@{ Key = 'backups';    Label = 'backups';     DetailKey = '' },
    [pscustomobject]@{ Key = 'tpsMonitor'; Label = 'tps monitor'; DetailKey = '' }
)
$shown = @{}
$deadline = (Get-Date).AddSeconds(75)

while ((Get-Date) -lt $deadline) {
    $status = Get-StatusJson
    if ($status) {
        foreach ($c in $components) {
            if ($shown.ContainsKey($c.Key)) { continue }
            $value = $null
            try { $value = $status.($c.Key) } catch { }
            $ok = $false
            if ($c.Key -eq 'discord') {
                $ok = ($value -eq 'running')
            } else {
                $ok = [bool]$value
            }
            if ($ok) {
                $detail = ''
                if ($c.DetailKey) {
                    try {
                        $d = $status.($c.DetailKey)
                        if ($d) { $detail = '  ' + $d }
                    } catch { }
                }
                Write-Host ('  ' + $c.Label.PadRight(14) + 'running' + $detail) -ForegroundColor Green
                $shown[$c.Key] = $true
            }
        }
    }

    $java = Get-JavaProcess
    if ($shown.Count -eq $components.Count -and $java) { break }
    if ($java -and $shown.Count -ge 4) { break }
    Start-Sleep -Seconds 2
}

foreach ($c in $components) {
    if (-not $shown.ContainsKey($c.Key)) {
        $state = 'not running'
        $tone = 'Yellow'
        if ($c.Key -eq 'discord') {
            $s = Get-StatusJson
            if ($s -and $s.discord) { $state = [string]$s.discord }
            if ($state -eq 'not configured') { $tone = 'DarkGray' }
        }
        Write-Host ('  ' + $c.Label.PadRight(14) + $state) -ForegroundColor $tone
    }
}

$java = Get-JavaProcess
Write-Host ''
if ($java) {
    Write-Host ('  java             running (PID ' + $java.ProcessId + ')') -ForegroundColor Green
} else {
    Write-Host '  java             not running yet' -ForegroundColor Yellow
    Write-Host '  If it stays down, check logs\host.log and logs\latest.log.' -ForegroundColor DarkGray
}
Write-Host ('  panel            ' + $panelUrl) -ForegroundColor DarkGray
Write-Host '============================================================' -ForegroundColor DarkGray
Write-Host ' The server runs as a background task. Closing this window does' -ForegroundColor DarkGray
Write-Host ' not stop it. Use the panel console for commands.' -ForegroundColor DarkGray
Write-Host '============================================================' -ForegroundColor DarkGray
Write-Host ''

if ($NoTail) { exit 0 }

Show-LiveLog

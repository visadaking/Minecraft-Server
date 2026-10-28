#Requires -Version 5.1
<#
    Runs backup.ps1 periodically while the server is up.
    Started minimized by start.bat; exits by itself a few minutes after the
    server stops. Only one loop can run at a time.
#>
param(
    [double]$IntervalHours = 2,
    [int]$Keep = 5
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$backupScript = Join-Path $root 'backup.ps1'
$backupDir = Join-Path $root 'backups'
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$logFile = Join-Path $backupDir 'backup-loop.log'

function Write-LoopLog {
    param([string]$Message)
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
}

function Get-ServerPort {
    $path = Join-Path $root 'server.properties'
    if (Test-Path $path) {
        foreach ($line in Get-Content $path -Encoding UTF8) {
            if ($line -match '^\s*server-port\s*=\s*(\d+)') { return [int]$Matches[1] }
        }
    }
    return 25565
}

function Test-ServerListening {
    param([int]$Port)
    try {
        return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
    } catch {
        return $false
    }
}

$mutex = New-Object System.Threading.Mutex($false, 'MinecraftBackupLoopMutex')
$hasMutex = $false
try {
    $hasMutex = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $hasMutex = $true
}
if (-not $hasMutex) { exit 0 }

try {
    $port = Get-ServerPort
    Write-LoopLog ("Backup loop started (every {0} h, keep {1}, server port {2})." -f $IntervalHours, $Keep, $port)

    $next = (Get-Date).AddHours($IntervalHours)
    $downSeconds = 0

    while ($true) {
        if (Test-ServerListening $port) {
            $downSeconds = 0
            if ((Get-Date) -ge $next) {
                Write-LoopLog 'Scheduled backup starting.'
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $backupScript -Keep $Keep
                if ($LASTEXITCODE -ne 0) {
                    Write-LoopLog ("Backup process exited with code {0}." -f $LASTEXITCODE)
                }
                $next = (Get-Date).AddHours($IntervalHours)
            }
        } else {
            $downSeconds += 60
            if ($downSeconds -ge 180) {
                Write-LoopLog 'Server has been offline for 3 minutes; stopping backup loop.'
                break
            }
        }
        Start-Sleep -Seconds 60
    }
}
finally {
    if ($hasMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

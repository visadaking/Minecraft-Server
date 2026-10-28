#Requires -Version 5.1
<#
    Auto-update for the Minecraft server.

    Decides which version the server should run from update-track.txt in the
    server folder (first non-comment line):
        release  (default) - newest stable release
        snapshot           - newest 26.4 snapshot (players must switch their
                             launcher to the same snapshot to join!)

    If server.jar is older than that:
      1. posts "server updating to X (was Y) - restarting soon" to Discord
      2. saves a pre-update backup (backup-preupdate-*, kept forever)
      3. downloads the new server.jar and verifies its SHA-1
      4. stops the server cleanly over RCON, swaps the jar
      5. starts the server again (only if it was running!)
      6. posts "server updated to X (was Y) - update your game to join"

    Never touches a server that is offline, so a manual stop stays stopped.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File update-server.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File update-server.ps1 -Watch
        powershell -NoProfile -ExecutionPolicy Bypass -File update-server.ps1 -ShowTarget
#>
[CmdletBinding()]
param(
    [switch]$Watch,
    [int]$CheckMinutes = 60,
    [switch]$ShowTarget
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) 'mc-update'
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$stateLog = Join-Path $root 'logs\update-server.log'

function Write-UpdateLog {
    param([string]$Message)
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message
    try { Add-Content -Path $stateLog -Value $line -Encoding UTF8 } catch { }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
. (Join-Path $root 'rcon.ps1')
. (Join-Path $root 'discord\discord.ps1')

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

function Get-ServerJarVersion {
    $jarPath = Join-Path $root 'server.jar'
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($jarPath)
        try {
            $entry = $zip.GetEntry('version.json')
            if (-not $entry) { return $null }
            $reader = New-Object IO.StreamReader($entry.Open())
            try { $raw = $reader.ReadToEnd() } finally { $reader.Close() }
            $json = $raw | ConvertFrom-Json
            $releaseTime = ''
            try { $releaseTime = [string]$json.release_time } catch { }
            return [pscustomobject]@{ Id = [string]$json.id; ReleaseTime = $releaseTime }
        } finally { $zip.Dispose() }
    } catch {
        return $null
    }
}

function Send-UpdateAnnouncement {
    param([string]$Text)
    try {
        $config = Get-DiscordConfig -Root (Join-Path $root 'discord')
        if (-not (Test-DiscordConfig -Config $config)) { return }
        $json = @{ content = $Text; allowed_mentions = @{ parse = @() } } | ConvertTo-Json -Compress
        Send-DiscordMessage -Config $config -Json $json | Out-Null
    } catch {
        Write-UpdateLog ('Announcement failed: ' + $_.Exception.Message)
    }
}

function Get-UpdateTrack {
    $path = Join-Path $root 'update-track.txt'
    if (Test-Path $path) {
        foreach ($line in Get-Content -Path $path -Encoding UTF8) {
            $text = $line.Trim()
            if ($text.Length -gt 0 -and -not $text.StartsWith('#')) {
                if ($text -eq 'snapshot' -or $text -eq 'release') { return $text }
                return 'release'
            }
        }
    }
    return 'release'
}

function Get-TargetVersion {
    param([string]$Track)
    try {
        $manifest = Invoke-RestMethod -Uri 'https://launchermeta.mojang.com/mc/game/version_manifest_v2.json' -TimeoutSec 30
        $wanted = 'type'
        $value = if ($Track -eq 'snapshot') { 'snapshot' } else { 'release' }
        # The manifest is newest first.
        $target = $manifest.versions | Where-Object { $_.$wanted -eq $value } | Select-Object -First 1
        if (-not $target) { return $null }
        return [pscustomobject]@{
            Id          = [string]$target.id
            Url         = $target.url
            ReleaseTime = [string]$target.releaseTime
        }
    } catch {
        Write-UpdateLog ('Could not read the version manifest: ' + $_.Exception.Message)
        return $null
    }
}

function Get-PlayerCountRcon {
    param([int]$Port, [string]$Password)
    try {
        $session = Connect-Rcon -Password $Password -Port $Port -TimeoutMs 8000
        try {
            $out = Invoke-RconSession -Session $session -Command 'list' -TimeoutMs 8000
            if ($out -match 'There are (\d+) of a max of (\d+) players') { return [int]$Matches[1] }
        } finally { Close-RconSession $session }
    } catch { }
    return 0
}

function Request-Update {
    param([string]$Track)

    $current = Get-ServerJarVersion
    if (-not $current -or [string]::IsNullOrWhiteSpace($current.Id)) {
        Write-UpdateLog 'Could not read the current server.jar version; skipping.'
        return $false
    }

    $target = Get-TargetVersion -Track $Track
    if (-not $target) { return $false }
    if ($target.Id -eq $current.Id) { return $false }

    # Never move backwards: a stable release is older than the snapshots that
    # led up to it, so compare official release dates.
    $currentTime = $null
    $targetTime = $null
    try { $currentTime = [datetime]::Parse($current.ReleaseTime) } catch { }
    try { $targetTime = [datetime]::Parse($target.ReleaseTime) } catch { }
    if ($currentTime -and $targetTime -and ($targetTime -le $currentTime)) {
        Write-UpdateLog ('Target ' + $target.Id + ' is not newer than the installed ' + $current.Id + '; skipping.')
        return $false
    }

    # Only update a RUNNING server. A stopped server stays stopped (the next
    # normal start brings it up with the jar that is on disk).
    $gamePort = 25565
    try { $gamePort = [int](Get-ServerProperty 'server-port' '25565') } catch { }
    if (-not (Test-GamePortListening -Port $gamePort)) {
        Write-UpdateLog ('New version available (' + $target.Id + ', current ' + $current.Id + '), but the server is offline; not starting anything.')
        return $false
    }

    if ($ShowTarget) {
        Write-LogAndHost ('Would update ' + $current.Id + ' -> ' + $target.Id)
        return $false
    }

    Write-UpdateLog ('Update available: ' + $current.Id + ' -> ' + $target.Id)
    Send-UpdateAnnouncement -Text ('server updating to ' + $target.Id + ' (was ' + $current.Id + ') - restarting soon')

    # 1) pre-update backup (tagged, kept forever; live RCON save if the server runs)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'backup.ps1') -Tag preupdate -Keep 5
    if ($LASTEXITCODE -ne 0) {
        Send-UpdateAnnouncement -Text ('server update to ' + $target.Id + ' failed: backup failed - still running ' + $current.Id)
        return $false
    }

    # 2) download + verify BEFORE stopping anything
    $package = Invoke-RestMethod -Uri $target.Url -TimeoutSec 30
    $dl = $package.downloads.server
    $target1 = Join-Path $tmpDir ('server-' + $target.Id + '.jar')
    try {
        Invoke-WebRequest -Uri $dl.url -OutFile $target1 -TimeoutSec 600
    } catch {
        Send-UpdateAnnouncement -Text ('server update to ' + $target.Id + ' failed: download failed - still running ' + $current.Id)
        Write-UpdateLog ('Download failed: ' + $_.Exception.Message)
        return $false
    }
    if ((Get-FileHash -Path $target1 -Algorithm SHA1).Hash.ToLower() -ne $dl.sha1.ToLower()) {
        Send-UpdateAnnouncement -Text ('server update to ' + $target.Id + ' failed: download check failed - still running ' + $current.Id)
        Remove-Item -Path $target1 -Force -ErrorAction SilentlyContinue
        return $false
    }
    $zip = [IO.Compression.ZipFile]::OpenRead($target1)
    try {
        $e = $zip.GetEntry('version.json')
        $r = New-Object IO.StreamReader($e.Open())
        try { $inside = ($r.ReadToEnd() | ConvertFrom-Json).id } finally { $r.Close() }
    } finally { $zip.Dispose() }
    if ($inside -ne $target.Id) {
        Send-UpdateAnnouncement -Text ('server update to ' + $target.Id + ' failed: wrong jar version ' + $inside)
        return $false
    }
    Write-UpdateLog ('Downloaded and verified ' + $target.Id + '.')

    # 3) wait for an empty server if people are online (up to 15 minutes)
    $rconPort = 25575
    try { $rconPort = [int](Get-ServerProperty 'rcon.port' '25575') } catch { }
    $rconPassword = Get-ServerProperty 'rcon.password' ''
    $waited = 0
    while ($waited -lt 900) {
        $online = Get-PlayerCountRcon -Port $rconPort -Password $rconPassword
        if ($online -le 0) { break }
        if ($waited -eq 0) {
            Send-UpdateAnnouncement -Text ('waiting for the server to empty before restarting (' + $online + ' online)')
        }
        Start-Sleep -Seconds 30
        $waited += 30
    }

    # 4) stop, swap, start
    $jarPath = Join-Path $root 'server.jar'
    $prevPath = Join-Path $root 'server.jar.prev.bak'
    $wasRunning = Test-GamePortListening -Port $gamePort

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'server-control.ps1') -Action stop
    Start-Sleep -Seconds 5
    if (Test-GamePortListening -Port $gamePort) {
        Send-UpdateAnnouncement -Text ('server update to ' + $target.Id + ' failed: could not stop the server')
        return $false
    }

    Remove-Item -Path $prevPath -Force -ErrorAction SilentlyContinue
    Move-Item -Path $jarPath -Destination $prevPath -Force
    Move-Item -Path $target1 -Destination $jarPath -Force
    try {
        Set-Content -Path (Join-Path $root 'logs\last-server-version.txt') -Value $target.Id -Encoding UTF8
    } catch { }
    Write-UpdateLog ('Swapped ' + $current.Id + ' -> ' + $target.Id + '.')

    if ($wasRunning) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'server-control.ps1') -Action start
        $deadline = (Get-Date).AddSeconds(150)
        $up = $false
        while ((Get-Date) -lt $deadline) {
            if (Test-GamePortListening -Port $gamePort) { $up = $true; break }
            Start-Sleep -Seconds 5
        }
        if ($up) {
            Send-UpdateAnnouncement -Text ('server updated to ' + $target.Id + ' (was ' + $current.Id + ') - update your game to join')
            Write-UpdateLog ('Update finished: ' + $target.Id + '.')
        } else {
            Send-UpdateAnnouncement -Text ('server updated to ' + $target.Id + ' but the port is not open yet - check the panel or logs')
            Write-UpdateLog 'WARNING: update applied but the game port did not come back.'
        }
    } else {
        Write-UpdateLog ('Server was not running; jar is updated for the next start.')
    }
    return $true
}

function Write-LogAndHost {
    param([string]$Text)
    Write-Host $Text
    Write-UpdateLog $Text
}

Write-UpdateLog ('Auto-update started (track ' + (Get-UpdateTrack) + ', watch: ' + [bool]$Watch + ').')

if ($ShowTarget) {
    [void](Request-Update -Track (Get-UpdateTrack))
    return
}

if (-not $Watch) {
    [void](Request-Update -Track (Get-UpdateTrack))
    return
}

# --------------------------------------------------------------- watch loop
$mutex = New-Object System.Threading.Mutex($false, 'MinecraftUpdateWatchMutex')
$hasMutex = $false
try { $hasMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $hasMutex = $true }
if (-not $hasMutex) { exit 0 }

try {
    $port = 25565
    try { $port = [int](Get-ServerProperty 'server-port' '25565') } catch { }
    $downSeconds = 0
    while ($true) {
        if (Test-GamePortListening -Port $port) {
            $downSeconds = 0
            [void](Request-Update -Track (Get-UpdateTrack))
        } else {
            $downSeconds += 60
            if ($downSeconds -ge 300) {
                Write-UpdateLog 'Server has been offline for 5 minutes; stopping the auto-update watcher.'
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

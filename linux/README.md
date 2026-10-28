# github release - linux

Linux build of the server helper stack (PowerShell 7 required, `pwsh`).

## What is included

* `rcon.ps1` - Source RCON client (pure .NET, works anywhere)
* `stop.ps1` / `stop.sh` - graceful RCON stop for the server
* `start.sh` - simple manual launcher (pid file in logs\; systemd is recommended)
* `backup.ps1` - everything-backup, zip, world copy, tagged preupdate backups,
  rotation that keeps plain backups down to -Keep and preupdate backups forever
* `update-server.ps1` - auto-update: checks Mojang hourly (-Watch), never
  downgrades, announces "server updating ..." and "server updated ..."
  on Discord, downloads + SHA-1-verifies the jar, stops over RCON, swaps,
  then runs restart-command.txt
* `update-track.txt` - "release" or "snapshot" (never downgrades!)
* `restart-command.txt.example` - copy to restart-command.txt and set the
  command that starts your server again (e.g. systemctl restart minecraft)
* `tps-monitor.ps1` - lag watcher with Discord alerts
* `discord\` - status feed + two-way chat bridge
  (discord.ps1 auto-detects the outbound address on Linux; discord-bind.txt
  overrides it, loopback/VPN keeps refusing to send)
* `README.md`

The Windows-only control panel (gui-server.ps1) is intentionally not part of
the Linux build.

## Requirements

```bash
sudo apt install -y powershell openjdk-21-jre-headless   # or your distro's way
```

## Quick start (manual)

```bash
chmod +x start.sh stop.sh
./start.sh      # java writes logs/latest.log
./stop.sh       # graceful RCON stop
```

## Recommended (systemd)

`/etc/systemd/system/minecraft.service`:

```ini
[Unit]
Description=Minecraft server
After=network.target

[Service]
User=minecraft
WorkingDirectory=/home/minecraft/server
ExecStart=/usr/bin/java -Xms6G -Xmx6G -jar server.jar nogui
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now minecraft
```

Then create `restart-command.txt` containing `systemctl restart minecraft`
so updates restart the service themselves.

## Backups every 2 hours (cron)

```cron
0 */2 * * * cd /home/minecraft/server && pwsh -NoProfile -File backup.ps1 -Keep 5 >> logs/backup.log 2>&1
```

## Discord

1. Put a webhook into `discord\discord-webhook.txt`, or bot token + channel id
   into `discord\discord-bot.txt` (bot mode needed for Discord -> game chat).
2. Run the feed and the chat bridge:

```bash
pwsh -NoProfile -File discord/discord-status.ps1 &
pwsh -NoProfile -File discord/discord-chat.ps1 &
```

(or as systemd services / tmux windows - they exit on their own 5 minutes
after the server goes offline, same as the Windows build)

## Auto-update

```bash
pwsh -NoProfile -File update-server.ps1 -Watch -CheckMinutes 60
```

Set the track in `update-track.txt` (release = stable only, snapshot = the
bleeding edge; players must run the same version either way).

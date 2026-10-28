#!/usr/bin/env bash
# Graceful stop over RCON; falls back to SIGTERM from logs/java.pid.
cd "$(dirname "$0")" || exit 1
if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File stop.ps1 && exit 0
fi
if [ -f logs/java.pid ]; then
  kill "$(cat logs/java.pid)"
  echo "sent SIGTERM to $(cat logs/java.pid)"
fi
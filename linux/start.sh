#!/usr/bin/env bash
# Starts the Minecraft server in this folder and writes logs/java.pid.
# For boot persistence use the minecraft.service example in README.md.
cd "$(dirname "$0")" || exit 1
if [ -f logs/java.pid ] && kill -0 "$(cat logs/java.pid)" 2>/dev/null; then
  echo "server already running (pid $(cat logs/java.pid))"
  exit 0
fi
mkdir -p logs
java -Xms6G -Xmx6G -jar server.jar nogui > logs/latest.log 2>&1 &
echo $! > logs/java.pid
echo "java started (pid $(cat logs/java.pid))"

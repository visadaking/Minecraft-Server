@echo off
rem Tiny launcher: the server itself runs as a background SYSTEM task, so a
rem Windows logoff or the F5 BIG-IP Edge Client cannot kill it.
rem This opens a visible PowerShell window that starts the task, shows the
rem startup status, and tails the live server log. Closing this window does
rem not stop the server.
setlocal
cd /d "%~dp0"
start "Minecraft Server" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0server-console.ps1"
endlocal

@echo off
rem Opens PitCrew. It asks for administrator rights by itself; say No to open it read-only.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0PitCrew.ps1" %*

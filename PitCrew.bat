@echo off
setlocal
rem Opens PitCrew. It asks for administrator rights by itself; say No to open it read-only.
rem The full path keeps cmd from running some other powershell.exe found in this folder or on PATH.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0PitCrew.ps1" %*
set "code=%errorlevel%"
rem Opened with a double click and PitCrew stopped without showing its own message (any code but
rem 0, or 2 = already shown): keep this window open so the error can be read. Never with arguments,
rem so a script or scheduled task using PitCrew.bat can't hang here.
if "%~1"=="" if not "%code%"=="0" if not "%code%"=="2" pause
exit /b %code%

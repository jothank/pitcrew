@echo off
setlocal
rem Installs PitCrew in Program Files, with a shortcut on the desktop and in the Start menu, and
rem lists it under Settings > Apps so it can be removed there. It asks first; Windows then asks
rem for administrator rights. The work is done by src\Setup.ps1, a script you can read.
if not exist "%~dp0src\Setup.ps1" goto notextracted
rem A 32-bit program that opens this file sees SysWOW64 as System32; Sysnative reaches the 64-bit
rem PowerShell, which installs into Program Files and not Program Files (x86).
set "ps=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "ps=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%ps%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0src\Setup.ps1" -Install %*
set "code=%errorlevel%"
rem 0 = done or cancelled, 2 = Setup.ps1 already showed its message; anything else is an error
rem printed in this window, so keep it open. Never with arguments (-Quiet in scripts and tests),
rem so nothing waits for a key there.
if "%~1"=="" if not "%code%"=="0" if not "%code%"=="2" pause
exit /b %code%

:notextracted
echo PitCrew's files are not next to Install.bat.
echo Extract the whole zip first: right-click it, choose Extract All, then run Install.bat
echo from the extracted PitCrew folder.
pause
exit /b 1

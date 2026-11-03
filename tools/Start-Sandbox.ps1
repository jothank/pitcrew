<#
.SYNOPSIS
    Opens PitCrew inside Windows Sandbox, a disposable Windows that is wiped when closed. This is
    the safe way to try Apply/Undo for real.

.DESCRIPTION
    Needs Windows 10/11 Pro or higher with the "Windows Sandbox" feature turned on
    (Settings > System > Optional features > More Windows features). The repository is mapped
    read-only, and PitCrew starts in test mode because the sandbox can't create restore points.
#>
param([string]$Language)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

if (-not (Get-Command WindowsSandbox.exe -ErrorAction SilentlyContinue)) {
    throw 'Windows Sandbox is not enabled. Turn on "Windows Sandbox" in Windows Features and restart.'
}

$launchArgs = '-NoProfile -STA -ExecutionPolicy Bypass -File C:\PitCrew\PitCrew.ps1 -NoRestorePoint'
if ($Language) { $launchArgs += " -Language $Language" }
$config = @"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$([Security.SecurityElement]::Escape($root))</HostFolder>
      <SandboxFolder>C:\PitCrew</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe $launchArgs</Command>
  </LogonCommand>
</Configuration>
"@
$wsb = Join-Path $env:TEMP 'PitCrew.wsb'
[IO.File]::WriteAllText($wsb, $config, [Text.Encoding]::UTF8)
Start-Process WindowsSandbox.exe -ArgumentList "`"$wsb`""

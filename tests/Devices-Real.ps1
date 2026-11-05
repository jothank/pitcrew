<#
.SYNOPSIS
    The device power switch for real: turns one device's "Allow the computer to turn off this
    device" box the other way and puts it back. Only on GitHub-hosted runners (throwaway VMs, run
    as administrator); anywhere else, or on a VM without such a device, it prints "skip".
    Exit code = failures.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not ($env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted')) {
    Write-Host '  skip  the real device switch (only on a GitHub-hosted runner)'
    exit 0
}
. (Join-Path $root 'src\Load.ps1')
Initialize-PcContext -Root $root -DataDir (Join-Path $env:TEMP ('PitCrewDevices-' + [guid]::NewGuid().ToString('N')))
$states = Get-PcDevicePowerStates
$devices = @(Get-PcPowerDevices)
Write-Host ('  info  {0} device(s) with the box here, {1} shown on the page' -f $states.Count, $devices.Count)
# A device the page shows, but never a network adapter: the runner's job talks to GitHub through it
$pick = $devices | Where-Object { @('wifi', 'ethernet', 'network') -notcontains $_.Kind } | Select-Object -First 1
if (-not $pick) {
    Write-Host '  skip  the real device switch (no device on this runner that the page shows, other than network)'
    exit 0
}
$name = @($pick.Instances)[0]
$was = $states[$name]
try {
    Set-PcDevicePowerEnabled $name (-not $was)
    $now = (Get-PcDevicePowerStates)[$name]
    if ($now -ne (-not $was)) { throw "set to $(-not $was), but it reads $now" }
} catch {
    Write-Host "  FAIL  the real device switch on ${name}: $($_.Exception.Message)"
    exit 1
} finally {
    try { Set-PcDevicePowerEnabled $name $was } catch { Write-Host "  FAIL  putting $name back: $($_.Exception.Message)" }
}
if ((Get-PcDevicePowerStates)[$name] -ne $was) {
    Write-Host "  FAIL  $name was not put back"
    exit 1
}
Write-Host "  ok    the real device switch changed $name and put it back"
exit 0

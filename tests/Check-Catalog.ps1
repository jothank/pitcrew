<#
.SYNOPSIS
    Read-only check of the catalog against THIS PC: for every tweak, whether each action's target
    exists (service, scheduled task, power plan...) and whether it is already applied. Changes
    nothing. Useful after adding tweaks: an action that is "missing" everywhere is probably a typo.
#>
param([string]$Language = 'en', [string]$Id)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Load.ps1')
Initialize-PcContext -Root $root -Language $Language

Write-Host ("Windows {0} build {1} ({2}, family {3}), {4}" -f (Get-PcWindowsInfo).DisplayVersion, (Get-PcWindowsInfo).Build,
    (Get-PcWindowsInfo).Edition, (Get-PcEditionFamily), (Get-PcFormFactor))

foreach ($t in Import-PcTweaks | Where-Object { -not $Id -or $_.id -like $Id }) {
    Write-Host ''
    Write-Host ('{0}  [{1}]  {2}' -f $t.id, (Get-PcTweakState $t), (Resolve-PcLocalized $t.title)) -ForegroundColor Cyan
    foreach ($a in @($t.actions)) {
        $target = switch ($a.type) {
            'registry' { '{0}\{1}' -f $a.path, $a.name }
            'dxSetting' { 'DirectXUserGlobalSettings: {0}' -f $a.key }
            'service' { 'service {0} -> {1}' -f $a.name, $a.startupType }
            'scheduledTask' { 'task {0}{1}' -f $a.path, $a.name }
            'powerPlan' { 'power plan {0}' -f $a.guid }
            'hibernation' { 'hibernation -> {0}' -f $a.enabled }
        }
        try {
            $available = Test-PcActionAvailable $a
            $applied = if ($available) { Test-PcActionApplied $a } else { $false }
            $label = if (-not $available) { 'missing' } elseif ($applied) { 'applied' } else { 'not applied' }
        } catch { $label = "ERROR: $($_.Exception.Message)" }
        $color = if ($label -eq 'missing' -or $label -like 'ERROR*') { 'Yellow' } else { 'Gray' }
        Write-Host ('    {0,-12} {1}' -f $label, $target) -ForegroundColor $color
    }
}

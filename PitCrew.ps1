<#
.SYNOPSIS
    PitCrew: tune-up for Windows 10/11 where every change can be undone.

.DESCRIPTION
    Without parameters, opens the window (asks for administrator; if refused, opens read-only).
    The parameters below run without a window, for scripts and for checking a PC quickly.

.PARAMETER List
    Lists every tweak with its current state on this PC. Changes nothing.

.PARAMETER Apply
    Tweak ids to apply. Creates a restore point first and stops if that fails.

.PARAMETER Undo
    Tweak ids to undo (only ones PitCrew applied).

.PARAMETER Language
    Interface language, e.g. en, pt-BR, es. Defaults to the Windows language.

.PARAMETER NoRestorePoint
    Test mode for Windows Sandbox and VMs, which can't create restore points. Changes are still
    recorded in the undo journal. Don't use it on a real PC.

.EXAMPLE
    .\PitCrew.ps1 -List
.EXAMPLE
    .\PitCrew.ps1 -Apply privacy.advertising-id, privacy.activity-history
#>
[CmdletBinding(DefaultParameterSetName = 'Window')]
param(
    [Parameter(ParameterSetName = 'List')][switch]$List,
    [Parameter(ParameterSetName = 'Apply')][string[]]$Apply,
    [Parameter(ParameterSetName = 'Undo')][string[]]$Undo,
    [string]$Language,
    [switch]$NoRestorePoint,
    # Set by the relaunch below so a refused UAC prompt doesn't loop
    [Parameter(ParameterSetName = 'Window')][switch]$NoElevate
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'src\Load.ps1')
Initialize-PcContext -Root $PSScriptRoot -Language $Language -SkipRestorePoint:$NoRestorePoint
if (Test-PcAdmin) {
    # Fails closed: if the folder can't be secured, every change is refused (Assert-PcDataTrusted)
    try { Protect-PcDataDir } catch { Write-PcLog "Could not secure $($Pc.DataDir): $($_.Exception.Message)" 'Error' }
}

if ($List) {
    Import-PcTweaks | ForEach-Object {
        [pscustomobject]@{
            Id    = $_.id
            State = Get-PcTweakState $_
            Risk  = $_.risk
            Title = Resolve-PcLocalized $_.title
        }
    } | Format-Table -AutoSize
    return
}

if ($Apply -or $Undo) {
    if (-not (Test-PcAdmin)) { throw (Get-PcText 'error.needsAdmin') }
    $tweaks = @(Import-PcTweaks)
    # "-File" passes "a,b" as one string, so split it here too
    $ids = @((@($Apply) + @($Undo)) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $unknown = @($ids | Where-Object { $tweaks.id -notcontains $_ })
    if ($unknown) { throw "Unknown tweak id: $($unknown -join ', ')" }
    if ($Apply) {
        if (-not (New-PcRestorePoint -Description ('PitCrew {0:yyyy-MM-dd HH:mm}' -f (Get-Date)))) {
            throw (Get-PcText 'msg.noRestorePointAbort')
        }
        foreach ($id in $ids) {
            $changed = Invoke-PcTweak ($tweaks | Where-Object id -eq $id)
            if ($changed) { Write-Host "Applied $id" } else { Write-Host "Already in place: $id" }
        }
    } else {
        foreach ($id in $ids) { $r = Undo-PcTweak ($tweaks | Where-Object id -eq $id); Write-Host "Undid $id (skipped $($r.Skipped))" }
    }
    return
}

# --- Window ---------------------------------------------------------------------------------------

$needsSta = [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'
if (-not $NoElevate -and ($needsSta -or -not (Test-PcAdmin))) {
    $relaunch = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -NoElevate"
    if ($Language) { $relaunch += " -Language $Language" }
    if ($NoRestorePoint) { $relaunch += ' -NoRestorePoint' }
    try {
        if (Test-PcAdmin) { Start-Process powershell.exe -ArgumentList $relaunch }
        else { Start-Process powershell.exe -Verb RunAs -ArgumentList $relaunch }
        return
    } catch {
        # UAC refused: open read-only in this process instead
        Write-PcLog 'Administrator refused; opening read-only'
    }
}

try {
    . (Join-Path $PSScriptRoot 'src\UI\Window.ps1')
    Show-PcWindow
} catch {
    Write-PcLog "Fatal: $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'Error'
    Add-Type -AssemblyName PresentationFramework
    [void][System.Windows.MessageBox]::Show("PitCrew: $($_.Exception.Message)", 'PitCrew', 'OK', 'Error')
    exit 1
}

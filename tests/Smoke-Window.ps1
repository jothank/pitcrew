<#
.SYNOPSIS
    Drives the window's read-only background jobs without showing the window: cleanup analysis,
    app list, driver summary and a Windows Update driver search. Nothing is changed on the PC.
    Run in an STA process: powershell -STA -File tests\Smoke-Window.ps1
#>
param([string]$Language = 'en')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Load.ps1')
Initialize-PcContext -Root $root -Language $Language
. (Join-Path $root 'src\UI\Window.ps1')
# Message boxes would block a headless run; print them instead
function Show-PcMessage([string]$Text, [string]$Icon = 'Information') { Write-Host "[message/$Icon] $Text" }

$failures = 0
$window = New-PcWindow
$Ui.Timer.Stop()

function Wait-PcJob([int]$TimeoutSec = 300) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($script:PcJob -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; Complete-PcJob }
    if ($script:PcJob) { throw 'job timed out' }
}

function Test-Page([string]$Name, [scriptblock]$Start, [scriptblock]$Check) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $Start
    Wait-PcJob
    $items = @($Ui.Items.ItemsSource)
    $ok = & $Check $items
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ('{0,-16} {1} items, {2:N1}s, status "{3}"' -f $Name, $items.Count, $sw.Elapsed.TotalSeconds, $Ui.StatusText.Text) -ForegroundColor $color
    if (-not $ok) { $script:failures++ }
}

Test-Page 'cleanup' { Show-PcPage 'cleanup' } { param($items) $items.Count -eq @($script:PcCleanupTargets).Count }
Test-Page 'apps' { Show-PcPage 'apps' } { param($items) $items.Count -eq @(Get-PcAppCatalog).Count }
Test-Page 'drivers summary' { Show-PcPage 'drivers' } { param($items) [bool]$Ui.PageInfo.Text }
Test-Page 'driver search' { Invoke-PcSearchDrivers } { param($items) $Ui.EmptyText.Visibility -eq 'Visible' -or $items.Count -gt 0 }
Test-Page 'performance' { Show-PcPage 'performance' } { param($items) $items.Count -eq @($script:PcTweaks | Where-Object category -eq 'performance').Count }

exit $failures

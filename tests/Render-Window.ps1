<#
.SYNOPSIS
    Renders the PitCrew window to a PNG without showing it or running any action. Used to check
    the layout in screenshots for docs and reviews. Must run in an STA process:
    powershell -STA -File tests\Render-Window.ps1 -Out docs\screenshot.png -Language pt-BR -Page privacy
#>
param(
    [Parameter(Mandatory)][string]$Out,
    [string]$Language = 'en',
    [ValidateSet('dashboard', 'analysis', 'analysis-dialog', 'performance', 'privacy', 'explorer', 'startup', 'cleanup', 'memory', 'maintenance', 'apps', 'devices', 'history', 'about',
        'apply-dialog', 'message-dialog', 'confirm-dialog')][string]$Page = 'performance',
    [int]$Width = 1120,
    [int]$Height = 760,
    # Draw it as an administrator would see it (no read-only banner); nothing can run anyway
    [switch]$AsAdmin,
    [ValidateSet('light', 'dark')][string]$Theme = 'light',
    # Draw the page as it looks while a job runs (navigation and buttons disabled)
    [switch]$Busy,
    # Draw the new-version notice for this version (higher than the running one), e.g. 0.2.0
    [string]$NewerVersion,
    # The analysis page: run a (read-only) analysis with these profiles first; none = the page as it opens
    [string[]]$Profiles = @()
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Load.ps1')
Initialize-PcContext -Root $root -Language $Language
. (Join-Path $root 'src\UI\Window.ps1')

function Wait-PcJob {
    # Pages load in background jobs; finish them here since the timer isn't running
    $deadline = (Get-Date).AddMinutes(3)
    while ($script:PcJob -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; Complete-PcJob }
}

$window = New-PcWindow
$Ui.Timer.Stop()
# The theme saved on this PC must not change the picture
Set-PcTheme $Theme
Wait-PcJob
if ($AsAdmin) {
    $script:PcIsAdmin = $true
    Set-PcStaticTexts
}
if ($Page -eq 'analysis-dialog') {
    # The confirmation before applying recommendations, with every area in it
    $source = New-PcAnalysisDialog ([pscustomobject]@{ Tweaks = 12; Cleanup = 4; CleanupBytes = 1.1GB; Apps = 2; Startup = 1 })
    $Height = 0
} elseif ($Page -eq 'apply-dialog') {
    # The confirmation shown before applying, filled with every tweak of the catalog
    $source = New-PcApplyDialog @($script:PcTweaks | Select-Object -First 4)
    $Height = 0
} elseif ($Page -eq 'message-dialog' -or $Page -eq 'confirm-dialog') {
    $text = if ($Page -eq 'message-dialog') { 'Voice Clarity: ' + (Get-PcText 'drivers.result.installed') } else { Get-PcText 'msg.confirmClean' -FormatArgs '1,2 GB' }
    $source = New-PcMessageDialog $text $(if ($Page -eq 'message-dialog') { 'Information' } else { 'Question' }) -Confirm:($Page -eq 'confirm-dialog')
    $Height = 0
} else {
    $Ui.Nav.SelectedItem = $Ui["Nav$((Get-Culture).TextInfo.ToTitleCase($Page))"]
    Wait-PcJob
    if ($AsAdmin) { Show-PcPage $Page; Wait-PcJob }
    if ($Page -eq 'analysis' -and $Profiles) {
        # powershell -File passes "a,b" as one string
        $wanted = @($Profiles | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() })
        foreach ($p in @($Ui.AnalysisProfiles.ItemsSource)) { $p.IsSelected = $wanted -contains $p.Id }
        Update-PcAnalysisRunButton
        Invoke-PcRunAnalysis
        Wait-PcJob
    }
    if ($Busy) { Set-PcBusy $true (Get-PcText 'status.creatingRestorePoint') }
    if ($NewerVersion) { Show-PcUpdateNotice (Select-PcNewerRelease -Tags "v$NewerVersion") }
    $source = $window
}

# Lay out the window's content offscreen, without ever showing the window
$content = $source.Content
$source.Content = $null
$content.Resources.MergedDictionaries.Add($source.Resources)
$content.Background = $source.Background
if ($Height -eq 0) {
    # Dialogs size to their content
    $content.Measure((New-Object System.Windows.Size($source.Width, [double]::PositiveInfinity)))
    $Width = [int]$source.Width
    $Height = [int][Math]::Ceiling($content.DesiredSize.Height)
}
$size = New-Object System.Windows.Size($Width, $Height)
$content.Measure($size)
$content.Arrange((New-Object System.Windows.Rect($size)))
$content.UpdateLayout()

$bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($Width, $Height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
$bitmap.Render($content)
$encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
$encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
$path = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path (Get-Location) $Out }
$stream = [IO.File]::Create($path)
try { $encoder.Save($stream) } finally { $stream.Dispose() }
Write-Host "Saved $path"

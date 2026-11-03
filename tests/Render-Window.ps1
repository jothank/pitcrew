<#
.SYNOPSIS
    Renders the PitCrew window to a PNG without showing it or running any action. Used to check
    the layout in screenshots for docs and reviews. Must run in an STA process:
    powershell -STA -File tests\Render-Window.ps1 -Out docs\screenshot.png -Language pt-BR -Page privacy
#>
param(
    [Parameter(Mandatory)][string]$Out,
    [string]$Language = 'en',
    [ValidateSet('performance', 'privacy', 'explorer', 'startup', 'maintenance', 'history', 'about', 'apply-dialog')][string]$Page = 'performance',
    [int]$Width = 1120,
    [int]$Height = 740,
    # Draw it as an administrator would see it (no read-only banner); nothing can run anyway
    [switch]$AsAdmin
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
Wait-PcJob
if ($AsAdmin) {
    $script:PcIsAdmin = $true
    Set-PcStaticTexts
}
if ($Page -eq 'apply-dialog') {
    # The confirmation shown before applying, filled with every tweak of the catalog
    $source = New-PcApplyDialog @($script:PcTweaks | Select-Object -First 4)
    $Height = 0
} else {
    $Ui.Nav.SelectedItem = $Ui["Nav$((Get-Culture).TextInfo.ToTitleCase($Page))"]
    Wait-PcJob
    if ($AsAdmin) { Show-PcPage $Page; Wait-PcJob }
    $source = $window
}

# Lay out the window's content offscreen, without ever showing the window
$content = $source.Content
$source.Content = $null
$content.Resources.MergedDictionaries.Add($window.Resources)
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

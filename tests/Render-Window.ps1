<#
.SYNOPSIS
    Renders the PitCrew window to a PNG without showing it or running any action. Used to check
    the layout in screenshots for docs and reviews. Must run in an STA process:
    powershell -STA -File tests\Render-Window.ps1 -Out docs\screenshot.png -Language pt-BR -Page privacy
#>
param(
    [Parameter(Mandatory)][string]$Out,
    [string]$Language = 'en',
    [ValidateSet('performance', 'privacy', 'about')][string]$Page = 'performance',
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

$window = New-PcWindow
$Ui.Timer.Stop()
if ($AsAdmin) {
    $script:PcIsAdmin = $true
    Set-PcStaticTexts
}
$Ui.Nav.SelectedItem = $Ui["Nav$((Get-Culture).TextInfo.ToTitleCase($Page))"]
if ($AsAdmin) { Show-PcPage $Page }

# Lay out the window's content offscreen, without ever showing the window
$content = $window.Content
$window.Content = $null
$content.Resources.MergedDictionaries.Add($window.Resources)
$content.Background = $window.Background
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

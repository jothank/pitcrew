# Dot-source this file to load every PitCrew function into the caller's scope, then call
# Initialize-PcContext. Keeping one list here makes a future single-file build a simple concat.

$script:PcSourceFiles = @(
    'Core\Context.ps1'
    'Core\I18n.ps1'
    'Core\Registry.ps1'
    'Core\Tweaks.ps1'
    'Core\RestorePoint.ps1'
    'Modules\Drivers.ps1'
    'Modules\Cleanup.ps1'
    'Modules\Apps.ps1'
)

foreach ($pcFile in $script:PcSourceFiles) {
    . (Join-Path $PSScriptRoot $pcFile)
}
Remove-Variable pcFile

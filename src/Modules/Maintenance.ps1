# One-off maintenance jobs: system file repair, component store cleanup, disk health and a full
# driver backup. Each returns plain result lines for the window to show.

$script:PcMaintenanceTasks = @(
    [pscustomobject]@{ Id = 'repair'; TextKey = 'maintenance.repair'; Long = $true }
    [pscustomobject]@{ Id = 'component-cleanup'; TextKey = 'maintenance.componentCleanup'; Long = $true }
    [pscustomobject]@{ Id = 'disk-health'; TextKey = 'maintenance.diskHealth'; Long = $false }
    [pscustomobject]@{ Id = 'driver-backup'; TextKey = 'maintenance.driverBackup'; Long = $false }
)

function Get-PcCbsLogTail([int64]$FromLength) {
    # CBS.log lines are English on every Windows language, unlike SFC's own (UTF-16) output
    $log = Join-Path $env:windir 'Logs\CBS\CBS.log'
    if (-not (Test-Path -LiteralPath $log)) { return '' }
    $stream = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
    try {
        if ($stream.Length -ge $FromLength) { [void]$stream.Seek($FromLength, 'Begin') }
        return (New-Object IO.StreamReader($stream)).ReadToEnd()
    } finally { $stream.Dispose() }
}

function Invoke-PcSystemRepair($Sync) {
    $lines = @()
    if ($Sync) { $Sync.Status = Get-PcText 'status.running' -FormatArgs 'DISM /RestoreHealth' }
    $null = & dism.exe /Online /Cleanup-Image /RestoreHealth /NoRestart
    $dismCode = $LASTEXITCODE
    Write-PcLog "DISM RestoreHealth exit $dismCode"

    $log = Join-Path $env:windir 'Logs\CBS\CBS.log'
    $startLength = if (Test-Path -LiteralPath $log) { (Get-Item -LiteralPath $log).Length } else { 0 }
    if ($Sync) { $Sync.Status = Get-PcText 'status.running' -FormatArgs 'SFC /scannow' }
    $null = & sfc.exe /scannow
    $sfcCode = $LASTEXITCODE
    $tail = Get-PcCbsLogTail $startLength
    Write-PcLog "SFC exit $sfcCode"

    if ($dismCode -ne 0 -or $tail -match 'Cannot repair member file') { $lines += Get-PcText 'maintenance.repairFailed' }
    elseif ($tail -match 'Repair(ing|ed) (corrupted )?(member )?file|Repairing \d+ components') { $lines += Get-PcText 'maintenance.repairFixed' }
    else { $lines += Get-PcText 'maintenance.repairOk' }
    return $lines
}

function Invoke-PcComponentCleanup($Sync) {
    if ($Sync) { $Sync.Status = Get-PcText 'status.running' -FormatArgs 'DISM /StartComponentCleanup' }
    # Never /ResetBase: it makes the installed updates impossible to uninstall
    $null = & dism.exe /Online /Cleanup-Image /StartComponentCleanup /NoRestart
    $code = $LASTEXITCODE
    Write-PcLog "DISM StartComponentCleanup exit $code"
    if ($code -eq 0) { return Get-PcText 'maintenance.componentDone' }
    return Get-PcText 'maintenance.componentFailed' -FormatArgs $code
}

function Get-PcDiskHealth {
    foreach ($disk in Get-PhysicalDisk) {
        $health = [string]$disk.HealthStatus
        if (@('Healthy', 'Warning', 'Unhealthy') -notcontains $health) { $health = 'Unknown' }
        $line = Get-PcText 'maintenance.diskLine' -FormatArgs $disk.FriendlyName, $disk.MediaType, (Get-PcText "disk.$health")
        try {
            # Reliability counters need administrator rights
            $c = $disk | Get-StorageReliabilityCounter -ErrorAction Stop
            $line += ' - ' + (Get-PcText 'maintenance.diskDetails' -FormatArgs ([int]$c.Wear), ([int]$c.Temperature), ([int]$c.ReadErrorsTotal))
        } catch { }
        $line
    }
}

function Get-PcDriverBackupFolder {
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) ('PitCrew\drivers-{0:yyyy-MM-dd_HHmm}' -f (Get-Date))
}

function Invoke-PcDriverBackup([string]$Destination) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $null = & pnputil.exe /export-driver * $Destination
    $code = $LASTEXITCODE
    Write-PcLog "Driver backup to $Destination exit $code"
    if ($code -eq 0) { return Get-PcText 'maintenance.driverBackupDone' -FormatArgs $Destination }
    return Get-PcText 'maintenance.driverBackupFailed' -FormatArgs $code
}

function Invoke-PcMaintenance {
    param([Parameter(Mandatory)][string[]]$Ids, $Sync, [string]$DriverBackupFolder)
    foreach ($id in $Ids) {
        switch ($id) {
            'repair'            { Invoke-PcSystemRepair $Sync }
            'component-cleanup' { Invoke-PcComponentCleanup $Sync }
            'disk-health'       { Get-PcDiskHealth }
            'driver-backup'     {
                if (-not $DriverBackupFolder) { $DriverBackupFolder = Get-PcDriverBackupFolder }
                if ($Sync) { $Sync.Status = Get-PcText 'status.running' -FormatArgs (Get-PcText 'maintenance.driverBackup') }
                Invoke-PcDriverBackup $DriverBackupFolder
            }
            default { throw "Unknown maintenance task: $id" }
        }
    }
}

function Get-PcRestorePointList {
    try { return @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue) } catch { return @() }
}

function New-PcRestorePoint {
    # Returns $true only when a point with this exact description shows up in the list afterwards.
    # Windows creates at most one point per 24 h and, inside that window, only warns; the limit is
    # lifted for this call and the original value is kept in a file in case the process dies midway.
    param([Parameter(Mandatory)][string]$Description, [string]$Type = 'MODIFY_SETTINGS')

    if ($Pc.SkipRestorePoint) {
        Write-PcLog "Restore point skipped (test mode): $Description" 'Warn'
        return $true
    }
    $before = 0
    $points = Get-PcRestorePointList
    if ($points.Count -gt 0) { $before = ($points | Measure-Object SequenceNumber -Maximum).Maximum }

    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $savedFile = Join-Path (Get-PcDataPath '') 'restore-frequency-original.txt'
    if (Test-Path -LiteralPath $savedFile) {
        $saved = (Get-Content -LiteralPath $savedFile -Raw).Trim()
    } else {
        $current = (Get-ItemProperty $key -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
        $saved = if ($null -eq $current) { 'none' } else { "$current" }
        Set-Content -LiteralPath $savedFile -Value $saved
    }
    try {
        $null = New-ItemProperty -Path $key -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force
        $null = Checkpoint-Computer -Description $Description -RestorePointType $Type -WarningAction SilentlyContinue
    } catch {
        Write-PcLog "Restore point: $($_.Exception.Message)" 'Warn'
    } finally {
        if ($saved -eq 'none') {
            Remove-ItemProperty -Path $key -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue
        } else {
            $null = New-ItemProperty -Path $key -Name SystemRestorePointCreationFrequency -Value ([int]$saved) -PropertyType DWord -Force
        }
        Remove-Item -LiteralPath $savedFile -ErrorAction SilentlyContinue
    }
    $created = @(Get-PcRestorePointList | Where-Object { $_.Description -eq $Description -and $_.SequenceNumber -gt $before })
    Write-PcLog "Restore point '$Description': $($created.Count -gt 0)"
    return [bool]($created.Count -gt 0)
}

function Enable-PcSystemProtection {
    # Only called after the user agrees: it reserves disk space for restore points
    Enable-ComputerRestore -Drive "$env:SystemDrive\"
    Write-PcLog "System Protection enabled on $env:SystemDrive"
}

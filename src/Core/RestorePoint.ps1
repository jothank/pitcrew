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
    $parsed = 0
    if (Test-Path -LiteralPath $savedFile) {
        $saved = ([string](Get-Content -LiteralPath $savedFile -Raw)).Trim()
        # A corrupt file must not block every later restore point: treat it as "no value"
        if ($saved -ne 'none' -and -not [int]::TryParse($saved, [ref]$parsed)) { $saved = 'none' }
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
        try {
            if ($saved -eq 'none' -or -not [int]::TryParse($saved, [ref]$parsed)) {
                Remove-ItemProperty -Path $key -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue
            } else {
                $null = New-ItemProperty -Path $key -Name SystemRestorePointCreationFrequency -Value $parsed -PropertyType DWord -Force
            }
        } finally {
            Remove-Item -LiteralPath $savedFile -ErrorAction SilentlyContinue
        }
    }
    $created = @(Get-PcRestorePointList | Where-Object { $_.Description -eq $Description -and $_.SequenceNumber -gt $before })
    Write-PcLog "Restore point '$Description': $($created.Count -gt 0)"
    return [bool]($created.Count -gt 0)
}

function Test-PcRestorePolicyBlocked {
    # "Turn off System Restore" (DisableSR) stops restore points; PitCrew never overrides it
    $p = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -ErrorAction SilentlyContinue
    return [bool]($p -and $p.DisableSR -eq 1)
}

function Test-PcRestoreConfigLocked {
    # "Turn off Configuration" (DisableConfig) only hides the settings: restore points still
    # work, but PitCrew must not offer to switch System Protection on
    $p = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -ErrorAction SilentlyContinue
    return [bool]($p -and $p.DisableConfig -eq 1)
}

function Get-PcLastRestorePoint {
    Get-PcRestorePointList | Sort-Object SequenceNumber -Descending | Select-Object -First 1 | ForEach-Object {
        [pscustomobject]@{ Description = $_.Description; Created = [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime) }
    }
}

function Enable-PcSystemProtection {
    # Only called after the user agrees: it reserves disk space for restore points
    Enable-ComputerRestore -Drive "$env:SystemDrive\"
    Write-PcLog "System Protection enabled on $env:SystemDrive"
}

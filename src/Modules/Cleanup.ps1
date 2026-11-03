# Disk cleanup. Nothing here can be undone, so the UI always shows sizes first (Get-) and only
# deletes what the user ticked (Invoke-). Temp files younger than a day are kept: running
# installers and apps often still need them.

$script:PcCleanupTargets = @(
    [pscustomobject]@{ Id = 'user-temp'; TextKey = 'cleanup.userTemp'; NeedsAdmin = $false; PerUser = $true }
    [pscustomobject]@{ Id = 'windows-temp'; TextKey = 'cleanup.windowsTemp'; NeedsAdmin = $true; PerUser = $false }
    [pscustomobject]@{ Id = 'recycle-bin'; TextKey = 'cleanup.recycleBin'; NeedsAdmin = $false; PerUser = $true }
    [pscustomobject]@{ Id = 'wu-cache'; TextKey = 'cleanup.wuCache'; NeedsAdmin = $true; PerUser = $false }
    [pscustomobject]@{ Id = 'delivery-optimization'; TextKey = 'cleanup.doCache'; NeedsAdmin = $true; PerUser = $false }
    [pscustomobject]@{ Id = 'error-reports'; TextKey = 'cleanup.errorReports'; NeedsAdmin = $true; PerUser = $true }
    [pscustomobject]@{ Id = 'minidumps'; TextKey = 'cleanup.minidumps'; NeedsAdmin = $true; PerUser = $false }
)

function Get-PcCleanupFolders([string]$Id) {
    switch ($Id) {
        'user-temp'     { [IO.Path]::GetTempPath() }
        'windows-temp'  { Join-Path $env:windir 'Temp' }
        'wu-cache'      { Join-Path $env:windir 'SoftwareDistribution\Download' }
        'error-reports' {
            Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'
            Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'
            Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive'
            Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue'
        }
        'minidumps'     { Join-Path $env:windir 'Minidump' }
    }
}

function Test-PcRebootPending {
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
}

function Get-PcDeliveryOptimizationCacheBytes {
    try { return [int64](Get-DeliveryOptimizationPerfSnap -ErrorAction Stop).FileSizeInCache } catch { return [int64]0 }
}

function Get-PcFolderTree([string]$Folder) {
    # Walks the folder by hand instead of Get-ChildItem -Recurse, which in Windows PowerShell 5.1
    # follows junctions and symlinks: one link inside Temp could point cleanup at Documents.
    if (-not (Test-Path -LiteralPath $Folder)) { return }
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($Folder)
    while ($pending.Count -gt 0) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction SilentlyContinue)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            $item
        }
    }
}

function Get-PcOldFiles([string]$Folder, [int]$MinAgeHours = 24) {
    $limit = (Get-Date).AddHours(-$MinAgeHours)
    Get-PcFolderTree $Folder | Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $limit }
}

function Remove-PcOldFiles([string]$Folder) {
    $freed = [int64]0
    $failed = 0
    foreach ($file in @(Get-PcOldFiles $Folder)) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $freed += $file.Length
        } catch {
            $failed++    # in use; it goes away on its own later
        }
    }
    # Folders left empty, deepest first; links were never collected, so they stay untouched
    Get-PcFolderTree $Folder | Where-Object PSIsContainer | Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ FreedBytes = $freed; InUse = $failed }
}

function Get-PcRecycleBinSize {
    $shell = New-Object -ComObject Shell.Application
    $bin = $shell.NameSpace(10)
    $total = [int64]0
    $count = 0
    foreach ($item in @($bin.Items())) {
        $total += [int64]$item.ExtendedProperty('Size')
        $count++
    }
    return [pscustomobject]@{ Bytes = $total; Files = $count }
}

function Get-PcCleanupTargets {
    $isAdmin = Test-PcAdmin
    $rebootPending = Test-PcRebootPending
    foreach ($t in $script:PcCleanupTargets) {
        $bytes = [int64]0
        $files = 0
        $available = (-not $t.NeedsAdmin -or $isAdmin)
        $blockedKey = if ($available) { $null } else { 'cleanup.adminOnly' }
        if ($t.Id -eq 'wu-cache' -and $rebootPending) { $available = $false; $blockedKey = 'cleanup.rebootPending' }
        if ($available) {
            if ($t.Id -eq 'recycle-bin') {
                $size = Get-PcRecycleBinSize
                $bytes = $size.Bytes
                $files = $size.Files
            } elseif ($t.Id -eq 'delivery-optimization') {
                $bytes = Get-PcDeliveryOptimizationCacheBytes
            } else {
                $old = @(foreach ($f in @(Get-PcCleanupFolders $t.Id)) { Get-PcOldFiles $f })
                $files = $old.Count
                if ($files -gt 0) { $bytes = [int64]($old | Measure-Object Length -Sum).Sum }
            }
        }
        [pscustomobject]@{
            Id         = $t.Id
            Name       = Get-PcText $t.TextKey
            Bytes      = $bytes
            Files      = $files
            Available  = $available
            BlockedKey = $blockedKey
            PerUser    = $t.PerUser
        }
    }
}

function Invoke-PcWindowsUpdateCacheCleanup {
    # The download folder is locked while these run; they are put back exactly as they were
    $services = @(Get-Service wuauserv, bits -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running')
    try {
        $services | Stop-Service -Force -ErrorAction Stop
        return Remove-PcOldFiles (Get-PcCleanupFolders 'wu-cache')
    } finally {
        foreach ($s in $services) { Start-Service -Name $s.Name -ErrorAction SilentlyContinue }
    }
}

function Invoke-PcCleanup {
    param([Parameter(Mandatory)][string[]]$Ids)
    foreach ($id in $Ids) {
        $target = $script:PcCleanupTargets | Where-Object Id -eq $id
        if (-not $target) { throw "Unknown cleanup target: $id" }
        if ($target.NeedsAdmin -and -not (Test-PcAdmin)) { throw (Get-PcText 'error.needsAdmin') }
        if ($target.PerUser -and (Test-PcUserMismatch)) { throw (Get-PcText 'error.otherUser') }

        $freed = [int64]0
        $failed = 0
        switch ($id) {
            'recycle-bin' {
                $freed = (Get-PcRecycleBinSize).Bytes
                Clear-RecycleBin -Force -ErrorAction SilentlyContinue
            }
            'delivery-optimization' {
                $freed = Get-PcDeliveryOptimizationCacheBytes
                Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
            }
            'wu-cache' {
                if (Test-PcRebootPending) { throw (Get-PcText 'cleanup.rebootPending') }
                $result = Invoke-PcWindowsUpdateCacheCleanup
                $freed = $result.FreedBytes
                $failed = $result.InUse
            }
            default {
                foreach ($folder in @(Get-PcCleanupFolders $id)) {
                    $result = Remove-PcOldFiles $folder
                    $freed += $result.FreedBytes
                    $failed += $result.InUse
                }
            }
        }
        Write-PcLog "Cleanup $id freed $freed bytes ($failed files in use)"
        [pscustomobject]@{ Id = $id; FreedBytes = $freed; InUse = $failed }
    }
}

function Format-PcBytes([int64]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

# Disk cleanup. Nothing here can be undone, so the UI always shows sizes first (Get-) and only
# deletes what the user ticked (Invoke-). Temp files younger than a day are kept: running
# installers and apps often still need them.

$script:PcCleanupTargets = @(
    [pscustomobject]@{ Id = 'user-temp'; TextKey = 'cleanup.userTemp'; NeedsAdmin = $false; PerUser = $true }
    [pscustomobject]@{ Id = 'windows-temp'; TextKey = 'cleanup.windowsTemp'; NeedsAdmin = $true; PerUser = $false }
    [pscustomobject]@{ Id = 'recycle-bin'; TextKey = 'cleanup.recycleBin'; NeedsAdmin = $false; PerUser = $true }
)

function Get-PcCleanupFolder([string]$Id) {
    switch ($Id) {
        'user-temp'    { return [IO.Path]::GetTempPath() }
        'windows-temp' { return Join-Path $env:windir 'Temp' }
    }
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
    foreach ($t in $script:PcCleanupTargets) {
        $bytes = [int64]0
        $files = 0
        if ($t.Id -eq 'recycle-bin') {
            $size = Get-PcRecycleBinSize
            $bytes = $size.Bytes
            $files = $size.Files
        } elseif (-not $t.NeedsAdmin -or $isAdmin) {
            $old = @(Get-PcOldFiles (Get-PcCleanupFolder $t.Id))
            $files = $old.Count
            if ($files -gt 0) { $bytes = [int64]($old | Measure-Object Length -Sum).Sum }
        }
        [pscustomobject]@{
            Id        = $t.Id
            Name      = Get-PcText $t.TextKey
            Bytes     = $bytes
            Files     = $files
            Available = (-not $t.NeedsAdmin -or $isAdmin)
            PerUser   = $t.PerUser
        }
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
        if ($id -eq 'recycle-bin') {
            $freed = (Get-PcRecycleBinSize).Bytes
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        } else {
            $result = Remove-PcOldFiles (Get-PcCleanupFolder $id)
            $freed = $result.FreedBytes
            $failed = $result.InUse
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

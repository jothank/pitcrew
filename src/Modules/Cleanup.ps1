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
    # Known-folder API only: TEMP, windir and friends are environment variables a process of the
    # same user can redirect, and cleanup deletes as administrator
    $windows = [Environment]::GetFolderPath('Windows')
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    switch ($Id) {
        'user-temp'     { Join-Path $localAppData 'Temp' }
        'windows-temp'  { Join-Path $windows 'Temp' }
        'wu-cache'      { Join-Path $windows 'SoftwareDistribution\Download' }
        'error-reports' {
            Join-Path $programData 'Microsoft\Windows\WER\ReportArchive'
            Join-Path $programData 'Microsoft\Windows\WER\ReportQueue'
            Join-Path $localAppData 'Microsoft\Windows\WER\ReportArchive'
            Join-Path $localAppData 'Microsoft\Windows\WER\ReportQueue'
        }
        'minidumps'     { Join-Path $windows 'Minidump' }
    }
}

function Test-PcCleanupRoot([string]$Folder) {
    # A root must be a real folder exactly where it is named: not a junction, and not resolving
    # anywhere else, otherwise the whole cleanup would move with it
    $item = Get-Item -LiteralPath $Folder -Force -ErrorAction SilentlyContinue
    if (-not $item -or -not $item.PSIsContainer) { return $false }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
    $final = [PitCrew.SafeDelete]::FinalPath($Folder)
    return [bool]($final -and $final.TrimEnd('\') -ieq $item.FullName.TrimEnd('\'))
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

if (-not ('PitCrew.SafeDelete' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace PitCrew {
    // Deletes by handle instead of by path. Cleanup runs as administrator in folders standard
    // users can write to (Windows\Temp, WER queues); between listing a file and deleting it, a
    // folder on its path could be swapped for a junction to C:\Windows. Here the object is opened
    // first (the last component never followed if it is a link), its real location is checked
    // against the root, and that exact object is deleted.
    public static class SafeDelete {
        const uint DELETE = 0x00010000, READ_ATTRIBUTES = 0x80, SHARE_ALL = 7, OPEN_EXISTING = 3;
        const uint BACKUP_SEMANTICS = 0x02000000, OPEN_REPARSE_POINT = 0x00200000, ATTR_REPARSE = 0x400;
        // BY_HANDLE_FILE_INFORMATION: FILETIMEs are 4-byte aligned there, hence Pack = 4
        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        struct FileInfo { public uint Attributes; public long Created, Accessed, Written; public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo info);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFileInformationByHandle(SafeFileHandle handle, int infoClass, ref byte deleteFile, uint size);
        [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "SetFileInformationByHandle")]
        static extern bool SetDispositionEx(SafeFileHandle handle, int infoClass, ref uint flags, uint size);

        static string Final(SafeFileHandle h) {
            var sb = new StringBuilder(1024);
            uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
            if (n == 0 || n >= sb.Capacity) return null;
            string p = sb.ToString();
            if (p.StartsWith(@"\\?\UNC\")) return @"\\" + p.Substring(8);
            if (p.StartsWith(@"\\?\")) return p.Substring(4);
            return p;
        }

        // The real, link-resolved path of a folder (used once for each cleanup root)
        public static string FinalPath(string path) {
            using (var h = CreateFileW(path, READ_ATTRIBUTES, SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, BACKUP_SEMANTICS, IntPtr.Zero)) {
                return h.IsInvalid ? null : Final(h);
            }
        }

        // True when deleted. False when it is a link, lies outside the root, is in use or the
        // folder isn't empty.
        public static bool Delete(string path, string rootFinal) {
            if (string.IsNullOrEmpty(rootFinal)) return false;
            using (var h = CreateFileW(path, DELETE | READ_ATTRIBUTES, SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, BACKUP_SEMANTICS | OPEN_REPARSE_POINT, IntPtr.Zero)) {
                if (h.IsInvalid) return false;
                FileInfo info;
                if (!GetFileInformationByHandle(h, out info) || (info.Attributes & ATTR_REPARSE) != 0) return false;
                string real = Final(h);
                string root = rootFinal.TrimEnd('\\') + "\\";
                if (real == null || !real.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return false;
                // FileDispositionInfoEx (Windows 10 1809+): DELETE | IGNORE_READONLY_ATTRIBUTE, so
                // read-only temp files go too; older builds fall back to the plain disposition
                uint flags = 0x1 | 0x10;
                if (SetDispositionEx(h, 21, ref flags, 4)) return true;
                byte yes = 1;
                return SetFileInformationByHandle(h, 4, ref yes, 1);   // FileDispositionInfo
            }
        }
    }
}
'@
}

function Remove-PcOldFiles([string]$Folder, [int]$MinAgeHours = 24) {
    $freed = [int64]0
    $failed = 0
    if (-not (Test-PcCleanupRoot $Folder)) {
        if (Test-Path -LiteralPath $Folder) { Write-PcLog "Cleanup skipped $Folder : not a plain folder where expected" 'Warn' }
        return [pscustomobject]@{ FreedBytes = $freed; InUse = $failed }
    }
    $root = [PitCrew.SafeDelete]::FinalPath($Folder)
    foreach ($file in @(Get-PcOldFiles $Folder $MinAgeHours)) {
        if ([PitCrew.SafeDelete]::Delete($file.FullName, $root)) { $freed += $file.Length }
        else { $failed++ }    # in use (goes away later), or no longer where it was listed
    }
    # Folders left empty, deepest first, only if untouched for the same period; a folder that
    # still has anything in it simply isn't deleted
    $limit = (Get-Date).AddHours(-$MinAgeHours)
    Get-PcFolderTree $Folder | Where-Object { $_.PSIsContainer -and $_.LastWriteTime -lt $limit } |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object { [void][PitCrew.SafeDelete]::Delete($_.FullName, $root) }
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
        foreach ($s in $services) {
            try { Start-Service -Name $s.Name -ErrorAction Stop }
            catch { Write-PcLog "Could not restart $($s.Name) after cleanup: $($_.Exception.Message)" 'Error' }
        }
    }
}

function Invoke-PcCleanup {
    param([Parameter(Mandatory)][string[]]$Ids)
    foreach ($id in $Ids) {
      # One target failing (reboot pending, cache busy) doesn't stop the others
      try {
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
        [pscustomobject]@{ Id = $id; FreedBytes = $freed; InUse = $failed; Error = $null }
      } catch {
        Write-PcLog "Cleanup $id failed: $($_.Exception.Message)" 'Error'
        [pscustomobject]@{ Id = $id; FreedBytes = [int64]0; InUse = 0; Error = $_.Exception.Message }
      }
    }
}

function Format-PcBytes([int64]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

<#
.SYNOPSIS
    Installs or removes PitCrew. Install.bat runs -Install; Settings > Apps runs -Uninstall.

.DESCRIPTION
    -Install copies PitCrew from the folder this script belongs to (an extracted release zip) into
    <Program Files>\PitCrew, adds a PitCrew shortcut to the desktop and the Start menu of every user,
    and lists PitCrew under Settings > Apps so it can be removed there. No exe is involved: the
    shortcuts open PitCrew.bat, which runs the Windows PowerShell that comes with Windows, so Smart
    App Control has nothing unsigned to block.

    -Uninstall removes the program folder, those shortcuts and the Settings entry. The undo journal
    and logs in %ProgramData%\PitCrew stay, and so does every setting PitCrew changed.

    Both need administrator rights. Without them the script asks first, then starts itself again
    through UAC with -Confirmed. Program Files is used because PitCrew runs as administrator: in a
    folder any program can write to, its scripts could be changed to run something else elevated.
    While PitCrew's window is open, or anything holds a file of the program folder, both refuse and
    change nothing.

    Tests pass -InstallDir, -DesktopDir and -StartMenuDir (inside the temp folder) and -UninstallKey
    (under HKCU:\Software\PitCrewTest\) together, so every write goes somewhere else; nothing is then
    elevated, and -Quiet shows no message (errors go to stderr, exit code 1). -WindowMutex, also only
    for tests, names the mutex that stands for an open window.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Quiet,
    # Set by the elevated restart: the question was already answered
    [switch]$Confirmed,
    [ValidatePattern('^$|^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?$')][string]$Language,
    [string]$InstallDir,
    [string]$DesktopDir,
    [string]$StartMenuDir,
    [string]$UninstallKey,
    [string]$WindowMutex
)

$ErrorActionPreference = 'Stop'
if ($Install -eq $Uninstall) { [Console]::Error.WriteLine('Use either -Install or -Uninstall.'); exit 1 }
# Whoever started this (Settings, a console) may have left it in the program folder, and a process
# working there holds the folder: the update or removal could never move it
Set-Location -LiteralPath ([Environment]::SystemDirectory)
[Environment]::CurrentDirectory = [Environment]::SystemDirectory

# A 32-bit PowerShell (a 32-bit program starting the uninstall command) would see Program Files
# (x86) and the 32-bit registry: hand over to the 64-bit one with the same arguments, as PitCrew.ps1 does
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $native = Join-Path ([Environment]::GetFolderPath('Windows')) 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $forward = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($p in $PSBoundParameters.GetEnumerator()) {
        if ($p.Value -is [switch]) { if ($p.Value.IsPresent) { $forward += "-$($p.Key)" } }
        else { $forward += "-$($p.Key)"; $forward += "`"$($p.Value)`"" }
    }
    $child = Start-Process -FilePath $native -ArgumentList $forward -NoNewWindow -PassThru -WorkingDirectory ([Environment]::SystemDirectory)
    $null = $child.Handle   # keeps the exit code readable after the process ends
    $child.WaitForExit()
    exit $child.ExitCode
}

$root = Split-Path $PSScriptRoot -Parent

# Only the version, the text helpers and the admin check. No logging: as administrator, logs go to
# %ProgramData%\PitCrew, which only PitCrew itself sets up (with the permissions it checks for).
. (Join-Path $PSScriptRoot 'Core\Context.ps1')
. (Join-Path $PSScriptRoot 'Core\I18n.ps1')

# Everything copied into the program folder. Tests, build tools and Install.bat stay in the zip.
$script:PcSetupItems = 'PitCrew.ps1', 'PitCrew.bat', 'PitCrew.exe', 'LICENSE', 'README.md', 'README.pt-BR.md',
    'CHANGELOG.md', 'SECURITY.md', 'assets', 'data', 'docs', 'locales', 'src', 'tweaks'
# What the source must hold before anything is replaced: every item but PitCrew.exe (a copy taken
# straight from the repository has none), plus files a partial extraction would miss
$script:PcSetupRequired = @($script:PcSetupItems | Where-Object { $_ -ne 'PitCrew.exe' }) + @(
    'src\Load.ps1', 'src\Setup.ps1', 'src\UI\Window.ps1', 'src\UI\Window.xaml', 'assets\pitcrew.ico',
    'locales\en.json', 'tweaks\privacy.json', 'data\apps.json')
# What a folder must hold to be taken for an installed PitCrew (to replace or remove it)
$script:PcSetupMarker = 'PitCrew.ps1', 'src\Load.ps1'
$script:PcPowerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'

if (-not ('PitCrew.SetupNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
namespace PitCrew {
    public static class SetupNative {
        [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
        class ShellLink { }

        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IPropertyStore {
            void GetCount(out uint count);
            void GetAt(uint index, out PropertyKey key);
            void GetValue(ref PropertyKey key, out PropVariant value);
            void SetValue(ref PropertyKey key, ref PropVariant value);
            void Commit();
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        struct PropertyKey { public Guid FormatId; public uint PropertyId; }

        // Only the string case is used; 24 bytes covers the union on 64-bit
        [StructLayout(LayoutKind.Explicit, Size = 24)]
        struct PropVariant { [FieldOffset(0)] public ushort Type; [FieldOffset(8)] public IntPtr Pointer; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct FindData {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
            public uint SizeHigh, SizeLow, ReparseTag, Reserved1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string ShortName;
        }

        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PropVariant value);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int MessageBoxW(IntPtr owner, string text, string caption, uint type);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr FindFirstFileW(string name, out FindData data);

        [DllImport("kernel32.dll")]
        static extern bool FindClose(IntPtr handle);

        // System.AppUserModel.ID: the ID PitCrew's window gives itself, so the taskbar treats the
        // window and this shortcut (pinned or not) as the same app
        public static void SetAppId(string shortcut, string appId) {
            var link = new ShellLink();
            try {
                var file = (IPersistFile)link;
                file.Load(shortcut, 2);   // STGM_READWRITE
                var key = new PropertyKey { FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), PropertyId = 5 };
                var value = new PropVariant { Type = 31, Pointer = Marshal.StringToCoTaskMemUni(appId) };   // VT_LPWSTR
                try {
                    var store = (IPropertyStore)link;
                    store.SetValue(ref key, ref value);
                    store.Commit();
                } finally {
                    PropVariantClear(ref value);
                }
                file.Save(shortcut, true);
            } finally {
                Marshal.ReleaseComObject(link);
            }
        }

        // True for junctions and symbolic links: reparse points that stand for another path (the
        // "name surrogate" bit of the tag). OneDrive marks its synced files as reparse points too,
        // and those are the files themselves.
        public static bool IsLink(string path) {
            FindData data;
            IntPtr handle = FindFirstFileW(path, out data);
            if (handle == new IntPtr(-1)) throw new Win32Exception();
            FindClose(handle);
            return (data.Attributes & 0x400) != 0 && (data.ReparseTag & 0x20000000) != 0;
        }

        // A plain Windows message box, brought to the front: after a UAC prompt this process may
        // have no window of its own to show it over
        public static int Show(string text, string caption, uint type) {
            return MessageBoxW(IntPtr.Zero, text, caption, type | 0x10000 | 0x40000);   // MB_SETFOREGROUND, MB_TOPMOST
        }
    }
}
'@
}

function Get-PcSetupFullPath([string]$Path) { [IO.Path]::GetFullPath($Path).TrimEnd('\') }

function Test-PcSetupLink($Item) {
    if (-not ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    [PitCrew.SetupNative]::IsLink($Item.FullName)
}

function Test-PcSetupInstallDir([string]$Path) {
    # A real folder (not a link) holding PitCrew's own files, also as real files
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or (Test-PcSetupLink $item)) { return $false }
        foreach ($name in $script:PcSetupMarker) {
            $file = Get-Item -LiteralPath (Join-Path $Path $name) -Force -ErrorAction Stop
            if ($file.PSIsContainer -or (Test-PcSetupLink $file)) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Test-PcSetupWindowOpen {
    # PitCrew's window holds this mutex while it is open (Show-PcWindow). A method call's error
    # comes wrapped, so the cause is checked by hand.
    $mutex = $null
    try {
        if ([Threading.Mutex]::TryOpenExisting($script:PcSetupWindowMutex, [ref]$mutex)) { $mutex.Dispose(); return $true }
        return $false
    } catch {
        # It exists, created by an elevated PitCrew this process may not open
        if ($_.Exception -is [UnauthorizedAccessException] -or $_.Exception.InnerException -is [UnauthorizedAccessException]) { return $true }
        throw
    }
}

function Move-PcSetupFolder([string]$From, [string]$To) {
    # A folder can't be renamed while anything holds a file in it. An antivirus scanning a file just
    # written lets go within moments, so try a few times before giving up.
    for ($attempt = 1; ; $attempt++) {
        try { [IO.Directory]::Move($From, $To); return }
        catch { if ($attempt -ge 5) { throw }; Start-Sleep -Milliseconds 300 }
    }
}

function Remove-PcSetupTree([string]$Folder) {
    # Deletes a folder without ever following a link inside it: Windows PowerShell 5.1's
    # Remove-Item -Recurse can delete what a directory symlink points to. A link is removed as a link.
    $top = Get-Item -LiteralPath $Folder -Force
    if (Test-PcSetupLink $top) { throw "Not removed, it is a link: $Folder" }
    $folders = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($top.FullName)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $folders.Add($current)
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force)) {
            if ($item.PSIsContainer -and (Test-PcSetupLink $item)) { [IO.Directory]::Delete($item.FullName) }
            elseif ($item.PSIsContainer) { $pending.Push($item.FullName) }
            else { Remove-Item -LiteralPath $item.FullName -Force }
        }
    }
    # Deepest first, each one empty by now
    foreach ($f in ($folders | Sort-Object Length -Descending)) { [IO.Directory]::Delete($f) }
}

function Copy-PcSetupItems([string]$From, [string]$To) {
    # Copies the program files and returns their total size. Bytes are copied, not files, so the
    # "downloaded from the internet" mark of the zip doesn't come along. Links are refused.
    New-Item -ItemType Directory -Path $To | Out-Null
    $bytes = [int64]0
    foreach ($name in $script:PcSetupItems) {
        $path = Join-Path $From $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $pending = New-Object System.Collections.Generic.Stack[string]
        $pending.Push($path)
        while ($pending.Count -gt 0) {
            $item = Get-Item -LiteralPath $pending.Pop() -Force
            if (Test-PcSetupLink $item) { throw "Links are not installed: $($item.FullName)" }
            $target = Join-Path $To $item.FullName.Substring($From.Length + 1)
            if ($item.PSIsContainer) {
                New-Item -ItemType Directory -Path $target | Out-Null
                foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force)) { $pending.Push($child.FullName) }
            } else {
                $content = [IO.File]::ReadAllBytes($item.FullName)
                [IO.File]::WriteAllBytes($target, $content)
                $bytes += $content.Length
            }
        }
    }
    $bytes
}

function New-PcSetupShortcut([string]$Path, [string]$Dir) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $link.TargetPath = Join-Path $Dir 'PitCrew.bat'
    # Not the program folder: a process started there would hold it, and an update or removal
    # could not move it (PitCrew.bat finds its files by its own path)
    $link.WorkingDirectory = [Environment]::SystemDirectory
    $link.IconLocation = (Join-Path $Dir 'assets\pitcrew.ico') + ',0'
    # Minimized: the console behind PitCrew.bat only shows in the taskbar, and only for a moment.
    # It stays reachable there if PitCrew stops before its window opens and the error waits.
    $link.WindowStyle = 7
    $link.Description = Get-PcText 'app.tagline'
    $link.Save()
    [PitCrew.SetupNative]::SetAppId($Path, $script:PcAppId)
}

function Get-PcSetupShortcuts {
    foreach ($folder in $DesktopDir, $StartMenuDir) { Join-Path $folder 'PitCrew.lnk' }
}

function Install-PcSetup {
    $source = Get-PcSetupFullPath $root
    $dest = Get-PcSetupFullPath $InstallDir
    $missing = @($script:PcSetupRequired | Where-Object { -not (Test-Path -LiteralPath (Join-Path $source $_)) })
    if ($missing) { throw ((Get-PcText 'setup.notExtracted' @($source)) + "`n`n" + ($missing -join ', ')) }
    if ($source -ieq $dest -or $source.StartsWith("$dest\", [StringComparison]::OrdinalIgnoreCase) -or
        $dest.StartsWith("$source\", [StringComparison]::OrdinalIgnoreCase)) {
        throw (Get-PcText 'setup.alreadyHere' @($dest))
    }
    if ((Test-Path -LiteralPath $dest) -and -not (Test-PcSetupInstallDir $dest)) { throw (Get-PcText 'setup.notPitCrew' @($dest)) }

    # The new copy is made next to the old one, then the two are swapped: a failed copy changes
    # nothing, and a failed swap puts the old copy back
    $stage = "$dest.new"
    $old = "$dest.old"
    try { foreach ($leftover in $stage, $old) { if (Test-Path -LiteralPath $leftover) { Remove-PcSetupTree $leftover } } }
    catch { throw (Get-PcText 'setup.inUse') }
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    try {
        $bytes = Copy-PcSetupItems $source $stage
    } catch {
        if (Test-Path -LiteralPath $stage) { try { Remove-PcSetupTree $stage } catch { } }
        throw
    }
    if (Test-Path -LiteralPath $dest) {
        try { Move-PcSetupFolder $dest $old }
        catch {
            try { Remove-PcSetupTree $stage } catch { }
            throw (Get-PcText 'setup.inUse')
        }
    }
    try {
        Move-PcSetupFolder $stage $dest
    } catch {
        $failure = $_
        if (-not (Test-Path -LiteralPath $dest) -and (Test-Path -LiteralPath $old)) { [IO.Directory]::Move($old, $dest) }
        try { Remove-PcSetupTree $stage } catch { }
        # The old copy is back in place, so nothing changed: something held the new folder
        if (Test-PcSetupInstallDir $dest) { throw (Get-PcText 'setup.inUse') }
        throw $failure
    }
    # A file of the old copy opened in the meantime only keeps this leftover; the next install or
    # removal takes it
    if (Test-Path -LiteralPath $old) { try { Remove-PcSetupTree $old } catch { } }

    foreach ($shortcut in Get-PcSetupShortcuts) { New-PcSetupShortcut $shortcut $dest }

    if (Test-Path -LiteralPath $UninstallKey) { Remove-Item -LiteralPath $UninstallKey -Recurse -Force }
    New-Item -Path $UninstallKey -Force | Out-Null
    $command = '"{0}" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Uninstall' -f $script:PcPowerShell, (Join-Path $dest 'src\Setup.ps1')
    $values = [ordered]@{
        DisplayName          = 'PitCrew'
        DisplayVersion       = $script:PcVersion
        Publisher            = 'Jonathan Costa'
        DisplayIcon          = Join-Path $dest 'assets\pitcrew.ico'
        InstallLocation      = $dest
        InstallDate          = (Get-Date).ToString('yyyyMMdd')
        URLInfoAbout         = $script:PcLinks.Repository
        HelpLink             = $script:PcLinks.Issues
        UninstallString      = $command
        QuietUninstallString = "$command -Quiet"
    }
    foreach ($v in $values.GetEnumerator()) { New-ItemProperty -LiteralPath $UninstallKey -Name $v.Key -Value $v.Value -PropertyType String | Out-Null }
    New-ItemProperty -LiteralPath $UninstallKey -Name 'EstimatedSize' -Value ([int][Math]::Ceiling($bytes / 1KB)) -PropertyType DWord | Out-Null
    foreach ($name in 'NoModify', 'NoRepair') { New-ItemProperty -LiteralPath $UninstallKey -Name $name -Value 1 -PropertyType DWord | Out-Null }
}

function Uninstall-PcSetup {
    $dir = Get-PcSetupFullPath $InstallDir
    $old = "$dir.old"
    if ((Test-Path -LiteralPath $dir) -and -not (Test-PcSetupInstallDir $dir)) { throw (Get-PcText 'setup.notPitCrew' @($dir)) }

    # This script normally runs from the folder it removes; it stepped out of it at the start, and
    # every text it still needs is already in memory
    try { foreach ($leftover in "$dir.new", $old) { if (Test-Path -LiteralPath $leftover) { Remove-PcSetupTree $leftover } } }
    catch { throw (Get-PcText 'setup.inUse') }
    # Moving the folder aside first is the check that nothing holds a file in it. If that fails,
    # nothing has changed yet.
    if (Test-Path -LiteralPath $dir) {
        try { Move-PcSetupFolder $dir $old } catch { throw (Get-PcText 'setup.inUse') }
    }

    # Only shortcuts that open this copy. One that can't be read or deleted stays behind rather than
    # stop the removal halfway, with the Settings entry pointing at files already gone.
    $shell = New-Object -ComObject WScript.Shell
    foreach ($shortcut in Get-PcSetupShortcuts) {
        try {
            if (-not (Test-Path -LiteralPath $shortcut -PathType Leaf)) { continue }
            $target = $shell.CreateShortcut($shortcut).TargetPath
            if ($target -and $target.StartsWith("$dir\", [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $shortcut -Force }
        } catch { }
    }
    # A file opened right after the move would only keep this leftover; the next install or
    # removal takes it
    if (Test-Path -LiteralPath $old) { try { Remove-PcSetupTree $old } catch { } }
    if (Test-Path -LiteralPath $UninstallKey) { Remove-Item -LiteralPath $UninstallKey -Recurse -Force }
}

function Show-PcSetupMessage([string]$Text, [ValidateSet('Info', 'Warning', 'Question')][string]$Kind) {
    # True when the answer is Yes
    $type = switch ($Kind) { 'Info' { 0x40 } 'Warning' { 0x30 } 'Question' { 0x24 } }
    ([PitCrew.SetupNative]::Show($Text, (Get-PcText 'setup.title'), [uint32]$type)) -eq 6
}

# --- Where everything goes --------------------------------------------------------------------------

$redirects = @($InstallDir, $DesktopDir, $StartMenuDir, $UninstallKey)
$testMode = @($redirects | Where-Object { $_ }).Count -gt 0
if ($testMode) {
    # All or nothing, and only where tests write: a test that forgot one, or pointed one elsewhere,
    # would change the real desktop or registry
    $temp = Get-PcSetupFullPath ([IO.Path]::GetTempPath())
    $problem = if (@($redirects | Where-Object { -not $_ }).Count) { 'Tests must pass -InstallDir, -DesktopDir, -StartMenuDir and -UninstallKey together.' }
        elseif (@($redirects | Where-Object { $_ -match '(^|[\\/])\.\.([\\/]|$)' }).Count) { 'Test locations may not contain "..".' }
        elseif (@($InstallDir, $DesktopDir, $StartMenuDir | Where-Object { -not (Get-PcSetupFullPath $_).StartsWith("$temp\", [StringComparison]::OrdinalIgnoreCase) }).Count) { "Test folders must be inside $temp." }
        elseif ($UninstallKey -notlike 'HKCU:\Software\PitCrewTest\*') { 'In tests, -UninstallKey must be under HKCU:\Software\PitCrewTest\.' }
    if ($problem) { [Console]::Error.WriteLine($problem); exit 1 }
    # A name nobody holds, unless the test stands in for an open window (and, with ".Setup" added,
    # for another setup at work)
    $script:PcSetupWindowMutex = if ($WindowMutex) { $WindowMutex } else { 'Local\PitCrewTest.' + [guid]::NewGuid().ToString('N') }
    $script:PcSetupLockName = "$script:PcSetupWindowMutex.Setup"
} else {
    if ($WindowMutex) { [Console]::Error.WriteLine('-WindowMutex is only for tests.'); exit 1 }
    $InstallDir = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PitCrew'
    $DesktopDir = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $StartMenuDir = [Environment]::GetFolderPath('CommonPrograms')
    $UninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PitCrew'
    $script:PcSetupWindowMutex = $script:PcWindowMutexName
    $script:PcSetupLockName = 'Global\PitCrew.Setup'
}

# Language: as asked by the first half, then the one picked in PitCrew's window, then Windows' own
if (-not $Language) { $Language = Get-PcPreference 'Language' }
if ($Language -notmatch '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?$' -or -not (Test-Path -LiteralPath (Join-Path $root "locales\$Language.json"))) { $Language = $null }
Initialize-PcContext -Root $root -Language $Language

# --- Run ----------------------------------------------------------------------------------------------

$installed = $null
if ($Install -and (Test-Path -LiteralPath $UninstallKey)) { $installed = (Get-ItemProperty -LiteralPath $UninstallKey -ErrorAction SilentlyContinue).DisplayVersion }
$question = if ($Uninstall) { Get-PcText 'setup.confirmUninstall' }
    elseif ($installed) { Get-PcText 'setup.confirmUpdate' @($script:PcVersion, (Get-PcSetupFullPath $InstallDir), $installed) }
    else { Get-PcText 'setup.confirmInstall' @($script:PcVersion, (Get-PcSetupFullPath $InstallDir)) }
try {
    # Replacing or removing the files under an open window would leave it running a mix of versions
    if (Test-PcSetupWindowOpen) { throw (Get-PcText 'setup.inUse') }

    if (-not $testMode -and -not (Test-PcAdmin)) {
        if ($Quiet) { throw (Get-PcText 'setup.needsAdmin') }
        if (-not (Show-PcSetupMessage $question 'Question')) { exit 0 }
        $mode = if ($Install) { '-Install' } else { '-Uninstall' }
        $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" {1} -Confirmed -Language {2}' -f $PSCommandPath, $mode, $Pc.Language
        $start = New-Object Diagnostics.ProcessStartInfo($script:PcPowerShell, $arguments)
        $start.UseShellExecute = $true
        $start.Verb = 'runas'
        $start.WindowStyle = 'Hidden'
        try {
            # Process.Start, not Start-Process: in Windows PowerShell 5.1 only this keeps the Win32
            # error that says the UAC prompt was answered No
            $elevated = [Diagnostics.Process]::Start($start)
        } catch {
            $cause = $_.Exception.InnerException
            if ($cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -eq 1223) {
                [void](Show-PcSetupMessage (Get-PcText 'setup.needsAdmin') 'Warning')
                exit 2
            }
            throw
        }
        # The elevated copy shows its own messages. A failure before it can (a mapped drive it
        # doesn't see, a policy that blocks scripts) would vanish with its hidden window, so watch
        # for an early exit. Not -Wait: it would also wait for a PitCrew opened at the end.
        $code = $null
        try { if ($elevated -and $elevated.WaitForExit(15000)) { $code = $elevated.ExitCode } } catch { }
        if ($null -ne $code -and $code -ne 0 -and $code -ne 2) { throw "Windows PowerShell stopped with code $code." }
        exit 0
    }

    if (-not $Quiet -and -not $Confirmed -and -not (Show-PcSetupMessage $question 'Question')) { exit 0 }
    # One setup at a time: a second one would remove the first one's work folders. Held until this
    # process ends; a setup that died leaves it abandoned, which counts as free.
    $lock = New-Object System.Threading.Mutex($false, $script:PcSetupLockName)
    $owned = $false
    try { $owned = $lock.WaitOne(0) }
    catch {
        if ($_.Exception -is [Threading.AbandonedMutexException] -or $_.Exception.InnerException -is [Threading.AbandonedMutexException]) { $owned = $true }
        else { throw }
    }
    if (-not $owned) { throw (Get-PcText 'setup.inUse') }
    if ($Install) {
        Install-PcSetup
        if ($Quiet) { Write-Output "PitCrew $script:PcVersion installed in $(Get-PcSetupFullPath $InstallDir)" }
        elseif (Show-PcSetupMessage (Get-PcText 'setup.installed' @($script:PcVersion)) 'Question') {
            # Through the shortcut, so it opens the way it always will
            Start-Process -FilePath (Join-Path $StartMenuDir 'PitCrew.lnk')
        }
    } else {
        Uninstall-PcSetup
        if ($Quiet) { Write-Output 'PitCrew removed' }
        else { [void](Show-PcSetupMessage (Get-PcText 'setup.uninstalled' @($Pc.DataDir)) 'Info') }
    }
    exit 0
} catch {
    if ($Quiet) {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
    [void](Show-PcSetupMessage (Get-PcText 'setup.failed' @($_.Exception.Message)) 'Warning')
    # 2: the message was already shown, so Install.bat doesn't keep its window open
    exit 2
}

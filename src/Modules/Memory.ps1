# Memory page: how much RAM is in use and which programs use it, with a way to close the ones the
# user picks. PitCrew never "cleans" memory: Windows already uses free RAM as cache and hands it to
# whichever program needs it; emptying it by force makes programs reload from disk, which is
# slower (docs/NOT-INCLUDED.md). Closing is always the polite kind (like clicking X): the program
# can ask to save or refuse. Nothing is ever killed.

# Never offered for closing: Windows itself, the desktop, consoles and security software
$script:PcMemoryProtected = @(
    'System', 'Idle', 'Registry', 'Memory Compression', 'Secure System', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass',
    'svchost', 'dwm', 'explorer', 'fontdrvhost', 'sihost', 'ctfmon', 'taskhostw', 'RuntimeBroker', 'ShellExperienceHost',
    'StartMenuExperienceHost', 'SearchHost', 'SearchApp', 'TextInputHost', 'LockApp', 'ApplicationFrameHost', 'SystemSettings',
    'conhost', 'cmd', 'powershell', 'powershell_ise', 'pwsh', 'WindowsTerminal', 'OpenConsole',
    'MsMpEng', 'NisSrv', 'SecurityHealthService', 'SecurityHealthSystray', 'audiodg', 'spoolsv', 'Taskmgr'
)

if (-not ('PitCrew.WindowInfo' -as [type])) {
    Add-Type -Namespace PitCrew -Name WindowInfo -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder className, int maxCount);
'@
}

function Test-PcClosableWindow($Process) {
    # Only a real app window gets the polite close. A console window would end every program in it
    # without a chance to save (CTRL_CLOSE_EVENT), and untitled windows are usually hidden helpers
    # of tray apps.
    if (-not $Process -or $Process.MainWindowHandle -eq [IntPtr]::Zero -or -not $Process.MainWindowTitle) { return $false }
    $name = New-Object System.Text.StringBuilder 256
    [void][PitCrew.WindowInfo]::GetClassName($Process.MainWindowHandle, $name, $name.Capacity)
    return @('ConsoleWindowClass', 'PseudoConsoleWindow') -notcontains $name.ToString()
}

function Get-PcProcessKey($Process) {
    # PID plus start time: a PID freed by a closed program can be reused by another one
    try { return '{0}|{1}' -f $Process.Id, $Process.StartTime.ToUniversalTime().Ticks } catch { return $null }
}

function Get-PcMemoryStatus {
    $os = Get-CimInstance Win32_OperatingSystem
    $total = [int64]$os.TotalVisibleMemorySize * 1KB
    $available = [int64]$os.FreePhysicalMemory * 1KB
    $pageFiles = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
    [pscustomobject]@{
        TotalBytes        = $total
        AvailableBytes    = $available
        UsedBytes         = $total - $available
        Percent           = $(if ($total -gt 0) { [int][Math]::Round(100.0 * ($total - $available) / $total) } else { 0 })
        PageFileUsedBytes = [int64](@($pageFiles | ForEach-Object { [int64]$_.CurrentUsage }) | Measure-Object -Sum).Sum * 1MB
        PageFileSizeBytes = [int64](@($pageFiles | ForEach-Object { [int64]$_.AllocatedBaseSize }) | Measure-Object -Sum).Sum * 1MB
    }
}

function ConvertTo-PcMemoryGroups {
    # Samples: Name ("chrome#3"), IDProcess, WorkingSetPrivate. One group per program, so twenty
    # browser processes show as one line. Kept apart from the system queries so tests can feed it.
    param(
        [object[]]$Samples,
        [int[]]$WindowIds,
        [hashtable]$Descriptions = @{},
        # PID -> "PID|start ticks", checked again right before closing
        [hashtable]$Keys = @{},
        [int]$Top = 15,
        [int]$SelfId = $PID
    )
    $groups = $Samples | Where-Object { $_.IDProcess -ne 0 -and $_.Name -ne '_Total' -and $_.Name -ne 'Idle' } |
        Group-Object { $_.Name -replace '#\d+$', '' }
    $result = foreach ($g in $groups) {
        $ids = @($g.Group | ForEach-Object { [int]$_.IDProcess })
        $windows = @($ids | Where-Object { $WindowIds -contains $_ })
        $label = $null
        foreach ($id in $ids) { if ($Descriptions[$id]) { $label = $Descriptions[$id]; break } }
        [pscustomobject]@{
            Name        = $g.Name
            DisplayName = $(if ($label) { $label } else { $g.Name })
            Count       = $ids.Count
            Bytes       = [int64](@($g.Group | ForEach-Object { [int64]$_.WorkingSetPrivate }) | Measure-Object -Sum).Sum
            WindowIds   = $windows
            WindowKeys  = @($windows | ForEach-Object { if ($Keys[$_]) { $Keys[$_] } else { [string]$_ } })
            Closable    = ($windows.Count -gt 0) -and ($script:PcMemoryProtected -notcontains $g.Name) -and ($ids -notcontains $SelfId)
        }
    }
    @($result | Sort-Object Bytes -Descending | Select-Object -First $Top)
}

function Get-PcMemoryGroups([int]$Top = 15) {
    # "Working set - private": the number Task Manager shows in its Memory column
    $samples = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Property Name, IDProcess, WorkingSetPrivate -ErrorAction Stop)
    $windowIds = @()
    $descriptions = @{}
    $keys = @{}
    foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
        if (Test-PcClosableWindow $p) {
            $key = Get-PcProcessKey $p
            if ($key) { $windowIds += $p.Id; $keys[$p.Id] = $key }
        }
        # Description is the friendly name ("Google Chrome"); unreadable for some system processes
        try { if ($p.Description) { $descriptions[$p.Id] = $p.Description } } catch { }
    }
    ConvertTo-PcMemoryGroups -Samples $samples -WindowIds $windowIds -Descriptions $descriptions -Keys $keys -Top $Top
}

function Close-PcProcessWindows([string[]]$Keys) {
    # Sends the same "close" a click on X sends; returns how many windows were asked. Each key is
    # "PID|start ticks" from when the page was loaded: a process that is no longer the same one is left alone.
    $asked = 0
    foreach ($key in @($Keys | Select-Object -Unique)) {
        if ($key -notmatch '^(\d+)\|(\d+)$') { continue }
        $p = Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue
        if (-not $p -or (Get-PcProcessKey $p) -ne $key) { continue }
        if ($p.Id -eq $PID -or $script:PcMemoryProtected -contains $p.ProcessName -or -not (Test-PcClosableWindow $p)) { continue }
        try { if ($p.CloseMainWindow()) { $asked++ } } catch { Write-PcLog "Close $($p.ProcessName): $($_.Exception.Message)" 'Warn' }
    }
    $asked
}

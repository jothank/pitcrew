<#
.SYNOPSIS
    Tests for src\Setup.ps1 (Install.bat). Standalone: exit code = failures.

.DESCRIPTION
    Every install here goes to temp folders and a key under HKCU:\Software\PitCrewTest\ (the
    redirects Setup.ps1 requires together), with -Quiet: no UAC prompt, no message box, nothing in
    Program Files, on the real desktop or in the real Settings list. A last case checks that those
    real places are as they were.

    On a GitHub-hosted runner (administrator, no UAC) one more case installs for real with
    Install.bat into Program Files, the public desktop and HKLM, and removes it again with the
    command Settings would run.
#>
$ErrorActionPreference = 'Stop'
# GitHub's runners give TEMP as a short 8.3 path (RUNNER~1), which never matches the long paths
# Windows reports for the same folder; the long form keeps path comparisons in these tests honest
$env:TEMP = $env:TMP = [IO.Path]::GetFullPath($env:TEMP)
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Core\Context.ps1')

$script:Passed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:Passed++
        Write-Host "  ok    $Name" -ForegroundColor Green
    } catch {
        $script:Failures.Add($Name)
        Write-Host "  FAIL  $Name`n        $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Equal($Expected, $Actual, [string]$What = 'value') {
    if ($Expected -is [array] -or $Actual -is [array]) {
        $e = @($Expected) -join '|'; $a = @($Actual) -join '|'
        if ($e -cne $a) { throw "$What : expected [$e], got [$a]" }
        return
    }
    if ($Expected -cne $Actual) { throw "$What : expected [$Expected], got [$Actual]" }
}

function Assert-True($Condition, [string]$What) { if (-not $Condition) { throw "Expected true: $What" } }

# The real places an install touches, to check at the end that the tests left them alone
$programDir = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PitCrew'
$realShortcuts = (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'PitCrew.lnk'),
    (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'PitCrew.lnk')
$realKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PitCrew'
$dataDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'PitCrew'
function Get-RealState {
    # The program folder and shortcuts with their last change; the Settings entry and the data
    # folder only as present or absent (a PitCrew open on this PC may write its journal meanwhile)
    foreach ($path in @($programDir) + $realShortcuts) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($item) { '{0}={1:o}' -f $path, $item.LastWriteTimeUtc } else { "$path=absent" }
    }
    foreach ($path in $realKey, $dataDir) { '{0}={1}' -f $path, (Test-Path -LiteralPath $path) }
}
$realBefore = @(Get-RealState)

$tmp = Join-Path $env:TEMP ('PitCrewSetupTest-' + [guid]::NewGuid().ToString('N'))
$testKey = 'HKCU:\Software\PitCrewTest\' + [guid]::NewGuid().ToString('N')

# Looks like an extracted release zip, with the parts that must not be installed
$source = Join-Path $tmp 'Downloads\PitCrew'
New-Item -ItemType Directory -Force -Path $source | Out-Null
foreach ($name in 'PitCrew.ps1', 'PitCrew.bat', 'Install.bat', 'LICENSE', 'README.md', 'README.pt-BR.md', 'CHANGELOG.md',
    'SECURITY.md', 'assets', 'data', 'docs', 'locales', 'src', 'tweaks', 'tests', 'tools') {
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination $source -Recurse
}
# Stands in for the launcher (never run here)
[IO.File]::WriteAllBytes((Join-Path $source 'PitCrew.exe'), [byte[]](77, 90))
# The mark Windows puts on files from a downloaded zip
Set-Content -LiteralPath (Join-Path $source 'PitCrew.ps1') -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
$setup = Join-Path $source 'src\Setup.ps1'

function New-Target([string]$Name) {
    # "Program Files" with its space, as on a real PC; English, so messages can be checked
    $base = Join-Path $tmp $Name
    $t = @{
        Dir     = Join-Path $base 'Program Files\PitCrew'
        Desktop = Join-Path $base 'Desktop'
        Start   = Join-Path $base 'Start Menu\Programs'
        Key     = "$testKey\$Name\PitCrew"
    }
    $t.Args = @('-Quiet', '-Language', 'en', '-InstallDir', $t.Dir, '-DesktopDir', $t.Desktop, '-StartMenuDir', $t.Start, '-UninstallKey', $t.Key)
    $t
}

function Invoke-Setup([string]$Script, [string[]]$Arguments) {
    # The failures are expected in some cases: read them, don't stop on them
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $text = & powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | Out-String }
    finally { $ErrorActionPreference = $previous }
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text.Trim() }
}

function Invoke-CommandLine([string]$CommandLine) {
    # A command line as Windows stores it (the Settings entry, Install.bat), run through cmd
    $info = New-Object Diagnostics.ProcessStartInfo($env:ComSpec, "/d /s /c `"$CommandLine 2>&1`"")
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $p = [Diagnostics.Process]::Start($info)
    $text = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    [pscustomobject]@{ Code = $p.ExitCode; Text = $text.Trim() }
}

function Get-ShortcutAppId([string]$Path) {
    # Read through the shell, not through Setup.ps1's own code that wrote it
    $folder = (New-Object -ComObject Shell.Application).Namespace((Split-Path $Path -Parent))
    [string]$folder.ParseName((Split-Path $Path -Leaf)).ExtendedProperty('System.AppUserModel.ID')
}

function Get-QuotedNames([string]$File, [string]$Variable) {
    # The names in a "$script:<Variable> = 'a', 'b', ..." list, which may span lines
    $text = [IO.File]::ReadAllText($File)
    $m = [regex]::Match($text, '\$script:' + $Variable + "\s*=\s*((?:'[^']+'(?:\s*,\s*)?)+)")
    if (-not $m.Success) { throw "No `$script:$Variable in $File" }
    @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
}

function Assert-Installed($Target, [string]$What) {
    Assert-True (Test-Path -LiteralPath (Join-Path $Target.Dir 'src\Load.ps1')) "$What : program files"
    foreach ($p in (Join-Path $Target.Desktop 'PitCrew.lnk'), (Join-Path $Target.Start 'PitCrew.lnk')) { Assert-True (Test-Path -LiteralPath $p) "$What : $p" }
    Assert-True (Test-Path -LiteralPath $Target.Key) "$What : Settings entry"
    Assert-True (-not (Test-Path -LiteralPath "$($Target.Dir).new") -and -not (Test-Path -LiteralPath "$($Target.Dir).old")) "$What : no work folders left"
}

function Assert-Removed($Target, [string]$What) {
    Assert-True (-not (Test-Path -LiteralPath $Target.Dir)) "$What : program folder removed"
    foreach ($p in (Join-Path $Target.Desktop 'PitCrew.lnk'), (Join-Path $Target.Start 'PitCrew.lnk')) { Assert-True (-not (Test-Path -LiteralPath $p)) "$What : $p removed" }
    Assert-True (-not (Test-Path -LiteralPath $Target.Key)) "$What : Settings entry removed"
    Assert-True (-not (Test-Path -LiteralPath "$($Target.Dir).old")) "$What : no work folder left"
}

$holder = $null
Write-Host "`nSetup" -ForegroundColor Cyan
try {
    $main = New-Target 'main'

    Test-Case 'install copies the program files and leaves the tests, tools and Install.bat behind' {
        $r = Invoke-Setup $setup ((@('-Install') + $main.Args))
        Assert-Equal 0 $r.Code "exit code ($($r.Text))"
        $expected = @('assets', 'CHANGELOG.md', 'data', 'docs', 'LICENSE', 'locales', 'PitCrew.bat', 'PitCrew.exe', 'PitCrew.ps1',
            'README.md', 'README.pt-BR.md', 'SECURITY.md', 'src', 'tweaks') | Sort-Object
        Assert-Equal $expected @(Get-ChildItem -LiteralPath $main.Dir -Force | ForEach-Object Name | Sort-Object) 'installed items'
        $same = (Get-FileHash -LiteralPath (Join-Path $source 'src\UI\Window.ps1')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $main.Dir 'src\UI\Window.ps1')).Hash
        Assert-True $same 'files are copied unchanged'
        Assert-Installed $main 'after install'
    }

    Test-Case 'installed files lose the "downloaded from the internet" mark' {
        $streams = @(Get-Item -LiteralPath (Join-Path $main.Dir 'PitCrew.ps1') -Stream * | ForEach-Object Stream)
        Assert-Equal ':$DATA' ($streams -join ',') 'streams of the installed PitCrew.ps1'
        Assert-True (@(Get-Item -LiteralPath (Join-Path $source 'PitCrew.ps1') -Stream * | ForEach-Object Stream) -contains 'Zone.Identifier') 'the source still has it'
    }

    Test-Case 'the shortcuts open PitCrew.bat minimized from System32, with the icon and taskbar ID' {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($path in (Join-Path $main.Desktop 'PitCrew.lnk'), (Join-Path $main.Start 'PitCrew.lnk')) {
            $link = $shell.CreateShortcut($path)
            Assert-Equal (Join-Path $main.Dir 'PitCrew.bat') $link.TargetPath 'target'
            Assert-Equal '' $link.Arguments 'arguments'
            Assert-Equal ([Environment]::SystemDirectory) $link.WorkingDirectory 'working folder (never the program folder)'
            Assert-Equal ((Join-Path $main.Dir 'assets\pitcrew.ico') + ',0') $link.IconLocation 'icon'
            Assert-Equal 7 $link.WindowStyle 'minimized'
            Assert-Equal $script:PcAppId (Get-ShortcutAppId $path) 'taskbar ID (same as the window)'
        }
    }

    Test-Case 'the Settings entry names this version and its removal command' {
        $v = Get-ItemProperty -LiteralPath $main.Key
        Assert-Equal 'PitCrew' $v.DisplayName 'name'
        Assert-Equal $script:PcVersion $v.DisplayVersion 'version'
        Assert-Equal 'Jonathan Costa' $v.Publisher 'publisher'
        Assert-Equal $main.Dir $v.InstallLocation 'location'
        Assert-Equal (Join-Path $main.Dir 'assets\pitcrew.ico') $v.DisplayIcon 'icon'
        Assert-True ($v.UninstallString -like "*-File `"$(Join-Path $main.Dir 'src\Setup.ps1')`" -Uninstall") "uninstall command ($($v.UninstallString))"
        Assert-Equal "$($v.UninstallString) -Quiet" $v.QuietUninstallString 'quiet uninstall command'
        Assert-Equal 1 $v.NoModify 'no Modify button'
        Assert-True ($v.EstimatedSize -gt 100) "size in KB ($($v.EstimatedSize))"
    }

    Test-Case 'installing again replaces the old copy, files it no longer has included' {
        Set-Content -LiteralPath (Join-Path $main.Dir 'src\Old.ps1') 'from an older version'
        $r = Invoke-Setup $setup ((@('-Install') + $main.Args))
        Assert-Equal 0 $r.Code "exit code ($($r.Text))"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $main.Dir 'src\Old.ps1'))) 'old file gone'
        Assert-Installed $main 'after the update'
    }

    Test-Case 'the installed copy refuses to install over itself' {
        $r = Invoke-Setup (Join-Path $main.Dir 'src\Setup.ps1') ((@('-Install') + $main.Args))
        Assert-Equal 1 $r.Code 'exit code'
        Assert-True ($r.Text -match 'PitCrew is already in') "reason ($($r.Text))"
        Assert-Installed $main 'untouched'
    }

    Test-Case 'nothing is replaced or removed while a PitCrew window is open' {
        $name = 'Local\PitCrewTest.' + [guid]::NewGuid().ToString('N')
        $window = New-Object System.Threading.Mutex($false, $name)
        try {
            foreach ($mode in '-Install', '-Uninstall') {
                $r = Invoke-Setup $setup ((@($mode, '-WindowMutex', $name) + $main.Args))
                Assert-Equal 1 $r.Code "$mode exit code"
                Assert-True ($r.Text -match 'PitCrew is open') "$mode reason ($($r.Text))"
                Assert-Installed $main "after $mode"
            }
        } finally { $window.Dispose() }
    }

    Test-Case 'a second setup waits its turn: nothing runs while another one is at work' {
        $name = 'Local\PitCrewTest.' + [guid]::NewGuid().ToString('N')
        $other = New-Object System.Threading.Mutex($false, "$name.Setup")
        try {
            Assert-True ($other.WaitOne(0)) 'this test holds the setup lock'
            foreach ($mode in '-Install', '-Uninstall') {
                $r = Invoke-Setup $setup ((@($mode, '-WindowMutex', $name) + $main.Args))
                Assert-Equal 1 $r.Code "$mode exit code"
                Assert-True ($r.Text -match 'another PitCrew setup') "$mode reason ($($r.Text))"
                Assert-Installed $main "after $mode"
            }
            $other.ReleaseMutex()
        } finally { $other.Dispose() }
    }

    Test-Case 'a program holding a file of the program folder stops an update or removal, and nothing changes' {
        # A process whose working folder is inside the program folder holds it, like a PitCrew
        # started from there would
        $script:holder = Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120' `
            -WorkingDirectory (Join-Path $main.Dir 'src') -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 500
        try {
            foreach ($mode in '-Uninstall', '-Install') {
                $r = Invoke-Setup $setup ((@($mode) + $main.Args))
                Assert-Equal 1 $r.Code "$mode exit code"
                Assert-True ($r.Text -match 'in use') "$mode reason ($($r.Text))"
                Assert-Installed $main "after $mode"
                Assert-True (Test-Path -LiteralPath (Join-Path $main.Dir 'src\Setup.ps1')) "$mode : files kept"
            }
        } finally {
            Stop-Process -Id $script:holder.Id -Force -ErrorAction SilentlyContinue
            $script:holder.WaitForExit(10000) | Out-Null
            $script:holder = $null
        }
    }

    Test-Case 'a partly extracted zip installs nothing and leaves the installed copy' {
        $partial = Join-Path $tmp 'Partial\PitCrew'
        New-Item -ItemType Directory -Force -Path (Split-Path $partial -Parent) | Out-Null
        Copy-Item -LiteralPath $source -Destination $partial -Recurse
        Remove-Item -LiteralPath (Join-Path $partial 'tweaks') -Recurse -Force
        $r = Invoke-Setup (Join-Path $partial 'src\Setup.ps1') ((@('-Install') + $main.Args))
        Assert-Equal 1 $r.Code 'exit code'
        Assert-True ($r.Text -match 'missing' -and $r.Text -match 'tweaks') "reason ($($r.Text))"
        Assert-True (Test-Path -LiteralPath (Join-Path $main.Dir 'tweaks\privacy.json')) 'installed copy kept its catalog'
        Assert-Installed $main 'untouched'
    }

    Test-Case 'a link inside the zip folder is refused and nothing is installed' {
        $linked = Join-Path $tmp 'Linked\PitCrew'
        New-Item -ItemType Directory -Force -Path (Split-Path $linked -Parent) | Out-Null
        Copy-Item -LiteralPath $source -Destination $linked -Recurse
        $elsewhere = Join-Path $tmp 'elsewhere'
        New-Item -ItemType Directory -Force -Path $elsewhere | Out-Null
        & cmd.exe /c mklink /J (Join-Path $linked 'docs\more') $elsewhere | Out-Null
        $fresh = New-Target 'fresh'
        $r = Invoke-Setup (Join-Path $linked 'src\Setup.ps1') ((@('-Install') + $fresh.Args))
        Assert-Equal 1 $r.Code 'exit code'
        Assert-True ($r.Text -match 'Links are not installed') "reason ($($r.Text))"
        Assert-True (-not (Test-Path -LiteralPath $fresh.Dir) -and -not (Test-Path -LiteralPath "$($fresh.Dir).new")) 'nothing installed'
        Assert-True (-not (Test-Path -LiteralPath $fresh.Key) -and -not (Test-Path -LiteralPath $fresh.Desktop)) 'no shortcut, no Settings entry'
    }

    Test-Case 'a folder that is not PitCrew is left alone' {
        $other = New-Target 'other'
        New-Item -ItemType Directory -Force -Path $other.Dir | Out-Null
        Set-Content -LiteralPath (Join-Path $other.Dir 'keep.txt') 'someone else''s'
        foreach ($mode in '-Install', '-Uninstall') {
            $r = Invoke-Setup $setup ((@($mode) + $other.Args))
            Assert-Equal 1 $r.Code "$mode exit code"
            Assert-True ($r.Text -match 'is not a PitCrew folder') "$mode reason ($($r.Text))"
            Assert-Equal 'keep.txt' (@(Get-ChildItem -LiteralPath $other.Dir -Force | ForEach-Object Name) -join ',') "$mode : folder contents"
        }
        Assert-True (-not (Test-Path -LiteralPath $other.Desktop) -and -not (Test-Path -LiteralPath $other.Key)) 'no shortcut, no Settings entry'
    }

    Test-Case 'tests must redirect every location, inside the temp folder, or nothing runs' {
        $half = New-Target 'half'
        $r = Invoke-Setup $setup @('-Install', '-Quiet', '-InstallDir', $half.Dir)
        Assert-True ($r.Code -eq 1 -and $r.Text -match 'together') "one redirect only ($($r.Text))"
        $bad = $half.Args.Clone(); $bad[-1] = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PitCrewTest'
        $r = Invoke-Setup $setup ((@('-Install') + $bad))
        Assert-True ($r.Code -eq 1 -and $r.Text -match 'PitCrewTest') "a real registry key ($($r.Text))"
        $bad = $half.Args.Clone(); $bad[-1] = 'HKCU:\Software\PitCrewTest\..\Microsoft\Windows\CurrentVersion\Uninstall\PitCrew'
        $r = Invoke-Setup $setup ((@('-Install') + $bad))
        Assert-True ($r.Code -eq 1 -and $r.Text -match '\.\.') "a key that climbs out with .. ($($r.Text))"
        $outside = Join-Path ([IO.Path]::GetPathRoot($env:TEMP)) ('PitCrewTestOutside-' + [guid]::NewGuid().ToString('N'))
        $bad = $half.Args.Clone(); $bad[4] = Join-Path $outside 'PitCrew'
        $r = Invoke-Setup $setup ((@('-Install') + $bad))
        Assert-True ($r.Code -eq 1 -and $r.Text -match 'inside') "a folder outside the temp folder ($($r.Text))"
        Assert-True (-not (Test-Path -LiteralPath $outside)) 'nothing created outside'
        Assert-True (-not (Test-Path -LiteralPath $half.Dir)) 'nothing installed'
        $r = Invoke-Setup $setup @('-Install', '-Quiet', '-WindowMutex', 'Local\x')
        Assert-True ($r.Code -eq 1 -and $r.Text -match 'only for tests') "-WindowMutex without redirects ($($r.Text))"
        $r = Invoke-Setup $setup @('-Quiet')
        Assert-Equal 1 $r.Code 'neither -Install nor -Uninstall'
    }

    Test-Case 'removal never follows a link inside the program folder, and keeps other shortcuts' {
        $outside = Join-Path $tmp 'outside'
        New-Item -ItemType Directory -Force -Path $outside | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'victim.txt') 'keep'
        & cmd.exe /c mklink /J (Join-Path $main.Dir 'linked') $outside | Out-Null
        Assert-True (Test-Path -LiteralPath (Join-Path $main.Dir 'linked\victim.txt')) 'the junction works'
        # A directory symlink is the case Windows PowerShell 5.1's Remove-Item -Recurse follows. Making
        # one needs administrator (or Developer Mode), so it is only checked where that is available,
        # such as GitHub's runners.
        $outsideSymlink = Join-Path $tmp 'outside-symlink'
        New-Item -ItemType Directory -Force -Path $outsideSymlink | Out-Null
        Set-Content -LiteralPath (Join-Path $outsideSymlink 'victim.txt') 'keep'
        & cmd.exe /c "mklink /D `"$(Join-Path $main.Dir 'symlinked')`" `"$outsideSymlink`" >nul 2>&1"
        $symlink = Test-Path -LiteralPath (Join-Path $main.Dir 'symlinked\victim.txt')
        if (-not $symlink) { Write-Host '        (no directory symlink here: needs administrator or Developer Mode)' -ForegroundColor DarkGray }
        $foreign = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $main.Desktop 'Other.lnk'))
        $foreign.TargetPath = Join-Path ([Environment]::SystemDirectory) 'notepad.exe'
        $foreign.Save()
        $r = Invoke-Setup (Join-Path $main.Dir 'src\Setup.ps1') ((@('-Uninstall') + $main.Args))
        Assert-Equal 0 $r.Code "exit code ($($r.Text))"
        Assert-True (Test-Path -LiteralPath (Join-Path $outside 'victim.txt')) 'file behind the junction kept'
        if ($symlink) { Assert-True (Test-Path -LiteralPath (Join-Path $outsideSymlink 'victim.txt')) 'file behind the directory symlink kept' }
        Assert-Removed $main 'removed by its own copy of Setup.ps1'
        Assert-True (Test-Path -LiteralPath (Join-Path $main.Desktop 'Other.lnk')) 'another shortcut kept'
    }

    Test-Case 'the command saved for Settings removes PitCrew' {
        $r = Invoke-Setup $setup ((@('-Install') + $main.Args))
        Assert-Equal 0 $r.Code "install exit code ($($r.Text))"
        $stored = (Get-ItemProperty -LiteralPath $main.Key).QuietUninstallString
        # Run as saved, plus the test redirects
        $redirects = '-Language en -InstallDir "{0}" -DesktopDir "{1}" -StartMenuDir "{2}" -UninstallKey "{3}"' -f $main.Dir, $main.Desktop, $main.Start, $main.Key
        $r = Invoke-CommandLine "$stored $redirects"
        Assert-Equal 0 $r.Code "exit code ($($r.Text))"
        Assert-Removed $main 'removed by the saved command'
    }

    Test-Case 'a 32-bit PowerShell hands over to the 64-bit one (Program Files, not Program Files (x86))' {
        $wow = Join-Path ([Environment]::GetFolderPath('Windows')) 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $wow)) { Write-Host '        (no 32-bit PowerShell on this Windows)' -ForegroundColor DarkGray; return }
        $t32 = New-Target 'from32'
        foreach ($mode in '-Install', '-Uninstall') {
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { $text = & $wow -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File $setup $mode @($t32.Args) 2>&1 | Out-String }
            finally { $ErrorActionPreference = $previous }
            Assert-Equal 0 $LASTEXITCODE "$mode exit code ($($text.Trim()))"
            if ($mode -eq '-Install') { Assert-Installed $t32 'installed through the 32-bit PowerShell' } else { Assert-Removed $t32 'removed through the 32-bit PowerShell' }
        }
    }

    Test-Case 'a program folder that is itself a link is not removed' {
        $linkTarget = New-Target 'link'
        $real = Join-Path $tmp 'real-folder'
        New-Item -ItemType Directory -Force -Path (Join-Path $real 'src') | Out-Null
        Set-Content -LiteralPath (Join-Path $real 'PitCrew.ps1') 'x'
        Set-Content -LiteralPath (Join-Path $real 'src\Load.ps1') 'x'
        New-Item -ItemType Directory -Force -Path (Split-Path $linkTarget.Dir -Parent) | Out-Null
        & cmd.exe /c mklink /J $linkTarget.Dir $real | Out-Null
        $r = Invoke-Setup $setup ((@('-Uninstall') + $linkTarget.Args))
        Assert-Equal 1 $r.Code 'exit code'
        Assert-True ($r.Text -match 'is not a PitCrew folder') "reason ($($r.Text))"
        Assert-True (Test-Path -LiteralPath (Join-Path $real 'src\Load.ps1')) 'files behind the link kept'
        & cmd.exe /c rmdir $linkTarget.Dir | Out-Null
    }

    Test-Case 'the installer copies what the release zip ships, minus tests, tools and Install.bat' {
        $installed = Get-QuotedNames (Join-Path $root 'src\Setup.ps1') 'PcSetupItems'
        $shipped = Get-QuotedNames (Join-Path $root 'tools\Build-Release.ps1') 'ReleaseTop'
        Assert-Equal (@($shipped | Where-Object { 'tests', 'tools', 'Install.bat' -notcontains $_ } | Sort-Object)) (@($installed | Sort-Object)) 'item lists'
    }

    Test-Case 'nothing outside the test folders changed (Program Files, public shortcuts, HKLM, ProgramData)' {
        Assert-Equal $realBefore @(Get-RealState) 'real locations'
        Assert-True (-not (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PitCrewTest')) 'no real per-user Settings entry'
    }

    $hosted = $env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted'
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($hosted -and $admin) {
        Test-Case 'a real install with Install.bat and removal with the saved command (GitHub-hosted runner only)' {
            $hadData = Test-Path -LiteralPath $dataDir
            $r = Invoke-CommandLine "`"$(Join-Path $source 'Install.bat')`" -Quiet -Language en"
            Assert-Equal 0 $r.Code "install exit code ($($r.Text))"
            Assert-True (Test-Path -LiteralPath (Join-Path $programDir 'src\Load.ps1')) "installed in $programDir"
            # Users, Authenticated Users, Everyone and INTERACTIVE get no right to change anything there
            $open = foreach ($rule in (Get-Acl -LiteralPath $programDir).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
                if ($rule.AccessControlType -eq 'Allow' -and 'S-1-5-32-545', 'S-1-5-11', 'S-1-1-0', 'S-1-5-4' -contains $rule.IdentityReference.Value -and
                    (([int64][int]$rule.FileSystemRights) -band $script:PcWriteRightsMask)) { "$($rule.IdentityReference.Value): $($rule.FileSystemRights)" }
            }
            Assert-Equal '' (@($open) -join '; ') 'write rights for non-administrators on the program folder'
            foreach ($s in $realShortcuts) { Assert-Equal $script:PcAppId (Get-ShortcutAppId $s) "taskbar ID of $s" }
            $v = Get-ItemProperty -LiteralPath $realKey
            Assert-Equal $script:PcVersion $v.DisplayVersion 'Settings entry'
            $r = Invoke-CommandLine "$($v.QuietUninstallString) -Language en"
            Assert-Equal 0 $r.Code "removal exit code ($($r.Text))"
            Assert-True (-not (Test-Path -LiteralPath $programDir)) 'program folder removed'
            foreach ($s in $realShortcuts) { Assert-True (-not (Test-Path -LiteralPath $s)) "$s removed" }
            Assert-True (-not (Test-Path -LiteralPath $realKey)) 'Settings entry removed'
            if (-not $hadData) { Assert-True (-not (Test-Path -LiteralPath $dataDir)) 'setup did not create %ProgramData%\PitCrew' }
        }
    } else {
        Write-Host '  skip  a real install and removal (only on a GitHub-hosted runner)' -ForegroundColor Yellow
    }
} finally {
    if ($script:holder) { Stop-Process -Id $script:holder.Id -Force -ErrorAction SilentlyContinue; $script:holder.WaitForExit(10000) | Out-Null }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testKey -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem 'HKCU:\Software\PitCrewTest' -ErrorAction SilentlyContinue)) {
        Remove-Item 'HKCU:\Software\PitCrewTest' -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
$color = if ($script:Failures.Count) { 'Red' } else { 'Green' }
Write-Host "$($script:Passed) passed, $($script:Failures.Count) failed" -ForegroundColor $color
exit $script:Failures.Count

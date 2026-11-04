<#
.SYNOPSIS
    Tests for PitCrew.exe (tools\launcher\PitCrew.cs). Standalone: exit code = failures.

.DESCRIPTION
    Builds the launcher into a temp folder and runs it with --dry-run: it goes through the same
    steps as a real start but prints each program it would start instead of starting it, so there
    is no UAC prompt and nothing else runs. --simulate-refusal answers No to the UAC prompt and
    --simulate-not-admin covers the prompt even when the tests run as administrator.

    Smart App Control (or another App Control policy) may refuse to run a freshly compiled,
    unsigned exe. Those tests are then reported as skipped, not failed: run them in Windows Sandbox.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Core\Context.ps1')

$script:Passed = 0
$script:Skipped = 0
$script:Blocked = $null
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
    if ($Expected -cne $Actual) { throw "$What : expected [$Expected], got [$Actual]" }
}

function Assert-True($Condition, [string]$What) { if (-not $Condition) { throw "Expected true: $What" } }

function Test-ExeCase([string]$Name, [scriptblock]$Body) {
    # Cases that run the built exe
    if ($script:Blocked) {
        $script:Skipped++
        Write-Host "  skip  $Name ($script:Blocked)" -ForegroundColor Yellow
        return
    }
    Test-Case $Name $Body
}

$tmp = Join-Path $env:TEMP ('PitCrewLauncherTest-' + [guid]::NewGuid().ToString('N'))
# Looks like an extracted zip: the script and src\Load.ps1 next to the exe (empty; nothing runs them)
$full = Join-Path $tmp 'full'
# The exe on its own, as when someone double-clicks it inside the zip
$alone = Join-Path $tmp 'alone'
New-Item -ItemType Directory -Force -Path (Join-Path $full 'src'), $alone | Out-Null
New-Item -ItemType File -Path (Join-Path $full 'PitCrew.ps1'), (Join-Path $full 'src\Load.ps1') | Out-Null
$exe = Join-Path $full 'PitCrew.exe'
$system = [Environment]::SystemDirectory
$powershell = Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe'
$runArgs = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -NoElevate' -f (Join-Path $full 'PitCrew.ps1')
function Invoke-PcLauncher([string]$Path, [string[]]$Arguments) {
    # Process.Start (not Start-Process) so a policy block comes back as a Win32 error code, the same
    # in every Windows language
    $info = New-Object Diagnostics.ProcessStartInfo($Path, ((@('--dry-run') + $Arguments) -join ' '))
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $p = [Diagnostics.Process]::Start($info)
    $text = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $lines = @($text -split "`r?`n" | Where-Object { $_ })
    $values = @{}
    $starts = @()
    foreach ($l in $lines) {
        $i = $l.IndexOf('=')
        if ($i -le 0) { continue }
        $key = $l.Substring(0, $i)
        $value = $l.Substring($i + 1)
        if ($key -eq 'start') {
            # "<file>" <arguments> | verb=<verb> shell=<bool> nowindow=<bool> dir=<folder>
            if ($value -notmatch '^"(?<file>[^"]+)" (?<args>.*) \| verb=(?<verb>\S*) shell=(?<shell>\S+) nowindow=(?<nowindow>\S+) dir=(?<dir>.*)$') { throw "unreadable start line: $value" }
            $starts += [pscustomobject]@{ File = $Matches.file; Args = $Matches.args; Verb = $Matches.verb; Shell = $Matches.shell; NoWindow = $Matches.nowindow; Dir = $Matches.dir }
        } else { $values[$key] = $value }
    }
    [pscustomobject]@{ ExitCode = $p.ExitCode; Values = $values; Starts = $starts; Text = $lines -join "`n" }
}

function Assert-PowerShellStart($Start, [string]$ExpectedArgs) {
    Assert-True ($Start.File -ieq $powershell) "the 64-bit Windows PowerShell by full path (got $($Start.File))"
    Assert-Equal $ExpectedArgs $Start.Args 'arguments'
    Assert-Equal 'False' $Start.Shell 'started directly, not through the shell'
    Assert-Equal 'True' $Start.NoWindow 'no console window'
    Assert-True ($Start.Dir -ieq $system) "working folder is System32 (got $($Start.Dir))"
}

try {
    Test-Case 'builds with the version, name and author from the project' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\Build-Release.ps1') -ExeOnly -OutDir $full 2>&1
        Assert-Equal 0 $LASTEXITCODE ("build failed: $($out -join ' ')")
        $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
        Assert-Equal $script:PcVersion $info.ProductVersion 'product version'
        Assert-Equal (($script:PcVersion -replace '-.*$', '') + '.0') $info.FileVersion 'file version'
        Assert-Equal 'PitCrew' $info.FileDescription 'description (shown in the UAC prompt)'
        Assert-Equal 'Jonathan Costa' $info.CompanyName 'company'
        Assert-True ($info.LegalCopyright -like '*Jonathan Costa*') 'copyright'
    }

    if (Test-Path -LiteralPath $exe) {
        try { [void](Invoke-PcLauncher $exe @('--elevated')) }
        catch {
            $code = $null
            for ($e = $_.Exception; $e; $e = $e.InnerException) { if ($e -is [ComponentModel.Win32Exception]) { $code = $e.NativeErrorCode; break } }
            # 4551: an App Control policy (Smart App Control) blocked it; 1260: blocked by Group Policy
            if ($code -eq 4551 -or $code -eq 1260) { $script:Blocked = "Windows blocked the new unsigned exe here (error $code)" }
            else { throw }
        }
    }

    Test-ExeCase 'the copy started through UAC runs PitCrew.ps1 with the 64-bit PowerShell, and only that' {
        $r = Invoke-PcLauncher $exe @('--elevated')
        Assert-Equal 0 $r.ExitCode "exit code ($($r.Text))"
        Assert-Equal $full $r.Values['folder'] 'folder'
        Assert-Equal ([Environment]::Is64BitOperatingSystem.ToString()) $r.Values['is64'] '64-bit process'
        Assert-Equal 1 $r.Starts.Count "one program started ($($r.Text))"
        Assert-PowerShellStart $r.Starts[0] $runArgs
    }

    Test-ExeCase 'without administrator it asks through UAC once and starts nothing else itself' {
        $r = Invoke-PcLauncher $exe @('--simulate-not-admin')
        Assert-Equal 1 $r.Starts.Count "one program started ($($r.Text))"
        $s = $r.Starts[0]
        Assert-True ($s.File -ieq $exe) "relaunches itself (got $($s.File))"
        Assert-Equal '--elevated' $s.Args 'marked so the elevated copy never asks again'
        Assert-Equal 'runas' $s.Verb 'through the UAC prompt'
        Assert-Equal 'True' $s.Shell 'through the shell, which shows the prompt'
    }

    Test-ExeCase 'with administrator rights it starts PowerShell directly, without asking' {
        if (-not (Test-PcAdmin)) { Write-Host '        (not running as administrator: covered by the copy started through UAC)'; return }
        $r = Invoke-PcLauncher $exe @()
        Assert-Equal 1 $r.Starts.Count "one program started ($($r.Text))"
        Assert-PowerShellStart $r.Starts[0] $runArgs
    }

    Test-ExeCase 'a No to the UAC prompt opens PitCrew read-only, without an error message' {
        $r = Invoke-PcLauncher $exe @('--simulate-not-admin', '--simulate-refusal')
        Assert-Equal 0 $r.ExitCode "exit code ($($r.Text))"
        Assert-Equal 2 $r.Starts.Count "the prompt, then PowerShell ($($r.Text))"
        Assert-Equal 'runas' $r.Starts[0].Verb 'first the prompt'
        Assert-PowerShellStart $r.Starts[1] $runArgs
        Assert-True (-not $r.Values.ContainsKey('warning')) 'a refusal is not reported as a failure'
    }

    Test-ExeCase 'passes on a language tag and nothing else' {
        $r = Invoke-PcLauncher $exe @('--elevated', '-Language', 'pt-BR')
        Assert-Equal ($runArgs + ' -Language pt-BR') $r.Starts[0].Args 'language passed on'
        foreach ($bad in '"en -Apply privacy.advertising-id"', ('"en' + "`n" + '"'), 'pt;calc') {
            $r = Invoke-PcLauncher $exe @('--elevated', '-Language', $bad)
            Assert-Equal $runArgs $r.Starts[0].Args "dropped: $bad"
        }
    }

    Test-ExeCase 'run alone (inside a zip) it asks to extract first, in the chosen language, and starts nothing' {
        Copy-Item -LiteralPath $exe -Destination $alone
        $r = Invoke-PcLauncher (Join-Path $alone 'PitCrew.exe') @('-Language', 'pt-BR')
        Assert-Equal 1 $r.ExitCode 'exit code'
        Assert-True ($r.Values['error'] -like '*Extrair tudo*') "message: $($r.Values['error'])"
        Assert-Equal 0 $r.Starts.Count 'nothing started'
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("`n{0} passed, {1} skipped, {2} failed" -f $script:Passed, $script:Skipped, $script:Failures.Count) -ForegroundColor $(if ($script:Failures.Count) { 'Red' } elseif ($script:Skipped) { 'Yellow' } else { 'Green' })
exit $script:Failures.Count

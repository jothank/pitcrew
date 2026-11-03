<#
.SYNOPSIS
    Tests for src\Modules\Startup.ps1. Standalone: exit code = failures.

.DESCRIPTION
    Registry writes go under HKCU:\Software\PitCrewTest\<random> (deleted at the end) and the Startup
    folders are temp folders. Nothing touches the real startup state.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Load.ps1')
. (Join-Path $root 'src\Modules\Startup.ps1')

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

$testKey = 'HKCU:\Software\PitCrewTest\' + [guid]::NewGuid().ToString('N')
$tmp = Join-Path $env:TEMP ('PitCrewStartupTest-' + [guid]::NewGuid().ToString('N'))
$userDir = Join-Path $tmp 'user'
$commonDir = Join-Path $tmp 'common'
$exeDir = Join-Path $tmp 'Program Files\Fake App'
foreach ($d in $userDir, $commonDir, $exeDir) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
Initialize-PcContext -Root $root -DataDir (Join-Path $tmp 'data') -Language 'en' -RegistryRedirect $testKey
$script:PcStartupFolders = @{ User = $userDir; Common = $commonDir }

$runHkcu = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runHklm = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$runWow = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
$approved = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

function Get-ApprovedBytes([string]$Hive, [string]$Kind, [string]$Name) {
    $v = Get-PcRegistryValue "${Hive}:\$approved\$Kind" $Name
    if (-not $v.Exists) { return $null }
    Assert-Equal 'Binary' $v.Kind 'approval kind'
    return , [Convert]::FromBase64String($v.Data)
}
function Set-ApprovedBytes([string]$Hive, [string]$Kind, [string]$Name, [byte[]]$Bytes) {
    [void](Set-PcRegistryValue "${Hive}:\$approved\$Kind" $Name 'Binary' $Bytes)
}
function Find-Item([string]$Id) { Get-PcStartupItems | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }

try {
    # A fake exe on a path with spaces; the quoted entry exercises quote parsing, the unquoted one space probing
    $fakeExe = Join-Path $exeDir 'app.exe'
    [IO.File]::WriteAllText($fakeExe, 'not a real program')
    [void](Set-PcRegistryValue $runHkcu 'Quoted' 'String' ('"{0}" --min' -f $fakeExe))
    [void](Set-PcRegistryValue $runHkcu 'Unquoted' 'String' ('{0} /silent' -f $fakeExe))
    [void](Set-PcRegistryValue $runHkcu 'Gone' 'String' '"C:\PitCrewTest\nope\missing.exe"')
    [void](Set-PcRegistryValue $runHklm 'MachineApp' 'String' ('"{0}"' -f $fakeExe))
    [void](Set-PcRegistryValue $runWow 'WowApp' 'String' ('"{0}"' -f $fakeExe))
    [IO.File]::WriteAllText((Join-Path $userDir 'Plain.cmd'), '@echo off')
    [IO.File]::WriteAllText((Join-Path $userDir 'desktop.ini'), '[.ShellClassInfo]')
    [IO.File]::WriteAllText((Join-Path $commonDir 'Shared.bat'), '@echo off')

    Test-Case 'lists Run entries and folder items from every source' {
        $items = @(Get-PcStartupItems)
        Assert-Equal 7 $items.Count 'item count'
        Assert-Equal 'HKCU Run' (Find-Item 'HKCU|Run|Quoted').Source 'hkcu source'
        Assert-Equal 'HKLM Run' (Find-Item 'HKLM|Run|MachineApp').Source 'hklm source'
        Assert-Equal 'HKLM Run32' (Find-Item 'HKLM|Run32|WowApp').Source 'run32 source'
        Assert-Equal 'User folder' (Find-Item 'HKCU|StartupFolder|Plain.cmd').Source 'user folder source'
        Assert-Equal 'Common folder' (Find-Item 'HKLM|StartupFolder|Shared.bat').Source 'common folder source'
        Assert-Equal 'user' (Find-Item 'HKCU|Run|Quoted').Scope 'user scope'
        Assert-Equal 'machine' (Find-Item 'HKLM|StartupFolder|Shared.bat').Scope 'machine scope'
        Assert-Equal 'Plain' (Find-Item 'HKCU|StartupFolder|Plain.cmd').Name 'folder item name'
    }

    Test-Case 'desktop.ini is not listed' {
        Assert-True (-not (Get-PcStartupItems | Where-Object { $_.Name -like 'desktop*' })) 'desktop.ini hidden'
    }

    Test-Case 'parses quoted and unquoted commands' {
        Assert-True (Find-Item 'HKCU|Run|Quoted').TargetExists 'quoted target exists'
        Assert-True (Find-Item 'HKCU|Run|Unquoted').TargetExists 'unquoted target with spaces exists'
        Assert-True (-not (Find-Item 'HKCU|Run|Gone').TargetExists) 'missing target flagged'
        Assert-Equal $fakeExe (Get-PcCommandExePath ('"{0}" --min' -f $fakeExe)) 'quoted exe'
        Assert-Equal $fakeExe (Get-PcCommandExePath ('{0} /silent' -f $fakeExe)) 'unquoted exe'
        Assert-Equal $fakeExe (Get-PcCommandExePath $fakeExe) 'bare exe'
    }

    Test-Case 'publisher is empty for a file without version info' {
        Assert-Equal '' (Find-Item 'HKCU|Run|Quoted').Publisher 'publisher'
    }

    Test-Case 'publisher comes from the version info of a real exe' {
        $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
        [void](Set-PcRegistryValue $runHkcu 'RealExe' 'String' ('"{0}" /c' -f $cmd))
        Assert-Equal 'Microsoft Corporation' (Find-Item 'HKCU|Run|RealExe').Publisher 'publisher'
        Remove-PcRegistryValue $runHkcu 'RealExe'
    }

    Test-Case 'a missing approval value means enabled' {
        foreach ($i in Get-PcStartupItems) { Assert-True $i.Enabled "$($i.Id) enabled" }
    }

    Test-Case 'disable writes byte 3, a FILETIME and zeros in bytes 1-3' {
        Set-PcStartupItemEnabled -Id 'HKCU|Run|Quoted' -Enabled $false
        $b = Get-ApprovedBytes 'HKCU' 'Run' 'Quoted'
        Assert-Equal 12 $b.Length 'length'
        Assert-Equal 3 $b[0] 'state byte'
        Assert-Equal '0,0,0' ($b[1..3] -join ',') 'bytes 1-3'
        $ft = [BitConverter]::ToInt64($b, 4)
        $age = ([DateTime]::UtcNow - [DateTime]::FromFileTimeUtc($ft)).TotalMinutes
        Assert-True ($age -ge -1 -and $age -lt 5) "FILETIME is now (age $age min)"
        Assert-True (-not (Find-Item 'HKCU|Run|Quoted').Enabled) 'listed as disabled'
        Assert-Equal ('"{0}" --min' -f $fakeExe) (Get-PcRegistryValue $runHkcu 'Quoted').Data 'Run value kept'
    }

    Test-Case 'enable writes byte 2 and clears the FILETIME' {
        Set-PcStartupItemEnabled -Id 'HKCU|Run|Quoted' -Enabled $true
        $b = Get-ApprovedBytes 'HKCU' 'Run' 'Quoted'
        Assert-Equal 12 $b.Length 'length'
        Assert-Equal 2 $b[0] 'state byte'
        Assert-Equal '0,0,0,0,0,0,0,0,0,0,0' ($b[1..11] -join ',') 'other bytes'
        Assert-True (Find-Item 'HKCU|Run|Quoted').Enabled 'listed as enabled'
    }

    Test-Case 'odd first byte is disabled, even is enabled (2, 3, 6, 7)' {
        foreach ($case in @(@(2, $true), @(3, $false), @(6, $true), @(7, $false))) {
            $bytes = New-Object byte[] 12
            $bytes[0] = $case[0]
            Set-ApprovedBytes 'HKCU' 'Run' 'Unquoted' $bytes
            Assert-Equal $case[1] (Find-Item 'HKCU|Run|Unquoted').Enabled "first byte $($case[0])"
        }
    }

    Test-Case 'machine Run and Run32 items use the HKLM approval keys' {
        Set-PcStartupItemEnabled -Id 'HKLM|Run|MachineApp' -Enabled $false
        Set-PcStartupItemEnabled -Id 'HKLM|Run32|WowApp' -Enabled $false
        Assert-Equal 3 (Get-ApprovedBytes 'HKLM' 'Run' 'MachineApp')[0] 'Run approval'
        Assert-Equal 3 (Get-ApprovedBytes 'HKLM' 'Run32' 'WowApp')[0] 'Run32 approval'
        Assert-True ($null -eq (Get-ApprovedBytes 'HKCU' 'Run' 'MachineApp')) 'nothing under HKCU'
        Assert-True (-not (Find-Item 'HKLM|Run|MachineApp').Enabled) 'machine item disabled'
        Assert-True (-not (Find-Item 'HKLM|Run32|WowApp').Enabled) 'wow item disabled'
    }

    Test-Case 'folder items are keyed by the shortcut file name under StartupFolder' {
        Set-PcStartupItemEnabled -Id 'HKCU|StartupFolder|Plain.cmd' -Enabled $false
        Set-PcStartupItemEnabled -Id 'HKLM|StartupFolder|Shared.bat' -Enabled $false
        Assert-Equal 3 (Get-ApprovedBytes 'HKCU' 'StartupFolder' 'Plain.cmd')[0] 'user folder approval'
        Assert-Equal 3 (Get-ApprovedBytes 'HKLM' 'StartupFolder' 'Shared.bat')[0] 'common folder approval'
        Assert-True (-not (Find-Item 'HKCU|StartupFolder|Plain.cmd').Enabled) 'user folder item disabled'
        Assert-True (Test-Path -LiteralPath (Join-Path $userDir 'Plain.cmd')) 'file kept'
    }

    Test-Case 'a .lnk shortcut is resolved to its target' {
        $lnk = Join-Path $userDir 'Fake App.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($lnk); $sc.TargetPath = $fakeExe; $sc.Save()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        $item = Find-Item 'HKCU|StartupFolder|Fake App.lnk'
        Assert-Equal 'Fake App' $item.Name 'name'
        Assert-Equal $fakeExe $item.Command 'command is the target'
        Assert-True $item.TargetExists 'target exists'
    }

    Test-Case 'malformed ids are rejected' {
        foreach ($bad in 'nonsense', 'HKCU|Run', 'HKXX|Run|a', 'HKCU|Bogus|a', 'HKCU|Run32|a', 'HKCU|Run|') {
            $threw = $false
            try { Set-PcStartupItemEnabled -Id $bad -Enabled $false } catch { $threw = $true }
            Assert-True $threw "rejected: $bad"
        }
    }

    # Like Assert-PcCanChange, the admin and account checks are skipped when the registry is
    # redirected, so the refusal paths can't be exercised here; this pins that rule.
    Test-Case 'machine changes are not refused under a redirect (refusals skipped)' {
        Assert-True ([bool]$Pc.RegistryRedirect) 'redirect active'
        Set-PcStartupItemEnabled -Id 'HKLM|Run|MachineApp' -Enabled $true
        Assert-Equal 2 (Get-ApprovedBytes 'HKLM' 'Run' 'MachineApp')[0] 'machine change allowed'
    }
}
finally {
    Remove-Item -LiteralPath $testKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures.Count -eq 0) {
    Write-Host "All $script:Passed startup tests passed." -ForegroundColor Green
    exit 0
}
Write-Host "$($script:Failures.Count) failed, $script:Passed passed." -ForegroundColor Red
exit $script:Failures.Count

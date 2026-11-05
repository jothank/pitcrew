<#
.SYNOPSIS
    PitCrew tests. No dependencies: runs on the Windows PowerShell 5.1 that ships with Windows.

.DESCRIPTION
    Engine tests write only under HKCU:\Software\PitCrewTest\<random> (deleted at the end) and keep
    the undo journal in a temp folder. Nothing touches real Windows settings. Exit code = failures.
#>
$ErrorActionPreference = 'Stop'
# GitHub's runners give TEMP as a short 8.3 path (RUNNER~1), which never matches the long paths
# Windows reports for the same folder; the long form keeps path comparisons in these tests honest
$env:TEMP = $env:TMP = [IO.Path]::GetFullPath($env:TEMP)
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Load.ps1')

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
$testData = Join-Path $env:TEMP ('PitCrewTest-' + [guid]::NewGuid().ToString('N'))
Initialize-PcContext -Root $root -DataDir $testData -Language 'en' -RegistryRedirect $testKey

function New-TestTweak([string]$Id, [object[]]$Actions, [string]$Scope = 'machine', $AppliesTo, [string]$Refresh) {
    [pscustomobject]@{
        id = $Id; risk = 'safe'; scope = $Scope; appliesTo = $AppliesTo; refresh = $Refresh
        title = [pscustomobject]@{ en = $Id }; description = [pscustomobject]@{ en = $Id }
        actions = $Actions
    }
}

# The real read-only task lookup, kept before it is replaced by a fake below
$script:RealGetTaskEnabled = ${function:Get-PcScheduledTaskEnabled}

# --- Fakes for everything that would touch the real system -------------------------------------
# Services and hibernation keep their state in the redirected registry, like the real ones do;
# scheduled tasks, power plans and the mouse refresh keep it in memory.
$script:FakeFailService = ''
function Set-PcServiceStartup([string]$Name, [string]$StartupType) {
    if ($Name -eq $script:FakeFailService) { throw "fake: access denied for $Name" }
    $t = $script:PcStartTypes[$StartupType]
    [void](Set-PcRegistryValue (Get-PcServiceKey $Name) 'Start' 'DWord' $t.Start)
    [void](Set-PcRegistryValue (Get-PcServiceKey $Name) 'DelayedAutostart' 'DWord' $t.Delayed)
}
$script:FakeTasks = @{}
function Get-PcScheduledTaskEnabled([string]$Path, [string]$Name) {
    if (-not $script:FakeTasks.ContainsKey("$Path$Name")) { return $null }
    return $script:FakeTasks["$Path$Name"]
}
function Set-PcScheduledTaskEnabled([string]$Path, [string]$Name, [bool]$Enabled) { $script:FakeTasks["$Path$Name"] = $Enabled }
$script:FakePower = @{ Active = 'aaaaaaaa-0000-0000-0000-000000000001'; Schemes = @('aaaaaaaa-0000-0000-0000-000000000001'); FailSetActive = $false }
function Get-PcActivePowerScheme { $script:FakePower.Active }
function Get-PcPowerSchemes { $script:FakePower.Schemes }
function Copy-PcPowerScheme([string]$Source, [string]$Destination) { $script:FakePower.Schemes += $Destination.ToLowerInvariant() }
function Set-PcActivePowerScheme([string]$Guid) {
    if ($script:FakePower.FailSetActive) { throw 'fake: Modern Standby' }
    $script:FakePower.Active = $Guid.ToLowerInvariant()
}
function Remove-PcPowerScheme([string]$Guid) { $script:FakePower.Schemes = @($script:FakePower.Schemes | Where-Object { $_ -ne $Guid.ToLowerInvariant() }) }
function Set-PcHibernation([bool]$Enabled) { [void](Set-PcRegistryValue $script:PcPowerKey 'HibernateEnabled' 'DWord' ([int]$Enabled)) }
$script:FakeMouseRefreshes = 0
function Update-PcMouseSettings { $script:FakeMouseRefreshes++ }

function New-RegAction([string]$Path, [string]$Name, [string]$Kind = 'DWord', $Value = 1, [switch]$Absent) {
    $a = [pscustomobject]@{ type = 'registry'; path = $Path; name = $Name; kind = $Kind; value = $Value }
    if ($Absent) { $a | Add-Member -NotePropertyName absent -NotePropertyValue $true }
    return $a
}

try {
    Write-Host "`nEngine (registry redirected to $testKey)" -ForegroundColor Cyan

    Test-Case 'apply on a missing value, then undo removes value and created keys' {
        $t = New-TestTweak 't.missing' @(New-RegAction 'HKLM:\SOFTWARE\Policies\PcA\Deep' 'V1' 'DWord' 1)
        Assert-Equal 'NotApplied' (Get-PcTweakState $t) 'state before'
        [void](Invoke-PcTweak $t)
        Assert-Equal 'Applied' (Get-PcTweakState $t) 'state after apply'
        Assert-True (Get-PcJournalEntry $t) 'journal entry exists'
        $r = Undo-PcTweak $t
        Assert-Equal 0 $r.Skipped 'skipped'
        Assert-Equal 'NotApplied' (Get-PcTweakState $t) 'state after undo'
        Assert-True (-not (Test-Path "$testKey\HKLM\SOFTWARE\Policies\PcA")) 'created keys removed'
        Assert-True (-not (Get-PcJournalEntry $t)) 'journal entry removed'
    }

    Test-Case 'undo restores the previous value and type' {
        [void](Set-PcRegistryValue 'HKLM:\SOFTWARE\PcB' 'Num' 'DWord' 5)
        [void](Set-PcRegistryValue 'HKLM:\SOFTWARE\PcB' 'Text' 'String' 'abc')
        $t = New-TestTweak 't.restore' @(
            (New-RegAction 'HKLM:\SOFTWARE\PcB' 'Num' 'DWord' 0),
            (New-RegAction 'HKLM:\SOFTWARE\PcB' 'Text' 'DWord' 7))
        [void](Invoke-PcTweak $t)
        Assert-Equal 'DWord' (Get-PcRegistryValue 'HKLM:\SOFTWARE\PcB' 'Text').Kind 'kind while applied'
        [void](Undo-PcTweak $t)
        $num = Get-PcRegistryValue 'HKLM:\SOFTWARE\PcB' 'Num'
        $text = Get-PcRegistryValue 'HKLM:\SOFTWARE\PcB' 'Text'
        Assert-Equal 5 $num.Data 'number restored'
        Assert-Equal 'String' $text.Kind 'type restored'
        Assert-Equal 'abc' $text.Data 'text restored'
        Assert-True (Test-Path "$testKey\HKLM\SOFTWARE\PcB") 'pre-existing key kept'
    }

    Test-Case 'undo leaves alone a value changed by someone else' {
        $t = New-TestTweak 't.changed' @(New-RegAction 'HKCU:\Software\PcC' 'V' 'DWord' 1)
        [void](Invoke-PcTweak $t)
        [void](Set-PcRegistryValue 'HKCU:\Software\PcC' 'V' 'DWord' 42)
        $r = Undo-PcTweak $t
        Assert-Equal 1 $r.Skipped 'skipped'
        Assert-Equal 42 (Get-PcRegistryValue 'HKCU:\Software\PcC' 'V').Data 'user value kept'
    }

    Test-Case 'applying twice keeps the first snapshot' {
        [void](Set-PcRegistryValue 'HKLM:\SOFTWARE\PcD' 'V' 'DWord' 3)
        $t = New-TestTweak 't.twice' @(New-RegAction 'HKLM:\SOFTWARE\PcD' 'V' 'DWord' 9)
        [void](Invoke-PcTweak $t)
        [void](Invoke-PcTweak $t)
        [void](Undo-PcTweak $t)
        Assert-Equal 3 (Get-PcRegistryValue 'HKLM:\SOFTWARE\PcD' 'V').Data 'original value'
    }

    Test-Case 'a failing action rolls back the ones before it' {
        $t = New-TestTweak 't.rollback' @(
            (New-RegAction 'HKLM:\SOFTWARE\PcE' 'Good' 'DWord' 1),
            (New-RegAction 'HKLM:\SOFTWARE\PcE' 'Bad' 'NoSuchKind' 1))
        $threw = $false
        try { [void](Invoke-PcTweak $t) } catch { $threw = $true }
        Assert-True $threw 'apply threw'
        Assert-True (-not (Get-PcRegistryValue 'HKLM:\SOFTWARE\PcE' 'Good').Exists) 'first action rolled back'
        Assert-True (-not (Get-PcJournalEntry $t)) 'no journal entry'
    }

    Test-Case 'an "absent" action deletes a value and undo brings it back' {
        [void](Set-PcRegistryValue 'HKLM:\SOFTWARE\PcF' 'Gone' 'String' 'keep me')
        $t = New-TestTweak 't.absent' @(New-RegAction 'HKLM:\SOFTWARE\PcF' 'Gone' -Absent)
        [void](Invoke-PcTweak $t)
        Assert-Equal 'Applied' (Get-PcTweakState $t) 'state'
        [void](Undo-PcTweak $t)
        Assert-Equal 'keep me' (Get-PcRegistryValue 'HKLM:\SOFTWARE\PcF' 'Gone').Data 'restored'
    }

    Test-Case 'DWORD 0xFFFFFFFF and one-item MultiString survive a round trip' {
        [void](Set-PcRegistryValue 'HKLM:\SOFTWARE\PcG' 'Big' 'DWord' 4294967295)
        [void](Set-PcRegistryValue 'HKLM:\SOFTWARE\PcG' 'Multi' 'MultiString' @('only'))
        $t = New-TestTweak 't.edge' @(
            (New-RegAction 'HKLM:\SOFTWARE\PcG' 'Big' 'DWord' 0),
            (New-RegAction 'HKLM:\SOFTWARE\PcG' 'Multi' 'DWord' 0))
        [void](Invoke-PcTweak $t)
        [void](Undo-PcTweak $t)
        Assert-Equal ([uint32]4294967295) (Get-PcRegistryValue 'HKLM:\SOFTWARE\PcG' 'Big').Data 'big dword'
        $multi = Get-PcRegistryValue 'HKLM:\SOFTWARE\PcG' 'Multi'
        Assert-Equal 'MultiString' $multi.Kind 'multi kind'
        Assert-Equal @('only') $multi.Data 'multi data'
    }

    Test-Case 'a key default value (empty name) applies and undo removes the key it created' {
        $t = New-TestTweak 't.default' @(New-RegAction 'HKCU:\Software\PcClasses\CLSID\{x}\InprocServer32' '' 'String' '') 'user'
        [void](Invoke-PcTweak $t)
        Assert-Equal 'Applied' (Get-PcTweakState $t) 'applied'
        [void](Undo-PcTweak $t)
        Assert-True (-not (Test-Path "$testKey\HKCU\Software\PcClasses")) 'created keys removed'
    }

    Test-Case 'user-scope journal entries are per user' {
        $t = New-TestTweak 't.user' @(New-RegAction 'HKCU:\Software\PcH' 'V') 'user'
        Assert-Equal ('t.user@' + (Get-PcCurrentUserSid)) (Get-PcJournalKey $t) 'journal key'
    }

    Test-Case 'a tweak for another Windows build is not applicable and cannot be applied' {
        $t = New-TestTweak 't.future' @(New-RegAction 'HKLM:\SOFTWARE\PcI' 'V') 'machine' ([pscustomobject]@{ minBuild = 999999 })
        Assert-Equal 'NotApplicable' (Get-PcTweakState $t) 'state'
        $threw = $false
        try { [void](Invoke-PcTweak $t) } catch { $threw = $true }
        Assert-True $threw 'apply refused'
    }

    Test-Case 'applying a tweak that is already in place records nothing to undo' {
        [void](Set-PcRegistryValue 'HKLM:\SOFTWARE\PcK' 'V' 'DWord' 1)
        $t = New-TestTweak 't.already' @(New-RegAction 'HKLM:\SOFTWARE\PcK' 'V' 'DWord' 1)
        [void](Invoke-PcTweak $t)
        Assert-True (-not (Get-PcJournalEntry $t)) 'no journal entry'
    }

    Test-Case 'undo ignores a tampered path or key list in the journal' {
        [void](Set-PcRegistryValue 'HKLM:\SOFTWARE\PcVictim' 'Keep' 'DWord' 1)
        New-Item -Path "$testKey\HKLM\SOFTWARE\PcVictimEmpty" -Force | Out-Null
        $t = New-TestTweak 't.tamper' @(New-RegAction 'HKLM:\SOFTWARE\PcJ' 'V' 'DWord' 1)
        [void](Invoke-PcTweak $t)
        $entries = @(Get-PcJournal)
        foreach ($e in $entries | Where-Object tweakId -eq 't.tamper') {
            # The journal doesn't store targets any more; an attacker could still add them
            $e.actions[0] | Add-Member -NotePropertyName path -NotePropertyValue 'HKLM:\SOFTWARE\PcVictim' -Force
            $e.actions[0] | Add-Member -NotePropertyName name -NotePropertyValue 'Keep' -Force
            $e.actions[0].createdKeys = @("$testKey\HKLM\SOFTWARE\PcVictimEmpty")
        }
        Save-PcJournal $entries
        [void](Undo-PcTweak $t)
        Assert-True (-not (Get-PcRegistryValue 'HKLM:\SOFTWARE\PcJ' 'V').Exists) 'real action undone'
        Assert-Equal 1 (Get-PcRegistryValue 'HKLM:\SOFTWARE\PcVictim' 'Keep').Data 'victim value untouched'
        Assert-True (Test-Path "$testKey\HKLM\SOFTWARE\PcVictimEmpty") 'victim key not deleted'
    }

    Test-Case 'reading state and the journal never creates the data folder' {
        $saved = $Pc.DataDir
        $Pc.DataDir = Join-Path $env:TEMP ('PitCrewNoCreate-' + [guid]::NewGuid().ToString('N'))
        try {
            $t = New-TestTweak 't.read' @(New-RegAction 'HKLM:\SOFTWARE\PcL' 'V')
            [void](Get-PcTweakState $t)
            [void](Get-PcJournalEntry $t)
            [void](@(Get-PcJournal))
            Assert-True (-not (Test-Path $Pc.DataDir)) 'data folder not created'
        } finally { $Pc.DataDir = $saved }
    }

    Write-Host "`nOther action types (with fakes)" -ForegroundColor Cyan

    Test-Case 'service: disable, then undo restores Manual' {
        [void](Set-PcRegistryValue (Get-PcServiceKey 'PcFakeSvc') 'Start' 'DWord' 3)
        $t = New-TestTweak 't.svc' @([pscustomobject]@{ type = 'service'; name = 'PcFakeSvc'; startupType = 'Disabled' })
        [void](Invoke-PcTweak $t)
        Assert-Equal 'Disabled' (Get-PcServiceStartup 'PcFakeSvc') 'disabled'
        [void](Undo-PcTweak $t)
        Assert-Equal 'Manual' (Get-PcServiceStartup 'PcFakeSvc') 'restored'
    }

    Test-Case 'service: delayed start is restored as delayed' {
        [void](Set-PcRegistryValue (Get-PcServiceKey 'PcFakeSvc2') 'Start' 'DWord' 2)
        [void](Set-PcRegistryValue (Get-PcServiceKey 'PcFakeSvc2') 'DelayedAutostart' 'DWord' 1)
        $t = New-TestTweak 't.svc2' @([pscustomobject]@{ type = 'service'; name = 'PcFakeSvc2'; startupType = 'Manual' })
        [void](Invoke-PcTweak $t)
        [void](Undo-PcTweak $t)
        Assert-Equal 'AutomaticDelayed' (Get-PcServiceStartup 'PcFakeSvc2') 'restored'
    }

    Test-Case 'service: a refused change rolls back the registry action before it' {
        [void](Set-PcRegistryValue (Get-PcServiceKey 'PcFakeLocked') 'Start' 'DWord' 3)
        $script:FakeFailService = 'PcFakeLocked'
        try {
            $t = New-TestTweak 't.svcfail' @(
                (New-RegAction 'HKLM:\SOFTWARE\PcM' 'V' 'DWord' 1),
                [pscustomobject]@{ type = 'service'; name = 'PcFakeLocked'; startupType = 'Disabled' })
            $threw = $false
            try { [void](Invoke-PcTweak $t) } catch { $threw = $true }
            Assert-True $threw 'apply threw'
            Assert-True (-not (Get-PcRegistryValue 'HKLM:\SOFTWARE\PcM' 'V').Exists) 'registry rolled back'
        } finally { $script:FakeFailService = '' }
    }

    Test-Case 'scheduled tasks: a missing task is skipped, the others apply and undo' {
        $script:FakeTasks['\Pc\TaskA'] = $true
        $t = New-TestTweak 't.tasks' @(
            [pscustomobject]@{ type = 'scheduledTask'; path = '\Pc\'; name = 'TaskA'; enabled = $false },
            [pscustomobject]@{ type = 'scheduledTask'; path = '\Pc\'; name = 'Missing'; enabled = $false })
        Assert-Equal 'NotApplied' (Get-PcTweakState $t) 'state before'
        [void](Invoke-PcTweak $t)
        Assert-Equal 'Applied' (Get-PcTweakState $t) 'applied although one task is missing'
        Assert-Equal $false $script:FakeTasks['\Pc\TaskA'] 'task disabled'
        Assert-Equal 1 @((Get-PcJournalEntry $t).actions).Count 'only the existing task recorded'
        [void](Undo-PcTweak $t)
        Assert-Equal $true $script:FakeTasks['\Pc\TaskA'] 'task enabled again'
    }

    Test-Case 'a tweak whose actions all target missing things is not applicable' {
        $t = New-TestTweak 't.none' @([pscustomobject]@{ type = 'scheduledTask'; path = '\Pc\'; name = 'Nope'; enabled = $false })
        Assert-Equal 'NotApplicable' (Get-PcTweakState $t) 'state'
    }

    Test-Case 'power plan: creates the plan, activates it, and undo removes it again' {
        $plan = 'bbbbbbbb-0000-0000-0000-000000000002'
        $t = New-TestTweak 't.power' @([pscustomobject]@{ type = 'powerPlan'; guid = $plan; source = 'cccccccc-0000-0000-0000-000000000003' })
        [void](Invoke-PcTweak $t)
        Assert-Equal $plan $script:FakePower.Active 'active'
        [void](Undo-PcTweak $t)
        Assert-Equal 'aaaaaaaa-0000-0000-0000-000000000001' $script:FakePower.Active 'previous plan active'
        Assert-True ($script:FakePower.Schemes -notcontains $plan) 'created plan removed'
    }

    Test-Case 'power plan: when Windows refuses to switch, the copied plan is removed' {
        $plan = 'dddddddd-0000-0000-0000-000000000004'
        $script:FakePower.FailSetActive = $true
        try {
            $t = New-TestTweak 't.powerfail' @([pscustomobject]@{ type = 'powerPlan'; guid = $plan; source = 'cccccccc-0000-0000-0000-000000000003' })
            $threw = $false
            try { [void](Invoke-PcTweak $t) } catch { $threw = $true }
            Assert-True $threw 'apply threw'
            Assert-True ($script:FakePower.Schemes -notcontains $plan) 'no leftover plan'
            Assert-True (-not (Get-PcJournalEntry $t)) 'nothing recorded'
        } finally { $script:FakePower.FailSetActive = $false }
    }

    Test-Case 'hibernation: off, then undo turns it back on' {
        [void](Set-PcRegistryValue $script:PcPowerKey 'HibernateEnabled' 'DWord' 1)
        $t = New-TestTweak 't.hib' @([pscustomobject]@{ type = 'hibernation'; enabled = $false })
        [void](Invoke-PcTweak $t)
        Assert-Equal $false (Get-PcHibernationEnabled) 'off'
        [void](Undo-PcTweak $t)
        Assert-Equal $true (Get-PcHibernationEnabled) 'on again'
    }

    Test-Case 'DirectX setting: keeps the other options and their order' {
        [void](Set-PcRegistryValue $script:PcDxPath $script:PcDxName 'String' 'VRROptimizeEnable=0;AutoHDREnable=1;')
        $t = New-TestTweak 't.dx' @([pscustomobject]@{ type = 'dxSetting'; key = 'SwapEffectUpgradeEnable'; value = '1' }) 'user'
        [void](Invoke-PcTweak $t)
        Assert-Equal 'VRROptimizeEnable=0;AutoHDREnable=1;SwapEffectUpgradeEnable=1;' (Get-PcRegistryValue $script:PcDxPath $script:PcDxName).Data 'added'
        [void](Undo-PcTweak $t)
        Assert-Equal 'VRROptimizeEnable=0;AutoHDREnable=1;' (Get-PcRegistryValue $script:PcDxPath $script:PcDxName).Data 'restored'
    }

    Test-Case 'DirectX setting: undo removes a value that did not exist before' {
        Remove-PcRegistryValue $script:PcDxPath $script:PcDxName
        $t = New-TestTweak 't.dx2' @([pscustomobject]@{ type = 'dxSetting'; key = 'SwapEffectUpgradeEnable'; value = '1' }) 'user'
        [void](Invoke-PcTweak $t)
        [void](Undo-PcTweak $t)
        Assert-True (-not (Get-PcRegistryValue $script:PcDxPath $script:PcDxName).Exists) 'value removed'
    }

    Test-Case 'the mouse refresh runs after apply and after undo' {
        $before = $script:FakeMouseRefreshes
        $t = New-TestTweak 't.mouse' @(New-RegAction 'HKCU:\Control Panel\Mouse' 'MouseSpeed' 'String' '0') 'user' $null 'mouse'
        [void](Invoke-PcTweak $t)
        [void](Undo-PcTweak $t)
        Assert-Equal ($before + 2) $script:FakeMouseRefreshes 'refresh count'
    }

    Test-Case 'undo ignores a journal record whose type was changed' {
        [void](Set-PcRegistryValue (Get-PcServiceKey 'PcFakeSvc3') 'Start' 'DWord' 3)
        $t = New-TestTweak 't.typeswap' @(New-RegAction 'HKLM:\SOFTWARE\PcN' 'V' 'DWord' 1)
        [void](Invoke-PcTweak $t)
        $entries = @(Get-PcJournal)
        foreach ($e in $entries | Where-Object tweakId -eq 't.typeswap') { $e.actions[0].type = 'service' }
        Save-PcJournal $entries
        $r = Undo-PcTweak $t
        Assert-Equal 1 $r.Skipped 'skipped'
        Assert-Equal 'Manual' (Get-PcServiceStartup 'PcFakeSvc3') 'unrelated service untouched'
    }

    Test-Case 'editions match by family and form factor gates desktop-only tweaks' {
        $savedInfo = $Pc.WindowsInfo; $savedForm = $Pc.FormFactor
        try {
            $Pc.WindowsInfo = [pscustomobject]@{ Edition = 'CoreSingleLanguage'; Build = 26100 }
            $Pc.FormFactor = 'laptop'
            Assert-Equal 'home' (Get-PcEditionFamily) 'family'
            $homeTweak = New-TestTweak 't.home' @(New-RegAction 'HKLM:\SOFTWARE\PcO' 'V') 'machine' ([pscustomobject]@{ editions = @('home', 'pro') })
            $ent = New-TestTweak 't.ent' @(New-RegAction 'HKLM:\SOFTWARE\PcO' 'V') 'machine' ([pscustomobject]@{ editions = @('enterprise') })
            $desk = New-TestTweak 't.desk' @(New-RegAction 'HKLM:\SOFTWARE\PcO' 'V') 'machine' ([pscustomobject]@{ formFactor = 'desktop' })
            Assert-Equal 'NotApplied' (Get-PcTweakState $homeTweak) 'home edition tweak'
            Assert-Equal 'NotApplicable' (Get-PcTweakState $ent) 'enterprise-only tweak'
            Assert-Equal 'NotApplicable' (Get-PcTweakState $desk) 'desktop-only tweak on a laptop'
        } finally { $Pc.WindowsInfo = $savedInfo; $Pc.FormFactor = $savedForm }
    }

    Write-Host "`nReview fixes" -ForegroundColor Cyan

    Test-Case 'undo keeps going after a failing step and keeps that step to retry' {
        [void](Set-PcRegistryValue (Get-PcServiceKey 'PcFakeUndoFail') 'Start' 'DWord' 3)
        $t = New-TestTweak 't.undofail' @(
            (New-RegAction 'HKLM:\SOFTWARE\PcP' 'V' 'DWord' 1),
            [pscustomobject]@{ type = 'service'; name = 'PcFakeUndoFail'; startupType = 'Disabled' })
        [void](Invoke-PcTweak $t)
        $script:FakeFailService = 'PcFakeUndoFail'
        try { $r = Undo-PcTweak $t } finally { $script:FakeFailService = '' }
        Assert-Equal 1 $r.Failed 'failed steps'
        Assert-True (-not (Get-PcRegistryValue 'HKLM:\SOFTWARE\PcP' 'V').Exists) 'the other step was undone'
        $left = Get-PcJournalEntry $t
        Assert-Equal 1 @($left.actions).Count 'failed step kept in the journal'
        $r2 = Undo-PcTweak $t
        Assert-Equal 0 $r2.Failed 'retry works'
        Assert-Equal 'Manual' (Get-PcServiceStartup 'PcFakeUndoFail') 'service restored on retry'
    }

    Test-Case 'a tweak that conflicts with an applied one is refused' {
        $a = New-TestTweak 't.planA' @(New-RegAction 'HKLM:\SOFTWARE\PcQ' 'A')
        $b = New-TestTweak 't.planB' @(New-RegAction 'HKLM:\SOFTWARE\PcQ' 'B')
        $b | Add-Member -NotePropertyName conflictsWith -NotePropertyValue @('t.planA')
        [void](Invoke-PcTweak $a)
        $threw = $false
        try { [void](Invoke-PcTweak $b) } catch { $threw = $true }
        Assert-True $threw 'conflict refused'
        Assert-True (-not (Get-PcRegistryValue 'HKLM:\SOFTWARE\PcQ' 'B').Exists) 'nothing written'
        [void](Undo-PcTweak $a)
    }

    Test-Case 'a create-only (absentOnly) target is never written back from the journal' {
        $path = 'HKCU:\Software\PcClasses2\CLSID\{y}\InprocServer32'
        $t = New-TestTweak 't.absentonly' @([pscustomobject]@{ type = 'registry'; restoreBefore = 'absentOnly'; path = $path; name = ''; kind = 'String'; value = '' }) 'user'
        [void](Invoke-PcTweak $t)
        $entries = @(Get-PcJournal)
        foreach ($e in $entries | Where-Object tweakId -eq 't.absentonly') {
            $e.actions[0].before = [pscustomobject]@{ exists = $true; kind = 'ExpandString'; data = '%PUBLIC%\evil.dll' }
        }
        Save-PcJournal $entries
        [void](Undo-PcTweak $t)
        Assert-True (-not (Get-PcRegistryValue $path '').Exists) 'value deleted, not replaced by the journal value'
        # And an existing value set by someone else is not taken over
        [void](Set-PcRegistryValue $path '' 'String' 'C:\Other\server.dll')
        $threw = $false
        try { [void](Invoke-PcTweak $t) } catch { $threw = $true }
        Assert-True $threw 'apply refused'
        Assert-Equal 'C:\Other\server.dll' (Get-PcRegistryValue $path '').Data 'other value untouched'
    }

    Test-Case 'undo still works after the tweak became not applicable (edition upgrade)' {
        $savedInfo = $Pc.WindowsInfo
        try {
            $Pc.WindowsInfo = [pscustomobject]@{ Edition = 'Professional'; Build = 26100 }
            $t = New-TestTweak 't.edition' @(New-RegAction 'HKLM:\SOFTWARE\PcR' 'V') 'machine' ([pscustomobject]@{ editions = @('pro') })
            [void](Invoke-PcTweak $t)
            $Pc.WindowsInfo = [pscustomobject]@{ Edition = 'Enterprise'; Build = 26100 }
            Assert-Equal 'NotApplicable' (Get-PcTweakState $t) 'now not applicable'
            [void](Undo-PcTweak $t)
            Assert-True (-not (Get-PcRegistryValue 'HKLM:\SOFTWARE\PcR' 'V').Exists) 'undone anyway'
        } finally { $Pc.WindowsInfo = $savedInfo }
    }

    Test-Case 'a journal record is only used for the action with the same target' {
        [void](Set-PcRegistryValue 'HKLM:\SOFTWARE\PcS' 'Old' 'DWord' 7)
        $t1 = New-TestTweak 't.moved' @(New-RegAction 'HKLM:\SOFTWARE\PcS' 'Old' 'DWord' 1)
        [void](Invoke-PcTweak $t1)
        # A catalog update points the same index at another value
        $t2 = New-TestTweak 't.moved' @(New-RegAction 'HKLM:\SOFTWARE\PcS' 'New' 'DWord' 1)
        [void](Set-PcRegistryValue 'HKLM:\SOFTWARE\PcS' 'New' 'DWord' 1)
        $r = Undo-PcTweak $t2
        Assert-Equal 1 $r.Skipped 'old record ignored'
        Assert-Equal 1 (Get-PcRegistryValue 'HKLM:\SOFTWARE\PcS' 'New').Data 'new value not given the old snapshot'
    }

    Test-Case 'the journal is written after each step (write-ahead)' {
        $script:FakeFailService = 'PcFakeWal'
        [void](Set-PcRegistryValue (Get-PcServiceKey 'PcFakeWal') 'Start' 'DWord' 3)
        try {
            # Watch the journal right after the first step by failing the second one
            $t = New-TestTweak 't.wal' @(
                (New-RegAction 'HKLM:\SOFTWARE\PcT' 'V' 'DWord' 1),
                [pscustomobject]@{ type = 'service'; name = 'PcFakeWal'; startupType = 'Disabled' })
            $seen = $null
            $orig = ${function:Set-PcServiceStartup}
            ${function:Set-PcServiceStartup} = { param($Name, $StartupType) $script:SeenEntry = Get-PcJournalEntry $t; throw 'fake fail' }
            try { [void](Invoke-PcTweak $t) } catch { }
            ${function:Set-PcServiceStartup} = $orig
            Assert-True ($script:SeenEntry -and @($script:SeenEntry.actions).Count -eq 1) 'first step was journaled before the second ran'
            Assert-True (-not (Get-PcJournalEntry $t)) 'rolled back and removed after the failure'
        } finally { $script:FakeFailService = '' }
    }

    Test-Case 'the real task lookup returns nothing (no error) for a task that does not exist' {
        $result = & $script:RealGetTaskEnabled '\PitCrewNoSuchFolder\' 'NoSuchTask'
        Assert-True ($null -eq $result) 'missing task is $null'
    }

    Test-Case 'a folder whose permissions cannot be read is simply not trusted' {
        Assert-Equal $false (Test-PcPathTrusted (Join-Path $testData 'does-not-exist')) 'missing path'
    }

    Test-Case 'cleanup refuses a root that is a junction' {
        $realRoot = Join-Path $testData 'real-root'
        $linkRoot = Join-Path $testData 'link-root'
        New-Item -ItemType Directory -Force -Path $realRoot | Out-Null
        Set-Content (Join-Path $realRoot 'old.txt') 'x'
        (Get-Item (Join-Path $realRoot 'old.txt')).LastWriteTime = (Get-Date).AddDays(-5)
        & cmd.exe /c mklink /J $linkRoot $realRoot | Out-Null
        $r = Remove-PcOldFiles $linkRoot
        Assert-Equal 0 $r.FreedBytes 'nothing deleted through the junction root'
        Assert-True (Test-Path (Join-Path $realRoot 'old.txt')) 'file kept'
        & cmd.exe /c rmdir $linkRoot | Out-Null
    }

    Test-Case 'read-only temp files are deleted too' {
        $ro = Join-Path $testData 'ro-root'
        New-Item -ItemType Directory -Force -Path $ro | Out-Null
        $file = Join-Path $ro 'readonly.txt'
        Set-Content $file 'x'
        $item = Get-Item $file; $item.LastWriteTime = (Get-Date).AddDays(-5); $item.IsReadOnly = $true
        $r = Remove-PcOldFiles $ro
        Assert-True (-not (Test-Path $file)) 'read-only file deleted'
    }

    Test-Case 'a junction is never a trusted data folder' {
        $real = Join-Path $testData 'real-folder'
        $link = Join-Path $testData 'link-folder'
        New-Item -ItemType Directory -Force -Path $real | Out-Null
        & cmd.exe /c mklink /J $link $real | Out-Null
        Assert-Equal $false (Test-PcPathTrusted $link) 'junction'
        & cmd.exe /c rmdir $link | Out-Null
    }

    Write-Host "`nCleanup" -ForegroundColor Cyan

    Test-Case 'safe delete refuses a path that now runs through a junction' {
        $base = Join-Path $testData 'toctou'
        $root = Join-Path $base 'root'
        $outside = Join-Path $base 'outside'
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'sub'), $outside | Out-Null
        Set-Content (Join-Path $outside 'victim.txt') 'keep'
        $rootFinal = [PitCrew.SafeDelete]::FinalPath($root)
        # Listed as root\sub\victim.txt, then "sub" is swapped for a junction to outside
        Remove-Item (Join-Path $root 'sub') -Force
        & cmd.exe /c mklink /J (Join-Path $root 'sub') $outside | Out-Null
        Assert-Equal $false ([PitCrew.SafeDelete]::Delete((Join-Path $root 'sub\victim.txt'), $rootFinal)) 'refused'
        Assert-True (Test-Path (Join-Path $outside 'victim.txt')) 'file outside the root kept'
        Set-Content (Join-Path $base 'root\plain.txt') 'temp'
        Assert-Equal $true ([PitCrew.SafeDelete]::Delete((Join-Path $root 'plain.txt'), $rootFinal)) 'normal file deleted'
        & cmd.exe /c rmdir (Join-Path $root 'sub') | Out-Null
    }

    Test-Case 'cleanup never follows a junction out of the folder' {
        $base = Join-Path $testData 'junction-test'
        $outside = Join-Path $base 'outside'
        $target = Join-Path $base 'target'
        New-Item -ItemType Directory -Force -Path $outside, (Join-Path $target 'inner') | Out-Null
        $old = (Get-Date).AddDays(-3)
        Set-Content (Join-Path $outside 'precious.txt') 'do not delete'
        Set-Content (Join-Path $target 'inner\old.txt') 'temp'
        (Get-Item (Join-Path $outside 'precious.txt')).LastWriteTime = $old
        (Get-Item (Join-Path $target 'inner\old.txt')).LastWriteTime = $old
        & cmd.exe /c mklink /J (Join-Path $target 'link') $outside | Out-Null
        Assert-True (Test-Path (Join-Path $target 'link\precious.txt')) 'junction created'

        $found = @(Get-PcOldFiles $target | ForEach-Object FullName)
        Assert-Equal @((Join-Path $target 'inner\old.txt')) $found 'only the file inside is listed'
        $result = Remove-PcOldFiles $target
        Assert-True (Test-Path (Join-Path $outside 'precious.txt')) 'file behind the junction kept'
        Assert-True (-not (Test-Path (Join-Path $target 'inner\old.txt'))) 'old temp file deleted'
        # Emptying a folder touches it, so it waits for the same 24 hours as files before going
        Assert-True (Test-Path (Join-Path $target 'inner')) 'folder emptied just now is kept until it is old'
        Assert-Equal 0 (@(Get-PcOldFiles $target)).Count 'nothing left to delete'
        Assert-True ($result.FreedBytes -gt 0) 'freed bytes counted'
        & cmd.exe /c rmdir (Join-Path $target 'link') | Out-Null
    }

    Write-Host "`nDrivers (synthetic Windows Update offers)" -ForegroundColor Cyan

    $installedDate = [datetime]'2025-06-01'
    $dev = [pscustomobject]@{ Name = 'Test NIC'; PNPDeviceID = 'PCI\VEN_1&DEV_2\1' }
    $drv = [pscustomobject]@{ DriverDate = $installedDate.ToLocalTime(); DriverVersion = '1.0'; InfName = 'oem7.inf' }
    $index = @{
        ByHardwareId     = @{ 'PCI\VEN_1&DEV_2' = [System.Collections.ArrayList]@($dev) }
        ByCompatibleId   = @{ 'PCI\CC_0200' = [System.Collections.ArrayList]@($dev) }
        DriverByDeviceId = @{ 'PCI\VEN_1&DEV_2\1' = $drv }
    }
    function New-FakeUpdate($HwId, $Date, $Class = 'Net') {
        [pscustomobject]@{ Title = "Vendor - $Class - 2.0.0.1"; DriverHardwareID = $HwId; DriverVerDate = $Date
            DriverClass = $Class; DriverModel = 'Model X'; Identity = [pscustomobject]@{ UpdateID = [guid]::NewGuid().ToString() } }
    }
    $cases = @(
        @('newer driver is recommended', (New-FakeUpdate 'pci\ven_1&dev_2' ([datetime]'2026-01-01')), 'recommended'),
        @('older driver is flagged', (New-FakeUpdate 'PCI\VEN_1&DEV_2' ([datetime]'2024-01-01')), 'older'),
        @('missing date is flagged', (New-FakeUpdate 'PCI\VEN_1&DEV_2' $null), 'noDate'),
        @('firmware is flagged', (New-FakeUpdate 'PCI\VEN_1&DEV_2' ([datetime]'2026-01-01') 'Firmware'), 'firmware'),
        @('graphics driver is flagged', (New-FakeUpdate 'PCI\VEN_1&DEV_2' ([datetime]'2026-01-01') 'Display'), 'display'),
        @('unknown device is flagged', (New-FakeUpdate 'USB\NOPE' ([datetime]'2026-01-01')), 'unknownDevice'),
        @('compatible-ID match is used as fallback', (New-FakeUpdate 'PCI\CC_0200' ([datetime]'2026-01-01')), 'recommended')
    )
    foreach ($c in $cases) {
        Test-Case $c[0] {
            $offer = ConvertTo-PcDriverOffer $c[1] $index
            Assert-Equal $c[2] $offer.Verdict 'verdict'
            Assert-Equal ($c[2] -eq 'recommended') $offer.Recommended 'recommended flag'
            if ($c[2] -ne 'unknownDevice') { Assert-Equal @('oem7.inf') $offer.CurrentInfs 'infs to back up' }
        }
    }

    Write-Host "`nCatalog and files" -ForegroundColor Cyan

    Test-Case 'tweak catalog is complete and points at sources' {
        $tweaks = @(Import-PcTweaks)
        $expected = 0
        foreach ($f in Get-ChildItem (Join-Path $root 'tweaks') -Filter *.json) {
            $expected += ([regex]::Matches((Get-Content $f.FullName -Raw), '"id"\s*:')).Count
        }
        Assert-Equal $expected $tweaks.Count 'one object per tweak entry'
        $languages = @(Get-ChildItem (Join-Path $root 'locales') -Filter *.json | ForEach-Object BaseName)
        foreach ($t in $tweaks) {
            $id = $t.id
            Assert-True ($id -is [string]) 'tweak id is a single string'
            Assert-True ($t.category -is [string]) "$id category"
            Assert-True (@('safe', 'moderate', 'advanced') -contains $t.risk) "$id risk"
            Assert-True (@('machine', 'user') -contains $t.scope) "$id scope"
            Assert-True ($script:PcEvidenceLevels -contains $t.evidence) "$id evidence (learn/vendor/community)"
            Assert-True ($t.reference -match '^https://') "$id reference"
            foreach ($lang in $languages) {
                Assert-True ($t.title.$lang -and $t.description.$lang) "$id texts in $lang"
            }
            if ($t.appliesTo.editions) {
                foreach ($e in @($t.appliesTo.editions)) { Assert-True ($script:PcEditionFamilies -contains $e) "$id edition family '$e'" }
            }
            if ($t.appliesTo.formFactor) { Assert-True ($script:PcFormFactors -contains $t.appliesTo.formFactor) "$id formFactor" }
            if ($t.refresh) { Assert-True (@('mouse') -contains $t.refresh) "$id refresh" }
            foreach ($other in @($t.conflictsWith)) { if ($other) { Assert-True ($tweaks.id -contains $other) "$id conflictsWith $other" } }
            foreach ($a in @($t.actions)) {
                Assert-True ($script:PcActionTypes.ContainsKey($a.type)) "$id action type '$($a.type)'"
                if ($script:PcActionTypes[$a.type].MachineOnly) { Assert-Equal 'machine' $t.scope "$id $($a.type) needs machine scope" }
                switch ($a.type) {
                    'registry' {
                        Assert-True ($a.path -match '^HK(LM|CU):\\') "$id path"
                        if ($a.restoreBefore) { Assert-Equal 'absentOnly' $a.restoreBefore "$id restoreBefore" }
                        if ($a.path -like 'HKCU:*') { Assert-Equal 'user' $t.scope "$id HKCU action needs user scope" }
                        else { Assert-Equal 'machine' $t.scope "$id HKLM action needs machine scope" }
                        if (-not $a.absent) { Assert-True ($script:PcRegistryKinds -contains $a.kind) "$id kind" }
                    }
                    'dxSetting' { Assert-Equal 'user' $t.scope "$id dxSetting needs user scope"; Assert-True ($a.key -and $a.key -notmatch '[;=]') "$id dx key" }
                    'service' { Assert-True ($script:PcStartTypes.ContainsKey($a.startupType)) "$id startupType" }
                    'scheduledTask' { Assert-True ($a.path -like '\*\') "$id task path must start and end with \"; Assert-True ($a.enabled -is [bool]) "$id enabled" }
                    'powerPlan' { Assert-True ((Test-PcGuid $a.guid) -and (Test-PcGuid $a.source)) "$id plan GUIDs" }
                    'hibernation' { Assert-True ($a.enabled -is [bool]) "$id enabled" }
                }
            }
        }
    }

    Test-Case 'every locale has the same keys as English' {
        $en = @((Read-PcJson (Join-Path $root 'locales\en.json')).PSObject.Properties.Name)
        foreach ($f in Get-ChildItem (Join-Path $root 'locales') -Filter *.json) {
            $keys = @((Read-PcJson $f.FullName).PSObject.Properties.Name)
            $missing = @($en | Where-Object { $keys -notcontains $_ })
            $extra = @($keys | Where-Object { $en -notcontains $_ })
            Assert-True ($missing.Count -eq 0 -and $extra.Count -eq 0) "$($f.Name): missing [$($missing -join ', ')] extra [$($extra -join ', ')]"
        }
    }

    Test-Case 'a data folder that standard users can write to is not trusted' {
        $dir = Join-Path $testData 'acl-test'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $acl = Get-Acl -LiteralPath $dir
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'), 'Write', 'Allow')))
        Set-Acl -LiteralPath $dir -AclObject $acl
        Assert-Equal $false (Test-PcDataDirTrusted $dir) 'Users can write'
    }

    Test-Case 'every text key used in the code exists in English' {
        # The window's page table lives in Window.ps1, which the engine tests don't load
        . (Join-Path $root 'src\UI\Window.ps1')
        $en = @((Read-PcJson (Join-Path $root 'locales\en.json')).PSObject.Properties.Name)
        $code = (Get-ChildItem (Join-Path $root 'src'), (Join-Path $root 'PitCrew.ps1') -Recurse -Filter *.ps1 | Get-Content -Raw) -join "`n"
        $used = [regex]::Matches($code, "Get-PcText '([^']+)'") | ForEach-Object { $_.Groups[1].Value }
        $used += [regex]::Matches($code, "'(drivers\.(problem|tip)\.[a-zA-Z]+)'") | ForEach-Object { $_.Groups[1].Value }
        $used += [regex]::Matches($code, "TextKey = '([^']+)'") | ForEach-Object { $_.Groups[1].Value }
        # Keys built at run time
        foreach ($s in $script:PcTweakStates) { $used += "state.$s" }
        foreach ($r in 'safe', 'moderate', 'advanced') { $used += "risk.$r" }
        foreach ($v in 'recommended', 'older', 'noDate', 'firmware', 'display', 'unknownDevice') { $used += "drivers.verdict.$v" }
        foreach ($v in 'installed', 'installedWithErrors', 'failed', 'aborted', 'downloadFailed') { $used += "drivers.result.$v" }
        foreach ($p in 'performance', 'privacy', 'explorer', 'startup', 'cleanup', 'memory', 'maintenance', 'apps', 'drivers', 'restore', 'history', 'about') { $used += "page.$p.title", "page.$p.intro", "nav.$p" }
        foreach ($o in @($script:PcFilterOptions.Values | ForEach-Object { $_ }) | Sort-Object -Unique) { $used += "filter.$o" }
        foreach ($t in 'auto', 'light', 'dark') { $used += "theme.$t" }
        foreach ($r in 'safe', 'caution') { $used += "apps.risk.$r" }
        $used += 'link.vendor', 'link.community'
        foreach ($c in $script:PcCleanupTargets) { $used += "cleanup.$($c.Id).detail" }
        foreach ($m in $script:PcMaintenanceTasks) { $used += "$($m.TextKey).detail" }
        foreach ($h in 'Healthy', 'Warning', 'Unhealthy', 'Unknown') { $used += "disk.$h" }
        foreach ($rt in '0', '1', '10', '12', '13', 'other') { $used += "restore.type.$rt" }
        foreach ($pg in $script:PcPages.Values) { foreach ($b in $pg.Primary, $pg.Secondary) { if ($b) { $used += $b[0] } } }
        $missing = @($used | Sort-Object -Unique | Where-Object { $en -notcontains $_ })
        Assert-True ($missing.Count -eq 0) "missing in en.json: $($missing -join ', ')"
    }

    Test-Case 'app catalog has valid Store IDs and no protected package' {
        $apps = @(Read-PcJson (Join-Path $root 'data\apps.json'))
        Assert-True ($apps.Count -gt 1) 'apps are read as separate items'
        Assert-Equal $apps.Count @(Get-PcAppCatalog).Count 'catalog keeps every app'
        $languages = @(Get-ChildItem (Join-Path $root 'locales') -Filter *.json | ForEach-Object BaseName)
        $packages = @{}
        foreach ($app in $apps) {
            Assert-True ($app.package -is [string]) 'package is a single string'
            Assert-True (-not $packages.ContainsKey($app.package)) "$($app.package) listed twice"
            $packages[$app.package] = $true
            Assert-True ($app.package -notmatch '[*?]') "$($app.package) must be an exact name, no wildcards"
            if ($app.risk) { Assert-True (@('safe', 'caution') -contains $app.risk) "$($app.package) risk" }
            if ($app.risk -eq 'caution') { Assert-True ($app.note.en -and $app.note.'pt-BR') "$($app.package) caution needs a note" }
            foreach ($lang in $languages) { Assert-True ($app.name.$lang) "$($app.package) name in $lang" }
            Assert-True ($app.storeId -match '^([0-9A-Z]{12}|XP[0-9A-Z]{12})$') "$($app.package) store id"
            Assert-True (-not (Test-PcProtectedPackage $app.package)) "$($app.package) is protected"
            Assert-True ($app.name.en -and $app.name.'pt-BR') "$($app.package) names"
        }
        Assert-True (Test-PcProtectedPackage 'Microsoft.DesktopAppInstaller') 'winget is protected'
        Assert-True (Test-PcProtectedPackage 'Microsoft.VCLibs.140.00') 'frameworks are protected'
    }

    Test-Case 'startup apps module tests pass (tests\Startup-Tests.ps1)' {
        $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Startup-Tests.ps1') 2>&1
        Assert-Equal 0 $LASTEXITCODE ("startup tests failed:`n" + (($out | Select-String 'FAIL') -join "`n"))
    }

    Test-Case 'presets only name existing tweaks and have names in every language' {
        $ids = @(Import-PcTweaks | ForEach-Object id)
        $languages = @(Get-ChildItem (Join-Path $root 'locales') -Filter *.json | ForEach-Object BaseName)
        foreach ($p in @(Read-PcJson (Join-Path $root 'data\presets.json'))) {
            foreach ($lang in $languages) { Assert-True ($p.name.$lang) "preset $($p.id) name in $lang" }
            $unknown = @(@($p.tweaks) | Where-Object { $ids -notcontains $_ })
            Assert-True ($unknown.Count -eq 0) "preset $($p.id) unknown tweaks: $($unknown -join ', ')"
        }
    }

    Test-Case 'the version is one semantic version and every About link is https' {
        Assert-True ($script:PcVersion -match '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$') "version '$script:PcVersion'"
        foreach ($k in 'Repository', 'Issues', 'AuthorGitHub', 'AuthorLinkedIn') {
            Assert-True ($script:PcLinks[$k] -match '^https://[^\s"]+$') "$k link"
        }
    }

    Test-Case 'new-version check: versions are ordered like Semantic Versioning' {
        $order = '0.1.0-beta', '0.1.1-alpha', '0.1.1-beta', '0.1.1-beta.2', '0.1.1-beta.10', '0.1.1', '0.1.2-beta', '0.2.0', '1.0.0'
        for ($i = 0; $i -lt $order.Count; $i++) {
            for ($j = 0; $j -lt $order.Count; $j++) {
                $c = Compare-PcVersion (ConvertTo-PcVersion $order[$i]) (ConvertTo-PcVersion $order[$j])
                Assert-Equal ([Math]::Sign($i - $j)) $c "$($order[$i]) vs $($order[$j])"
            }
        }
        Assert-Equal 0 (Compare-PcVersion (ConvertTo-PcVersion 'v0.1.1-beta') (ConvertTo-PcVersion '0.1.1-beta')) 'a leading v'
        Assert-True (ConvertTo-PcVersion $script:PcVersion) 'the running version parses'
        # A tag ends up in a link, so anything but a plain version is refused
        foreach ($bad in 'v0.1', '0.1.1.1', 'v0.1.1-', 'v0.1.1-beta/../x', "v0.1.1`n", 'v0.1.1 ', ' v0.1.1', 'V0.1.1', 'vv0.1.1',
            'v0.1.1+build', 'v0.1.1-bet a', ('v0.1.' + [char]0x0663), '') {
            Assert-True (-not (ConvertTo-PcVersion $bad)) "'$bad' refused"
        }
    }

    Test-Case 'new-version check: picks the newest release above this one from the GitHub list' {
        $list = ConvertTo-Json -Depth 3 @(
            @{ tag_name = 'v0.3.0-beta'; draft = $true; prerelease = $true }     # a draft is not out yet
            @{ tag_name = 'v0.2.1-beta'; draft = $false; prerelease = $true }
            @{ tag_name = 'v0.2.0'; draft = $false; prerelease = $false }
            @{ tag_name = 'v9.9.9/../../evil'; draft = $false; prerelease = $false }
            @{ tag_name = 'nightly'; draft = $false; prerelease = $true }
            @{ tag_name = 5; draft = $false; prerelease = $false }
            @{ tag_name = 'v0.1.1-beta'; draft = $false; prerelease = $true }
        )
        $found = Find-PcNewerRelease -Json $list -Current '0.1.1-beta'
        Assert-Equal '0.2.1-beta' $found.Version 'a beta hears about the newest beta'
        Assert-Equal "$($script:PcLinks.Repository)/releases/tag/v0.2.1-beta" $found.Url 'the link is built from the repository address'
        Assert-Equal '0.2.0' (Find-PcNewerRelease -Json $list -Current '0.1.1').Version 'a release only hears about releases'
        Assert-True (-not (Find-PcNewerRelease -Json $list -Current '0.2.1-beta')) 'already the newest'
        Assert-True (-not (Find-PcNewerRelease -Json $list -Current '0.3.0-dev')) 'a build ahead of every release'
        Assert-True (-not (Find-PcNewerRelease -Json $list -Current 'dev')) 'a running version that does not parse'
        Assert-True (-not (Find-PcNewerRelease -Json '[]' -Current '0.1.1-beta')) 'no releases'
        Assert-Equal '0.2.0' (Find-PcNewerRelease -Json '[{"tag_name":"v0.2.0"}]' -Current '0.1.1-beta').Version 'a list of one'
        # Anything but the list (a proxy's empty page, an error object) is an error, never "up to date"
        foreach ($odd in '<html>rate limited</html>', '', 'null', '{"message":"Not Found"}', '{"tag_name":"v0.2.0"}', '[{"name":"x"}]') {
            $threw = $false
            try { [void](Find-PcNewerRelease -Json $odd -Current '0.1.1-beta') } catch { $threw = $true }
            Assert-True $threw "'$odd' is an error"
        }
        # The window sends only this function's body to the background runspace
        $body = [scriptblock]::Create(${function:Get-PcReleaseList}.ToString())
        Assert-True (@($body.Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) -contains 'Url') 'the URL parameter survives in the body'
        # Between checks the window keeps a tag in the preferences; it goes through the same filter
        Assert-Equal '0.2.0' (Select-PcNewerRelease -Tags 'v0.2.0' -Current '0.1.1-beta').Version 'saved tag'
        Assert-True (-not (Select-PcNewerRelease -Tags 'javascript:alert(1)' -Current '0.1.1-beta')) 'a tampered saved tag'
    }

    Test-Case 'the Pix code follows the Banco Central format and the QR picture is up to date' {
        # The example from the Pix manual (BR Code, static QR), CRC included
        $example = '00020126580014br.gov.bcb.pix0136123e4567-e12b-12d1-a456-4266554400005204000053039865802BR5913Fulano de Tal6008BRASILIA62070503***63041D3D'
        Assert-Equal $example (Get-PcPixPayload -Key '123e4567-e12b-12d1-a456-426655440000' -Name 'Fulano de Tal' -City 'BRASILIA') 'manual example'
        $d = $script:PcDonation
        Assert-True ($d.PixName -match '^[A-Za-z ]{1,25}$' -and $d.PixCity -match '^[A-Za-z ]{1,15}$') 'name and city fit the Pix limits'
        $payload = Get-PcPixPayload
        Assert-True ($payload.Contains($d.PixKey)) 'the key is in the code'
        # Build-PixQr.ps1 writes the text it drew next to the picture
        Assert-Equal $payload ([IO.File]::ReadAllText((Join-Path $root 'assets\pix-qr.txt')).Trim()) 'assets\pix-qr.png was drawn from the current Pix data (run tools\Build-PixQr.ps1)'
        Assert-True (Test-Path (Join-Path $root 'assets\pix-qr.png')) 'QR picture'
        if (-not ('PitCrew.QrCode' -as [type])) { Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $root 'tools\QrCode.cs'))) }
        # Error correction of the textbook "HELLO WORLD" 1-M example
        $hello = [byte[]](32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17)
        Assert-Equal '196 35 39 119 235 215 231 226 93 23' (([PitCrew.QrCode]::ReedSolomon($hello, 10)) -join ' ') 'Reed-Solomon'
        Assert-Equal '5412 5125 5E7C 5B4B 45F9 40CE 4F97 4AA0' ((0..7 | ForEach-Object { '{0:X4}' -f [PitCrew.QrCode]::FormatBits($_) }) -join ' ') 'format bits, level M'
    }

    Test-Case 'every theme color is swappable: palettes match and nothing is hard-coded' {
        . (Join-Path $root 'src\UI\Window.ps1')
        $themeXaml = [IO.File]::ReadAllText((Join-Path $root 'src\UI\Theme.xaml'))
        $defaults = @{}
        foreach ($m in [regex]::Matches($themeXaml, '<SolidColorBrush x:Key="(\w+)" Color="(#[0-9A-Fa-f]{6})"/>')) { $defaults[$m.Groups[1].Value] = $m.Groups[2].Value }
        $light = $script:PcPalettes.light
        $dark = $script:PcPalettes.dark
        Assert-Equal (@($defaults.Keys | Sort-Object) -join ',') (@($light.Keys | Sort-Object) -join ',') 'Theme.xaml and the light palette name the same colors'
        Assert-Equal (@($light.Keys | Sort-Object) -join ',') (@($dark.Keys | Sort-Object) -join ',') 'light and dark name the same colors'
        foreach ($k in $light.Keys) { Assert-Equal $defaults[$k].ToUpperInvariant() $light[$k].ToUpperInvariant() "light $k matches Theme.xaml" }
        # Outside the palette, colors must be DynamicResource: a StaticResource or a literal never follows the theme
        $windowCode = [IO.File]::ReadAllText((Join-Path $root 'src\UI\Window.ps1'))
        $xamlParts = @([IO.File]::ReadAllText((Join-Path $root 'src\UI\Window.xaml'))) + @([regex]::Matches($windowCode, "(?s)@'\s*(<Window.*?)'@") | ForEach-Object { $_.Groups[1].Value })
        $themeStyles = $themeXaml -replace '<SolidColorBrush x:Key="\w+" Color="#[0-9A-Fa-f]{6}"/>', ''
        foreach ($x in $xamlParts + $themeStyles) {
            $literal = [regex]::Match($x, '"#[0-9A-Fa-f]{6,8}"')
            Assert-True (-not $literal.Success) "hard-coded color $($literal.Value)"
            foreach ($k in $light.Keys) { Assert-True ($x -notmatch "StaticResource $k\}") "StaticResource $k" }
        }
    }

    Test-Case 'memory page groups processes per program and never offers to close Windows or PitCrew' {
        $samples = @(
            [pscustomobject]@{ Name = 'chrome'; IDProcess = 100; WorkingSetPrivate = 300MB }
            [pscustomobject]@{ Name = 'chrome#1'; IDProcess = 101; WorkingSetPrivate = 200MB }
            [pscustomobject]@{ Name = 'svchost'; IDProcess = 200; WorkingSetPrivate = 900MB }
            [pscustomobject]@{ Name = 'notepad'; IDProcess = 300; WorkingSetPrivate = 10MB }
            [pscustomobject]@{ Name = 'helper'; IDProcess = 400; WorkingSetPrivate = 50MB }
            [pscustomobject]@{ Name = 'powershell'; IDProcess = 500; WorkingSetPrivate = 80MB }
            [pscustomobject]@{ Name = '_Total'; IDProcess = 0; WorkingSetPrivate = 9GB }
        )
        $groups = @(ConvertTo-PcMemoryGroups -Samples $samples -WindowIds @(101, 200, 300, 500) -Descriptions @{ 100 = 'Google Chrome' } -Keys @{ 101 = '101|638000000000000000' } -SelfId 300)
        Assert-Equal 'svchost,chrome,powershell,helper,notepad' (($groups | ForEach-Object Name) -join ',') 'one line per program, largest first, no _Total'
        $chrome = $groups | Where-Object Name -eq 'chrome'
        Assert-Equal 'Google Chrome' $chrome.DisplayName 'friendly name'
        Assert-Equal 2 $chrome.Count 'two processes'
        Assert-Equal ([int64]500MB) $chrome.Bytes 'memory summed'
        Assert-Equal '101' (@($chrome.WindowIds) -join ',') 'only the process with a window is asked to close'
        Assert-Equal '101|638000000000000000' (@($chrome.WindowKeys) -join ',') 'closing is keyed by PID and start time'
        Assert-Equal 0 (Close-PcProcessWindows -Keys @("$PID|1", 'not-a-key')) 'a stale or malformed key closes nothing'
        Assert-True ((Get-PcText 'memory.closeDone' -FormatArgs 0) -notlike '*{0}*') 'a count of 0 is still filled in'
        Assert-True $chrome.Closable 'a program with a window can be closed'
        Assert-True (-not ($groups | Where-Object Name -eq 'svchost').Closable) 'Windows services never'
        Assert-True (-not ($groups | Where-Object Name -eq 'powershell').Closable) 'consoles never'
        Assert-True (-not ($groups | Where-Object Name -eq 'helper').Closable) 'nothing without a window'
        Assert-True (-not ($groups | Where-Object Name -eq 'notepad').Closable) 'never PitCrew itself'
        Assert-Equal 2 @(ConvertTo-PcMemoryGroups -Samples $samples -WindowIds @() -Top 2).Count 'top N'
    }

    Test-Case 'the icon has every size Windows asks for and each frame is well formed' {
        $b = [IO.File]::ReadAllBytes((Join-Path $root 'assets\pitcrew.ico'))
        Assert-Equal 1 ([BitConverter]::ToUInt16($b, 2)) 'ICO type'
        $sizes = @()
        for ($i = 0; $i -lt [BitConverter]::ToUInt16($b, 4); $i++) {
            $e = 6 + 16 * $i
            $size = if ($b[$e] -eq 0) { 256 } else { [int]$b[$e] }
            $length = [BitConverter]::ToInt32($b, $e + 8)
            $offset = [BitConverter]::ToInt32($b, $e + 12)
            Assert-True ($offset + $length -le $b.Length) "$size px frame inside the file"
            if ($b[$offset] -eq 0x89 -and $b[$offset + 1] -eq 0x50) { Assert-Equal 256 $size 'only the 256 px frame is PNG' }
            else {
                # Bitmap frames: the height counts the color image and the AND mask together
                Assert-Equal $size ([BitConverter]::ToInt32($b, $offset + 4)) "$size px width"
                Assert-Equal (2 * $size) ([BitConverter]::ToInt32($b, $offset + 8)) "$size px height"
                Assert-Equal 32 ([int][BitConverter]::ToUInt16($b, $offset + 14)) "$size px bits"
                $maskRow = [int][Math]::Ceiling($size / 32) * 4
                Assert-Equal (40 + $size * $size * 4 + $maskRow * $size) $length "$size px frame length"
            }
            $sizes += $size
        }
        foreach ($s in 16, 20, 24, 32, 40, 48, 64, 256) { Assert-True ($sizes -contains $s) "$s px frame" }
    }

    Test-Case 'launcher tests pass (tests\Launcher-Tests.ps1)' {
        $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Launcher-Tests.ps1') 2>&1
        Assert-Equal 0 $LASTEXITCODE ("launcher tests failed:`n" + (($out | Select-String 'FAIL' -CaseSensitive -Context 0, 1) -join "`n"))
        $skipped = @($out | Select-String '^\s+skip\s')
        if ($skipped) {
            Write-Host "        $($skipped.Count) launcher checks skipped: Windows blocked the newly built exe here (Smart App Control). Run them in Windows Sandbox." -ForegroundColor Yellow
        }
    }

    Test-Case 'installer tests pass (tests\Setup-Tests.ps1)' {
        $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Setup-Tests.ps1') 2>&1
        Assert-Equal 0 $LASTEXITCODE ("installer tests failed:`n" + (($out | Select-String 'FAIL' -CaseSensitive -Context 0, 1) -join "`n"))
        # Whether the real install (GitHub-hosted runners only) ran or was skipped, so a build log shows it
        foreach ($line in @($out | Select-String '^\s+(ok|skip)\s+a real install')) {
            Write-Host "        installer: $($line.Line.Trim())" -ForegroundColor DarkGray
        }
    }

    Test-Case 'every .ps1 file is saved as UTF-8 with BOM (needed by Windows PowerShell 5.1)' {
        $bad = @(Get-ChildItem $root -Recurse -Filter *.ps1 | Where-Object {
            $b = [IO.File]::ReadAllBytes($_.FullName)
            -not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
        } | ForEach-Object Name)
        Assert-True ($bad.Count -eq 0) "without BOM: $($bad -join ', ')"
    }
} finally {
    Remove-Item -LiteralPath $testKey -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem 'HKCU:\Software\PitCrewTest' -ErrorAction SilentlyContinue)) {
        Remove-Item 'HKCU:\Software\PitCrewTest' -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $testData -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("`n{0} passed, {1} failed" -f $script:Passed, $script:Failures.Count) -ForegroundColor $(if ($script:Failures.Count) { 'Red' } else { 'Green' })
exit $script:Failures.Count

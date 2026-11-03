<#
.SYNOPSIS
    PitCrew tests. No dependencies: runs on the Windows PowerShell 5.1 that ships with Windows.

.DESCRIPTION
    Engine tests write only under HKCU:\Software\PitCrewTest\<random> (deleted at the end) and keep
    the undo journal in a temp folder. Nothing touches real Windows settings. Exit code = failures.
#>
$ErrorActionPreference = 'Stop'
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

function New-TestTweak([string]$Id, [object[]]$Actions, [string]$Scope = 'machine', $AppliesTo) {
    [pscustomobject]@{
        id = $Id; risk = 'safe'; scope = $Scope; appliesTo = $AppliesTo
        title = [pscustomobject]@{ en = $Id }; description = [pscustomobject]@{ en = $Id }
        actions = $Actions
    }
}

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
        Invoke-PcTweak $t
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
        Invoke-PcTweak $t
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
        Invoke-PcTweak $t
        [void](Set-PcRegistryValue 'HKCU:\Software\PcC' 'V' 'DWord' 42)
        $r = Undo-PcTweak $t
        Assert-Equal 1 $r.Skipped 'skipped'
        Assert-Equal 42 (Get-PcRegistryValue 'HKCU:\Software\PcC' 'V').Data 'user value kept'
    }

    Test-Case 'applying twice keeps the first snapshot' {
        [void](Set-PcRegistryValue 'HKLM:\SOFTWARE\PcD' 'V' 'DWord' 3)
        $t = New-TestTweak 't.twice' @(New-RegAction 'HKLM:\SOFTWARE\PcD' 'V' 'DWord' 9)
        Invoke-PcTweak $t
        Invoke-PcTweak $t
        [void](Undo-PcTweak $t)
        Assert-Equal 3 (Get-PcRegistryValue 'HKLM:\SOFTWARE\PcD' 'V').Data 'original value'
    }

    Test-Case 'a failing action rolls back the ones before it' {
        $t = New-TestTweak 't.rollback' @(
            (New-RegAction 'HKLM:\SOFTWARE\PcE' 'Good' 'DWord' 1),
            (New-RegAction 'HKLM:\SOFTWARE\PcE' 'Bad' 'NoSuchKind' 1))
        $threw = $false
        try { Invoke-PcTweak $t } catch { $threw = $true }
        Assert-True $threw 'apply threw'
        Assert-True (-not (Get-PcRegistryValue 'HKLM:\SOFTWARE\PcE' 'Good').Exists) 'first action rolled back'
        Assert-True (-not (Get-PcJournalEntry $t)) 'no journal entry'
    }

    Test-Case 'an "absent" action deletes a value and undo brings it back' {
        [void](Set-PcRegistryValue 'HKLM:\SOFTWARE\PcF' 'Gone' 'String' 'keep me')
        $t = New-TestTweak 't.absent' @(New-RegAction 'HKLM:\SOFTWARE\PcF' 'Gone' -Absent)
        Invoke-PcTweak $t
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
        Invoke-PcTweak $t
        [void](Undo-PcTweak $t)
        Assert-Equal ([uint32]4294967295) (Get-PcRegistryValue 'HKLM:\SOFTWARE\PcG' 'Big').Data 'big dword'
        $multi = Get-PcRegistryValue 'HKLM:\SOFTWARE\PcG' 'Multi'
        Assert-Equal 'MultiString' $multi.Kind 'multi kind'
        Assert-Equal @('only') $multi.Data 'multi data'
    }

    Test-Case 'user-scope journal entries are per user' {
        $t = New-TestTweak 't.user' @(New-RegAction 'HKCU:\Software\PcH' 'V') 'user'
        Assert-Equal ('t.user@' + (Get-PcCurrentUserSid)) (Get-PcJournalKey $t) 'journal key'
    }

    Test-Case 'a tweak for another Windows build is not applicable and cannot be applied' {
        $t = New-TestTweak 't.future' @(New-RegAction 'HKLM:\SOFTWARE\PcI' 'V') 'machine' ([pscustomobject]@{ minBuild = 999999 })
        Assert-Equal 'NotApplicable' (Get-PcTweakState $t) 'state'
        $threw = $false
        try { Invoke-PcTweak $t } catch { $threw = $true }
        Assert-True $threw 'apply refused'
    }

    Test-Case 'applying a tweak that is already in place records nothing to undo' {
        [void](Set-PcRegistryValue 'HKLM:\SOFTWARE\PcK' 'V' 'DWord' 1)
        $t = New-TestTweak 't.already' @(New-RegAction 'HKLM:\SOFTWARE\PcK' 'V' 'DWord' 1)
        Invoke-PcTweak $t
        Assert-True (-not (Get-PcJournalEntry $t)) 'no journal entry'
    }

    Test-Case 'undo ignores a tampered path or key list in the journal' {
        [void](Set-PcRegistryValue 'HKLM:\SOFTWARE\PcVictim' 'Keep' 'DWord' 1)
        New-Item -Path "$testKey\HKLM\SOFTWARE\PcVictimEmpty" -Force | Out-Null
        $t = New-TestTweak 't.tamper' @(New-RegAction 'HKLM:\SOFTWARE\PcJ' 'V' 'DWord' 1)
        Invoke-PcTweak $t
        $entries = @(Get-PcJournal)
        foreach ($e in $entries | Where-Object tweakId -eq 't.tamper') {
            $e.actions[0].path = 'HKLM:\SOFTWARE\PcVictim'
            $e.actions[0].name = 'Keep'
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

    Write-Host "`nCleanup" -ForegroundColor Cyan

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
        Assert-True (-not (Test-Path (Join-Path $target 'inner'))) 'emptied folder removed'
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
        foreach ($t in $tweaks) {
            Assert-True ($t.id -is [string]) 'tweak id is a single string'
            Assert-True ($t.category -is [string]) "$($t.id) category"
            Assert-True (@('safe', 'moderate', 'advanced') -contains $t.risk) "$($t.id) risk"
            Assert-True (@('machine', 'user') -contains $t.scope) "$($t.id) scope"
            Assert-True ($t.reference -match '^https://') "$($t.id) reference"
            Assert-True ($t.title.en -and $t.title.'pt-BR' -and $t.description.en -and $t.description.'pt-BR') "$($t.id) en/pt-BR texts"
            foreach ($a in @($t.actions)) {
                Assert-Equal 'registry' $a.type "$($t.id) action type"
                Assert-True ($a.path -match '^HK(LM|CU):\\') "$($t.id) path"
                if ($a.path -like 'HKCU:*') { Assert-Equal 'user' $t.scope "$($t.id) HKCU action needs user scope" }
                else { Assert-Equal 'machine' $t.scope "$($t.id) HKLM action needs machine scope" }
                if (-not $a.absent) { Assert-True ($script:PcRegistryKinds -contains $a.kind) "$($t.id) kind" }
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

    Test-Case 'every text key used in the code exists in English' {
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
        foreach ($p in 'performance', 'privacy', 'cleanup', 'apps', 'drivers', 'about') { $used += "page.$p.title", "page.$p.intro", "nav.$p" }
        foreach ($c in $script:PcCleanupTargets) { $used += "cleanup.$($c.Id).detail" }
        $missing = @($used | Sort-Object -Unique | Where-Object { $en -notcontains $_ })
        Assert-True ($missing.Count -eq 0) "missing in en.json: $($missing -join ', ')"
    }

    Test-Case 'app catalog has valid Store IDs and no protected package' {
        $apps = @(Read-PcJson (Join-Path $root 'data\apps.json'))
        Assert-True ($apps.Count -gt 1) 'apps are read as separate items'
        Assert-Equal $apps.Count @(Get-PcAppCatalog).Count 'catalog keeps every app'
        foreach ($app in $apps) {
            Assert-True ($app.package -is [string]) 'package is a single string'
            Assert-True ($app.storeId -match '^[0-9A-Z]{12}$') "$($app.package) store id"
            Assert-True (-not (Test-PcProtectedPackage $app.package)) "$($app.package) is protected"
            Assert-True ($app.name.en -and $app.name.'pt-BR') "$($app.package) names"
        }
        Assert-True (Test-PcProtectedPackage 'Microsoft.DesktopAppInstaller') 'winget is protected'
        Assert-True (Test-PcProtectedPackage 'Microsoft.VCLibs.140.00') 'frameworks are protected'
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

# Declarative tweaks: tweaks/<category>.json holds an array of entries such as
#
#   { "id": "privacy.advertising-id", "risk": "safe", "scope": "machine", "evidence": "learn",
#     "reference": "https://learn.microsoft.com/...",
#     "title": { "en": "...", "pt-BR": "..." }, "description": { ... },
#     "actions": [ { "type": "registry", "path": "HKLM:\\...", "name": "X", "kind": "DWord", "value": 1 } ] }
#
# Action types live in Actions.ps1. Before an action runs, its previous state goes to the undo
# journal. Undo restores that state, but only where the current state is still the one PitCrew
# set; anything changed later is left alone. Actions whose target doesn't exist on this PC (a
# removed service or task) are skipped everywhere.

$script:PcTweakStates = @('Applied', 'NotApplied', 'Partial', 'NotApplicable', 'Error')
$script:PcEvidenceLevels = @('learn', 'vendor', 'community')
$script:PcEditionFamilies = @('home', 'pro', 'enterprise', 'education')
$script:PcFormFactors = @('desktop', 'laptop')

function Import-PcTweaks {
    $ids = @{}
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Pc.Root 'tweaks') -Filter '*.json' | Sort-Object Name) {
        foreach ($t in @(Read-PcJson $file.FullName)) {
            foreach ($field in 'id', 'risk', 'scope', 'evidence', 'reference', 'title', 'description', 'actions') {
                if (-not $t.$field) { throw "$($file.Name): tweak '$($t.id)' has no '$field'" }
            }
            if ($ids.ContainsKey($t.id)) { throw "$($file.Name): duplicate tweak id '$($t.id)'" }
            $ids[$t.id] = $true
            if (-not $t.PSObject.Properties['category']) {
                $t | Add-Member -NotePropertyName category -NotePropertyValue $file.BaseName
            }
            $t
        }
    }
}

# --- Where a tweak applies ------------------------------------------------------------------------

function Get-PcEditionFamily {
    # Exact EditionIDs vary (CoreSingleLanguage, ProfessionalN, EnterpriseS...); tweaks use families
    $id = (Get-PcWindowsInfo).Edition
    if ($id -like 'Core*') { return 'home' }
    if ($id -like 'Education*') { return 'education' }
    if ($id -like 'Enterprise*' -or $id -like 'IoTEnterprise*') { return 'enterprise' }
    if ($id -like 'Professional*') { return 'pro' }
    return 'other'
}

function Get-PcFormFactor {
    if ($Pc.FormFactor) { return $Pc.FormFactor }
    # Chassis type decides; a battery alone could be a USB UPS on a desktop
    $laptopChassis = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $chassis = @(Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue | ForEach-Object { $_.ChassisTypes } | Where-Object { $_ })
    $isLaptop = @($chassis | Where-Object { $laptopChassis -contains [int]$_ }).Count -gt 0
    if (-not $isLaptop -and @($chassis | Where-Object { @(1, 2) -notcontains [int]$_ }).Count -eq 0) {
        # Unknown chassis: fall back to "has a battery"
        $isLaptop = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0
    }
    $Pc.FormFactor = if ($isLaptop) { 'laptop' } else { 'desktop' }
    return $Pc.FormFactor
}

function Test-PcTweakApplicable($Tweak) {
    $rules = $Tweak.appliesTo
    if (-not $rules) { return $true }
    $win = Get-PcWindowsInfo
    if ($rules.minBuild -and $win.Build -lt [int]$rules.minBuild) { return $false }
    if ($rules.maxBuild -and $win.Build -gt [int]$rules.maxBuild) { return $false }
    if ($rules.editions -and @($rules.editions) -notcontains (Get-PcEditionFamily)) { return $false }
    if ($rules.formFactor -and $rules.formFactor -ne (Get-PcFormFactor)) { return $false }
    return $true
}

# --- Action dispatch ------------------------------------------------------------------------------

function Test-PcActionAvailable($Action) {
    $fn = "Test-Pc$(Get-PcActionNoun $Action.type)ActionAvailable"
    if (Get-Command $fn -ErrorAction SilentlyContinue) { return [bool](& $fn $Action) }
    return $true
}

function Test-PcActionApplied($Action) {
    return [bool](& "Test-Pc$(Get-PcActionNoun $Action.type)ActionApplied" $Action)
}

function Invoke-PcAction($Action) {
    $record = & "Invoke-Pc$(Get-PcActionNoun $Action.type)Action" $Action
    $record | Add-Member -NotePropertyName type -NotePropertyValue $Action.type -Force
    return $record
}

function Undo-PcAction($Action, $Record, [switch]$Force) {
    # Returns $true when restored, $false when skipped because something changed it since
    if (-not $Force -and -not (Test-PcActionApplied $Action)) { return $false }
    & "Undo-Pc$(Get-PcActionNoun $Action.type)Action" $Action $Record
    return $true
}

function Get-PcAvailableActions($Tweak) {
    # Index matters: journal records point at the action's position in the catalog
    $actions = @($Tweak.actions)
    for ($i = 0; $i -lt $actions.Count; $i++) {
        if (Test-PcActionAvailable $actions[$i]) { [pscustomobject]@{ Index = $i; Action = $actions[$i] } }
    }
}

# --- Journal --------------------------------------------------------------------------------------

# Reading must not create the data folder: a folder first created by a standard user would be
# owned by that user, who could then edit what an administrator's Undo reads
function Get-PcJournalPath { Join-Path $Pc.DataDir 'journal.json' }

function Get-PcJournalKey($Tweak) {
    # HKCU differs per user, so user-scope entries are kept per SID
    if ($Tweak.scope -eq 'user') { return '{0}@{1}' -f $Tweak.id, (Get-PcCurrentUserSid) }
    return $Tweak.id
}

function Get-PcJournal([switch]$Strict) {
    # -Strict is for apply and undo: a journal that can't be read must stop them, not be
    # overwritten as if it were empty. Display code just shows nothing.
    $path = Get-PcJournalPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        return @((Read-PcJson $path).entries)
    } catch {
        Write-PcLog "Journal unreadable: $($_.Exception.Message)" 'Error'
        if ($Strict) { throw (Get-PcText 'error.journalUnreadable') }
        return @()
    }
}

function Save-PcJournal([object[]]$Entries) {
    [void](Get-PcDataPath '')
    Write-PcJson (Get-PcJournalPath) ([pscustomobject]@{ version = 1; entries = @($Entries) })
}

function Get-PcJournalEntry($Tweak) {
    $key = Get-PcJournalKey $Tweak
    Get-PcJournal | Where-Object { $_.key -eq $key } | Select-Object -First 1
}

function Get-PcMyJournalEntries {
    # Machine entries plus this user's own; other users' HKCU entries aren't theirs to undo
    $sid = Get-PcCurrentUserSid
    Get-PcJournal | Where-Object { $_.key -notlike '*@*' -or $_.key -like "*@$sid" }
}

function Get-PcActionTarget($Action) {
    # Fingerprint of what an action touches. A journal record is only used for the action with the
    # same target, so a catalog update that moves or changes actions can't mix up snapshots.
    switch ($Action.type) {
        'registry'      { '{0}|{1}' -f $Action.path, $Action.name }
        'dxSetting'     { $Action.key }
        'service'       { $Action.name }
        'scheduledTask' { '{0}{1}' -f $Action.path, $Action.name }
        'powerPlan'     { $Action.guid.ToLowerInvariant() }
        'hibernation'   { 'hibernation' }
    }
}

function Test-PcRecordMatches($Action, $Record) {
    if (-not $Action -or $Action.type -ne $Record.type) { return $false }
    return $Record.target -eq (Get-PcActionTarget $Action)
}

# --- Tweak operations -----------------------------------------------------------------------------

function Get-PcTweakState($Tweak) {
    if (-not (Test-PcTweakApplicable $Tweak)) { return 'NotApplicable' }
    try {
        $available = @(Get-PcAvailableActions $Tweak)
        if ($available.Count -eq 0) { return 'NotApplicable' }
        $applied = @($available | Where-Object { Test-PcActionApplied $_.Action }).Count
    } catch {
        Write-PcLog "State of $($Tweak.id): $($_.Exception.Message)" 'Warn'
        return 'Error'
    }
    if ($applied -eq 0) { return 'NotApplied' }
    if ($applied -eq $available.Count) { return 'Applied' }
    return 'Partial'
}

function Assert-PcCanChange($Tweak, [switch]$ForUndo) {
    # Undo stays possible after an edition upgrade or a new build made the tweak "not applicable"
    if (-not $ForUndo -and -not (Test-PcTweakApplicable $Tweak)) { throw (Get-PcText 'error.notApplicable') }
    if ($Pc.RegistryRedirect) { return }
    if ($Tweak.scope -eq 'machine' -and -not (Test-PcAdmin)) { throw (Get-PcText 'error.needsAdmin') }
    if ($Tweak.scope -eq 'user' -and (Test-PcUserMismatch)) { throw (Get-PcText 'error.otherUser') }
    Assert-PcDataTrusted
}

function Invoke-PcTweakRefresh($Tweak) {
    # A refresh that fails doesn't undo anything: the change is made and recorded
    if (-not $Tweak.refresh) { return }
    try { Invoke-PcRefresh $Tweak.refresh } catch { Write-PcLog "Refresh '$($Tweak.refresh)' for $($Tweak.id): $($_.Exception.Message)" 'Warn' }
}

function Invoke-PcTweak($Tweak) {
    # Returns $true when something changed, $false when it was already in place
    Assert-PcCanChange $Tweak
    $entries = @(Get-PcJournal -Strict)
    $key = Get-PcJournalKey $Tweak
    $existing = $entries | Where-Object { $_.key -eq $key } | Select-Object -First 1
    $others = @($entries | Where-Object { $_.key -ne $key })

    # Two tweaks that own the same thing (both power plans, say) would undo each other's snapshot
    foreach ($otherId in @($Tweak.conflictsWith)) {
        if (-not $otherId) { continue }
        $owner = $others | Where-Object { $_.tweakId -eq $otherId } | Select-Object -First 1
        if ($owner) { throw (Get-PcText 'error.conflict' -FormatArgs $otherId) }
    }

    $state = Get-PcTweakState $Tweak
    if ($state -eq 'NotApplicable') { throw (Get-PcText 'error.notApplicable') }
    if (-not $existing -and $state -eq 'Applied') {
        # Already set by Windows, a policy or another tool: recording it would offer an Undo
        # that can only put back the same values
        Write-PcLog "Apply $($Tweak.id): already applied, nothing recorded"
        return $false
    }

    $actions = @($Tweak.actions)
    $fresh = New-Object System.Collections.Generic.List[object]     # what this call changed, for rollback
    $records = New-Object System.Collections.Generic.List[object]   # what goes to the journal
    try {
        foreach ($item in @(Get-PcAvailableActions $Tweak)) {
            $target = Get-PcActionTarget $item.Action
            $previous = $null
            if ($existing) {
                $previous = @($existing.actions) | Where-Object { $_.index -eq $item.Index -and (Test-PcRecordMatches $item.Action $_) } | Select-Object -First 1
            }
            $record = Invoke-PcAction $item.Action
            $record | Add-Member -NotePropertyName index -NotePropertyValue $item.Index -Force
            $record | Add-Member -NotePropertyName target -NotePropertyValue $target -Force
            $fresh.Add($record)

            # Applying twice must not lose the original state: the journal keeps the first snapshot
            $journalRecord = $record
            if ($previous) {
                $journalRecord = $record.PSObject.Copy()
                $journalRecord.before = $previous.before
                if ($previous.PSObject.Properties['createdKeys']) {
                    $journalRecord | Add-Member -NotePropertyName createdKeys -NotePropertyValue @($previous.createdKeys) -Force
                }
            }
            $records.Add($journalRecord)

            # Write-ahead: what is already changed is recorded before the next step, so a crash,
            # a kill or Ctrl+C still leaves an Undo for it
            $entry = [pscustomobject]@{
                key       = $key
                tweakId   = $Tweak.id
                appliedAt = (Get-Date).ToString('o')
                userSid   = Get-PcCurrentUserSid
                actions   = $records.ToArray()
            }
            Save-PcJournal ($others + $entry)
        }
    } catch {
        $err = $_
        # Leave nothing half-applied: put back what this call changed, using this call's own
        # snapshots (not the older ones kept for the journal)
        for ($j = $fresh.Count - 1; $j -ge 0; $j--) {
            try { [void](Undo-PcAction $actions[$fresh[$j].index] $fresh[$j] -Force) }
            catch { Write-PcLog "Rollback of $($Tweak.id) action $($fresh[$j].index) failed: $($_.Exception.Message)" 'Error' }
        }
        try { Save-PcJournal $entries } catch { Write-PcLog "Could not restore the journal after a failed apply: $($_.Exception.Message)" 'Error' }
        Invoke-PcTweakRefresh $Tweak
        Write-PcLog "Apply $($Tweak.id) failed and was rolled back: $($err.Exception.Message)" 'Error'
        throw $err
    }

    Invoke-PcTweakRefresh $Tweak
    Write-PcLog "Applied $($Tweak.id)"
    return $true
}

function Undo-PcTweak($Tweak, [switch]$Force) {
    Assert-PcCanChange $Tweak -ForUndo
    $entries = @(Get-PcJournal -Strict)
    $key = Get-PcJournalKey $Tweak
    $entry = $entries | Where-Object { $_.key -eq $key } | Select-Object -First 1
    if (-not $entry) { throw (Get-PcText 'error.notInJournal') }

    $actions = @($Tweak.actions)
    $skipped = 0
    $keep = New-Object System.Collections.Generic.List[object]   # records that stay in the journal
    foreach ($record in @($entry.actions) | Sort-Object index -Descending) {
        $index = [int]$record.index
        $action = $null
        if ($index -ge 0 -and $index -lt $actions.Count) { $action = $actions[$index] }
        # The catalog decides what an action is; a record that no longer matches it is ignored
        if (-not (Test-PcRecordMatches $action $record)) { $skipped++; continue }
        # Target missing right now (task deleted, service removed): keep the snapshot for later
        if (-not (Test-PcActionAvailable $action)) { $keep.Add($record); continue }
        try {
            if (-not (Undo-PcAction $action $record -Force:$Force)) {
                $skipped++
                Write-PcLog "Undo $($Tweak.id): action $index changed since PitCrew applied it; left as is" 'Warn'
            }
        } catch {
            # One failure doesn't stop the rest; the failed one stays in the journal to retry
            $keep.Add($record)
            Write-PcLog "Undo $($Tweak.id) action ${index}: $($_.Exception.Message)" 'Error'
        }
    }
    $others = @($entries | Where-Object { $_.key -ne $key })
    if ($keep.Count -gt 0) {
        $entry.actions = @($keep.ToArray() | Sort-Object index)
        Save-PcJournal ($others + $entry)
    } else {
        Save-PcJournal $others
    }
    Invoke-PcTweakRefresh $Tweak
    Write-PcLog "Undid $($Tweak.id) (skipped $skipped, kept $($keep.Count))"
    return [pscustomobject]@{ TweakId = $Tweak.id; Skipped = $skipped; Failed = $keep.Count }
}

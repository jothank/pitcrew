# Declarative tweaks: tweaks/<category>.json holds an array of entries such as
#
#   { "id": "privacy.advertising-id", "risk": "safe", "scope": "machine",
#     "reference": "https://learn.microsoft.com/...",
#     "title": { "en": "...", "pt-BR": "..." }, "description": { ... },
#     "actions": [ { "type": "registry", "path": "HKLM:\\...", "name": "X", "kind": "DWord", "value": 1 } ] }
#
# Before an action runs, its previous state goes to the undo journal. Undo restores that state, but
# only where the current value is still the one PitCrew wrote; anything changed later is left alone.

$script:PcTweakStates = @('Applied', 'NotApplied', 'Partial', 'NotApplicable', 'Error')

function Import-PcTweaks {
    $ids = @{}
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Pc.Root 'tweaks') -Filter '*.json' | Sort-Object Name) {
        foreach ($t in @(Read-PcJson $file.FullName)) {
            foreach ($field in 'id', 'risk', 'scope', 'title', 'description', 'actions') {
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

function Test-PcTweakApplicable($Tweak) {
    $rules = $Tweak.appliesTo
    if (-not $rules) { return $true }
    $win = Get-PcWindowsInfo
    if ($rules.minBuild -and $win.Build -lt [int]$rules.minBuild) { return $false }
    if ($rules.maxBuild -and $win.Build -gt [int]$rules.maxBuild) { return $false }
    if ($rules.editions -and @($rules.editions) -notcontains $win.Edition) { return $false }
    return $true
}

# --- Actions ------------------------------------------------------------------------------------

function Test-PcActionApplied($Action) {
    switch ($Action.type) {
        'registry' {
            $current = Get-PcRegistryValue $Action.path $Action.name
            if ($Action.absent) { return -not $current.Exists }
            return $current.Exists -and $current.Kind -eq $Action.kind -and
                (Test-PcRegistryDataEqual $Action.kind $current.Data $Action.value)
        }
        default { throw "Unsupported action type: $($Action.type)" }
    }
}

function Invoke-PcAction($Action) {
    switch ($Action.type) {
        'registry' {
            $before = Get-PcRegistryValue $Action.path $Action.name
            $createdKeys = @()
            if ($Action.absent) {
                Remove-PcRegistryValue $Action.path $Action.name
            } else {
                $createdKeys = Set-PcRegistryValue $Action.path $Action.name $Action.kind $Action.value
            }
            return [pscustomobject]@{
                type        = 'registry'
                path        = $Action.path
                name        = $Action.name
                before      = [pscustomobject]@{ exists = $before.Exists; kind = $before.Kind; data = $before.Data }
                createdKeys = @($createdKeys)
            }
        }
        default { throw "Unsupported action type: $($Action.type)" }
    }
}

function Get-PcAllowedCreatedKeys($Action, $Record) {
    # The journal sits in a folder other accounts may be able to write to, so a recorded key is only
    # removed if it is this action's own key or one of its parents
    $allowed = @()
    $probe = Resolve-PcRegistryPath $Action.path
    while ($probe) { $allowed += $probe; $probe = Split-Path $probe -Parent }
    @($Record.createdKeys) | Where-Object { $_ -and ($allowed -contains $_) }
}

function Undo-PcAction($Action, $Record, [switch]$Force) {
    # Returns $true when restored, $false when skipped because someone changed the value since.
    # Where to write always comes from the catalog ($Action); the journal only supplies the old value.
    if (-not $Force -and -not (Test-PcActionApplied $Action)) { return $false }
    switch ($Action.type) {
        'registry' {
            if ($Record.before.exists) {
                if ($script:PcRegistryKinds -notcontains $Record.before.kind) { throw "Journal has an invalid registry kind: $($Record.before.kind)" }
                [void](Set-PcRegistryValue $Action.path $Action.name $Record.before.kind $Record.before.data)
            } else {
                Remove-PcRegistryValue $Action.path $Action.name
            }
            $keys = @(Get-PcAllowedCreatedKeys $Action $Record)
            if ($keys.Count -gt 0) { Remove-PcEmptyKeys $keys }
            return $true
        }
        default { throw "Unsupported action type: $($Action.type)" }
    }
}

# --- Journal ------------------------------------------------------------------------------------

# Reading must not create the data folder: a folder first created by a standard user would be
# owned by that user, who could then edit what an administrator's Undo reads
function Get-PcJournalPath { Join-Path $Pc.DataDir 'journal.json' }

function Get-PcJournalKey($Tweak) {
    # HKCU differs per user, so user-scope entries are kept per SID
    if ($Tweak.scope -eq 'user') { return '{0}@{1}' -f $Tweak.id, (Get-PcCurrentUserSid) }
    return $Tweak.id
}

function Get-PcJournal {
    $path = Get-PcJournalPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @((Read-PcJson $path).entries)
}

function Save-PcJournal([object[]]$Entries) {
    [void](Get-PcDataPath '')
    Write-PcJson (Get-PcJournalPath) ([pscustomobject]@{ version = 1; entries = @($Entries) })
}

function Get-PcJournalEntry($Tweak) {
    $key = Get-PcJournalKey $Tweak
    Get-PcJournal | Where-Object { $_.key -eq $key } | Select-Object -First 1
}

# --- Tweak operations -----------------------------------------------------------------------------

function Get-PcTweakState($Tweak) {
    if (-not (Test-PcTweakApplicable $Tweak)) { return 'NotApplicable' }
    try {
        $applied = @(@($Tweak.actions) | Where-Object { Test-PcActionApplied $_ }).Count
    } catch {
        Write-PcLog "State of $($Tweak.id): $($_.Exception.Message)" 'Warn'
        return 'Error'
    }
    if ($applied -eq 0) { return 'NotApplied' }
    if ($applied -eq @($Tweak.actions).Count) { return 'Applied' }
    return 'Partial'
}

function Assert-PcCanChange($Tweak) {
    if (-not (Test-PcTweakApplicable $Tweak)) { throw (Get-PcText 'error.notApplicable') }
    if ($Pc.RegistryRedirect) { return }
    if ($Tweak.scope -eq 'machine' -and -not (Test-PcAdmin)) { throw (Get-PcText 'error.needsAdmin') }
    if ($Tweak.scope -eq 'user' -and (Test-PcUserMismatch)) { throw (Get-PcText 'error.otherUser') }
}

function Invoke-PcTweak($Tweak) {
    Assert-PcCanChange $Tweak
    $entries = @(Get-PcJournal)
    $key = Get-PcJournalKey $Tweak
    $existing = $entries | Where-Object { $_.key -eq $key } | Select-Object -First 1
    if (-not $existing -and (Get-PcTweakState $Tweak) -eq 'Applied') {
        # Already set by Windows, a policy or another tool: recording it would offer an Undo
        # that can only put back the same values
        Write-PcLog "Apply $($Tweak.id): already applied, nothing recorded"
        return
    }

    $records = New-Object System.Collections.Generic.List[object]
    $actions = @($Tweak.actions)
    try {
        for ($i = 0; $i -lt $actions.Count; $i++) {
            $previous = $null
            if ($existing) { $previous = @($existing.actions) | Where-Object { $_.index -eq $i } | Select-Object -First 1 }
            $record = Invoke-PcAction $actions[$i]
            # Applying twice must not lose the original value: keep the first snapshot taken
            if ($previous) { $record.before = $previous.before; $record.createdKeys = @($previous.createdKeys) }
            $record | Add-Member -NotePropertyName index -NotePropertyValue $i
            $records.Add($record)
        }
    } catch {
        $err = $_
        # Leave nothing half-applied: put back what this call already changed
        for ($j = $records.Count - 1; $j -ge 0; $j--) {
            try { [void](Undo-PcAction $actions[$records[$j].index] $records[$j] -Force) } catch { }
        }
        Write-PcLog "Apply $($Tweak.id) failed and was rolled back: $($err.Exception.Message)" 'Error'
        throw $err
    }

    $entry = [pscustomobject]@{
        key       = $key
        tweakId   = $Tweak.id
        appliedAt = (Get-Date).ToString('o')
        userSid   = Get-PcCurrentUserSid
        actions   = $records.ToArray()
    }
    Save-PcJournal (@($entries | Where-Object { $_.key -ne $key }) + $entry)
    Write-PcLog "Applied $($Tweak.id)"
}

function Undo-PcTweak($Tweak, [switch]$Force) {
    Assert-PcCanChange $Tweak
    $entries = @(Get-PcJournal)
    $key = Get-PcJournalKey $Tweak
    $entry = $entries | Where-Object { $_.key -eq $key } | Select-Object -First 1
    if (-not $entry) { throw (Get-PcText 'error.notInJournal') }

    $actions = @($Tweak.actions)
    $skipped = 0
    foreach ($record in @($entry.actions) | Sort-Object index -Descending) {
        $index = [int]$record.index
        if ($index -lt 0 -or $index -ge $actions.Count) { $skipped++; continue }
        if (-not (Undo-PcAction $actions[$index] $record -Force:$Force)) {
            $skipped++
            Write-PcLog "Undo $($Tweak.id): action $($record.index) changed since PitCrew applied it; left as is" 'Warn'
        }
    }
    Save-PcJournal @($entries | Where-Object { $_.key -ne $key })
    Write-PcLog "Undid $($Tweak.id) (skipped $skipped)"
    return [pscustomobject]@{ TweakId = $Tweak.id; Skipped = $skipped }
}

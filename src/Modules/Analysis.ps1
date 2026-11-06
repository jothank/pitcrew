# Automatic analysis: from the profiles the user picks (data/presets.json), what PitCrew would
# change, clean, remove and take out of startup, each shown for review with how it can be undone.
# Only what is safe and can be undone comes ticked; the rest is listed for the user to decide.
# Nothing here decides on its own: Get-PcAnalysis only reads, and Invoke-PcRecommendations runs
# exactly the ids it is given, after the user has reviewed them and confirmed.

# The order the areas are shown and applied in
$script:PcAnalysisAreas = @('tweak', 'cleanup', 'app', 'startup')

function Get-PcPresets { @(Read-PcJson (Join-Path $Pc.Root 'data\presets.json')) }

function Get-PcAnalysis {
    param([string[]]$ProfileIds, $Sync)
    $presets = @(Get-PcPresets | Where-Object { $ProfileIds -contains $_.id })
    $catalog = @(Import-PcTweaks)
    $failed = New-Object System.Collections.Generic.List[string]
    $read = {
        param([string]$Area, [scriptblock]$Body)
        try { & $Body } catch { Write-PcLog "Analysis: $Area not read: $($_.Exception.Message)" 'Warn'; $failed.Add($Area) }
    }

    # States only for the tweaks the profiles name, and for their alternatives (conflictsWith)
    $states = @{}
    & $read 'tweak' {
        $ids = @($presets | ForEach-Object { @($_.tweaks) }) | Select-Object -Unique
        $ids = @($ids) + @($catalog | Where-Object { $ids -contains $_.id } | ForEach-Object { @($_.conflictsWith) } | Where-Object { $_ }) | Select-Object -Unique
        $i = 0
        foreach ($id in $ids) {
            $i++
            $t = $catalog | Where-Object { $_.id -eq $id } | Select-Object -First 1
            if (-not $t) { continue }
            if ($Sync) { $Sync.Status = Get-PcText 'analysis.step.tweaks' -FormatArgs $i, @($ids).Count }
            $states[$id] = Get-PcTweakState $t
        }
    }
    # The engine refuses a tweak while its alternative is in the journal, applied now or not
    $recorded = @(Get-PcJournal | ForEach-Object { [string]$_.tweakId })
    if ($Sync) { $Sync.Status = Get-PcText 'analysis.step.cleanup' }
    $cleanup = @(& $read 'cleanup' { Get-PcCleanupTargets })
    if ($Sync) { $Sync.Status = Get-PcText 'analysis.step.apps' }
    $apps = @(& $read 'app' { Get-PcRemovableApps })
    $startup = @(& $read 'startup' { Get-PcStartupItems })

    [pscustomobject]@{
        Items  = @(ConvertTo-PcRecommendations -Catalog $catalog -Presets $presets -States $states -Recorded $recorded -Cleanup $cleanup -Apps $apps -Startup $startup)
        Failed = @($failed)
    }
}

function New-PcRecommendation([hashtable]$Values) {
    $r = [ordered]@{ Area = ''; Id = ''; Title = ''; Detail = ''; Category = ''; Risk = 'safe'; Ticked = $false; Enabled = $true
        Undo = 'none'; Profiles = @(); Bytes = [int64]0; Files = 0; BlockedKey = $null; Requires = $null; Reference = $null; Evidence = $null; Source = ''; Publisher = '' }
    foreach ($k in $Values.Keys) { $r[$k] = $Values[$k] }
    [pscustomobject]$r
}

function ConvertTo-PcRecommendations {
    # Everything the analysis read, turned into the list to review. No system access here.
    param([object[]]$Catalog, [object[]]$Presets, [hashtable]$States, [string[]]$Recorded = @(), [object[]]$Cleanup, [object[]]$Apps, [object[]]$Startup)
    if (-not $States) { $States = @{} }

    # Tweaks: the chosen profiles together, in their own order, each once
    $order = New-Object System.Collections.Generic.List[string]
    $profiles = @{}
    foreach ($p in @($Presets)) {
        foreach ($id in @($p.tweaks)) {
            if (-not $profiles.ContainsKey($id)) { $profiles[$id] = New-Object System.Collections.Generic.List[string]; $order.Add($id) }
            $profiles[$id].Add((Resolve-PcLocalized $p.name))
        }
    }
    $chosen = New-Object System.Collections.Generic.List[string]
    foreach ($id in $order) {
        $t = @($Catalog) | Where-Object { $_.id -eq $id } | Select-Object -First 1
        # Advanced tweaks are for people who know why they want them, never a recommendation
        if (-not $t -or $t.risk -eq 'advanced') { continue }
        # Already in place, not for this PC, or unreadable: nothing to recommend
        if (@('NotApplied', 'Partial') -notcontains $States[$id]) { continue }
        $others = @(@($t.conflictsWith) | Where-Object { $_ })
        # Its alternative is in place (the Ultimate plan, say), which was someone's choice, or is in
        # the journal, where the engine would refuse this one until it is undone
        if (@($others | Where-Object { $States[$_] -eq 'Applied' -or $Recorded -contains $_ }).Count -gt 0) { continue }
        # Two profiles asking for the two sides of a pair: the first one wins
        if (@($others | Where-Object { $chosen -contains $_ }).Count -gt 0) { continue }
        $chosen.Add($id)
        # Every catalog tweak can be undone today; one marked otherwise would never come ticked
        $undoable = $t.reversible -ne $false
        New-PcRecommendation @{
            Area = 'tweak'; Id = $t.id; Category = [string]$t.category; Title = Resolve-PcLocalized $t.title
            Detail = Resolve-PcLocalized $t.description; Risk = [string]$t.risk; Ticked = ($t.risk -eq 'safe' -and $undoable)
            Undo = $(if ($undoable) { 'history' } else { 'none' })
            Profiles = @($profiles[$id]); Requires = $t.requires; Reference = $t.reference; Evidence = $t.evidence
        }
    }

    # Cleanup: what has something to free; one that can't run now is shown without a tick box
    foreach ($c in @($Cleanup)) {
        if ($c.Available -and [int64]$c.Bytes -le 0) { continue }
        if (-not $c.Available -and -not $c.BlockedKey) { continue }
        New-PcRecommendation @{
            Area = 'cleanup'; Id = [string]$c.Id; Title = [string]$c.Name; Detail = Get-PcText "cleanup.$($c.Id).detail"
            # The Recycle Bin holds the user's own files: listed, never ticked
            Ticked = ([bool]$c.Available -and $c.Id -ne 'recycle-bin'); Enabled = [bool]$c.Available
            Undo = 'none'; Bytes = [int64]$c.Bytes; Files = [int]$c.Files; BlockedKey = $c.BlockedKey
        }
    }

    # Built-in apps: only the ones marked safe to remove and installed. Whether the user needs one
    # is something no analysis knows, so none comes ticked.
    foreach ($a in @($Apps)) {
        if (-not $a.Installed -or $a.Risk -ne 'safe') { continue }
        New-PcRecommendation @{
            Area = 'app'; Id = [string]$a.Package; Title = [string]$a.Name; Detail = $(if ($a.Note) { [string]$a.Note } else { [string]$a.Package })
            Undo = 'reinstall'
        }
    }

    # Startup: what starts with Windows now, for review. It could be the antivirus or a driver's
    # helper, so nothing comes ticked.
    foreach ($s in @($Startup)) {
        if (-not $s.Enabled) { continue }
        New-PcRecommendation @{
            Area = 'startup'; Id = [string]$s.Id; Title = [string]$s.Name; Detail = [string]$s.Command
            Undo = 'startup'; Source = [string]$s.Source; Publisher = [string]$s.Publisher
        }
    }
}

function Invoke-PcRecommendations {
    # Runs only the ids given, area by area: restore point, tweaks, cleanup, apps, startup. One area
    # failing doesn't stop the others; a restore point that can't be made stops everything.
    param($Sync, [string[]]$TweakIds = @(), [string[]]$CleanupIds = @(), [string[]]$AppPackages = @(),
        [string[]]$StartupIds = @(), [hashtable]$Names = @{}, [bool]$CreateRestorePoint)
    $status = { param([string]$Text) if ($Sync) { $Sync.Status = $Text } }
    $name = { param([string]$Key) if ($Names.ContainsKey($Key)) { $Names[$Key] } else { ($Key -split '\|')[-1] } }

    if ($CreateRestorePoint) {
        & $status (Get-PcText 'status.creatingRestorePoint')
        if (-not (New-PcRestorePoint -Description ('PitCrew {0:yyyy-MM-dd HH:mm}' -f (Get-Date)))) { return [pscustomobject]@{ NoRestorePoint = $true } }
    }
    $done = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    $r = [ordered]@{ NoRestorePoint = $false; Changed = 0; AlreadySet = 0; Cleaned = 0; Freed = [int64]0; AppsRemoved = 0; StartupOff = 0
        Restart = $false; SignOut = $false; RestartExplorer = $false }

    $catalog = @()
    if (@($TweakIds).Count -gt 0) {
        # A catalog that can't be read fails the tweaks, not the cleanup, apps and startup after them
        try { $catalog = @(Import-PcTweaks) } catch { $failed.Add(('{0}: {1}' -f (Get-PcText 'filter.areaTweak'), $_.Exception.Message)); $TweakIds = @() }
        foreach ($id in $TweakIds) {
            $t = $catalog | Where-Object { $_.id -eq $id } | Select-Object -First 1
            $label = & $name "tweak|$id"
            if (-not $t) { $failed.Add(('{0}: {1}' -f $label, (Get-PcText 'history.removedTweak'))); continue }
            & $status ('{0} {1}' -f (Get-PcText 'status.applying'), $label)
            try {
                if (Invoke-PcTweak $t) {
                    $r.Changed++
                    if ($t.requires.restart) { $r.Restart = $true }
                    if ($t.requires.signOut) { $r.SignOut = $true }
                    if ($t.requires.restartExplorer) { $r.RestartExplorer = $true }
                } else { $r.AlreadySet++ }
                $done.Add("tweak|$id")
            } catch { $failed.Add(('{0}: {1}' -f $label, $_.Exception.Message)) }
        }
    }

    if (@($CleanupIds).Count -gt 0) {
        & $status (Get-PcText 'status.cleaning')
        try {
            foreach ($c in @(Invoke-PcCleanup -Ids $CleanupIds)) {
                if ($c.Error) { $failed.Add(('{0}: {1}' -f (& $name "cleanup|$($c.Id)"), $c.Error)); continue }
                $r.Cleaned++
                $r.Freed += [int64]$c.FreedBytes
                $done.Add("cleanup|$($c.Id)")
            }
        } catch { $failed.Add(('{0}: {1}' -f (Get-PcText 'nav.cleanup'), $_.Exception.Message)) }
    }

    if (@($AppPackages).Count -gt 0) {
        & $status (Get-PcText 'status.removing')
        try {
            foreach ($a in @(Remove-PcApps -Packages $AppPackages)) {
                if ($a.Removed) { $r.AppsRemoved++; $done.Add("app|$($a.Package)") }
                else { $failed.Add(('{0}: {1}' -f (& $name "app|$($a.Package)"), (Get-PcText 'analysis.notRemoved'))) }
            }
        } catch { $failed.Add(('{0}: {1}' -f (Get-PcText 'nav.apps'), $_.Exception.Message)) }
    }

    foreach ($id in @($StartupIds)) {
        try {
            Set-PcStartupItemEnabled -Id $id -Enabled $false
            $r.StartupOff++
            $done.Add("startup|$id")
        } catch { $failed.Add(('{0}: {1}' -f (& $name "startup|$id"), $_.Exception.Message)) }
    }

    $r.Done = @($done)
    $r.Failed = @($failed)
    [pscustomobject]$r
}

# The State each card carries for the page's area filter (distinct from the other pages' states)
$script:PcAnalysisStates = @{ tweak = 'AreaTweak'; cleanup = 'AreaCleanup'; app = 'AreaApp'; startup = 'AreaStartup' }

function ConvertTo-PcRecommendationCard($Item) {
    # One card: the page it belongs to, how it can be undone, why it is there
    $meta = @()
    switch ($Item.Area) {
        'tweak' {
            $tag = Get-PcText "nav.$($Item.Category)"
            if (@($Item.Profiles).Count -gt 0) { $meta += Get-PcText 'analysis.inProfiles' -FormatArgs (@($Item.Profiles) -join ', ') }
            if ($Item.Risk -eq 'moderate') { $meta += Get-PcText 'risk.moderate' }
            if ($Item.Requires -and $Item.Requires.restart) { $meta += Get-PcText 'tweak.restart' }
            if ($Item.Requires -and $Item.Requires.signOut) { $meta += Get-PcText 'tweak.signOut' }
            if ($Item.Requires -and $Item.Requires.restartExplorer) { $meta += Get-PcText 'tweak.restartExplorer' }
        }
        'cleanup' {
            $tag = Get-PcText 'nav.cleanup'
            if (-not $Item.Enabled) { $meta += Get-PcText $Item.BlockedKey }
            elseif ($Item.Files -gt 0) { $meta += Get-PcText 'cleanup.meta' -FormatArgs (Format-PcBytes $Item.Bytes), $Item.Files }
            else { $meta += Format-PcBytes $Item.Bytes }
        }
        'app' { $tag = Get-PcText 'nav.apps'; $meta += $Item.Id }
        'startup' {
            $tag = Get-PcText 'nav.startup'
            $meta += @($Item.Source, $Item.Publisher) | Where-Object { $_ }
        }
    }
    $card = @{
        Id         = '{0}|{1}' -f $Item.Area, $Item.Id
        State      = $script:PcAnalysisStates[$Item.Area]
        Title      = [string]$Item.Title
        Detail     = [string]$Item.Detail
        Tag        = [string]$tag
        Badge      = Get-PcText "analysis.undo.$($Item.Undo)"
        BadgeKind  = $(if ($Item.Undo -eq 'none') { 'warn' } else { 'neutral' })
        Meta       = $meta -join '  ·  '
        IsEnabled  = [bool]$Item.Enabled
        IsSelected = [bool]$Item.Ticked -and [bool]$Item.Enabled
        Data       = $Item
    }
    if ($Item.Area -eq 'tweak' -and $Item.Reference) {
        $card.Link = [string]$Item.Reference
        $card.LinkText = Get-PcText $(switch ($Item.Evidence) { 'vendor' { 'link.vendor' } 'community' { 'link.community' } default { 'link.learnMore' } })
    }
    $card
}

function Get-PcRecommendationCounts([object[]]$Items) {
    # What the confirmation lists: counted from exactly the items that will run
    # @() around each call: one item comes back unrolled, and a single object has no Count in PS 5.1
    $by = { param($a) $Items | Where-Object { $_.Area -eq $a } }
    [pscustomobject]@{
        Tweaks       = @(& $by 'tweak').Count
        Cleanup      = @(& $by 'cleanup').Count
        CleanupBytes = [int64](@(& $by 'cleanup' | ForEach-Object { [int64]$_.Bytes }) | Measure-Object -Sum).Sum
        Apps         = @(& $by 'app').Count
        Startup      = @(& $by 'startup').Count
    }
}

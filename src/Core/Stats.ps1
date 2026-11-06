# Running totals for the dashboard: what PitCrew did from this version on (space freed, apps
# removed, drivers installed, tweaks applied). The actions add to them as they finish; opening the
# dashboard only reads. Kept in the data folder next to the journal, where only administrators
# write, and everything counted needs administrator rights anyway.

$script:PcStatNames = @('tweaksApplied', 'cleanups', 'cleanupBytes', 'appsRemoved', 'driversInstalled')

function Get-PcStatsPath { Join-Path $Pc.DataDir 'stats.json' }

function ConvertTo-PcStats($Raw) {
    # Every counter a whole number from 0 up; anything else in the file counts as 0
    $since = $null
    if ($Raw -and $Raw.since) {
        try { $since = [datetime]::Parse([string]$Raw.since, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { }
    }
    $out = [ordered]@{ Since = $since }
    foreach ($name in $script:PcStatNames) {
        $value = [int64]0
        if ($Raw) { try { $value = [int64]$Raw.$name } catch { } }
        if ($value -lt 0) { $value = [int64]0 }
        $out[$name] = $value
    }
    [pscustomobject]$out
}

function Get-PcStats {
    # $null until something was counted. Reading never creates the data folder, and numbers from a
    # folder someone other than an administrator could have written are not shown.
    if (-not $Pc.RegistryRedirect -and -not (Test-PcPathTrusted $Pc.DataDir)) { return $null }
    $path = Get-PcStatsPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return ConvertTo-PcStats (Read-PcJson $path) }
    catch { Write-PcLog "Totals unreadable: $($_.Exception.Message)" 'Warn'; return $null }
}

function Add-PcStats([hashtable]$Add) {
    # Counting must never fail or stop the action it counts: any problem is logged and that's all
    try {
        if (-not $Pc.RegistryRedirect -and -not (Test-PcAdmin)) { Write-PcLog 'Totals not updated: not running as administrator' 'Warn'; return }
        Use-PcJournalLock {
            $path = Join-Path (Get-PcDataPath '') 'stats.json'
            $temp = "$path.tmp"
            # A swap cut short can leave only the new copy beside it
            if (-not (Test-Path -LiteralPath $path) -and (Test-Path -LiteralPath $temp)) { [IO.File]::Move($temp, $path) }
            $current = $null
            if (Test-Path -LiteralPath $path) {
                # A file that can't be opened right now (antivirus, say) is left alone; one that
                # opens but isn't valid JSON can't be fixed, so it is kept aside and the count starts over
                $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
                try { $current = ConvertTo-PcStats ($text | ConvertFrom-Json) }
                catch {
                    Write-PcLog "Totals file was not valid, kept as stats.json.bad and starting over: $($_.Exception.Message)" 'Warn'
                    # Not being able to keep the copy must not stop the count from starting over
                    try { Copy-Item -LiteralPath $path -Destination "$path.bad" -Force -ErrorAction Stop }
                    catch { Write-PcLog "stats.json.bad not written: $($_.Exception.Message)" 'Warn' }
                }
            }
            $since = if ($current -and $current.Since) { $current.Since } else { Get-Date }
            $data = [ordered]@{ version = 1; since = $since.ToString('o') }
            foreach ($name in $script:PcStatNames) {
                $value = if ($current) { [int64]$current.$name } else { [int64]0 }
                if ($Add.ContainsKey($name)) { $value += [int64]$Add[$name] }
                $data[$name] = $value
            }
            # Written beside it and swapped in, so a crash mid-write never leaves half a file
            Write-PcJson $temp ([pscustomobject]$data)
            # [NullString]: a plain $null reaches .NET as "" and Replace rejects it as a backup path
            if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temp, $path, [NullString]::Value) } else { [IO.File]::Move($temp, $path) }
        }
    } catch { Write-PcLog "Totals not updated: $($_.Exception.Message)" 'Warn' }
}

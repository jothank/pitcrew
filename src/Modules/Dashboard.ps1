# Dashboard: what this PC is, what PitCrew changed on it and how each change looked before and
# looks now (from the undo journal), and the running totals from src\Core\Stats.ps1. Only facts
# read on the spot: no score, no promise about speed or boot time. Opening it writes nothing.
#
# Get-PcDashboard gathers everything in the background; the ConvertTo-* functions turn it into
# rows and tiles without touching the system, so the tests can feed them.

# Model names some boards report when the maker left them blank
$script:PcPlaceholderModels = @('System Product Name', 'System Version', 'To Be Filled By O.E.M.', 'Default string', 'Not Applicable', 'None', 'Unknown')
# Video "adapters" that aren't a graphics card
$script:PcIgnoredGpus = @('Microsoft Remote Display Adapter', 'Microsoft Basic Render Driver')
$script:PcArrow = [string][char]0x2192

# --- PC summary -----------------------------------------------------------------------------------

function Get-PcSystemSummary {
    # A provider that hangs (a disk that stopped answering) mustn't hold the first page forever
    $PSDefaultParameterValues = @{ 'Get-CimInstance:OperationTimeoutSec' = 15 }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $win = Get-PcWindowsInfo

    $maker = [string]$cs.Manufacturer
    $model = [string]$cs.Model
    if ($maker -match 'lenovo' -and $cs.SystemFamily) { $model = [string]$cs.SystemFamily }   # "ThinkPad X1", not "20XW0026US"
    if ($script:PcPlaceholderModels -contains $model.Trim() -or -not $model.Trim()) {
        $board = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($board) { $maker = [string]$board.Manufacturer; $model = [string]$board.Product }
    }

    $cpus = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue)
    $memory = [int64](@(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | ForEach-Object { [int64]$_.Capacity }) | Measure-Object -Sum).Sum
    if ($memory -le 0 -and $cs) { $memory = [int64]$cs.TotalPhysicalMemory }
    $usedPercent = $null
    if ($os -and [int64]$os.TotalVisibleMemorySize -gt 0) {
        $usedPercent = [int][Math]::Round(100.0 * ([int64]$os.TotalVisibleMemorySize - [int64]$os.FreePhysicalMemory) / [int64]$os.TotalVisibleMemorySize)
    }

    # The Storage namespace directly: Get-PhysicalDisk loads a module and takes seconds more
    $disks = @(Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName MSFT_PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{
                Name      = ([string]$_.FriendlyName).Trim()
                Media     = switch ([int]$_.MediaType) { 3 { 'HDD' } 4 { 'SSD' } 5 { 'SCM' } default { '' } }
                Nvme      = [int]$_.BusType -eq 17
                Usb       = [int]$_.BusType -eq 7
                SizeBytes = [int64]$_.Size
                Health    = switch ([int]$_.HealthStatus) { 0 { 'Healthy' } 1 { 'Warning' } 2 { 'Unhealthy' } default { 'Unknown' } }
            }
        })

    [pscustomobject]@{
        Windows           = $(if ($os.Caption) { ([string]$os.Caption -replace '^Microsoft\s+', '').Trim() } else { 'Windows' })
        DisplayVersion    = [string]$win.DisplayVersion
        Build             = '{0}.{1}' -f $win.Build, $win.Ubr
        Maker             = Get-PcCompanyName $maker
        Model             = $model.Trim()
        FormFactor        = Get-PcFormFactor
        Cpu               = $(if ($cpus) { ([string]$cpus[0].Name -replace '\s+', ' ').Trim() } else { '' })
        CpuCount          = $cpus.Count
        Cores             = [int](@($cpus | ForEach-Object { [int]$_.NumberOfCores }) | Measure-Object -Sum).Sum
        Threads           = [int](@($cpus | ForEach-Object { [int]$_.NumberOfLogicalProcessors }) | Measure-Object -Sum).Sum
        MemoryBytes       = $memory
        MemoryUsedPercent = $usedPercent
        Gpus              = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { ([string]$_.Name).Trim() } |
                Where-Object { $_ -and $script:PcIgnoredGpus -notcontains $_ } | Select-Object -Unique)
        Volumes           = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | Where-Object { [int64]$_.Size -gt 0 } | ForEach-Object {
                [pscustomobject]@{ Letter = [string]$_.DeviceID; FreeBytes = [int64]$_.FreeSpace; SizeBytes = [int64]$_.Size }
            })
        Disks             = $disks
        LastBoot          = $(if ($os) { $os.LastBootUpTime } else { $null })
    }
}

function Format-PcMemorySize([int64]$Bytes) {
    # Installed memory comes in whole gigabytes: "32 GB", not "32,0 GB"
    if ($Bytes -gt 0 -and $Bytes % 1GB -eq 0) { return '{0} GB' -f ($Bytes / 1GB) }
    return Format-PcBytes $Bytes
}

function ConvertTo-PcSummaryRows($Summary, [datetime]$Now = (Get-Date)) {
    # One label and one value per line of the "PC summary" card; a fact that couldn't be read is left out
    if (-not $Summary) { return }
    $row = { param($Key, $Value) if ($Value) { [pscustomobject]@{ Label = Get-PcText "dashboard.row.$Key"; Value = [string]$Value } } }

    $windows = $Summary.Windows
    if ($Summary.DisplayVersion) { $windows = Get-PcText 'dashboard.windowsValue' -FormatArgs $Summary.Windows, $Summary.DisplayVersion, $Summary.Build }
    & $row 'windows' $windows

    $computer = ('{0} {1}' -f $Summary.Maker, $Summary.Model).Trim()
    if ($Summary.FormFactor) { $computer = ('{0} · {1}' -f $computer, (Get-PcText "dashboard.$($Summary.FormFactor)")).TrimStart(' ·') }
    & $row 'computer' $computer

    if ($Summary.Cpu) {
        $cpu = Get-PcText 'dashboard.cpuValue' -FormatArgs $Summary.Cpu, $Summary.Cores, $Summary.Threads
        if ($Summary.CpuCount -gt 1) { $cpu = '{0} x {1}' -f $Summary.CpuCount, $cpu }
        & $row 'cpu' $cpu
    }
    if ($Summary.MemoryBytes -gt 0) {
        $memory = Format-PcMemorySize $Summary.MemoryBytes
        if ($null -ne $Summary.MemoryUsedPercent) { $memory = Get-PcText 'dashboard.memoryValue' -FormatArgs $memory, $Summary.MemoryUsedPercent }
        & $row 'memory' $memory
    }
    & $row 'gpu' (@($Summary.Gpus) -join ', ')
    & $row 'storage' ((@($Summary.Volumes) | ForEach-Object {
                Get-PcText 'dashboard.volumeValue' -FormatArgs $_.Letter, (Format-PcBytes $_.FreeBytes), (Format-PcBytes $_.SizeBytes)
            }) -join "`n")
    & $row 'disks' ((@($Summary.Disks) | ForEach-Object {
                $disk = $_
                $type = @($disk.Media, $(if ($disk.Nvme) { 'NVMe' } elseif ($disk.Usb) { 'USB' })) | Where-Object { $_ }
                $parts = @($disk.Name, (@($type) -join ' '), (Format-PcBytes $disk.SizeBytes), (Get-PcText "disk.$($disk.Health)"))
                (@($parts | Where-Object { $_ }) -join ' · ')
            }) -join "`n")
    if ($Summary.LastBoot) {
        $boot = [datetime]$Summary.LastBoot
        $up = $Now - $boot
        if ($up.Ticks -lt 0) { $up = [TimeSpan]::Zero }
        $days = [int][Math]::Floor($up.TotalDays)
        & $row 'boot' (Get-PcText 'dashboard.bootValue' -FormatArgs $boot.ToString('g'), $days, $up.Hours)
    }
}

# --- Before and now, for each change in the journal -----------------------------------------------

function Get-PcPowerSchemeNames {
    # Plan GUID -> the name Windows shows (translated); empty when powercfg can't be read
    $names = @{}
    try {
        foreach ($line in @(& powercfg.exe /list)) {
            if ([string]$line -match '([0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})\s+\((.+)\)') { $names[$Matches[1].ToLowerInvariant()] = $Matches[3].Trim() }
        }
    } catch { Write-PcLog "Power plan names not read: $($_.Exception.Message)" 'Warn' }
    return $names
}

function Get-PcServiceDisplayName([string]$Name) {
    try { return [string](Get-Service -Name $Name -ErrorAction Stop).DisplayName } catch { return $Name }
}

function Format-PcRegistryData($Value) {
    # A journal snapshot ({exists, kind, data}) or a live Get-PcRegistryValue result, shown short
    if (-not $Value -or -not $Value.exists) { return Get-PcText 'dashboard.notSet' }
    $text = switch ([string]$Value.kind) {
        'Binary' {
            $bytes = @()
            try { $bytes = [Convert]::FromBase64String([string]$Value.data) } catch { }
            $hex = (@($bytes | Select-Object -First 8 | ForEach-Object { $_.ToString('X2') })) -join ' '
            if ($bytes.Count -gt 8) { $hex += ' ...' }
            $hex
        }
        'MultiString' { '"' + (@($Value.data) -join '", "') + '"' }
        { @('String', 'ExpandString') -contains $_ } { '"' + [string]$Value.data + '"' }
        default { [string]$Value.data }
    }
    if ($text.Length -gt 60) { $text = $text.Substring(0, 57) + '...' }
    return $text
}

function Format-PcOnOff($Enabled) {
    if ($null -eq $Enabled) { return Get-PcText 'dashboard.missing' }
    if ($Enabled) { return Get-PcText 'dashboard.enabled' }
    return Get-PcText 'dashboard.disabled'
}

function Format-PcStartType([string]$Type) {
    if (-not $Type) { return Get-PcText 'dashboard.missing' }
    if ($script:PcStartTypes.ContainsKey($Type)) { return Get-PcText "dashboard.start.$Type" }
    return $Type
}

function Format-PcPowerPlan([string]$Guid, [hashtable]$Names) {
    $key = $Guid.ToLowerInvariant()
    if ($Names.ContainsKey($key)) { return $Names[$key] }
    return Get-PcText 'dashboard.otherPlan'
}

function Test-PcRecordChanged($Action, $Record) {
    # Applying a tweak that was partly in place records every action, also the ones that already
    # had the value: those weren't PitCrew's doing and are left out of "before and now"
    $b = $Record.before
    switch ($Action.type) {
        'registry' {
            if ($Action.absent) { return [bool]$b.exists }
            return -not ($b.exists -and $b.kind -eq $Action.kind -and (Test-PcRegistryDataEqual $Action.kind $b.data $Action.value))
        }
        'dxSetting'     { return -not ($b.present -and [string]$b.value -ceq [string]$Action.value) }
        'service'       { return [string]$b.startupType -ne [string]$Action.startupType }
        'scheduledTask' { return $b.enabled -ne [bool]$Action.enabled }
        'powerPlan'     { return ([string]$b.activeScheme).ToLowerInvariant() -ne ([string]$Action.guid).ToLowerInvariant() }
        'hibernation'   { return $b.enabled -ne [bool]$Action.enabled }
    }
    return $true
}

function Format-PcChangeLine($Action, $Record, [hashtable]$Cache) {
    # "What: before -> now" for one catalog action and its journal record. "Now" is read live, so a
    # change someone made since shows up here as it is.
    if (-not (Test-PcRecordChanged $Action $Record)) { return }
    $what = ''; $before = ''; $now = ''
    switch ($Action.type) {
        'registry' {
            $what = Get-PcText 'dashboard.registry' -FormatArgs $(if ($Action.name) { $Action.name } else { Get-PcText 'dashboard.defaultValue' })
            $before = Format-PcRegistryData $Record.before
            $now = Format-PcRegistryData (Get-PcRegistryValue $Action.path $Action.name)
        }
        'dxSetting' {
            $what = Get-PcText 'dashboard.dx' -FormatArgs $Action.key
            $before = if ($Record.before.present) { [string]$Record.before.value } else { Get-PcText 'dashboard.notSet' }
            $live = Get-PcDxSetting $Action.key
            $now = if ($live.Present) { [string]$live.Value } else { Get-PcText 'dashboard.notSet' }
        }
        'service' {
            $what = Get-PcText 'dashboard.service' -FormatArgs (Get-PcServiceDisplayName $Action.name)
            $before = Format-PcStartType ([string]$Record.before.startupType)
            $now = Format-PcStartType (Get-PcServiceStartup $Action.name)
        }
        'scheduledTask' {
            $what = Get-PcText 'dashboard.task' -FormatArgs $Action.name
            $before = Format-PcOnOff $Record.before.enabled
            $now = Format-PcOnOff (Get-PcScheduledTaskEnabled $Action.path $Action.name)
        }
        'powerPlan' {
            if (-not $Cache.ContainsKey('PowerNames')) { $Cache.PowerNames = Get-PcPowerSchemeNames }
            # Without the list every plan would read as "no longer exists"
            if ($Cache.PowerNames.Count -eq 0) { return }
            $what = Get-PcText 'dashboard.powerPlan'
            $before = Format-PcPowerPlan ([string]$Record.before.activeScheme) $Cache.PowerNames
            $now = Format-PcPowerPlan (Get-PcActivePowerScheme) $Cache.PowerNames
        }
        'hibernation' {
            $what = Get-PcText 'dashboard.hibernation'
            $before = Format-PcOnOff $Record.before.enabled
            $now = Format-PcOnOff (Get-PcHibernationEnabled)
        }
        default { return }
    }
    '{0}: {1} {2} {3}' -f $what, $before, $script:PcArrow, $now
}

function Format-PcYesNo([object[]]$Values) {
    # Several interfaces of one device: yes, no, or partly
    $v = @($Values | Where-Object { $_ -is [bool] })
    if ($v.Count -eq 0) { return Get-PcText 'dashboard.disconnected' }
    $on = @($v | Where-Object { $_ }).Count
    if ($on -eq $v.Count) { return Get-PcText 'dashboard.yes' }
    if ($on -eq 0) { return Get-PcText 'dashboard.no' }
    return Get-PcText 'dashboard.partly'
}

function Format-PcDeviceChangeLine($Entry) {
    # One line per device, not per interface: "Windows may turn it off: yes -> no"
    $records = @($Entry.actions | Where-Object { $_.type -eq 'devicePower' -and $_.target -and $_.before -is [bool] })
    $live = @(foreach ($r in $records) { $d = Resolve-PcDevicePowerInstance ([string]$r.target); if ($d) { [bool]$d.Enabled } })
    '{0}: {1} {2} {3}' -f (Get-PcText 'dashboard.deviceAllowOff'), (Format-PcYesNo @($records | ForEach-Object { $_.before })), $script:PcArrow, (Format-PcYesNo $live)
}

function Get-PcChangeReport([object[]]$Catalog) {
    # One record per journal entry this user can see, newest first: title, category, current
    # state and the before/now lines
    if (-not $PSBoundParameters.ContainsKey('Catalog')) { $Catalog = @(Import-PcTweaks) }
    $cache = @{}
    foreach ($e in @(Get-PcMyJournalEntries) | Sort-Object appliedAt -Descending) {
        $appliedAt = $null
        if ($e.appliedAt -is [datetime]) { $appliedAt = $e.appliedAt }
        else { try { $appliedAt = [datetime]::Parse([string]$e.appliedAt, [Globalization.CultureInfo]::InvariantCulture) } catch { } }
        $t = $Catalog | Where-Object { $_.id -eq $e.tweakId } | Select-Object -First 1
        $isDevice = (-not $t) -and ([string]$e.tweakId -like 'device.power.*')
        if ($isDevice) { $t = Get-PcDeviceUndoTweak $e }
        if (-not $t) {
            # Taken out of the catalog since: nothing left to compare it with
            [pscustomobject]@{ TweakId = [string]$e.tweakId; Title = [string]$e.tweakId; Category = ''; State = ''; AppliedAt = $appliedAt; Lines = @() }
            continue
        }
        $lines = @()
        try {
            if ($isDevice) {
                $lines = @(Format-PcDeviceChangeLine $e)
            } else {
                $lines = @(foreach ($r in @($e.actions) | Sort-Object index) {
                        $action = Find-PcRecordAction $t $r
                        if ($action) {
                            try { Format-PcChangeLine $action $r $cache }
                            catch { Write-PcLog "Before/now of $($e.tweakId): $($_.Exception.Message)" 'Warn' }
                        }
                    })
            }
        } catch { Write-PcLog "Before/now of $($e.tweakId): $($_.Exception.Message)" 'Warn' }
        [pscustomobject]@{
            TweakId   = [string]$e.tweakId
            Title     = Resolve-PcLocalized $t.title
            Category  = $(if ($isDevice) { 'devices' } else { [string]$t.category })
            State     = [string](Get-PcTweakState $t)
            AppliedAt = $appliedAt
            Lines     = @($lines | Where-Object { $_ })
        }
    }
}

function ConvertTo-PcChangeCards([object[]]$Changes) {
    # The "Before and now" cards: read only (Undo stays in History)
    foreach ($c in @($Changes)) {
        $meta = @()
        if ($c.AppliedAt) { $meta += Get-PcText 'history.appliedAt' -FormatArgs ([datetime]$c.AppliedAt).ToString('g') }
        if ($c.Category) { $meta += Get-PcText "nav.$($c.Category)" }
        $detail = @($c.Lines) -join "`n"
        if (-not $c.Category) { $detail = Get-PcText 'history.removedTweak' }
        @{
            Id         = [string]$c.TweakId
            Title      = [string]$c.Title
            Detail     = $detail
            Meta       = $meta -join '  ·  '
            Badge      = $(if ($c.State) { Get-PcText "state.$($c.State)" } else { '' })
            BadgeKind  = $(if ($c.State -eq 'Applied') { 'good' } elseif ($c.State) { 'warn' } else { 'neutral' })
            Selectable = $false
        }
    }
}

# --- Tiles ----------------------------------------------------------------------------------------

# Same order as the pages in the window
$script:PcTweakCategoryOrder = @('performance', 'privacy', 'explorer')

function New-PcTile($Value, [string]$Label, [string]$Note = '') {
    [pscustomobject]@{ Value = [string]$Value; Label = $Label; Note = $Note }
}

function ConvertTo-PcOptimizedTiles([object[]]$Changes, $Startup, $Apps) {
    # Tweaks and devices: only what PitCrew changed (the journal) and is still in place. Startup
    # and apps: how things are now, whoever changed them.
    $tweaks = @($Changes | Where-Object { $_.Category -and $_.Category -ne 'devices' })
    $kept = @($tweaks | Where-Object { $_.State -eq 'Applied' })
    $notes = @($kept | Group-Object Category | Sort-Object { [array]::IndexOf($script:PcTweakCategoryOrder, $_.Name) } | ForEach-Object {
            '{0}: {1}' -f (Get-PcText "nav.$($_.Name)"), $_.Count
        })
    # "Changed later" only when it reads as no longer (fully) set; "not applicable" (an unplugged
    # device, another edition) and "couldn't read" say nothing about who changed what
    $isLater = { param($c) @('NotApplied', 'Partial') -contains $c.State }
    $later = @($tweaks | Where-Object { & $isLater $_ }).Count
    if ($later -gt 0) { $notes += Get-PcText 'dashboard.tile.changedLater' -FormatArgs $later }
    New-PcTile $kept.Count (Get-PcText 'dashboard.tile.tweaks') ($notes -join ' · ')

    $devices = @($Changes | Where-Object { $_.Category -eq 'devices' })
    $keptDevices = @($devices | Where-Object { $_.State -eq 'Applied' }).Count
    $laterDevices = @($devices | Where-Object { & $isLater $_ }).Count
    $note = ''
    if ($laterDevices -gt 0) { $note = Get-PcText 'dashboard.tile.changedLater' -FormatArgs $laterDevices }
    New-PcTile $keptDevices (Get-PcText 'dashboard.tile.devices') $note

    if ($Startup) { New-PcTile $Startup.Off (Get-PcText 'dashboard.tile.startup' -FormatArgs $Startup.Total) }
    if ($Apps) { New-PcTile $Apps.NotInstalled (Get-PcText 'dashboard.tile.apps' -FormatArgs $Apps.Total) }
}

function ConvertTo-PcTotalsTiles($Stats) {
    # Nothing counted yet reads as zeros
    if (-not $Stats) { $Stats = ConvertTo-PcStats $null }
    New-PcTile (Format-PcBytes $Stats.cleanupBytes) (Get-PcText 'dashboard.tile.freed') (Get-PcText 'dashboard.tile.cleanups' -FormatArgs $Stats.cleanups)
    New-PcTile $Stats.appsRemoved (Get-PcText 'dashboard.tile.appsRemoved')
    New-PcTile $Stats.driversInstalled (Get-PcText 'dashboard.tile.drivers')
    New-PcTile $Stats.tweaksApplied (Get-PcText 'dashboard.tile.tweaksApplied')
}

# --- Everything at once (background job) ----------------------------------------------------------

function Get-PcDashboard {
    # Each part on its own: one that fails is left empty and the rest still shows
    $part = {
        param([string]$Name, [scriptblock]$Read)
        try { & $Read } catch { Write-PcLog "Dashboard $Name not read: $($_.Exception.Message)" 'Warn'; $null }
    }
    [pscustomobject]@{
        Summary = & $part 'summary' { Get-PcSystemSummary }
        Changes = @(& $part 'changes' { Get-PcChangeReport } | Where-Object { $_ })
        Startup = & $part 'startup' {
            $items = @(Get-PcStartupItems)
            [pscustomobject]@{ Total = $items.Count; Off = @($items | Where-Object { -not $_.Enabled }).Count }
        }
        Apps    = & $part 'apps' {
            $apps = @(Get-PcRemovableApps)
            [pscustomobject]@{ Total = $apps.Count; NotInstalled = @($apps | Where-Object { -not $_.Installed }).Count }
        }
        Stats   = & $part 'totals' { Get-PcStats }
    }
}

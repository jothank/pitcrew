# Device power: the "Allow the computer to turn off this device to save power" box of Device
# Manager's Power Management tab, for every device at once. Device Manager reads and sets it
# through the MSPower_DeviceEnable WMI class (root\wmi), one boolean per device, and so does this:
# https://learn.microsoft.com/windows-hardware/drivers/kernel/wmi-and-the-power-management-tab
#
# Each device (or the interfaces of one physical device, like a keyboard's two HID entries) becomes
# a tweak built on the fly, with one devicePower action per WMI instance. Changes go through the
# tweak engine, so they are journaled and show up in History with Undo.

$script:PcDevicePowerReference = 'https://learn.microsoft.com/windows-hardware/drivers/kernel/wmi-and-the-power-management-tab'
# Only the kinds of device people actually have trouble with; system and security devices (GPIO,
# AMD PSP...) also offer the box, but nothing documents a reason to touch them
$script:PcDevicePowerClasses = @('Net', 'Bluetooth', 'USB', 'HIDClass', 'Keyboard', 'Mouse')
# Display order of the kinds
$script:PcDeviceKinds = @('wifi', 'ethernet', 'network', 'bluetooth', 'keyboard', 'mouse', 'input', 'usbDevice', 'usbHub', 'usbController')

# --- Windows wrappers (tests replace these) -------------------------------------------------------

$script:PcDevicePowerCache = $null

function Get-PcDevicePowerStates {
    # WMI instance name ("<device instance ID>_0") -> $true when Windows may turn the device off.
    # Reading works without administrator rights. Kept for a few seconds, since the engine asks
    # several times per device (available? applied?); any change clears it.
    $cache = $script:PcDevicePowerCache
    if ($cache -and ((Get-Date) - $cache.At).TotalSeconds -lt 5) { return $cache.States }
    $states = @{}
    try {
        $instances = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSPower_DeviceEnable' -ErrorAction Stop)
    } catch {
        # A PC or VM where no driver offers the box may have no provider for the class at all
        $e = $_.Exception
        if ($e.GetType().FullName -ne 'Microsoft.Management.Infrastructure.CimException' -or
            @('NotSupported', 'InvalidClass', 'InvalidNamespace', 'NotFound') -notcontains [string]$e.NativeErrorCode) { throw }
        $instances = @()
    }
    foreach ($i in $instances) { $states[[string]$i.InstanceName] = [bool]$i.Enable }
    $script:PcDevicePowerCache = @{ At = Get-Date; States = $states }
    return $states
}

function Set-PcDevicePowerEnabled([string]$InstanceName, [bool]$Enabled) {
    Assert-PcRealSystem "device power of $InstanceName"
    $script:PcDevicePowerCache = $null
    $match = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSPower_DeviceEnable' -ErrorAction Stop |
        Where-Object { $_.InstanceName -eq $InstanceName })
    if ($match.Count -ne 1) { throw (Get-PcText 'devices.gone') }
    Set-CimInstance -InputObject $match[0] -Property @{ Enable = $Enabled } -ErrorAction Stop
}

function Get-PcPowerDeviceInventory {
    # Raw facts about each device that has the box: its class, names, parent and children.
    # Read-only; slow enough (PnP properties) that the window runs it in the background.
    $states = Get-PcDevicePowerStates
    if ($states.Count -eq 0) { return @() }
    $byId = @{}
    foreach ($name in $states.Keys) { $byId[($name -replace '_\d+$', '').ToUpperInvariant()] = $name }
    $entities = @{}
    foreach ($e in @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)) {
        if ($e.PNPDeviceID) { $entities[$e.PNPDeviceID.ToUpperInvariant()] = $e }
    }
    # Get-PnpDeviceProperty misses some devices when given an ID in another case, so it gets the
    # IDs exactly as Windows wrote them; the lookups below are all by upper case
    $props = Get-PcPnpProperties @($states.Keys | ForEach-Object { $_ -replace '_\d+$', '' }) @('DEVPKEY_Device_BusReportedDeviceDesc', 'DEVPKEY_Device_Parent', 'DEVPKEY_Device_Children')
    # Product names of what is plugged into a USB hub or controller, and of the device a keyboard's
    # interfaces belong to; everything else is named from Win32_PnPEntity (one PnP call each is slow)
    $related = @(foreach ($id in $byId.Keys) {
            $class = if ($entities[$id]) { [string]$entities[$id].PNPClass } else { '' }
            if ($class -eq 'USB') { @($props["$id|DEVPKEY_Device_Children"]) }
            if ($class -eq 'HIDClass' -and $id -match '&MI_[0-9A-F]{2}') { $props["$id|DEVPKEY_Device_Parent"] }
        }) | Where-Object { $_ } | Select-Object -Unique
    $more = Get-PcPnpProperties @($related) @('DEVPKEY_Device_BusReportedDeviceDesc')
    $media = @{}
    try {
        foreach ($a in @(Get-CimInstance -Namespace 'root\StandardCimv2' -ClassName 'MSFT_NetAdapter' -ErrorAction Stop)) {
            if ($a.PnPDeviceID) { $media[$a.PnPDeviceID.ToUpperInvariant()] = [int]$a.NdisPhysicalMedium }
        }
    } catch { }
    foreach ($id in $byId.Keys) {
        $entity = $entities[$id]
        $parent = [string]$props["$id|DEVPKEY_Device_Parent"]
        $children = @(@($props["$id|DEVPKEY_Device_Children"]) | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() })
        [pscustomobject]@{
            InstanceName  = $byId[$id]
            InstanceId    = $id
            Class         = if ($entity) { [string]$entity.PNPClass } else { '' }
            Name          = if ($entity) { [string]$entity.Name } else { $id }
            Service       = if ($entity) { [string]$entity.Service } else { '' }
            ChildIds      = $children
            BusName       = ([string]$props["$id|DEVPKEY_Device_BusReportedDeviceDesc"]).Trim()
            ParentId      = $parent.ToUpperInvariant()
            ParentBusName = if ($parent) { ([string]$more["$($parent.ToUpperInvariant())|DEVPKEY_Device_BusReportedDeviceDesc"]).Trim() } else { '' }
            ChildClasses  = @($children | ForEach-Object { if ($entities[$_]) { [string]$entities[$_].PNPClass } } | Where-Object { $_ })
            ChildNames    = @($children | ForEach-Object {
                    $bus = ([string]$more["$_|DEVPKEY_Device_BusReportedDeviceDesc"]).Trim()
                    if ($bus) { $bus } elseif ($entities[$_]) { [string]$entities[$_].Name }
                } | Where-Object { $_ })
            NetMedium     = $media[$id]
            Enabled       = $states[$byId[$id]]
        }
    }
}

function Get-PcPnpProperties([string[]]$Ids, [string[]]$Keys) {
    # "<INSTANCE ID>|<key>" -> data. One device per call: given several IDs at once,
    # Get-PnpDeviceProperty sometimes labels a row with the wrong device.
    $result = @{}
    foreach ($id in @($Ids | Where-Object { $_ })) {
        foreach ($p in @(Get-PnpDeviceProperty -InstanceId $id -KeyName $Keys -ErrorAction SilentlyContinue)) {
            if ($null -ne $p.Data) { $result["$($id.ToUpperInvariant())|$($p.KeyName)"] = $p.Data }
        }
    }
    return $result
}

# --- Grouping and names (pure, tested) ------------------------------------------------------------

function Get-PcDeviceKind($Raw) {
    switch ($Raw.Class) {
        'Net' {
            # NDIS physical medium: 1 wireless LAN, 9 native 802.11, 14 802.3 (Ethernet)
            if (@(1, 9) -contains $Raw.NetMedium -or $Raw.Name -match 'Wi-?Fi|Wireless|WLAN|802\.11') { return 'wifi' }
            if ($Raw.NetMedium -eq 14 -or $Raw.Name -match 'Ethernet|GbE|Gigabit|\bLAN\b') { return 'ethernet' }
            return 'network'
        }
        'Bluetooth' { return 'bluetooth' }
        'Keyboard' { return 'keyboard' }
        'Mouse' { return 'mouse' }
        'USB' {
            # By ID and driver, not by the name, which Windows translates ("Concentrateur USB racine")
            if ($Raw.InstanceId -like 'USB\ROOT_HUB*' -or $Raw.Service -match '^usbhub') { return 'usbHub' }
            if ($Raw.InstanceId -like 'PCI\*' -or $Raw.Service -match '^usb[xeou]hci') { return 'usbController' }
            if ($Raw.Name -match 'Hub') { return 'usbHub' }
            return 'usbDevice'
        }
        default {
            if (@($Raw.ChildClasses) -contains 'Keyboard') { return 'keyboard' }
            if (@($Raw.ChildClasses) -contains 'Mouse') { return 'mouse' }
            return 'input'
        }
    }
}

function ConvertTo-PcPowerDevices([object[]]$Inventory) {
    # One entry per physical device: the interfaces of a composite USB device (a keyboard's two
    # "USB Input Device" entries, IDs with &MI_xx) share its parent and are changed together. A
    # single-interface device's parent is a hub, so it stays on its own. Only $PcDevicePowerClasses.
    $generic = @('', 'HID Device', 'USB Input Device', 'USB Composite Device')
    $groups = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]'
    foreach ($raw in @($Inventory | Where-Object { $_ -and $script:PcDevicePowerClasses -contains $_.Class })) {
        [string]$key = if ($raw.Class -eq 'HIDClass' -and $raw.ParentId -and $raw.InstanceId -match '&MI_[0-9A-F]{2}') { $raw.ParentId } else { $raw.InstanceId }
        if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object System.Collections.Generic.List[object] }
        $groups[$key].Add($raw)
    }
    $byId = @{}
    foreach ($raw in @($Inventory | Where-Object { $_ })) { $byId[[string]$raw.InstanceId] = $raw }
    $devices = foreach ($key in @($groups.Keys)) {
        $members = @($groups[$key].ToArray())
        $kinds = @($members | ForEach-Object { Get-PcDeviceKind $_ })
        # A mouse with a keyboard interface (or the other way round) is neither for sure
        $kind = if ($kinds -contains 'keyboard' -and $kinds -contains 'mouse') { 'input' }
        else { $script:PcDeviceKinds | Where-Object { $kinds -contains $_ } | Select-Object -First 1 }
        # A product name the device itself reports beats Windows' generic "USB Input Device". Only
        # an interface (&MI_xx) takes its parent's name; a single device's parent is a hub.
        $hid = @($members | Where-Object { $_.Class -eq 'HIDClass' })
        $name = @($members | ForEach-Object { $_.BusName; if ($_.InstanceId -match '&MI_[0-9A-F]{2}') { $_.ParentBusName } } |
                Where-Object { $generic -notcontains $_ -and $_ -notmatch 'Hub$' }) | Select-Object -First 1
        if ($hid.Count -eq 0 -or -not $name) { $name = $(if ($hid.Count -gt 0) { $hid[0].Name } else { $members[0].Name }) }
        # What is plugged into a hub or controller tells them apart; a keyboard's or adapter's own
        # sub-functions would only be noise. A controller's child is its root hub, so it shows what
        # is plugged into that.
        $connected = @(foreach ($m in $members) {
                if ($kind -eq 'usbController') {
                    foreach ($c in @($m.ChildIds)) { if ($byId[[string]$c]) { $byId[[string]$c].ChildNames } }
                } elseif ($kind -like 'usb*') { $m.ChildNames }
            }) | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 3
        $on = @($members | Where-Object { $_.Enabled }).Count
        [pscustomobject]@{
            Key       = $key
            Name      = $name
            Kind      = $kind
            Connected = @($connected)
            Instances = @($members | ForEach-Object InstanceName)
            State     = $(if ($on -eq $members.Count) { 'CanTurnOff' } elseif ($on -eq 0) { 'AlwaysOn' } else { 'Mixed' })
        }
    }
    @($devices) | Sort-Object @{ Expression = { [array]::IndexOf($script:PcDeviceKinds, $_.Kind) } }, Name
}

function Get-PcPowerDevices { ConvertTo-PcPowerDevices @(Get-PcPowerDeviceInventory) }

# --- Changes through the tweak engine -------------------------------------------------------------

function Get-PcDeviceTweakId([string]$Key) {
    # Stable per physical device, short, and free of the backslashes and ampersands in instance IDs
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Key.ToUpperInvariant())) } finally { $sha.Dispose() }
    return 'device.power.' + (-join ($hash[0..7] | ForEach-Object { $_.ToString('x2') }))
}

function New-PcDeviceTweak([string]$Id, [string]$Name, [object[]]$Actions) {
    [pscustomobject]@{
        id = $Id; category = 'devices'; scope = 'machine'; risk = 'safe'; evidence = 'learn'
        reference = $script:PcDevicePowerReference; title = $Name; description = ''; label = $Name
        actions = @($Actions)
    }
}

function Get-PcDeviceTweak($Device, [bool]$Enabled) {
    # $Enabled = $true lets Windows turn the device off (the box ticked), $false keeps it on.
    # History shows the label; three "USB Root Hub" entries need what is plugged into them.
    $label = $Device.Name
    if ($Device.Kind -like 'usb*' -and @($Device.Connected).Count -gt 0) { $label = '{0} · {1}' -f $Device.Name, (@($Device.Connected) -join ', ') }
    New-PcDeviceTweak (Get-PcDeviceTweakId $Device.Key) $label @($Device.Instances | ForEach-Object {
        [pscustomobject]@{ type = 'devicePower'; instanceName = $_; enabled = $Enabled }
    })
}

function Get-PcDeviceUndoTweak($Entry) {
    # The tweak a journal entry was made with: each record holds the value PitCrew set ("enabled";
    # "before" for the undo). Which device to touch is checked again against the live list.
    New-PcDeviceTweak $Entry.tweakId $(if ($Entry.label) { [string]$Entry.label } else { $Entry.tweakId }) @(
        foreach ($r in @($Entry.actions)) {
            if ($r.type -ne 'devicePower' -or -not $r.target -or $r.before -isnot [bool] -or $r.enabled -isnot [bool]) { continue }
            [pscustomobject]@{ type = 'devicePower'; instanceName = [string]$r.target; enabled = $r.enabled }
        })
}

function Set-PcDevicePower($Device, [bool]$Enabled) {
    # When PitCrew made the opposite change, undoing it puts back what was there before; otherwise
    # this is a new change with its own Undo. Returns $true when something changed.
    $id = Get-PcDeviceTweakId $Device.Key
    $changed = $false
    $entry = @(Get-PcMyJournalEntries) | Where-Object { $_.tweakId -eq $id } | Select-Object -First 1
    if ($entry) {
        $undo = Get-PcDeviceUndoTweak $entry
        if (@($undo.actions | Where-Object { $_.enabled -ne $Enabled }).Count -gt 0) {
            [void](Undo-PcTweak $undo)
            $changed = $true
        }
    }
    $tweak = Get-PcDeviceTweak $Device $Enabled
    if ((Get-PcTweakState $tweak) -ne 'Applied') { $changed = [bool](Invoke-PcTweak $tweak) -or $changed }
    return $changed
}

# Action handlers used by the tweak engine. Each type implements:
#   Test-Pc<Noun>ActionAvailable  (optional) - does the thing exist on this PC?
#   Test-Pc<Noun>ActionApplied    - is it already as the tweak wants?
#   Invoke-Pc<Noun>Action         - apply; returns a record with the previous state
#   Undo-Pc<Noun>Action           - put the previous state back
# Where to act always comes from the catalog ($Action). The record, which comes back from the
# journal file, only supplies previous values, and those are validated before use.
# Every call into Windows goes through a small wrapper (Set-PcServiceStartup, powercfg...) so tests
# can replace it; with a registry redirect active the real wrappers refuse to run.

$script:PcActionTypes = @{
    registry      = @{ Noun = 'Registry'; MachineOnly = $false }
    dxSetting     = @{ Noun = 'DxSetting'; MachineOnly = $false }
    service       = @{ Noun = 'Service'; MachineOnly = $true }
    scheduledTask = @{ Noun = 'ScheduledTask'; MachineOnly = $true }
    powerPlan     = @{ Noun = 'PowerPlan'; MachineOnly = $true }
    hibernation   = @{ Noun = 'Hibernation'; MachineOnly = $true }
    # Built on the fly by src\Modules\Devices.ps1, never in the catalog
    devicePower   = @{ Noun = 'DevicePower'; MachineOnly = $true }
}

function Get-PcActionNoun([string]$Type) {
    $info = $script:PcActionTypes[$Type]
    if (-not $info) { throw "Unsupported action type: $Type" }
    return $info.Noun
}

function Assert-PcRealSystem([string]$What) {
    if ($Pc.RegistryRedirect) { throw "Refusing to change the real system ($What) while the registry is redirected" }
}

function Test-PcGuid([string]$Value) {
    return $Value -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
}

# --- registry ---------------------------------------------------------------------------------

function Test-PcRegistryActionApplied($Action) {
    $current = Get-PcRegistryValue $Action.path $Action.name
    if ($Action.absent) { return -not $current.Exists }
    return $current.Exists -and $current.Kind -eq $Action.kind -and
        (Test-PcRegistryDataEqual $Action.kind $current.Data $Action.value)
}

function Invoke-PcRegistryAction($Action) {
    $before = Get-PcRegistryValue $Action.path $Action.name
    # "absentOnly" targets load code (e.g. a COM server path): PitCrew only ever creates and later
    # deletes them, and won't take over a value another program already set
    if ($Action.restoreBefore -eq 'absentOnly' -and $before.Exists) { throw (Get-PcText 'error.targetInUse') }
    $createdKeys = @()
    if ($Action.absent) { Remove-PcRegistryValue $Action.path $Action.name }
    else { $createdKeys = Set-PcRegistryValue $Action.path $Action.name $Action.kind $Action.value }
    [pscustomobject]@{
        before      = [pscustomobject]@{ exists = $before.Exists; kind = $before.Kind; data = $before.Data }
        createdKeys = @($createdKeys)
    }
}

function Get-PcAllowedCreatedKeys([string]$Path, $Record) {
    # A recorded key is only removed if it is this action's own key or one of its parents
    $allowed = @()
    $probe = Resolve-PcRegistryPath $Path
    while ($probe) { $allowed += $probe; $probe = Split-Path $probe -Parent }
    @($Record.createdKeys) | Where-Object { $_ -and ($allowed -contains $_) }
}

function Undo-PcRegistryAction($Action, $Record) {
    if ($Action.restoreBefore -eq 'absentOnly') {
        # Never write a value taken from the journal into a code-loading location
        Remove-PcRegistryValue $Action.path $Action.name
    } elseif ($Record.before.exists) {
        if ($script:PcRegistryKinds -notcontains $Record.before.kind) { throw "Journal has an invalid registry kind: $($Record.before.kind)" }
        [void](Set-PcRegistryValue $Action.path $Action.name $Record.before.kind $Record.before.data)
    } else {
        Remove-PcRegistryValue $Action.path $Action.name
    }
    $keys = @(Get-PcAllowedCreatedKeys $Action.path $Record)
    if ($keys.Count -gt 0) { Remove-PcEmptyKeys $keys }
}

# --- dxSetting: one "key=value;" pair inside DirectXUserGlobalSettings ---------------------------

$script:PcDxPath = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$script:PcDxName = 'DirectXUserGlobalSettings'

function ConvertFrom-PcDxSettings([string]$Text) {
    $pairs = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($part in ($Text -split ';')) {
        if ($part -match '^\s*([^=]+?)\s*=\s*(.*?)\s*$') { $pairs[$Matches[1]] = $Matches[2] }
    }
    return , $pairs
}

function ConvertTo-PcDxSettings($Pairs) {
    (@($Pairs.Keys | ForEach-Object { '{0}={1};' -f $_, $Pairs[$_] }) -join '')
}

function Get-PcDxSetting([string]$Key) {
    $current = Get-PcRegistryValue $script:PcDxPath $script:PcDxName
    $pairs = ConvertFrom-PcDxSettings ([string]$current.Data)
    [pscustomobject]@{ ValueExists = $current.Exists; Present = $pairs.Contains($Key); Value = $pairs[$Key]; Pairs = $pairs }
}

function Set-PcDxSetting([string]$Key, $Value, [switch]$Remove) {
    $state = Get-PcDxSetting $Key
    if ($Remove) { $state.Pairs.Remove($Key) } else { $state.Pairs[$Key] = [string]$Value }
    if ($state.Pairs.Count -eq 0) { Remove-PcRegistryValue $script:PcDxPath $script:PcDxName; return @() }
    return Set-PcRegistryValue $script:PcDxPath $script:PcDxName 'String' (ConvertTo-PcDxSettings $state.Pairs)
}

function Test-PcDxSettingActionApplied($Action) {
    $s = Get-PcDxSetting $Action.key
    return $s.Present -and $s.Value -ceq [string]$Action.value
}

function Invoke-PcDxSettingAction($Action) {
    $s = Get-PcDxSetting $Action.key
    $created = Set-PcDxSetting $Action.key $Action.value
    [pscustomobject]@{
        before      = [pscustomobject]@{ present = $s.Present; value = $s.Value }
        createdKeys = @($created)
    }
}

function Undo-PcDxSettingAction($Action, $Record) {
    if ($Record.before.present) {
        $old = [string]$Record.before.value
        if ($old -match '[;=]') { throw "Journal has an invalid DirectX setting value: $old" }
        [void](Set-PcDxSetting $Action.key $old)
    } else {
        [void](Set-PcDxSetting $Action.key -Remove)
    }
    $keys = @(Get-PcAllowedCreatedKeys $script:PcDxPath $Record)
    if ($keys.Count -gt 0) { Remove-PcEmptyKeys $keys }
}

# --- service: start type ---------------------------------------------------------------------

# Start / DelayedAutostart values in HKLM\SYSTEM\CurrentControlSet\Services\<name>
$script:PcStartTypes = @{
    Automatic        = @{ Start = 2; Delayed = 0; Sc = 'auto' }
    AutomaticDelayed = @{ Start = 2; Delayed = 1; Sc = 'delayed-auto' }
    Manual           = @{ Start = 3; Delayed = 0; Sc = 'demand' }
    Disabled         = @{ Start = 4; Delayed = 0; Sc = 'disabled' }
}

function Get-PcServiceKey([string]$Name) { "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" }

function Get-PcServiceStartup([string]$Name) {
    $start = Get-PcRegistryValue (Get-PcServiceKey $Name) 'Start'
    if (-not $start.Exists) { return $null }
    $delayed = Get-PcRegistryValue (Get-PcServiceKey $Name) 'DelayedAutostart'
    $d = 0
    if ($delayed.Exists) { $d = [int]$delayed.Data }
    foreach ($k in $script:PcStartTypes.Keys) {
        $t = $script:PcStartTypes[$k]
        if ($t.Start -eq [int]$start.Data -and ($t.Start -ne 2 -or $t.Delayed -eq $d)) { return $k }
    }
    return "Other$($start.Data)"   # boot/system drivers: never touched
}

function Set-PcServiceStartup([string]$Name, [string]$StartupType) {
    Assert-PcRealSystem "service $Name"
    $sc = $script:PcStartTypes[$StartupType].Sc
    # sc.exe, not "sc" (that's Set-Content); the space after "start=" is required
    $output = & sc.exe config $Name start= $sc 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sc.exe config $Name start= $sc failed ($LASTEXITCODE): $output" }
}

function Test-PcServiceActionAvailable($Action) { [bool](Get-PcServiceStartup $Action.name) }

function Test-PcServiceActionApplied($Action) { (Get-PcServiceStartup $Action.name) -eq $Action.startupType }

function Invoke-PcServiceAction($Action) {
    if (-not $script:PcStartTypes.ContainsKey($Action.startupType)) { throw "Invalid startupType: $($Action.startupType)" }
    $before = Get-PcServiceStartup $Action.name
    if (-not $script:PcStartTypes.ContainsKey($before)) { throw "Service $($Action.name) has a start type PitCrew doesn't change ($before)" }
    Set-PcServiceStartup $Action.name $Action.startupType
    [pscustomobject]@{ before = [pscustomobject]@{ startupType = $before } }
}

function Undo-PcServiceAction($Action, $Record) {
    $old = [string]$Record.before.startupType
    if (-not $script:PcStartTypes.ContainsKey($old)) { throw "Journal has an invalid service start type: $old" }
    Set-PcServiceStartup $Action.name $old
}

# --- scheduledTask: enabled / disabled -----------------------------------------------------------

function Get-PcScheduledTaskEnabled([string]$Path, [string]$Name) {
    # $null only when the task doesn't exist; any other error (access denied) is raised, so a task
    # that can't be read isn't mistaken for a missing one and its undo record isn't dropped
    try {
        $task = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop
    } catch {
        # "Not found" arrives as a CimJobException with category ObjectNotFound
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound' -or $_.FullyQualifiedErrorId -like 'CmdletizationQuery_NotFound*') { return $null }
        throw
    }
    if (-not $task) { return $null }
    return [bool]($task.State -ne 'Disabled')
}

function Set-PcScheduledTaskEnabled([string]$Path, [string]$Name, [bool]$Enabled) {
    Assert-PcRealSystem "task $Path$Name"
    if ($Enabled) { $null = Enable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop }
    else { $null = Disable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop }
}

function Test-PcScheduledTaskActionAvailable($Action) { $null -ne (Get-PcScheduledTaskEnabled $Action.path $Action.name) }

function Test-PcScheduledTaskActionApplied($Action) { (Get-PcScheduledTaskEnabled $Action.path $Action.name) -eq [bool]$Action.enabled }

function Invoke-PcScheduledTaskAction($Action) {
    if (-not $Action.path.EndsWith('\')) { throw "Task path must end with a backslash: $($Action.path)" }
    $before = Get-PcScheduledTaskEnabled $Action.path $Action.name
    Set-PcScheduledTaskEnabled $Action.path $Action.name ([bool]$Action.enabled)
    [pscustomobject]@{ before = [pscustomobject]@{ enabled = [bool]$before } }
}

function Undo-PcScheduledTaskAction($Action, $Record) {
    if ($Record.before.enabled -isnot [bool]) { throw 'Journal has an invalid task state' }
    Set-PcScheduledTaskEnabled $Action.path $Action.name $Record.before.enabled
}

# --- powerPlan: make a plan active (recreating it from its template if missing) ------------------

function Get-PcActivePowerScheme {
    $text = (& powercfg.exe /getactivescheme) -join ' '
    if ($text -match '([0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})') { return $Matches[1].ToLowerInvariant() }
    throw 'Could not read the active power plan'
}

function Get-PcPowerSchemes {
    # Plan names are translated, so only the GUIDs are read
    [regex]::Matches(((& powercfg.exe /list) -join "`n"), '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}') |
        ForEach-Object { $_.Value.ToLowerInvariant() }
}

function Copy-PcPowerScheme([string]$Source, [string]$Destination) {
    Assert-PcRealSystem 'power plan'
    $null = & powercfg.exe /duplicatescheme $Source $Destination
    if ($LASTEXITCODE -ne 0) { throw "powercfg /duplicatescheme $Source failed ($LASTEXITCODE)" }
}

function Set-PcActivePowerScheme([string]$Guid) {
    Assert-PcRealSystem 'power plan'
    $null = & powercfg.exe /setactive $Guid
    # Modern Standby PCs only allow Balanced; setactive may "succeed" without switching
    if ($LASTEXITCODE -ne 0 -or (Get-PcActivePowerScheme) -ne $Guid.ToLowerInvariant()) {
        throw (Get-PcText 'error.powerPlan')
    }
}

function Remove-PcPowerScheme([string]$Guid) {
    Assert-PcRealSystem 'power plan'
    $null = & powercfg.exe /delete $Guid
}

function Test-PcPowerPlanActionApplied($Action) { (Get-PcActivePowerScheme) -eq $Action.guid.ToLowerInvariant() }

function Invoke-PcPowerPlanAction($Action) {
    if (-not (Test-PcGuid $Action.guid) -or -not (Test-PcGuid $Action.source)) { throw 'Invalid power plan GUID in catalog' }
    $guid = $Action.guid.ToLowerInvariant()
    $before = Get-PcActivePowerScheme
    $created = $false
    if (@(Get-PcPowerSchemes) -notcontains $guid) {
        Copy-PcPowerScheme $Action.source $guid
        $created = $true
    }
    try {
        Set-PcActivePowerScheme $guid
    } catch {
        if ($created) { try { Remove-PcPowerScheme $guid } catch { } }
        throw
    }
    [pscustomobject]@{ before = [pscustomobject]@{ activeScheme = $before; created = $created } }
}

$script:PcBalancedScheme = '381b4222-f694-41f0-9685-ff5bb260df2e'

function Undo-PcPowerPlanAction($Action, $Record) {
    $old = [string]$Record.before.activeScheme
    if (-not (Test-PcGuid $old)) { throw "Journal has an invalid power plan: $old" }
    $schemes = @(Get-PcPowerSchemes)
    if ($schemes -notcontains $old.ToLowerInvariant()) {
        # The previous plan was deleted since; Balanced is the Windows default and always exists
        Write-PcLog "Power plan $old no longer exists; switching back to Balanced" 'Warn'
        $old = $script:PcBalancedScheme
    }
    Set-PcActivePowerScheme $old
    if ($Record.before.created -eq $true) { Remove-PcPowerScheme $Action.guid }
}

# --- hibernation ---------------------------------------------------------------------------------

$script:PcPowerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'

function Get-PcHibernationEnabled {
    $v = Get-PcRegistryValue $script:PcPowerKey 'HibernateEnabled'
    if (-not $v.Exists) { return $null }
    return [bool]([int]$v.Data -ne 0)
}

function Set-PcHibernation([bool]$Enabled) {
    Assert-PcRealSystem 'hibernation'
    $mode = if ($Enabled) { 'on' } else { 'off' }
    $null = & powercfg.exe /hibernate $mode
    if ($LASTEXITCODE -ne 0) { throw "powercfg /hibernate $mode failed ($LASTEXITCODE)" }
}

function Test-PcHibernationActionAvailable($Action) { $null -ne (Get-PcHibernationEnabled) }

function Test-PcHibernationActionApplied($Action) { (Get-PcHibernationEnabled) -eq [bool]$Action.enabled }

function Invoke-PcHibernationAction($Action) {
    $before = Get-PcHibernationEnabled
    Set-PcHibernation ([bool]$Action.enabled)
    [pscustomobject]@{ before = [pscustomobject]@{ enabled = [bool]$before } }
}

function Undo-PcHibernationAction($Action, $Record) {
    if ($Record.before.enabled -isnot [bool]) { throw 'Journal has an invalid hibernation state' }
    Set-PcHibernation $Record.before.enabled
}

# --- devicePower: "Allow the computer to turn off this device" (src\Modules\Devices.ps1) ----------

function Resolve-PcDevicePowerInstance([string]$Name) {
    # The live WMI instance with this name (any case), or $null: only a device that is plugged in
    # and offers the box can be changed, whatever a journal record names
    $states = Get-PcDevicePowerStates
    foreach ($key in $states.Keys) { if ($key -eq $Name) { return [pscustomobject]@{ Name = $key; Enabled = $states[$key] } } }
    return $null
}

function Test-PcDevicePowerActionAvailable($Action) { [bool](Resolve-PcDevicePowerInstance $Action.instanceName) }

function Test-PcDevicePowerActionApplied($Action) {
    $live = Resolve-PcDevicePowerInstance $Action.instanceName
    return $live -and $live.Enabled -eq [bool]$Action.enabled
}

function Invoke-PcDevicePowerAction($Action) {
    $live = Resolve-PcDevicePowerInstance $Action.instanceName
    if (-not $live) { throw (Get-PcText 'devices.gone') }
    Set-PcDevicePowerEnabled $live.Name ([bool]$Action.enabled)
    # Also what was set: an interface that already had that value keeps before = enabled, so the
    # value can't be worked out from "before" alone
    [pscustomobject]@{ before = [bool]$live.Enabled; enabled = [bool]$Action.enabled }
}

function Undo-PcDevicePowerAction($Action, $Record) {
    if ($Record.before -isnot [bool]) { throw 'Journal has an invalid device power state' }
    $live = Resolve-PcDevicePowerInstance $Action.instanceName
    if (-not $live) { throw (Get-PcText 'devices.gone') }
    Set-PcDevicePowerEnabled $live.Name $Record.before
}

# --- refresh hooks (run after apply and undo) -----------------------------------------------------

function Update-PcMouseSettings {
    # Applies HKCU\Control Panel\Mouse now instead of at next sign-in. SPIF_SENDCHANGE only:
    # SPIF_UPDATEINIFILE would make Windows rewrite the values the journal recorded.
    Assert-PcRealSystem 'mouse settings'
    if (-not ('PitCrew.NativeMouse' -as [type])) {
        Add-Type -Namespace PitCrew -Name NativeMouse -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfo(uint action, uint param, int[] values, uint winIni);
'@
    }
    $m = Get-ItemProperty 'HKCU:\Control Panel\Mouse'
    $values = [int[]]@([int]$m.MouseThreshold1, [int]$m.MouseThreshold2, [int]$m.MouseSpeed)
    [void][PitCrew.NativeMouse]::SystemParametersInfo(0x0004, 0, $values, 0x02)   # SPI_SETMOUSE, SPIF_SENDCHANGE
}

function Invoke-PcRefresh([string]$Name) {
    switch ($Name) {
        'mouse' { Update-PcMouseSettings }
        ''      { }
        default { throw "Unknown refresh: $Name" }
    }
}

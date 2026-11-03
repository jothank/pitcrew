# Registry access used by the tweak engine. Paths in tweak files use the PowerShell drive form
# (HKLM:\..., HKCU:\...). With a redirect set (tests), HKLM:\X becomes <redirect>\HKLM\X.

$script:PcRegistryKinds = @('DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary')

function Get-PcRegistryCmdletName([string]$Name) {
    # A key's default value has an empty name in the registry API, "(default)" for the cmdlets
    if ($Name -eq '') { return '(default)' }
    return $Name
}

function Resolve-PcRegistryPath([string]$Path) {
    if ($Path -notmatch '^(HKLM|HKCU):\\(.+)$') { throw "Unsupported registry path: $Path" }
    if (-not $Pc.RegistryRedirect) { return $Path }
    return Join-Path $Pc.RegistryRedirect ($Matches[1] + '\' + $Matches[2])
}

function Get-PcRegistryValue([string]$Path, [string]$Name) {
    $real = Resolve-PcRegistryPath $Path
    $key = Get-Item -LiteralPath $real -ErrorAction SilentlyContinue
    if (-not $key) { return [pscustomobject]@{ KeyExists = $false; Exists = $false; Kind = $null; Data = $null } }
    if (@($key.GetValueNames()) -notcontains $Name) {
        return [pscustomobject]@{ KeyExists = $true; Exists = $false; Kind = $null; Data = $null }
    }
    $kind = [string]$key.GetValueKind($Name)
    $raw = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return [pscustomobject]@{ KeyExists = $true; Exists = $true; Kind = $kind; Data = (ConvertTo-PcPortableData $kind $raw) }
}

function ConvertTo-PcPortableData([string]$Kind, $Raw) {
    # Form stored in the journal and compared against tweak targets: plain JSON-friendly values
    switch ($Kind) {
        'DWord'       { return [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32](ConvertTo-PcNativeData 'DWord' $Raw)), 0) }
        'QWord'       { return [int64]$Raw }
        # The leading comma keeps a one-item array from being unrolled into a plain string
        'MultiString' { return , ([string[]]@($Raw)) }
        'Binary'      { return [Convert]::ToBase64String([byte[]]$Raw) }
        default       { return [string]$Raw }
    }
}

function ConvertTo-PcNativeData([string]$Kind, $Data) {
    # Form the registry API expects
    switch ($Kind) {
        'DWord' {
            $unsigned = [uint32]([int64]$Data -band [int64]4294967295)
            return [BitConverter]::ToInt32([BitConverter]::GetBytes($unsigned), 0)
        }
        'QWord'       { return [int64]$Data }
        'MultiString' { return , ([string[]]@($Data)) }
        'Binary' {
            if ($Data -is [string]) { return , ([Convert]::FromBase64String($Data)) }
            return , ([byte[]]@($Data))
        }
        default       { return [string]$Data }
    }
}

function Test-PcRegistryDataEqual([string]$Kind, $A, $B) {
    if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
    $left = ConvertTo-PcPortableData $Kind (ConvertTo-PcNativeData $Kind $A)
    $right = ConvertTo-PcPortableData $Kind (ConvertTo-PcNativeData $Kind $B)
    if ($Kind -eq 'MultiString') { return (@($left) -join "`0") -ceq (@($right) -join "`0") }
    return $left -ceq $right
}

function Set-PcRegistryValue([string]$Path, [string]$Name, [string]$Kind, $Data) {
    # Returns the keys this call had to create, deepest last, so undo can remove them again
    if ($script:PcRegistryKinds -notcontains $Kind) { throw "Unsupported registry kind: $Kind" }
    $real = Resolve-PcRegistryPath $Path
    $created = New-Object System.Collections.Generic.List[string]
    $probe = $real
    $missing = New-Object System.Collections.Generic.List[string]
    while ($probe -and -not (Test-Path -LiteralPath $probe)) {
        $missing.Insert(0, $probe)
        $probe = Split-Path $probe -Parent
    }
    foreach ($k in $missing) {
        New-Item -Path $k -Force | Out-Null
        $created.Add($k)
    }
    New-ItemProperty -LiteralPath $real -Name (Get-PcRegistryCmdletName $Name) -PropertyType $Kind -Value (ConvertTo-PcNativeData $Kind $Data) -Force | Out-Null
    return , $created.ToArray()
}

function Remove-PcRegistryValue([string]$Path, [string]$Name) {
    $real = Resolve-PcRegistryPath $Path
    if (-not (Test-Path -LiteralPath $real)) { return }
    if ($Name -ne '') {
        Remove-ItemProperty -LiteralPath $real -Name $Name -ErrorAction SilentlyContinue
        return
    }
    # Remove-ItemProperty can't delete an empty default value ("property does not exist"); the
    # registry API can
    if ($real -notmatch '^(HKLM|HKCU):\\(.+)$') { throw "Unsupported registry path: $real" }
    $hive = if ($Matches[1] -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
    $key = $hive.OpenSubKey($Matches[2], $true)
    if ($key) { try { $key.DeleteValue('', $false) } finally { $key.Close() } }
}

function Remove-PcEmptyKeys([string[]]$Keys) {
    # Keys are real paths recorded at apply time; only delete the ones still empty
    foreach ($k in @($Keys) | Sort-Object { $_.Length } -Descending) {
        $item = Get-Item -LiteralPath $k -ErrorAction SilentlyContinue
        if ($item -and $item.SubKeyCount -eq 0 -and $item.ValueCount -eq 0) {
            Remove-Item -LiteralPath $k -ErrorAction SilentlyContinue
        }
    }
}

# Startup programs: list them and turn them on or off the way Task Manager's Startup tab does.
# Nothing is ever deleted: the Run value or the shortcut stays, only the StartupApproved flag changes.

$script:PcRunKey = 'Software\Microsoft\Windows\CurrentVersion\Run'
$script:PcApprovedKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
# Tests point these at temp folders; $null means the real Startup folders
$script:PcStartupFolders = @{ User = $null; Common = $null }

function Get-PcStartupSources {
    $user = $script:PcStartupFolders.User
    if (-not $user) { $user = [Environment]::GetFolderPath('Startup') }
    $common = $script:PcStartupFolders.Common
    if (-not $common) { $common = [Environment]::GetFolderPath('CommonStartup') }
    # Hive, Kind (also the StartupApproved subkey), label, run key or folder
    @(
        @{ Hive = 'HKCU'; Kind = 'Run';           Source = 'HKCU Run';      Key = "HKCU:\$script:PcRunKey" }
        @{ Hive = 'HKLM'; Kind = 'Run';           Source = 'HKLM Run';      Key = "HKLM:\$script:PcRunKey" }
        @{ Hive = 'HKLM'; Kind = 'Run32';         Source = 'HKLM Run32';    Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' }
        @{ Hive = 'HKCU'; Kind = 'StartupFolder'; Source = 'User folder';   Folder = $user }
        @{ Hive = 'HKLM'; Kind = 'StartupFolder'; Source = 'Common folder'; Folder = $common }
    )
}

function Get-PcStartupApprovedPath([string]$Hive, [string]$Kind) {
    return "${Hive}:\$script:PcApprovedKey\$Kind"
}

function Get-PcStartupApproved([string]$Hive, [string]$Kind, [string]$Name) {
    # No value means enabled. Even first byte = enabled (2, 6), odd = disabled (3, 7).
    $v = Get-PcRegistryValue (Get-PcStartupApprovedPath $Hive $Kind) $Name
    if (-not $v.Exists -or $v.Kind -ne 'Binary') { return $true }
    $bytes = [Convert]::FromBase64String($v.Data)
    if ($bytes.Length -eq 0) { return $true }
    return (($bytes[0] -band 1) -eq 0)
}

function Get-PcCommandExePath([string]$Command) {
    # Path of the program in a Run command: quoted, or unquoted with spaces ("C:\Program Files\x\a.exe -min")
    if (-not $Command) { return '' }
    $text = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    if ($text -match '^"([^"]+)"') { return $Matches[1] }
    $parts = $text -split ' '
    $candidate = ''
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $candidate = ($parts[0..$i] -join ' ')
        if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) { return $candidate }
    }
    return $parts[0]
}

function Get-PcShortcutTarget([string]$Path) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        try { return [string]$shell.CreateShortcut($Path).TargetPath } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    } catch { return '' }
}

function Get-PcExePublisher([string]$Exe) {
    try {
        if ($Exe -and (Test-Path -LiteralPath $Exe -PathType Leaf)) {
            $company = (Get-Item -LiteralPath $Exe).VersionInfo.CompanyName
            if ($company) { return $company.Trim() }
        }
    } catch { }
    return ''
}

function New-PcStartupItem($Src, [string]$Name, [string]$ApprovedName, [string]$Command, [string]$Exe) {
    [pscustomobject]@{
        Id           = '{0}|{1}|{2}' -f $Src.Hive, $Src.Kind, $ApprovedName
        Name         = $Name
        Command      = $Command
        Source       = $Src.Source
        Scope        = if ($Src.Hive -eq 'HKLM') { 'machine' } else { 'user' }
        Enabled      = (Get-PcStartupApproved $Src.Hive $Src.Kind $ApprovedName)
        Publisher    = (Get-PcExePublisher $Exe)
        TargetExists = [bool]($Exe -and (Test-Path -LiteralPath $Exe -ErrorAction SilentlyContinue))
    }
}

function Get-PcStartupItems {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($src in Get-PcStartupSources) {
        try {
            if ($src.Key) {
                $key = Get-Item -LiteralPath (Resolve-PcRegistryPath $src.Key) -ErrorAction SilentlyContinue
                if (-not $key) { continue }
                foreach ($name in $key.GetValueNames()) {
                    if ($name -eq '') { continue }
                    $command = [string](Get-PcRegistryValue $src.Key $name).Data
                    $items.Add((New-PcStartupItem $src $name $name $command (Get-PcCommandExePath $command)))
                }
            } elseif ($src.Folder -and (Test-Path -LiteralPath $src.Folder -PathType Container)) {
                foreach ($file in Get-ChildItem -LiteralPath $src.Folder -File -Force -ErrorAction SilentlyContinue) {
                    if ($file.Name -ieq 'desktop.ini') { continue }
                    $target = if ($file.Extension -ieq '.lnk') { Get-PcShortcutTarget $file.FullName } else { $file.FullName }
                    $command = if ($target) { $target } else { $file.FullName }
                    $items.Add((New-PcStartupItem $src $file.BaseName $file.Name $command $target))
                }
            }
        } catch {
            Write-PcLog "Startup: could not read $($src.Source): $($_.Exception.Message)" 'Warn'
        }
    }
    return @($items | Sort-Object { $_.Name.ToLowerInvariant() })
}

function Set-PcStartupItemEnabled {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][bool]$Enabled)
    $parts = $Id -split '\|', 3
    if ($parts.Count -ne 3 -or $parts[0] -notin 'HKCU', 'HKLM' -or $parts[1] -notin 'Run', 'Run32', 'StartupFolder' -or -not $parts[2]) {
        throw "Invalid startup item id: $Id"
    }
    $hive, $kind, $name = $parts
    if ($kind -eq 'Run32' -and $hive -ne 'HKLM') { throw "Invalid startup item id: $Id" }
    # Same rule as the tweak engine: a redirected registry (tests) skips the admin and account checks
    if (-not $Pc.RegistryRedirect) {
        if ($hive -eq 'HKLM' -and -not (Test-PcAdmin)) { throw (Get-PcText 'error.needsAdmin') }
        if ($hive -eq 'HKCU' -and (Test-PcUserMismatch)) { throw (Get-PcText 'error.otherUser') }
    }
    $data = New-Object byte[] 12
    $data[0] = if ($Enabled) { 2 } else { 3 }
    if (-not $Enabled) { [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()).CopyTo($data, 4) }
    [void](Set-PcRegistryValue (Get-PcStartupApprovedPath $hive $kind) $name 'Binary' $data)
    Write-PcLog ("Startup item {0}: {1}" -f $Id, $(if ($Enabled) { 'enabled' } else { 'disabled' }))
}

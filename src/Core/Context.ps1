# Shared state for every PitCrew function. Background runspaces call Initialize-PcContext
# again with the same values, so nothing here may hold live objects (COM, WPF, handles).

function Initialize-PcContext {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$DataDir,
        [string]$Language,
        # Tests point every registry action at a throwaway key instead of the real hives
        [string]$RegistryRedirect,
        # Windows Sandbox and many VMs can't create restore points; only for testing there
        [switch]$SkipRestorePoint
    )
    if (-not $DataDir) { $DataDir = Join-Path $env:ProgramData 'PitCrew' }
    $script:Pc = @{
        Root             = $Root
        DataDir          = $DataDir
        RegistryRedirect = $RegistryRedirect
        SkipRestorePoint = [bool]$SkipRestorePoint
        Language         = 'en'
        Texts            = @{}
        WindowsInfo      = $null
        FormFactor       = $null
    }
    if (-not $Language) { $Language = Get-PcDefaultLanguage }
    Import-PcLocale $Language
}

function Get-PcContextArgs {
    # What a background runspace needs to rebuild the same context
    @{
        Root             = $Pc.Root
        DataDir          = $Pc.DataDir
        Language         = $Pc.Language
        RegistryRedirect = $Pc.RegistryRedirect
        SkipRestorePoint = $Pc.SkipRestorePoint
    }
}

function Test-PcAdmin {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PcCurrentUserSid {
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-PcInteractiveUserSid {
    # The desktop belongs to whoever owns explorer.exe in this session. If UAC was approved with a
    # different admin account, HKCU points at that admin, not at the person sitting at the PC.
    $sessionId = (Get-Process -Id $PID).SessionId
    $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$sessionId" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $explorer) { return $null }
    $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid -ErrorAction SilentlyContinue
    if ($owner -and $owner.ReturnValue -eq 0) { return $owner.Sid }
    return $null
}

function Test-PcUserMismatch {
    $interactive = Get-PcInteractiveUserSid
    return [bool]($interactive -and $interactive -ne (Get-PcCurrentUserSid))
}

function Get-PcWindowsInfo {
    if ($Pc.WindowsInfo) { return $Pc.WindowsInfo }
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $Pc.WindowsInfo = [pscustomobject]@{
        Edition        = $cv.EditionID          # Core, Professional, Enterprise, Education...
        Build          = [int]$cv.CurrentBuildNumber
        Ubr            = [int]$cv.UBR
        DisplayVersion = $cv.DisplayVersion
        ProductName    = $cv.ProductName
    }
    return $Pc.WindowsInfo
}

function Get-PcDataPath([string]$Child) {
    $path = Join-Path $Pc.DataDir $Child
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
    return $path
}

# The undo journal decides what an administrator's Undo writes, so its folder must not be
# writable by standard users. %ProgramData% lets any user create subfolders, hence the reset.
$script:PcTrustedOwners = @('S-1-5-32-544', 'S-1-5-18')                         # Administrators, SYSTEM
$script:PcUntrustedSids = @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0', 'S-1-5-4')    # Users, Authenticated Users, Everyone, Interactive
# WriteData, AppendData, WriteExtendedAttributes, DeleteSubdirectoriesAndFiles, WriteAttributes,
# Delete, ChangePermissions, TakeOwnership
$script:PcWriteRightsMask = 2 + 4 + 16 + 64 + 256 + 65536 + 262144 + 524288

function Test-PcDataDirTrusted([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($script:PcTrustedOwners -notcontains $owner) { return $false }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow') { continue }
        if ($script:PcUntrustedSids -contains $rule.IdentityReference.Value -and ([int]$rule.FileSystemRights -band $script:PcWriteRightsMask)) {
            return $false
        }
    }
    return $true
}

function Protect-PcDataDir {
    # Admin only. Creates the data folder, or resets its permissions if anyone else could have
    # written to it; a journal found in an untrusted folder is set aside, never trusted.
    $path = $Pc.DataDir
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
    if (Test-PcDataDirTrusted $path) { return }
    $journal = Join-Path $path 'journal.json'
    if (Test-Path -LiteralPath $journal) {
        $aside = Join-Path $path ('journal.untrusted-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))
        Move-Item -LiteralPath $journal -Destination $aside
        Write-PcLog "Journal in a folder with unsafe permissions moved to $aside" 'Warn'
    }
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier $rule[0]), $rule[1], 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $path -AclObject $acl
    Write-PcLog 'Data folder permissions set: Administrators and SYSTEM full control, Users read'
}

function Get-PcUntrustedJournals {
    if (-not (Test-Path -LiteralPath $Pc.DataDir)) { return }
    Get-ChildItem -LiteralPath $Pc.DataDir -Filter 'journal.untrusted-*.json' -ErrorAction SilentlyContinue | ForEach-Object FullName
}

function Get-PcLogDir {
    # ProgramData only accepts writes from the elevated process; without admin, log per user
    if (Test-PcAdmin) { return Get-PcDataPath 'logs' }
    $path = Join-Path $env:LOCALAPPDATA 'PitCrew\logs'
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
    return $path
}

function Write-PcLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level.ToUpperInvariant(), $Message
    Write-Verbose $line
    try {
        $file = Join-Path (Get-PcLogDir) ('pitcrew-{0:yyyy-MM-dd}.log' -f (Get-Date))
        [IO.File]::AppendAllText($file, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    } catch {
        # Logging must never break an apply or an undo
    }
}

function Read-PcJson([string]$Path) {
    # Windows PowerShell 5.1 reads files without a BOM as ANSI; JSON here is always UTF-8
    $parsed = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    # 5.1 also emits a top-level JSON array as one single object; returning the variable unrolls
    # it, so @(Read-PcJson ...) gives the items rather than a one-item list holding the array
    return $parsed
}

function Write-PcJson([string]$Path, $Object) {
    $json = ConvertTo-Json -InputObject $Object -Depth 12
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

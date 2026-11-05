# Shared state for every PitCrew function. Background runspaces call Initialize-PcContext
# again with the same values, so nothing here may hold live objects (COM, WPF, handles).

# The one place for the version: the About page, PitCrew.exe and the release zip all read it
$script:PcVersion = '0.1.1-beta'

# Where the project and its author live (About page). The repository links work once it is public.
$script:PcLinks = @{
    Repository     = 'https://github.com/jothank/pitcrew'
    Issues         = 'https://github.com/jothank/pitcrew/issues'
    AuthorGitHub   = 'https://github.com/jothank'
    AuthorLinkedIn = 'https://www.linkedin.com/in/jothank/'
}

# Donations by Pix (Brazil), shown on the About page. Name and city go into the Pix code (ASCII,
# at most 25 and 15 characters); the bank app shows the account holder's registered name anyway.
# After changing them, run tools\Build-PixQr.ps1 to redraw assets\pix-qr.png.
$script:PcDonation = @{
    PixKey  = '7405c643-a1be-43dc-97f3-ee468160668a'
    PixName = 'JONATHAN COSTA'
    PixCity = 'FLORIANOPOLIS'
}

# The taskbar ID of PitCrew's window, also given to the shortcuts src\Setup.ps1 creates, so the
# taskbar shows a running PitCrew and its pinned shortcut as one app
$script:PcAppId = 'JonathanCosta.PitCrew'
# Exists while a PitCrew window is open; src\Setup.ps1 won't replace or remove the files under it
$script:PcWindowMutexName = 'Global\PitCrew.Window'

# Choices made in the window (language, theme), per Windows user
$script:PcPreferencesKey = 'HKCU:\Software\PitCrew'

function Get-PcPreference([string]$Name) {
    try { return [string](Get-ItemPropertyValue -LiteralPath $script:PcPreferencesKey -Name $Name -ErrorAction Stop) } catch { return $null }
}

function Set-PcPreference([string]$Name, [string]$Value) {
    try {
        if (-not (Test-Path -LiteralPath $script:PcPreferencesKey)) { New-Item -Path $script:PcPreferencesKey -Force | Out-Null }
        Set-ItemProperty -LiteralPath $script:PcPreferencesKey -Name $Name -Value $Value -Type String -ErrorAction Stop
    } catch { Write-PcLog "Preference $Name not saved: $($_.Exception.Message)" 'Warn' }
}

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
    # The known-folder API, not $env:ProgramData: environment variables can be redirected per user
    if (-not $DataDir) { $DataDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'PitCrew' }
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
    # Writing into a folder someone else controls would follow their junctions as administrator
    Assert-PcDataTrusted
    $path = Join-Path $Pc.DataDir $Child
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
    elseif ($Child -and -not $Pc.RegistryRedirect -and -not (Test-PcPathTrusted $path)) {
        # A subfolder left over from before the folder was secured (a "logs" junction, say)
        throw (Get-PcText 'error.dataUntrusted')
    }
    return $path
}

# The undo journal decides what an administrator's Undo writes, so its folder may only be
# writable by Administrators and SYSTEM. %ProgramData% lets any user create subfolders (even a
# junction named PitCrew pointing at their own folder), so an existing folder is reused only when
# it is provably ours, and everything that reads or writes there checks that again.
$script:PcTrustedWriters = @(
    'S-1-5-18'                                                          # SYSTEM
    'S-1-5-32-544'                                                      # Administrators
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'    # TrustedInstaller
)
# Any right that lets someone change or replace content: WriteData, AppendData, WriteEA,
# DeleteChild, WriteAttributes, Delete, WriteDAC, WriteOwner, GENERIC_ALL, GENERIC_WRITE
$script:PcWriteRightsMask = [int64](2 + 4 + 16 + 64 + 256 + 65536 + 262144 + 524288 + 0x10000000 + 0x40000000)

function Test-PcPathTrusted([string]$Path) {
    # Any failure (no access to read the permissions, say) means "not trusted", never an error
    # that stops the window or, under another error preference, falls through to $true
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        if (@('S-1-5-32-544', 'S-1-5-18') -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { return $false }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -ne 'Allow') { continue }
            $sid = $rule.IdentityReference.Value
            if ($script:PcTrustedWriters -contains $sid) { continue }
            # CREATOR OWNER only reaches children, and only trusted accounts can create them here
            if ($sid -eq 'S-1-3-0' -and ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
            if (([int64][int]$rule.FileSystemRights) -band $script:PcWriteRightsMask) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

# Kept for the tests and older callers
function Test-PcDataDirTrusted([string]$Path) { Test-PcPathTrusted $Path }

function Protect-PcDataDir {
    # Admin only. A data folder that isn't provably ours (owned by someone else, writable by
    # others, or a junction) is moved aside and never read; a new one is created with its
    # permissions already set. Throws when that can't be done, and callers stay read-only.
    $path = $Pc.DataDir
    if (Test-Path -LiteralPath $path) {
        if (Test-PcPathTrusted $path) { return }
        # Unpredictable name: a user can't pre-create it to make the move fail every time
        $aside = '{0}.untrusted-{1:yyyyMMdd-HHmmss}-{2}' -f $path.TrimEnd('\'), (Get-Date), [guid]::NewGuid().ToString('N').Substring(0, 8)
        # Moving a junction moves the link itself, not what it points to
        [IO.Directory]::Move($path, $aside)
        Write-PcLog "Data folder with unsafe owner or permissions moved to $aside" 'Warn'
    }
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier $rule[0]), $rule[1], 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    # Created with its ACL in one step: no window with the inherited, user-writable permissions.
    # An elevated token's default owner is Administrators; the check below confirms it.
    [void][IO.Directory]::CreateDirectory($path, $acl)
    # If someone recreated the folder in between, CreateDirectory returned theirs untouched
    if (-not (Test-PcPathTrusted $path)) { throw "The data folder $path could not be secured" }
    Write-PcLog 'Data folder created: Administrators and SYSTEM full control, Users read'
}

function Assert-PcDataTrusted {
    # Before anything reads the journal to act on it or writes into the data folder
    if ($Pc.RegistryRedirect) { return }   # tests use a temp folder owned by the test user
    if (-not (Test-PcPathTrusted $Pc.DataDir)) { throw (Get-PcText 'error.dataUntrusted') }
    $journal = Join-Path $Pc.DataDir 'journal.json'
    if ((Test-Path -LiteralPath $journal) -and -not (Test-PcPathTrusted $journal)) { throw (Get-PcText 'error.dataUntrusted') }
}

function Get-PcUntrustedJournals {
    $parent = Split-Path $Pc.DataDir.TrimEnd('\') -Parent
    $leaf = Split-Path $Pc.DataDir.TrimEnd('\') -Leaf
    # Only set-aside folders that actually held a journal are worth telling the user about
    Get-ChildItem -LiteralPath $parent -Directory -Filter "$leaf.untrusted-*" -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'journal.json') } | ForEach-Object FullName
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

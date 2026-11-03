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

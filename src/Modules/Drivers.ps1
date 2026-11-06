# Driver inventory and driver updates from Windows Update. Only drivers Microsoft publishes on
# Windows Update are offered; for vendors that ship newer versions elsewhere we point to their tool.

$script:PcProblemCodes = @{
    1  = 'drivers.problem.misconfigured'
    10 = 'drivers.problem.cannotStart'
    18 = 'drivers.problem.reinstall'
    22 = 'drivers.problem.disabled'
    24 = 'drivers.problem.missing'
    28 = 'drivers.problem.noDriver'
    31 = 'drivers.problem.notWorking'
    43 = 'drivers.problem.stopped'
}

$script:PcVendorTips = [ordered]@{
    'NVIDIA'                      = 'drivers.tip.nvidia'
    'Advanced Micro Devices|^AMD' = 'drivers.tip.amd'
    'Intel'                       = 'drivers.tip.intel'
    'Realtek'                     = 'drivers.tip.realtek'
    'TP-Link'                     = 'drivers.tip.tplink'
}

function Format-PcDriverDate($Date) {
    # WMI hands back a local-time DateTime, which shows the day before; UTC is the real driver date
    if ($Date) { $Date.ToUniversalTime().ToString('yyyy-MM-dd') } else { '' }
}

function Get-PcDriverInventory {
    Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -and $_.DriverProviderName } | ForEach-Object {
        [pscustomobject]@{
            Device     = $_.DeviceName
            Class      = $_.DeviceClass
            Provider   = $_.DriverProviderName
            Version    = $_.DriverVersion
            Date       = Format-PcDriverDate $_.DriverDate
            Inf        = $_.InfName
            # Microsoft's inbox drivers carry 2006-06-21 by convention; that date doesn't mean "old"
            ThirdParty = $_.DriverProviderName -notmatch '^Microsoft'
        }
    } | Sort-Object Class, Device
}

function Get-PcProblemDevices {
    Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 } | ForEach-Object {
        $key = $script:PcProblemCodes[[int]$_.ConfigManagerErrorCode]
        $text = if ($key) { Get-PcText $key } else { Get-PcText 'drivers.problem.code' -FormatArgs $_.ConfigManagerErrorCode }
        $name = if ($_.Name) { $_.Name } else { $_.PNPDeviceID }
        [pscustomobject]@{ Device = $name; Problem = $text; Code = [int]$_.ConfigManagerErrorCode }
    }
}

function Get-PcDriverVendorTips($Inventory) {
    $thirdParty = @($Inventory | Where-Object ThirdParty)
    foreach ($pattern in $script:PcVendorTips.Keys) {
        if (@($thirdParty | Where-Object { $_.Provider -match $pattern }).Count -gt 0) { Get-PcText $script:PcVendorTips[$pattern] }
    }
}

$script:PcBoardSupport = [ordered]@{
    'ASUS'                 = 'https://www.asus.com/support/'
    'Gigabyte'             = 'https://www.gigabyte.com/Support'
    'Micro-Star|MSI'       = 'https://www.msi.com/support'
    'ASRock'               = 'https://www.asrock.com/support/'
    'Dell'                 = 'https://www.dell.com/support'
    'Lenovo'               = 'https://pcsupport.lenovo.com'
    'HP|Hewlett'           = 'https://support.hp.com'
    'Acer'                 = 'https://www.acer.com/support'
    'Samsung'              = 'https://www.samsung.com/support/'
    'Biostar'              = 'https://www.biostar.com.tw/app/en/support/'
}

function Get-PcBoardInfo {
    $board = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $board) { return $null }
    $url = $null
    foreach ($pattern in $script:PcBoardSupport.Keys) {
        if ($board.Manufacturer -match $pattern) { $url = $script:PcBoardSupport[$pattern]; break }
    }
    [pscustomobject]@{ Maker = Get-PcCompanyName $board.Manufacturer; Model = $board.Product; SupportUrl = $url }
}

function Get-PcCompanyName([string]$Name) {
    # "Gigabyte Technology Co., Ltd." -> "Gigabyte", "Dell Inc." -> "Dell", "ASUSTeK COMPUTER INC." -> "ASUSTeK"
    ($Name -replace '\s*\b(Technology|Co|Ltd|Inc|Corporation|Computer)\b\.?,?', '').Trim(' ,.')
}

function Test-PcDriverPolicyBlocksUpdates {
    $policy = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
    return [bool]($policy -and $policy.ExcludeWUDriversInQualityUpdate -eq 1)
}

function New-PcDriverIndex {
    $add = {
        param($index, $id, $device)
        if (-not $id) { return }
        $k = $id.ToUpperInvariant()
        if (-not $index.ContainsKey($k)) { $index[$k] = New-Object System.Collections.ArrayList }
        [void]$index[$k].Add($device)
    }
    $index = @{ ByHardwareId = @{}; ByCompatibleId = @{}; DriverByDeviceId = @{} }
    foreach ($dev in Get-CimInstance Win32_PnPEntity) {
        foreach ($id in @($dev.HardwareID)) { & $add $index.ByHardwareId $id $dev }
        foreach ($id in @($dev.CompatibleID)) { & $add $index.ByCompatibleId $id $dev }
    }
    foreach ($d in Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -and $_.DriverProviderName }) {
        $k = $d.DeviceID.ToUpperInvariant()
        if (-not $index.DriverByDeviceId.ContainsKey($k)) { $index.DriverByDeviceId[$k] = $d }
    }
    return $index
}

function ConvertTo-PcDriverOffer($Update, $Index) {
    # Hardware ID first; a Compatible ID is generic and many devices share the same one
    $matched = @()
    if ($Update.DriverHardwareID) {
        $key = $Update.DriverHardwareID.ToUpperInvariant()
        if ($Index.ByHardwareId.ContainsKey($key)) { $matched = @($Index.ByHardwareId[$key]) }
        elseif ($Index.ByCompatibleId.ContainsKey($key)) { $matched = @($Index.ByCompatibleId[$key]) }
    }
    $installed = @($matched | ForEach-Object { $Index.DriverByDeviceId[$_.PNPDeviceID.ToUpperInvariant()] } | Where-Object { $_ })
    $newest = $installed | Where-Object { $_.DriverDate } | Sort-Object DriverDate -Descending | Select-Object -First 1

    $offeredDate = $null
    if ($Update.DriverVerDate) { $offeredDate = ([datetime]$Update.DriverVerDate).Date }
    # Titles usually end with the version: "Realtek - Net - 10.68.815.2023"
    $offeredVersion = ''
    if ($Update.Title -match '(\d+(\.\d+){1,3})\s*$') { $offeredVersion = $Matches[1] }

    # Windows Update sometimes offers a driver older than the one installed from the vendor's site
    $verdict = 'recommended'
    if ($matched.Count -eq 0) { $verdict = 'unknownDevice' }
    elseif ($newest -and -not $offeredDate) { $verdict = 'noDate' }
    elseif ($newest -and $offeredDate -lt $newest.DriverDate.ToUniversalTime().Date) { $verdict = 'older' }
    elseif ($Update.DriverClass -eq 'Firmware') { $verdict = 'firmware' }    # restore points can't undo firmware
    elseif ($Update.DriverClass -eq 'Display') { $verdict = 'display' }      # the GPU vendor's app does this better

    $device = $Update.DriverModel
    if ($matched.Count -gt 1) { $device = '{0} (+{1})' -f $matched[0].Name, ($matched.Count - 1) }
    elseif ($matched.Count -eq 1) { $device = $matched[0].Name }

    $installedText = ''
    if ($newest) { $installedText = '{0} ({1})' -f $newest.DriverVersion, (Format-PcDriverDate $newest.DriverDate) }
    $offeredText = $offeredVersion
    if ($offeredDate) { $offeredText = ('{0} ({1})' -f $offeredVersion, $offeredDate.ToString('yyyy-MM-dd')).Trim() }

    [pscustomobject]@{
        UpdateId    = $Update.Identity.UpdateID
        Device      = $device
        Class       = $Update.DriverClass
        Installed   = $installedText
        Offered     = $offeredText
        Verdict     = $verdict
        Recommended = $verdict -eq 'recommended'
        CurrentInfs = @($installed | ForEach-Object { $_.InfName } | Where-Object { $_ -like 'oem*.inf' } | Sort-Object -Unique)
    }
}

function Search-PcDriverUpdates {
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'PitCrew'
    $searcher = $session.CreateUpdateSearcher()
    $searcher.ServerSelection = 2   # ssWindowsUpdate: ask Microsoft directly even if a WSUS server is set
    $result = $searcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    return @{ Session = $session; Updates = $result.Updates }
}

function Find-PcDriverUpdates {
    $search = Search-PcDriverUpdates
    $index = New-PcDriverIndex
    for ($i = 0; $i -lt $search.Updates.Count; $i++) { ConvertTo-PcDriverOffer $search.Updates.Item($i) $index }
}

function Install-PcDriverUpdates {
    # The caller creates the restore point first. COM objects can't cross runspaces, so the
    # updates are searched again here and picked by UpdateID.
    param([Parameter(Mandatory)][string[]]$UpdateIds, [string]$BackupRoot)

    $search = Search-PcDriverUpdates
    $index = New-PcDriverIndex
    $chosen = @(for ($i = 0; $i -lt $search.Updates.Count; $i++) {
        $u = $search.Updates.Item($i)
        if ($UpdateIds -contains $u.Identity.UpdateID) { [pscustomobject]@{ Update = $u; Offer = ConvertTo-PcDriverOffer $u $index } }
    })
    if ($chosen.Count -eq 0) { return @() }

    # Copies of the third-party drivers about to be replaced, for a manual rollback
    if (-not $BackupRoot) { $BackupRoot = Get-PcDataPath 'driver-backups' }
    $backupDir = Join-Path $BackupRoot (Get-Date -Format 'yyyy-MM-dd_HHmmss')
    foreach ($inf in @($chosen | ForEach-Object { $_.Offer.CurrentInfs } | Where-Object { $_ } | Sort-Object -Unique)) {
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        & pnputil.exe /export-driver $inf $backupDir | Out-Null
        Write-PcLog "Driver backup $inf -> exit $LASTEXITCODE"
    }

    $toDownload = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($c in $chosen) {
        if (-not $c.Update.EulaAccepted) { $c.Update.AcceptEula() }
        [void]$toDownload.Add($c.Update)
    }
    $downloader = $search.Session.CreateUpdateDownloader()
    $downloader.Updates = $toDownload
    [void]$downloader.Download()

    $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
    $installing = @()
    foreach ($c in $chosen) {
        if ($c.Update.IsDownloaded) { [void]$toInstall.Add($c.Update); $installing += $c }
        else { [pscustomobject]@{ Device = $c.Offer.Device; Result = 'downloadFailed'; RebootRequired = $false } }
    }
    if ($installing.Count -eq 0) { return }

    $installer = $search.Session.CreateUpdateInstaller()
    $installer.Updates = $toInstall
    $result = $installer.Install()
    $codes = @{ 2 = 'installed'; 3 = 'installedWithErrors'; 4 = 'failed'; 5 = 'aborted' }
    $installed = 0   # for the dashboard's totals
    for ($i = 0; $i -lt $installing.Count; $i++) {
        $r = $result.GetUpdateResult($i)
        $code = $codes[[int]$r.ResultCode]
        if (-not $code) { $code = "code$($r.ResultCode)" }
        if (@('installed', 'installedWithErrors') -contains $code) { $installed++ }
        Write-PcLog ('Driver {0}: {1} (0x{2:X8})' -f $installing[$i].Offer.Device, $code, $r.HResult)
        [pscustomobject]@{ Device = $installing[$i].Offer.Device; Result = $code; RebootRequired = [bool]$result.RebootRequired }
    }
    if ($installed -gt 0) { Add-PcStats @{ driversInstalled = $installed } }
}

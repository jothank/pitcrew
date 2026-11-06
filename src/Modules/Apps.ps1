# Preinstalled Store apps. Only apps listed in data/apps.json are offered, each with a verified
# Microsoft Store ID so it can be reinstalled through winget. Removal is for the current user;
# the packages that keep Windows, the Store and winget working are blocked outright.

$script:PcProtectedPackages = @(
    'Microsoft.WindowsStore'
    'Microsoft.DesktopAppInstaller'       # winget itself, and the way back for reinstalling
    'Microsoft.StorePurchaseApp'
    'Microsoft.SecHealthUI'               # Windows Security
    'Microsoft.VCLibs.*'
    'Microsoft.UI.Xaml.*'
    'Microsoft.NET.Native.*'
    'Microsoft.WindowsAppRuntime.*'
    'Microsoft.Windows.ShellExperienceHost'
    'Microsoft.Windows.StartMenuExperienceHost'
    'windows.immersivecontrolpanel'
)

function Test-PcProtectedPackage([string]$Name) {
    foreach ($pattern in $script:PcProtectedPackages) { if ($Name -like $pattern) { return $true } }
    return $false
}

function Get-PcAppCatalog {
    @(Read-PcJson (Join-Path $Pc.Root 'data\apps.json')) | Where-Object { -not (Test-PcProtectedPackage $_.package) }
}

function Get-PcRemovableApps {
    # One Get-AppxPackage call for all apps; one call per app is slow
    $installed = @{}
    foreach ($p in @(Get-AppxPackage -ErrorAction SilentlyContinue)) { $installed[$p.Name] = $p }
    foreach ($app in Get-PcAppCatalog) {
        $risk = if ($app.risk) { $app.risk } else { 'safe' }
        [pscustomobject]@{
            Package   = $app.package
            Name      = Resolve-PcLocalized $app.name
            Note      = Resolve-PcLocalized $app.note
            Risk      = $risk
            StoreId   = $app.storeId
            Installed = $installed.ContainsKey($app.package)
        }
    }
}

function Assert-PcAppsAllowed {
    # Get/Remove-AppxPackage act on the user running PitCrew, which is the wrong person if UAC
    # was approved with someone else's admin account
    if (Test-PcUserMismatch) { throw (Get-PcText 'error.otherUser') }
}

function Remove-PcAppxPackage([string]$FullName) {
    # The one place an app is removed, so tests can replace it; with a test redirect it refuses
    Assert-PcRealSystem "app $FullName"
    Remove-AppxPackage -Package $FullName -ErrorAction Stop
}

function Remove-PcApps {
    param([Parameter(Mandatory)][string[]]$Packages)
    Assert-PcAppsAllowed
    $catalog = @(Get-PcAppCatalog | ForEach-Object package)
    $removed = 0   # for the dashboard's totals: apps that were installed and are gone now
    try {
        foreach ($name in $Packages) {
            if ($catalog -notcontains $name -or (Test-PcProtectedPackage $name)) { throw "Not removable: $name" }
            $ok = $true
            $found = @(Get-AppxPackage -Name $name -ErrorAction SilentlyContinue)
            foreach ($pkg in $found) {
                try { Remove-PcAppxPackage $pkg.PackageFullName }
                catch { $ok = $false; Write-PcLog "Remove $name failed: $($_.Exception.Message)" 'Warn' }
            }
            if ($ok -and $found.Count -gt 0) { $removed++ }
            Write-PcLog "Removed app $name : $ok"
            [pscustomobject]@{ Package = $name; Removed = $ok }
        }
    } finally {
        if ($removed -gt 0) { Add-PcStats @{ appsRemoved = $removed } }
    }
}

function Install-PcApps {
    param([Parameter(Mandatory)][string[]]$Packages)
    Assert-PcAppsAllowed
    $catalog = @(Get-PcAppCatalog)
    foreach ($name in $Packages) {
        $app = $catalog | Where-Object package -eq $name | Select-Object -First 1
        if (-not $app) { throw "Unknown app: $name" }
        # The Store's terms are accepted by the user through the confirmation in the UI
        & winget.exe install --id $app.storeId --source msstore --exact --silent --disable-interactivity `
            --accept-package-agreements --accept-source-agreements | Out-Null
        $code = $LASTEXITCODE
        # 0x8A15002B: already installed
        $ok = $code -eq 0 -or $code -eq -1978335189
        Write-PcLog ('Reinstall {0} ({1}): exit 0x{2:X8}' -f $name, $app.storeId, $code)
        [pscustomobject]@{ Package = $name; Installed = $ok; ExitCode = $code }
    }
}

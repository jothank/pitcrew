<#
.SYNOPSIS
    Drives the window's read-only background jobs without showing the window: cleanup analysis,
    app list, driver summary and a Windows Update driver search. Nothing is changed on the PC.
    Run in an STA process: powershell -STA -File tests\Smoke-Window.ps1
#>
param([string]$Language = 'en')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Load.ps1')
Initialize-PcContext -Root $root -Language $Language
. (Join-Path $root 'src\UI\Window.ps1')
# Message boxes would block a headless run; print them instead
function Show-PcMessage([string]$Text, [string]$Icon = 'Information') { Write-Host "[message/$Icon] $Text" }

$failures = 0
# Choices made in the window go to a throwaway key, never to the real preferences
$script:PcPreferencesKey = 'HKCU:\Software\PitCrewTest\smoke-' + [guid]::NewGuid().ToString('N')
$window = New-PcWindow
$Ui.Timer.Stop()

function Wait-PcJob([int]$TimeoutSec = 300) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($script:PcJob -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; Complete-PcJob }
    if ($script:PcJob) { throw 'job timed out' }
}

# The window opens on the first page, which loads in the background
Wait-PcJob

function Test-Page([string]$Name, [scriptblock]$Start, [scriptblock]$Check) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $Start
    Wait-PcJob
    $items = @($Ui.Items.ItemsSource)
    $ok = & $Check $items
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ('{0,-16} {1} items, {2:N1}s, status "{3}"' -f $Name, $items.Count, $sw.Elapsed.TotalSeconds, $Ui.StatusText.Text) -ForegroundColor $color
    if (-not $ok) { $script:failures++ }
}

Test-Page 'cleanup' { Show-PcPage 'cleanup' } { param($items) $items.Count -eq @($script:PcCleanupTargets).Count }
Test-Page 'apps' { Show-PcPage 'apps' } { param($items) $items.Count -eq @(Get-PcAppCatalog).Count }
Test-Page 'drivers summary' { Show-PcPage 'drivers' } { param($items) [bool]$Ui.PageInfo.Text }
Test-Page 'driver search' { Invoke-PcSearchDrivers } { param($items) $Ui.EmptyText.Visibility -eq 'Visible' -or $items.Count -gt 0 }
Test-Page 'performance' { Show-PcPage 'performance' } { param($items) $items.Count -eq @($script:PcTweaks | Where-Object category -eq 'performance').Count }
Test-Page 'privacy' { Show-PcPage 'privacy' } { param($items) $items.Count -eq @($script:PcTweaks | Where-Object category -eq 'privacy').Count }
Test-Page 'explorer' { Show-PcPage 'explorer' } { param($items) $items.Count -eq @($script:PcTweaks | Where-Object category -eq 'explorer').Count }
Test-Page 'startup' { Show-PcPage 'startup' } { param($items) $Ui.EmptyText.Visibility -eq 'Visible' -or $items.Count -gt 0 }
Test-Page 'device power' { Show-PcPage 'devices' } {
    param($items)
    foreach ($i in $items) { Write-Host "    $($i.Title) | $($i.Detail) | $($i.Badge)" }
    # Read only: every card has a kind and a state in the current language
    ($Ui.EmptyText.Visibility -eq 'Visible' -or $items.Count -gt 0) -and
        @($items | Where-Object { $_.Detail -like 'devices.*' -or $_.Badge -like 'devices.*' }).Count -eq 0 -and $Ui.PageInfo.Text -notlike 'devices.*'
}
Test-Page 'search filter' { Show-PcPage 'privacy'; Wait-PcJob; $Ui.SearchBox.Text = 'Copilot' } {
    param($items)
    $visible = @($items | Where-Object { Test-PcItemVisible $_ }).Count
    Write-Host "    'Copilot' shows $visible of $($items.Count)"
    $visible -gt 0 -and $visible -lt $items.Count
}
Test-Page 'maintenance' { Show-PcPage 'maintenance' } { param($items) $items.Count -eq @($script:PcMaintenanceTasks).Count }
Test-Page 'restore points' { Show-PcPage 'restore' } { param($items) $Ui.EmptyText.Visibility -eq 'Visible' -or $items.Count -gt 0 }
Test-Page 'history' { Show-PcPage 'history' } { param($items) $Ui.EmptyText.Visibility -eq 'Visible' -or $items.Count -gt 0 }
Test-Page 'about' { Show-PcPage 'about' } {
    param($items)
    $features = @($Ui.AboutFeatures.ItemsSource).Count
    Write-Host "    $features features, $($Ui.LinkRepo.NavigateUri), window icon: $([bool]$Ui.Window.Icon)"
    Write-Host "    Pix card: $($Ui.SupportCard.Visibility), key $($Ui.PixKey.Text), QR loaded: $([bool]$Ui.PixQr.Source)"
    if ($Ui.SupportCard.Visibility -ne 'Visible' -or $Ui.PixKey.Text -ne $script:PcDonation.PixKey -or -not $Ui.PixQr.Source) { return $false }
    # A missing text key would show up as the key itself
    $Ui.AboutPanel.Visibility -eq 'Visible' -and $features -ge 5 -and "$($Ui.LinkRepo.NavigateUri)" -eq $script:PcLinks.Repository -and
        [bool]$Ui.Window.Icon -and [bool]$Ui.LogoImage.Source -and $Ui.AboutWhat.Text -notlike 'about.*' -and $Ui.AboutAuthorBio.Text -notlike 'about.*'
}
Test-Page 'leaving about' { Show-PcPage 'maintenance' } { param($items) $Ui.AboutPanel.Visibility -eq 'Collapsed' }
Test-Page 'memory' { Show-PcPage 'memory' } {
    param($items)
    Write-Host ('    ' + $Ui.PageInfo.Text.Split("`n")[0])
    $Ui.MemoryBar.Visibility -eq 'Visible' -and $Ui.MemoryBar.Value -gt 0 -and $items.Count -gt 0
}
Test-Page 'apps status filter' { Show-PcPage 'apps'; Wait-PcJob; $Ui.StatusFilter.SelectedIndex = 2 } {
    param($items)
    $visible = @($items | Where-Object { Test-PcItemVisible $_ })
    $expected = @($items | Where-Object { $_.State -eq 'NotInstalled' })
    Write-Host "    '$($Ui.StatusFilter.SelectedItem.Content)' shows $($visible.Count) of $($items.Count)"
    $Ui.StatusFilter.SelectedItem.Tag -eq 'notInstalled' -and $visible.Count -eq $expected.Count
}
Test-Page 'tick all shown' { Select-PcVisibleItems $true } {
    param($items)
    $n = @(Get-PcSelectedItems).Count
    Write-Host "    ticked $n, footer '$($Ui.SelectionText.Text)'"
    $n -eq @($items | Where-Object { (Test-PcItemVisible $_) -and $_.Selectable -and $_.IsEnabled }).Count -and ($n -eq 0 -or [bool]$Ui.SelectionText.Text)
}
Test-Page 'untick all' { Select-PcVisibleItems $false } { param($items) @($items | Where-Object IsSelected).Count -eq 0 -and -not $Ui.SelectionText.Text }
Test-Page 'filter resets on page change' { Show-PcPage 'privacy' } { param($items) $script:PcStatusFilter -eq 'all' -and $Ui.StatusFilter.SelectedItem.Tag -eq 'all' }
Test-Page 'theme switch' { Set-PcTheme 'dark' } {
    param($items)
    $dark = $Ui.Window.Resources['Bg'].Color.ToString()
    Set-PcTheme 'light'
    $light = $Ui.Window.Resources['Bg'].Color.ToString()
    Write-Host "    dark $dark, light $light"
    $dark -eq '#FF121418' -and $light -eq '#FFF6F7F9'
}
Test-Page 'theme box remembers' { $Ui.ThemeBox.SelectedIndex = 2 } {
    param($items)
    $saved = Get-PcPreference 'Theme'
    $ok = $script:PcTheme -eq 'dark' -and $saved -eq 'dark'
    $Ui.ThemeBox.SelectedIndex = 0
    Write-Host "    saved '$saved', back to '$(Get-PcPreference 'Theme')'"
    $ok -and (Get-PcPreference 'Theme') -eq 'auto'
}
$startLanguage = $Pc.Language
Test-Page 'language box remembers' {
    $other = @($Ui.LanguageBox.Items | Where-Object { $_.Tag -ne $startLanguage })[0]
    $Ui.LanguageBox.SelectedItem = $other
} {
    param($items)
    $saved = Get-PcPreference 'Language'
    Write-Host "    switched to '$($Pc.Language)', saved '$saved', title '$($Ui.PageTitle.Text)'"
    $saved -eq $Pc.Language -and $Pc.Language -ne $startLanguage -and $Ui.PageTitle.Text -notlike 'page.*'
}
# New-version notice, never on the network: the request is replaced by a counter, the question by
# a fixed answer, and a completed check is faked with a canned list
$script:UpdateRequests = 0
function Start-PcUpdateCheck([switch]$Manual) { $script:UpdateRequests++ }
$script:UpdateAnswer = $false
function Confirm-PcAction([string]$Text) { $script:UpdateAsked = $Text; return $script:UpdateAnswer }
Test-Page 'new-version question: No' {
    Remove-ItemProperty -LiteralPath $script:PcPreferencesKey -Name 'UpdateCheck', 'UpdateCheckedOn', 'UpdateLatest' -ErrorAction SilentlyContinue
    Initialize-PcUpdateCheck
    Initialize-PcUpdateCheck
} {
    param($items)
    Write-Host "    asked: '$($script:UpdateAsked.Split("`n")[0])', saved '$(Get-PcPreference 'UpdateCheck')', requests $script:UpdateRequests"
    # Asked once; the second opening neither asks again nor goes online
    $script:UpdateAsked -eq (Get-PcText 'update.ask') -and (Get-PcPreference 'UpdateCheck') -eq 'off' -and $script:UpdateRequests -eq 0
}
Test-Page 'new-version question: Yes' {
    Remove-ItemProperty -LiteralPath $script:PcPreferencesKey -Name 'UpdateCheck' -ErrorAction SilentlyContinue
    $script:UpdateAnswer = $true
    Initialize-PcUpdateCheck
    Initialize-PcUpdateCheck
} {
    param($items)
    Write-Host "    saved '$(Get-PcPreference 'UpdateCheck')', checked on '$(Get-PcPreference 'UpdateCheckedOn')', requests $script:UpdateRequests"
    # One request a day, even if it fails
    (Get-PcPreference 'UpdateCheck') -eq 'on' -and $script:UpdateRequests -eq 1 -and (Get-PcPreference 'UpdateCheckedOn') -eq (Get-Date -Format 'yyyy-MM-dd')
}
Test-Page 'new-version notice' {
    Set-PcPreference 'UpdateCheck' 'on'
    Set-PcPreference 'UpdateCheckedOn' (Get-Date -Format 'yyyy-MM-dd')
    Set-PcPreference 'UpdateLatest' 'v99.0.0'
    Initialize-PcUpdateCheck
} {
    param($items)
    Write-Host "    '$($Ui.UpdateText.Text) $($Ui.UpdateLinkText.Text)' -> $($Ui.UpdateLink.NavigateUri)"
    # Checked today already: the saved answer shows, and no request goes out
    $Ui.UpdateBar.Visibility -eq 'Visible' -and -not $script:PcUpdateCheck -and $Ui.UpdateText.Text -notlike 'update.*' -and
        "$($Ui.UpdateLink.NavigateUri)" -eq "$($script:PcLinks.Repository)/releases/tag/v99.0.0"
}
Test-Page 'new-version check answers' {
    Show-PcPage 'about'
    $ps = [powershell]::Create()
    $ps.Runspace = [runspacefactory]::CreateRunspace()
    $ps.Runspace.Open()
    [void]$ps.AddScript("'[{`"tag_name`":`"v0.0.1`"}]'")
    $script:PcUpdateCheck = @{ PS = $ps; Handle = $ps.BeginInvoke(); Manual = $true }
    while (-not $script:PcUpdateCheck.Handle.IsCompleted) { Start-Sleep -Milliseconds 50 }
    Complete-PcUpdateCheck
} {
    param($items)
    Write-Host "    About: '$($Ui.UpdateStatus.Text)', box ticked: $($Ui.UpdateAuto.IsChecked)"
    $Ui.UpdateBar.Visibility -eq 'Collapsed' -and (Get-PcPreference 'UpdateLatest') -eq '' -and $Ui.UpdateAuto.IsChecked -and
        $Ui.UpdateStatus.Text -eq (Get-PcText 'update.upToDate' -FormatArgs $script:PcVersion) -and $Ui.UpdateTitle.Text -notlike 'update.*'
}
Test-Page 'new-version box unticked' {
    Show-PcUpdateNotice (Select-PcNewerRelease -Tags 'v99.0.0')
    $Ui.UpdateAuto.IsChecked = $false
    $Ui.UpdateAuto.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
} {
    param($items)
    (Get-PcPreference 'UpdateCheck') -eq 'off' -and $Ui.UpdateBar.Visibility -eq 'Collapsed'
}
Remove-Item -LiteralPath $script:PcPreferencesKey -Recurse -Force -ErrorAction SilentlyContinue
Test-Page 'disk health' {
    $script:SmokeDisk = @()
    Start-PcJob -Work { param($Sync) @(Get-PcDiskHealth) } -OnDone { param($r) $script:SmokeDisk = @($r) }
} { param($items) Write-Host ('    ' + ($script:SmokeDisk -join ' | ')); $script:SmokeDisk.Count -gt 0 }

exit $failures

# WPF front end. Everything slow (restore points, Windows Update, cleanup, winget) runs in a
# background runspace through Start-PcJob, so the window never freezes. Event handlers can't see
# function locals, so live UI objects are kept in $script:Ui.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if (-not ('PitCrew.ListItem' -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;
namespace PitCrew {
    // One card in the list. Every page (tweaks, cleanup, apps, drivers) maps its data onto this.
    public class ListItem : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        void Notify(string name) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(name)); }

        string title = "", detail = "", badge = "", badgeKind = "neutral", tag = "", tagKind = "neutral", meta = "", link, linkText = "";
        bool isSelected, isEnabled = true;

        public string Id { get; set; }
        public object Data { get; set; }
        public string Title { get { return title; } set { title = value; Notify("Title"); } }
        public string Detail { get { return detail; } set { detail = value; Notify("Detail"); } }
        public string Badge { get { return badge; } set { badge = value; Notify("Badge"); } }
        public string BadgeKind { get { return badgeKind; } set { badgeKind = value; Notify("BadgeKind"); } }
        public string Tag { get { return tag; } set { tag = value; Notify("Tag"); } }
        public string TagKind { get { return tagKind; } set { tagKind = value; Notify("TagKind"); } }
        public string Meta { get { return meta; } set { meta = value; Notify("Meta"); } }
        public string Link { get { return link; } set { link = value; Notify("Link"); } }
        public string LinkText { get { return linkText; } set { linkText = value; Notify("LinkText"); } }
        public bool IsSelected { get { return isSelected; } set { isSelected = value; Notify("IsSelected"); } }
        public bool IsEnabled { get { return isEnabled; } set { isEnabled = value; Notify("IsEnabled"); } }
    }
}
'@
}

$script:Ui = @{}
$script:PcJob = $null
$script:PcPage = $null
$script:PcIsAdmin = $false
$script:PcOtherUser = $false

$script:PcJobBootstrap = {
    param($Loader, $Context, $WorkText, $Arguments)
    $ErrorActionPreference = 'Stop'
    . $Loader
    Initialize-PcContext @Context
    $work = [scriptblock]::Create($WorkText)
    & $work @Arguments
}

# --- Infrastructure -----------------------------------------------------------------------------

function Start-PcJob {
    param([Parameter(Mandatory)][scriptblock]$Work, [hashtable]$Arguments = @{}, [Parameter(Mandatory)][scriptblock]$OnDone, [string]$Status)
    $sync = [hashtable]::Synchronized(@{ Status = $Status })
    $jobArgs = $Arguments.Clone()
    $jobArgs.Sync = $sync
    $ps = [powershell]::Create()
    $ps.Runspace = [runspacefactory]::CreateRunspace()
    $ps.Runspace.ApartmentState = 'STA'
    $ps.Runspace.Open()
    [void]$ps.AddScript($script:PcJobBootstrap.ToString()).
        AddArgument((Join-Path $Pc.Root 'src\Load.ps1')).
        AddArgument((Get-PcContextArgs)).
        AddArgument($Work.ToString()).
        AddArgument($jobArgs)
    $script:PcJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Sync = $sync }
    Set-PcBusy $true $Status
}

function Complete-PcJob {
    # Called by the dispatcher timer; runs OnDone on the UI thread
    $job = $script:PcJob
    if (-not $job) { return }
    if ($job.Sync.Status) { $Ui.StatusText.Text = $job.Sync.Status }
    if (-not $job.Handle.IsCompleted) { return }
    $script:PcJob = $null
    $result = @()
    $failure = $null
    try {
        $result = @($job.PS.EndInvoke($job.Handle))
    } catch {
        $failure = $_.Exception
        while ($failure.InnerException) { $failure = $failure.InnerException }
    }
    foreach ($e in $job.PS.Streams.Error) { Write-PcLog "Job: $e" 'Warn' }
    $job.PS.Runspace.Dispose()
    $job.PS.Dispose()
    Set-PcBusy $false
    # OnDone may replace this with a result line (e.g. how much cleanup can free)
    $Ui.StatusText.Text = Get-PcText 'status.ready'
    if ($failure) {
        Write-PcLog "Job failed: $($failure.Message)" 'Error'
        Show-PcMessage (Get-PcText 'msg.error' -FormatArgs $failure.Message) 'Error'
        return
    }
    try { & $job.OnDone $result } catch { Show-PcMessage (Get-PcText 'msg.error' -FormatArgs $_.Exception.Message) 'Error' }
}

function Set-PcBusy([bool]$IsBusy, [string]$Status) {
    $Ui.Busy.Visibility = if ($IsBusy) { 'Visible' } else { 'Collapsed' }
    $Ui.Nav.IsEnabled = -not $IsBusy
    $Ui.LanguageBox.IsEnabled = -not $IsBusy
    $Ui.Items.IsEnabled = -not $IsBusy
    if ($IsBusy) {
        $Ui.PrimaryAction.IsEnabled = $false
        $Ui.SecondaryAction.IsEnabled = $false
        if ($Status) { $Ui.StatusText.Text = $Status }
    } else {
        Update-PcActionButtons
    }
}

function Show-PcMessage([string]$Text, [string]$Icon = 'Information') {
    [void][System.Windows.MessageBox]::Show($Ui.Window, $Text, 'PitCrew', 'OK', $Icon)
}

function Confirm-PcAction([string]$Text) {
    $answer = [System.Windows.MessageBox]::Show($Ui.Window, $Text, 'PitCrew', 'YesNo', 'Question', 'No')
    return $answer -eq 'Yes'
}

function Get-PcSelectedItems { @($Ui.Items.ItemsSource | Where-Object { $_.IsSelected }) }

function New-PcItem([hashtable]$Values) {
    $item = New-Object PitCrew.ListItem
    foreach ($k in $Values.Keys) { $item.$k = $Values[$k] }
    return $item
}

function Set-PcItems($Items, [string]$EmptyKey = 'empty.list') {
    $list = New-Object System.Collections.ObjectModel.ObservableCollection[PitCrew.ListItem]
    foreach ($i in @($Items)) { if ($i) { $list.Add($i) } }
    $Ui.Items.ItemsSource = $list
    $Ui.EmptyText.Text = Get-PcText $EmptyKey
    $Ui.EmptyText.Visibility = if ($list.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    Update-PcActionButtons
}

function Set-PcPageInfo([string]$Text) {
    $Ui.PageInfo.Text = $Text
    $Ui.PageInfo.Visibility = if ($Text) { 'Visible' } else { 'Collapsed' }
}

# --- Pages ----------------------------------------------------------------------------------------

$script:PcPages = @{
    performance = @{ Primary = 'button.apply'; Secondary = 'button.undo'; ReadOnlySecondary = $false }
    privacy     = @{ Primary = 'button.apply'; Secondary = 'button.undo'; ReadOnlySecondary = $false }
    cleanup     = @{ Primary = 'button.clean'; Secondary = 'button.analyze'; ReadOnlySecondary = $true }
    apps        = @{ Primary = 'button.remove'; Secondary = 'button.reinstall'; ReadOnlySecondary = $false }
    drivers     = @{ Primary = 'button.install'; Secondary = 'button.search'; ReadOnlySecondary = $true }
    about       = @{}
}

function Update-PcActionButtons {
    $page = $script:PcPages[$script:PcPage]
    if (-not $page -or -not $page.Primary) {
        $Ui.PrimaryAction.Visibility = 'Collapsed'
        $Ui.SecondaryAction.Visibility = 'Collapsed'
        return
    }
    $Ui.PrimaryAction.Visibility = 'Visible'
    $Ui.SecondaryAction.Visibility = 'Visible'
    $Ui.PrimaryAction.Content = Get-PcText $page.Primary
    $Ui.SecondaryAction.Content = Get-PcText $page.Secondary
    $hasItems = @($Ui.Items.ItemsSource).Count -gt 0
    $Ui.PrimaryAction.IsEnabled = $script:PcIsAdmin -and $hasItems
    if ($page.ReadOnlySecondary) { $Ui.SecondaryAction.IsEnabled = $true }
    else { $Ui.SecondaryAction.IsEnabled = $script:PcIsAdmin -and $hasItems }
}

function Show-PcPage([string]$Page) {
    $script:PcPage = $Page
    $Ui.PageTitle.Text = Get-PcText "page.$Page.title"
    $Ui.PageIntro.Text = Get-PcText "page.$Page.intro"
    Set-PcPageInfo ''
    Set-PcItems @()
    $Ui.EmptyText.Visibility = 'Collapsed'
    $Ui.StatusText.Text = Get-PcText 'status.ready'
    switch ($Page) {
        { $_ -in 'performance', 'privacy' } { Set-PcItems (Get-PcTweakItems $Page) }
        'cleanup' { Invoke-PcAnalyzeCleanup }
        'apps'    { Invoke-PcLoadApps }
        'drivers' { Invoke-PcLoadDriverSummary }
        'about'   { Set-PcPageInfo ((Get-PcText 'about.text') + "`n`n" + (Get-PcText 'about.dataDir' -FormatArgs $Pc.DataDir) + "`n`n" + (Get-PcText 'about.credits')) }
    }
}

function Invoke-PcPrimaryAction {
    switch ($script:PcPage) {
        { $_ -in 'performance', 'privacy' } { Invoke-PcApplyTweaks }
        'cleanup' { Invoke-PcRunCleanup }
        'apps'    { Invoke-PcRemoveApps }
        'drivers' { Invoke-PcInstallDrivers }
    }
}

function Invoke-PcSecondaryAction {
    switch ($script:PcPage) {
        { $_ -in 'performance', 'privacy' } { Invoke-PcUndoTweaks }
        'cleanup' { Invoke-PcAnalyzeCleanup }
        'apps'    { Invoke-PcReinstallApps }
        'drivers' { Invoke-PcSearchDrivers }
    }
}

# --- Tweaks ---------------------------------------------------------------------------------------

function Get-PcTweakItems([string]$Category) {
    $journalKeys = @(Get-PcJournal | ForEach-Object { $_.key })
    foreach ($t in $script:PcTweaks | Where-Object category -eq $Category) {
        $state = Get-PcTweakState $t
        $meta = @()
        if ($t.scope -eq 'user') { $meta += Get-PcText 'tweak.userScope' }
        if ($t.requires -and $t.requires.restart) { $meta += Get-PcText 'tweak.restart' }
        if ($journalKeys -contains (Get-PcJournalKey $t)) { $meta += Get-PcText 'tweak.canUndo' }
        $badgeKind = switch ($state) { 'Applied' { 'good' } 'Partial' { 'warn' } 'Error' { 'bad' } default { 'neutral' } }
        $tagKind = switch ($t.risk) { 'moderate' { 'warn' } 'advanced' { 'bad' } default { 'neutral' } }
        New-PcItem @{
            Id        = $t.id
            Title     = Resolve-PcLocalized $t.title
            Detail    = Resolve-PcLocalized $t.description
            Badge     = Get-PcText "state.$state"
            BadgeKind = $badgeKind
            Tag       = Get-PcText "risk.$($t.risk)"
            TagKind   = $tagKind
            Meta      = $meta -join '  ·  '
            Link      = $t.reference
            LinkText  = Get-PcText 'link.learnMore'
            IsEnabled = $state -ne 'NotApplicable'
        }
    }
}

$script:PcApplyWork = {
    param($Sync, $Ids)
    $Sync.Status = Get-PcText 'status.creatingRestorePoint'
    if (-not (New-PcRestorePoint -Description ('PitCrew {0:yyyy-MM-dd HH:mm}' -f (Get-Date)))) {
        return [pscustomobject]@{ NoRestorePoint = $true }
    }
    $tweaks = @(Import-PcTweaks)
    $ok = 0
    $failed = @()
    foreach ($id in $Ids) {
        $t = $tweaks | Where-Object id -eq $id
        $Sync.Status = '{0} {1}' -f (Get-PcText 'status.applying'), (Resolve-PcLocalized $t.title)
        try { Invoke-PcTweak $t; $ok++ } catch { $failed += '{0}: {1}' -f (Resolve-PcLocalized $t.title), $_.Exception.Message }
    }
    [pscustomobject]@{ NoRestorePoint = $false; Ok = $ok; Failed = $failed }
}

function Invoke-PcApplyTweaks {
    $selected = Get-PcSelectedItems
    if ($selected.Count -eq 0) { Show-PcMessage (Get-PcText 'msg.selectFirst'); return }
    $script:PcPendingIds = @($selected | ForEach-Object Id)
    Start-PcJob -Work $script:PcApplyWork -Arguments @{ Ids = $script:PcPendingIds } -Status (Get-PcText 'status.creatingRestorePoint') -OnDone {
        param($r)
        $res = $r[-1]
        if ($res.NoRestorePoint) {
            if (Confirm-PcAction (Get-PcText 'msg.noRestorePoint')) {
                Start-PcJob -Work { param($Sync) Enable-PcSystemProtection } -Status (Get-PcText 'status.enablingProtection') -OnDone {
                    param($r)
                    Start-PcJob -Work $script:PcApplyWork -Arguments @{ Ids = $script:PcPendingIds } -Status (Get-PcText 'status.creatingRestorePoint') -OnDone ${function:Complete-PcApply}
                }
            } else {
                Show-PcMessage (Get-PcText 'msg.noRestorePointAbort') 'Warning'
            }
            return
        }
        Complete-PcApply $r
    }
}

function Complete-PcApply($r) {
    $res = $r[-1]
    if ($res.NoRestorePoint) { Show-PcMessage (Get-PcText 'msg.noRestorePointAbort') 'Warning'; return }
    $text = Get-PcText 'msg.applyDone' -FormatArgs $res.Ok, @($res.Failed).Count
    if (@($res.Failed).Count -gt 0) { $text += "`n`n" + (@($res.Failed) -join "`n") }
    Set-PcItems (Get-PcTweakItems $script:PcPage)
    Show-PcMessage $text
}

function Invoke-PcUndoTweaks {
    $selected = Get-PcSelectedItems
    if ($selected.Count -eq 0) { Show-PcMessage (Get-PcText 'msg.selectFirst'); return }
    $work = {
        param($Sync, $Ids)
        $tweaks = @(Import-PcTweaks)
        $done = 0; $skipped = 0; $notApplied = 0; $failed = @()
        foreach ($id in $Ids) {
            $t = $tweaks | Where-Object id -eq $id
            if (-not (Get-PcJournalEntry $t)) { $notApplied++; continue }
            $Sync.Status = '{0} {1}' -f (Get-PcText 'status.undoing'), (Resolve-PcLocalized $t.title)
            try { $skipped += (Undo-PcTweak $t).Skipped; $done++ }
            catch { $failed += '{0}: {1}' -f (Resolve-PcLocalized $t.title), $_.Exception.Message }
        }
        [pscustomobject]@{ Done = $done; Skipped = $skipped; NotApplied = $notApplied; Failed = $failed }
    }
    Start-PcJob -Work $work -Arguments @{ Ids = @($selected | ForEach-Object Id) } -Status (Get-PcText 'status.undoing') -OnDone {
        param($r)
        $res = $r[-1]
        $lines = @(Get-PcText 'msg.undoDone' -FormatArgs $res.Done)
        if ($res.Skipped -gt 0) { $lines += Get-PcText 'msg.undoSkipped' -FormatArgs $res.Skipped }
        if ($res.NotApplied -gt 0) { $lines += Get-PcText 'msg.undoNotApplied' -FormatArgs $res.NotApplied }
        $lines += @($res.Failed)
        Set-PcItems (Get-PcTweakItems $script:PcPage)
        Show-PcMessage ($lines -join "`n`n")
    }
}

# --- Cleanup --------------------------------------------------------------------------------------

function Invoke-PcAnalyzeCleanup {
    Start-PcJob -Work { param($Sync) Get-PcCleanupTargets } -Status (Get-PcText 'status.analyzing') -OnDone {
        param($r)
        Set-PcItems @(foreach ($t in $r) {
            $meta = Get-PcText 'cleanup.meta' -FormatArgs (Format-PcBytes $t.Bytes), $t.Files
            if (-not $t.Available) { $meta = Get-PcText 'cleanup.adminOnly' }
            New-PcItem @{ Id = $t.Id; Title = $t.Name; Detail = Get-PcText "cleanup.$($t.Id).detail"; Meta = $meta; IsEnabled = $t.Available; Data = $t.Bytes }
        })
        $total = [int64](@($r | Where-Object Available) | Measure-Object Bytes -Sum).Sum
        $Ui.StatusText.Text = Get-PcText 'cleanup.total' -FormatArgs (Format-PcBytes $total)
    }
}

function Invoke-PcRunCleanup {
    $selected = Get-PcSelectedItems
    if ($selected.Count -eq 0) { Show-PcMessage (Get-PcText 'msg.selectFirst'); return }
    $bytes = [int64](@($selected | ForEach-Object { [int64]$_.Data }) | Measure-Object -Sum).Sum
    if (-not (Confirm-PcAction (Get-PcText 'msg.confirmClean' -FormatArgs (Format-PcBytes $bytes)))) { return }
    Start-PcJob -Work { param($Sync, $Ids) Invoke-PcCleanup -Ids $Ids } -Arguments @{ Ids = @($selected | ForEach-Object Id) } -Status (Get-PcText 'status.cleaning') -OnDone {
        param($r)
        $freed = [int64](@($r) | Measure-Object FreedBytes -Sum).Sum
        $inUse = [int](@($r) | Measure-Object InUse -Sum).Sum
        $text = Get-PcText 'msg.cleanDone' -FormatArgs (Format-PcBytes $freed)
        if ($inUse -gt 0) { $text += "`n" + (Get-PcText 'msg.cleanInUse' -FormatArgs $inUse) }
        Show-PcMessage $text
        Invoke-PcAnalyzeCleanup
    }
}

# --- Apps -----------------------------------------------------------------------------------------

function Invoke-PcLoadApps {
    Start-PcJob -Work { param($Sync) Get-PcRemovableApps } -Status (Get-PcText 'status.loading') -OnDone {
        param($r)
        Set-PcItems @(foreach ($a in $r) {
            $badge = if ($a.Installed) { Get-PcText 'apps.installed' } else { Get-PcText 'apps.notInstalled' }
            $kind = if ($a.Installed) { 'neutral' } else { 'good' }
            New-PcItem @{ Id = $a.Package; Title = $a.Name; Detail = $a.Package; Badge = $badge; BadgeKind = $kind; Data = $a.Installed }
        })
    }
}

function Invoke-PcRemoveApps {
    $selected = @(Get-PcSelectedItems | Where-Object { $_.Data })
    if ($selected.Count -eq 0) { Show-PcMessage (Get-PcText 'msg.selectInstalled'); return }
    if (-not (Confirm-PcAction (Get-PcText 'msg.confirmRemove' -FormatArgs $selected.Count))) { return }
    Start-PcJob -Work { param($Sync, $Packages) Remove-PcApps -Packages $Packages } -Arguments @{ Packages = @($selected | ForEach-Object Id) } -Status (Get-PcText 'status.removing') -OnDone {
        param($r)
        $ok = @($r | Where-Object Removed).Count
        Show-PcMessage (Get-PcText 'msg.removeDone' -FormatArgs $ok, (@($r).Count - $ok))
        Invoke-PcLoadApps
    }
}

function Invoke-PcReinstallApps {
    $selected = @(Get-PcSelectedItems | Where-Object { -not $_.Data })
    if ($selected.Count -eq 0) { Show-PcMessage (Get-PcText 'msg.selectRemoved'); return }
    if (-not (Confirm-PcAction (Get-PcText 'msg.confirmReinstall' -FormatArgs $selected.Count))) { return }
    Start-PcJob -Work { param($Sync, $Packages) Install-PcApps -Packages $Packages } -Arguments @{ Packages = @($selected | ForEach-Object Id) } -Status (Get-PcText 'status.reinstalling') -OnDone {
        param($r)
        $ok = @($r | Where-Object Installed).Count
        Show-PcMessage (Get-PcText 'msg.reinstallDone' -FormatArgs $ok, (@($r).Count - $ok))
        Invoke-PcLoadApps
    }
}

# --- Drivers --------------------------------------------------------------------------------------

function Invoke-PcLoadDriverSummary {
    $work = {
        param($Sync)
        $inventory = @(Get-PcDriverInventory)
        [pscustomobject]@{
            Total      = $inventory.Count
            ThirdParty = @($inventory | Where-Object ThirdParty).Count
            Problems   = @(Get-PcProblemDevices)
            Tips       = @(Get-PcDriverVendorTips $inventory)
            PolicyOff  = Test-PcDriverPolicyBlocksUpdates
        }
    }
    Start-PcJob -Work $work -Status (Get-PcText 'status.loading') -OnDone {
        param($r)
        $s = $r[-1]
        $lines = @(Get-PcText 'drivers.summary' -FormatArgs $s.Total, ($s.Total - $s.ThirdParty), $s.ThirdParty)
        if (@($s.Problems).Count -gt 0) {
            $lines += (Get-PcText 'drivers.problemsTitle') + "`n" + ((@($s.Problems) | ForEach-Object { '  • {0}: {1}' -f $_.Device, $_.Problem }) -join "`n")
        } else {
            $lines += Get-PcText 'drivers.noProblems'
        }
        if (@($s.Tips).Count -gt 0) {
            $lines += (Get-PcText 'drivers.tipsTitle') + "`n" + ((@($s.Tips) | ForEach-Object { "  • $_" }) -join "`n")
        }
        if ($s.PolicyOff) { $lines += Get-PcText 'drivers.policyBlocks' }
        Set-PcPageInfo ($lines -join "`n`n")
        Set-PcItems @() 'drivers.searchHint'
    }
}

function Invoke-PcSearchDrivers {
    Start-PcJob -Work { param($Sync) Find-PcDriverUpdates } -Status (Get-PcText 'status.searching') -OnDone {
        param($r)
        Set-PcItems @(foreach ($o in $r) {
            $kind = if ($o.Recommended) { 'good' } else { 'warn' }
            New-PcItem @{
                Id        = $o.UpdateId
                Title     = $o.Device
                Detail    = Get-PcText 'drivers.meta' -FormatArgs $(if ($o.Installed) { $o.Installed } else { '?' }), $o.Offered
                Badge     = Get-PcText "drivers.verdict.$($o.Verdict)"
                BadgeKind = $kind
                Tag       = $o.Class
            }
        }) 'drivers.noUpdates'
    }
}

function Invoke-PcInstallDrivers {
    $selected = Get-PcSelectedItems
    if ($selected.Count -eq 0) { Show-PcMessage (Get-PcText 'msg.selectFirst'); return }
    if (-not (Confirm-PcAction (Get-PcText 'msg.confirmDrivers' -FormatArgs $selected.Count))) { return }
    $work = {
        param($Sync, $Ids)
        $Sync.Status = Get-PcText 'status.creatingRestorePoint'
        if (-not (New-PcRestorePoint -Description ('PitCrew drivers {0:yyyy-MM-dd HH:mm}' -f (Get-Date)) -Type 'DEVICE_DRIVER_INSTALL')) {
            return [pscustomobject]@{ NoRestorePoint = $true }
        }
        $Sync.Status = Get-PcText 'status.installing'
        [pscustomobject]@{ NoRestorePoint = $false; Results = @(Install-PcDriverUpdates -UpdateIds $Ids) }
    }
    Start-PcJob -Work $work -Arguments @{ Ids = @($selected | ForEach-Object Id) } -Status (Get-PcText 'status.creatingRestorePoint') -OnDone {
        param($r)
        $res = $r[-1]
        if ($res.NoRestorePoint) { Show-PcMessage (Get-PcText 'msg.noRestorePointAbort') 'Warning'; return }
        $lines = @($res.Results | ForEach-Object { '{0}: {1}' -f $_.Device, (Get-PcText "drivers.result.$($_.Result)") })
        if (@($res.Results | Where-Object RebootRequired).Count -gt 0) { $lines += ''; $lines += Get-PcText 'msg.reboot' }
        Show-PcMessage ($lines -join "`n")
        Invoke-PcSearchDrivers
    }
}

# --- Window ---------------------------------------------------------------------------------------

function Set-PcStaticTexts {
    $Ui.Tagline.Text = Get-PcText 'app.tagline'
    foreach ($page in 'Performance', 'Privacy', 'Cleanup', 'Apps', 'Drivers', 'About') {
        $Ui["Nav$page"].Content = Get-PcText "nav.$($page.ToLowerInvariant())"
    }
    $Ui.ModeText.Text = if ($script:PcIsAdmin) { Get-PcText 'mode.admin' } else { Get-PcText 'mode.readOnly' }
    $banner = @()
    if (-not $script:PcIsAdmin) { $banner += Get-PcText 'banner.readOnly' }
    if ($script:PcOtherUser) { $banner += Get-PcText 'banner.otherUser' }
    if ($Pc.SkipRestorePoint) { $banner += Get-PcText 'banner.testMode' }
    $Ui.BannerText.Text = $banner -join "`n"
    $Ui.Banner.Visibility = if ($banner) { 'Visible' } else { 'Collapsed' }
}

function New-PcWindow {
    $xaml = [IO.File]::ReadAllText((Join-Path $Pc.Root 'src\UI\Window.xaml'))
    $window = [Windows.Markup.XamlReader]::Parse($xaml)
    $script:Ui = @{ Window = $window }
    foreach ($name in 'Tagline', 'ModeText', 'LanguageBox', 'Nav', 'NavPerformance', 'NavPrivacy', 'NavCleanup', 'NavApps',
        'NavDrivers', 'NavAbout', 'PageTitle', 'PageIntro', 'Banner', 'BannerText', 'PageInfo', 'Items', 'EmptyText',
        'PrimaryAction', 'SecondaryAction', 'Busy', 'StatusText') {
        $Ui[$name] = $window.FindName($name)
    }

    $script:PcIsAdmin = Test-PcAdmin
    $script:PcOtherUser = Test-PcUserMismatch
    $script:PcTweaks = @(Import-PcTweaks)

    foreach ($lang in Get-PcAvailableLanguages) {
        $option = New-Object System.Windows.Controls.ComboBoxItem
        $option.Content = $lang.Name
        $option.Tag = $lang.Code
        [void]$Ui.LanguageBox.Items.Add($option)
        if ($lang.Code -eq $Pc.Language) { $Ui.LanguageBox.SelectedItem = $option }
    }
    $Ui.LanguageBox.Add_SelectionChanged({
        $code = $Ui.LanguageBox.SelectedItem.Tag
        if (-not $code -or $code -eq $Pc.Language) { return }
        Import-PcLocale $code
        Set-PcStaticTexts
        Show-PcPage $script:PcPage
    })
    $Ui.Nav.Add_SelectionChanged({
        $item = $Ui.Nav.SelectedItem
        if ($item) { Show-PcPage $item.Tag }
    })
    $Ui.PrimaryAction.Add_Click({ Invoke-PcPrimaryAction })
    $Ui.SecondaryAction.Add_Click({ Invoke-PcSecondaryAction })
    $window.AddHandler([System.Windows.Documents.Hyperlink]::RequestNavigateEvent,
        [System.Windows.Navigation.RequestNavigateEventHandler] { param($s, $e) Start-Process $e.Uri.AbsoluteUri; $e.Handled = $true })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({ Complete-PcJob })
    $timer.Start()
    $Ui.Timer = $timer
    $window.Add_Closing({
        param($s, $e)
        # Closing mid-job would cut a restore point or an install in half
        if ($script:PcJob) { $e.Cancel = $true; Show-PcMessage (Get-PcText 'msg.waitForJob') }
    })

    Set-PcStaticTexts
    $Ui.Nav.SelectedIndex = 0
    return $window
}

function Show-PcWindow {
    $window = New-PcWindow
    [void]$window.ShowDialog()
    $Ui.Timer.Stop()
}

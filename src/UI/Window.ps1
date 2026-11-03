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
        bool isSelected, isEnabled = true, selectable = true;

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
        // False for read-only lists (restore points): the card shows no checkbox
        public bool Selectable { get { return selectable; } set { selectable = value; Notify("Selectable"); } }
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
    # One job at a time: a second one would orphan the first and its OnDone would never run
    if ($script:PcJob) { Write-PcLog 'Start-PcJob ignored: another job is running' 'Warn'; return }
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

# Items hidden by the search or filter are never acted on, even if they were ticked before
function Get-PcSelectedItems { @($Ui.Items.ItemsSource | Where-Object { $_.IsSelected -and (Test-PcItemVisible $_) }) }

function New-PcItem([hashtable]$Values) {
    $item = New-Object PitCrew.ListItem
    foreach ($k in $Values.Keys) { $item.$k = $Values[$k] }
    return $item
}

function Set-PcItems($Items, [string]$EmptyKey = 'empty.list') {
    $list = New-Object System.Collections.ObjectModel.ObservableCollection[PitCrew.ListItem]
    foreach ($i in @($Items)) { if ($i) { $list.Add($i) } }
    $Ui.Items.ItemsSource = $list
    Update-PcFilter
    $Ui.EmptyText.Text = Get-PcText $EmptyKey
    $Ui.EmptyText.Visibility = if ($list.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    Update-PcActionButtons
}

# --- Search, filter, presets and profiles ---------------------------------------------------------

$script:PcPreselected = @()

function Test-PcItemVisible($Item) {
    if (-not $Ui.FilterBar -or $Ui.FilterBar.Visibility -ne 'Visible') { return $true }
    if ($Ui.HideUnavailable.IsChecked -and $Item.Selectable -and -not $Item.IsEnabled) { return $false }
    $q = $Ui.SearchBox.Text.Trim()
    if (-not $q) { return $true }
    return ($Item.Title.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
        ($Item.Detail.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Update-PcFilter {
    $Ui.SearchHint.Visibility = if ($Ui.SearchBox.Text) { 'Collapsed' } else { 'Visible' }
    if (-not $Ui.Items.ItemsSource) { return }
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($Ui.Items.ItemsSource)
    $view.Filter = [Predicate[object]] { param($item) Test-PcItemVisible $item }
    $view.Refresh()
}

function Update-PcPresetBox {
    # First entry is a "Preset..." placeholder; the last one imports a profile file
    $script:PcPresetUpdating = $true
    $Ui.PresetBox.Items.Clear()
    $placeholder = New-Object System.Windows.Controls.ComboBoxItem
    $placeholder.Content = Get-PcText 'preset.placeholder'
    $placeholder.Tag = ''
    [void]$Ui.PresetBox.Items.Add($placeholder)
    foreach ($p in @(Read-PcJson (Join-Path $Pc.Root 'data\presets.json'))) {
        $option = New-Object System.Windows.Controls.ComboBoxItem
        $option.Content = Resolve-PcLocalized $p.name
        $option.Tag = $p.id
        [void]$Ui.PresetBox.Items.Add($option)
    }
    $import = New-Object System.Windows.Controls.ComboBoxItem
    $import.Content = Get-PcText 'preset.import'
    $import.Tag = '__import'
    [void]$Ui.PresetBox.Items.Add($import)
    $Ui.PresetBox.SelectedIndex = 0
    $script:PcPresetUpdating = $false
}

function Set-PcPreselection([string[]]$Ids) {
    # Presets and profiles only tick boxes; nothing changes until Apply is clicked
    $known = @($script:PcTweaks | ForEach-Object id)
    $script:PcPreselected = @($Ids | Where-Object { $known -contains $_ })
    $counts = foreach ($c in $script:PcTweakCategories) {
        $n = @($script:PcTweaks | Where-Object { $_.category -eq $c -and $script:PcPreselected -contains $_.id }).Count
        if ($n -gt 0) { '{0} ({1})' -f (Get-PcText "nav.$c"), $n }
    }
    Update-PcCurrentPage
    Show-PcMessage (Get-PcText 'preset.marked' -FormatArgs $script:PcPreselected.Count, (@($counts) -join ', '))
}

function Invoke-PcPresetChosen {
    if ($script:PcPresetUpdating) { return }
    $tag = [string]$Ui.PresetBox.SelectedItem.Tag
    if (-not $tag) { return }
    if ($tag -eq '__import') {
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter = Get-PcText 'profile.dialogFilter'
        if ($dialog.ShowDialog($Ui.Window)) {
            try {
                $data = Read-PcJson $dialog.FileName
                if ($data.pitcrewProfile -ne 1) { throw 'not a profile' }
                Set-PcPreselection @($data.tweaks)
            } catch { Show-PcMessage (Get-PcText 'profile.invalid') 'Warning' }
        }
        $script:PcPresetUpdating = $true
        $Ui.PresetBox.SelectedIndex = 0
        $script:PcPresetUpdating = $false
        return
    }
    $preset = @(Read-PcJson (Join-Path $Pc.Root 'data\presets.json')) | Where-Object id -eq $tag | Select-Object -First 1
    if ($preset) { Set-PcPreselection @($preset.tweaks) }
}

function Invoke-PcExportProfile {
    # A profile is the list of settings currently in place, to reproduce them on another PC
    $work = {
        param($Sync)
        @(Import-PcTweaks | Where-Object { (Get-PcTweakState $_) -eq 'Applied' } | ForEach-Object { $_.id })
    }
    Start-PcJob -Work $work -Status (Get-PcText 'status.loading') -OnDone {
        param($r)
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Filter = Get-PcText 'profile.dialogFilter'
        $dialog.FileName = 'PitCrew-{0}-{1:yyyy-MM-dd}.json' -f $env:COMPUTERNAME, (Get-Date)
        if (-not $dialog.ShowDialog($Ui.Window)) { return }
        Write-PcJson $dialog.FileName ([pscustomobject]@{ pitcrewProfile = 1; created = (Get-Date).ToString('o'); tweaks = @($r) })
        Show-PcMessage (Get-PcText 'profile.saved' -FormatArgs @($r).Count, $dialog.FileName)
    }
}

function Set-PcPageInfo([string]$Text) {
    $Ui.PageInfo.Text = $Text
    $Ui.PageInfo.Visibility = if ($Text) { 'Visible' } else { 'Collapsed' }
}

# --- Pages ----------------------------------------------------------------------------------------

# Pages that list tweaks from tweaks/<category>.json
$script:PcTweakCategories = @('performance', 'privacy', 'explorer')

# For each button: its text, whether it needs administrator rights and whether it needs items
$script:PcPages = @{
    performance = @{ Primary = @('button.apply', $true, $true); Secondary = @('button.undo', $true, $true) }
    privacy     = @{ Primary = @('button.apply', $true, $true); Secondary = @('button.undo', $true, $true) }
    explorer    = @{ Primary = @('button.apply', $true, $true); Secondary = @('button.undo', $true, $true) }
    startup     = @{ Primary = @('button.disable', $false, $true); Secondary = @('button.enable', $false, $true) }
    cleanup     = @{ Primary = @('button.clean', $true, $true); Secondary = @('button.analyze', $false, $false) }
    maintenance = @{ Primary = @('button.run', $true, $true) }
    apps        = @{ Primary = @('button.remove', $true, $true); Secondary = @('button.reinstall', $true, $true) }
    drivers     = @{ Primary = @('button.install', $true, $true); Secondary = @('button.search', $false, $false) }
    restore     = @{ Primary = @('button.createRestorePoint', $true, $false); Secondary = @('button.openSystemRestore', $false, $false) }
    history     = @{ Primary = @('button.undo', $true, $true) }
    about       = @{}
}

function Set-PcButton($Button, $Spec, [bool]$HasItems) {
    if (-not $Spec) { $Button.Visibility = 'Collapsed'; return }
    $Button.Visibility = 'Visible'
    $Button.Content = Get-PcText $Spec[0]
    $Button.IsEnabled = ($script:PcIsAdmin -or -not $Spec[1]) -and ($HasItems -or -not $Spec[2])
}

function Update-PcActionButtons {
    $page = $script:PcPages[$script:PcPage]
    $hasItems = @($Ui.Items.ItemsSource | Where-Object { $_.Selectable }).Count -gt 0
    Set-PcButton $Ui.PrimaryAction $page.Primary $hasItems
    Set-PcButton $Ui.SecondaryAction $page.Secondary $hasItems
}

function Show-PcPage([string]$Page) {
    $script:PcPage = $Page
    $Ui.PageTitle.Text = Get-PcText "page.$Page.title"
    $Ui.PageIntro.Text = Get-PcText "page.$Page.intro"
    Set-PcPageInfo ''
    # Search and filter on long lists; presets and profiles only where there are tweaks
    $isTweakPage = $script:PcTweakCategories -contains $Page
    $Ui.FilterBar.Visibility = if ($isTweakPage -or $Page -eq 'apps' -or $Page -eq 'startup') { 'Visible' } else { 'Collapsed' }
    $Ui.PresetBox.Visibility = if ($isTweakPage) { 'Visible' } else { 'Collapsed' }
    $Ui.ExportProfile.Visibility = if ($isTweakPage) { 'Visible' } else { 'Collapsed' }
    $Ui.SearchBox.Text = ''
    Set-PcItems @()
    $Ui.EmptyText.Visibility = 'Collapsed'
    $Ui.StatusText.Text = Get-PcText 'status.ready'
    switch ($Page) {
        'startup' { Invoke-PcLoadStartup }
        'cleanup' { Invoke-PcAnalyzeCleanup }
        'apps'    { Invoke-PcLoadApps }
        'drivers' { Invoke-PcLoadDriverSummary }
        'restore' { Invoke-PcLoadRestorePoints }
        'about'   { Set-PcPageInfo ((Get-PcText 'about.text') + "`n`n" + (Get-PcText 'about.dataDir' -FormatArgs $Pc.DataDir) + "`n`n" + (Get-PcText 'about.credits')) }
        default   { Update-PcCurrentPage }
    }
}

function Update-PcCurrentPage {
    # Pages whose list is quick to rebuild on the UI thread
    switch ($script:PcPage) {
        { $script:PcTweakCategories -contains $_ } { Invoke-PcLoadTweakPage $script:PcPage }
        'maintenance' { Set-PcItems (Get-PcMaintenanceItems) }
        'history' {
            Set-PcItems (Get-PcHistoryItems) 'history.empty'
            $untrusted = @(Get-PcUntrustedJournals)
            if ($untrusted.Count -gt 0) { Set-PcPageInfo (Get-PcText 'history.untrusted' -FormatArgs ($untrusted -join ', ')) }
        }
    }
}

function Invoke-PcPrimaryAction {
    switch ($script:PcPage) {
        { $script:PcTweakCategories -contains $_ } { Invoke-PcApplyTweaks }
        'startup'     { Invoke-PcSetStartup $false }
        'cleanup'     { Invoke-PcRunCleanup }
        'maintenance' { Invoke-PcRunMaintenance }
        'apps'        { Invoke-PcRemoveApps }
        'drivers'     { Invoke-PcInstallDrivers }
        'restore'     { Invoke-PcCreateRestorePoint }
        'history'     { Invoke-PcUndoTweaks }
    }
}

function Invoke-PcSecondaryAction {
    switch ($script:PcPage) {
        { $script:PcTweakCategories -contains $_ } { Invoke-PcUndoTweaks }
        'startup' { Invoke-PcSetStartup $true }
        'cleanup' { Invoke-PcAnalyzeCleanup }
        'apps'    { Invoke-PcReinstallApps }
        'drivers' { Invoke-PcSearchDrivers }
        'restore' { Start-Process rstrui.exe }
    }
}

# --- Tweaks ---------------------------------------------------------------------------------------

function Invoke-PcLoadTweakPage([string]$Category) {
    # Reading states can take seconds (scheduled tasks, powercfg), so it runs in the background
    $work = {
        param($Sync, $Category)
        foreach ($t in @(Import-PcTweaks) | Where-Object category -eq $Category) {
            [pscustomobject]@{ Id = $t.id; State = Get-PcTweakState $t }
        }
    }
    Start-PcJob -Work $work -Arguments @{ Category = $Category } -Status (Get-PcText 'status.loading') -OnDone {
        param($r)
        $states = @{}
        foreach ($s in $r) { $states[$s.Id] = $s.State }
        # Ignore a result for a page the user already left
        if ($script:PcTweakCategories -contains $script:PcPage) { Set-PcItems (Get-PcTweakItems $script:PcPage $states) }
    }
}

function Get-PcTweakItems([string]$Category, [hashtable]$States) {
    $journalKeys = @(Get-PcJournal | ForEach-Object { $_.key })
    foreach ($t in $script:PcTweaks | Where-Object category -eq $Category) {
        $state = if ($States -and $States.ContainsKey($t.id)) { $States[$t.id] } else { Get-PcTweakState $t }
        $meta = @()
        if ($t.scope -eq 'user') { $meta += Get-PcText 'tweak.userScope' }
        if ($t.requires -and $t.requires.restart) { $meta += Get-PcText 'tweak.restart' }
        if ($t.requires -and $t.requires.signOut) { $meta += Get-PcText 'tweak.signOut' }
        if ($t.requires -and $t.requires.restartExplorer) { $meta += Get-PcText 'tweak.restartExplorer' }
        if ($t.evidence -eq 'community') { $meta += Get-PcText 'tweak.community' }
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
            # The link says honestly where it goes: Microsoft, the vendor, or a community source
            LinkText  = Get-PcText $(switch ($t.evidence) { 'vendor' { 'link.vendor' } 'community' { 'link.community' } default { 'link.learnMore' } })
            IsEnabled = $state -ne 'NotApplicable'
            IsSelected = ($script:PcPreselected -contains $t.id) -and @('NotApplicable', 'Applied') -notcontains $state
        }
    }
}

$script:PcApplyWork = {
    param($Sync, $Ids, $CreateRestorePoint)
    if ($CreateRestorePoint) {
        $Sync.Status = Get-PcText 'status.creatingRestorePoint'
        if (-not (New-PcRestorePoint -Description ('PitCrew {0:yyyy-MM-dd HH:mm}' -f (Get-Date)))) {
            return [pscustomobject]@{ NoRestorePoint = $true }
        }
    }
    $tweaks = @(Import-PcTweaks)
    $ok = 0
    $failed = @()
    foreach ($id in $Ids) {
        $t = $tweaks | Where-Object id -eq $id
        $Sync.Status = '{0} {1}' -f (Get-PcText 'status.applying'), (Resolve-PcLocalized $t.title)
        try { [void](Invoke-PcTweak $t); $ok++ } catch { $failed += '{0}: {1}' -f (Resolve-PcLocalized $t.title), $_.Exception.Message }
    }
    [pscustomobject]@{ NoRestorePoint = $false; Ok = $ok; Failed = $failed }
}

function Show-PcApplyDialog($Tweaks) {
    # Returns $null when cancelled, otherwise whether to create a restore point first
    $dialog = New-PcApplyDialog $Tweaks
    $dialog.Owner = $Ui.Window
    if (-not $dialog.ShowDialog()) { return $null }
    return @{ RestorePoint = [bool]$script:PcDialog.RestorePoint.IsChecked }
}

function New-PcApplyDialog($Tweaks) {
    # Lists what is about to change and offers a restore point (checked by default).
    # Handlers can't see locals, so the dialog's controls live in $script:PcDialog.
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="540" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False" FontFamily="Segoe UI" FontSize="13" Background="White">
  <StackPanel Margin="26,22">
    <TextBlock x:Name="Heading" FontSize="18" FontWeight="SemiBold" Foreground="#1B1F24"/>
    <TextBlock x:Name="Intro" Foreground="#5F6773" Margin="0,8,0,6"/>
    <ItemsControl x:Name="Changes" Margin="0,0,0,14">
      <ItemsControl.ItemTemplate>
        <DataTemplate><TextBlock Text="{Binding}" TextWrapping="Wrap" Margin="0,2" Foreground="#1B1F24"/></DataTemplate>
      </ItemsControl.ItemTemplate>
    </ItemsControl>
    <CheckBox x:Name="RestorePoint" IsChecked="True">
      <TextBlock x:Name="RestorePointText" TextWrapping="Wrap" FontWeight="SemiBold"/>
    </CheckBox>
    <TextBlock x:Name="LastPoint" Foreground="#5F6773" TextWrapping="Wrap" Margin="22,4,0,0" FontSize="12" Visibility="Collapsed"/>
    <TextBlock x:Name="Note" Foreground="#9A5B00" TextWrapping="Wrap" Margin="22,6,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
      <Button x:Name="Cancel" IsCancel="True"/>
      <Button x:Name="Confirm" IsDefault="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $dialog = [Windows.Markup.XamlReader]::Parse($xaml)
    $script:PcDialog = @{ Window = $dialog }
    foreach ($n in 'Heading', 'Intro', 'Changes', 'RestorePoint', 'RestorePointText', 'LastPoint', 'Note', 'Cancel', 'Confirm') { $script:PcDialog[$n] = $dialog.FindName($n) }
    $d = $script:PcDialog
    $dialog.Title = 'PitCrew'
    $d.Heading.Text = Get-PcText 'dialog.apply.title'
    $d.Intro.Text = Get-PcText 'dialog.apply.intro'
    $d.Changes.ItemsSource = @(foreach ($t in $Tweaks) {
        $line = '•  ' + (Resolve-PcLocalized $t.title)
        if ($t.requires -and $t.requires.restart) { $line += '  (' + (Get-PcText 'dialog.apply.restart') + ')' }
        $line
    })
    $d.RestorePointText.Text = Get-PcText 'dialog.apply.restorePoint'
    $d.Cancel.Content = Get-PcText 'dialog.cancel'
    $d.Confirm.Content = Get-PcText 'dialog.apply.confirm'
    $d.Cancel.Style = $Ui.Window.Resources['SecondaryButton']
    $d.Confirm.Style = $Ui.Window.Resources['PrimaryButton']
    $d.Note.Text = Get-PcText 'dialog.apply.noRestorePointNote'
    $blockedKey = $null
    if ($Pc.SkipRestorePoint) { $blockedKey = 'dialog.apply.testMode' }
    elseif (Test-PcRestorePolicyBlocked) { $blockedKey = 'dialog.apply.policyBlocked' }
    if ($blockedKey) {
        $d.RestorePoint.IsChecked = $false
        $d.RestorePoint.IsEnabled = $false
        $d.Note.Text = Get-PcText $blockedKey
        $d.Note.Visibility = 'Visible'
    } elseif ($script:PcIsAdmin) {
        # Knowing a recent point exists helps decide; listing needs admin and takes a moment
        $last = Get-PcLastRestorePoint
        if ($last) {
            $d.LastPoint.Text = Get-PcText 'dialog.apply.lastPoint' -FormatArgs $last.Created.ToString('g'), $last.Description
            $d.LastPoint.Visibility = 'Visible'
        }
    }
    $toggle = { $script:PcDialog.Note.Visibility = if ($script:PcDialog.RestorePoint.IsChecked) { 'Collapsed' } else { 'Visible' } }
    $d.RestorePoint.Add_Checked($toggle)
    $d.RestorePoint.Add_Unchecked($toggle)
    $d.Confirm.Add_Click({ $script:PcDialog.Window.DialogResult = $true })
    return $dialog
}

function Invoke-PcApplyTweaks {
    $selected = Get-PcSelectedItems
    if ($selected.Count -eq 0) { Show-PcMessage (Get-PcText 'msg.selectFirst'); return }
    $ids = @($selected | ForEach-Object Id)
    $choice = Show-PcApplyDialog @($script:PcTweaks | Where-Object { $ids -contains $_.id })
    if (-not $choice) { return }
    $script:PcPendingApply = @{ Ids = $ids; CreateRestorePoint = $choice.RestorePoint }
    $status = if ($choice.RestorePoint) { Get-PcText 'status.creatingRestorePoint' } else { Get-PcText 'status.applying' }
    Start-PcJob -Work $script:PcApplyWork -Arguments $script:PcPendingApply -Status $status -OnDone {
        param($r)
        $res = $r[-1]
        if ($res.NoRestorePoint) {
            if (Confirm-PcAction (Get-PcText 'msg.noRestorePoint')) {
                Start-PcJob -Work { param($Sync) Enable-PcSystemProtection } -Status (Get-PcText 'status.enablingProtection') -OnDone {
                    param($r)
                    Start-PcJob -Work $script:PcApplyWork -Arguments $script:PcPendingApply -Status (Get-PcText 'status.creatingRestorePoint') -OnDone ${function:Complete-PcApply}
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
    $script:PcPreselected = @($script:PcPreselected | Where-Object { $script:PcPendingApply.Ids -notcontains $_ })
    Update-PcCurrentPage
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
        Update-PcCurrentPage
        Show-PcMessage ($lines -join "`n`n")
    }
}

# --- History --------------------------------------------------------------------------------------

function Get-PcHistoryItems {
    foreach ($e in @(Get-PcMyJournalEntries) | Sort-Object appliedAt -Descending) {
        $t = $script:PcTweaks | Where-Object id -eq $e.tweakId | Select-Object -First 1
        $when = Get-PcText 'history.appliedAt' -FormatArgs ([datetime]::Parse($e.appliedAt).ToString('g'))
        if ($t) {
            $state = Get-PcTweakState $t
            New-PcItem @{ Id = $t.id; Title = Resolve-PcLocalized $t.title; Detail = Resolve-PcLocalized $t.description
                Badge = Get-PcText "state.$state"; BadgeKind = $(if ($state -eq 'Applied') { 'good' } else { 'warn' }); Meta = $when }
        } else {
            # Undo needs the catalog entry to know what to touch
            New-PcItem @{ Id = $e.tweakId; Title = $e.tweakId; Detail = Get-PcText 'history.removedTweak'; Meta = $when; Selectable = $false }
        }
    }
}

# --- Restore points -------------------------------------------------------------------------------

function Invoke-PcLoadRestorePoints {
    # Listing restore points needs administrator rights
    if (-not $script:PcIsAdmin) { Set-PcItems @() 'restore.needsAdmin'; return }
    $work = {
        param($Sync)
        foreach ($p in Get-PcRestorePointList) {
            [pscustomobject]@{
                Description = $p.Description
                Type        = [int]$p.RestorePointType
                Created     = [Management.ManagementDateTimeConverter]::ToDateTime($p.CreationTime)
            }
        }
    }
    Start-PcJob -Work $work -Status (Get-PcText 'status.loading') -OnDone {
        param($r)
        Set-PcItems @(foreach ($p in @($r) | Sort-Object Created -Descending) {
            $typeKey = "restore.type.$($p.Type)"
            if (@(0, 1, 10, 12, 13) -notcontains $p.Type) { $typeKey = 'restore.type.other' }
            New-PcItem @{ Id = [string]$p.Created.Ticks; Title = $p.Description; Meta = $p.Created.ToString('g'); Badge = Get-PcText $typeKey; Selectable = $false }
        }) 'restore.empty'
    }
}

function Invoke-PcCreateRestorePoint {
    if (Test-PcRestorePolicyBlocked) { Show-PcMessage (Get-PcText 'msg.restorePolicyBlocked') 'Warning'; return }
    $work = {
        param($Sync, $EnableFirst)
        if ($EnableFirst) { Enable-PcSystemProtection }
        $name = 'PitCrew {0:yyyy-MM-dd HH:mm}' -f (Get-Date)
        [pscustomobject]@{ Created = (New-PcRestorePoint -Description $name); Name = $name }
    }
    $script:PcRestoreWork = $work
    Start-PcJob -Work $work -Arguments @{ EnableFirst = $false } -Status (Get-PcText 'status.creatingRestorePoint') -OnDone {
        param($r)
        if ($r[-1].Created) { Show-PcMessage (Get-PcText 'msg.restorePointCreated' -FormatArgs $r[-1].Name); Invoke-PcLoadRestorePoints; return }
        if (-not (Confirm-PcAction (Get-PcText 'msg.noRestorePoint'))) { return }
        Start-PcJob -Work $script:PcRestoreWork -Arguments @{ EnableFirst = $true } -Status (Get-PcText 'status.enablingProtection') -OnDone {
            param($r)
            if ($r[-1].Created) { Show-PcMessage (Get-PcText 'msg.restorePointCreated' -FormatArgs $r[-1].Name) }
            else { Show-PcMessage (Get-PcText 'msg.noRestorePointAbort') 'Warning' }
            Invoke-PcLoadRestorePoints
        }
    }
}

# --- Maintenance ----------------------------------------------------------------------------------

function Get-PcMaintenanceItems {
    foreach ($m in $script:PcMaintenanceTasks) {
        New-PcItem @{ Id = $m.Id; Title = Get-PcText $m.TextKey; Detail = Get-PcText "$($m.TextKey).detail"; Data = $m.Long }
    }
}

function Invoke-PcRunMaintenance {
    $selected = Get-PcSelectedItems
    if ($selected.Count -eq 0) { Show-PcMessage (Get-PcText 'msg.selectFirst'); return }
    foreach ($long in @($selected | Where-Object { $_.Data })) {
        if (-not (Confirm-PcAction (Get-PcText 'maintenance.confirmLong' -FormatArgs $long.Title))) { return }
    }
    $folder = $null
    if (@($selected | Where-Object Id -eq 'driver-backup').Count -gt 0) {
        $folder = Get-PcDriverBackupFolder
        if (-not (Confirm-PcAction (Get-PcText 'maintenance.confirmDriverBackup' -FormatArgs $folder))) { return }
    }
    $work = { param($Sync, $Ids, $Folder) @(Invoke-PcMaintenance -Ids $Ids -Sync $Sync -DriverBackupFolder $Folder) }
    Start-PcJob -Work $work -Arguments @{ Ids = @($selected | ForEach-Object Id); Folder = $folder } -Status (Get-PcText 'status.loading') -OnDone {
        param($r)
        Show-PcMessage (@($r) -join "`n`n")
    }
}

# --- Startup apps ---------------------------------------------------------------------------------

function Invoke-PcLoadStartup {
    Start-PcJob -Work { param($Sync) Get-PcStartupItems } -Status (Get-PcText 'status.loading') -OnDone {
        param($r)
        Set-PcItems @(foreach ($s in $r) {
            $meta = $s.Source
            if ($s.Publisher) { $meta += '  ·  ' + $s.Publisher }
            New-PcItem @{
                Id        = $s.Id
                Title     = $s.Name
                Detail    = [string]$s.Command
                Meta      = $meta
                Badge     = $(if ($s.Enabled) { Get-PcText 'startup.enabled' } else { Get-PcText 'startup.disabled' })
                BadgeKind = $(if ($s.Enabled) { 'good' } else { 'neutral' })
                Tag       = $(if ($s.TargetExists) { '' } else { Get-PcText 'startup.missing' })
                TagKind   = 'warn'
                Data      = $s.Enabled
            }
        }) 'startup.empty'
    }
}

function Invoke-PcSetStartup([bool]$Enabled) {
    # Same switch as Task Manager: nothing is deleted, so this is its own undo
    $selected = @(Get-PcSelectedItems | Where-Object { [bool]$_.Data -ne $Enabled })
    if ($selected.Count -eq 0) { Show-PcMessage (Get-PcText 'msg.selectFirst'); return }
    $work = {
        param($Sync, $Ids, $Enabled)
        $ok = 0; $failed = @()
        foreach ($id in $Ids) {
            try { Set-PcStartupItemEnabled -Id $id -Enabled $Enabled; $ok++ }
            catch { $failed += '{0}: {1}' -f ($id -split '\|')[-1], $_.Exception.Message }
        }
        [pscustomobject]@{ Ok = $ok; Failed = $failed }
    }
    Start-PcJob -Work $work -Arguments @{ Ids = @($selected | ForEach-Object Id); Enabled = $Enabled } -Status (Get-PcText 'status.loading') -OnDone {
        param($r)
        $res = $r[-1]
        $text = Get-PcText 'msg.startupDone' -FormatArgs $res.Ok, @($res.Failed).Count
        if (@($res.Failed).Count -gt 0) { $text += "`n`n" + (@($res.Failed) -join "`n") }
        Show-PcMessage $text
        Invoke-PcLoadStartup
    }
}

# --- Cleanup --------------------------------------------------------------------------------------

function Invoke-PcAnalyzeCleanup {
    Start-PcJob -Work { param($Sync) Get-PcCleanupTargets } -Status (Get-PcText 'status.analyzing') -OnDone {
        param($r)
        Set-PcItems @(foreach ($t in $r) {
            $meta = Get-PcText 'cleanup.meta' -FormatArgs (Format-PcBytes $t.Bytes), $t.Files
            if ($t.Id -eq 'delivery-optimization') { $meta = Format-PcBytes $t.Bytes }
            if (-not $t.Available) { $meta = Get-PcText $t.BlockedKey }
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
            $detail = if ($a.Note) { $a.Note } else { $a.Package }
            $tagKind = if ($a.Risk -eq 'caution') { 'warn' } else { 'neutral' }
            New-PcItem @{ Id = $a.Package; Title = $a.Name; Detail = $detail; Meta = $a.Package; Badge = $badge; BadgeKind = $kind
                Tag = Get-PcText "apps.risk.$($a.Risk)"; TagKind = $tagKind; Data = $a.Installed }
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
            Board      = Get-PcBoardInfo
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
        if ($s.Board -and $s.Board.SupportUrl) {
            $lines += Get-PcText 'drivers.board' -FormatArgs $s.Board.Maker, $s.Board.Model, $s.Board.SupportUrl
        }
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
    # Drivers always get a restore point; a policy that forbids them also stops this
    if (Test-PcRestorePolicyBlocked) { Show-PcMessage (Get-PcText 'msg.restorePolicyBlocked') 'Warning'; return }
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
    $Ui.SearchHint.Text = Get-PcText 'filter.search'
    $Ui.HideUnavailable.Content = Get-PcText 'filter.hideUnavailable'
    $Ui.ExportProfile.Content = Get-PcText 'button.exportProfile'
    Update-PcPresetBox
    foreach ($page in 'Performance', 'Privacy', 'Explorer', 'Startup', 'Cleanup', 'Maintenance', 'Apps', 'Drivers', 'Restore', 'History', 'About') {
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
    foreach ($name in 'Tagline', 'ModeText', 'LanguageBox', 'Nav', 'NavPerformance', 'NavPrivacy', 'NavExplorer', 'NavStartup', 'NavCleanup', 'NavMaintenance',
        'NavApps', 'NavDrivers', 'NavRestore', 'NavHistory', 'NavAbout', 'PageTitle', 'PageIntro', 'Banner', 'BannerText', 'PageInfo', 'Items', 'EmptyText',
        'PrimaryAction', 'SecondaryAction', 'Busy', 'StatusText', 'FilterBar', 'SearchBox', 'SearchHint', 'HideUnavailable',
        'ExportProfile', 'PresetBox') {
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
    $Ui.SearchBox.Add_TextChanged({ Update-PcFilter })
    $Ui.HideUnavailable.Add_Checked({ Update-PcFilter })
    $Ui.HideUnavailable.Add_Unchecked({ Update-PcFilter })
    $Ui.PresetBox.Add_SelectionChanged({ Invoke-PcPresetChosen })
    $Ui.ExportProfile.Add_Click({ Invoke-PcExportProfile })
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

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
        // Untranslated state the status filter works on (Applied, NotApplied, Installed, On...)
        public string State { get; set; }
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

if (-not ('PitCrew.NativeShell' -as [type])) {
    # Gives the window its own taskbar button and icon instead of grouping it with PowerShell
    Add-Type -Namespace PitCrew -Name NativeShell -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
public static extern void SetCurrentProcessExplicitAppUserModelID(string appId);
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
'@
}

# --- Themes ---------------------------------------------------------------------------------------

# Light must match the defaults in Theme.xaml (switching back from dark restores these)
$script:PcPalettes = @{
    light = @{
        Bg = '#F6F7F9'; Surface = '#FFFFFF'; SurfaceAlt = '#E9ECF0'; Line = '#E3E6EA'; Ink = '#1B1F24'; Body = '#3C434D'
        Muted = '#5F6773'; Faint = '#8A919C'; Link = '#0B62D6'; Accent = '#E10600'; AccentText = '#FFFFFF'
        Sidebar = '#15171C'; SidebarText = '#C9CED6'; SidebarFaint = '#8A919C'; SidebarInput = '#22252B'; NavHover = '#1F2228'; NavSelected = '#262A31'
        PillBg = '#EEF0F3'; PillText = '#4A5160'; GoodBg = '#E7F6EC'; GoodText = '#1E7B3A'; WarnBg = '#FFF4E0'; WarnText = '#8A5200'; WarnLine = '#F2D29B'
        BadBg = '#FDECEC'; BadText = '#B42318'; InfoBg = '#E8F0FD'; InfoText = '#0B62D6'; InputBg = '#FFFFFF'; Thumb = '#C7CCD3'
        Hero = '#15171C'; HeroText = '#C9CED6'
    }
    dark = @{
        Bg = '#121418'; Surface = '#1B1E24'; SurfaceAlt = '#2A2E36'; Line = '#2C3038'; Ink = '#E8EAED'; Body = '#C4C9D0'
        Muted = '#9AA1AC'; Faint = '#7D848F'; Link = '#6CA8FF'; Accent = '#E10600'; AccentText = '#FFFFFF'
        Sidebar = '#0B0C0F'; SidebarText = '#C9CED6'; SidebarFaint = '#7D848F'; SidebarInput = '#1A1D22'; NavHover = '#1A1D22'; NavSelected = '#22262D'
        PillBg = '#2A2E36'; PillText = '#B8BEC7'; GoodBg = '#16351F'; GoodText = '#7DDA92'; WarnBg = '#33280F'; WarnText = '#F5C26B'; WarnLine = '#5C4518'
        BadBg = '#3D1A1A'; BadText = '#FF8A80'; InfoBg = '#1A2A44'; InfoText = '#8DBBFF'; InputBg = '#15181D'; Thumb = '#3A3F48'
        Hero = '#0B0C0F'; HeroText = '#C9CED6'
    }
}
$script:PcThemeChoice = 'auto'
$script:PcTheme = 'light'

function ConvertFrom-PcXaml([string]$Xaml) {
    # Every window and dialog gets the shared theme dictionary (styles and palette) in its resources
    $theme = [IO.File]::ReadAllText((Join-Path $Pc.Root 'src\UI\Theme.xaml')) -replace '^\s*<\?xml[^>]*\?>', ''
    [Windows.Markup.XamlReader]::Parse($Xaml.Replace('<!--THEME-->', $theme))
}

function Get-PcEffectiveTheme([string]$Choice) {
    if (@('light', 'dark') -contains $Choice) { return $Choice }
    # Automatic: the app mode chosen in Windows Settings > Personalization > Colors
    try {
        $light = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' -ErrorAction Stop
        if ($light -eq 0) { return 'dark' }
    } catch { }
    return 'light'
}

function Set-PcPalette($Resources, [string]$Theme) {
    foreach ($entry in $script:PcPalettes[$Theme].GetEnumerator()) {
        $brush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($entry.Value))
        $brush.Freeze()
        # The cast unwraps PowerShell's PSObject; WPF only accepts the brush itself
        $Resources[$entry.Key] = [Windows.Media.SolidColorBrush]$brush
    }
}

function Set-PcTitleBarTheme($Window, [string]$Theme) {
    # Dark title bar: attribute 20 on current Windows, 19 on early Windows 10; ignored elsewhere
    try {
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper($Window)).Handle
        if ($hwnd -eq [IntPtr]::Zero) { return }
        $on = [int]($Theme -eq 'dark')
        if ([PitCrew.NativeShell]::DwmSetWindowAttribute($hwnd, 20, [ref]$on, 4) -ne 0) {
            [void][PitCrew.NativeShell]::DwmSetWindowAttribute($hwnd, 19, [ref]$on, 4)
        }
    } catch { }
}

function Set-PcTheme([string]$Choice) {
    $script:PcThemeChoice = $Choice
    $script:PcTheme = Get-PcEffectiveTheme $Choice
    Set-PcPalette $Ui.Window.Resources $script:PcTheme
    Set-PcTitleBarTheme $Ui.Window $script:PcTheme
}

function Initialize-PcDialogWindow($Dialog) {
    # Same colors and title bar as the main window; owned by it only once it is on screen
    Set-PcPalette $Dialog.Resources $script:PcTheme
    $Dialog.Add_SourceInitialized({ Set-PcTitleBarTheme $this $script:PcTheme })
    if ($Ui.Window -and $Ui.Window.IsVisible) { $Dialog.Owner = $Ui.Window } else { $Dialog.WindowStartupLocation = 'CenterScreen' }
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
    # Anything that would start another job or switch pages waits until this one ends
    foreach ($control in $Ui.Nav, $Ui.LanguageBox, $Ui.Items, $Ui.RefreshButton, $Ui.ExportProfile, $Ui.PresetBox) {
        if ($control) { $control.IsEnabled = -not $IsBusy }
    }
    if ($IsBusy) {
        $Ui.PrimaryAction.IsEnabled = $false
        $Ui.SecondaryAction.IsEnabled = $false
        if ($Status) { $Ui.StatusText.Text = $Status }
    } else {
        Update-PcActionButtons
    }
}

function Show-PcDialog([string]$Text, [string]$Icon = 'Information', [switch]$Confirm) {
    $dialog = New-PcMessageDialog $Text $Icon -Confirm:$Confirm
    if ($script:PcDialogSound) { $script:PcDialogSound.Play() }
    return [bool]$dialog.ShowDialog()
}

function New-PcMessageDialog([string]$Text, [string]$Icon = 'Information', [switch]$Confirm) {
    # PitCrew's own message box: follows the theme, and the text can be selected and copied
    # (to paste an error into an issue). A confirmation defaults to No, like the Windows one did.
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PitCrew" Width="480" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False" FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Surface}">
  <Window.Resources>
    <ResourceDictionary>
      <ResourceDictionary.MergedDictionaries><!--THEME--></ResourceDictionary.MergedDictionaries>
    </ResourceDictionary>
  </Window.Resources>
  <DockPanel Margin="24,22,24,20">
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
      <Button x:Name="No" Style="{StaticResource SecondaryButton}" MinWidth="88" Visibility="Collapsed"/>
      <Button x:Name="Yes" Style="{StaticResource PrimaryButton}" MinWidth="88"/>
    </StackPanel>
    <Border x:Name="Badge" DockPanel.Dock="Left" Width="34" Height="34" CornerRadius="17" VerticalAlignment="Top" Margin="0,0,14,0">
      <TextBlock x:Name="Glyph" FontSize="17" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <ScrollViewer MaxHeight="440" VerticalScrollBarVisibility="Auto">
      <TextBox x:Name="Message" IsReadOnly="True" TextWrapping="Wrap" BorderThickness="0" Background="Transparent" Padding="0" Margin="0,7,0,0"/>
    </ScrollViewer>
  </DockPanel>
</Window>
'@
    $dialog = ConvertFrom-PcXaml $xaml
    $parts = @{}
    foreach ($n in 'No', 'Yes', 'Badge', 'Glyph', 'Message') { $parts[$n] = $dialog.FindName($n) }
    $look = switch ($Icon) {
        'Warning' { @('!', 'WarnBg', 'WarnText', [System.Media.SystemSounds]::Exclamation) }
        'Error'   { @([string][char]0x00D7, 'BadBg', 'BadText', [System.Media.SystemSounds]::Hand) }
        'Question' { @('?', 'InfoBg', 'InfoText', $null) }
        default   { @('i', 'InfoBg', 'InfoText', [System.Media.SystemSounds]::Asterisk) }
    }
    if ($Confirm -and $Icon -eq 'Information') { $look = @('?', 'InfoBg', 'InfoText', $null) }
    $parts.Glyph.Text = $look[0]
    $parts.Badge.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $look[1])
    $parts.Glyph.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $look[2])
    $parts.Message.Text = $Text
    if ($Confirm) {
        $parts.No.Visibility = 'Visible'
        $parts.No.Content = Get-PcText 'dialog.no'
        $parts.Yes.Content = Get-PcText 'dialog.yes'
        # Enter and Esc both answer No; only a deliberate click says Yes
        $parts.No.IsDefault = $true
        $parts.No.IsCancel = $true
    } else {
        $parts.Yes.Content = Get-PcText 'dialog.ok'
        $parts.Yes.IsDefault = $true
        $parts.Yes.IsCancel = $true
    }
    $parts.Yes.Add_Click({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })
    Initialize-PcDialogWindow $dialog
    $dialog.Add_ContentRendered({ [void]$this.FindName($(if ($this.FindName('No').IsVisible) { 'No' } else { 'Yes' })).Focus() })
    $script:PcDialogSound = $look[3]
    return $dialog
}

function Show-PcMessage([string]$Text, [string]$Icon = 'Information') {
    [void](Show-PcDialog $Text $Icon)
}

function Confirm-PcAction([string]$Text) {
    return (Show-PcDialog $Text 'Question' -Confirm)
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
    Update-PcSelectionCount
    $Ui.EmptyText.Text = Get-PcText $EmptyKey
    $Ui.EmptyText.Visibility = if ($list.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    Update-PcActionButtons
}

# --- Search, filter, presets and profiles ---------------------------------------------------------

$script:PcPreselected = @()

# Status filter options per kind of page; the texts are filter.<option>
$script:PcFilterOptions = @{
    tweaks  = @('all', 'available', 'notApplied', 'applied', 'partial', 'selected')
    apps    = @('all', 'installed', 'notInstalled', 'selected')
    startup = @('all', 'on', 'off', 'selected')
}
# Options that keep only one State (set on each card, never translated)
$script:PcFilterStates = @{
    notApplied = 'NotApplied'; applied = 'Applied'; partial = 'Partial'
    installed = 'Installed'; notInstalled = 'NotInstalled'; on = 'On'; off = 'Off'
}
$script:PcStatusFilter = 'all'

function Get-PcFilterKind([string]$Page) {
    if ($script:PcTweakCategories -contains $Page) { return 'tweaks' }
    if ($script:PcFilterOptions.ContainsKey($Page)) { return $Page }
    return $null
}

function Update-PcStatusFilter([string]$Page) {
    # Refilled on every page change and language change; starts at "All"
    $script:PcFilterUpdating = $true
    $Ui.StatusFilter.Items.Clear()
    $kind = Get-PcFilterKind $Page
    if ($kind) {
        foreach ($option in $script:PcFilterOptions[$kind]) {
            $entry = New-Object System.Windows.Controls.ComboBoxItem
            $entry.Content = Get-PcText "filter.$option"
            $entry.Tag = $option
            [void]$Ui.StatusFilter.Items.Add($entry)
        }
        $Ui.StatusFilter.SelectedIndex = 0
    }
    $script:PcStatusFilter = 'all'
    $script:PcFilterUpdating = $false
}

function Test-PcItemVisible($Item) {
    if (-not $Ui.FilterBar -or $Ui.FilterBar.Visibility -ne 'Visible') { return $true }
    switch ($script:PcStatusFilter) {
        'all'       { }
        'available' { if ($Item.State -eq 'NotApplicable') { return $false } }
        'selected'  { if (-not $Item.IsSelected) { return $false } }
        default     { if ($Item.State -ne $script:PcFilterStates[$script:PcStatusFilter]) { return $false } }
    }
    $q = $Ui.SearchBox.Text.Trim()
    if (-not $q) { return $true }
    return ($Item.Title.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
        ($Item.Detail.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Update-PcFilter {
    $Ui.SearchHint.Visibility = if ($Ui.SearchBox.Text) { 'Collapsed' } else { 'Visible' }
    if ($Ui.Items.ItemsSource) {
        $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($Ui.Items.ItemsSource)
        $view.Filter = [Predicate[object]] { param($item) Test-PcItemVisible $item }
        $view.Refresh()
    }
    Update-PcSelectionCount
}

function Update-PcSelectionCount {
    # Counts what an action would really touch: ticked and visible
    $n = @(Get-PcSelectedItems).Count
    $Ui.SelectionText.Text = if ($n -gt 0) { Get-PcText 'footer.selected' -FormatArgs $n } else { '' }
}

function Select-PcVisibleItems([bool]$Selected) {
    foreach ($item in @($Ui.Items.ItemsSource)) {
        if (-not $Selected) { $item.IsSelected = $false; continue }
        # Only what is on screen and can be acted on
        if ($item.Selectable -and $item.IsEnabled -and (Test-PcItemVisible $item)) { $item.IsSelected = $true }
    }
    Update-PcSelectionCount
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
    memory      = @{ Primary = @('button.closeApps', $false, $true); Secondary = @('button.memoryDiagnostic', $true, $false) }
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
    # Search, status filter and quick selection on long lists; presets and profiles only for tweaks
    $isTweakPage = $script:PcTweakCategories -contains $Page
    $Ui.FilterBar.Visibility = if (Get-PcFilterKind $Page) { 'Visible' } else { 'Collapsed' }
    $Ui.PresetBox.Visibility = if ($isTweakPage) { 'Visible' } else { 'Collapsed' }
    $Ui.ExportProfile.Visibility = if ($isTweakPage) { 'Visible' } else { 'Collapsed' }
    Update-PcStatusFilter $Page
    $Ui.SearchBox.Text = ''
    Set-PcItems @()
    $Ui.EmptyText.Visibility = 'Collapsed'
    $Ui.AboutPanel.Visibility = 'Collapsed'
    $Ui.MemoryBar.Visibility = 'Collapsed'
    $Ui.RefreshButton.Visibility = if ($Page -eq 'memory') { 'Visible' } else { 'Collapsed' }
    $Ui.StatusText.Text = Get-PcText 'status.ready'
    switch ($Page) {
        'startup' { Invoke-PcLoadStartup }
        'cleanup' { Invoke-PcAnalyzeCleanup }
        'memory'  { Invoke-PcLoadMemory }
        'apps'    { Invoke-PcLoadApps }
        'drivers' { Invoke-PcLoadDriverSummary }
        'restore' { Invoke-PcLoadRestorePoints }
        'about'   { Show-PcAbout }
        default   { Update-PcCurrentPage }
    }
}

function Open-PcWebPage([Uri]$Uri) {
    # Web pages only: a link (some come from the catalog files) must never start a program or open a file
    if (-not ($Uri -and $Uri.IsAbsoluteUri -and @('http', 'https') -contains $Uri.Scheme)) { return }
    if (Test-PcAdmin) {
        # Started from here the browser would run as administrator too. Explorer hands the link to
        # the desktop's own shell, which opens it as the signed-in user.
        $explorer = Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe'
        Start-Process -FilePath $explorer -ArgumentList "`"$($Uri.AbsoluteUri)`""
    } else {
        Start-Process $Uri.AbsoluteUri
    }
}

function Set-PcLink($Hyperlink, $TextRun, [string]$Url) {
    $Hyperlink.NavigateUri = [Uri]$Url
    $TextRun.Text = $Url -replace '^https://(www\.)?', '' -replace '/$', ''
}

function Show-PcAbout {
    $Ui.AboutVersion.Text = Get-PcText 'about.version' -FormatArgs $script:PcVersion
    $Ui.AboutTagline.Text = Get-PcText 'app.tagline'
    $Ui.AboutBeta.Text = Get-PcText 'about.beta'
    $Ui.AboutWhatTitle.Text = Get-PcText 'about.whatTitle'
    $Ui.AboutWhat.Text = Get-PcText 'about.what'
    $Ui.AboutFeaturesTitle.Text = Get-PcText 'about.featuresTitle'
    $Ui.AboutFeatures.ItemsSource = @((Get-PcText 'about.features' -FormatArgs $script:PcTweaks.Count) -split "`n" | Where-Object { $_ })
    $Ui.AboutGoalTitle.Text = Get-PcText 'about.goalTitle'
    $Ui.AboutGoal.Text = Get-PcText 'about.goal'
    $Ui.AboutAuthorTitle.Text = Get-PcText 'about.authorTitle'
    $Ui.AboutAuthorBio.Text = Get-PcText 'about.authorBio'
    Set-PcLink $Ui.LinkGitHub $Ui.LinkGitHubText $script:PcLinks.AuthorGitHub
    Set-PcLink $Ui.LinkLinkedIn $Ui.LinkLinkedInText $script:PcLinks.AuthorLinkedIn
    $Ui.AboutProjectTitle.Text = Get-PcText 'about.projectTitle'
    $Ui.AboutRepoText.Text = Get-PcText 'about.repo'
    Set-PcLink $Ui.LinkRepo $Ui.LinkRepoText $script:PcLinks.Repository
    $Ui.LinkIssues.NavigateUri = [Uri]$script:PcLinks.Issues
    $Ui.LinkIssuesText.Text = Get-PcText 'about.issues'
    $Ui.AboutCredits.Text = Get-PcText 'about.credits'
    $Ui.AboutTranslations.Text = Get-PcText 'about.translations'
    $Ui.AboutDataDir.Text = Get-PcText 'about.dataDir' -FormatArgs $Pc.DataDir
    $Ui.UpdateTitle.Text = Get-PcText 'update.title'
    $Ui.UpdateAutoText.Text = Get-PcText 'update.auto'
    $Ui.UpdateAuto.IsChecked = (Get-PcPreference 'UpdateCheck') -eq 'on'
    $Ui.UpdateCheckNow.Content = Get-PcText 'update.checkNow'
    $status = $script:PcUpdateStatus
    if ($status) { Set-PcUpdateStatus $status[0] $status[1] } else { Set-PcUpdateStatus '' }
    Show-PcSupport
    $Ui.AboutPanel.Visibility = 'Visible'
}

# --- New-version notice (the check itself is in src\Core\Update.ps1) ---------------------------------

$script:PcUpdateCheck = $null    # the request in flight, finished by the window's timer
$script:PcUpdateFound = $null    # the newer release shown at the top of the window, or $null
$script:PcUpdateStatus = $null   # the About page's line after "Check now": text key and value
$script:PcUpdateStartPending = $false   # set by Show-PcWindow; the timer then runs Initialize-PcUpdateCheck

function Initialize-PcUpdateCheck {
    # Once the window is on screen. The first time, ask: No, Esc or closing the question mean off.
    $choice = Get-PcPreference 'UpdateCheck'
    if (@('on', 'off') -notcontains $choice) {
        $choice = if (Confirm-PcAction (Get-PcText 'update.ask')) { 'on' } else { 'off' }
        Set-PcPreference 'UpdateCheck' $choice
    }
    if ($choice -ne 'on') { return }
    # What the last check found stays up until the next one answers
    $last = Get-PcPreference 'UpdateLatest'
    if ($last) { Show-PcUpdateNotice (Select-PcNewerRelease -Tags $last) }
    # Noted before asking, so a failed check (offline, a proxy) also waits for tomorrow
    $today = Get-Date -Format 'yyyy-MM-dd'
    if ((Get-PcPreference 'UpdateCheckedOn') -ne $today) {
        Set-PcPreference 'UpdateCheckedOn' $today
        Start-PcUpdateCheck
    }
}

function Start-PcUpdateCheck([switch]$Manual) {
    # Not a Start-PcJob job: it runs beside page loads and never holds up the window or its closing
    if ($script:PcUpdateCheck) {
        if ($Manual) { $script:PcUpdateCheck.Manual = $true }
        return
    }
    $ps = [powershell]::Create()
    $ps.Runspace = [runspacefactory]::CreateRunspace()
    $ps.Runspace.Open()
    [void]$ps.AddScript(${function:Get-PcReleaseList}.ToString()).AddArgument($script:PcReleasesApi)
    $script:PcUpdateCheck = @{ PS = $ps; Handle = $ps.BeginInvoke(); Manual = [bool]$Manual }
}

function Complete-PcUpdateCheck {
    # Called by the dispatcher timer, like Complete-PcJob
    $check = $script:PcUpdateCheck
    if (-not $check -or -not $check.Handle.IsCompleted) { return }
    $script:PcUpdateCheck = $null
    try {
        $found = Find-PcNewerRelease -Json (-join @($check.PS.EndInvoke($check.Handle)))
        Set-PcPreference 'UpdateLatest' $(if ($found) { $found.Tag } else { '' })
        # Turned off while the request was out: only an explicit "Check now" still shows it
        if ($check.Manual -or (Get-PcPreference 'UpdateCheck') -eq 'on') { Show-PcUpdateNotice $found }
        $status = if ($found) { @('update.found', $found.Version) } else { @('update.upToDate', $script:PcVersion) }
    } catch {
        # Offline, a proxy, GitHub's hourly limit: logged, and tried again the next time
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        # A parse error quotes the whole answer; one short line is enough here
        $reason = ($e.Message -replace '\s+', ' ').Trim()
        if ($reason.Length -gt 200) { $reason = $reason.Substring(0, 200) + '...' }
        Write-PcLog "New-version check failed: $reason" 'Warn'
        $status = @('update.failed', $reason)
    } finally {
        $check.PS.Runspace.Dispose()
        $check.PS.Dispose()
    }
    if ($check.Manual) { Set-PcUpdateStatus $status[0] $status[1] }
}

function Show-PcUpdateNotice($Found) {
    $script:PcUpdateFound = $Found
    $Ui.UpdateBar.Visibility = if ($Found) { 'Visible' } else { 'Collapsed' }
    if (-not $Found) { return }
    $Ui.UpdateText.Text = Get-PcText 'update.available' -FormatArgs $Found.Version, $script:PcVersion
    $Ui.UpdateLinkText.Text = Get-PcText 'update.open'
    $Ui.UpdateLink.NavigateUri = [Uri]$Found.Url
}

function Set-PcUpdateStatus([string]$Key, [string]$Value) {
    $script:PcUpdateStatus = if ($Key) { @($Key, $Value) } else { $null }
    $Ui.UpdateStatus.Text = if ($Key) { Get-PcText $Key -FormatArgs $Value } else { '' }
}

function Show-PcSupport {
    # Donations by Pix: the key, the "copia e cola" code and the QR code (assets\pix-qr.png)
    $key = $script:PcDonation.PixKey
    $Ui.SupportCard.Visibility = if ($key) { 'Visible' } else { 'Collapsed' }
    if (-not $key) { return }
    $Ui.SupportTitle.Text = Get-PcText 'about.support'
    $Ui.SupportText.Text = Get-PcText 'about.supportText'
    $Ui.PixKeyLabel.Text = Get-PcText 'about.pixKey'
    $Ui.PixKey.Text = $key
    $Ui.CopyPixKey.Content = Get-PcText 'about.copyPixKey'
    $Ui.CopyPixCode.Content = Get-PcText 'about.copyPixCode'
    $qr = Get-PcAssetImage 'pix-qr.png'
    $Ui.PixQr.Source = $qr
    $Ui.PixQrFrame.Visibility = if ($qr) { 'Visible' } else { 'Collapsed' }
}

function Copy-PcText([string]$Text) {
    try {
        [System.Windows.Clipboard]::SetText($Text)
        $Ui.StatusText.Text = Get-PcText 'about.copied'
    } catch { Show-PcMessage (Get-PcText 'msg.error' -FormatArgs $_.Exception.Message) 'Error' }
}

function Get-PcLogoImage { Get-PcAssetImage 'pitcrew.png' }

function Get-PcAssetImage([string]$Name) {
    # A missing picture only hides it; it never stops the window from opening
    $file = Join-Path $Pc.Root "assets\$Name"
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $image = New-Object Windows.Media.Imaging.BitmapImage
    $image.BeginInit()
    $image.UriSource = New-Object Uri $file
    $image.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $image.EndInit()
    $image.Freeze()
    $image
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
        'memory'      { Invoke-PcCloseApps }
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
        'memory'  { Invoke-PcMemoryDiagnostic }
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
            State     = [string]$state
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
        ShowInTaskbar="False" FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Surface}">
  <Window.Resources>
    <ResourceDictionary>
      <ResourceDictionary.MergedDictionaries><!--THEME--></ResourceDictionary.MergedDictionaries>
    </ResourceDictionary>
  </Window.Resources>
  <StackPanel Margin="26,22">
    <TextBlock x:Name="Heading" FontSize="18" FontWeight="SemiBold" Foreground="{DynamicResource Ink}"/>
    <TextBlock x:Name="Intro" Foreground="{DynamicResource Muted}" Margin="0,8,0,6"/>
    <ItemsControl x:Name="Changes" Margin="0,0,0,14">
      <ItemsControl.ItemTemplate>
        <DataTemplate><TextBlock Text="{Binding}" TextWrapping="Wrap" Margin="0,2" Foreground="{DynamicResource Ink}"/></DataTemplate>
      </ItemsControl.ItemTemplate>
    </ItemsControl>
    <CheckBox x:Name="RestorePoint" IsChecked="True">
      <TextBlock x:Name="RestorePointText" TextWrapping="Wrap" FontWeight="SemiBold"/>
    </CheckBox>
    <TextBlock x:Name="LastPoint" Foreground="{DynamicResource Muted}" TextWrapping="Wrap" Margin="24,4,0,0" FontSize="12" Visibility="Collapsed"/>
    <TextBlock x:Name="Note" Foreground="{DynamicResource WarnText}" TextWrapping="Wrap" Margin="24,6,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
      <Button x:Name="Cancel" Style="{StaticResource SecondaryButton}" IsCancel="True"/>
      <Button x:Name="Confirm" Style="{StaticResource PrimaryButton}"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $dialog = ConvertFrom-PcXaml $xaml
    Initialize-PcDialogWindow $dialog
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
            # A policy that locks System Restore settings means PitCrew must not offer to change them
            if (-not (Test-PcRestoreConfigLocked) -and (Confirm-PcAction (Get-PcText 'msg.noRestorePoint'))) {
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
            try {
                $u = Undo-PcTweak $t
                $skipped += $u.Skipped
                $done++
                if ($u.Failed -gt 0) { $failed += Get-PcText 'msg.undoPartial' -FormatArgs (Resolve-PcLocalized $t.title), $u.Failed }
            }
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
        if ($script:PcPage -ne 'restore') { return }
        Set-PcItems @(foreach ($p in @($r) | Sort-Object Created -Descending) {
            $typeKey = "restore.type.$($p.Type)"
            if (@(0, 1, 10, 12, 13) -notcontains $p.Type) { $typeKey = 'restore.type.other' }
            New-PcItem @{ Id = [string]$p.Created.Ticks; Title = $p.Description; Meta = $p.Created.ToString('g'); Badge = Get-PcText $typeKey; Selectable = $false }
        }) 'restore.empty'
    }
}

function Invoke-PcCreateRestorePoint {
    if (Test-PcRestorePolicyBlocked) { Show-PcMessage (Get-PcText 'msg.restorePolicyBlocked') 'Warning'; return }
    if ($Pc.SkipRestorePoint) { Show-PcMessage (Get-PcText 'dialog.apply.testMode'); return }
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
        if ((Test-PcRestoreConfigLocked) -or -not (Confirm-PcAction (Get-PcText 'msg.noRestorePoint'))) { Show-PcMessage (Get-PcText 'msg.noRestorePointAbort') 'Warning'; return }
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

# --- Memory ---------------------------------------------------------------------------------------

function Invoke-PcLoadMemory {
    Start-PcJob -Work { param($Sync) [pscustomobject]@{ Status = Get-PcMemoryStatus; Groups = @(Get-PcMemoryGroups) } } -Status (Get-PcText 'status.loading') -OnDone {
        param($r)
        if ($script:PcPage -ne 'memory') { return }
        $m = $r[-1]
        $s = $m.Status
        $Ui.MemoryBar.Value = $s.Percent
        $Ui.MemoryBar.Visibility = 'Visible'
        $lines = @(Get-PcText 'memory.summary' -FormatArgs (Format-PcBytes $s.UsedBytes), (Format-PcBytes $s.TotalBytes), $s.Percent, (Format-PcBytes $s.AvailableBytes))
        if ($s.PageFileSizeBytes -gt 0) { $lines[0] += '  ·  ' + (Get-PcText 'memory.pageFile' -FormatArgs (Format-PcBytes $s.PageFileUsedBytes), (Format-PcBytes $s.PageFileSizeBytes)) }
        $lines += Get-PcText 'memory.note'
        Set-PcPageInfo ($lines -join "`n`n")
        Set-PcItems @(foreach ($g in @($m.Groups)) {
            New-PcItem @{
                Id         = $g.Name
                Title      = $g.DisplayName
                Detail     = $(if ($g.Count -gt 1) { Get-PcText 'memory.processes' -FormatArgs $g.Count } else { $g.Name })
                Badge      = Format-PcBytes $g.Bytes
                BadgeKind  = $(if ($g.Bytes -ge 1.5GB) { 'warn' } else { 'neutral' })
                Meta       = $(if ($g.Closable) { '' } else { Get-PcText 'memory.notClosable' })
                Selectable = [bool]$g.Closable
                Data       = @($g.WindowKeys)
            }
        }) 'memory.empty'
    }
}

function Invoke-PcCloseApps {
    $selected = Get-PcSelectedItems
    if ($selected.Count -eq 0) { Show-PcMessage (Get-PcText 'msg.selectFirst'); return }
    if (-not (Confirm-PcAction (Get-PcText 'memory.confirmClose' -FormatArgs $selected.Count))) { return }
    $keys = @(foreach ($s in $selected) { @($s.Data) | ForEach-Object { [string]$_ } })
    $work = {
        param($Sync, $Keys)
        $asked = Close-PcProcessWindows -Keys $Keys
        # Give the programs a moment to close (or to ask about saving) before measuring again
        Start-Sleep -Seconds 2
        $asked
    }
    Start-PcJob -Work $work -Arguments @{ Keys = $keys } -Status (Get-PcText 'status.closingApps') -OnDone {
        param($r)
        Show-PcMessage (Get-PcText 'memory.closeDone' -FormatArgs ([int]$r[-1]))
        Invoke-PcLoadMemory
    }
}

function Invoke-PcMemoryDiagnostic {
    # Windows' own memory test runs at the next restart; MdSched asks when to restart
    try { Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'MdSched.exe') }
    catch { Show-PcMessage (Get-PcText 'msg.error' -FormatArgs $_.Exception.Message) 'Error' }
}

# --- Startup apps ---------------------------------------------------------------------------------

function Invoke-PcLoadStartup {
    Start-PcJob -Work { param($Sync) Get-PcStartupItems } -Status (Get-PcText 'status.loading') -OnDone {
        param($r)
        # A result for a page the user already left is dropped
        if ($script:PcPage -ne 'startup') { return }
        Set-PcItems @(foreach ($s in $r) {
            $meta = $s.Source
            if ($s.Publisher) { $meta += '  ·  ' + $s.Publisher }
            New-PcItem @{
                Id        = $s.Id
                State     = $(if ($s.Enabled) { 'On' } else { 'Off' })
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
        if ($script:PcPage -ne 'cleanup') { return }
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
        foreach ($bad in @($r | Where-Object Error)) { $text += "`n" + ('{0}: {1}' -f ((Get-PcText "cleanup.$($bad.Id).detail") -split '[.。]')[0], $bad.Error) }
        Show-PcMessage $text
        Invoke-PcAnalyzeCleanup
    }
}

# --- Apps -----------------------------------------------------------------------------------------

function Invoke-PcLoadApps {
    Start-PcJob -Work { param($Sync) Get-PcRemovableApps } -Status (Get-PcText 'status.loading') -OnDone {
        param($r)
        if ($script:PcPage -ne 'apps') { return }
        Set-PcItems @(foreach ($a in $r) {
            $badge = if ($a.Installed) { Get-PcText 'apps.installed' } else { Get-PcText 'apps.notInstalled' }
            $kind = if ($a.Installed) { 'neutral' } else { 'good' }
            $detail = if ($a.Note) { $a.Note } else { $a.Package }
            $tagKind = if ($a.Risk -eq 'caution') { 'warn' } else { 'neutral' }
            New-PcItem @{ Id = $a.Package; State = $(if ($a.Installed) { 'Installed' } else { 'NotInstalled' })
                Title = $a.Name; Detail = $detail; Meta = $a.Package; Badge = $badge; BadgeKind = $kind
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
        if ($script:PcPage -ne 'drivers') { return }
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
        if ($script:PcPage -ne 'drivers') { return }
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
    $Ui.SelectVisible.Content = Get-PcText 'filter.selectVisible'
    $Ui.ClearSelection.Content = Get-PcText 'filter.clearSelection'
    $Ui.RefreshButton.Content = Get-PcText 'button.refresh'
    $Ui.ExportProfile.Content = Get-PcText 'button.exportProfile'
    Update-PcPresetBox
    Update-PcThemeBox
    foreach ($page in 'Performance', 'Privacy', 'Explorer', 'Startup', 'Cleanup', 'Memory', 'Maintenance', 'Apps', 'Drivers', 'Restore', 'History', 'About') {
        $Ui["Nav$page"].Content = Get-PcText "nav.$($page.ToLowerInvariant())"
    }
    $Ui.ModeText.Text = if ($script:PcIsAdmin) { Get-PcText 'mode.admin' } else { Get-PcText 'mode.readOnly' }
    $banner = @()
    if (-not $script:PcIsAdmin) { $banner += Get-PcText 'banner.readOnly' }
    if ($script:PcOtherUser) { $banner += Get-PcText 'banner.otherUser' }
    if ($Pc.SkipRestorePoint) { $banner += Get-PcText 'banner.testMode' }
    # Fail closed: an unsafe data folder means nothing can be changed this session
    if ($script:PcIsAdmin -and -not $Pc.RegistryRedirect -and -not (Test-PcPathTrusted $Pc.DataDir)) { $banner += Get-PcText 'error.dataUntrusted' }
    $Ui.BannerText.Text = $banner -join "`n"
    $Ui.Banner.Visibility = if ($banner) { 'Visible' } else { 'Collapsed' }
    # In the language just picked
    Show-PcUpdateNotice $script:PcUpdateFound
}

function Update-PcThemeBox {
    $script:PcThemeUpdating = $true
    $Ui.ThemeBox.Items.Clear()
    foreach ($choice in 'auto', 'light', 'dark') {
        $option = New-Object System.Windows.Controls.ComboBoxItem
        $option.Content = Get-PcText "theme.$choice"
        $option.Tag = $choice
        [void]$Ui.ThemeBox.Items.Add($option)
        if ($choice -eq $script:PcThemeChoice) { $Ui.ThemeBox.SelectedItem = $option }
    }
    $script:PcThemeUpdating = $false
}

function New-PcWindow {
    $xaml = [IO.File]::ReadAllText((Join-Path $Pc.Root 'src\UI\Window.xaml'))
    $window = ConvertFrom-PcXaml $xaml
    $script:Ui = @{ Window = $window }
    foreach ($name in 'Tagline', 'ModeText', 'LanguageBox', 'ThemeBox', 'Nav', 'NavPerformance',
        'NavPrivacy', 'NavExplorer', 'NavStartup', 'NavCleanup', 'NavMemory', 'NavMaintenance', 'NavApps', 'NavDrivers', 'NavRestore', 'NavHistory',
        'NavAbout', 'PageTitle', 'PageIntro', 'RefreshButton', 'Banner', 'BannerText', 'MemoryBar', 'PageInfo', 'Items', 'EmptyText',
        'PrimaryAction', 'SecondaryAction', 'SelectionText', 'Busy', 'StatusText', 'FilterBar', 'SearchBox', 'SearchHint', 'StatusFilter',
        'SelectVisible', 'ClearSelection', 'ExportProfile', 'PresetBox', 'LogoImage', 'AboutPanel', 'AboutIcon', 'AboutVersion', 'AboutTagline', 'AboutBeta',
        'AboutWhatTitle', 'AboutWhat', 'AboutFeaturesTitle', 'AboutFeatures', 'AboutGoalTitle', 'AboutGoal', 'AboutAuthorTitle',
        'AboutAuthorBio', 'LinkGitHub', 'LinkGitHubText', 'LinkLinkedIn', 'LinkLinkedInText',
        'SupportCard', 'PixQrFrame', 'PixQr', 'SupportTitle', 'SupportText', 'PixKeyLabel', 'PixKey', 'CopyPixKey', 'CopyPixCode',
        'AboutProjectTitle', 'AboutRepoText', 'LinkRepo', 'LinkRepoText', 'LinkIssues', 'LinkIssuesText', 'AboutCredits',
        'AboutTranslations', 'AboutDataDir', 'UpdateBar', 'UpdateText', 'UpdateLink', 'UpdateLinkText', 'UpdateTitle', 'UpdateAuto',
        'UpdateAutoText', 'UpdateCheckNow', 'UpdateStatus') {
        $Ui[$name] = $window.FindName($name)
    }

    # Theme: the one picked last time, otherwise follow Windows
    $savedTheme = Get-PcPreference 'Theme'
    $script:PcThemeChoice = if (@('auto', 'light', 'dark') -contains $savedTheme) { $savedTheme } else { 'auto' }
    Set-PcTheme $script:PcThemeChoice
    $window.Add_SourceInitialized({ Set-PcTitleBarTheme $Ui.Window $script:PcTheme })

    $iconFile = Join-Path $Pc.Root 'assets\pitcrew.ico'
    if (Test-Path -LiteralPath $iconFile) {
        try {
            $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri $iconFile),
                [Windows.Media.Imaging.BitmapCreateOptions]::None, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        } catch { Write-PcLog "Window icon not loaded: $($_.Exception.Message)" 'Warn' }
    }
    $logo = Get-PcLogoImage
    if ($logo) { $Ui.LogoImage.Source = $logo; $Ui.AboutIcon.Source = $logo }

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
        # Remembered for next time; without a saved choice PitCrew follows the Windows language
        Set-PcPreference 'Language' $code
        Set-PcStaticTexts
        Show-PcPage $script:PcPage
    })
    $Ui.ThemeBox.Add_SelectionChanged({
        if ($script:PcThemeUpdating) { return }
        $choice = [string]$Ui.ThemeBox.SelectedItem.Tag
        if (-not $choice -or $choice -eq $script:PcThemeChoice) { return }
        Set-PcTheme $choice
        Set-PcPreference 'Theme' $choice
    })
    $Ui.Nav.Add_SelectionChanged({
        $item = $Ui.Nav.SelectedItem
        if ($item) { Show-PcPage $item.Tag }
    })
    $Ui.SearchBox.Add_TextChanged({ Update-PcFilter })
    $Ui.StatusFilter.Add_SelectionChanged({
        if ($script:PcFilterUpdating -or -not $Ui.StatusFilter.SelectedItem) { return }
        $script:PcStatusFilter = [string]$Ui.StatusFilter.SelectedItem.Tag
        Update-PcFilter
    })
    $Ui.SelectVisible.Add_Click({ Select-PcVisibleItems $true })
    $Ui.ClearSelection.Add_Click({ Select-PcVisibleItems $false })
    $Ui.RefreshButton.Add_Click({ if ($script:PcPage -eq 'memory') { Invoke-PcLoadMemory } })
    $Ui.CopyPixKey.Add_Click({ Copy-PcText $script:PcDonation.PixKey })
    $Ui.CopyPixCode.Add_Click({ Copy-PcText (Get-PcPixPayload) })
    $Ui.UpdateAuto.Add_Click({
        $on = [bool]$Ui.UpdateAuto.IsChecked
        Set-PcPreference 'UpdateCheck' $(if ($on) { 'on' } else { 'off' })
        # Off also takes down what an earlier check found
        if (-not $on) { Show-PcUpdateNotice $null }
    })
    $Ui.UpdateCheckNow.Add_Click({
        Set-PcUpdateStatus 'update.checking'
        Start-PcUpdateCheck -Manual
    })
    $Ui.PresetBox.Add_SelectionChanged({ Invoke-PcPresetChosen })
    $Ui.ExportProfile.Add_Click({ Invoke-PcExportProfile })
    $Ui.PrimaryAction.Add_Click({ Invoke-PcPrimaryAction })
    $Ui.SecondaryAction.Add_Click({ Invoke-PcSecondaryAction })
    $window.AddHandler([System.Windows.Documents.Hyperlink]::RequestNavigateEvent,
        [System.Windows.Navigation.RequestNavigateEventHandler] {
            param($s, $e)
            $e.Handled = $true
            Open-PcWebPage $e.Uri
        })
    # A card ticked or unticked updates the "N ticked" count in the footer
    $window.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler] {
            param($s, $e)
            if ($e.OriginalSource -is [System.Windows.Controls.CheckBox]) { Update-PcSelectionCount }
        })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        Complete-PcJob
        Complete-PcUpdateCheck
        # The first-time question waits until the window is up and the first page has loaded
        if ($script:PcUpdateStartPending -and -not $script:PcJob -and $Ui.Window.IsVisible) {
            $script:PcUpdateStartPending = $false
            try { Initialize-PcUpdateCheck } catch { Write-PcLog "New-version check not started: $($_.Exception.Message)" 'Warn' }
        }
    })
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
    # Must happen before the first window exists, or the taskbar groups it under PowerShell
    try { [PitCrew.NativeShell]::SetCurrentProcessExplicitAppUserModelID($script:PcAppId) }
    catch { Write-PcLog "AppUserModelID not set: $($_.Exception.Message)" 'Warn' }
    # Only its existence matters: it tells src\Setup.ps1 a window is open, and goes away with this
    # process. Opening one an elevated PitCrew made can fail here; that window already counts.
    try { $script:PcWindowMarker = New-Object System.Threading.Mutex($false, $script:PcWindowMutexName) }
    catch { Write-PcLog "Window mutex not created: $($_.Exception.Message)" 'Warn' }
    $window = New-PcWindow
    # The timer runs Initialize-PcUpdateCheck once the window is up (tests build the window
    # without this, so they never ask or go online)
    $script:PcUpdateStartPending = $true
    [void]$window.ShowDialog()
    $Ui.Timer.Stop()
}

# Architecture

PitCrew is plain PowerShell 5.1 (ships with every Windows 10/11) plus a WPF window. No build step,
no binaries, nothing downloaded at run time.

```
PitCrew.bat / PitCrew.ps1   entry point: window by default, -List / -Apply / -Undo for scripts
PitCrew.exe                 (release zip only) double-click launcher built from tools/launcher/PitCrew.cs
Install.bat / src/Setup.ps1 installer: Program Files, desktop and Start menu shortcuts, removal from Settings > Apps
src/Load.ps1                dot-sources every file below, in order (a future single-file build = concat)
src/Core/Context.ps1        version and links, shared state ($Pc), admin and user checks, logging, JSON helpers
src/Core/I18n.ps1           locales/<lang>.json, English fallback, per-tweak localized texts
src/Core/Registry.ps1       registry reads/writes, type-exact comparison, test redirect
src/Core/Tweaks.ps1         declarative tweak engine and the undo journal
src/Core/RestorePoint.ps1   verified restore point creation
src/Modules/*.ps1           drivers, cleanup, maintenance, memory, apps, startup, devices: task-style features that aren't simple settings
src/UI/Window.xaml|.ps1     the window and PitCrew's own dialogs; slow work runs in a background runspace
src/UI/Theme.xaml           shared styles and the light palette, put into every window and dialog
tweaks/<category>.json      the settings catalog (one file per category)
data/apps.json              removable apps with verified Microsoft Store IDs and safe/caution labels
data/presets.json           presets: lists of tweak ids that are only pre-ticked, never applied directly
locales/<lang>.json         interface texts
assets/pitcrew.ico|.png     the icon (window, taskbar, PitCrew.exe, README), drawn by tools/Build-Icon.ps1
tests/Run-Tests.ps1         dependency-free tests (also runs Startup-Tests, Launcher-Tests, Setup-Tests and Devices-Real)
tests/Launcher-Tests.ps1    builds PitCrew.exe and checks, with --dry-run, what it would start
tests/Setup-Tests.ps1       installs and removes PitCrew in temp folders (for real only on GitHub's runners)
tests/Devices-Real.ps1      flips one device's power box and puts it back (only on GitHub's runners)
tests/Smoke-Window.ps1      drives every page's read-only jobs without showing the window
tests/Check-Catalog.ps1     read-only: which catalog targets exist on this PC and their state
tests/Render-Window.ps1     renders a page or the apply dialog to PNG
tools/Start-Sandbox.ps1     run PitCrew inside Windows Sandbox
tools/Build-CatalogDoc.ps1  regenerates docs/CATALOG.md from the catalog
tools/Build-Icon.ps1        draws the icon from code (WPF geometry) at every size
tools/Build-Release.ps1     tests, PitCrew.exe and dist/PitCrew-<version>.zip with its SHA-256
tools/launcher/             source and manifest of PitCrew.exe
tools/Build-PixQr.ps1       draws assets/pix-qr.png (donations) from the Pix data, with tools/QrCode.cs
src/Core/Pix.ps1            the Pix "copia e cola" code (Banco Central BR Code with its CRC16)
src/Core/Update.ps1         the new-version check: GitHub's list of releases, version order, the link
src/Core/Stats.ps1          the dashboard's running totals (stats.json next to the journal)
src/Modules/Dashboard.ps1   the dashboard: PC summary, before and now from the journal, tiles
src/Modules/Analysis.ps1    the automatic analysis: recommendations from the presets, and applying them in one go
.github/workflows/build.yml tests and builds on GitHub Actions; signs PitCrew.exe for version tags (docs/SIGNING.md)
.github/signpath/           copy of the SignPath artifact configuration (what gets signed, and its checks)
```

## A tweak

```jsonc
{
  "id": "privacy.advertising-id",
  "risk": "safe",                  // safe | moderate (has side effects) | advanced
  "scope": "machine",              // machine (HKLM, needs admin) | user (HKCU of the signed-in user)
  "evidence": "learn",             // learn (Microsoft Learn) | vendor (vendor docs) | community (observed, undocumented)
  "reversible": true,
  "reference": "https://learn.microsoft.com/...",   // where the setting is documented (always required)
  "appliesTo": {                                    // optional
    "minBuild": 22000, "maxBuild": 26100,
    "editions": ["home", "pro"],                    // families: home | pro | enterprise | education
    "formFactor": "desktop"                         // desktop | laptop (chassis type, not just "has a battery")
  },
  "requires": { "restart": true, "signOut": false, "restartExplorer": false },   // optional badges
  "refresh": "mouse",                               // optional; applies HKCU\Control Panel\Mouse immediately
  "title":       { "en": "...", "pt-BR": "...", "es": "...", "fr": "...", "de": "...", "ru": "...", "tr": "...", "zh-CN": "..." },
  "description": { "en": "What it does. What you lose.", "...": "every locale in locales/" },
  "actions": [ ... ]
}
```

One tweak has one scope, because the undo journal is keyed by it: split a setting that has both a
machine and a per-user part into two tweaks.

Two more optional fields:

- `"conflictsWith": ["other.id"]` for tweaks that own the same thing (the two power plans, the
  two diagnostic-data levels). Applying one is refused while the other is recorded, so undoing
  them can't restore each other's snapshot.
- `"restoreBefore": "absentOnly"` on a registry action whose location loads code (a COM server
  path, for example). PitCrew only creates the value and later deletes it; it refuses to take over
  a value another program already set, and Undo never writes a value read from the journal there.

### Action types

| type | fields | scope | notes |
|---|---|---|---|
| `registry` | `path` (`HKLM:\...` or `HKCU:\...`), `name` (`""` = the key's default value), `kind` (`DWord`, `QWord`, `String`, `ExpandString`, `MultiString`, `Binary`), `value` — or `absent: true` to delete | HKLM → machine, HKCU → user | Keys PitCrew had to create are removed again on undo when empty |
| `dxSetting` | `key`, `value` | user | One `key=value;` pair inside `HKCU\Software\Microsoft\DirectX\UserGpuPreferences\DirectXUserGlobalSettings`; other pairs are kept |
| `service` | `name`, `startupType` (`Automatic`, `AutomaticDelayed`, `Manual`, `Disabled`) | machine | Changed with `sc.exe config`; takes effect at next start, so set `requires.restart`. Skipped if the service doesn't exist |
| `scheduledTask` | `path` (starts and ends with `\`), `name`, `enabled` (bool) | machine | Skipped if the task doesn't exist. Prefer small groups per tweak: one access-denied task fails the whole tweak |
| `powerPlan` | `guid` (plan to activate), `source` (template to copy it from if missing) | machine | Undo re-activates the previous plan and deletes the copy if PitCrew made it. Use `appliesTo.formFactor: "desktop"` |
| `hibernation` | `enabled` (bool) | machine | `powercfg /hibernate`; turning it off also turns off Fast Startup |

State is computed from the actions whose target exists on this PC: **Applied** (all match),
**Not applied**, **Partially applied**, or **Not available** when `appliesTo` excludes this
Windows or none of the targets exist. `tests\Check-Catalog.ps1` shows, read-only, which targets
exist on the current PC.

## Undo

Before each action runs, the engine records the previous state in the journal
(`%ProgramData%\PitCrew\journal.json`):

- whether the value existed, its exact type and data;
- which registry keys it had to create.

The journal stores only previous *values*; where to act (paths, service and task names, plan
GUIDs) always comes from the catalog, every record carries a fingerprint of its target and is
only used for the catalog action with the same one, and every value read back is validated.

The journal is written after **each** step (write-ahead), so a crash or Ctrl+C still leaves an
Undo for what was already changed; a named mutex keeps two PitCrew processes from rewriting it at
the same time, and a step whose rollback fails keeps its record. Undo keeps going when one step fails and keeps that step in
the journal to retry. Undo stays possible after an edition upgrade made a tweak "not available".

`%ProgramData%\PitCrew` is reused only when it is provably PitCrew's: owned by Administrators or
SYSTEM, not a junction, and writable by no one else. Otherwise it is moved aside (never read) and
a new one is created with its permissions set in the same call. If that fails, PitCrew changes
nothing (fail closed), and every apply, undo and write into the folder checks this again.

Cleanup deletes by handle: each file or folder is opened without following a final link, its real
location is checked against the folder being cleaned, and only then is that exact object deleted.
A folder swapped for a junction between listing and deleting can't redirect it.

Undo restores that state and deletes created keys that are empty again, **but only where the
current value is still the one PitCrew wrote**. If something else changed it since, that action is
skipped and reported. Applying the same tweak twice keeps the first snapshot. If one action in a
tweak fails, the ones before it are rolled back, so a tweak is never left half applied. Entries
for user-scope tweaks are keyed by the user's SID.

Before applying, the window lists what will change and offers a restore point, ticked by default.
With it ticked, and always from the command line (`-Apply`), nothing is changed if the restore point
can't be created (the user can choose to turn on System Protection and retry). Driver installs
always require one.

## Safety checks

- **Wrong account:** if UAC was approved with a different admin account, HKCU belongs to that
  account. PitCrew compares its own SID with the owner of `explorer.exe` and blocks user-scope
  tweaks, user cleanup and app removal in that case.
- **Read-only mode:** without admin rights, everything can be viewed, nothing can be changed.
- **Drivers:** offers older than the installed driver, without a date, for an unidentified
  device, firmware, or graphics drivers are never marked recommended. Third-party drivers being
  replaced are exported with `pnputil` first.
- **Apps:** only apps in `data/apps.json`; the Store, winget, Windows Security and runtime
  frameworks are blocked even if someone adds them there.

## Adding a setting

1. Find the setting on Microsoft Learn (Policy CSP, ADMX reference or the privacy endpoints page)
   and put the URL in `reference`. If Microsoft doesn't document it, say so in the pull request and
   explain where the behaviour was verified.
2. Add the entry to `tweaks/<category>.json` with `en` and `pt-BR` texts at least. The description
   must say what the user loses, if anything.
3. Run `tests\Run-Tests.ps1`, then try Apply and Undo in Windows Sandbox (`tools\Start-Sandbox.ps1`).

Settings that only exist as folklore go to [NOT-INCLUDED.md](NOT-INCLUDED.md) instead.

## Window and background work

Event handlers can't see function locals, so live controls are kept in `$script:Ui`. Anything
slow (restore point, Windows Update, cleanup, winget) runs through `Start-PcJob`, which starts a
runspace, loads `src/Load.ps1` again with the same context, and runs the work there. A dispatcher
timer polls the job and calls its `OnDone` handler on the UI thread. One job runs at a time and the
window can't be closed while it runs.

## Themes, dialogs and preferences

`src/UI/Theme.xaml` holds the shared styles (buttons, check boxes, combo boxes, scroll bars) and the
light palette. `ConvertFrom-PcXaml` puts it into the resources of every window and dialog before
parsing, and `Set-PcTheme` swaps the palette for the dark one at run time, so every color in the
XAML must be a `DynamicResource` (a test fails on any hard-coded color or `StaticResource` color).
"Automatic" follows the Windows app mode (`AppsUseLightTheme`); the title bar follows through the
DWM dark-mode attribute.

Messages and confirmations are PitCrew's own dialogs, themed like the window, with selectable text
(errors can be copied into an issue). A confirmation answers No to Enter and Esc.

The language and theme picked in the window are saved in `HKCU\Software\PitCrew`. Language order:
`-Language`, the saved choice, the Windows display language (`es-AR` gets `es`, `pt-PT` gets
`pt-BR`), English.

The list cards carry an untranslated `State` (Applied, NotApplied, Installed, On...) that the status
filter uses, so filters work the same in every language. Hidden cards are never acted on, and "tick
all shown" only ticks visible cards that can be acted on.

## Device power

`src/Modules/Devices.ps1` lists the devices whose driver offers Device Manager's "Allow the
computer to turn off this device to save power" box. Device Manager reads and sets that box
through the `MSPower_DeviceEnable` WMI class (`root\wmi`, one boolean per device; see
[WMI and the Power Management tab](https://learn.microsoft.com/windows-hardware/drivers/kernel/wmi-and-the-power-management-tab)),
and PitCrew does the same. Reading works without administrator rights. Only network, Bluetooth,
USB, keyboard, mouse and HID devices are shown: GPIO, security processors and the like also offer
the box, but nothing documents a reason to touch them.

The page shows one card per physical device. The interfaces of a composite USB device (a
keyboard's two "USB Input Device" entries, IDs with `&MI_xx`) are one card. Names come from what
the device reports on the bus ("USB Mouse", the keyboard's product name) rather than Windows'
generic "USB Input Device". A hub shows what is plugged into it, and a controller shows what is
plugged into its root hub, so identical "USB Root Hub" cards can be told apart (History adds the
same to the name). Hubs and controllers are recognized by ID and driver (`USB\ROOT_HUB*`,
`PCI\*`, `USBHUB3`, `USBXHCI`...), never by the name, which Windows translates. PnP properties
are read one device per call, because `Get-PnpDeviceProperty` given several IDs at once sometimes
labels a row with the wrong device.

Each card becomes a tweak built on the fly (`device.power.<hash of the device ID>`), with one
`devicePower` action per WMI instance, so changes use the same engine as everything else. The
journal records the previous value and the value set (an interface that already had it keeps
`before` equal to `enabled`, so one can't be worked out from the other), History lists the change
under the device's name (kept in the entry as `label`), and Undo puts it back. A device that is
unplugged when undone is skipped and kept to retry. The journal only says which device; the
action only runs on a device that is plugged in and has the box right now. "Let Windows turn off" on a device PitCrew kept on undoes
that change instead of stacking a second one. The fakes in `tests/Run-Tests.ps1` cover the
engine side; `tests/Devices-Real.ps1` flips a real device and puts it back on GitHub's runners,
when the VM has one.

## Dashboard

The first page. It only reads, in one background job (`Get-PcDashboard`, about 3 seconds), and
each part is read on its own, so one that fails is left out and the rest still shows:

- **PC summary:** CIM classes (`Win32_OperatingSystem`, `Win32_ComputerSystem`, `Win32_Processor`,
  `Win32_PhysicalMemory`, `Win32_VideoController`, `Win32_LogicalDisk`) and `MSFT_PhysicalDisk`
  queried directly, which is seconds faster than `Get-PhysicalDisk`. A board that reports
  "System Product Name" is named by its motherboard. "Last full start" is `LastBootUpTime`; with
  Fast Startup on, shutting down doesn't reset it, so it's labelled as a full start.
- **What has been optimized:** only journal entries count as PitCrew's work, never a setting that
  was already in place (on a typical PC most "Applied" states were set by Windows or another tool).
  Startup apps and built-in apps show how things are now, whoever changed them. Counting every
  catalog state would take about ten seconds, so the dashboard doesn't.
- **Before and now:** one card per journal entry. "Before" is the journal's snapshot; "now" is
  read live by type (registry value, service start type, task on/off, power plan name from
  `powercfg /list`, hibernation, device power box), so a change someone made later shows up.
  Applying a tweak that was partly in place records every action, also the ones that already had
  the value; those lines are left out (`Test-PcRecordChanged`), since PitCrew didn't change them.
  "Changed later" on the tiles means the entry now reads Not applied or Partial; Not applicable
  (an unplugged device, another edition) and unreadable aren't counted as changes. Undo stays in
  History.
- **Totals:** `src/Core/Stats.ps1` keeps `stats.json` in the data folder. The actions add to it
  themselves, only for what really happened: an apply that changed something (`Invoke-PcTweak`
  returned true; device power changes have their own tile and aren't counted as tweaks), a
  cleanup with at least one target done (the Recycle Bin and the Delivery Optimization cache are
  measured before and after), an app that was installed and is gone, a driver that installed. The
  number counts applies, not distinct tweaks: apply, undo and apply again count 2. Only
  administrators write there, and everything counted needs administrator rights anyway; the
  totals aren't shown from a data folder that isn't provably ours. The start date is the first
  counted action, never the first visit: opening the dashboard writes nothing. A write goes to a
  temp file swapped in with `File.Replace`; a file that isn't valid JSON is kept as
  `stats.json.bad` and the count starts over, one that can't be opened right now is left alone,
  and nothing about counting can fail the action it counts.

No score and no claim about speed or boot time: the dashboard shows what was read, and leaves out
what couldn't be. The memory card shows what is in use and leads to the Memory page; there is no
"clean memory" button (docs/NOT-INCLUDED.md).

## Automatic analysis

For people who don't know which pages to visit, `src/Modules/Analysis.ps1` gathers the
recommendations of the tweak, cleanup, built-in apps and startup pages in one list. Drivers,
device power, maintenance and memory stay out: installing drivers carries risk, device power only
fixes a problem someone has, and repairs take long. It never runs on its own: the profiles (the
presets in `data/presets.json`) start unticked, and Analyze stays off until one is ticked.

`Get-PcAnalysis` only reads: the state of the tweaks the chosen presets name (and of their
`conflictsWith` alternatives), the cleanup sizes, the built-in apps and the startup programs.
`ConvertTo-PcRecommendations` turns that into the list, without touching the system:

| Area | Listed | Ticked |
|---|---|---|
| Tweaks | in a chosen preset, Not applied or Partial | `safe` only; `moderate` listed unticked; `advanced` never listed |
| Cleanup | something to free, or blocked with the reason | yes, except the Recycle Bin |
| Built-in apps | installed and labelled `safe` | no: whether you use an app is not something an analysis knows |
| Startup | starts with Windows now | no: it could be the antivirus or a driver's helper |

A tweak is left out when its alternative is applied (High Performance while Ultimate is on) or is
still in the journal (the engine refuses the pair until that entry is undone), and of two presets
asking for both sides of a pair the first wins, so a batch never hits `error.conflict`. A tweak
the catalog marks `reversible: false` is never ticked. Each card says how it comes back: Undo in
History, reinstall from the Apps page (needs internet and the Store; a restore point doesn't bring
apps back), turn back on in the Startup page, or not at all (cleanup). "Tick all shown" is hidden
on this page, so startup programs and apps are only ever ticked one by one.

Apply counts exactly the ticked, visible cards, and its dialog lists them per area, offers the
restore point under the same rules as the tweak pages, and keeps Apply off until the user ticks
that they understand the analysis is automatic and the decision is theirs (Enter and Esc cancel).
`Invoke-PcRecommendations` then runs only those ids, area by area: restore point (failing stops
everything, with the same offer to turn System Protection on), tweaks through the engine, cleanup,
app removal (through `Remove-PcAppxPackage`, which refuses to run under the test redirect), and
startup entries turned off the way Task Manager does. One area failing doesn't stop the others;
the cards that went through are marked Done in place.

## New-version notice

PitCrew never goes online on its own, so the first time the window opens (once it is up and the
first page has loaded) it asks whether it may check for new versions. No is the default answer, and
the About page changes it later. The answer is kept in `HKCU\Software\PitCrew` as `UpdateCheck`
(`on` or `off`).

With `on`, at most once a calendar day, `Get-PcReleaseList` asks GitHub for the public list of
releases. The day is saved (`UpdateCheckedOn`) before the request goes out, so a failed one also
waits for the next day. The request goes to `api.github.com/repos/jothank/pitcrew/releases`, with
no sign-in and the user agent `PitCrew`. It runs in its own runspace, apart from `Start-PcJob`, so it never holds up a page or the closing of
the window; the dispatcher timer collects it. `/releases/latest` isn't used because it leaves out
prereleases, and every PitCrew release so far is one.

`Find-PcNewerRelease` only accepts a JSON list of releases; anything else (an empty page from a
proxy, an error object) is an error, never "up to date". It skips drafts and keeps tags that are
plain versions (`v1.2.3` or `v1.2.3-beta.4`, ASCII only), compares them in Semantic Versioning order
and returns the newest one above the running version. Someone on a release only hears about
releases; someone on a beta hears about betas too. That tag is saved as `UpdateLatest` (empty when
there is none), so the notice stays up between checks. The notice is a bar at the top of the
window, linking to the release page. `Select-PcNewerRelease` builds that link from
`$PcLinks.Repository` and the checked tag; no address from GitHub's answer is ever opened. Nothing
is downloaded or installed: updating is the same as installing (download the zip, run
`Install.bat` as administrator).

Failures (offline, a proxy, GitHub's limit of 60 anonymous requests an hour) are only logged. "Check
now" on the About page runs the same check whenever it is clicked and shows its result there.

## Launcher and release

`PitCrew.exe` exists so people who never opened PowerShell can start PitCrew with a double click.
It holds no PitCrew logic and no embedded script (tools that pack a script into an exe are often
flagged by antivirus). It:

1. checks that `PitCrew.ps1` and `src\` are next to it, and otherwise says to extract the zip
   first (double-clicking an exe inside a zip runs it alone from a temp folder);
2. relaunches itself through UAC with `--elevated`, so the prompt names PitCrew and shows its icon;
   if the answer is No (error 1223), it opens PitCrew read-only; any other failure is shown first;
3. starts `PitCrew.ps1 -NoElevate` with the full path of the 64-bit Windows PowerShell (through
   `Sysnative` if the launcher itself runs 32-bit), with no console window and System32 as the
   working folder. Only `-Language <tag>` and `-NoRestorePoint` are passed on;
4. waits up to 15 seconds: if PowerShell exits with code 1 (an error before PitCrew could show
   one, such as a Group Policy that blocks scripts), it says so. `PitCrew.ps1` exits with 2 when it
   already showed its own error. The compiler stamps the build time, so two builds of the same
   source never match byte for byte.

`PitCrew.ps1` itself hands over to the 64-bit PowerShell when it was started by a 32-bit one (a
32-bit program opening `PitCrew.bat`), since a 32-bit PowerShell writes machine settings into
`WOW6432Node`, where they do nothing.

`--dry-run` walks through the same steps but prints each program it would start instead of
starting it; with it, `--simulate-refusal` answers No to the UAC prompt and `--simulate-not-admin`
covers the prompt when the tests run as administrator. Where Smart App Control (or another App
Control policy) refuses to run the freshly compiled, unsigned exe, those tests are reported as
skipped; run them in Windows Sandbox. `PitCrew.bat` is the fallback for users in that situation:
Windows PowerShell scripts still run there.

`tools\Build-Release.ps1` runs the tests, compiles the launcher with the .NET Framework's own
`csc.exe` (icon, manifest and version from `$script:PcVersion`), and builds the zip with
`git archive` from the last commit; it refuses to run with uncommitted changes. `-Dev` builds
`PitCrew-<version>-dev.zip` from them instead, through a throwaway index, for testing only.
Everything sits in a `PitCrew\` folder inside the zip, so "Extract here" never drops `PitCrew.exe`
straight into Downloads, where a planted DLL or `PitCrew.exe.config` could be waiting. Every entry
is checked against a list of what may ship (no stray binaries, keys or archives, nothing twice),
and the SHA-256 is written next to the zip.

Official releases are built by `.github/workflows/build.yml` on a GitHub-hosted runner (0.1.0-beta
was still built locally; 0.1.1-beta to 0.1.4-beta were built there but are unsigned, since SignPath
had not approved the project yet). Signing needs that too, since
SignPath Foundation only signs what a CI built from the public source. For a version tag, the
workflow builds `PitCrew.exe` (`-ExeOnly`), sends only that file to SignPath, and builds the zip
around the copy that comes back (`-ExeFile <signed exe> -RequireSignature`). Signing touches no other
file, so the scripts stay readable and unchanged. Before zipping, the script checks that the exe has
a valid, timestamped signature, the product name PitCrew and this version. The signed zip ends up in
a draft release, to be checked and published by hand. Setup and the release steps are in
[SIGNING.md](SIGNING.md).

The window sets its own AppUserModelID before it is created, so the taskbar shows it as PitCrew
with its icon instead of grouping it with other PowerShell windows. Links in the window open only
`http`/`https` addresses; as administrator they go through `explorer.exe`, which hands them to the
desktop's shell, so the browser doesn't start as administrator too.

## Installer

`Install.bat` runs `src\Setup.ps1 -Install` with the 64-bit Windows PowerShell (through `Sysnative`
when a 32-bit program opened it, or it would install into Program Files (x86)). Setup.ps1:

1. asks first (showing the installed version when it replaces one), then starts itself again
   through UAC with `-Confirmed`. Program Files is used because PitCrew runs as administrator: its
   scripts, in a folder any program can write to, could be changed to run something else elevated;
2. refuses while a PitCrew window is open: the window holds the mutex `Global\PitCrew.Window`
   (`$script:PcWindowMutexName`), and replacing the files under it would leave it loading a mix of
   versions into its background jobs. It also refuses while another setup holds
   `Global\PitCrew.Setup`, since each one clears the other's work folders. It works from System32,
   whatever folder it was started in, so it never holds the program folder itself;
3. checks the zip folder is complete (every item but `PitCrew.exe`, plus key files), then copies
   the program files (not `tests\`, `tools\` or `Install.bat`) byte by byte into
   `<Program Files>\PitCrew.new`, so the zip's "downloaded from the internet" mark doesn't come
   along. A junction or symlink met on the way stops the copy (OneDrive's synced files are reparse
   points too, but not links, so they are copied). A failed copy changes nothing;
4. renames the old copy to `PitCrew.old` and the new one into place. A folder can't be renamed
   while anything holds a file in it, so a copy in use stops the update with nothing changed; if
   the second rename fails, the old copy is put back;
5. puts a `PitCrew.lnk` on the public desktop and in the all-users Start menu. It opens
   `PitCrew.bat` minimized, from System32 (a process started in the program folder would hold it),
   so there is no unsigned exe for Smart App Control to block, and the installed files carry no
   download mark. (With Smart App Control on, a `.bat` that still has the mark is blocked when File
   Explorer opens it with a double click; started with Run as administrator it is not, which is
   why the README says to start `Install.bat` that way.) It carries the window's
   AppUserModelID (`$script:PcAppId`), so the taskbar can treat the shortcut and the window as one
   app;
6. registers `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PitCrew`, whose command runs
   the installed `src\Setup.ps1 -Uninstall`.

Removal also refuses while a window is open. It first renames the program folder to `PitCrew.old`:
if something holds a file in it, that fails and nothing has changed. Then it deletes the shortcuts
that open this copy, the renamed folder (a link inside it is removed as a link, never followed) and
the Settings entry. A leftover `PitCrew.old` is taken by the next install or removal.
`%ProgramData%\PitCrew`, with the undo journal and logs, stays. Setup.ps1 loads only `Context.ps1`
and `I18n.ps1` and doesn't log: as administrator, logs go to that data folder, which only PitCrew
itself sets up. When the UAC prompt is answered No, it says nothing was changed; a failure of the
elevated copy before it can show anything (exit code other than 0 or 2 within 15 seconds) is
reported by the first one.

Tests pass `-InstallDir`, `-DesktopDir` and `-StartMenuDir` (inside the temp folder) and
`-UninstallKey` (under `HKCU:\Software\PitCrewTest\`) together, and `-WindowMutex` to stand in for
an open window; anything else and nothing runs. On a GitHub-hosted runner, which is administrator
without UAC, `tests\Setup-Tests.ps1` also installs with `Install.bat` and removes with the saved
command, for real. Once `PitCrew.exe` is signed, the shortcuts could open it instead of
`PitCrew.bat`, so the UAC prompt would name PitCrew rather than Windows PowerShell.

## Encoding

Windows PowerShell 5.1 reads `.ps1` files without a BOM as ANSI, so every `.ps1` is saved as
UTF-8 **with** BOM (a test enforces it). JSON files are UTF-8 without BOM and are always read with
`-Encoding UTF8`.

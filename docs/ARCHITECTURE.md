# Architecture

PitCrew is plain PowerShell 5.1 (ships with every Windows 10/11) plus a WPF window. No build step,
no binaries, nothing downloaded at run time.

```
PitCrew.bat / PitCrew.ps1   entry point: window by default, -List / -Apply / -Undo for scripts
PitCrew.exe                 (release zip only) double-click launcher built from tools/launcher/PitCrew.cs
src/Load.ps1                dot-sources every file below, in order (a future single-file build = concat)
src/Core/Context.ps1        version and links, shared state ($Pc), admin and user checks, logging, JSON helpers
src/Core/I18n.ps1           locales/<lang>.json, English fallback, per-tweak localized texts
src/Core/Registry.ps1       registry reads/writes, type-exact comparison, test redirect
src/Core/Tweaks.ps1         declarative tweak engine and the undo journal
src/Core/RestorePoint.ps1   verified restore point creation
src/Modules/*.ps1           drivers, cleanup, maintenance, memory, apps, startup: task-style features that aren't simple settings
src/UI/Window.xaml|.ps1     the window and PitCrew's own dialogs; slow work runs in a background runspace
src/UI/Theme.xaml           shared styles and the light palette, put into every window and dialog
tweaks/<category>.json      the settings catalog (one file per category)
data/apps.json              removable apps with verified Microsoft Store IDs and safe/caution labels
data/presets.json           presets: lists of tweak ids that are only pre-ticked, never applied directlylocales/<lang>.json         interface texts
assets/pitcrew.ico|.png     the icon (window, taskbar, PitCrew.exe, README), drawn by tools/Build-Icon.ps1
tests/Run-Tests.ps1         dependency-free tests (also runs tests/Startup-Tests.ps1 and Launcher-Tests.ps1)
tests/Launcher-Tests.ps1    builds PitCrew.exe and checks, with --dry-run, what it would start
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

The window sets its own AppUserModelID before it is created, so the taskbar shows it as PitCrew
with its icon instead of grouping it with other PowerShell windows. Links in the window open only
`http`/`https` addresses; as administrator they go through `explorer.exe`, which hands them to the
desktop's shell, so the browser doesn't start as administrator too.

## Encoding

Windows PowerShell 5.1 reads `.ps1` files without a BOM as ANSI, so every `.ps1` is saved as
UTF-8 **with** BOM (a test enforces it). JSON files are UTF-8 without BOM and are always read with
`-Encoding UTF8`.

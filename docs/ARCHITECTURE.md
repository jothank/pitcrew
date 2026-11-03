# Architecture

PitCrew is plain PowerShell 5.1 (ships with every Windows 10/11) plus a WPF window. No build step,
no binaries, nothing downloaded at run time.

```
PitCrew.bat / PitCrew.ps1   entry point: window by default, -List / -Apply / -Undo for scripts
src/Load.ps1                dot-sources every file below, in order (a future single-file build = concat)
src/Core/Context.ps1        shared state ($Pc), admin and user checks, logging, JSON helpers
src/Core/I18n.ps1           locales/<lang>.json, English fallback, per-tweak localized texts
src/Core/Registry.ps1       registry reads/writes, type-exact comparison, test redirect
src/Core/Tweaks.ps1         declarative tweak engine and the undo journal
src/Core/RestorePoint.ps1   verified restore point creation
src/Modules/*.ps1           drivers, cleanup, maintenance, apps, startup: task-style features that aren't simple settings
src/UI/Window.xaml|.ps1     the window; slow work runs in a background runspace
tweaks/<category>.json      the settings catalog (one file per category)
data/apps.json              removable apps with verified Microsoft Store IDs and safe/caution labels
data/presets.json           presets: lists of tweak ids that are only pre-ticked, never applied directly
locales/<lang>.json         interface texts
tests/Run-Tests.ps1         dependency-free tests (also runs tests/Startup-Tests.ps1)
tests/Smoke-Window.ps1      drives every page's read-only jobs without showing the window
tests/Check-Catalog.ps1     read-only: which catalog targets exist on this PC and their state
tests/Render-Window.ps1     renders a page or the apply dialog to PNG
tools/Start-Sandbox.ps1     run PitCrew inside Windows Sandbox
tools/Build-CatalogDoc.ps1  regenerates docs/CATALOG.md from the catalog
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
GUIDs) always comes from the catalog, and every value read back from the journal is validated
before use. As administrator, PitCrew makes `%ProgramData%\PitCrew` writable only by
Administrators and SYSTEM; a journal found in a folder others could write to is set aside as
`journal.untrusted-*.json` and ignored.

Undo restores that state and deletes created keys that are empty again, **but only where the
current value is still the one PitCrew wrote**. If something else changed it since, that action is
skipped and reported. Applying the same tweak twice keeps the first snapshot. If one action in a
tweak fails, the ones before it are rolled back, so a tweak is never left half applied. Entries
for user-scope tweaks are keyed by the user's SID.

Every apply batch first creates a restore point; if that fails, nothing is changed (the user can
choose to turn on System Protection and retry).

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

## Encoding

Windows PowerShell 5.1 reads `.ps1` files without a BOM as ANSI, so every `.ps1` is saved as
UTF-8 **with** BOM (a test enforces it). JSON files are UTF-8 without BOM and are always read with
`-Encoding UTF8`.

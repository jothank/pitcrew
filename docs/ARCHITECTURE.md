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
src/Modules/*.ps1           drivers, cleanup, apps: task-style features that aren't simple settings
src/UI/Window.xaml|.ps1     the window; slow work runs in a background runspace
tweaks/<category>.json      the settings catalog (one file per category)
data/apps.json              removable apps with verified Microsoft Store IDs
locales/<lang>.json         interface texts
tests/Run-Tests.ps1         dependency-free tests
tools/Start-Sandbox.ps1     run PitCrew inside Windows Sandbox
```

## A tweak

```jsonc
{
  "id": "privacy.advertising-id",
  "risk": "safe",                  // safe | moderate (has side effects) | advanced
  "scope": "machine",              // machine (HKLM, needs admin) | user (HKCU of the signed-in user)
  "reversible": true,
  "reference": "https://learn.microsoft.com/...",   // where the setting is documented
  "appliesTo": { "minBuild": 22000, "editions": ["Professional"] },   // optional
  "requires": { "restart": true },                                    // optional
  "title":       { "en": "...", "pt-BR": "...", "es": "..." },
  "description": { "en": "What it does. What you lose.", "pt-BR": "..." },
  "actions": [
    { "type": "registry", "path": "HKLM:\\SOFTWARE\\Policies\\...", "name": "Value", "kind": "DWord", "value": 1 },
    { "type": "registry", "path": "HKCU:\\Software\\...", "name": "Other", "absent": true }
  ]
}
```

State is computed from the actions: **Applied** (all match), **Not applied**, **Partially applied**,
or **Not available** when `appliesTo` excludes this Windows.

## Undo

Before each action runs, the engine records the previous state in the journal
(`%ProgramData%\PitCrew\journal.json`):

- whether the value existed, its exact type and data;
- which registry keys it had to create.

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

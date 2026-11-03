# PitCrew

**Tune-up for Windows 10 and 11. Every change can be undone.**

[Português](README.pt-BR.md)

PitCrew is a free, open-source maintenance tool for Windows: privacy and performance settings,
disk cleanup, removal of preinstalled apps and driver updates from Windows Update, in one window.

![PitCrew](docs/screenshot.png)

## Principles

- **Only real effects.** Each setting has a documented effect and links to its source, usually
  Microsoft Learn. Popular "tweaks" with no measurable benefit, or that weaken security, are left
  out on purpose: see [docs/NOT-INCLUDED.md](docs/NOT-INCLUDED.md).
- **Everything can be undone.** Before changing a setting, PitCrew records exactly what was there
  (including "this value didn't exist"). Undo puts it back, and leaves alone anything you changed
  yourself afterwards. A restore point is created before every batch of changes.
- **Nothing is preselected.** You see the current state of each item and choose what to change.
- **Plain language.** Each item says what it does and what you lose.
- **No telemetry, no ads, no downloads of unknown code.**

## What it does

| Area | What it does |
|---|---|
| Performance | Power plans (desktops), hibernation and Fast Startup, game recording, mouse acceleration, windowed games, GPU scheduling, background apps and more |
| Privacy | Diagnostic data, telemetry service and tasks, ads and suggestions, Copilot, Recall, Widgets, location, Edge/Firefox/Brave data collection and more |
| Explorer & taskbar | File extensions, classic context menu, taskbar alignment and buttons, End Task, dark mode and more |
| Startup apps | Turn programs that open with Windows on or off, the same way Task Manager does |
| Presets and profiles | "Essentials", "Gaming" and "More privacy" only tick boxes for you to review; export what's applied on one PC and import it on another |
| Cleanup | Temp files, Windows Update downloads, Delivery Optimization cache, error reports, crash dumps, Recycle Bin, with sizes shown first |
| Maintenance | Repair system files (DISM + SFC), remove old update files, disk health report, back up all drivers |
| Built-in apps | Remove or reinstall 30 preinstalled apps, each labelled "safe" or "read before removing" |
| Drivers | Windows Update drivers, with a check that each one is really newer, a backup of the ones replaced, and a link to your motherboard maker |
| Restore points | See existing points, create one now, open System Restore; before applying, PitCrew offers to create one (checked by default) |
| History | Everything PitCrew changed, with Undo |

Every setting with its source is listed in [docs/CATALOG.md](docs/CATALOG.md) (generated from the
code); what comes next is in [docs/TWEAKS.md](docs/TWEAKS.md).

## Running it

Download or clone the repository and double-click **`PitCrew.bat`**. Windows asks for
administrator rights; answer No to open it read-only.

From PowerShell:

```powershell
.\PitCrew.ps1 -List                              # state of every setting, changes nothing
.\PitCrew.ps1 -Apply privacy.advertising-id      # as administrator
.\PitCrew.ps1 -Undo privacy.advertising-id
```

Logs and the undo journal are kept in `%ProgramData%\PitCrew`.

## Languages

English, Português (Brasil), Español, Français, Deutsch, Русский, Türkçe and 简体中文. The interface
follows the Windows language and can be switched in the window.

Translations other than English and Portuguese were machine-generated. Corrections from native
speakers are very welcome: each language is one file in [`locales/`](locales), and setting texts
live next to each setting in [`tweaks/`](tweaks).

## Testing

```powershell
powershell -File tests\Run-Tests.ps1     # no dependencies; touches only a throwaway registry key
powershell -File tools\Start-Sandbox.ps1  # try Apply/Undo for real inside Windows Sandbox
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the engine works and how to add a setting.

## License and credits

MIT. Before writing PitCrew we studied other open-source tools for ideas; what we took from each
and why is in [docs/RESEARCH.md](docs/RESEARCH.md). No code was copied from GPL projects.

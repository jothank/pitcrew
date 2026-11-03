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

## What's in this first version

| Area | What it does |
|---|---|
| Performance | Turn off game recording; stop Store apps running in the background |
| Privacy | Advertising ID, activity history, tailored experiences, feedback requests |
| Cleanup | Temp files (yours and Windows'), Recycle Bin, with sizes shown before deleting |
| Built-in apps | Remove or reinstall a curated list of preinstalled apps, for your user only |
| Drivers | Driver updates from Windows Update, with a check that each one is really newer, and a backup of the drivers being replaced |

The full list being planned is in [docs/TWEAKS.md](docs/TWEAKS.md).

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

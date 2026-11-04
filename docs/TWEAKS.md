# Roadmap

What ships today is listed, generated from the code, in [CATALOG.md](CATALOG.md). This file is
what comes next. 🧩 = needs a new engine action type, 📋 = only content or UI work.

## Settings that need new action types

| Status | Item | Mechanism | Source |
|---|---|---|---|
| 🧩 | Window and menu animations off (slow PCs) | `UserPreferencesMask` bits + `SystemParametersInfo` | Learn (SystemParametersInfo) |
| 🧩 | Reserved Storage off (frees ~7 GB; updates may then fail on a full disk) | `Set-WindowsReservedStorageState` | Learn |
| 🧩 | Network adapter power saving off (desktops) | `Set-NetAdapterPowerManagement` per physical adapter | Learn |
| 🧩 | Remove optional features: PowerShell 2.0, XPS writer, legacy components | `Disable-WindowsOptionalFeature` | Learn |
| 🧩 | Remove Steps Recorder, IE mode, legacy Media Player (needs Windows Update to re-add) | `Remove-WindowsCapability` | Learn |
| 🧩 | Remove "Give access to", "Include in library", "Share" from the context menu | delete whole registry keys | community |
| 📋 | Registry hive backups back on | `Configuration Manager\EnablePeriodicBackup=1` + `RegIdleBackup` task | Microsoft Support |
| 📋 | Storage Sense on, conservative (temp files only, never Downloads) | `StorageSense\Parameters\StoragePolicy` | Learn (Policy CSP Storage) |
| 📋 | No automatic restart while signed in | `WindowsUpdate\AU\NoAutoRebootWithLoggedOnUsers=1` | Learn |

## Apps

| Status | Item |
|---|---|
| 📋 | Picker for every removable installed app (filter: not NonRemovable, not framework, not system-signed) |
| 📋 | Also remove for new users (provisioned packages), as an advanced option |
| 📋 | OneDrive uninstall, off by default |
| 📋 | More apps once their Store IDs are verified: Solitaire, Maps, Tips, Bing Sports/Finance, OneNote, Dev Home |

## Window and workflow

| Status | Item |
|---|---|
| ✅ | Startup apps manager (`Explorer\StartupApproved`, the same switch Task Manager uses) |
| ✅ | Search and "hide not available" filter in long lists |
| ✅ | Presets (Essentials, Gaming, More privacy) that only pre-tick items; nothing applies without a click |
| ✅ | Export/import your choices as a profile file |
| ✅ | Light and dark themes following Windows, PitCrew's own dialogs |
| ✅ | Status filter (applied, not applied, installed...), tick all shown, ticked count |
| ✅ | Memory page and more maintenance (optimize drives, read-only disk check, DNS cache) |
| 📋 | Pre-flight checks before applying: pending restart, third-party antivirus, BitLocker state, settings locked by policy |
| 📋 | Update installed programs with `winget upgrade` (needs structured output, not the localized table) |

## Security follow-ups (from the second review)

| Status | Item |
|---|---|
| 📋 | Journal a "pending" record with the before-state *before* each step, so a kill during `sc.exe`/`powercfg` itself also leaves an Undo |
| 📋 | At an elevated start, warn if PitCrew's own folder (`src`, `tweaks`) is writable by standard users |

## Release

| Status | Item |
|---|---|
| ✅ | `PitCrew.exe` launcher, icon, release zip with SHA-256 (`tools/Build-Release.ps1`) |
| 📋 | Signed release, so SmartScreen and Smart App Control don't block it |
| 📋 | Build releases in GitHub Actions with artifact attestations, so anyone can check a zip came from a given commit |
| 📋 | Start menu shortcut, and a taskbar pin that opens PitCrew (the window's relaunch command) |
| 📋 | "Check for a new version" on the About page (a link to Releases, nothing downloaded) |

## Later

| Status | Item |
|---|---|
| 📋 | Clean-install answer file generator (see [RESEARCH.md](RESEARCH.md)) |
| 📋 | Single-file build |

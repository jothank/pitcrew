# Research: other open-source tools

Before building PitCrew we read the source of four projects (nothing was run). This file records
what we took, what we didn't, and the license constraints. Registry paths and values are facts and
were re-verified against Microsoft documentation before use; no code or text was copied.

| Project | License | Status (Nov 2026) | What we took |
|---|---|---|---|
| [hellzerg/optimizer](https://github.com/hellzerg/optimizer) | GPL-3.0 | Archived; replaced by OptimizerNXT | Ideas only (see below) |
| [GustavoReset/ResetExplode](https://github.com/GustavoReset/ResetExplode) | MIT (bundled vendor drivers excluded) | Active, new | Ideas and UX patterns |
| [raphael-c-martins/Otimizador-Windows-10-11](https://github.com/raphael-c-martins/Otimizador-Windows-10-11) | MIT | Active, small | Ideas and safety patterns |
| [XerifeTech-code/Gerador-autounattend](https://github.com/XerifeTech-code/Gerador-autounattend) | None (all rights reserved); content derived from Winhance (PolyForm Shield) | New | Nothing; only the idea of an answer-file generator |

## hellzerg/optimizer (C#, GPL-3.0)

Because it is GPL-3.0, PitCrew (MIT) must not copy its code, its `.reg`/`.bat` scripts or its
translation strings. Ideas and registry facts are fine once verified on Microsoft Learn.

- **Candidates for our catalog:** the documented privacy policies (diagnostic data level, CEIP,
  advertising ID, activity history, cloud content, web search in Start, input personalization,
  settings sync, Windows AI), Game DVR, long paths, hibernation, and Edge/Firefox/Visual Studio
  telemetry policies.
- **UX ideas:** profiles that can be exported and imported (their "silent mode" template), a cleanup
  preview with sizes, a hosts-file editor with backup, a DNS switcher.
- **Lesson:** its "undo" writes hard-coded defaults instead of what was there before, and several
  are wrong (Spooler, crash dumps). That is exactly what our snapshot journal avoids.
- **Left out:** Defender/SmartScreen/Update/System Restore off, HPET, core parking, svchost split,
  NetworkThrottlingIndex and friends. See [NOT-INCLUDED.md](NOT-INCLUDED.md).

## GustavoReset/ResetExplode (C# WPF, MIT)

Mostly a hardware diagnostics and benchmark suite; only six Windows tweaks, all clean.

- **Engine lessons that match ours:** record "value was absent" explicitly; back up only on the
  first change.
- **Worth adding:** the startup manager using `Explorer\StartupApproved` (the same mechanism as Task
  Manager, so it's reversible), a read-only disk health (S.M.A.R.T.) report, a High Performance
  power plan that recreates the plan from its template when missing, the windowed-games flip-model
  setting (`DirectXUserGlobalSettings`, keeping the other options in that string), mouse
  acceleration off applied live.
- **UX:** an honest "effect" line on every tweak (it says when something won't raise FPS), a
  "needs restart" badge, signature and publisher checks before running any downloaded installer.
- **Left out:** standby-list purge and working-set trimming ("RAM cleaners").

## raphael-c-martins/Otimizador-Windows-10-11 (PowerShell + WPF, MIT)

Architecturally close to PitCrew (JSON catalog, undo journal, dry run, presets).

- **Worth adding:** laptop detection before power-plan/hibernation changes, the Game Bar protocol
  fix for when Game Bar is removed, path-safe temp cleaning, an app list with safe/caution labels
  (matched by exact package name, not wildcards), the telemetry scheduled-tasks list.
- **Left out:** SysMain/WSearch off, Edge force-uninstall, broad wildcard app removal, and the
  `irm | iex` bootstrap that runs an unsigned download elevated.

## XerifeTech-code/Gerador-autounattend (Go, no license)

Generates `autounattend.xml` through a local web UI. No license, content derived from Winhance
(PolyForm Shield), only prebuilt `.exe` files that can't be rebuilt from the published source, and
risky defaults (UAC prompt off, automatic device encryption blocked, lock screen disabled,
automatic maintenance off, feature updates deferred a year). Nothing reused.

## Round 2: WinUtil, Win11Debloat, Sophia Script (Nov 2026)

| Project | License | What we took |
|---|---|---|
| [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil) | MIT | Restore point runs first and is offered before any change; Minimal/Standard/Advanced presets (as an idea: presets may only pre-tick); confirmation before risky actions |
| [Raphire/Win11Debloat](https://github.com/Raphire/Win11Debloat) | MIT | Restore point checkbox checked by default; an overview of pending changes before applying; per-feature build limits; safe/optional/unsafe app labels; registry backup before each run |
| [farag2/Sophia-Script-for-Windows](https://github.com/farag2/Sophia-Script-for-Windows) | MIT (bundled cursor pack and HEVC package excluded) | The most careful restore point code (frequency limit lifted only for the call); the app filter that hides system, framework and non-removable packages; the list of apps never to offer (Store, Terminal, codecs, GPU/audio control panels) |

Candidates added to the catalog from this round (verified one by one before shipping): Copilot
and Widgets off through their documented policies, Settings and Start ads, location through the
same switch Settings uses, Find My Device, automatic sign-in after updates, device companion app
auto-install, Notepad and Paint AI, Brave extras, transparency, Multiplane Overlay
(troubleshooting only), Delivery Optimization peer sharing, and an "Explorer & taskbar" category
(file extensions, classic context menu, taskbar alignment and buttons, Sticky Keys shortcut,
End Task, seconds on the clock, dark mode).

**Restore point lessons:** say when a recent point already exists; lift the 24-hour limit only for
the call and put back the previous value; never delete an administrator's `DisableSR` policy,
just explain it; ask before turning System Protection on.

**Left out from this round** (details in [NOT-INCLUDED.md](NOT-INCLUDED.md)): decrypting BitLocker,
force-removing Windows AI packages, denying ACLs on Store files or vendor folders, `/ResetBase`,
bypassing the UCPD driver with a renamed `powershell.exe`, IPv6 off, service and visual-effects
bundles, WPBT off, Defender sample submission off, and hard-coded "defaults" as undo.

**Idea kept for later:** a small clean-install answer-file generator that writes PitCrew's own
catalog into the setup (locale, local account, privacy defaults, app removal), with
[schneegans/unattend-generator](https://github.com/cschneegans/unattend-generator) (MIT) as the
reference.

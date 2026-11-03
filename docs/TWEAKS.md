# Catalog: shipped and proposed

**Status:** ✅ shipped and tested · 📋 proposed, source to verify before adding · 🧩 needs a new
engine action type. Sources marked "Learn" are Microsoft Learn pages; "community" means widely used
and observable but not documented by Microsoft (the tweak text must say so).

## Performance

| Status | Setting | Mechanism | Source | Risk |
|---|---|---|---|---|
| ✅ | Turn off Windows game recording | Policy `GameDVR\AllowGameDVR=0` | Learn (Policy CSP) | safe |
| ✅ | Stop Store apps running in background | Policy `AppPrivacy\LetAppsRunInBackground=2` | Learn | moderate |
| 📋 | Game Bar background capture off (per user, without the policy) | `GameDVR\AppCaptureEnabled=0`, `GameConfigStore\GameDVR_Enabled=0` | community | safe |
| 🧩 | High / Ultimate Performance power plan (desktops only) | `powercfg`; record previous active plan | Learn (powercfg) | moderate |
| 🧩 | Hibernation off (desktops only), frees `hiberfil.sys` | `powercfg /hibernate off`; undo `on` | Learn (powercfg) | safe |
| 📋 | Fast Startup off (fixes stuck drivers, dual boot) | `Session Manager\Power\HiberbootEnabled=0` | Learn | safe |
| 🧩 | Mouse acceleration off (applied live) | `Control Panel\Mouse` + `SPI_SETMOUSE` | Learn (SystemParametersInfo) | safe |
| 🧩 | Optimizations for windowed games (flip model) | `DirectX\UserGpuPreferences\DirectXUserGlobalSettings` sub-key `SwapEffectUpgradeEnable=1` | community | safe |
| 📋 | Hardware-accelerated GPU scheduling | `GraphicsDrivers\HwSchMode=2`, restart | Learn (DirectX blog) | moderate |
| 📋 | Long paths | `FileSystem\LongPathsEnabled=1` | Learn | safe |
| 🧩 | Startup apps manager | `Explorer\StartupApproved\*` (same as Task Manager) | community | safe |

## Privacy

| Status | Setting | Mechanism | Source | Risk |
|---|---|---|---|---|
| ✅ | Advertising ID off | Policy `AdvertisingInfo\DisabledByGroupPolicy=1` | Learn | safe |
| ✅ | Activity history off | Policy `System\EnableActivityFeed/PublishUserActivities/UploadUserActivities=0` | Learn | safe |
| ✅ | No tailored experiences | User policy `CloudContent\DisableTailoredExperiencesWithDiagnosticData=1` | Learn | safe |
| ✅ | No feedback requests | Policy `DataCollection\DoNotShowFeedbackNotifications=1` | Learn | safe |
| 📋 | Diagnostic data to the minimum the edition allows | Policy `AllowTelemetry`: 1 on Home/Pro (0 is ignored there), 0 on Enterprise/Education | Learn | safe |
| 🧩 | Telemetry service off | `DiagTrack` start type Disabled | Learn | moderate (Feedback Hub stops working) |
| 🧩 | Telemetry scheduled tasks off | Compatibility Appraiser, ProgramDataUpdater, CEIP Consolidator, UsbCeip | Learn | moderate |
| 📋 | Ads and suggestions in Start, Settings and lock screen | `ContentDeliveryManager\SubscribedContent-*`, `SystemPaneSuggestionsEnabled`, `SilentInstalledAppsEnabled` | community | safe |
| 📋 | Web results in Start search off | User policy `Explorer\DisableSearchBoxSuggestions=1` | Learn (ADMX) | safe |
| 📋 | Typing and inking personalization off | Policy `InputPersonalization\AllowInputPersonalization=0` | Learn | safe |
| 📋 | Cloud clipboard off | Policy `System\AllowCrossDeviceClipboard=0` | Learn | safe |
| 📋 | Recall and Click to Do off (Copilot+ PCs, 24H2+) | Policy `WindowsAI\DisableAIDataAnalysis=1`, `AllowRecallEnablement=0` | Learn | safe |
| 📋 | Edge: telemetry, shopping, sidebar, startup boost | Edge policies | Learn (Edge policies) | safe ("managed by your organization" appears in Edge) |
| 📋 | Firefox / Visual Studio telemetry | Their documented policies | vendor docs | safe |

## Cleanup and maintenance

| Status | Item | Notes |
|---|---|---|
| ✅ | Temp files (user and Windows), Recycle Bin | Sizes first; files younger than 24 h kept |
| 📋 | Windows Update download cache | Skip while an update is pending |
| 📋 | Delivery Optimization cache | `Delete-DeliveryOptimizationCache` |
| 📋 | Component store cleanup | `DISM /StartComponentCleanup`, never `/ResetBase` by default |
| 📋 | Repair system files | `sfc /scannow` + `DISM /RestoreHealth`, in background with progress |
| 📋 | Error reports and minidumps | WER ReportArchive/ReportQueue, `Minidump` |
| 📋 | Disk health report (read-only) | S.M.A.R.T. via `MSFT_PhysicalDisk` / reliability counters |
| 📋 | Update installed programs | `winget upgrade`, user picks which |

## Built-in apps

| Status | Item | Notes |
|---|---|---|
| ✅ | 10 apps with verified Store IDs, current user | Remove and reinstall |
| 📋 | Larger list with safe/caution labels | Xbox apps (caution: Game Pass), Teams (personal), Solitaire, Maps, Sound Recorder... exact package names only |
| 📋 | Also remove for new users (provisioned) | Advanced |
| 📋 | OneDrive uninstall | Moderate, off by default |

## Drivers

| Status | Item | Notes |
|---|---|---|
| ✅ | Windows Update drivers with "really newer?" check and pnputil backup | |
| 📋 | Export all third-party drivers (backup before formatting) | `pnputil /export-driver *` |
| 📋 | Link to the motherboard/laptop maker's support page | From `Win32_BaseBoard` / `Win32_ComputerSystem` |

## Interface and later modules

| Status | Item |
|---|---|
| 📋 | Presets (Basic, Gamer, Privacy) that only pre-tick items; nothing applies without a click |
| 📋 | Export/import your choices as a profile file |
| 📋 | Dark theme following Windows |
| 📋 | "Explorer" category: file extensions visible, classic context menu, taskbar buttons |
| 📋 | Clean-install answer file generator (see [RESEARCH.md](RESEARCH.md)) |
| 📋 | Single-file build and a signed release |
| 📋 | **Before the first public release:** protect `%ProgramData%\PitCrew` with an ACL (SYSTEM and Administrators full control, Users read) and ignore a journal not owned by them. Undo already takes paths from the catalog, not the journal |

# Not included, on purpose

Many popular "optimizers" ship the settings below. PitCrew doesn't, because they have no
measurable benefit on current Windows, weaken security, or can't be undone cleanly. If you have
evidence that one of them helps on Windows 10/11 today, open an issue with measurements.

## Security and updates

| Setting | Why it's out |
|---|---|
| Turn off Microsoft Defender (`DisableAntiSpyware`, real-time protection policies, Tamper Protection) | Leaves the PC unprotected. `DisableAntiSpyware` has been ignored by Defender since 2020 anyway. |
| Turn off SmartScreen | Removes the warning before running downloaded malware. |
| Turn off or "pause forever" Windows Update | Security fixes stop arriving. Many scripts also mislabel `AUOptions`/`NoAutoUpdate` values. |
| UAC without prompt (`ConsentPromptBehaviorAdmin=0`, `PromptOnSecureDesktop=0`) | Any program can silently gain admin rights. |
| Turn off System Restore / VSS | Removes the safety net PitCrew itself relies on. |
| Block telemetry by denying ACLs on `ETLLogs\AutoLogger` or with IFEO "debugger" tricks on `CompatTelRunner.exe` | Hard to undo and known to break servicing. The documented policies do the job. |
| Windows 11 hardware-requirement bypass (`LabConfig`, `MoSetup`) | Unsupported by Microsoft; such PCs may stop receiving updates. |
| Force-uninstall Microsoft Edge | Unsupported, breaks apps that use WebView2, and can't be undone reliably. |

## Performance folklore

| Setting | Why it's out |
|---|---|
| `NetworkThrottlingIndex = 0xFFFFFFFF` | Throttles network *processing* only while multimedia plays; no effect on game latency or download speed on modern hardware. |
| `SystemResponsiveness`, MMCSS `Tasks\Games` priorities (`GPU Priority`, `Priority`, `Scheduling Category`, `SFIO Priority`) | No measured effect in games; MMCSS only applies to apps that register with it. |
| `Win32PrioritySeparation` | Changes quantum length for foreground apps; benchmarks show noise-level differences. |
| TCP "boosts" (`TcpAckFrequency`, `TCPNoDelay`, autotuning off) | Can increase or decrease latency depending on the game's own socket options; autotuning off lowers throughput. |
| Turn off SysMain (Superfetch) / Prefetcher | Neutral on SSDs, slower app starts on HDDs. |
| Turn off Windows Search (`WSearch`) | Breaks Start, Settings and File Explorer search. |
| "RAM cleaners": `EmptyWorkingSet` on all processes, purging the standby list | Windows already reclaims standby memory on demand; trimming just causes page faults and stutter. |
| Disable HPET / `bcdedit useplatformclock` / `disabledynamictick` | `useplatformclock` isn't set by default, so deleting it does nothing; the others are undocumented as performance fixes. |
| "Unlock all cores" (core parking registry edits) | Only unhides a power plan option; Windows 11 parks cores dynamically. |
| `SvcHostSplitThresholdInKB` | Trades memory for fewer service processes; no speed gain. |
| `MenuShowDelay=0`, `MouseHoverTime=0`, very short `HungAppTimeout` / `WaitToKillServiceTimeout` | Cosmetic at best; short kill timeouts can lose unsaved data. |
| Turn off Auto Game Mode | Game Mode is on by default and is not a known cause of problems. |

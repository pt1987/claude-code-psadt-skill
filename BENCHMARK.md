# Ten applications, measured end to end

A run of 2026-09-18 that packaged ten applications with this skill and timed every
phase, from the first research call to the finished output files. The applications were packaged **one
after another**, never in parallel, so the numbers stay comparable. Inside one application phase 6 runs
alongside phases 7 and 8, which is what the skill prescribes: packaging and the dossier do not need the
test verdict.

| Condition | Value |
|---|---|
| Host | Windows 11 Enterprise 26200 |
| Skill version | 0.35.0 |
| PSAppDeployToolkit | 4.1.8 |
| Phase 6 depth | full gate |
| Intune upload | no, `decisions.upload = false` in every manifest |
| Execution | strictly serial, one application at a time |

## Results

| # | Application | Version | Engine | Class | P1 | P2 | P2D | P3 | P4 | P5 | P6 | P7 | P8 | End to end | Gate runs | Verdict |
|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | 7-Zip | 26.03 | MSI | simple / small | 0.13 s | 3:18 min | 0.49 s | 15.8 s | 2:18 min | 0.50 s | 3:35 min | 6.2 s | 2:19 min | 10:28 min | 1 | GREEN |
| 2 | Notepad++ | 8.9.8 | MSI (vendor) | simple / small | 16.9 s | 4:02 min | 0.44 s | 9.8 s | 58.5 s | 0.30 s | 3:30 min | 7.2 s | 38.0 s | 9:32 min | 1 | GREEN |
| 3 | PuTTY | 0.85 | MSI | simple / small | 11.9 s | 4:26 min | 0.35 s | 9.9 s | 30.4 s | 0.30 s | 3:22 min | 6.8 s | 16.7 s | 9:11 min | 1 | GREEN |
| 4 | VLC media player | 3.0.23 | MSI (vendor) | medium / medium | 22.0 s | 6:50 min | 2.8 s | 15.5 s | 1:25 min | 0.58 s | 6:09 min | 29.6 s | 36.8 s | 15:46 min | 1 | GREEN |
| 5 | Git for Windows | 2.55.0.5 | Inno Setup | medium / medium | 12.1 s | 4:11 min | 2.3 s | 27.3 s | 1:30 min | 0.96 s | 7:53 min | 17.7 s | 33.6 s | 16:17 min | 1 | GREEN |
| 6 | Google Chrome Enterprise | 153.0.8010.53 | MSI | medium / medium | 15.4 s | 5:11 min | 5.4 s | 34.9 s | 20.3 s | 0.91 s | 6:45 min | 27.2 s | 30.2 s | 13:44 min | 1 | GREEN |
| 7 | Eclipse Temurin JDK 21 | 21.0.12.101 | MSI (ADDLOCAL) | medium / large | 13.1 s | 3:49 min | 5.9 s | 26.7 s | 15.0 s | 0.71 s | 6:50 min | 48.7 s | 2:38 min | 12:19 min | 1 | GREEN |
| 8 | GIMP | 3.2.6 | Inno Setup | hard / large | 10.4 s | 6:58 min | 8.8 s | 33.7 s | 30.2 s | 0.74 s | 9:16 min | 52.1 s | 34.2 s | 18:56 min | 1 | GREEN |
| 9 | LibreOffice | 26.2.6.3 | MSI (properties) | hard / large | 11.1 s | 6:28 min | 12.2 s | 15.7 s | 17.1 s | 0.82 s | 14:03 min | 55.1 s | 1:09 min | 23:51 min | **2** | GREEN |
| 10 | Citrix Workspace App | 26.7.0.269 | vendor bootstrapper | hard / large | 14.3 s | 7:23 min | 22.2 s | 15.8 s | 34.3 s | 1.1 s | 20:04 min | 1:30 min | 34.1 s | 32:04 min | **2** | GREEN |

10 of 10 applications passed the full sandbox gate, 8 of them on the first
attempt. Median 15:46 min per application, 162:11 min for the whole run.

**Gate runs is the column to read first.** It counts how often phase 6 had to execute. Two runs means
the gate rejected a package and the fix was tested again. The LibreOffice rejection was the serious
one and it is written up in `benchmark/FINDINGS.md`.

### What each phase covers

| ID | Phase | What is measured |
|---|---|---|
| P1 | Intake | Settling identity, architecture and deployment semantics |
| P2 | Research | Evidence ladder, then at most one sub-agent per question it could not close |
| P2D | Installer download | Fetching the setup. Network bound, so reported separately |
| P3 | Scaffold | Generator writes launcher, detection script and manifest |
| P4 | Hooks | Filling install, uninstall and repair, plus any extension function |
| P5 | Pre-flight | Invoke-PsadtPreflight, the GREEN gate before anything runs |
| P6 | SYSTEM test | Windows Sandbox, all five scenarios, every action as SYSTEM |
| P7 | Packaging | Invoke-PsadtPackage produces and verifies the .intunewin |
| P8 | Dossier and logo | Logo acquisition and New-PsadtReport |

## How this was measured

- `benchmark/bench.ps1` writes one marker per call, always inside the **same** PowerShell invocation as
  the work it brackets. A separate tool round-trip between marker and work would leak one to two
  seconds of harness latency into every phase boundary.
- `start` sits at the end of the preceding call and `end` at the beginning of the next, so the thinking
  time between two tool calls falls inside the measured window rather than into a gap.
- **End to end** is the first start to the last end of an application. It contains the gaps between
  phases and it subtracts whatever ran in parallel, so it can be lower than the phases added up. Both
  numbers appear per application below.
- A phase can consist of several intervals. P8 is the logo before the sandbox verdict and the dossier
  after it; P6 is two intervals where the gate rejected the first attempt. Intervals are added up, not
  stretched across the wait.
- P1 is honest but not useful. The intake decision falls between two tool calls and measures fractions
  of a second on most applications.
- Application 1 was built twice. The first pass calibrated the harness and lost three markers, so 7-Zip
  was re-measured with fresh research agents. Its research figure is the most optimistic in the table.
- Raw data: `benchmark/bench.jsonl` holds every marker, `benchmark/results/` the package facts and
  sandbox results per application. The `note` fields in the marker file were translated to English
  after the run; timestamps were not touched.

## Per application

### 1. 7-Zip 26.03

Engine: MSI. Class: simple / small. Package content unencrypted: 11.4 MB.

| Phase | Duration | Intervals | Note |
|---|---:|---:|---|
| P1 Intake | 0.13 s | 1 | MSI x64, system context, uninstall keeps user data, reboot never forced |
| P2 Research | 3:18 min | 1 | 2 agents (49s/175s) plus ladder; 7 of 10 questions closed locally |
| P2D Installer download | 0.49 s | 1 | 7z2603-x64.msi |
| P3 Scaffold | 15.8 s | 1 |  |
| P4 Hooks | 2:18 min | 1 | extension Remove-ADTLegacySevenZipExeInstall plus its pre-install call |
| P5 Pre-flight | 0.50 s | 1 | Overall=GREEN |
| P6 SYSTEM test | 3:35 min | 1 | Verdict=GREEN |
| P7 Packaging | 6.2 s | 1 |  |
| P8 Dossier and logo | 2:19 min | 2 | logo: Wikimedia wordmark, vendor ICO only 48px, MSI carries no icon table; squared to 1280x1280 | dossier written |
| **Phases added up** | **11:54 min** | | |
| **End to end** | **10:28 min** | | first start to last end |

Sandbox scenarios: Install, Uninstall, Reinstall, Repair, FinalUninstall. Verdict **GREEN**.

### 2. Notepad++ 8.9.8

Engine: MSI (vendor). Class: simple / small. Package content unencrypted: 16.7 MB.

| Phase | Duration | Intervals | Note |
|---|---:|---:|---|
| P1 Intake | 16.9 s | 1 | engine still open: the corpus reports an official x64 MSI |
| P2 Research | 4:02 min | 1 | 2 agents plus ladder plus MSI feature table; 10 sourced pitfalls |
| P2D Installer download | 0.44 s | 1 | npp.8.9.8.Installer.x64.msi |
| P3 Scaffold | 9.8 s | 1 |  |
| P4 Hooks | 58.5 s | 1 | ADDLOCAL=MainApplication plus Remove-ADTLegacyExeInstall |
| P5 Pre-flight | 0.30 s | 1 | Overall=GREEN |
| P6 SYSTEM test | 3:30 min | 1 | Verdict=GREEN |
| P7 Packaging | 7.2 s | 1 |  |
| P8 Dossier and logo | 38.0 s | 2 | logo from Wikimedia, transparent, squared | dossier written |
| **Phases added up** | **9:44 min** | | |
| **End to end** | **9:32 min** | | first start to last end |

Sandbox scenarios: Install, Uninstall, Reinstall, Repair, FinalUninstall. Verdict **GREEN**.

### 3. PuTTY 0.85

Engine: MSI. Class: simple / small. Package content unencrypted: 12.8 MB.

| Phase | Duration | Intervals | Note |
|---|---:|---:|---|
| P1 Intake | 11.9 s | 1 | MSI x64, system context |
| P2 Research | 4:26 min | 1 | 2 agents plus ladder plus MSI feature and upgrade tables |
| P2D Installer download | 0.35 s | 1 | putty-64bit-0.85-installer.msi |
| P3 Scaffold | 9.9 s | 1 |  |
| P4 Hooks | 30.4 s | 1 | explicit ADDLOCAL with DesktopFeature excluded, plus post-uninstall directory cleanup |
| P5 Pre-flight | 0.30 s | 1 | Overall=GREEN |
| P6 SYSTEM test | 3:22 min | 1 | Verdict=GREEN |
| P7 Packaging | 6.8 s | 1 |  |
| P8 Dossier and logo | 16.7 s | 2 | logo from the file name the corpus already recorded, square and transparent as is | dossier written |
| **Phases added up** | **9:05 min** | | |
| **End to end** | **9:11 min** | | first start to last end |

Sandbox scenarios: Install, Uninstall, Reinstall, Repair, FinalUninstall. Verdict **GREEN**.

### 4. VLC media player 3.0.23

Engine: MSI (vendor). Class: medium / medium. Package content unencrypted: 66.8 MB.

| Phase | Duration | Intervals | Note |
|---|---:|---:|---|
| P1 Intake | 22.0 s | 1 | NSIS expected, x64, system context |
| P2 Research | 6:50 min | 1 | 2 agents plus ladder plus MSI feature hierarchy, parent fetched by direct query |
| P2D Installer download | 2.8 s | 1 | vlc-3.0.23-win64.msi (60.6 MB) |
| P3 Scaffold | 15.5 s | 1 |  |
| P4 Hooks | 1:25 min | 1 | ADDLOCAL without WEBPLUGINS, ACTIVEX and MOZILLA, plus NSIS predecessor cleanup |
| P5 Pre-flight | 0.58 s | 1 | Overall=GREEN |
| P6 SYSTEM test | 6:09 min | 1 | Verdict=GREEN |
| P7 Packaging | 29.6 s | 1 |  |
| P8 Dossier and logo | 36.8 s | 2 | logo from Wikimedia, 1280x1280 transparent | dossier written |
| **Phases added up** | **16:12 min** | | |
| **End to end** | **15:46 min** | | first start to last end |

Sandbox scenarios: Install, Uninstall, Reinstall, Repair, FinalUninstall. Verdict **GREEN**.

### 5. Git for Windows 2.55.0.5

Engine: Inno Setup. Class: medium / medium. Package content unencrypted: 71.4 MB.

| Phase | Duration | Intervals | Note |
|---|---:|---:|---|
| P1 Intake | 12.1 s | 1 | Inno Setup EXE, x64, system context; New-ExePackage needs InstallArgs and VerifyRelativePath |
| P2 Research | 4:11 min | 1 | 2 agents plus engine probe (inno, high); hash verified against the vendor |
| P2D Installer download | 2.3 s | 1 | Git-2.55.0.5-64-bit.exe (65 MB) |
| P3 Scaffold | 27.3 s | 1 |  |
| P4 Hooks | 1:30 min | 1 | RESTARTEXITCODE=3010 declared in both lists; keyboxd and gpg-agent added to CloseProcesses |
| P5 Pre-flight | 0.96 s | 1 | Overall=GREEN |
| P6 SYSTEM test | 7:53 min | 1 | Verdict=GREEN |
| P7 Packaging | 17.7 s | 1 |  |
| P8 Dossier and logo | 33.6 s | 2 | logo from Wikimedia (Git-logo.svg), squared to 1280x1280 transparent | dossier written |
| **Phases added up** | **15:09 min** | | |
| **End to end** | **16:17 min** | | first start to last end |

Sandbox scenarios: Install, Uninstall, Reinstall, Repair, FinalUninstall. Verdict **GREEN**.

### 6. Google Chrome Enterprise 153.0.8010.53

Engine: MSI. Class: medium / medium. Package content unencrypted: 162.3 MB.

| Phase | Duration | Intervals | Note |
|---|---:|---:|---|
| P1 Intake | 15.4 s | 1 | MSI x64 enterprise, system context |
| P2 Research | 5:11 min | 1 | 2 agents plus ladder; version confirmed deterministically from the MSI |
| P2D Installer download | 5.4 s | 1 | GoogleChromeStandaloneEnterprise64.msi (167 MB) |
| P3 Scaffold | 34.9 s | 1 |  |
| P4 Hooks | 20.3 s | 1 | no extra hooks needed; the updater is kept on purpose because other products share it |
| P5 Pre-flight | 0.91 s | 1 | Overall=GREEN |
| P6 SYSTEM test | 6:45 min | 1 | Verdict=GREEN |
| P7 Packaging | 27.2 s | 1 |  |
| P8 Dossier and logo | 30.2 s | 2 | logo from Wikimedia, 1280x1280 transparent | dossier written |
| **Phases added up** | **14:11 min** | | |
| **End to end** | **13:44 min** | | first start to last end |

Sandbox scenarios: Install, Uninstall, Reinstall, Repair, FinalUninstall. Verdict **GREEN**.

### 7. Eclipse Temurin JDK 21 21.0.12.101

Engine: MSI (ADDLOCAL). Class: medium / large. Package content unencrypted: 179.8 MB.

| Phase | Duration | Intervals | Note |
|---|---:|---:|---|
| P1 Intake | 13.1 s | 1 | MSI x64 with ADDLOCAL features, system context; nothing in the corpus |
| P2 Research | 3:49 min | 1 | 2 agents plus ladder plus feature table; SHA256 verified against the vendor |
| P2D Installer download | 5.9 s | 1 | OpenJDK21U MSI (171 MB) |
| P3 Scaffold | 26.7 s | 1 |  |
| P4 Hooks | 15.0 s | 1 | ADDLOCAL with FeatureEnvironment and FeatureJavaHome, without FeatureOracleJavaSoft |
| P5 Pre-flight | 0.71 s | 1 | Overall=GREEN |
| P6 SYSTEM test | 6:50 min | 1 | Verdict=GREEN |
| P7 Packaging | 48.7 s | 1 |  |
| P8 Dossier and logo | 2:38 min | 2 | logo from the MSI icon table (256px, the vendor maximum); no Wikimedia hit | dossier written |
| **Phases added up** | **15:08 min** | | |
| **End to end** | **12:19 min** | | first start to last end |

Sandbox scenarios: Install, Uninstall, Reinstall, Repair, FinalUninstall. Verdict **GREEN**.

### 8. GIMP 3.2.6

Engine: Inno Setup. Class: hard / large. Package content unencrypted: 190.5 MB.

| Phase | Duration | Intervals | Note |
|---|---:|---:|---|
| P1 Intake | 10.4 s | 1 | Inno Setup EXE expected, x64, system context; nothing in the corpus |
| P2 Research | 6:58 min | 1 | 2 agents, one corrected the other, plus engine probe; size matched exactly |
| P2D Installer download | 8.8 s | 1 | gimp-3.2.6-setup.exe (181 MiB) |
| P3 Scaffold | 33.7 s | 1 |  |
| P4 Hooks | 30.2 s | 1 | /ALLUSERS set, 3010 in both lists; no /COMPONENTS, the core components are fixed |
| P5 Pre-flight | 0.74 s | 1 | Overall=GREEN |
| P6 SYSTEM test | 9:16 min | 1 | Verdict=GREEN |
| P7 Packaging | 52.1 s | 1 |  |
| P8 Dossier and logo | 34.2 s | 2 | logo from Wikimedia (GIMP 3.0 icon), 1280x1280 transparent | dossier written |
| **Phases added up** | **19:05 min** | | |
| **End to end** | **18:56 min** | | first start to last end |

Sandbox scenarios: Install, Uninstall, Reinstall, Repair, FinalUninstall. Verdict **GREEN**.

### 9. LibreOffice 26.2.6.3

Engine: MSI (properties). Class: hard / large. Package content unencrypted: 351.7 MB.

| Phase | Duration | Intervals | Note |
|---|---:|---:|---|
| P1 Intake | 11.1 s | 1 | MSI x64 with properties, system context; nothing in the corpus |
| P2 Research | 6:28 min | 1 | 2 agents plus ladder plus the feature table (1680 features) read from the MSI |
| P2D Installer download | 12.2 s | 1 | LibreOffice_26.2.6_Win_x86-64.msi (356 MiB) |
| P3 Scaffold | 15.7 s | 1 |  |
| P4 Hooks | 17.1 s | 2 | no ADDLOCAL=ALL, it would defeat UI_LANGS; online update and quickstarter dropped via REMOVE | fix after the red gate: REMOVE dropped |
| P5 Pre-flight | 0.82 s | 2 | Overall=GREEN | Overall=GREEN |
| P6 SYSTEM test | 14:03 min | 2 | Verdict=RED | Verdict=GREEN (second run) |
| P7 Packaging | 55.1 s | 2 | repackaged after the launcher fix |
| P8 Dossier and logo | 1:09 min | 2 | logo: wordmark first, unusable as a tile, then the LibreOffice main icon at 1280x1280 | dossier written |
| **Phases added up** | **23:33 min** | | |
| **End to end** | **23:51 min** | | first start to last end |

Sandbox scenarios: Install, Uninstall, Reinstall, Repair, FinalUninstall. Verdict **GREEN**.

### 10. Citrix Workspace App 26.7.0.269

Engine: vendor bootstrapper. Class: hard / large. Package content unencrypted: 450.8 MB.

| Phase | Duration | Intervals | Note |
|---|---:|---:|---|
| P1 Intake | 14.3 s | 1 | EXE installer, x64, system context; the corpus knows 40032 and a 30 minute timeout |
| P2 Research | 7:23 min | 1 | 2 agents plus corpus plus probe; engine unknown, no default invented |
| P2D Installer download | 22.2 s | 1 | CitrixWorkspaceApp_x64_26.7.0.269.exe (463 MB) |
| P3 Scaffold | 15.8 s | 1 |  |
| P4 Hooks | 34.3 s | 2 | 40032 and 40037 as success, 3010 and 40026 as reboot, in the launcher AND the harness | path corrected after the red gate: ICA Client\wfica32.exe relative to C:\Program Files\Citrix |
| P5 Pre-flight | 1.1 s | 2 | Overall=GREEN | Overall=GREEN |
| P6 SYSTEM test | 20:04 min | 2 | Verdict=RED | Verdict=GREEN (second run) |
| P7 Packaging | 1:30 min | 2 | repackaged after the detection fix |
| P8 Dossier and logo | 34.1 s | 2 | logo from Wikimedia (Citrix Systems), squared to 1280x1280 | dossier written |
| **Phases added up** | **30:59 min** | | |
| **End to end** | **32:04 min** | | first start to last end |

Sandbox scenarios: Install, Uninstall, Reinstall, Repair, FinalUninstall. Verdict **GREEN**.


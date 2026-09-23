# Five applications, measured end to end

A run of 2026-09-23 that packaged five applications with this skill and timed every
phase, from the first research call to the finished output files. The applications were packaged **one
after another**, never in parallel, so the numbers stay comparable. Inside one application phase 6 runs
alongside phases 7 and 8, which is what the skill prescribes: packaging and the dossier do not need the
test verdict.

| Condition | Value |
|---|---|
| Host | Windows 11 Enterprise 26200 |
| Skill version | 0.46.0 |
| PSAppDeployToolkit | 4.1.8 |
| Phase 6 depth | full gate |
| Intune upload | no, `decisions.upload = false` in every manifest |
| Execution | strictly serial, one application at a time |

## Results

| # | Application | Version | Engine | Class | P1 | P2 | P2D | P3 | P4 | P5 | P6 | P7 | P8 | End to end | Gate runs | Verdict |
|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | 7-Zip | 26.03 | MSI | simple / small | - | 4.1 s | 0.72 s | 15.1 s | 0.07 s | 0.51 s | 3:16 min | 1.3 s | 0.93 s | 3:38 min | 1 | GREEN |
| 2 | Notepad++ | 8.9.8 | MSI (vendor) | simple / small | - | 1.5 s | 0.02 s | 8.1 s | 0.06 s | 0.20 s | 3:27 min | 1.4 s | 0.33 s | 3:39 min | 1 | GREEN |
| 3 | PuTTY | 0.85 | MSI | simple / small | - | 2.4 s | 0.06 s | 12.0 s | 0.07 s | 0.39 s | 3:26 min | 1.8 s | 1.2 s | 3:44 min | 1 | GREEN |
| 4 | VLC media player | 3.0.23 | MSI (vendor) | medium / medium | - | 4.3 s | 0.05 s | 9.7 s | 0.17 s | 0.32 s | 3:54 min | 3.2 s | 0.31 s | 4:13 min | 1 | GREEN |
| 5 | Git for Windows | 2.55.0.5 | Inno Setup | medium / medium | - | 3.9 s | 0.31 s | 14.5 s | 0.30 s | 1.2 s | 16:34 min | 8.3 s | 1.8 s | 22:12 min | **2** | GREEN |

5 of 5 applications passed the full sandbox gate, 4 of them on the first
attempt. Median 3:44 min per application, 37:28 min for the whole run.

**Gate runs is the column to read first.** It counts how often phase 6 had to execute. Two runs means
The package(s) the gate sent back here: Git for Windows. What each rejection was is in `benchmark/FINDINGS.md`.

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
| P2 Research | 4.1 s | 1 | AgentBudget=1 |
| P2D Installer download | 0.72 s | 1 | 2007040 bytes |
| P3 Scaffold | 15.1 s | 1 |  |
| P4 Hooks | 0.07 s | 1 | recorded 2 answer(s) |
| P5 Pre-flight | 0.51 s | 1 | GREEN |
| P6 SYSTEM test | 3:16 min | 1 | GREEN |
| P7 Packaging | 1.3 s | 1 | 11961204 bytes |
| P8 Dossier and logo | 0.93 s | 1 |  |
| **Phases added up** | **3:38 min** | | |
| **End to end** | **3:38 min** | | first start to last end |

Sandbox scenarios: Install, Uninstall, Reinstall, Repair, FinalUninstall. Verdict **GREEN**.

### 2. Notepad++ 8.9.8

Engine: MSI (vendor). Class: simple / small. Package content unencrypted: 16.7 MB.

| Phase | Duration | Intervals | Note |
|---|---:|---:|---|
| P2 Research | 1.5 s | 1 | AgentBudget=1 |
| P2D Installer download | 0.02 s | 1 | 7806976 bytes (local) |
| P3 Scaffold | 8.1 s | 1 |  |
| P4 Hooks | 0.06 s | 1 | recorded 2 answer(s) |
| P5 Pre-flight | 0.20 s | 1 | GREEN |
| P6 SYSTEM test | 3:27 min | 1 | GREEN |
| P7 Packaging | 1.4 s | 1 | 17469496 bytes |
| P8 Dossier and logo | 0.33 s | 1 |  |
| **Phases added up** | **3:39 min** | | |
| **End to end** | **3:39 min** | | first start to last end |

Sandbox scenarios: Install, Uninstall, Reinstall, Repair, FinalUninstall. Verdict **GREEN**.

### 3. PuTTY 0.85

Engine: MSI. Class: simple / small. Package content unencrypted: 12.8 MB.

| Phase | Duration | Intervals | Note |
|---|---:|---:|---|
| P2 Research | 2.4 s | 1 | AgentBudget=1 |
| P2D Installer download | 0.06 s | 1 | 3846144 bytes (local) |
| P3 Scaffold | 12.0 s | 1 |  |
| P4 Hooks | 0.07 s | 1 | recorded 2 answer(s) |
| P5 Pre-flight | 0.39 s | 1 | GREEN |
| P6 SYSTEM test | 3:26 min | 1 | GREEN |
| P7 Packaging | 1.8 s | 1 | 13400341 bytes |
| P8 Dossier and logo | 1.2 s | 1 |  |
| **Phases added up** | **3:44 min** | | |
| **End to end** | **3:44 min** | | first start to last end |

Sandbox scenarios: Install, Uninstall, Reinstall, Repair, FinalUninstall. Verdict **GREEN**.

### 4. VLC media player 3.0.23

Engine: MSI (vendor). Class: medium / medium. Package content unencrypted: 66.8 MB.

| Phase | Duration | Intervals | Note |
|---|---:|---:|---|
| P2 Research | 4.3 s | 1 | AgentBudget=1 |
| P2D Installer download | 0.05 s | 1 | 60608512 bytes (local) |
| P3 Scaffold | 9.7 s | 1 |  |
| P4 Hooks | 0.17 s | 1 | recorded 2 answer(s) |
| P5 Pre-flight | 0.32 s | 1 | GREEN |
| P6 SYSTEM test | 3:54 min | 1 | GREEN |
| P7 Packaging | 3.2 s | 1 | 70025873 bytes |
| P8 Dossier and logo | 0.31 s | 1 |  |
| **Phases added up** | **4:12 min** | | |
| **End to end** | **4:13 min** | | first start to last end |

Sandbox scenarios: Install, Uninstall, Reinstall, Repair, FinalUninstall. Verdict **GREEN**.

### 5. Git for Windows 2.55.0.5

Engine: Inno Setup. Class: medium / medium. Package content unencrypted: 71.4 MB.

| Phase | Duration | Intervals | Note |
|---|---:|---:|---|
| P2 Research | 3.9 s | 2 | AgentBudget=2 | AgentBudget=2 |
| P2D Installer download | 0.31 s | 2 | 65343712 bytes (local) | 65343712 bytes (local) |
| P3 Scaffold | 14.5 s | 2 |  |
| P4 Hooks | 0.30 s | 2 | recorded 3 answer(s) | recorded 3 answer(s) |
| P5 Pre-flight | 1.2 s | 2 | GREEN | GREEN |
| P6 SYSTEM test | 16:34 min | 2 | RED | GREEN |
| P7 Packaging | 8.3 s | 2 | 74881625 bytes | 74881709 bytes |
| P8 Dossier and logo | 1.8 s | 2 |  |
| **Phases added up** | **17:04 min** | | |
| **End to end** | **22:12 min** | | first start to last end |

Sandbox scenarios: Install, Uninstall, Reinstall, Repair, FinalUninstall. Verdict **GREEN**.


---

## Earlier run: ten applications on 0.35.0, 2026-09-18

The numbers above replace a run of **2026-09-18 against skill 0.35.0** that covered ten applications,
including GIMP, LibreOffice, Temurin, Chrome and the Citrix bootstrapper. That run is not reproduced here
and its timings are not comparable: 0.41.0 short-circuited the research ladder, 0.44.0 added a pre-flight
check that can stop a run outright, and 0.46.0 added a host-side check of the sandbox verdict.

What survives from it, and is still worth reading: `benchmark/FINDINGS.md` (six defects the run exposed,
none of them fixed during it, on purpose) and `benchmark/roster.2026-09-18.json` (the ten-application
definition). The per-application records of the five applications NOT re-measured here still sit in
`benchmark/results/` and carry no `skillVersion` field - that absence is how you tell them apart from the
2026-09-23 records, which do.

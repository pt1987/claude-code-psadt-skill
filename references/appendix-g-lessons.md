# Appendix G: Lessons Learned (from real-world incidents)

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Contents

- [2026-04-21/22 - Database package (large installer, ~2 GB, with post-install DB verify)](#2026-04-2122---database-package-large-installer-2-gb-with-post-install-db-verify)
- [2026-06-05 - 7-Zip package (MSI, automated SYSTEM test loop)](#2026-06-05---7-zip-package-msi-automated-system-test-loop)
- [2026-09-05 - Notepad++ package (official MSI, first Windows Sandbox SYSTEM test)](#2026-09-05---notepad-package-official-msi-first-windows-sandbox-system-test)
- [2026-09-05 (same day, second package) - PuTTY 0.85: the lessons above, measured](#2026-09-05-same-day-second-package---putty-085-the-lessons-above-measured)
- [2026-09-08 - BootForge + Windows ADK + WinPE add-on (three packages, one dependency chain)](#2026-09-08---bootforge--windows-adk--winpe-add-on-three-packages-one-dependency-chain)

## Appendix G: Lessons Learned (from real-world incidents)

These lessons come from concrete packaging projects and apply to PSADT v4 Intune deployments in general - not app-specific. Every new incident is added here as a new entry (format: date, symptom, cause, fix, general lesson).

### 2026-04-21/22 - Database package (large installer, ~2 GB, with post-install DB verify)

1. **Em-dash encoding bug**: the script had 74 em-dashes (`—`) as UTF-8 without a BOM. In double-quoted strings PowerShell 5.1 broke during parsing. Exit 1, Intune showed `0x80070001`, no local logs. Fix: all em-dashes to `-`, arrows `→` to `->`, set the UTF-8 BOM.

2. **Transient post-install-check false positive**: a functional check right after `msiexec` finished came up empty - the services registered by the installer were still in `Starting`, the listener/API not yet reachable. The single check returned `NO_OUTPUT` / an empty result, which the script interpreted as "not installed" and triggered a 30-minute drop+recreate fallback action - even though the installation was actually successful. Fix: first wait for the service to be Running (max 3 min), then a check function with a retry loop (6x, 30s apart), and only after that the fallback. **General lesson**: for every post-install check that depends on asynchronously started state (services, listeners, registry keys that a service writes) ALWAYS use a retry loop + service-ready wait, never single-shot. Applies to all installers with service registration (DBs, message queues, search indexers, license daemons, ...).

3. **IME HRESULT mapping trap**: `0x80070001` looks like "ERROR_INVALID_FUNCTION" (Win32 API), but it is `0x80070000 + 1`, i.e. exit 1 from the script. Always do the math.

4. **IntuneManagementExtension.log vs AppWorkload.log**: IntuneManagementExtension.log shows the service state and state-machine definitions ("Adding new state transition..." are just table entries, NOT real transitions). For install diagnosis **AppWorkload.log** is the hit.

5. **The acid test is `Invoke-AppDeployToolkit.exe`, not `.ps1` directly**. The launcher exe uses `powershell.exe -Command "try { & 'script.ps1' ... } catch { throw }; exit $Global:LASTEXITCODE"` - a different encoding path than `.\script.ps1`. Encoding bugs only show up here.

6. **Avoid a wrong param-block diagnosis**: at one point I changed `$SuppressRebootPassThru` to `$AllowRebootPassThru` - v3 thinking applied to a v4 script. The launcher does NOT automatically pass reboot switches; the parameter name in v4.x is `$SuppressRebootPassThru`. The reference is ALWAYS the template under `<pkg>\PSAppDeployToolkit\Frontend\v4\Invoke-AppDeployToolkit.ps1`.

### 2026-06-05 - 7-Zip package (MSI, automated SYSTEM test loop)

1. **SYSTEM test loop dies under PowerShell 7 - `New-ScheduledJobOption` / PSScheduledJob cannot load**: running `Invoke-PsadtSystemTest.ps1` (which calls `Invoke-CommandAs -AsSystem`) from **pwsh 7** failed on every action with `The 'New-ScheduledJobOption' command was found in the module 'PSScheduledJob', but the module could not be loaded`. The launcher never actually ran as SYSTEM, so every step came back `ExitCode=0 Success=False Detection=not-installed` (deceptive: exit 0 but nothing happened). **Cause**: `Invoke-CommandAs -AsSystem` schedules its work via the **`PSScheduledJob`** module (`New-ScheduledJobOption`, `Register-ScheduledJob`). `PSScheduledJob` is a **Windows PowerShell 5.1-only** module and is **blocked** from loading under PowerShell 7 (Core) by the `WindowsPowerShellCompatibilityModuleDenyList`. Under WinPS 5.1 the same calls work natively. (Tell-tale: PS7 renders errors in ConciseView with `Line |` + `~~~~` underlines; WinPS 5.1 uses the older NormalView - the error format alone reveals which host you are in.) **Fix**: `Invoke-PsadtSystemTest.ps1` now detects `$PSVersionTable.PSEdition -eq 'Core'` and transparently **re-execs itself under `...\WindowsPowerShell\v1.0\powershell.exe` (5.1)**, marshalling the structured result back via a temp JSON file (UTF-8 **no BOM**, so `ConvertFrom-Json` reads it cleanly). **General lesson**: any helper that relies on `Invoke-CommandAs`/`PSScheduledJob`/`Register-ScheduledJob` (scheduled-job-backed "run as SYSTEM" tricks) is **WinPS-5.1-only** - never assume it works in pwsh 7. Either force the 5.1 host or use a native `Register-ScheduledTask` (CIM) SYSTEM principal. Gotcha when re-execing via `powershell.exe -File`: **`[int[]]` array parameters do NOT bind** (only the first value binds, the rest become stray positional args -> "no positional parameter accepts ...") - marshal arrays as a CSV string and split inside the child.

2. **`Start-ADTMsiProcess -Action Uninstall -FilePath '{GUID}'` -> exit 60001 (`InvalidFilePathParameterValue`)**: once the SYSTEM loop actually ran, Install was green but Uninstall failed with `FullyQualifiedErrorId : InvalidFilePathParameterValue,Start-ADTMsiProcess` (exit 60001, app stayed installed). **Cause**: in **PSADT 4.1.x** `Start-ADTMsiProcess` split the target into two parameters - `-FilePath` is now validated as a **real .msi file path**, and a **ProductCode GUID must be passed via the dedicated `-ProductCode` parameter**. Older v4.0 patterns (and earlier versions of this skill's own examples) used `-FilePath '{<ProductCode>}'`, which now throws. **Fix**: `Start-ADTMsiProcess -Action Uninstall -ProductCode '{<GUID>}'` (same for `-Action Repair`). **General lesson**: this is exactly the "newer PSADT version changed a command" trap from Phase 4 - verify cmdlet parameters against the **installed** module (`(Get-Command Start-ADTMsiProcess).Parameters.Keys`) instead of trusting a remembered pattern; `-ProductCode` for GUIDs, `-FilePath` for actual files.

### 2026-09-05 - Notepad++ package (official MSI, first Windows Sandbox SYSTEM test)

Outcome: package GREEN, all seven loop steps clean. But it took **75 minutes of wall clock for an app that
an experienced admin packages by hand in fifteen**, and every one of those extra minutes came from the four
lessons below. They are ordered by how much time they cost.

1. **Never hand-roll the SYSTEM-test harness (cost: ~40 min, three wasted VM runs).** Driving deployment
   actions as SYSTEM and reading their exit codes back looks like ten lines of `schtasks`. It is not. Three
   separate bugs each destroyed a full sandbox run, and all three present as *a timeout or a null-reference
   minutes after launch*, nowhere near the cause:
   - **`echo %ERRORLEVEL%>file` is not what you think.** With a single-digit exit code cmd reads
     `echo 0>file`, where **`0>` is the stdin redirection operator** - the file is created EMPTY and never
     receives the number. Write `echo %ERRORLEVEL% > file`, with the space.
   - **File existence is not completion.** The redirection creates the file before the value lands, so
     `Test-Path` returns true on an empty file. Poll until the content *matches a number*.
   - **`Get-Content -Raw` on an empty file returns `$null`, and in Windows PowerShell 5.1 `$x = [string]$null`
     is STILL `$null`** - only concatenation (`'' + (...)`) or a typed variable (`[string]$x = ...`) produces
     a real empty string. An empty file is the NORMAL result here: it is exactly what a correct detection
     script writes when the app is absent. So the harness crashed *because the package was clean*.
   **General lesson**: use `scripts/Invoke-PsadtSandboxTest.ps1`. Its
   `tests/Invoke-PsadtSandboxTest.Tests.ps1` contains a regression guard for each of these, and each guard
   was verified to FAIL when the bug is reintroduced.

2. **A local self-test beats a VM round-trip by three orders of magnitude (cost: the same 40 min).** Each of
   those bugs was found by launching a VM and waiting ten minutes. All three are reproducible in **two
   seconds** on the host with a temp file and four lines of PowerShell. **General lesson**: before any
   change that can only be observed after a long-running job, write the two-second local check first. If a
   probe would take longer than the thing it verifies, it is the wrong probe.

3. **Batch installer probing into ONE script (cost: ~10 min).** Reading an MSI's Property, Feature,
   FeatureComponents, File, Directory, Shortcut, Registry and Upgrade tables was done as eight separate
   round-trips, each ~30-60 s of process start plus COM setup. One script that opens the database once and
   dumps every table costs one round-trip. **General lesson**: N sequential probes of the same artefact is
   a single script, not N tool calls. Same for `Get-Command`/`Get-Help` parameter verification.

4. **Start the SYSTEM test in parallel with Phase 7/8, not after them.** Packaging (`Invoke-PsadtPackage`)
   and the dossier do not depend on the test result - only the *verdict recorded in* the dossier does. Boot
   the sandbox first, build the `.intunewin` and the report while it runs, then fold the result in and
   regenerate. Serialising them adds the full test duration to the wall clock for no reason.

Two things that were NOT the problem, recorded so the next run does not "optimise" them away:

- **Windows Sandbox is fast enough.** The complete seven-step loop - Install, detection, Uninstall,
  detection, Reinstall, Repair, final Uninstall, all as SYSTEM - ran in **5 minutes 58 seconds**
  unattended, with no elevation on the host and no DEV VM. Individual actions take ~2 min instead of ~20 s
  because the VM has no warm file cache and Defender scans every file it sees. That is the price of a
  machine that has provably never seen the app; do not "fix" it by disabling Defender, which would test a
  configuration no real client has.
- **The package itself never failed.** Not once across four runs. When a test harness and the thing under
  test both look broken, check the harness first: it is the part that was written today.

Package-specific findings worth generalising:

- **An official MSI may exist even where everyone uses the EXE.** Notepad++ has shipped an x64 MSI
  "intended for IT departments" since 8.8.8, while practically every public guide still documents the NSIS
  `/S` route. Check the vendor's full asset list before accepting the community answer - the MSI brought a
  ProductCode detection rule, native repair and standard exit codes for free.
- **Prefer an MSI FEATURE over post-install cleanup.** The auto-updater is its own feature
  (`AutoUpdaterFeature`), so `ADDLOCAL=MainApplication` keeps it off the device entirely instead of
  installing it and deleting it afterwards. Read the Feature/FeatureComponents tables before writing any
  cleanup code.
- **`msidbUpgradeAttributesMigrateFeatures` can defeat `ADDLOCAL` on an upgrade.** A device upgrading from
  an install that HAD the feature can migrate that state. Keep the cleanup as a belt-and-braces second step
  even when the feature selection is correct.
- **A non-MSI predecessor is invisible to `RemoveExistingProducts`.** An app installed by an NSIS/Inno
  setup is not a Windows Installer product, so the MSI's UpgradeCode cannot supersede it: the device ends
  up with two ARP entries over one directory. Detect and remove it in Pre-Install.

### 2026-09-05 (same day, second package) - PuTTY 0.85: the lessons above, measured

The Notepad++ entry was written after a 75-minute run. PuTTY 0.85 - comparable app, same official-MSI
shape - was packaged straight afterwards with those lessons applied: **13 minutes 45 seconds end to end**,
from "package PuTTY" to a GREEN seven-step SYSTEM test, a verified `.intunewin` and a finished dossier.

What actually produced the difference, in order of effect:

1. **The sandbox test cost ZERO wall-clock time.** It was started the moment pre-flight went GREEN and ran
   while the `.intunewin`, the logo and the dossier were produced. 6 minutes 24 seconds of testing,
   0 seconds of waiting. Serialising it - as the Notepad++ run did - would have added its full duration.
2. **One MSI probe instead of eight.** `Get-PsadtMsiFacts.ps1` returned identity, signature, features,
   feature-component counts, shortcuts, directories, upgrade flags, files and registry rows in a single
   call. That one call is what surfaced `DesktopFeature` at Level 2 and the `MigrateFeatures` upgrade flag,
   which together decided the whole `ADDLOCAL` design.
3. **Gates 1 and 2 in ONE `AskUserQuestion` call**, every option pre-filled from the probe. Three
   questions, one interaction, no back-and-forth.
4. **One research pass, not a three-agent fan-out.** For a well-known app with an official MSI, the vendor
   download page plus the MSI itself IS the research. The fan-out is for apps whose silent switches are
   genuinely unknown.

Two things still went wrong, and both are now closed:

- **The Wikimedia thumbnail trap was hit AGAIN**, in the same session, for the same reason: a hand-built
  `1024px-` URL returns HTTP 400 because only pre-rendered widths are served. Cost ~1 minute, twice.
  Appendix J now says: never hand-build the URL, take `thumburl` from the API verbatim, and search the File
  namespace instead of guessing a file name (`File:Putty-256.png` does not exist; `File:PuTTY Icon.svg`
  does). **General lesson**: a mistake repeated inside one session is a missing guard-rail, not
  carelessness - write it down the first time.
- **The MSI probe itself took four attempts to get right** (COM `InvokeMember` vs. a direct call,
  `Execute`/`Close` returning `$null` into the pipeline, a `return ,$rows` over-correction, and
  `SummaryInformation` needing the direct call too). That is the same script for every MSI package ever
  built, so it belongs in the skill rather than in a scratch file. It is now
  `scripts/Get-PsadtMsiFacts.ps1` with five regression guards, each verified to fail on its reintroduced
  bug. **General lesson**: the second time you write a probe by hand, it is not a probe, it is a missing
  script.

Package-specific findings worth generalising:

- **A Level 2 feature is not installed by default, but an upgrade can still bring it in.** PuTTY's
  `DesktopFeature` is Level 2, so a plain install skips the desktop icon - yet the Upgrade row carries
  `MigrateFeatures`, so a device upgrading from an install where someone ticked it would keep it. Naming
  the wanted features in `ADDLOCAL` beats relying on the level.
- **A feature that edits the PATH turns the install directory into a drop zone.** PuTTY's `PathFeature`
  puts the install directory on the system PATH, which invites third-party binaries into a folder the MSI
  does not own - so the folder survives uninstall and a leftover `putty.exe` keeps detection reporting the
  app as installed. Clean the directory in Post-Uninstall whenever a package edits the PATH.
- **Leave SSH host keys alone.** PuTTY's saved sessions and host keys live in
  `HKCU\Software\SimonTatham\PuTTY`. Purging them on uninstall would make a genuine man-in-the-middle
  warning indistinguishable from a normal first-connection prompt. "Clean uninstall" never means deleting
  a user's trust store.

### 2026-09-08 - BootForge + Windows ADK + WinPE add-on (three packages, one dependency chain)

An in-house MSI whose service builds bootable USB media. Two of the three packages are Microsoft kits
bundled as offline layouts (1.8 / 1.9 GB). What this project taught, in order of how much time it cost.

**1. `Get-DriverSignatureInfo.ps1` reported valid WHQL drivers as Unsigned - FIXED in 0.26.2.**
`Get-InfValue` captured everything after `=` to end of line. WHQL packs routinely write
`CatalogFile=foo.cat   ; for WHQL certified`, and `;` starts a comment in INF syntax. The catalog path
therefore never resolved, the driver classified `Unsigned`, and the pre-flight went **RED for a perfectly
signed pack** (6 of 70 INF in a Dell WinPE set). Verified: all six catalogs were Authenticode-`Valid`,
signed by `CN=Microsoft Windows Hardware Compatibility Publisher`. An unquoted `;` now ends the value;
two Pester cases guard it. **General lesson**: any INF field can carry a trailing comment.

**2. `New-MsiPackage.ps1` was the sixth script with the `-File` binder trap - FIXED in 0.26.2.**
0.25.1 fixed five scripts and missed the generator. `-ProcessesToClose 'a','b'` arrived as ONE element,
so the scaffold got `AppProcessesToClose = @('''a'',''b''')` - a single nonsense name.
`Show-ADTInstallationWelcome -CloseProcesses` then closes NOTHING and reports success, so the install
runs against a running application. **General lesson**: when a whole-class fix lands, grep for `[string[]]`
across every script instead of fixing the reported call sites.

**3. The sandbox harness cannot test a heavy package at all.** `ActionTimeoutSeconds` is capped at 3600 and
`TotalTimeoutMinutes` at 180. A single ADK install (~30 MSI + 9 MSP out of a 1.9 GB payload) exceeds the
per-action ceiling. Worse, once an action times out the harness moves on while msiexec is still running
inside the VM: the next action gets `1618` (ERROR_INSTALL_ALREADY_RUNNING), the final detection still finds
the product, and the verdict is RED - none of which says anything about the package. Install and Uninstall
had both returned 0. **General lesson**: after a timeout the remaining steps are artifacts, not results;
report them as "not evaluated" and judge the package on the steps that actually ran.

**4. A package with a hard prerequisite is not sandbox-testable.** The WinPE add-on refuses to install
without the ADK, so in a fresh sandbox it aborts on its own precondition check - a run there confirms the
precondition, never the installation. Such packages need a DEV VM with the dependency pre-installed. Say
"not tested" in the dossier rather than shipping a green verdict that measured nothing.

**5. The SYSTEM test validates the package FOLDER, not the `.intunewin`.** The harness maps the folder into
the VM. The artifact that ships is therefore never the artifact tested. They match only if nothing was
edited after packaging - worth verifying explicitly (compare the newest file mtime under the package
against the `.intunewin` mtime) before an upload.

**6. Killing a sandbox run from the host orphans the VM worker.** The design is correct - the GUEST shuts
itself down, which is what releases the mapped folder. `vmmemWindowsSandbox` is owned by the Hyper-V
compute service, so the host cannot terminate it: kill the run from outside and it holds the work folder
(measured: ~200 s) while the next run THROWS instead of waiting. The message names the cause precisely;
the remaining manual step is the wait.

> **Corrected in 0.26.6 for the case the script itself controls.** The host TIMEOUT used to be handled
> like a finished run: the viewer processes were force-killed, which orphaned the worker AND destroyed the
> window that was the user's only way to shut the guest down cleanly - and the warning then advised
> "close the window by hand". The script now distinguishes the three terminal states (DONE.txt written /
> VM gone / host gave up while the guest still runs) and on a timeout deliberately touches nothing,
> explaining why and what to close. A run killed from OUTSIDE the script (Ctrl+C on the host) is still
> the un-recoverable case above.

**7. Service `%TEMP%` is not what the registry says.** On Windows 11 a LocalSystem service gets
`C:\Windows\SystemTemp`, while `HKLM\...\Session Manager\Environment` still reads `C:\WINDOWS\TEMP`. Both
`...\BootForge` folders existed; the failing call named the registry one, the actual work happened in the
other. **General lesson**: never infer a service's temp directory from the machine environment - and never
let privileged code write scripts to a fixed path under it. `C:\Windows\Temp` grants `Users`
CreateFiles/AppendData, so a predictable path there is user-controllable.

**8. `C:\ProgramData\<App>` subfolders are user-writable by default.** Creating them (from a package or
from the service) inherits `Users: Write` from `C:\ProgramData`. Measured on a live machine: the folder
holding a finished 562 MB WinPE boot image and the one caching a baked 7.6 GB install.wim were both
writable by any standard user - content that lands on every USB stick produced afterwards. **General
lesson**: creating a ProgramData folder is not the same as owning it. Harden every folder a privileged
service reads from or writes to, and do it in the SERVICE as well - a package-only hardening is skipped
entirely whenever the service creates the folder first.

---

### 2026-09-11 - Google Chrome: the sandbox ran nothing as SYSTEM and blamed the package

The first sandbox run on this host after 0.28.0. The package was fine from the start - it went GREEN on
the first run whose harness actually worked (14 steps, 9.9 minutes, no failed assertion). Getting there
took five stacked faults, each hiding the next, and about two hours. What made it expensive was not any
one fault but reading each symptom as a package problem.

**1. `elevated=True` is not evidence that anything can run as SYSTEM.** 0.28.0 had moved the runner from
`<LogonCommand>` to a Startup-folder trigger and added an `IsInRole(Administrator)` assertion to guard
the change. The assertion passed - and `schtasks /Create` + `/Run` returned exit 0 while the task never
ran; `Register-ScheduledTask` said "Cannot connect to CIM server. Access denied". Explorer's token is not
the token the Task Scheduler wants. **General lesson**: a precondition check must exercise the mechanism
it guards, not a proxy for it. The harness now runs `whoami` as SYSTEM before anything else.

**2. `2>file` does not suppress a native command's stderr under `$ErrorActionPreference='Stop'`.** The
0.28.0 comment asserted it did; a ten-line probe under `powershell.exe` showed `THREW - NativeCommandError`.
The redirect chooses where the ErrorRecord goes, not whether one is raised. **General lesson**: a comment
that explains why code is safe is a claim. When the run dies exactly where the comment says it cannot,
measure the claim before touching anything else.

**3. A guest that looks like the host is not the host.** Two things the host had, the sandbox image did
not: `Microsoft.PowerShell.Archive\de-DE\ArchiveResources.psd1` (PSADT imports that module at load, and
WinPS 5.1 throws rather than falling back), and a WMI service that answers SYSTEM (`Win32_ComputerSystem`
-> `0x80070005`, which `Initialize-ADTModule` needs). Both had worked on 2026-09-08; both broke with the
host's cumulative updates of 2026-09-11, from which the sandbox image is built. Both surfaced as the same
60008. **General lesson**: when every package fails identically, the environment is the suspect, not the
package - and a guest image changes every Patch Tuesday even though nothing in the repository did.

**4. `Invoke-AppDeployToolkit.exe` discards the `.ps1`'s stderr.** 60008 is "Initialization failed" and
is raised before the first log line, so the `.exe` route leaves exactly one number and nothing else. It
took two separate probe VMs to read the two lines that explained the two 60008s. The harness now re-runs
a 60008 action once through `powershell.exe -File` with stderr captured, and its PSADT canary opens a
real Silent session as SYSTEM so the next environment fault is named before the loop starts.

**5. Never edit the package while the sandbox is running against it.** The package folder is mapped
read-only into the VM and copied at the start of the run; a launcher edit mid-run produced a result that
would have mixed old and new code. That run had to be thrown away. **General lesson**: finish every edit,
re-run pre-flight, re-pack - then start the test, and touch nothing until the verdict.

**6. A SYSTEM action draws nothing.** Twenty minutes of an idle-looking VM screen are indistinguishable
from a hang, and "I see nothing happening" was correct - both when the tasks really did not run and later
when the install was working. The runner now prints a heartbeat every ten seconds and sets the console
title; the LogonCommand deliberately does not hide that window.

**7. One probe VM beats an hour of reasoning.** Every fault above was settled by a three-minute sandbox
that ran one command and wrote one text file back. The reasoning that preceded each probe was mostly
wrong in detail and would have produced another blind full run.

---

# Changelog

All notable changes to this skill. Newest first. This project follows a loose [SemVer](https://semver.org/).

## 0.34.0 - 2026-09-16 - A run can park for 25 minutes on a dialog nobody can see, and the timer said nothing

Packaging Time-Access 3010 (IDC, with the EDIsecure XID8600 card printer) spent four sandbox runs on two
problems that have nothing to do with that package. Both are about the same thing: the harness could not
tell a working run from a stuck one, and neither could the operator watching it.

### Added
- **`-TrustedPublisherCert` on `Invoke-PsadtSandboxTest.ps1`.** Takes one or more `.cer`, stages them in
  the mapped work folder and imports them into the guest's `LocalMachine\TrustedPublisher` during
  GuestPrepare - the same thing an Intune `RootCATrustedCertificates` profile does on the fleet (App. N).
  Without it, any installer that stages a third-party driver raises the Windows *"install device
  software?"* prompt, and that prompt is **invisible**: every action runs as SYSTEM through a scheduled
  task and draws nothing on the desktop. The installer waits for an answer nobody can give and the phase
  burns its whole timeout, which is indistinguishable from a slow installer unless you read the log tail.
  Measured: **25 minutes parked in `CA.dll: InstallPrinterDriver` versus 43 seconds with the certificate
  present** - for a `.cer` that was sitting in the package's own output folder. A RED now means the
  package is broken rather than the harness being short a prerequisite.

  The import goes through `certutil -addstore`, not `Import-Certificate`: the PKI cmdlet routes via the
  `Cert:` provider and returns `E_ACCESSDENIED` against `LocalMachine\TrustedPublisher` in this guest even
  though the runner is elevated. An `X509Store` call is kept as a second route, and **the result is
  verified by reading the store back by thumbprint** - a failed import looks exactly like a successful one
  in a log that records only the return value, which cost one full run testing a hypothesis whose
  precondition was never met.

### Fixed
- **The elapsed timer in the progress window stopped counting.** It read `$p.elapsed` from
  `progress.json` verbatim, and `Update-Ui` returns early when that file is byte-identical to the last
  read - correct for the phase list, which would otherwise reset the operator's selection on every tick,
  but fatal for a clock. Phases that are not an action wait loop never rewrite the file at all, and
  GuestPrepare alone can sit there for 90 seconds. So the one element whose entire job is to prove the run
  is alive was frozen exactly when that question gets asked. The clock is now computed above the
  unchanged-guard, on the window's own 1s tick, re-syncing on every value the file brings; it cannot drift
  more than one write interval and it never stands still.
- **The heartbeat was up to 20 seconds stale.** The guest refreshed `progress.json` every 10s and the host
  re-read it every 10s, and the two stacked. Both are 1s now. The console line and the transcript keep the
  coarser beat on purpose - one line per second buries the phase boundaries - and the host's output stays
  change-gated, so a quiet phase is still quiet.

### Documentation
- Phase 6.1 gains the three things this package needed and the docs did not say: `-TrustedPublisherCert`,
  cancelling with `STOP.txt` rather than killing the process (which orphans `vmmemWindowsSandbox` and
  blocks every further run until an elevated `Restart-Service vmcompute -Force`), and scoping with
  `-Scenarios` while iterating instead of re-proving a known failure four more times at ten minutes a
  turn. App. Q names the certificate requirement where a driver package is actually being built.
  SKILL.md is deliberately NOT touched: its pre-Phase-7 region had 55 bytes of headroom against the
  5000-token budget, and `tests/SkillContextBudget.Tests.ps1` forbids making room by deleting a rule
  or raising the budget. The certificate therefore reaches the agent through phase 6.1, which SKILL.md
  already points at - an unsatisfying place for a failure this expensive and this silent.

## 0.33.0 - 2026-09-16 - Three research agents went looking for a command Windows had been storing all along

Phase 2 dispatched a fixed three-agent research fan-out on every job. On an app that was already
installed on the packaging machine, one of those runs cost 400k tokens to rediscover a
`QuietUninstallString` sitting in the Uninstall registry. The fan-out was not too slow. It was not
gated.

### Fixed
- **The research fan-out is now conditional, and the condition is a number.** `SKILL.md` ordered it in
  the imperative - *"Dispatch the three Researcher roles concurrently"* - one line ABOVE the two probe
  sentences, and the handoff rules hardened that into *"Researchers run concurrently and return before
  scaffold"*. Operating-mode rule 1 then routed every unknown into it, because asking is forbidden. So
  three agents ran whether or not anyone needed them. Phase 2 now runs a local-evidence ladder first and
  dispatches against its `OpenQuestions[]` only; `AgentBudget` is the cap. Zero open questions, zero
  sub-agents.
- **The condition already existed, unreachable.** App. L.0 has defined stage 3 as *"the Phase 2 web
  fan-out, when the stages above found nothing"* for two releases, and App. B and App. G both argue
  against a fixed three-agent fan-out. Nothing in the Phase 2 block pointed at any of them.
  `rule:research-gate` now lives in `SKILL.md` itself, and `tests/RuleAnchors.Tests.ps1` lists it among
  the rules that may not be moved into a reference - a gate parked in an appendix is how this one got
  lost the first time.
- **Guide 1.3 stopped requiring research it no longer needs.** It labelled five web queries *"Mandatory"*
  and made the filled table a packaging gate, so research was compulsory even when the probe had already
  answered it. They are *query templates for an OPEN question* now, and the table gains a **Closed by**
  column naming the rung that answers each row.

### Added
- **`scripts/Get-PsadtLocalEvidence.ps1`** - four rungs, deterministic, offline, and it REPORTS rather
  than decides.
  **0 tooling:** the installed PSADT module's manifest via `Import-PowerShellDataFile` (never
  `Import-Module` - that has side effects), comparing `FunctionsToExport` against the commands this skill
  uses. That retires Researcher role (a), the version and command-drift check, entirely: a rename is a
  fact about a file on disk.
  **1 installed here:** the Uninstall registry, HKLM 64-bit and 32-bit views plus HKCU. A
  `QuietUninstallString` is not a claim - it is the vendor's own registration of a silent uninstall that
  works, and it closes the uninstall question outright with **no installer file present at all**. That
  case is a test.
  **2 binary here:** composition only. ONE call to `Get-PsadtSwitchCandidates.ps1 -Json`, which already
  carries the engine probe and the verified-switch store, plus `Get-PsadtMsiFacts.ps1` when the
  compound-file header says MSI. A source guard asserts it does NOT call `Get-PsadtInstallerEngine.ps1`
  a second time; that would re-scan the whole file for data already in hand.
  **3 written down already:** this skill's own corpus (word-bounded, so a short name like "Git" does not
  match every "GitHub"), plus a vendor doc URL taken from `HelpLink` / `URLInfoAbout` / `ARPHELPLINK`.
  The URL is **named, never fetched** - one direct fetch by the orchestrator is the cheap middle step
  between the ladder and an agent, and keeping the script offline is what makes "the gate is
  deterministic" a test rather than a promise.
- Each open question ships with its own `KnownContext`, `AcceptanceCriteria`, `SuggestedQuery` and a
  paste-ready `AgentPromptHint`, so a dispatched agent confirms rather than rediscovers. Everything that
  is open but not worth an agent lands in `Deferred[]` with a reason: `probe-run`,
  `recheck-after-binary`, `accept-unanswered`, `folded`. Nothing is dropped silently.
- **Questions one vendor page answers fold into a single agent, by FAMILY.** Caught in review, and it
  mattered: a chain-based fold only fired when its named carrier was itself being dispatched, so an app
  whose engine *was* identified (`silent-install` goes to `probe-run`, not to an agent) left uninstall,
  repair and post-install config each taking one - **four agents, where the old fixed fan-out sent
  three**, on the common path. There are now three families that can ever dispatch - `vendor-doc`,
  `runtime`, `intune` - so the cap is structural rather than arithmetic, and it holds however the
  question set grows. Measured across all four installer shapes: **3, and never more**. The rider stays
  visible in `Deferred[]` as `folded` and the carrier's prompt is told to answer it too.
- **A question could fall out of both output lists.** `OpenQuestions` and `Deferred` were two
  independent predicates, and `Provisional` + the initial `dispatch-agent` matched neither - reproduced
  with two ARP rows matching one build, where the **blocking** uninstall question vanished and the
  counts added to 8 of 9. `Deferred` is now the *complement* of `OpenQuestions`, so every question is
  Closed, open or deferred by construction, and a `Provisional` that never got a resolution is
  normalised to `probe-run` rather than left carrying a stale one.
- **A weak ARP row could get its key name laundered into a fabricated `msiexec /x`.** The code refused
  that row's `QuietUninstallString` as too weak to trust, then trusted the *same row's* GUID-shaped key
  enough to emit `msiexec /x {guid} /qn /norestart` at `high` and mark the question **Closed** - a
  confident command line for a product Windows Installer has never heard of, replacing the real one. A
  ProductCode is now only taken from the MSI database, the caller, or a strong row that is also
  `WindowsInstaller`-registered; a near-match row's real quiet string is kept at `medium` for the probe
  run instead.
- **The `install-source` matcher was dead code** - it compared the installer's *file* name to
  `InstallSource`, which is a *folder*. It never matched, which quietly removed the only `high`-confidence
  matcher and widened how far a weak row could reach.
- **The corpus search missed every name with a non-word edge.** `\b` asserts a word/non-word
  *transition*, so a name ending in punctuation can never satisfy it: `Notepad++` found **0** of its 5
  real mentions in this repo's own references. That is not cosmetic - a false miss is stated outright in
  the `KnownContext` handed to the pitfalls agent ("this skill's corpus does NOT mention X"). Lookarounds
  now say what was meant. The reported hit count is the true total, not the truncated one.
- **Repair is a question again.** Scoping every agent to one ladder question would have dropped it off
  the map entirely - not Closed, not Open, not Deferred, just absent - while `rule:all-three-deployment-types`
  makes Repair a deliverable and SKILL.md calls it the usual miss. `repair-strategy` closes from the MSI
  repair verb, treats a registered `ModifyPath` as a claim for the probe run, and otherwise carries
  App. L.7's warning that re-running an installer is not a safe substitute.
- `tests/Get-PsadtLocalEvidence.Tests.ps1` (46 cases), pointed at Pester's `TestRegistry:` drive through
  `-UninstallRoots` so it never reads the machine's real hives. Three of them existed and asserted
  nothing: two restated the definitions of `OpenQuestions` and `AgentBudget` (tautologies that cannot
  fail), and one read `.Ok | Should -BeFalse` off an empty filter, which passes on `$null` whether the
  probe failed or never ran. They are replaced by the invariant that actually matters - every question
  in exactly one list, the budget capped across all four installer shapes - and mutation-checked: three
  fail against the pre-fix code.
- `evals/behaviour-local-evidence-before-fanout/` - the fourth behaviour eval. It fails a plan that
  announces three parallel Researchers before anything local has been checked.

### Notes
- **Two questions can never be closed locally, and the ladder says so** with `CanCloseLocally = $false`:
  the external runtime prerequisite (1.4) and known Intune pitfalls. A statement about other people's
  fleets does not follow from this machine. Pretending otherwise would have been worse than the fan-out
  being replaced, so the realistic floor is about 2 agents, not 0.
- **`setup.exe /?` was considered and rejected.** Reading a vendor binary's help output would run vendor
  code on the packaging HOST, three phases before the throwaway sandbox that exists for exactly that -
  and the engines where it would help are the ones that answer `/?` with a modal dialog, or by installing
  anyway. It is reported as a not-attempted miss naming the reason.
- The new Phase 2 block is **60 bytes smaller** than the one it replaces. That was not incidental:
  `tests/SkillContextBudget.Tests.ps1` had 28 bytes of headroom, and the ladder detail belongs in guide
  1.3 anyway.

## 0.32.0 - 2026-09-15 - Every dossier said the SYSTEM test was not run, including the ones whose gate was green

Packaging JetBrains PyCharm 2026.2.2 (NSIS, 908 MB) turned up one trap in the app and one hole in this
skill. The hole is the bigger of the two: the sandbox harness measures every action and writes result.json,
records its path in the manifest - and the dossier ignored all of it.

### Fixed
- **The dossier now reads the sandbox verdict instead of asking for it.** `New-PsadtReport.ps1` takes
  identity, artefacts and return codes from the manifest but not the test result, so without a hand-built
  `-Metadata SystemTest` it printed *"the SYSTEM test was not run (no evidence)"* on a package whose gate
  was GREEN. The only remedy was to retype, by hand, numbers the harness had already produced - exactly
  the transcription this skill refuses everywhere else. It reads `results.sandboxTest.resultPath` now and
  **judges** the rows rather than copying them: an action that exits 0 while the detection rule disagrees
  is a **fail**, because that combination is the signature of a per-user install (App. L.7). A
  caller-supplied `SystemTest` still wins, for the DEV-VM route that has no result.json, and an
  unreadable result.json keeps the neutral "not run" default - unreadable evidence is not evidence.
- **The guest progress window hung off the right edge of the sandbox desktop.** `WindowStartupLocation`
  put it at x=208 on a 1353-wide guest, so TIMEOUT and DETECTION - the two columns a reader needs when a
  phase misbehaves - were off screen. It is sized against the work area and positioned explicitly now,
  which cannot place it outside the visible desktop. Verified in the guest.

### Changed
- `references/appendix-l-installers.md` L.7 gains a **fourth BINDING trap**, and the engine catalog
  carries it as a note on `nsis`, `inno` and `electron-builder`:
  **re-running the installer over an existing install is not a safe repair.** "NSIS has no repair verb, so
  re-run the installer" is the standard substitute and assumes the installer tolerates finding itself
  already there. Measured on PyCharm 2026.2.2 as SYSTEM: `installer.exe /S` over an existing install of
  the same version **never returned** - killed at 603 s, the process alive with no child process, no
  uninstaller and no error, while Install (217 s) and Reinstall (234 s) on a clean machine both exited 0.
  Repair is then an explicit uninstall followed by an install. The signature is a Repair that times out
  while Install and Reinstall pass.

### Notes
- PyCharm 2026.2.2 then passed the full gate: Install 185 s, Uninstall 32 s, Reinstall 195 s, Repair
  210 s, FinalUninstall 32 s, every detection correct, **GREEN with no failed assertion** - at 908 MB the
  largest package this skill has produced.
- Two further traps that cost nothing only because the research found them first: PyCharm **Community is
  discontinued** (the unified edition is the successor), and JetBrains writes the **build** number into
  `DisplayVersion` (`262.10315.174`), not the marketing version - a rule comparing against `2026.2.2`
  finds the app installed and decides it is years out of date, forever.
- Suite 572 -> 576.

## 0.31.0 - 2026-09-14 - The window in the sandbox said the run was busy, never what it was doing

The guest window added in 0.30.1 solved the right problem - a SYSTEM task draws nothing, and on some
Sandbox builds the LogonCommand process gets no console at all - but it showed one line: the step running
now. A run three phases in looked like one stuck on its first, and a phase that failed left nothing behind
to read. It is a WPF master/detail window now, and the JSON under it carries the whole run.

### Added
- **The guest window shows every phase at once.** Tick, cross or live marker per phase, and for the
  selected one its exit code, duration, start and end, timeout, detection result and its own transcript.
  Still a separate process polling a file, still passive: it never drives the run and closing it stops
  nothing. `SHOW-PROGRESS.cmd` still starts it by hand if it did not open.
- **`progress.json` carries a `phases[]` plan**, derived from `-Scenarios` rather than fixed. The old
  hardcoded `total = 14` was wrong for every partial run and wrong for the full gate too, which has 15
  steps. The top-level fields it published before are unchanged, so an older window still works.
- `tests/SandboxProgressUi.Tests.ps1`: ASCII and parse guards on both halves, the XAML loaded through
  `XamlReader` in a child `powershell.exe -STA` with every name the script looks up asserted, a guard
  against setting `Style` twice on one element, the passivity rules, and the phase plan exercised by
  running the runner's own functions - extracted through the AST by name, not by a byte range.

### Fixed
- **`-Scenarios Install,Uninstall` was refused before the run could start.** A `[ValidateSet]` on the
  parameter runs at BINDING time, before any line of the body - and `pwsh -File` hands a comma list to a
  `[string[]]` parameter as ONE string, which is exactly what `Expand-CommaSeparated` exists to split.
  The attribute rejected it first with "does not belong to the set" and nothing ran, so the documented
  short-iteration form has never worked from the documented invocation. The names are validated after the
  split now, naming the unknown one and the valid set.
- **The phase list never moved off the first row.** Selecting a row does not scroll to it in WPF, and the
  code could not tell its OWN automatic selection from a click - so the first auto-selection counted as the
  operator's choice and the list stayed on `Elevation` for the whole run while the work happened below the
  fold. It follows the running phase now, and stops following the moment a person clicks a row.
- **The pre-checks showed no duration.** They report no `seconds` of their own, so four of the five rows
  that start every run were a dash. Phases are strictly sequential, so they are timed from the end of the
  phase before; an action's own measurement still wins where it has one.
- **`GuestStaging` threw its exit code away.** `robocopy` returns one, it was tested (`-ge 8` throws) and
  then dropped. It is recorded now - 1, 2 and 3 all say different things about what the guest received.
  `Elevation` and `GuestPrepare` keep a dash, because they start no process and no exit code exists.
- **Two PowerShell consoles sat behind the window.** Both are hidden by console handle, not with
  `-WindowStyle Hidden` - that lands in STARTUPINFO and the first window the process creates inherits it,
  which is what hid the progress window itself in 0.30.1. The runner's console is hidden only AFTER the
  window has been launched, so a failed launch still leaves the operator something to look at.
- **A failed phase looked exactly like a passed one.** In WPF a LOCAL value beats a style trigger, and the
  phase marker carried `Background=` as an attribute alongside a style whose `DataTrigger`s set it.
  Measured: Pending, Running, Done and Failed all rendered `#FF0A2F29`. The defaults moved into the style,
  where a trigger can win; a test now rejects that combination anywhere in the markup.

### Notes
- **Measured in the guest before any of it was written**, because a window that cannot render there is
  worth nothing: WPF loads under Windows PowerShell 5.1 (STA by default - `pwsh` is MTA and would throw),
  the real XAML parses, and the window paints at 1180x800 on render tier 0, with no vGPU. A PNG of the
  rendered window came back out of the VM as the proof.
- Three faults in the imported drafts, each of which made them unusable and none visible by reading them:
  the script carried non-ASCII bytes with no BOM and had **four parse errors** under WinPS 5.1 (App. B.1);
  the XAML set `Style` twice on one element and `XamlReader` threw; and a `{Binding Phases}` on the window
  reports `UpdateTargetError` against a `PSCustomObject` DataContext, so the list stayed empty - inside the
  item templates the very same objects bind correctly, so only that one hop is done in code.
- The window is clamped to the guest work area before it is shown. A window bigger than the desktop is
  centred anyway and then hangs off all four edges, taking the phase list and the buttons with it.
- Suite 554 -> 569.

## 0.30.2 - 2026-09-14 - The exit code was accepted by the launcher and rejected by the harness

Citrix Workspace 26.3.10.69 needed ten sandbox launches in one afternoon. Nine of them were faults in this
skill, not in the package, and 0.30.0 and 0.30.1 already carry five of those. This release carries the last
one, which is the one that wasted the most runs for the least reason.

### Changed
- **A vendor-specific success code has to be in BOTH lists** - guide 6.1, Appendix G fault 5, Appendix B.
  A sandbox step is judged twice, by two independent lists that share a parameter name: PSADT's
  `-SuccessExitCodes` on the `Start-ADTProcess` call inside the launcher decides whether the DEPLOYMENT
  throws, and `Invoke-PsadtSandboxTest.ps1 -SuccessExitCodes` (default `0, 1707, 3010, 1641`) decides
  whether the STEP is painted green. Citrix Workspace Repair returns 40032 - "already at the current
  version", CTX695019, a documented success. It went into the launcher, the run still came back RED, and
  three more runs were spent re-editing a launcher that had been correct since the first edit. With the
  code passed to the harness as well, the unchanged package passed the full gate: Install 157 s, Uninstall
  85 s, Reinstall 72 s, Repair 30 s (exit 40032), FinalUninstall 72 s, every detection correct, GREEN with
  no failed assertion. **Before changing anything after a RED, read which of the two produced it.**
- `references/appendix-b-anti-patterns.md` gains the four PowerShell traps that each cost a run here on
  2026-09-14, all silent: `@(...)` around an EMPTY `Generic.List` throws *Argument types do not match* in
  WinPS 5.1 AND pwsh 7 (use `.ToArray()`); `-WindowStyle Hidden` on `Start-Process` is inherited by the
  FIRST window the child creates, so a progress GUI launched that way runs windowless and reads as a hang;
  two variables differing only in case are the SAME variable, with no warning; `-like` against a literal
  containing `*` silently matches more than it should (use `.Contains()`). The file crossed 100 lines and
  gained the table of contents the doc guard requires.

### Added
- A drift guard in `tests/DocCrossRefs.Tests.ps1`: the harness default list quoted in guide 6.1 must equal
  the actual parameter default in `Invoke-PsadtSandboxTest.ps1`, with an anti-vacuity test on both regexes.
  A documented list that has drifted teaches exactly the wrong thing, silently.

### Notes
- All 12 applications packaged with 0.30.x are GREEN, Citrix Workspace included.
- Suite 552 -> 554.

## 0.30.1 - 2026-09-14 - A scheduled task will not start on battery, and Greenshot installed into a profile nobody uses

Packaging Greenshot with 0.30.0 produced four consecutive RED runs, none of which were the package. Two
were faults in this harness, one is a documented Windows Sandbox defect, and one is a packaging trap that
ships a green deployment nobody receives.

### Fixed
- **A scheduled task will not start on battery.** `schtasks /Create` defaults
  `DisallowStartIfOnBatteries` and `StopIfGoingOnBatteries` to TRUE. On a laptop that is not plugged in,
  the task is created, `/Run` returns 0, and the task then sits at status **Queued** forever without ever
  executing. Every deployment action reports a bare timeout that names no cause, and the failure follows
  the POWER CABLE rather than the package - the identical build had passed hours earlier on mains. The
  task is registered from XML now, with both settings false; that also drops the 72-hour execution limit
  `/Create` imposes, so a long action is bounded by this harness's timeout and nothing else.
- **A leftover `WindowsSandboxServer` silently broke every later run.** After a run the VM worker exits
  but the broker can survive (microsoft/Windows-Sandbox#124, filed by a Microsoft engineer: an unhandled
  exception during teardown "blocking new launches until things are cleaned up", reproducing on
  long-running, high-throughput sessions - which is what an automated harness is). The next sandbox comes
  up and its scheduled tasks never execute, so a DIFFERENT pre-check times out on each attempt and it
  reads as flakiness. Broker-without-VM is now detected and cleared at start rather than reported as "a
  sandbox is already running", which it is not.
- **The timeout diagnostics answered their own cleanup.** They ran after the task was deleted, so the task
  query could only ever report "the system cannot find the file specified", and they read the process
  table through WMI - which is broken in the guest until GuestPrepare repairs it, and the first pre-check
  runs before that. Now they run before the delete and use `Get-Process`.

### Added
- **An ARP dump whenever detection contradicts the action.** A deployment that returns exit 0 while the
  detection rule reports "absent" is the most confusing outcome this harness can produce, and the VM is
  discarded seconds later taking the evidence with it. Every ARP entry is now captured from both HKLM
  views AND every `HKEY_USERS` subtree. That dump found fault #4 below in a single run.
- **The progress window lists what has already passed**, with a tick per completed step and a cross for a
  failed one, above the live transcript. Until now it showed only the step running right now, so a run
  three steps in looked the same as one stuck on its first.

### Changed
- `references/appendix-l-installers.md` L.7 gains a third BINDING trap, and the engine catalog carries it
  as a note on `inno`, `nsis` and `electron-builder`:
  **an EXE installer that can install per-user must be forced to per-machine.** Measured on Greenshot
  1.3.315: without `/ALLUSERS` the install landed in
  `C:\Windows\SysWOW64\config\systemprofile\AppData\Local\Programs\` and registered under
  `HKEY_USERS\S-1-5-18\...\Uninstall\Greenshot_is1`. Install, uninstall, reinstall and repair each
  returned exit 0, and an HKLM detection rule correctly said "absent" every time. On a real device that
  ships as a green deployment no user ever receives. An HKLM rule reporting "absent" right after a
  successful install is the signature - check the user hives before touching the detection script.
- Appendix G gains the incident, and its table of contents gains the two entries it was missing.

### Notes
- Greenshot 1.3.315 then passed the full gate: Install 14 s, Uninstall 16 s, Reinstall 14 s, Repair 16 s,
  FinalUninstall 16 s, every detection correct, **GREEN with no failed assertion**.
- The two diagnostics that cut this from hours to one run each - the timeout process/task capture and the
  ARP dump - both existed only because an earlier run had already been wasted. Build the capture before
  the second attempt, not the fifth.
- Suite 551 -> 552.

## 0.30.0 - 2026-09-14 - The sandbox spent half an hour asking a switched-off Defender whether it trusted a file

Two things came out of one afternoon of packaging Citrix Workspace, and the second one is bigger than the
feature that started it.

The feature: Appendix L.1 has carried a BINDING rule since the Aperio incident - identify the installer by
its *definitive* fingerprint, never by a coincidental substring. That package shipped `/S` to an install4j
installer, which shows the language dialog and waits forever. The rule was right and unenforceable, because
it asked a human to eyeball a strings dump. `references/research-trust.md` made the gap visible: it names a
verifying script for every kind of value except two, "installer engine" and "silent switch". Both rows now
name a script.

The bug: every attempt to test that package in the Windows Sandbox timed out after 30 minutes with no exit
code - three times, with three different command lines. It was never the package. Microsoft's own root
cause, on their sandbox issue tracker: **Smart App Control is enabled in the sandbox base image while
Windows Defender is disabled.** `wintrust` asks the disabled Defender to rate the trust of every signed
package and sits in a retry loop, about **two minutes per file**, inside the MSI server process. A
bootstrapper chaining a dozen signed MSIs therefore takes half an hour and looks exactly like a hang.
Two lines in the guest remove it. The same run then finished in **5.7 minutes with exit 0 and the app
detected**.

That explains an older entry too. Appendix G recorded the ADK (about 30 MSIs) as proof that "the sandbox
harness cannot test a heavy package at all", and blamed Defender scanning every file. Defender was switched
off the whole time. Both the lesson and the code comment are corrected.

### Added
- **`scripts/Get-PsadtInstallerEngine.ps1`** - identifies the installer engine from the file. Markers are
  classified DEFINITIVE or HINT and a definitive marker always wins, so the Aperio case now resolves to
  install4j even when the binary also carries NSIS branding. It reports the marker, the byte offset and the
  region, so the answer can be checked instead of believed. An unrecognised binary returns engine `unknown`
  with empty evidence rather than a guess.
- **`references/switch-catalog/engine-defaults.json`** - 19 engines with silent install, uninstall, log and
  no-reboot switches, a detection hint, the traps as notes, and a dated source reference per entry.
  Validated against `references/switch-catalog/schema.catalog.json`.
- **`scripts/Get-PsadtSwitchCandidates.ps1`** - ranked candidates for an installer. Stage 0 is the per-user
  verified-switch store, stage 1 the engine default, stage 2 winget-pkgs (opt-in, not implemented yet),
  stage 3 the existing Researcher. Every stage reports hit **or miss with a reason**, so the dossier can
  show what was checked rather than only what was found.
- **Appendix L.0** - the stage table, what each confidence level means, and why the catalog does not end the
  search.
- **`scripts/_SandboxProgressUi.ps1`** - a top-most progress window inside the sandbox showing the current
  step, elapsed time against the timeout, a bar and the live transcript. It runs as its own process, so it
  no longer depends on the runner's console existing.
- **A cancel path.** `STOP.txt` in the work folder makes the guest shut ITSELF down - measured at 5 seconds
  - which is the only teardown that does not orphan `vmmemWindowsSandbox` and lock the work folder until a
  reboot. The host writes it on its own timeout too, instead of walking away from a running VM.
- **`-Scenarios`** on the sandbox test. The full Install/Uninstall/Reinstall/Repair/FinalUninstall loop
  stays the default and the gate; a shorter set is for iteration, and a partial run is recorded as
  `GREEN_PARTIAL` so it can never be mistaken for the gate.
- **Timeout diagnostics.** A timed-out action now captures the guest's full process table with command
  lines and every vendor log touched in the last two hours, before the VM is discarded. PSADT's own log
  cannot explain a hang - PSADT is the thing waiting.

### Fixed
- **The sandbox could not test a heavy package** (see above). `Disable-GuestSmartAppControl` runs first in
  GuestPrepare and records its state as a step.
- **Nothing was visible inside the sandbox.** On this Sandbox build the process started by `<LogonCommand>`
  gets no console window at all, so the heartbeat added in 0.29.0 was written to a file nobody could see.
  The new progress window is independent of it, and the runner now MEASURES whether a console exists and
  reports it as `consoleWindow`. The window launcher must not use `-WindowStyle Hidden`: Start-Process
  passes the show state to the child and the first window it creates inherits it, so the form was created
  invisible while the process ran happily. Measured both ways.
- **The host was silent for the whole run** and now mirrors the guest's progress file.
- **A failed VM start was reported as "the VM was closed"**, sending the operator to look for a person who
  closed a window. The two cases are now distinguished by whether the runner ever produced output.
- **`schtasks` and the WMI probe printed red error blocks on a healthy run.** Both are expected, handled
  conditions; they no longer render as failures.
- **Relative paths broke four scripts.** .NET file APIs resolve against the process working directory,
  which PowerShell's `Set-Location` does not change, so `-PackagePath .` made the pre-flight look beside the
  SHELL and report a complete package as broken. Fixed in the pre-flight, the SYSTEM test and the manifest
  writer, and guarded by `tests/PathNormalisation.Tests.ps1` - which found a fourth script on its first run.

### Changed
- `SKILL.md` Phase 2 points at the script instead of the table. The swap cost 16 bytes; Phase 6 ends at
  byte 17457 of the 17500-byte compaction budget.
- Appendix L.2 carries each engine's catalog id in code ticks and gained five rows (MSP, electron-builder,
  BitRock, 7-Zip SFX, WinRAR SFX); InstallAware and Wise are separate rows now. The table stays - the agent
  reads Markdown in Phase 2, not JSON - and a drift guard binds the two in both directions.
- Staging the package into the guest uses `robocopy /MT` instead of `Copy-Item`, and `Unblock-File` only
  touches scripts, modules and binaries. Measured on a 481 MB package: 3.6 s to 0.6 s on local disk, and
  1 to 2 seconds inside the guest.
- The per-action timeout default drops from 900 to 600 seconds. An install that has not returned in ten
  minutes is almost never still working.
- `references/research-trust.md` names a script for "installer engine" and for "silent switch".
- `references/phases-0-6.md` 1.3 runs the catalog before the first web query.
- `SECURITY.md` section 3 covers the catalog: repo data, dated sources, still claims, offline by default.

### Notes
- **An engine catalog, not an application catalog.** Applications are a long tail whose entries rot
  silently - Teams classic became MSIX, Citrix Receiver became Workspace with a different bootstrapper -
  and a stale entry is worse than none, because the sandbox only catches it minutes later. Engines are a
  short list that is stable for years.
- **winget stays opt-in, including as a research source.** WinGet has never been auto-selected in this
  skill (gate 1, App. I). Stage 2 needs `-WithWinget`, the default path makes no network call at all, and a
  test asserts the script contains no web cmdlet.
- **`winget show` does not print InstallerSwitches** (measured, client 1.29.290), and it only shows the
  installer selected for the local machine. When stage 2 is built it will read the raw manifest.
- **4 KB header fixtures would have proven nothing.** Only MSI (compound-file magic at offset 0) and WiX
  Burn (a section name) are visible in the first pages; NSIS, Inno, InstallShield, install4j and the SFX
  formats keep their markers in the PE overlay or the resources. On a real Inno installer the marker sat in
  the section data. The whole file is scanned in one streaming pass instead - 460 MB in 1.1 s.
- **`@($emptyGenericList)` throws "Argument types do not match"** - in Windows PowerShell 5.1 and pwsh 7
  alike - and the exception surfaces at the enclosing object literal, pointing at whatever key happens to
  sit there. The empty case is the normal one here: it is what an unrecognised installer returns.
- **Citrix Workspace itself returns `unknown`, and that is correct.** A full scan finds no engine marker,
  because it is a bespoke vendor bootstrapper. The catalog says so explicitly and routes to the probe run.
  It is also the honest limit of an engine catalog.
- Verified against the real installers on the authoring machine: eight MSIs, an Inno setup, a WiX Burn
  bundle and a 7-Zip SFX, each identified correctly with the marker and offset reported.
- Suite 503 -> 551.

## 0.29.1 - 2026-09-14 - The v3 mapping table sent readers to a cmdlet that does not exist

Found while reviewing an externally proposed patch against this skill. The patch had the direction right
and the details wrong: it also declared the skill "verified against PSADT 4.2.0" (which exists only as a
release candidate), claimed `-ArgumentList` drops the MSI log, and pushed 1602 into the mandatory Intune
table without touching the two tests that count its rows. Every claim was checked against the installed
PSADT 4.1.8 module source, Microsoft Learn and the GitHub release list before anything changed here.

### Fixed
- **Phase 5.5 mapped `Remove-MSIApplications` to `Remove-ADTApplication`, which v4 does not have.** The
  v4 name is `Uninstall-ADTApplication`. A "forbidden -> correct" table whose right column names nothing
  is worse than no table, so the right column is now checked against `FunctionsToExport` of the newest
  installed toolkit manifest (read, not imported; skipped where no toolkit is installed).
- **Appendix A listed 60012 as the v4 deferral code.** 4.1.x has no 60012; a deferral exits with
  `UI.DeferExitCode`, default 1602 - the number msiexec uses for "user cancelled". It stays OUT of the
  mandatory return-code table on purpose: every install command this skill writes runs
  `-DeployMode Silent`, where no Defer button exists, and Intune's `retry` would mean three more attempts
  five minutes apart for a code that cannot occur.
- **The Phase 4.3 MSI sample put the `.mst` in `SupportFiles\` and passed `-ArgumentList`.** Phase 4
  already says transforms live in `Files\` next to the MSI; PSADT resolves a bare name against the MSI
  folder and passes `TRANSFORMSSECURE=1`, whose rule is a transform source next to the package. The
  `-ArgumentList` was byte-identical to the 4.1.8 config defaults and did nothing - but it REPLACES those
  defaults when it differs, which is what `-AdditionalArgumentList` is for. The `/L*V` log is appended
  separately either way; the patch's claim that `-ArgumentList` drops it is wrong.
- **README still claimed 441 Pester tests** in three places; the suite passed 441 several releases ago.
- Suite 501 -> 503.

## 0.29.0 - 2026-09-11 - The sandbox ran nothing as SYSTEM and blamed the package

Found while packaging Google Chrome for Intune - the first sandbox run on this host after 0.28.0. Five
faults were stacked on top of each other, and every one of them hid the next: the run died before its
first action, then every action timed out with no cause, then every action exited 60008 with no log, then
60008 again for a different reason. Each was measured inside the guest with a standalone probe before it
was fixed; nothing here was taken from a comment, a thread or a plausible theory.

### Fixed
- **The Startup-folder trigger from 0.28.0 could not run a single task as SYSTEM.** Explorer launches a
  Startup item, and the resulting runner passes `IsInRole(Administrator)` yet cannot drive the Task
  Scheduler: `schtasks /Create` and `/Run` both return exit 0 while the task never executes, and
  `Register-ScheduledTask` is refused outright ("Cannot connect to CIM server. Access denied"). Every
  deployment action then hit its full timeout with no cause, and the evidence pointed at the package.
  `<LogonCommand>` is back - the five GREEN runs on this host before 0.28.0 all used it. What
  [microsoft/Windows-Sandbox#125](https://github.com/microsoft/Windows-Sandbox/issues/125) describes is
  left to the host's `DONE.txt` timeout, which already says "the runner never started".
- **`schtasks`' own stderr notice killed the run before the first action.** The ONCE trigger is
  deliberately in the past, so `schtasks` writes "/ST is earlier than current time" on every step. In
  Windows PowerShell 5.1 that raises a terminating `NativeCommandError` under
  `$ErrorActionPreference = 'Stop'` - and a `2>file` redirect does NOT prevent it, it only chooses where
  the ErrorRecord is written (measured; the 0.28.0 comment claimed otherwise). The preference is lowered
  around the three `schtasks` calls and around the final `shutdown.exe`; the exit-code checks stay.
- **The sandbox image lacked a localized resource PSADT needs just to load.** PSADT imports
  `Microsoft.PowerShell.Archive` at import time; the guest had no `de-DE\ArchiveResources.psd1` while
  the de-DE host has it, and WinPS 5.1 throws instead of falling back to another culture. Every launcher
  exited 60008 before writing one log line - for any package, not just this one. The host's culture
  folders for the modules PSADT imports are shipped in the work folder and laid down in the guest
  wherever they are missing (`GuestPrepare`).
- **WMI refused SYSTEM inside the guest.** `Initialize-ADTModule` queries `Win32_ComputerSystem` and got
  `0x80070005`, so `Open-ADTSession` threw - 60008 again, even after the import had been fixed. The same
  guest image had passed on 2026-09-08; the host's cumulative updates of 2026-09-11 are the only change
  in between. `GuestPrepare` verifies WMI and salvages, then resets, the repository
  (`winmgmt /resetrepository` is what worked). Both are safe in a VM that is discarded minutes later.

### Added
- **Three canaries run before the loop.** `SystemTaskCanary` runs `whoami` as SYSTEM;
  `PsadtModuleCanary` imports the package's toolkit AND opens a Silent session as SYSTEM. Each fails in
  seconds with the real error text and names a HARNESS/environment fault, so a broken guest can no
  longer look like a broken package. Elevation alone was proven necessary but not sufficient.
- **A 60008 action is re-run once through `powershell.exe -File`** and its stderr recorded on the step
  (`diagnostic`). `Invoke-AppDeployToolkit.exe` discards the `.ps1`'s stderr, and 60008 means nothing
  was deployed, so the re-run is side-effect-free. It took two probe VMs to read that one line by hand.
- **A heartbeat in the guest console.** Every SYSTEM action draws nothing on the desktop; the runner now
  prints progress every ten seconds and sets the window title, so a healthy two-minute install no
  longer looks identical to a hang to anyone watching the VM.
- Suite 493 -> 501.

### Changed
- The `-GuestSettleDelaySeconds` wait moved into the LogonCommand (`cmd /c ping ...`) and is XML-escaped
  on the way into the `.wsb`: an unescaped `&` there makes the whole configuration unparseable, and the
  sandbox then boots with no mapped folders at all. The suite caught it before it shipped.

## 0.28.0 - 2026-09-11 - The sandbox booted without its mapped folders and said nothing

Ported from [#17](https://github.com/pt1987/claude-code-psadt-skill/pull/17) by @CSN-TechX, found while
packaging real apps for Intune. The branch predated the 0.27.0 reference split, so the documentation half
landed in `references/appendix-l-installers.md` rather than the guide file it was written against.

### Fixed
- **A space anywhere in the `.wsb` path silently disabled every custom mapped folder.**
  `Start-Process -ArgumentList $wsbPath` does not quote its elements, so the path was split across
  several argv entries and `WindowsSandbox.exe` booted with the built-in shares only - no error, no
  warning, just a guest that could not see the package. A Windows username with a space in it is enough
  to trigger it, and it puts a space in `%LOCALAPPDATA%` too, which is where the work folder lives. The
  symptom reads exactly like an upstream Sandbox bug, which is how it survived this long.
- **`<LogonCommand>` never ran at all on the affected Sandbox app version**
  ([microsoft/Windows-Sandbox#125](https://github.com/microsoft/Windows-Sandbox/issues/125)) - the
  process is not spawned, while `MappedFolders` keeps working. The work folder is now mapped straight
  onto the guest's Startup folder, which Windows' own logon path populates, and a one-line
  `StartupTrigger.cmd` starts the runner. The runner `.ps1` sits in a `runner\` subfolder: Startup
  auto-executes only `.exe/.bat/.cmd/.lnk/.vbs`, and a bare `.ps1` loose in there additionally makes
  Explorer raise its own "how do you want to open this file" prompt.
- **A transient read could report a real result as empty.** The action's `.cmd` writes the output file
  and the exit-code file on consecutive lines, but the bytes of the first are not guaranteed visible to
  the reading process the moment the second is - Defender briefly locking a fresh file is enough. A
  detection step captured `stdout: ""` and was read as "not detected", while the same file re-read at
  the end of the run held the real answer. The read now retries, which separates a genuinely empty
  result (the normal case for an absent app) from an unreadable one.

### Changed
- **`schtasks` failures are no longer invisible.** Neither the `/Create` nor the `/Run` call checked its
  exit code, so any failure to create or start the SYSTEM task presented as the action timing out 900
  seconds later - the one symptom that says nothing about the cause. Both are checked and the real
  message is raised.
- **The runner verifies it is elevated before the first action.** `schtasks /RU SYSTEM /RL HIGHEST`
  needs the full administrator token. `<LogonCommand>` supplied one implicitly; an Explorer-launched
  Startup item does not guarantee it. Without the check, a filtered token would have made all seven
  actions fail identically and pointed the evidence at the package.
- **The noisy `/ST` warning is suppressed rather than designed away.** The PR silenced it by moving the
  trigger to now+1min. That arms a real ONCE trigger - which can re-launch the same deployment `.cmd`
  as SYSTEM while the action is still running, since `MultipleInstancesPolicy` defaults to `IgnoreNew`
  and only covers overlap - and `(Get-Date).ToString('HH:mm')` is culture-dependent on top: under fi-FI
  it renders `15.02`, which `schtasks` rejects with "Invalid start time value", creating no task at all.
  `00:00` stays, deliberately in the past, and its stderr notice goes to a file.
- **New `-GuestSettleDelaySeconds`** (default 0), for hosts where the mapped folder is not ready the
  instant the guest logs on. Implemented with `ping -n` rather than `timeout`, which aborts without a
  console it owns.

### Added
- **NSIS MultiUser (`MultiUser.nsh`) is documented as its own trap** (App. L.1 / L.2 / L.7). Built with
  the MultiUser plugin, a bare `/S` fails `.onInit`'s command-line validation and exits in well under a
  second, before a single file is written, with no stdout and no stderr at all. The fix is `/allusers`
  or `/currentuser` alongside `/S`; `/allusers` is the default for a System-context Intune install, and
  `/currentuser` moves the detection rule into the user profile. The observed exit code is recorded as
  one data point, not a signature - the reliable tell is the shape: genuine NSIS, sub-second exit, no
  output, nothing written. It is now a **Gate 2** decision.
- **An external runtime prerequisite is researched in Phase 2 and decided at Gate 1** (phase 1.4, rule
  `runtime-prerequisite`). A package can pass every gate GREEN while the installed app is inert, because
  no phase in this skill ever launches the application: Phase 5 parses it, Phase 6 drives the detection
  script, Phase 11 watches the delivery. Options: separate package + Intune app dependency
  (recommended), bundle it, document as manual, or skip - recorded either way.
- **A manual interactive test is offered after a GREEN Phase 6 verdict** (phase 6.4), situationally -
  for an unfamiliar app or vendor, anything flagged in 1.4, or the first package of a new app family.
  GREEN means the package installs, detects, uninstalls, reinstalls and repairs. It does not mean the
  app works: a missing runtime, a first-run wizard, an absent licence and a broken default config all
  leave it GREEN.

### Notes
- Suite 484 -> 493.
- SKILL.md gained four control-plane decisions and stayed inside the compaction budget by **moving three
  blocks into the appendices that already own them**, not by shortening anything: the driver decision
  tree to App. Q.1, the sandbox route detail to phase 6.1, and the per-action loop to phase 6.2 (which
  never carried it - it existed only in SKILL.md). Phase 6 ends at byte 17 456 of 17 500.

## 0.27.1 - 2026-09-10 - The dossier described a package that did not exist

### Fixed
- **`New-PsadtReport.ps1` invented facts about the package when they were not supplied, and printed
  them as statements.** Found while packaging two real apps to test 0.27.0. A dossier generated
  without `-Metadata` claimed, in the document an approver reads before shipping:
  - **`_Beschreibung folgt._`** as the Company-Portal app description. That text is copied into
    Intune verbatim. It is not an empty state - it reads like a finished sentence, survives review
    and ships to every device in the assignment.
  - **`Start-ADTMsiProcess`, `Remove-ADTApplication`, "Nutzerdaten bleiben erhalten"** as the hook
    contents, and a four-cmdlet list, for whatever package was being reported on. A WinMerge package
    driven by `Start-ADTProcess` with Inno Setup switches was described as calling
    `Start-ADTMsiProcess` four times. Nothing marked the list as a guess.

  The file already stated the correct rule for itself - *"Default = NOT RUN (neutral) - same honesty
  rule as pre-flight: no synthetic Success rows"* - and the identity guard already refused with *"a
  dossier without a real app identity is a placeholder, not a deliverable"*. The rule simply had not
  been applied to the fields that describe the package's content.

  Now:
  - The **hooks and the cmdlet list are read out of the launcher** by AST, per `*-ADTDeployment`
    function, in source order. No launcher to read means `nicht ermittelbar / not derivable`, not a
    plausible list. An explicit `-Metadata` value still wins.
  - A **missing description warns** and renders an unmissable marker, and **refuses outright** when
    `decisions.upload = true` - the same shape as the existing SYSTEM-test gate. `-AllowMissingDescription`
    is the deliberate, visible opt-out, like `-AllowDefaultLogo` on the upload script.
  - The **header status is derived** from the pre-flight and SYSTEM-test evidence instead of
    defaulting to `Upload-bereit - getestet`. That default was a landmine rather than a live bug: the
    template does not currently render `{{STATUS_DE}}`, so nobody ever saw a dossier claim "tested"
    while stating "no SYSTEM-test results supplied (no evidence)" three sections lower. It would have
    gone live the moment the token was wired up.

- **`SKILL.md` Phase 8 did not say the description was mandatory.** It said "App description =
  Markdown, dossier language, real umlauts" - a formatting rule for a field it never said had to be
  supplied. It now says the report refuses without it, and that the hooks and cmdlets are derived
  rather than authored.

### Notes
- Suite 474 -> 484. The new cases assert the absence of each invented value, that the derived cmdlet
  list matches a launcher that calls `Start-ADTProcess` and not `Start-ADTMsiProcess`, and that the
  upload path refuses and writes no file.
- One pre-existing test needed a description added: an upload now has to clear two gates, not one.

## 0.27.0 - 2026-09-10 - Half the control plane was gone after the first compaction

### Fixed
- **After auto-compaction, SKILL.md lost everything from the middle of Phase 2 onwards.** Claude Code
  re-attaches only the **first 5000 tokens** of an invoked skill after a summary. SKILL.md was ~10900
  tokens, so that cut fell at line 198. In exactly the sessions long enough to compact - a difficult
  package, a long troubleshooting run - the skill silently lost Phases 3-12, the entire troubleshooting
  table, every anti-pattern and the reference map. The half that prevents mistakes was the half that
  disappeared, and nothing about the file made that visible.

  The fix is ordering, not size. Ahead of the cut: the operating mode, the four decision gates, the
  binding conventions and Phases 0-6 - where software first runs as SYSTEM and where every upload is
  gated. Behind it: Phases 7-12, the sub-agent roles, self-update, the troubleshooting pointer and the
  reference map, all of which cost a fetch rather than a mistake when they are missing. **Phase 6 now
  ends at byte 17457 of a 17500-byte budget** (462 -> 353 lines, 40982 -> 28634 bytes), and
  `tests/SkillContextBudget.Tests.ps1` fails if it ever crosses back.

- **`--ref <tag>` returned HTTP 404 on the tarball route.** `bin/install.mjs` built the download URL as
  `tar.gz/refs/heads/${ref}`, and `refs/heads` only resolves *branches*. Pinning therefore worked on both
  git routes and failed on the one a machine without git actually uses - which is the machine most likely
  to need a pinned release. The 404 handler then blamed repository visibility. Both routes now select
  `refs/tags` or `refs/heads` by what the ref is. `scripts/Update-PsadtSkill.ps1` had the same latent bug
  in its archive apply path (`archive/refs/heads/<tag>.zip`) and is fixed with it.

- **A failed install exited 127 instead of 1, with a libuv assertion after the error message.**
  `process.exit()` while Node's `fetch` still holds a pooled socket aborts the process. A mistyped
  `--ref` printed a correct explanation and then looked like an installer crash, and any wrapper reading
  the exit code got the wrong number. The installer body moved into `main()`; failures unwind instead of
  exiting.

- **Two documentation pointers had rotted.** `SKILL.md` said "Appendix A-P" while Appendix Q existed and
  was referenced three times, and `scripts/New-PsadtReport.ps1` pointed at "SKILL.md Appendix F" -
  SKILL.md has no appendices at all. Neither was caught, because the existing guard only checked that
  SKILL.md does not reference a *missing* appendix, and never looked at `scripts/`.

- **The README claimed 326 Pester tests.** It had claimed that for several releases; the suite was at 441.

### Changed
- **The default install is now the newest release tag, not `main`.** This skill registers an Entra
  application with admin consent and writes to an Intune tenant. Installing whatever last landed on a
  branch is not a defensible default for that. `--ref main` is still available as an explicit choice, and
  `--ref v0.26.7` pins. When the tag list cannot be read the installer falls back to `main` and says so
  rather than pretending to have pinned something. Tags `v0.26.2` through `v0.26.7` existed only as
  changelog entries and are now tagged at their commits; the 45 older versions cannot be, because 51
  versions live on 13 commits.

- **The update check now asks what an installation follows.** With pinning as the default, most
  installations sit on a tag, and the old commit-versus-`main` comparison would have reported every one
  of them as "behind" whenever an unreleased commit landed - the opposite of what pinning is for. A
  release-pinned installation is compared against the newest release tag and reports `Behind` as a count
  of *releases*; a branch installation behaves exactly as before. `Track`, `LocalRef` and `RemoteRef` are
  new on the result object.

- **The 2942-line deployment guide became nineteen files**, one per domain, with `references/README.md`
  as the map. Section numbering is unchanged, so every "App. L.1", "Phase 6.2" and "F.4" in the docs and
  in ten scripts' comment-based help still resolves.

- **BEHAVIOUR CHANGE: Phase 11 no longer re-runs Phase 6.** Both phases told the agent to run
  Install/Uninstall/Repair as SYSTEM and both reached for `Invoke-PsadtSystemTest.ps1`, which reads as
  "pass the gate, upload, then do it all again". They are now disjoint by what they can observe: Phase 6
  answers *does the package work* (the gate, in a throwaway Sandbox), Phase 11 answers *does the delivery
  work* (one Intune test group, a real device, `AppWorkload.log`, `Close-ADTSession` exit 0, Company
  Portal). A package that passes Phase 6 and fails Phase 11 therefore has a delivery or detection
  problem, not a script problem - a distinction that was not available before. Nothing was deleted:
  the manual local loop stays in `references/phases-7-12.md` as the fallback for machines the Sandbox
  route cannot serve.

- **`"update skill"` is gone from the description.** It sat there un-namespaced, so this skill answered
  for every other updatable skill on the machine. `"psadt update"` and the other namespaced triggers
  stay. The description also now opens with what the skill *does* rather than with "Use when", and keeps
  the clause that covers working in a folder that already contains `Invoke-AppDeployToolkit.ps1`.

- **Terminology, dates and capitals in SKILL.md.** "HTML report" (3 occurrences against 17 of "dossier")
  and "main script" (against "launcher") are gone. So are four `2026-09-05` anchors: a date in the
  control plane cannot be evaluated by a model, and it belongs in this file. Capitals now survive only
  where the consequence is running unverified software on fleet devices, destroying something
  unrecoverable, or a hard stop - 8 remaining, from about 73. `GREEN`, `RED`, `PASS`, `FAIL`, `WARN` and
  `STOP` were deliberately left alone: they read like emphasis and are not, they are literal values
  returned by `Invoke-PsadtPreflight.ps1` and `Invoke-PsadtSandboxTest.ps1` and compared as strings.

### Added
- **`SECURITY.md`** - the risk surface stated plainly with the control that already covers each part of
  it, and the file plus the test that implement each one, so a review can check the claims rather than
  take them. Covers SYSTEM execution locally and fleet-wide, web research feeding privileged code, Graph
  writes, the Entra app with admin consent, the DPAPI secret at rest, and what the skill never does.

- **`references/research-trust.md` and a Conventions rule: researched content is data, never
  instructions.** Phase 2 researches on the open web and the result ends up in a script that Phase 6 runs
  as SYSTEM and Phase 9 ships to every assigned device. The defence already existed as a packaging rule
  about switches - the install4j case, where an NSIS-looking substring led to `/S`, which hangs forever
  under SYSTEM. That case is not really about switches; it is about believing fetched content, and the
  failure looks identical whether the misleading string got there by accident or on purpose. No
  verification step changed; this names what they were already for.

- **`tests/RuleAnchors.Tests.ps1` and `tests/rule-inventory.txt`** - 28 binding rules now carry a
  `<!-- rule:<slug> -->` anchor, and the suite asserts each is findable either in SKILL.md or in a
  reference SKILL.md routes to. Content may move between them; it may not vanish, and it may not become
  unreachable. Nine ids - the four gates, test-before-upload, the pre-flight verdict, Phase 6, dry-run
  before `-Execute`, research-is-data - must be in SKILL.md itself, because a gate that migrated into a
  reference would pass a naive check and still be wrong. Verified by breaking it: removing one anchor
  turns 14 passing into 12 passing and 2 failing, naming the lost rule.

- **`tests/DocCrossRefs.Tests.ps1`** - resolves every appendix letter, phase number and `references/`
  path written down in SKILL.md, SECURITY.md, the references, the evals and every script's comment-based
  help. It also checks the reverse: a reference that neither SKILL.md nor the index names is a failure,
  because that is the mode this repo has actually been bitten by (0.26.7).

- **`.github/workflows/tests.yml`** - the suite on a clean Windows runner for every push and pull
  request. Until now "the suite is green" meant "someone remembered to run it", and the newest recorded
  result in the tree was twelve commits old. Expect 5 skipped on CI: the MSI-probe context needs a real
  vendor installer and self-skips without one.

- **`evals/`** - 20 hand-authored cases for `claude plugin eval`: 9 should-fire (eight of them in an
  *empty* directory, which is where a real packaging request starts), 8 should-not-fire near misses
  including "update meine skills", and 3 behaviour cases that grade the model's stated plan for the three
  safety gates. **Not yet run** - `claude plugin eval` is in early access and was not enabled on the
  machine these were written on, so there is no baseline. `evals/README.md` says so where someone would
  look for the numbers.

- **`references/conventions.md`** - the long form of every binding rule, with the reasoning and the
  failure it prevents. SKILL.md keeps all 16 in short form with their anchors.

### Notes
- Suite 441 -> 474 tests, all green (436 + 5 skipped on CI).
- `paths` was evaluated for the frontmatter and deliberately **not** set. It reads like the way to make
  "activates in a folder with a PSADT package" deterministic; it is the reverse - it *limits* activation
  to files matching the globs, and would have switched the skill off for the most common request there
  is, packaging an app in an empty folder where `Invoke-AppDeployToolkit.ps1` does not exist yet. All
  five frontmatter omissions are now argued in the README rather than merely absent.
- The presentation website was corrected to match (reference count, the Phase 11 card, test count,
  version). It is a Claude Design export, so those edits also need making in the canvas - see the pending
  drift table in its README.

## 0.26.7 - 2026-09-08 - The control plane did not know MSIX exists

### Fixed
- **SKILL.md never mentioned MSIX, so 0.26.5's research was unreachable.** Appendix L gained L.8 (MSIX/AppX) and
  L.9 (App-V) two releases ago, but the Gate 1 package-type decision still listed only native installer / WinGet /
  script-only / browser-extension / windows-features / driver. A `.msix` therefore fell through to "native
  installer (default)" - the one route that is wrong for it - and nothing pointed at L.8. Content nothing routes to
  is not documentation.

  Gate 1 now carries **MSIX/AppX** as its own package type with the decision attached: **Intune takes a `.msix`
  natively as a line-of-business app** (no switches, no detection rule, no `.intunewin`, cap 8 GB), so the DEFAULT
  is to use that and NOT build a PSADT package. The wrapper is offered only for what the native type cannot do -
  closing processes, removing a legacy MSI/EXE of the same product, importing the signing certificate (App. N),
  per-machine config, dependency packages, or a payload over 8 GB - and if it IS wrapped, L.8 is to be read first,
  because under SYSTEM `Add-AppxPackage` registers the app for the SYSTEM account and still reports success.

### Added
- **`tests/SKILL.Tests.ps1` - a coherence guard for the control plane**, because this drift is structural rather
  than a one-off. Two halves:
  - every `App. <letter>` / `Appendix <letter>` referenced in SKILL.md must exist as a heading in the guide
    (catches a pointer to an appendix nobody wrote);
  - the Gate 1 decision must know MSIX, route it to L.8, and state the native-LOB default (catches research that
    lands in the guide while the router stays blind to it).

  RED first: three of the four cases failed against 0.26.6. The appendix cross-reference was already green and is
  a regression guard, not a fix.
## 0.26.6 - 2026-09-08 - The sandbox timeout killed the window it then told you to close

### Fixed
- **A host timeout was handled like a finished run, and did the one thing the script's own comments forbid.**
  `Invoke-PsadtSandboxTest.ps1` ended its wait loop in one of three states, but treated them all alike. Two are
  harmless: DONE.txt written (the guest shut itself down) or the VM already gone. The third - the HOST giving up
  while the guest is still working - then went through the same teardown, which force-kills every viewer process.
  Two consequences, both bad:
  - It **orphans `vmmemWindowsSandbox`**. The Hyper-V compute service owns that worker, so the host cannot
    terminate it; it keeps holding the mapped work folder, and the NEXT run of the package throws on the locked
    folder instead of starting. The script documents this exact mechanism as the reason the guest must shut
    itself down - and then did it anyway on the timeout path.
  - It **destroys the only remaining way out**. After the viewer is killed there is no window left, yet the
    warning read *"close the window by hand"* - advice the user cannot act on.

  The script now computes `$hostTimedOut` BEFORE any teardown and, on a timeout, deliberately touches nothing:
  it explains that the VM is still running, why killing it from the host would make things worse, that closing
  the Windows Sandbox window and confirming the discard prompt is what releases the folder, and that
  `-TotalTimeoutMinutes` is the knob if the package simply needs longer.
- **The warning named a timeout the code did not wait.** It claimed 60 seconds while `Stop-SandboxInstance`
  waited 180 - a literal in a message duplicating a parameter default, which is why the two had drifted. Both
  now read `$sandboxStopTimeoutSeconds`, declared once.

Four Pester cases cover it (RED first: all four failed against the old script), including the two that encode the
contract rather than the wording - that a timeout is told apart from a finished run, and that the teardown branches
on it.

### Documentation
- **Appendix G finding 6 is corrected rather than left standing.** It claimed there is "no recovery path" when a
  run is aborted, which was true for the whole class before this fix. Now scoped: the case the script controls
  (its own timeout) is handled, and a run killed from OUTSIDE the script (Ctrl+C on the host) remains the
  un-recoverable one. The mechanism - the compute service owning the worker - is stated where it belongs.
## 0.26.5 - 2026-09-08 - MSIX installs for nobody when SYSTEM makes the obvious call; App-V is not end of life

### Documentation
- **L.8, new: MSIX/AppX is a deployment model, not a switch set** - verified against Microsoft Learn AND against
  the live cmdlets on Windows 11 26200, because the parameter names in circulation are wrong as often as not.
  The section is built around the two-step model (machine-wide **staging** into `%ProgramFiles%\WindowsApps`,
  then **per-user registration** at logon by the App Readiness Service), from which every trap follows:
  - **`Add-AppxPackage` under SYSTEM registers the package for the SYSTEM account and reports success.** Intune
    and the Phase 6 SYSTEM test both run as SYSTEM, so the obvious cmdlet produces a package that installs
    "successfully" and that no interactive user can launch. The device-context call is
    `Add-AppxProvisionedPackage -Online`.
  - **`Get-AppxPackage` is the wrong detection cmdlet and fails silently.** Right after provisioning the package
    is staged but registered for nobody, so a SYSTEM detection script finds nothing, Intune concludes "not
    installed", and reinstalls on every check-in forever while the app works fine for every logged-on user.
    Detect with `Get-AppxProvisionedPackage -Online`, or `Get-AppxPackage -AllUsers` for registration truth.
  - **Uninstall is asymmetric, in Microsoft's own words:** de-provisioning means packages "will not be removed
    from existing user accounts". An Uninstall hook that only de-provisions leaves the app fully working for
    every user who has already logged on. A complete removal is `Remove-AppxProvisionedPackage -Online` **plus**
    `Remove-AppxPackage -AllUsers`.
  - **Signing: the certificate Subject must equal the manifest Publisher**, which is why a vendor MSIX cannot
    simply be re-signed with a corporate certificate - the manifest has to be edited and the package repacked.
    Self-signed/internal certs must land in `LocalMachine\TrustedPeople`, which is the Appendix N machine-store
    problem again (Custom OMA-URI, not the built-in template). And **missing timestamping** is what turns an
    expired certificate into "installed fine last year, fails on new devices today".
  - Plus the decision that comes first: **usually do not wrap MSIX in PSADT at all.** Intune takes it natively
    as a Line-of-business app. Wrap only for process-closing, legacy-version removal, certificate import,
    per-machine config, dependency packages - or a package above the **8 GB** LOB cap (Win32 allows 30 GB).
- **L.9, new: App-V's support position, corrected.** "App-V is end of life" is the claim in circulation and it
  is wrong. The **client and sequencer are no longer deprecated** - they moved to *fixed extended support*, keep
  shipping in Windows, have **no new end-of-support date**, and cost nothing extra; only design changes and new
  features are off the table. The **server components** remain deprecated and end **April 2026** (MDOP extended
  support ends 14.04.2026). Microsoft's own guidance is that an estate whose feature set still works needs no
  migration. Also recorded: `Add-AppvClientPackage` alone publishes to nobody, `-Global` is the device-context
  switch (without it a SYSTEM publish targets SYSTEM), and a package that is **in use** goes *pending* rather
  than failing - where a global task applies only after a **shutdown and restart**, so a `-Global` upgrade of a
  running app has not taken effect when the hook returns.

### Changed
- **The MSIX row in L.2 was actively misleading and is rewritten.** It listed `Remove-AppxPackage` as the
  uninstall (leaves the provisioned package behind) and "package name / version" as the detection (the trap
  above). It now carries the full pair for uninstall, the correct detection cmdlet with an explicit NOT, and
  the SYSTEM caveat.
- **L.2 gains an App-V row**; L.1's MSIX fingerprint now names what is actually inside the package
  (`AppxManifest.xml` with `<Identity>`, `AppxBlockMap.xml`, `AppxSignature.p7x`) and points at L.8 before any
  hook gets written.
## 0.26.4 - 2026-09-08 - Inno Setup reboots by itself, an NSIS uninstall returns too early

### Documentation
- **L.7, new: the two open-source engines each hide one packaging-breaking behaviour.** Both verified
  against the vendor documentation rather than written from memory - the switch table had one line each,
  and neither line carried the part that matters.
  - **Inno Setup `/VERYSILENT` reboots the machine on its own** when a restart is required, without
    prompting. Under Intune that is an unannounced SYSTEM-context reboot mid-workday. `/NORESTART` is
    therefore mandatory, not optional - and `/RESTARTEXITCODE=3010` turns "a restart was needed" into
    exactly the code Intune already reads as a soft reboot, instead of the installer either rebooting or
    hiding the fact. Also recorded: `/SUPPRESSMSGBOXES` is ignored without `/SILENT` or `/VERYSILENT`,
    `/SP-` only suppresses the startup prompt and is not a silent switch, `/NOCLOSEAPPLICATIONS` keeps Inno's
    restart manager from fighting PSADT's own `-CloseProcesses`, and `/LOADINF` / `/SAVEINF` capture a
    complex option set the way an InstallShield `.iss` does.
  - **`Uninstall.exe /S` in NSIS returns BEFORE the uninstall has finished.** The uninstaller copies itself
    to temp and re-launches so it can delete its own folder, so the process you started exits immediately -
    and any Post-Uninstall verification races a still-running uninstall. The documented fix is the
    `_?=<installdir>` parameter, which suppresses the copy and makes the run synchronous; it must be LAST
    and unquoted even with spaces in the path, and it leaves `Uninstall.exe` behind for the package to
    remove. Also: `/D=` must be last and unquoted (quoting it is the usual reason a "silent" install still
    lands in the default directory), and `/NCRC` is ignored rather than honoured when the script used
    `CRCCheck force`.

### Changed
- **Advanced Installer is now in L.1 and L.2, not only in L.6.** 0.26.3 added the project-side section but
  never wired the engine into the identification list or the switch table. The fingerprint is measured, not
  guessed: an `AI_*`-heavy `CustomAction` table referencing `aicustact.dll`, with
  `SecureCustomProperties = OLDPRODUCTS;AI_NEWERPRODUCTFOUND`.
- **The Inno Setup and NSIS rows in L.2 now carry the mandatory switches** (`/NORESTART`, `_?=`) instead of
  the minimal command that looks correct and behaves badly.
## 0.26.3 - 2026-09-08 - Appendix L grows three sections it should always have had

### Documentation
- **L.4 MSP patches**, verified against Microsoft Learn rather than memory. The full option matrix
  (`/p` on an installed product, `/p` + `/a` on an administrative image, `PATCH=` during an install,
  `/n` for one instance), the rule that `/i` and `/p` may never be combined - patching an administrative
  install being the single documented exception - and that the `PATCH` property is silently overwritten
  when `/p` is used. Two findings that change how patch results should be read:
  - **1642 is ambiguous.** Microsoft's own wording is "the program to be upgraded may be missing, **or the
    upgrade patch may update a different version of the program**". Treating it as a blanket success hides a
    wrong patch revision. Expected and harmless for a feature-scoped bundle; a real defect anywhere else.
  - **`/l*` is not `/l*v`.** The `*` wildcard covers everything EXCEPT `v` and `x`. On the ADK's 172 MB DISM
    patch, verbose logging costs more wall-clock than the patching itself.
- **L.5 WiX Burn bundles**: the built-in action and display switches, why a single ProductCode is the wrong
  detection key (BundleProviderKey instead), and the part that is easy to get backwards - `/layout` is a
  Burn action, but whether it can be narrowed is decided by the bundle's Bootstrapper Application. The
  Windows ADK's BA refuses `/features` together with `/layout` outright, so an offline layout is always the
  whole kit (measured: 1473 MB ADK, 1894 MB WinPE add-on).
- **L.6 Advanced Installer projects**: the `.aip` CLI (`/build`, `/rebuild`, `/edit /SetVersion`,
  `/edit /SetProductCode`, `/execute`), the consequence of a fresh ProductCode per build - the package
  identity changes every time, so the launcher's `-ProductCode`, the detection script and the manifest must
  be re-derived from a fresh `Get-PsadtMsiFacts.ps1` probe - and one behaviour the vendor does not document
  at all: **relative paths in an `.aip` resolve against the .aip's own location**. Moving a project between
  drives silently breaks every relative reference ("Resources referred by the project are missing").
## 0.26.2 - 2026-09-08 - A WHQL driver pack no longer turns the pre-flight red; the generator survives the -File binder

### Fixed
- **`Get-DriverSignatureInfo.ps1` reported validly signed WHQL drivers as `Unsigned`.** `Get-InfValue`
  captured everything after `=` to end of line, and WHQL packs routinely write
  `CatalogFile=foo.cat   ; for WHQL certified`. In INF syntax `;` starts a comment, so the catalog path
  never resolved, the driver classified `Unsigned`, and the whole pre-flight went **RED for a perfectly
  signed pack** - 6 of 70 INF in a Dell WinPE driver set, whose catalogs were all Authenticode-`Valid`
  and signed by `CN=Microsoft Windows Hardware Compatibility Publisher`. An unquoted `;` now ends the
  value; a `;` inside a quoted value is preserved. Two Pester cases guard both, proven against the
  reintroduced bug.
- **`New-MsiPackage.ps1` was the sixth script with the `-File` binder trap.** 0.25.1 fixed five scripts
  and missed the generator. `-ProcessesToClose 'a','b'` arrives as ONE element, so the scaffold got
  `AppProcessesToClose = @('''a'',''b''')` - a single nonsense process name.
  `Show-ADTInstallationWelcome -CloseProcesses` then closes NOTHING and still reports success, so the
  install proceeds against a running application. Now expanded via `Expand-CommaSeparated`, like the
  other five, with three tests including one that asserts the expansion happens BEFORE the literal is
  built.

### Documentation
- **Appendix G gains the 2026-09-08 entry** (BootForge + Windows ADK + WinPE add-on, three packages in
  one dependency chain): the two bugs above, plus five findings that are limitations rather than defects -
  the sandbox harness cannot test a heavy package at all (`ActionTimeoutSeconds` caps at 3600, and after
  a timeout the following steps are artifacts, not results); a package with a hard prerequisite is not
  sandbox-testable; the SYSTEM test validates the package FOLDER, never the `.intunewin`; aborting a run
  from the host orphans the VM worker with no recovery path; a LocalSystem service's `%TEMP%` is
  `C:\Windows\SystemTemp`, not what the machine environment says; and `C:\ProgramData\<App>` subfolders
  inherit `Users: Write`, so creating one is not the same as owning it.
- **Appendix B gains four anti-patterns**, each of which cost real time: `msiexec /a` against a file
  inside a package payload (it rewrites the source MSI - `0x80091007` on the next install); `-Include`
  with `-LiteralPath -Recurse` (silently ignored, returns every file); comparing paths by string prefix
  when one side may be an 8.3 short name (`Resolve-Path` does not expand it); and reading a stack trace's
  PDB path as evidence about the source tree instead of comparing mtimes.
## 0.26.1 - 2026-09-06 - Click the row to copy; the template's JavaScript is now tested

### Fixed
- **A syntax error in the template silently disabled the ENTIRE dossier script.** A patch turned a `
`
  inside a JS string literal into a real newline. JavaScript discards the whole `<script>` block on a parse
  error, so the language toggle, every copy button and the condensing sticky header stopped working at
  once - and the document still looked finished. Every one of the 419 tests stayed green, because they
  assert on rendered HTML strings and never check that the script in it loads.
- **`tests/Report-Template.Tests.ps1`** now guards exactly that: `node --check` on the extracted script
  block (skipped where node is absent), a node-free quote-balance check that catches this specific
  breakage, an assertion that every interactive feature is still wired at boot, and one that the
  sticky-header logic survives. Verified by reintroducing the bug: two guards fail.

### Changed
- **Every table copies by clicking the row.** One interaction for the whole document, replacing the 24px
  hover icon that was a poor target for the one value each table exists to hand over. Key/value tables
  give the VALUE, return codes give the CODE, assignments give the GROUP NAME, the SYSTEM-test table gives
  the whole row tab-separated. The row flashes green as confirmation.
  A click on a row's own interactive elements still works - the detection script stays foldable - and a
  text selection is never hijacked by a copy.
  The Markdown description keeps its own "copy" button, and Return Codes keep "copy table".
- **The Graph token moved out of sight into `data-rc-type`.** Printed next to the portal label it read as
  a duplicated word ("Soft reboot softReboot") rather than as two audiences; "copy table" still emits the
  API spelling.

## 0.26.0 - 2026-09-06 - Return codes: one source of truth, validated, sorted, copyable

### Fixed
- **The dossier could name a return-code type Intune does not have.** `win32LobAppReturnCode.type` accepts
  exactly `success`, `softReboot`, `hardReboot`, `retry`, `failed`. There is no `ignored` - yet "Ignored"
  reached a real dossier, because `New-PsadtReport.ps1` rendered a caller-supplied `ReturnCodes` array
  without validating a single field: `Label` was free text and `Cls` was interpolated RAW and UNESCAPED
  into `class="badge $($r.Cls)"`. A dossier is a document somebody configures Intune from, so a wrong type
  in it is a false statement nobody notices.
  The fix is structural, not a corrected value: `Label` and `Cls` are now DERIVED from `Type` through a
  closed switch and can no longer be supplied at all - which also closes the attribute-injection hole by
  construction. An invalid type THROWS, and `ignored` gets its own message explaining that the concept does
  not exist rather than a generic "unknown value".
- **The return-code table is sorted.** By type in Appendix F.4 order, then numerically within a type - so
  the dossier reads in the same sequence as the mandatory table it is verified against and as the portal
  grid it is transcribed into. Previously it rendered in whatever order the caller happened to supply.
- **Return codes are click-to-copy.** The code cell carries a copy icon and the section header a
  "copy table" button, reusing the template's existing clipboard machinery. The bilingual span moved from
  the `<td>` INTO the cell, because `setLang()` assigns `el.textContent` to every `[data-de]` element and
  would silently delete an appended button on the first DE/EN toggle - a failure that only shows on click.
  `setLang` now preserves element children as well, protecting the SYSTEM-test and assignment tables from
  the same trap, and `addFieldCopyButtons` gained the `<thead>` guard it always needed.

### Added
- **`scripts/Get-PsadtReturnCodes.ps1`** - the canonical table, read by BOTH the dossier and the upload.
  `-Custom` merges installer-specific codes over the mandatory rows (never replacing them: a package that
  fails to map 60001/60008 reports its own crashes as success); `-AsGraphBody` projects to the win32LobApp
  shape. Accepts the portal wording as well as the Graph token, and both PascalCase hashtables and the
  camelCase objects that come out of the manifest JSON.
- **`Invoke-IntuneWin32Upload.ps1 -ReturnCodes`** - until now the installer-specific codes that Appendix
  F.4 tells the operator to research could only ever be *documented*; there was no way to get them into the
  app. Resolved BEFORE the token is acquired, so a bad code fails at validation time instead of after
  authenticating against the tenant.
- **Manifest key `research.returnCodes`** (`{ code, type, de, en }`), read by both, so the codes are
  written down once and the document and the app cannot disagree.
- 31 tests (419 total), including six regression guards each verified to FAIL when its bug is reintroduced,
  and a cross-script test that generates a dossier and a Graph body from the same input and asserts the
  code sequences match - "report and upload agree" as a checked property rather than a coincidence.

### Changed - BREAKING for callers passing a full custom table
`-Metadata ReturnCodes` now MERGES OVER the mandatory Appendix F.4 table instead of replacing it. Pass only
the installer-specific extras. This is deliberate: dropping 60001/60008 was never a legitimate choice.

## 0.25.2 - 2026-09-06 - No error dialog left on the desktop after a sandbox run

### Fixed
- **The Windows Sandbox client left a connection-lost dialog behind.** The guest shuts itself down at the
  end of a run; the client is an RDP-style viewer, so the session drops out from under it and it puts an
  error box on the user's desktop plus a lingering `WindowsSandboxRemoteSession` process. Nothing was
  broken, but an unattended packaging run has no business littering the desktop. The host now disposes of
  the viewer (`Stop-SandboxInstance`) as soon as `DONE.txt` appears.

### Notes - the wrong fix, and why it was wrong
The obvious move was to stop shutting the guest down and let the host kill the VM instead. Measured: that
ORPHANS the `vmmemWindowsSandbox` worker. Client processes vanish, the worker survives - it cannot be
terminated, the Hyper-V compute service owns it - and it keeps the host's mapped work folder open for
minutes, so the cleanup then reports a failure it could not have avoided. The folder was still locked long
after the run and only cleared when a later, correct run tore its VM down properly.

So the division of labour is not interchangeable, and the code says so:
- the **guest** shuts itself down, because only that tears the VM down cleanly and releases the mapped folder;
- the **host** kills only the **viewer**, which is the thing showing the dialog;
- `WindowsSandboxServer` is deliberately NOT killed - it supervises the teardown;
- the wait is on `vmmemWindowsSandbox`, which does NOT match `WindowsSandbox*` and is the process actually
  holding the folder. `vmwp` is deliberately not waited on: it is shared with every other Hyper-V guest on
  the machine (WSL, a dev VM) and may legitimately never exit.

This was only visible because 0.25.0 made the script report the work folder from `Test-Path` instead of
from a flag. A cleanup that assumed its own success would have hidden it.

- A stale work folder that cannot be removed at the start of a run now fails with a message naming the
  orphaned worker and the fact that a reboot clears it, instead of a bare "used by another process".
- Six regression tests pin the division of labour. Suite: 388 passed.
- Verified end to end: GREEN, no leftover processes, work folder removed on the first attempt.

## 0.25.1 - 2026-09-06 - Array parameters survive the `-File` binder

### Fixed
- **`-Intents required,available,uninstall` failed at bind time.** `pwsh script.ps1 -Intents a,b` uses the
  `-File` binder, which hands the whole string over as ONE array element. The `[ValidateSet]` on
  `Invoke-IntuneAppAssignment.ps1 -Intents` then rejected it with *"the argument
  'required,available,uninstall' does not belong to the set"* - an error naming a value the caller never
  typed. The parameter now carries no ValidateSet, splits the list itself, trims and lower-cases the parts,
  and still rejects a genuinely unknown intent BY NAME (`Unknown intent(s): bogus. Valid values are: ...`).
  Hit while assigning a real app in a live tenant; the trap is the one already recorded in Appendix G for
  `[int[]]` parameters, so the documented workaround existed and the affected script did not apply it.
- **`Invoke-PsadtSandboxTest.ps1 -Paths*` had the same trap with a worse failure mode.** `-PathsAbsentAfterInstall a,b`
  asserted only `a` and still reported GREEN - a silent loss of coverage rather than an error. All three
  `-Paths*` parameters now expand comma-separated values.

### Changed
- Guide Appendix M.4 and SKILL.md Phase 10 state the binder rule at the invocation, with the real-array
  `-Command` form for values that genuinely contain a comma.
- Six regression tests added (4 on the intents parameter, 2 on the sandbox paths). Suite: 382 passed.

### Notes
Verified against the exact invocation that failed: the `-File` form now resolves all three intents, the
`-Command` array form still works, and `-Intents required,bogus` is rejected with a message that names the
offending value and lists the valid ones.

## 0.25.0 - 2026-09-05 - One MSI probe instead of eight, and the sandbox stops leaving litter

### Added
- **`scripts/Get-PsadtMsiFacts.ps1`** - reads everything a packaging decision needs out of an MSI in ONE
  pass: identity, Authenticode status, SHA256, features with component counts, DECODED upgrade flags,
  shortcuts, directories, file versions, registry rows and the Icon table. `-AsText` prints the readable
  dump; without it you get an object to feed the manifest and the dossier.
  - This is the probe that decides how a package is built. On two real MSIs it is what surfaced Notepad++'s
    `AutoUpdaterFeature` (so `ADDLOCAL` replaces post-install cleanup), PuTTY's `DesktopFeature` at Level 2,
    and `MigrateFeatures` on both upgrade rows - the flag that means `ADDLOCAL` alone is not enough.
  - Four load-bearing details, each a real failure while the same probe was written by hand four times:
    `OpenDatabase` must be a DIRECT method call (`InvokeMember` throws `DISP_E_TYPEMISMATCH` against the
    Windows Installer automation object); `Execute`/`Close` return `$null` that must be swallowed or the
    caller indexes into it; rows are PSCustomObjects with named columns, never nested arrays (which break
    only when a table has exactly one row); and `OpenDatabase` is retried, because a freshly downloaded MSI
    can still be held by the on-access scanner. Every table except `Property` is optional.
- **`tests/Get-PsadtMsiFacts.Tests.ps1`** - 15 tests: guards, five regression guards on the code, and
  functional tests against any real MSI found on the machine (skipped when there is none). Each regression
  guard was verified to FAIL when its bug is reintroduced.

### Fixed
- **The sandbox test left its work folder behind - one per app, under the config home, forever.** Worse,
  the EVIDENCE lived there: `result.json` and the PSADT logs, with the manifest pointing into a profile
  directory. `Invoke-PsadtSandboxTest.ps1` now copies result.json, the PSADT logs and the `.wsb` into
  `<outputRoot>\<Stem>\SandboxTest\` - beside the dossier and the detection script, and deliberately NOT
  into the package folder, which is what IntuneWinAppUtil packs. The log paths are appended to
  `artifacts.logs[]`, and the scratch folder is then removed. `-KeepWorkFolder` keeps it; a run that fails
  before producing a result keeps it automatically, so a failure stays investigable.
- **The test suite wrote into the REAL config home.** `Invoke-PsadtSandboxTest.Tests.ps1` now points
  `PSADT_DEPLOY_HOME` at a temp directory, with a test that asserts the work folder actually lands there.

### Changed
- **Phase 2 in SKILL.md**: for an MSI, the probe IS the research - run `Get-PsadtMsiFacts.ps1` before
  web-searching anything.
- **Guide Appendix J** gained the two Wikimedia rules that cost time twice in one session: never guess a
  Commons file name (search the File namespace), and never hand-build a thumbnail URL - only pre-rendered
  widths are served, so `1024px-` returns HTTP 400 where `1280px-` works. Take `thumburl` from the API
  verbatim. The MSI Icon-table fallback now warns that the DIB reader assumes 32 bpp, while older
  installers often carry nothing better than 48x48 at 8 bpp (PuTTY 0.85 does).
- **New anti-patterns**: hand-building a Wikimedia thumbnail URL or guessing a Commons file name; a
  three-agent research fan-out for an app whose vendor ships an official MSI.

### Notes - the lessons, measured (guide Appendix G, 2026-09-05 second entry)
PuTTY 0.85 was packaged straight after the 75-minute Notepad++ run, with those lessons applied:
**13 minutes 45 seconds end to end**, GREEN seven-step SYSTEM test, verified `.intunewin`, finished dossier.
The single biggest factor was that the sandbox test cost ZERO wall-clock time - started the moment
pre-flight went GREEN, it ran while the `.intunewin`, the logo and the dossier were produced.

Two things still went wrong and are now closed: the Wikimedia thumbnail trap was hit AGAIN in the same
session (a mistake repeated inside one session is a missing guard-rail, not carelessness - write it down
the first time), and the MSI probe took four attempts (the second time you write a probe by hand, it is not
a probe, it is a missing script).

## 0.24.0 - 2026-09-05 - The whole Phase 6 loop in a Windows Sandbox, without elevation

### Added
- **`scripts/Invoke-PsadtSandboxTest.ps1`** - runs the COMPLETE SYSTEM-test loop (Install, detection,
  Uninstall, detection, Reinstall, Repair, final Uninstall) inside one throwaway Windows Sandbox, every
  action executed as `NT AUTHORITY\SYSTEM` through a scheduled task. It is now the DEFAULT Phase 6 route.
  - **Needs no elevation on the host and never modifies it.** The per-action `Invoke-PsadtSystemTest.ps1`
    needs an elevated session and installs on the machine it runs on, which is why Phase 6 kept being
    deferred to "a DEV VM later". This one is available in an ordinary packaging session.
  - Every action starts from a machine that has never seen the app, so a pass cannot be an artefact of what
    the previous run left behind.
  - The verdict is keyed on the **detection script** - what Intune actually evaluates - with
    package-specific facts asserted via `-PathsPresentAfterInstall` / `-PathsAbsentAfterInstall` /
    `-PathsAbsentAfterUninstall`.
  - Writes `results.sandboxTest` and one `results.systemTest[]` entry per action to the manifest, and
    copies the PSADT logs back to the host.
  - Guards: `Containers-DisposableClientVM` read through `Win32_OptionalFeature` (WMI, unelevated - NOT
    `Get-WindowsOptionalFeature`, which needs admin), and a refusal to start while another sandbox is
    running, because Windows permits one instance and a second launch silently attaches to the first.
  - `-GenerateOnly` writes the runner and the `.wsb` without launching - for inspection, and the seam the
    test suite uses.
  - Verified end to end on a real package (Notepad++ 8.9.8 x64 MSI): **GREEN, all seven steps, 5 min 58 s.**

- **`tests/Invoke-PsadtSandboxTest.Tests.ps1`** - 20 tests. Six on the guards, three REGRESSION GUARDS on
  the generated runner, the rest on the generated `.wsb`, quoting and parseability. Each regression guard
  was verified to FAIL when its bug is deliberately reintroduced.

### Notes - why the script exists (full write-up: guide Appendix G, 2026-09-05)
Driving deployment actions as SYSTEM and reading their exit codes back looks like ten lines of `schtasks`.
A hand-rolled version hit three bugs, each of which silently destroyed a full VM run and each of which
presents as a timeout or a null-reference minutes after launch, nowhere near its cause:

1. **`echo %ERRORLEVEL%>file` is not what it looks like.** With a single-digit exit code cmd parses
   `echo 0>file`, where `0>` is the **stdin redirection operator** - the file is created EMPTY and never
   receives the number. The space in `echo %ERRORLEVEL% > file` is load-bearing.
2. **File existence is not completion.** The redirection creates the file before the value lands, so
   `Test-Path` is true on an empty file. Poll until the content matches a number.
3. **`Get-Content -Raw` returns `$null` for an empty file, and `$x = [string]$null` is STILL `$null` in
   Windows PowerShell 5.1.** Only `'' + (...)` or a typed variable yields a real empty string. An empty
   file is the NORMAL result here - it is exactly what a correct detection script writes when the app is
   absent - so the harness crashed *because the package was clean*.

Three further process lessons from the same session, also in Appendix G: write the two-second local check
before debugging via a ten-minute VM round-trip; collapse N sequential probes of one artefact (an MSI's
tables, a module's cmdlet signatures) into one script; and run Phase 6 in parallel with Phases 7-8 instead
of after them, since packaging and the dossier do not depend on the verdict.

### Changed
- **SKILL.md Phase 6** now leads with the sandbox route and names the per-action route as the fallback for
  apps the VM cannot host (domain join, TPM, GPU, a reboot to complete).
- **Gate 3 (SYSTEM-test consent)** offers the sandbox first; only the DEV-VM route asks for a snapshot.
  "Skip the test" is explicitly not an option to offer while `decisions.upload = true`.
- **Anti-patterns** gained: hand-rolling the SYSTEM-test harness; debugging through a long job when a local
  check would do; N tool calls against one artefact; serialising Phase 6 after 7-8; and "speeding up" the
  test by disabling Defender or dropping Repair/Uninstall.
- **Guide Phase 6** rewritten into 6.1 sandbox / 6.2 per-action / 6.3 run it in parallel.

## 0.23.1 — 2026-09-04 — Two generators were broken since 0.21.0

### Fixed
- **`New-BrowserExtensionPackage.ps1` and `New-WindowsFeaturePackage.ps1` failed at run time.** The 0.21.0
  change that added the per-run `LogName` put the `$logStem` computation *inside* the
  `$out = $tpl.Replace(...).Replace(...)` chain, which PowerShell reads as `$tpl.$logStem = ...`: valid
  syntax, empty property name, and the generator died with *"The property '' cannot be found on this
  object."* The MSI and driver generators were unaffected.
  - Nothing could have caught it as written: the AST parse check passes on valid syntax, and the generator
    tests inspect the source without executing it. It surfaced the first time the whole 0.19–0.23 chain was
    run against a real package.
  - **Guard added** to all four generator test suites: from `$out = $tpl.` onward, every non-empty line must
    be a `.Replace(...)` continuation, and the log stem must be computed *before* the chain. The guard was
    itself verified against a deliberately broken sample and a good one.

### Notes
- First full end-to-end run of the pipeline on a real package: generator → manifest → per-run `LogName` →
  pre-flight GREEN → named `.intunewin` (10 MB, `SetupFile` + SHA256 verified) → dossier →
  `results.preflight` / `results.package` written back to the manifest.
- The npm package version follows the skill version, so a release means a republish even when only
  `scripts/` changed. That is deliberate: one version number for the whole thing beats explaining which of
  two applies.
- Test suite: 326 → **334** tests, all green.

## 0.23.0 — 2026-09-04 — `npx psadt-deploy-skill`

### Added
- **One-line install.** `npx psadt-deploy-skill` clones or updates the skill into
  `~/.claude/skills/psadt-deploy` and runs the setup doctor. Flags: `--dir <path>`, `--project` (into
  `./.claude/skills`), `--ref <branch|tag>`, `--no-setup`, `--help`. Cloning to exactly the right path by
  hand was the first thing a new user could get wrong.
- **`bin/install.mjs` — zero dependencies.** Node 18's global `fetch` and the `tar.exe` that ships in
  `C:\Windows\System32` are enough; an installer with a dependency tree is an installer that can break for
  reasons unrelated to the skill. Three acquisition routes in order: an existing clone is updated with
  `git pull --ff-only`, otherwise `git clone --depth 1`, otherwise the branch tarball with
  `--strip-components=1` — the last one because plenty of managed machines have no git at all.
- **`tests/Package.Tests.ps1`** — drift guards: `package.json` parses, ships only `bin/`, declares no
  dependencies, points `bin` at a file that exists, and its **version equals the top CHANGELOG entry**. A
  published installer claiming one version while the skill is at another is a support case nobody can
  reproduce. Plus: the installer imports only `node:` builtins and never reads the config itself.

### Changed
- **`Update-PsadtSkill.ps1` tracks `package.json` and `bin/`.** Without that the archive update route
  silently drops them, and the next update on a git-less machine would leave a skill whose installer is
  from an older version.
- **README: the npx one-liner is the documented install**, with `git clone` as the alternative.
  `npx skills add pt1987/claude-code-psadt-skill` keeps working unchanged, because SKILL.md sits in the
  repository root.

### Notes
- **The installer never writes the skill config.** Resolving the config home is `Get-PsadtConfig`'s job
  (explicit `-SkillRoot` > `$env:PSADT_DEPLOY_HOME` > `%LOCALAPPDATA%\psadt-deploy`), and a second
  implementation in JavaScript would drift from it. It spawns `Set-PsadtConfig.ps1` to record the commit
  and `Initialize-PsadtSkill.ps1 -Fix` to provision, and lets those decide. `-JsonPath` rather than
  `-Json` because the doctor's stdout is inherited so the user sees its table live.
- Both PowerShell hosts are launched with `-ExecutionPolicy Bypass`: Windows PowerShell 5.1 defaults to
  `Restricted`, and a GPO can pin `pwsh` to `AllSigned` — either way an unsigned script would not run.
- The package is deliberately tiny: it carries only `bin/`, and the skill itself is fetched from GitHub at
  install time, so an installed skill updates without npm being involved at all. (The package *version*
  still follows the skill version — see the 0.23.1 note.)
- Verified end to end against the published package: the git route (update an existing clone) and the
  git-less route (branch tarball + Windows' `tar.exe`, with the `powershell` fallback for the doctor).
- Test suite: 307 → **326** tests, all green.

## 0.22.0 — 2026-09-04 — Third-party drivers

### Added
- **`scripts/Get-DriverSignatureInfo.ps1` — the driver trust classifier.** Per INF it reads
  `Class` / `Provider` / `DriverVer` / `CatalogFile` from `[Version]` and checks the signature of the
  **catalog**, not the `.sys`: a dual-signed `.sys` reports only its primary signature, which would
  misclassify exactly the drivers that are hardest to get right, and the catalog is what PnP validates
  anyway. Results: `MicrosoftSigned` (WHQL/Attestation publisher or inbox `CN=Microsoft Windows*`),
  `VendorSigned`, `Unsigned` (no catalog / `NotSigned` / `HashMismatch`).
  - **A vendor-signed KERNEL driver is RED, not a warning.** With Secure Boot on (Windows 10 1607+ / 11)
    the kernel loads only Microsoft Dev-Portal-signed drivers. Importing the signer certificate into
    `TrustedPublisher` satisfies the PnP *installation* check and does nothing for Code Integrity — so the
    driver installs, the deployment reports success, and the device never loads it. Selling
    TrustedPublisher as the fix there is the expensive mistake this check exists to prevent.
    `-AssumeSecureBootOff` downgrades it to YELLOW for the real exceptions (in-place-upgraded machines,
    Secure Boot off, cross-signing before 2015-07-29) and demands the reason be recorded in `driverTrust`.
  - **`Unsigned` is a hard stop** with three honest options in English — a signed driver from the vendor,
    vendor-side Attestation signing via Partner Center, or an isolated lab. `testsigning` is not among
    them, and the skill never enables it or disables integrity checks.
- **`scripts/New-DriverPackage.ps1` — the driver package generator.** Classifies **before** it scaffolds
  (a rejected source leaves no half-package behind), defaults `-CertOwner policy|package|none` from the
  classification, and writes `package.type='driver'` plus the whole `driverTrust` decision into the
  manifest. Install stages every INF individually; uninstall resolves the DriverStore's `oemNN.inf` via
  `/enum-drivers` by Original Name + Provider + Version; repair re-adds idempotently. Detection uses
  `Get-WindowsDriver -Online` and compares the **leaf** of `OriginalFileName` (which is a full DriverStore
  path). Four extension helpers: `Add-ADTDriverPackage`, `Remove-ADTDriverPackage`, `Get-ADTStagedDriver`,
  `Import-ADTTrustedPublisherCert`.
- **Guide Appendix Q** — the decision tree, the PnP-install-vs-Code-Integrity distinction, the pnputil exit
  codes, `oemNN.inf` resolution, detection, the installer-bundled-driver tree (a vendor EXE calling dpinst
  internally, e.g. the install4j case in L.1) and the anti-patterns. Anti-pattern 15 points there.
- **Pre-flight check 10 `DriverTrust`** — runs whenever the package ships an `.inf` under `Files\`,
  regardless of `package.type`, because a vendor installer that stages a driver is the case nobody declares
  as a driver package. FAIL on an unsigned driver and on a vendor-signed one whose certificate has no owner
  in the manifest; WARN for a vendor-signed kernel driver. No `.inf` means no row at all.
- **Report: a driver-trust row** (`{{V_DRIVERS}}`) with classification, certificate owner, signer
  thumbprint and one line per INF. A package without drivers gets a neutral "no drivers" row rather than an
  empty cell.

### Changed
- **`New-IntuneTrustedCertPolicy.ps1` is now self-contained**, like the firewall script: it dot-sources
  nothing and reads no config, because it is a deliverable that gets copied to test clients with no skill
  installed. Console helpers, WAM sign-in and Graph error extraction are embedded (a test asserts the WAM
  block is byte-identical to the firewall copy); the config-tenant fallback is deliberately gone.
  Credentials come from outside: `-Interactive`, or
  `-GraphToken (& scripts/Get-GraphToken.ps1).Token`. `-SkillRoot` is kept for call-site compatibility and
  documented as unused.
- **SKILL.md**: `driver` is a Gate-1 package type; Phase 4 says classify-first for an installer-bundled
  driver; the driver anti-patterns and Appendix Q are in the lookup.

### Notes
- **pnputil exit codes are documented, NOT verified here.** `0` / `259` (`ERROR_NO_MORE_ITEMS` — staged, no
  matching device or a newer driver already in use) / `3010`, plus `0xE000022F`
  (`ERROR_NO_CATALOG_FOR_OEM_INF`) and `0xE0000247` (`ERROR_DRIVER_STORE_ADD_FAILED`), are taken from
  Microsoft's documentation. Confirming them against `setupapi.dev.log` on a DEV VM with a real
  vendor-signed printer driver and a real Microsoft-signed USB driver is still open — this entry does not
  claim that verification happened.
- Test suite: 251 → **307** tests, all green.

## 0.21.0 — 2026-09-04 — Package manifest, deterministic packaging, one log per run

### Added
- **`psadt-package.json` — one manifest per package, and the single source of truth for that app.**
  Schema 1 records the identity, the decisions taken at the gates, the research findings, every phase's
  `results.*` and the `artifacts.*`. Read with `scripts/Get-PsadtPackageManifest.ps1` (gaps in `.Missing`,
  never a throw), written with `scripts/Set-PsadtPackageManifest.ps1` (dotted paths, deep merge,
  `-Remove`, and `-Append` for the results arrays). Before this, an app's identity lived in the operator's
  head and in `$meta` arguments — which is how two packages of the same app could disagree about their own
  version.
- **`scripts/Invoke-PsadtPackage.ps1` — one packaging command.** Derives the name from the manifest, packs
  with `-o` pointing at a private temp folder, verifies the archive (`Detection.xml`, content blob,
  recorded `SetupFile`, unencrypted size, SHA256), renames the artifact, copies the detection script and
  the real logo next to it, and records `artifacts.*` + `results.package`.
- **Guide: the missing phase headings.** `## Phase 6` (SYSTEM test), `## Phase 9` (upload) and
  `## Phase 10` (assignment) exist as sections now instead of being mentioned only in passing.

### Changed
- **The `.intunewin` is finally named after the app.** New binding convention:
  `<paths.outputRoot>\<Vendor>_<App>_<Version>_<Arch>\<same stem>.intunewin`.
  **Why:** `-s` is always `Invoke-AppDeployToolkit.exe` and IntuneWinAppUtil names its output after it, so
  every package produced `Invoke-AppDeployToolkit.intunewin`. That generic name reached Intune as
  `win32LobApp.fileName`, and every concurrent upload collided in the same
  `%TEMP%\iwup-Invoke-AppDeployToolkit` working folder. Renaming is safe because the upload reads
  `setupFilePath` from the archive's INNER `Detection.xml` — a test pins that. Existing folders using the
  old `<App[-Version]>` scheme are never touched or renamed.
- **One PSADT log per run.** All three generators now emit
  `LogName = <Vendor>_<App>_<Version>_<Arch>_<DeploymentType>_<yyyyMMdd-HHmmss>.log` in the launcher's
  `$adtSession`. `Toolkit.LogAppend` is `$true` by default in 4.1.8 and the name was fixed, so every run of
  every version appended to one file — by the third attempt a failed install is unreadable. Location stays
  `C:\Windows\Logs\Software` and `LogAppend` is untouched.
- **The generators write the manifest**, so the identity that names the log and the artifact is recorded
  where every later phase reads it. The sanitizing rule exists exactly once
  (`Get-PsadtPackageManifest.ps1 -Identity`) — a second copy would drift and rename an app behind
  everyone's back.
- **Every phase records its own result:** `results.preflight` (pre-flight), `results.systemTest[]` +
  `artifacts.logs[]` (each SYSTEM-test run, appended — Install and Uninstall are two pieces of evidence),
  `results.package`, `results.upload` (app id, content version, portal URL, tenant).
- **Pre-flight: two new checks.** `Manifest` FAILs (→ RED) on a missing, malformed or incomplete manifest —
  the artifact name is derived from that identity, so a package that cannot say what it is cannot be
  packed, reported on or uploaded consistently; the PASS line reports the artifact stem, which is the
  fastest way to catch a wrong version before anything is built. `LogName` WARNs for a pre-0.21 scaffold.
- **`New-PsadtReport.ps1 -ManifestPath`** takes identity and artifact names from the manifest
  (`-Metadata` still overrides every key). The mandatory floor is identity only — `AppName`, `AppVersion`,
  `Publisher`; everything else keeps rendering neutrally, because "report ALWAYS" has to hold for a package
  that is not packed or tested yet. A missing SYSTEM test throws only when `decisions.upload = true`.
- **`Invoke-IntuneWin32Upload.ps1 -ManifestPath`** supplies DisplayName / Publisher / AppVersion /
  Architecture, so the app in Intune carries the same identity as the artifact and the dossier. Explicit
  parameters always win (checked via `PSBoundParameters`).
- **`Invoke-PsadtSystemTest.ps1` picks the right log.** The old filter matched the fixed legacy name only
  and took the newest hit, so a per-run name matched nothing — and worse, a stale legacy log from last week
  could win. `Get-FreshSessionLog` accepts both shapes and requires `LastWriteTime >= the run's start`.
- **Guide Appendix E is numbered by phase** (0.1, 3.4, 7.2 …) instead of carrying a third numbering scheme,
  and says that the manifest's `results` block is the machine-readable form of the same checklist.
- **SKILL.md**: new conventions "Manifest = single source of truth per app" and "Logging: ONE log per run";
  Phase 3 makes the generators the default route; Phase 6 states plainly that it is binding before upload
  and skippable only without one; Phase 7 is now a single script call.

### Fixed
- **`New-BrowserExtensionPackage.ps1` and `New-WindowsFeaturePackage.ps1` had no tests at all.** Both now
  have the same AST/source harness as the MSI generator.
- **A single-element array silently became a hashtable merge.** `-Append` on a results array hit
  PowerShell's unwrapping of one-element arrays (`$x = if (...) { @($v) }` hands back the bare element), so
  appending the second SYSTEM-test run threw on a duplicate key instead of appending.

### Notes
- Test suite: 173 → **251** tests, all green.

## 0.20.0 — 2026-09-04 — Intune access as state, not as a 403

### Added
- **`scripts/Test-PsadtIntuneAccess.ps1` — the read-only access verdict.** Answers before Phase 9 what used
  to be answered by a 403 during it: is the configured app usable, what is it allowed to do, and for how
  long. Reports `TokenOk`, the granted `Roles`, a capability per feature
  (`Upload` / `Groups` / `Configuration`), `CredExpires` / `DaysToExpiry` and actionable `Hints`. Verified
  roles and a `lastVerified` timestamp are cached in the config; `-NoPersist` suppresses that, `-Json` /
  `-JsonPath` are for other tooling.
  - **`TokenOk` and every capability are three-valued on purpose.** `$true` verified, `$false` refused,
    `$null` "could not ask" — and for capabilities `$null` means the token could not be introspected, which
    is **not** the same as "not permitted". Graph tokens are opaque by contract, so conflating the two is
    how a working setup gets declared broken. A `$null` verdict never overwrites persisted state: being
    offline is not evidence that an app lost its permissions.
- **Token introspection in `_GraphCommon.ps1`** — `Get-GraphTokenRoles`, `Assert-GraphRole` and
  `Get-GraphAuthErrorHint`, plus `ConvertFrom-JwtPayload` moved in from `New-PsadtEntraApp.ps1`. Costs **no
  extra Graph permission**: an app-only token already carries its granted roles in the `roles` claim.
- **`references/app-registration.md` section 0 is now THE permission matrix** — every app role with its
  capability and how to grant it, plus the two delegated bootstrap scopes. Guide M.1 and N.4 point there
  instead of repeating it.
- **Guide: Phase 0.4 documents the access verdict**, including the rule to gate on `Capabilities.<X>` before
  Phase 9 / 10 / a cert or firewall policy.

### Changed
- **Consumers assert the role they need before their first write.** `Invoke-IntuneWin32Upload.ps1` and
  `Invoke-IntuneAppAssignment.ps1` check the token first (no request, names the exact missing permission);
  the upload's read probe stays as proof that the permission is effective end to end. Assignment requires
  **both** group roles — an app that creates a group but cannot read its members produces a half-finished
  assignment, and the hint says which half is missing. Both policy scripts get their own embedded variant
  so they stay self-contained (a test asserts the two copies are byte-identical).
- **`Get-GraphToken.ps1`** additionally returns `Roles` and `AuthMethod`, and maps the AADSTS codes that
  actually strand a user — expired secret (7000222), invalid secret (7000215), unknown app (700016),
  unknown tenant (90002), Conditional Access (53003) — to one actionable sentence instead of
  `invalid_client`.
- **`New-PsadtEntraApp.ps1` is stateful and never prompts.** It finds the app by the recorded
  `intune.clientId` (display name only as a fallback), **merges** `requiredResourceAccess` instead of
  replacing it, persists `appObjectId` / `appDisplayName` / `credExpires` / the roles it actually holds, sets
  `uploadEnabled` only once consent is really in place, removes the other credential pointer on a method
  switch, and counts older client secrets instead of touching them. `-Force` is kept as a no-op.
- **`Get-PsadtConfig.ps1`** exposes `IntuneState` (`NotConfigured` | `Configured` | `Incomplete`), derived
  from the checks that already build `.Missing`. Group naming is deliberately excluded — a missing
  `intune.groups.naming` is a Phase 10 concern, not a broken upload path.
- **`New-IntuneFirewallPolicy.ps1`**: its own `Get-InteractiveGraphToken` took `-Tenant` while
  `_GraphInteractive.ps1` takes `-TenantId`. Unified.

### Fixed
- **Re-running `New-PsadtEntraApp.ps1` could revoke permissions.** The reuse branch sent only the roles
  requested in *that* run, so a run without `-IncludeConfigurationManagement` silently dropped the config
  role an earlier run had requested. Now merged, and only PATCHed when something is actually absent.
- **`New-PsadtEntraApp.ps1` blocked every non-interactive caller** with a `Read-Host` confirmation when the
  app already existed. Reuse is the default and nothing is prompted.
- **A credential-method switch left the other pointer behind.** `Get-GraphToken` prefers the certificate
  path, so a leftover `intune.certThumbprint` silently beat a freshly stored secret.
- **`uploadEnabled` was set to `$true` even when consent was still pending**, moving the failure to Phase 9.
- **An undecryptable DPAPI secret produced "Error occurred during a cryptographic operation."** It now says
  what actually happened (DPAPI is bound to the Windows user profile, so a re-installed OS or a copied file
  breaks it) and what to do. Found on this project's own config after a machine re-install.

### Notes
- Test suite: 128 → **173** tests, all green.

## 0.19.0 — 2026-09-04 — Config home + setup doctor

### Added
- **`scripts/Initialize-PsadtSkill.ps1` — the setup doctor.** One idempotent script replaces the Phase 0
  prose wizard. It reports **GREEN / YELLOW / RED** over 13 checks (PowerShell 7, Windows PowerShell 5.1,
  elevation, git, PSAppDeployToolkit, IntuneWinAppUtil, Invoke-CommandAs, Pester, config, legacy config,
  skill tree, pending skill update, Intune access), each with a status and a concrete fix hint — so a
  missing prerequisite is a line in a table instead of a failure three phases later.
  - `-Fix` does everything that needs no decision: migrates a legacy config home, installs the modules,
    downloads the content-prep tool, fills the `language.*` defaults (EN/DE) and records
    `paths.intuneWinAppUtil`.
  - `-Set @{...}` persists user values *before* anything is judged; `-Json` / `-JsonPath` emit the result
    for non-PowerShell callers; `-SkipUpdateCheck` skips the only network call.
  - `.Missing` deliberately lists **only what a human must supply** — `paths.packageRoot`,
    `paths.outputRoot`, `author.person`, `author.company` — never a key the doctor could fill itself.

### Changed
- **Config, secret and tools moved out of the skill folder into a per-user config home.**
  `Get-PsadtConfig.ps1` is now the single resolver: explicit `-SkillRoot` > `$env:PSADT_DEPLOY_HOME` >
  `%LOCALAPPDATA%\psadt-deploy`, and it returns `.Home` / `.DefaultHome` / `.LegacyInUse` alongside the
  config. Every other script derives `config.json`, `secret.dpapi` and `tools/` from `.Home` and no longer
  defaults `-SkillRoot` to the skill folder. **Why:** the old layout lost the whole setup on a re-clone or
  re-install, and broke as soon as a script ran from an output folder.
- **A legacy `config.json` beside `scripts/` keeps working, read-only**, and is reported as
  `LegacyConfig WARN` until `-Fix` migrates it. Migration copies config and secret into the home and
  renames the originals to `*.migrated` — **nothing is deleted** — moves `tools/*`, and rebases a recorded
  `paths.intuneWinAppUtil`.
- **`Set-PsadtConfig.ps1` writes to the resolved home** (creating it on demand) and gained `-Remove` for
  deleting dotted leaves, so a credential switch can clean up `intune.certThumbprint` / `intune.secretRef`
  instead of leaving both behind.
- **`Update-PsadtSkill.ps1`** keeps `-SkillRoot` as the skill *tree* but resolves the config separately
  (tree if it still holds one, else the config home), so the recorded commit is read and written in one place.

### Fixed
- **`New-PsadtEntraApp.ps1` reported the wrong config path** ("Saved to `<skill>\config.json`" plus
  `ConfigPath` in its result object) whenever the config did not actually live in the skill folder. Both now
  come from the resolver.
- **Four config-home tests could not run**: `$script:home` collides with the read-only automatic variable
  `$HOME` (`SessionStateUnauthorizedAccessException`). Renamed to `$script:cfgHome`.
- **`Update-PsadtSkill` tests pin `$env:PSADT_DEPLOY_HOME`** to an empty temp dir, so the machine's real
  config home can no longer leak into a test run.

### Notes
- Test suite: 120 → **128** tests, all green.

## 0.18.1 — 2026-09-03 — Upload: configurable install time limit

### Added
- **`Invoke-IntuneWin32Upload.ps1 -MaxRunTimeMinutes`** — sets `installExperience.maxRunTimeInMinutes`
  (1–1440). `0` (default) omits the field, keeping the Intune service default of 60 minutes and the previous
  request shape unchanged. Raise it for long-running installs (e.g. 240 for an OS in-place upgrade) so the IME
  does not kill them. Eight new tests guard the binding range and the "only when > 0" body shape.

### Notes
- Reconciles a finished change that lived only in the installed working copy back into `main` (same class of
  drift as 0.9.2).

## 0.18.0 — 2026-07-01 — HanseMerkur corporate design + editorial report redesign

### Changed
- **Report/dossier re-themed to the HanseMerkur corporate design** (`references/Report-Template.html`):
  green brand family (`#005E52` / `#00A075`) on a light mint canvas, Metric-Regular/-SemiBold font stack
  (family names only — a locally-installed corporate face is used, else Segoe fallback; **no** web `@font-face`
  fetch, so opening the dossier from a local `file://` no longer triggers CORS console errors).
- **Editorial Data-Report layout.** Flat hairline sections (no drop shadows, 20px radius), oversized
  auto-numbered section headings (CSS counter, `01…13`), an at-a-glance **KPI band** under the hero
  (App-Version · Pre-flight status · Minimum OS · Architecture), and a wider container (1180 → 1600px).
- **Detection script folded away by default.** The rule summary (format, run-as-32bit, signature check) stays
  visible; the full PowerShell detection script now sits behind a collapsed "Detection-Skript anzeigen"
  `<details>` instead of dominating the section.
- **German dossier text uses real umlauts** (`GRÜN`, `für`, `Gerätesoftware`, …). Scripts stay 7-bit ASCII;
  the report carries the umlauts (via UTF-8 / HTML entities).

### Fixed
- **Sticky-header flicker eliminated.** The condensing hero changes height by ~100px; Chrome/Edge
  scroll-anchoring compensated by teleporting `scrollY` across the shrink/grow threshold → an endless
  class-toggle loop that the 30–80px hysteresis could not contain. Added `overflow-anchor: none` (html/body)
  so the collapse is a single smooth shift. Reproduced and verified with Playwright (self-sustained toggles
  at the threshold: 36 → 1).
- **Redundant hero status pill removed.** The verbose multi-line pill overlapped the title / looked cramped;
  the Pre-flight status now lives in the KPI band. The hero keeps only the DE/EN language switch.

### Added
- `New-PsadtReport.ps1` derives a compact KPI pre-flight roll-up (`GRÜN` / `GELB` / `ROT` / `nicht ausgeführt`)
  and exposes it as `KPI_STATUS_DE` / `KPI_STATUS_EN` / `KPI_STATUS_CLS` tokens for the KPI band.

## 0.17.0 — 2026-07-01 — install4j fingerprint + behavioral silent-switch verification

### Added
- **install4j installer fingerprint (Appendix L.1).** Recognise install4j (Java) installers by
  `com/install4j/runtime` / `exe4j` / `i4jparams.conf` / `-Duser.language` strings and a bundled `jre\` in the
  extracted `e4j*.tmp_dir*`. Records that **`/S` is NOT its switch** — passing `/S` shows the language-selection
  dialog and hangs forever; the unattended switch is **`-q`**, and it needs elevation or it stalls. Also sharpened
  the InstallShield fingerprint (`ISSetupStream`, Basic-MSI vs InstallScript).
- **BINDING rule: a single string match is a hint, not proof (Appendix L.1).** Confirm the engine by its
  definitive fingerprint AND **behaviorally verify the silent switch** — run `installer <switch>` once with a
  timeout + window/exit watch (kill on timeout) and confirm exit 0 with no dialog — BEFORE building the package.
- **Trademark-sign gotcha in DisplayName filters (Appendix L.3).** A `(R)`/`(TM)` sign (e.g.
  `Aperio(R) Programming Application`) breaks a literal `-match 'Name'`, so `Uninstall-ADTApplication` /
  `Get-ADTApplication` find nothing and silently no-op; use a tolerant regex (`-match 'Name.*Rest'`).
- **Anti-patterns 13–15 (Appendix B).** Guessing the installer engine from a lone string match without ever
  running it; a trademark sign breaking a DisplayName filter; shipping a driver/cert as a note instead of a
  bundled deliverable (extract the signer `.cer`, import to TrustedPublisher in Pre-Install).

### Changed
- **Appendix L.2 install4j row corrected** (`-q`, elevation, empty QuietUninstallString → append `-q` via
  `-AdditionalArgumentList`, bundled JRE, dpinst driver-cert pre-trust); IzPack split into its own row.

_Driven by real-world friction: an ASSA ABLOY Aperio install4j installer carried a coincidental `nsis` string,
was mistaken for NSIS, and `/S` hung on the language dialog during install._

## 0.16.0 — 2026-06-29 — Dossier stays in sync after script changes + report header layout fix

### Added
- **Dossier auto-sync convention (BINDING).** The "HTML report ALWAYS" convention in `SKILL.md` now states
  that ANY change to the package scripts — launcher, Extensions module, detection script, version/changelog,
  return codes, or a re-packaging — REQUIRES re-checking and regenerating `Intune-Dossier.html` in the same
  pass, on the agent's own initiative, without being asked. A dossier still showing the old version, detection
  logic, hooks, or stale pre-flight/SYSTEM-test results is now classed as a defect; if no dossier exists yet it
  is generated then. (Driven by repeated real-world friction: a fix would land but the dossier went stale.)

### Fixed
- **Report header overlap with longer status text.** In `references/Report-Template.html` the `.pill-lg` status
  badge had `white-space: nowrap` and no `max-width`, so a multi-word status grew leftward as one infinite line
  over the hero subtitle and title (the absolutely-positioned `.hero-status` reserves only a 230px gutter). The
  pill now caps at `max-width: 230px`, wraps (`overflow-wrap: anywhere`, right-aligned, tighter `line-height`),
  and the status dot is pinned to the first line (`align-self`/`margin-top`). Short statuses are unaffected;
  long ones form a compact multi-line badge inside the gutter instead of colliding with the text.

## 0.15.2 — 2026-06-15 — Follow-up: one more stale phase reference

### Fixed (docs)
- A contradiction sweep after 0.15.1 found a residual stale **"Phase 7.5"** in `New-PsadtReport.ps1`
  comment-based help - upload is **Phase 9**. 0.15.1 had only corrected `New-PsadtEntraApp.ps1`. No other live
  stale references remain (verified across all `.ps1`/`.md`; the `exit 1` occurrences left in the guide are
  legitimate prose / the fix-script "couldn't run" guard, not detection paths).

## 0.15.1 — 2026-06-15 — Generator hardening from a self-review (correctness + security)

### Fixed
- **Apostrophe in App name/vendor/author produced an unparseable package.** All three generators now
  single-quote-escape every value embedded in a single-quoted `$adtSession` literal (`AppName`, `AppVendor`,
  `AppVersion`, `AppScriptAuthor`) — so "Bob's App" / "L'Oreal" no longer break the generated script. The MSI
  generator's `-AdditionalArgumentList` and `ProcessesToClose` literals are escaped too (this also closes a
  code-injection path into a script that runs as SYSTEM). The MSI desktop-shortcut path keeps the raw name
  (valid inside a double-quoted string) via a dedicated token.
- **Detection exit-code contract drift.** `New-MsiPackage.ps1` and the WinGet detection example (Appendix I)
  emitted `exit 1` for "not installed"; per the contract (stated in SKILL.md / 8.5 / App. A) that path must be
  `exit 0` + empty stdout (a non-zero exit reads as a detection *error/retry*). Both now `exit 0`. The newer
  Browser/Feature generators were already correct.
- **WSUS-bypass could be left on permanently.** In `New-WindowsFeaturePackage.ps1`, `Set-ADTWindowsUpdateFodAccess`
  now records the prior state of *all* targets before writing any (a partial write is fully reversible), and the
  install/repair hooks call it *inside* the `try` so the `finally` always restores `RepairContentServerSource` /
  `UseWUServer` even if the toggle itself throws.

### Added
- **Pre-flight check 7 (Detection).** `Invoke-PsadtPreflight.ps1` now scans `Detect*.ps1` and WARNs on a
  non-zero `exit` (the "not installed" path should be `exit 0`). WARN-only — does not flip GREEN.
- **Input guards in all three generators:** reject a `$Name` containing path separators or `..` (before the
  `Remove-Item -Recurse` scaffold step), and reject any free-text parameter containing a `__TOKEN__` sequence
  that would corrupt the `.Replace()` templating.
- `New-MsiPackage.ps1` now resolves `$Author` from config when omitted (parity with the other generators) and
  validates `-InstallerPath` exists before scaffolding.

### Fixed (docs)
- Stale `SKILL.md` intro range "Appendix A-M" -> "A-P"; `New-PsadtEntraApp.ps1` "Phase 7.5" -> "Phase 9".

## 0.15.0 — 2026-06-15 — Windows-feature packages (optional features + capabilities / FoD)

### Added
- **`scripts/New-WindowsFeaturePackage.ps1`** — one-call generator for a new opt-in package type: enable
  **Windows Optional Features** (`Enable-WindowsOptionalFeature`, e.g. NetFx3, Hyper-V, WSL, TelnetClient) and
  **Capabilities / Features on Demand** (`Add-WindowsCapability`, e.g. RSAT.*, OpenSSH) — both in one typed list,
  multiple per package. Feature-only (no vendor installer). Writes the launcher (data model + 3 hooks), the
  Extensions module (enable/disable dispatch + WU-FoD access toggle) and the detection script.
- **Guide Appendix P** — model, Phase-2 name/reboot/source research, cmdlet+state reference, generator usage,
  helpers, hooks (3010), detection + Intune wiring, content source (bundled SxS vs Windows Update / WSUS-bypass),
  dossier additions, anti-patterns.
- SKILL.md control-plane: Gate-1 package-type option, Phase-2 research note, anti-patterns, reference-lookup
  line for Appendix P.

### Notes
- **Uninstall reverts** (`Disable-WindowsOptionalFeature` / `Remove-WindowsCapability`); Repair re-enables
  (idempotent). Enable/disable helpers skip features already in the target state.
- **Reboot:** features that report `RestartNeeded` surface **3010** via `$adtSession.SetExitCode(3010)`;
  `-NoRestart` prevents DISM from rebooting mid-install. Detection treats `EnablePending` as not-yet-done.
- **Content source:** bundled `Files\<Source>` via `-Source -LimitAccess` (offline), else Windows Update with a
  **temporary** WSUS bypass (`RepairContentServerSource=2`, `UseWUServer=0`) that records and **restores** the
  exact prior state — reuses the proven pattern from the existing `RSAT-1.0.0` package.
- Verified: generated package passes the Phase-5 pre-flight **GREEN**; enable/disable dispatch + idempotency +
  clean boolean returns and the WU-FoD save/restore (incl. remove-value-that-didn't-exist) validated against an
  in-memory registry sim; generator is 7-bit ASCII-clean.

## 0.14.0 — 2026-06-15 — Browser-extension force-install packages (Edge / Chrome / Firefox)

### Added
- **`scripts/New-BrowserExtensionPackage.ps1`** — one-call generator for a new opt-in package type:
  force-install browser extensions via enterprise **policy registry keys** (no vendor installer, `Files\`
  empty, ESP-safe, no reboot). Each browser then pulls the extension from its own store. Supports **multiple
  extensions per package** across Edge / Chrome / Firefox. Writes the launcher (data model + 3 hooks), the
  Extensions module (4 helpers) and the detection script.
- **Guide Appendix O** — model, Phase-2 store-availability research (per-store IDs: Chrome/Edge 32-char `a-p`,
  Firefox `id@domain` + AMO slug), verbatim registry reference, generator usage, helpers, hooks, the honest
  detection model, dossier additions and anti-patterns.
- SKILL.md control-plane: Gate-1 package-type option, Phase-2 research note, three anti-patterns, reference-
  lookup line for Appendix O.

### Notes
- **Coexistence by design.** The Chromium helper computes the **next free `ExtensionInstallForcelist` index**
  (never hard-codes `1`), dedupes by extension ID, and removes only its own entry — so multiple extension
  packages share the key without clobbering. Firefox merges into the single `ExtensionSettings` JSON keyed by ID.
- **Firefox `REG_MULTI_SZ` trap.** `ExtensionSettings` is written as `REG_MULTI_SZ`; a single-line `REG_SZ` is
  silently ignored by current Firefox (Mozilla bug 1750233).
- Verified: generated package passes the Phase-5 pre-flight **GREEN**; all four helpers validated against a
  scratch registry hive (next-free index, idempotent add, selective remove, `REG_MULTI_SZ` merge incl.
  remove-last cleanup); generator is 7-bit ASCII-clean.

## 0.13.1 — 2026-06-15 — Firewall policy body fixed against the live template (verified 201)

### Fixed
- **`New-IntuneFirewallPolicy.ps1` built a body Graph rejected (400 BadRequest).** Corrected against the live
  "Windows Firewall Rules" template (looked up via the **msgraph skill**, not guessed):
  - the group setting id needs the `{firewallrulename}` token (`vendor_msft_firewall_mdmstore_firewallrules_{firewallrulename}`);
  - the program path is the **direct child** `..._{firewallrulename}_app_filepath` (not a nested `_app` group);
  - action values are numeric: `_action_type_1` = Allow, `_action_type_0` = Block (not `_allow`/`_block`);
  - a template-based settings-catalog policy REQUIRES `settingInstanceTemplateReference` on every instance and
    `settingValueTemplateReference` on each simple/choice value; the profiles **collection** takes the instance
    ref only (a per-value ref is rejected as a duplicate). All template GUIDs are embedded.
  Confirmed by a live **201 Create** against the tenant; the generated body is byte-identical to the accepted one.
- Mirrored the same correct body into the MxManagementCenter self-contained Output deliverable.
- `tests/New-IntuneFirewallPolicy.Tests.ps1` now asserts the template references and the verified option values.

## 0.13.0 — 2026-06-15 — Self-contained firewall deliverable (copy-to-client safe)

### Changed
- **`scripts/New-IntuneFirewallPolicy.ps1` is now fully SELF-CONTAINED** — no dot-sourcing of
  `_GraphCommon` / `_GraphInteractive`, no skill path; the WAM interactive sign-in, the policy body builder
  and console helpers are embedded in the one file. It is copied into an app's Output folder and runs on test
  clients that do NOT have the skill installed (`-Interactive` WAM, or a passed `-GraphToken`). This fixes the
  "Skill script not found … Pass the correct -SkillRoot" failure when the deliverable was run on another machine.

### Added
- **SKILL.md binding convention "Self-contained deliverables"** — anything shipped in an app's Output folder
  must carry everything it needs (no dot-source of skill files, no hardcoded skill/user path, no `-SkillRoot`).
- **`tests/New-IntuneFirewallPolicy.Tests.ps1`** self-containment assertions (no dot-source, no skill path,
  embeds its own WAM) — enforces the convention. Authored test-first (RED->GREEN) per superpowers:writing-skills.

## 0.12.0 — 2026-06-15 — Interactive WAM sign-in for the Intune policy scripts

### Added
- **`-Interactive` (+ `-TenantId`) on `New-IntuneFirewallPolicy.ps1` and `New-IntuneTrustedCertPolicy.ps1`** —
  delegated sign-in via **WAM** (Windows Web Account Manager) so the scripts run with **no app registration**
  (maximum compatibility). No device code. Default path is still app-only via `Get-GraphToken.ps1`; the 403
  hint now also points at `-Interactive`.
- **`scripts/_GraphInteractive.ps1`** — shared WAM sign-in helper (`Initialize-MsalBroker` / `Get-WamToken` /
  `Get-InteractiveGraphToken` + the pinned MSAL version set), dot-sourced after `_GraphCommon.ps1`.

### Changed
- **`New-PsadtEntraApp.ps1`** refactored to consume `_GraphInteractive.ps1` instead of its own inline WAM copy
  (one implementation, no copy-paste drift — the concern called out in `_GraphCommon.ps1`). Behaviour unchanged
  (WAM, device-code fallback retained in the bootstrap only).
- **MxManagementCenter `New-MxMcFirewallPolicy.ps1` deliverable** is now a thin wrapper over
  `New-IntuneFirewallPolicy.ps1` (DRY; inherits `-Interactive` automatically).
- New `-Interactive` dry-run test case in `tests/New-IntuneFirewallPolicy.Tests.ps1`.

## 0.11.0 — 2026-06-15 — Firewall-rules policy + app config-management permission

### Added
- **`scripts/New-IntuneFirewallPolicy.ps1`** — prepares (and optionally creates via Graph) an Intune Endpoint
  Security "Windows Firewall Rules" policy with one program-scoped rule (`-FilePath`, `-Direction In/Out`,
  `-Action Allow/Block`, `-Profiles Domain/Private/Public`). The policy-based way to suppress the first-run
  Windows Firewall prompt for apps that listen inbound (e.g. MxManagementCenter) — a non-admin user cannot
  approve it. Read-only dry-run by default; `-Execute` creates it app-only via `Get-GraphToken.ps1`, and on a
  missing `DeviceManagementConfiguration.ReadWrite.All` (403) prints ready-to-paste manual portal steps.
  New `tests/New-IntuneFirewallPolicy.Tests.ps1` (10 cases: profile mask, rule children, policy body, manual
  steps, dry run).
- **`New-PsadtEntraApp.ps1 -IncludeConfigurationManagement`** — opt-in switch that adds + admin-consents the
  Graph application role `DeviceManagementConfiguration.ReadWrite.All`, so the upload app can create
  config / Endpoint-Security policies app-only (firewall rules **and** the 0.10.0 trusted-cert policy). Mirrors
  `-IncludeGroupManagement`; reflected in the reuse-app PATCH. Off by default.

### Changed
- **`New-IntuneTrustedCertPolicy.ps1`** — its help and the 403 hint now point at
  `New-PsadtEntraApp.ps1 -Force -IncludeConfigurationManagement` as the supported way to grant the role
  (instead of implying manual-only), now that the switch exists.
- **SKILL.md** — Phase-0 setup documents the new `-IncludeConfigurationManagement` switch.

## 0.10.0 — 2026-06-15 — Certificate store deployment (driver-trust / TrustedPublisher)

### Added
- **`scripts/New-IntuneTrustedCertPolicy.ps1`** — prepares (and optionally creates via Graph) an Intune Custom
  OMA-URI configuration profile that places a certificate into a Windows machine store (Root / CA /
  **TrustedPublisher** / TrustedPeople) via the `RootCATrustedCertificates` CSP. The transparent, policy-based way
  to suppress the Windows "install device software?" prompt for installers that stage a 3rd-party driver. Extracts
  the Authenticode signer cert from a signed payload (MSI/EXE/.cat) or loads a raw `.cer`; emits single-line
  base64 + the exact OMA-URI; read-only dry-run, `-Execute` creates the profile, and on a missing
  `DeviceManagementConfiguration.ReadWrite.All` (403) it prints ready-to-paste manual portal steps instead of
  failing. New `tests/New-IntuneTrustedCertPolicy.Tests.ps1` (9 cases).
- **Guide Appendix N** — certificate store deployment: store→mechanism matrix (the built-in Trusted-certificate
  template can't target TrustedPublisher/TrustedPeople — the CSP can), the base64/thumbprint `0x87d1fde8`
  gotchas, the policy-vs-package single-owner rule, Graph permission + manual fallback.
- **Dossier "Treiber-Zertifikat" row** — `New-PsadtReport.ps1` gains a `CertPolicy` metadata field
  (Store/Owner/Thumbprint/OmaUri) rendered in the Requirements card; defaults to "none". `Report-Template.html`
  gains `{{V_CERT_POLICY}}`.
- **SKILL.md** — new binding Convention (certificates into a machine store), a Phase-4 driver-trust touchpoint,
  an anti-pattern (claiming Intune can't do TrustedPublisher / multi-line base64 / dual ownership), and the
  Appendix-N reference.

## 0.9.2 — 2026-06-12 — Reconcile diverged install copy: SYSTEM-test fix, richer report, MSI generator

A separate working copy had drifted from `main`; its genuinely newer parts were merged back into the repo
(the canonical source). The repo keeps the 0.9.0 `_GraphCommon` refactor, unified 0-12 phases and full test
suite; only the items below were brought in.

### Fixed
- **`Invoke-PsadtSystemTest.ps1` crashed at param binding under the WinPS 5.1 re-exec.** The `$SkillRoot`
  default was `Split-Path $PSScriptRoot -Parent`. When the script self-re-execs from PowerShell 7 (Core) to
  Windows PowerShell 5.1 via `powershell.exe -File`, `$PSScriptRoot` can be empty during parameter-default
  evaluation, so `Split-Path` threw `ParameterArgumentValidationErrorEmptyStringNotAllowed` and every SYSTEM
  action returned `ExitCode=EXC, Success=false` ("child produced no result") **before the MSI ever ran** -
  making the mandatory Install/Uninstall gate impossible to pass on a pwsh-7 host. The default is now
  fail-safe: it falls back to `$PSCommandPath` and finally to an empty string (the param is currently unused
  downstream, so an empty value is harmless). No other logic changed.

### Added
- **Per-field copy buttons in the HTML dossier.** `references/Report-Template.html` gains a `file://`-safe
  clipboard path (synchronous `execCommand` first, async Clipboard API as a best-effort bonus) plus a copy
  icon on every Intune value cell, recomputed at click time so it follows the DE/EN toggle. `{{LANG}}` is
  retained so the generator still controls the root language. The token set is unchanged, so the existing
  `New-PsadtReport.ps1` fills the template as-is.
- **`scripts/New-MsiPackage.ps1`** - reusable PSADT v4.1.8 MSI package generator (scaffold + fully-customized
  ASCII `Invoke-AppDeployToolkit.ps1` for Install/Uninstall/Repair + registry detection script). The hard-coded
  `.claude\skills\...` path for `Get-PsadtConfig` was replaced with a `$PSScriptRoot` sibling lookup so it runs
  from any location. New `tests/New-MsiPackage.Tests.ps1` (AST parse, mandatory-param, ASCII, no-hard-path).

## 0.9.1 — 2026-06-12 — Applicability/portability drift cleanup (docs + instructions)

Follow-up to the 0.9.0 audit: a consistency pass found documented behaviour that no longer matched the
implementation. No script logic changed.

### Fixed
- **Dead config keys removed.** SKILL.md Phase 6 described the SYSTEM-test loop as honouring
  `test.maxIterations` / `test.endState`, but neither key exists in any script or in the `Get-PsadtConfig`
  schema. The cap is now stated as a hard count of 5 the orchestrator owns, and the end-state as "uninstalled"
  in plain text - no phantom config.
- **Stale phase numbers.** SKILL.md handoff rules said "Upload (7.5)" and `references/app-registration.md`
  said "Phase 7.5"; both now correctly read **Phase 9** (the unified 0-12 numbering from 0.9.0).
- **README project tree.** `New-PsadtReport.ps1` was labelled "Phase 7" (now **Phase 8**), and three shipped
  scripts were missing from the tree: `Invoke-PsadtPreflight.ps1` (Phase 5), `Invoke-IntuneAppAssignment.ps1`
  (Phase 10), `_GraphCommon.ps1` (shared Graph helpers).

### Changed
- **`superpowers` is now an optional methodology layer, not a hard dependency.** The Researcher/Reviewer roles
  referenced `superpowers:dispatching-parallel-agents` and `superpowers:requesting-code-review` as `REQUIRED`,
  but that plugin was never declared as a prerequisite anywhere. Those references are now "prefer if installed;
  else fall back to the native Agent tool / `/code-review`", the workflow no longer depends on the plugin, and
  the README Requirements list documents it as an optional (recommended) enhancement.

## 0.9.0 — 2026-06-11 — Audit cleanup (quality, content, applicability/compatibility, tests)

A three-auditor review surfaced concrete defects; the maintainer decided per-category which to fix. Security
items (secret hygiene) were deliberately out of scope; the one correctness bug was included.

### Added
- **Test coverage for the four previously-untested high-risk scripts** (upload, assignment, Entra-app,
  Get-GraphToken) plus `_GraphCommon` - 28 new Pester cases (param validation, dry-run = no writes,
  idempotency, `-MinWindowsRelease` ValidateSet, DPAPI round-trip, retry-only-on-transient, and a regression
  guard for the precedence bug below). Full suite is now 74 cases.
- **`scripts/_GraphCommon.ps1`** - shared `Invoke-Graph` / `Get-GraphErr` / `Write-*` plus cross-version
  `Get-GraphStatusCode` + `Get-GraphRetryAfterSeconds`, dot-sourced by the three Graph scripts (the request/
  retry/error logic was copy-pasted three times, which let a bug drift into one copy).

### Fixed
- **Operator-precedence bug** in `New-PsadtEntraApp.ps1` `Invoke-WithRetry`: `-in ... -and` without parentheses
  was an always-truthy array, so EVERY error was retried 6x (including real permission denials). Parenthesized
  and regression-tested.
- **PS7-fragile throttling.** `Retry-After` / HTTP-status reads now work on Windows PowerShell 5.1 AND
  PowerShell 7 (the old `[int]$Headers['Retry-After']` threw on PS7, silently dropping the server's hint).
- **Report "green by default."** `New-PsadtReport.ps1` no longer renders synthetic `passed` rows for
  pre-flight / SYSTEM-test when no real results are supplied - it shows a neutral "not run" state (the same
  honesty rule as the 0.7.5 exit-code fix). The PSADT version default now comes from the installed module, not
  the literal `4.1.8`.
- **GUID validation** (`ValidatePattern`) on `-MsiProductCode` / `-MsiUpgradeCode` (a malformed code previously
  failed late, server-side).
- **Guide self-contradictions**: the `$adtSession` template showed `AppScriptVersion='<1.0.0>'` + a literal
  author (contradicting the BINDING "always 0.1, author from config" rule); the intro appendix index listed
  only A-G with wrong labels. Both corrected to `0.1`/config and the full A-M list.

### Changed
- **Phase numbering unified** across SKILL.md and the guide into ONE integer scheme **0-12** (Setup, Intake,
  Research, Scaffold, Hooks, Pre-flight, SYSTEM test, Package, Report, Upload, Groups, Test, Rollout).
  Previously the two files used offset numbers (SKILL 0-9 with `.5` sub-phases, guide 0-7), so guide
  references to "Phase 5.5 / 7.5" pointed at the wrong sections. Every Phase + Appendix cross-reference was
  re-verified - all resolve.
- **Redundancy trimmed**: SKILL.md anti-pattern list reduced to the top offenders + a pointer to guide
  B/I.7/K.7; the dense language-split convention split into two clear rules.
- **Docs added**: SYSTEM-test prerequisites stated prominently (WinPS 5.1 + elevation + `Invoke-CommandAs` +
  VM); `/beta` drift caveat (guide H.1); upload wires supersedence but NOT app dependencies (`-DependsOnAppId`
  is portal-only); explicit rollback step (Phase 12); PSADT log-path logging convention; comment-based help
  completed on Get/Set-PsadtConfig; README setup table documents the optional `intune.*` / `intune.groups.*`
  blocks, fixes "App. A-J" -> "A-M", and clarifies the uploader does no group assignment (separate opt-in).
- **Test harness**: `Run-All.ps1` fails fast with a clear message if Pester < 5; removed a dead invocation in
  the report umlaut test; documented the SYSTEM-test re-exec path as untested-by-design.

## 0.8.1 — 2026-06-11 — Docs consistency fixes

### Fixed
- **Stale cross-reference in SKILL.md.** The intro pointed at the guide as "Phases 0-7 + Appendix **A-J**",
  but the guide now runs through **Appendix M** - K/L were added in 0.7.0 and M in 0.8.0 without updating this
  range. Now reads "Appendix A-M". (Phases 0-7 is correct: those are the guide's phase headers.)
- **Missing 0.5.3 entry in the README changelog mirror.** `CHANGELOG.md` had the 0.5.3 release but the README's
  mirrored "Changelog" section skipped it. Restored, so the two changelogs match entry-for-entry.

## 0.8.0 — 2026-06-11 — Opt-in Entra group assignment (wired end-to-end) + min-OS upload fix

### Added
- **Group assignment as a first-class opt-in step (Phase 7.6).** `Invoke-IntuneAppAssignment.ps1` creates/reuses
  Entra security groups by a configured naming scheme and assigns the uploaded `win32LobApp`
  (intents required/available/uninstall). Read-only dry-run by default, `-Execute` writes; idempotent; never
  deletes a group or another app's assignment; ambiguous/duplicate names are skipped, not guessed.
- **`New-PsadtEntraApp.ps1 -IncludeGroupManagement`** consents the least-privilege group roles `Group.Create`
  + `GroupMember.Read.All` (NOT tenant-wide `Group.ReadWrite.All`) on the existing upload app.
- **`intune.groups` config schema** (`enabled`, `create`, `membershipType: assigned`,
  `naming.{required|available|uninstall}`), validated by `Get-PsadtConfig.ps1`.
- **Guide Appendix M** — the full feature reference: permission model, config schema + `Set-PsadtConfig`
  snippet, naming tokens, the version-INDEPENDENT default (so a new version reuses the same groups for
  supersedence) vs the `%version%` opt-in, the "no `%intent%` token" rule, dry-run -> execute workflow,
  idempotency/ambiguous/missing handling, and `-SkillRoot`/config-location gotchas.

### Fixed
- **`Invoke-IntuneWin32Upload.ps1 -MinWindowsRelease` no longer dies mid-upload.** The Graph backend
  validates `minimumSupportedWindowsRelease` as a server-side string and rejects unknown values
  (`BadRequest: Unknown MinimumSupportedWindowsRelease`, e.g. `21H2`/`22H2`) only at the create step. The
  parameter is now a `ValidateSet` of backend-accepted release IDs (`1607..2004`) that fails fast at param
  binding with the valid list; set a higher minimum in the portal if needed. New guide note **H.11**.

### Wiring
- **SKILL.md** wired for the feature: Gate 2 ties "AAD groups" to the opt-in; Phase 0 mentions
  `-IncludeGroupManagement`; new Phase 7.6; the "never auto-assign group" lines reframed as "only when the
  user opted in at Gate 2 AND `intune.groups.enabled`"; anti-patterns for reflexive `%version%` and a
  non-existent `%intent%` token; troubleshooting rows for the min-OS and group-permission errors.

## 0.7.5 — 2026-06-10 — Honest exit codes + detection for fix/remediation packages

### Fixed
- **Removed the dangerous "always exit 0" guidance** from guide **Appendix K**. A blanket `exit 0` (and a
  detection tag written in a `finally`) reports GREEN on failure — a real defect that hides broken deployments.
  The recipe now teaches the honest model (new **K.7**):
  - **Exit code = could the fix RUN?** Ran to completion -> `0`; couldn't run / crashed -> **non-zero**. The
    64-bit relaunch now **propagates the child's exit code** (`exit $LASTEXITCODE`), never a hard-coded `0` (K.2).
  - **Detection = the real END-STATE**, not an unconditional tag; if a tag is used, write it ONLY on a successful
    run (never in a `finally`). A failed fix -> detection negative -> Intune retry + **visible** (K.5).
  - Per-package decision table (real installer / important fix / non-critical ESP cleanup), and "never block
    enrollment" reframed as an explicit ESP-assignment + return-code-mapping choice (K.6), not a masked exit code.
- **SKILL.md** anti-pattern added: a blanket `exit 0` or a `finally`-written tag both report green on failure.

## 0.7.0 — 2026-06-10 — Value-adding extensions (pre-flight tool, recipes, knowledge)

### Added
- **`scripts/Invoke-PsadtPreflight.ps1`** — the Phase-5 Reviewer gate as one deterministic, testable tool.
  `-PackagePath <pkg>` returns `{ Overall='GREEN'|'RED'; Checks=@(...) }` covering encoding (ASCII/BOM), AST
  parse, v3-cmdlet scan (launcher + Extensions only; a private `Write-Log` in a bundled `Files\*.ps1` is no
  longer a false positive), top-level-statement scan, the structural acid-test (all three hooks defined +
  Extensions helpers actually called), and the GUID→`-FilePath` anti-pattern. New `tests/Invoke-PsadtPreflight.Tests.ps1`
  (clean package = GREEN; em-dash / v3 cmdlet / GUID-to-`-FilePath` / missing-hook fixtures = RED).
- **Guide Appendix K — script-only remediation / fix packages (ESP-safe).** Codifies the recurring
  debloat/Cisco-style pattern: run a bundled PS script via native 64-bit PowerShell (Extensions helper shared by
  Install + Repair), self-healing file/tag detection, no-op uninstall that never removes the fixed artifact,
  `DeployMode Silent`, always exit 0, `CloseProcesses` for in-use files, ESP blocking-app wiring.
- **Guide Appendix L — installer technologies + silent switches.** A lookup (consulted before web research):
  identify MSI / MSI-wrapped EXE / InstallShield / Inno Setup / NSIS / WiX Burn / Squirrel / MSIX / install4j /
  Wise, with silent install/uninstall/no-reboot/log switches and the natural detection rule.
- **Expanded error-code catalogue** (guide Appendix A.1 + new A.4; highest-frequency rows in the SKILL.md
  troubleshooting table): MSI 1603/1605/1618/1619/1620/1622/1625/1635/1638/1639/110x, the matching `0x8007…`
  HRESULTs, and the PSADT 60001/60008 + 60002–60007/69000+/70000+ ranges — each with a concrete reaction.

### Changed
- **SKILL.md** Phase 5 now points at the pre-flight script (GREEN required); Phase 2 research consults Appendix L
  first (and Appendix K for script-only fixes); reference lookup + anti-patterns updated. SKILL.md stays a lean
  control plane (no inlined code).

## 0.6.2 — 2026-06-10 — Audit & harden (scripts, report, guide)

A full agent-based audit (3 parallel reviewers) followed by source-level verification of every finding
(which discarded ~8 false positives). Only verified weaknesses were fixed; the proven Graph request shapes
were left untouched.

### Fixed
- **Guide doc-vs-code that broke packaging** (`references/PSADTv4-Deployment-Guide.md`): the "Extended scaffold"
  told the agent to pass `-AppVendor/-AppName/-AppVersion/...` to `New-ADTTemplate`, which v4.1.x rejects
  ("A parameter cannot be found …"). Removed it; metadata goes into `$adtSession` after scaffolding (matches SKILL.md).
- **Upload leaves AES keys in `%TEMP%`** (`scripts/Invoke-IntuneWin32Upload.ps1`): the extracted work dir
  (whose `Detection.xml` holds `encryptionKey/macKey/IV/mac`) is now removed via `try/finally` on success,
  dry-run, or throw.
- **Report `Notes` double-escape** (`scripts/New-PsadtReport.ps1`): the default `Notes` contained `&middot;`,
  which `Esc` turned into a literal `&amp;middot;`. Switched the default to ASCII separators.
- **Fallback logo hardening** (`scripts/New-PsadtReport.ps1`): the initials-tile SVG now XML-escapes the
  AppName-derived initials and is emitted as a base64 data URI (a special character can no longer break or
  inject markup). New regression test in `tests/New-PsadtReport.Tests.ps1`.

### Changed (robustness)
- **Graph throttling retry** (additive): `Invoke-Graph` now retries 429 / 5xx honouring `Retry-After`
  (max 4 attempts); request bodies unchanged.
- **Malformed-config safety**: `Get-PsadtConfig`, `Get-IntuneWinAppUtil`, `Get-WinGetModule`, `Set-PsadtConfig`
  now handle a corrupt `config.json` with a clear message instead of a raw `ConvertFrom-Json` throw.
- **Download hardening**: WinGet zip header check reads only 2 bytes (not the whole archive) and guards a
  <2-byte download; `Get-IntuneWinAppUtil` releases its file handle via `finally`; `Update-PsadtSkill` cleans
  its temp files on the failure path too.
- Doc comment corrected: block-blob upload uses 4 MB blocks (was mislabelled "6 MB").

## 0.6.1 — 2026-06-10 — Report header: fix scrollbar-feedback flicker

### Fixed
- **`references/Report-Template.html` — wild header flicker at certain viewport widths.** The dossier did not
  reserve the vertical scrollbar gutter, so at widths where the content height landed at the viewport edge the
  scrollbar toggled on/off; each toggle changed the content width, and the header's `vw`-based `clamp()` padding
  and `h1` font-size reflowed on every toggle, producing a rapid flicker loop. Reserving the gutter
  (`html { overflow-y: scroll; scrollbar-gutter: stable; }`) holds the width constant and breaks the loop.

## 0.6.0 — 2026-06-10 — SKILL.md slimmed to a control plane (progressive disclosure)

### Changed
- **`SKILL.md` rewritten as a lean orchestrator: 733 → 244 lines (~16k → ~3.5k tokens, ~67% smaller).** It
  now holds the binding conventions, the workflow skeleton, the decision gates, and pointers - the long
  inline PowerShell blocks (encoding fix, pre-flight scans, packaging, logo fetch, MSI icon-table extraction,
  WinGet lifecycle, upload examples) moved into the reference guide and load on demand. No behaviour and no
  binding rule was dropped - all 11 conventions, the self-update flow, all phases, the troubleshooting table,
  and the anti-pattern list are preserved (verbatim where they are rules, relocated where they are code).
- **Autonomy:** intake is restructured from 8 mandatory questions into **4 decision gates**; everything
  researchable (version, installer type, silent/uninstall/repair switches, ProductCode, Intune issues) is now
  a researched, transparently-stated assumption instead of a question. `AskUserQuestion` is still the only way
  to ask, and the test/upload consents are unchanged.
- **Sub-agent architecture:** explicit Orchestrator / Researcher×3 / Builder / Reviewer roles with hard
  handoff gates (no packaging before a GREEN pre-flight; no upload before a GREEN SYSTEM test), wired to
  `superpowers:dispatching-parallel-agents` and `superpowers:requesting-code-review`.
- **Error handling:** a single **blockade protocol** (`PROBLEM / TRIED / OPTIONS 1,2`) replaces the scattered
  "stop and hand back" notes.
- **Frontmatter `description`** trimmed to triggering conditions only (no workflow summary), per Anthropic
  skill-authoring guidance.

### Added
- **`references/PSADTv4-Deployment-Guide.md` — Appendix I (WinGet packaging)** and **Appendix J (app-logo
  acquisition + verification)**: the WinGet discovery/provisioning/hook/detection code and the logo
  source-priority / Wikimedia / MSI icon-table / corner-pixel-verification code, lifted verbatim from the old
  SKILL.md so nothing is lost. The guide now spans Appendix A–J.

## 0.5.3 — 2026-06-09 — Guide: code inside code-fences is now English/ASCII

### Changed
- **`references/PSADTv4-Deployment-Guide.md`** — anglicized every German comment, string literal and
  placeholder that lived **inside PowerShell/text code fences** (and the inline-code placeholders in the
  Appendix F.1 table). Examples: `# Lokale Modulversion` → `# Local module version`,
  `"Neueste: … vom …"` → `"Latest: … from …"`, `<Hersteller>` → `<Vendor>`,
  `<Vorname Nachname>` → `<FirstName LastName>`, `<pfad-zur-ps1>` → `<path-to-ps1>`,
  `<prozess1>` → `<process1>`. Reason: snippets get copied verbatim into deployment scripts, where the
  binding rule is English + 7-bit ASCII — German comments/umlauts in a copied snippet are exactly the
  encoding/consistency failure class the pre-flight warns about.
- Deliberately **left unchanged**: the German explanatory **prose** of the guide and the **F.2 Company
  Portal description template** (legitimate end-user dossier text, `language.dossier` = German with real
  umlauts). No script/tooling code changed; `scripts/` and `Report-Template.html` were already compliant
  (German only as dossier output, ASCII-clean via HTML entities).

## 0.5.2 — 2026-06-08 — Always-on HTML package report (template + generator)

### Added
- **`scripts/New-PsadtReport.ps1`** (+ `tests/New-PsadtReport.Tests.ps1`, 9 cases): generates the package
  report as a single self-contained HTML file from the fixed template `references/Report-Template.html`.
  Data-driven via a `-Metadata` hashtable (or `-MetadataPath` JSON) with sane defaults for every field, so a
  minimal call still yields a complete report. Variable-length sections (return codes, cmdlets, deployment-hook
  bullets, pre-flight checks, SYSTEM-test rows, assignments) are built from arrays. The logo is embedded as a
  base64 data URI (fallback: a neutral initials tile), and free text is HTML-escaped (no injection).
- **`references/Report-Template.html`** — the fixed, tokenized report template. Fluent-2 styling, a **sticky
  header that shrinks on scroll** (with hysteresis to avoid flicker; disabled on mobile), the **real app logo
  in the header**, a **DE/EN language toggle** (decoupled, absolutely-positioned status block so switching
  never shifts the layout), and a client-side Markdown renderer so the description **preview is generated from
  its Markdown source**. The document stays browser-translatable.

### Changed
- **The HTML report is now BINDING — generated for EVERY package, whether or not it is uploaded to Intune.**
  It is one combined document: the **Intune dossier** (App Info, description, Program, Return Codes,
  Requirements, Detection, Dependencies, Supersedence, Assignments) **plus a technical package report**
  (deployment hooks, PSADT cmdlets used, pre-flight + SYSTEM-test results, logo/`.intunewin` verification).
  SKILL.md Phase 7 + conventions updated; Appendix F rewritten around the generator + the `-Metadata` key list;
  README Features/structure updated. New anti-patterns: never skip the report, never hand-assemble it.
- The report is bilingual and keeps **real umlauts** (the report is end-user output — the script-only ASCII
  rule does not apply; the template is ASCII via HTML entities, umlauts come from the description metadata,
  output is written UTF-8).

## 0.5.1 — 2026-06-06 — Robust commit-based self-update + README fix

### Changed
- **Self-update now decides by commit, not by the CHANGELOG version.** `Update-PsadtSkill.ps1` compares the
  local `HEAD` against `origin/<branch>` (git clone) or the GitHub commits-API sha against the recorded
  `tooling.skillCommit` (non-clone). This removes the `raw.githubusercontent.com` CDN cache lag and the
  circular "read the version from a file that can't know about a newer one." The CHANGELOG version is now
  shown only as context (`RemoteVersion` / `WhatsNew`); `Behind` reports how many commits behind a clone is.

### Fixed
- README project-structure tree compacted so it renders without horizontal scroll / truncated right-hand comments.

## 0.5.0 — 2026-06-06 — Skill self-update

### Added
- **`scripts/Update-PsadtSkill.ps1`** (+ Pester tests): checks GitHub for a newer skill version (compares the
  top `CHANGELOG.md` version), reports `LocalVersion` / `RemoteVersion` / `UpdateAvailable` / `WhatsNew`, and
  on confirmation updates **in place** — `git pull --ff-only` for a clone, otherwise overwrites only the
  tracked files (`SKILL.md`, `README.md`, `CHANGELOG.md`, `LICENSE`, `references/`, `scripts/`, `tests/`) from
  the branch zip. `config.json`, `secret.dpapi`, `tools/` and `docs/` are never touched.
- **SKILL.md**: a "Self-update" section + a non-blocking check at the start of Phase 0; triggers
  "update skill" / "/update-skill" / "psadt update" / "check for skill updates". The skill always **asks**
  before applying; an update check never blocks packaging.

## 0.4.0 — 2026-06-06 — WinGet support + certificate auth (PR #4)

Contributed by **@joakim-i** (PR #4), reviewed + hardened before merge.

### Added
- **WinGet packaging support** (strictly **opt-in**, never the default): `scripts/Get-WinGetModule.ps1`
  (self-heals the `PSAppDeployToolkit.WinGet` extension into `tools/` + the package), full SKILL.md lifecycle
  (intake Q2 option, Phase 2b discovery, install/uninstall/repair via `*-ADTWinGet*`, detection caveats,
  anti-patterns) and `tests/Get-WinGetModule.Tests.ps1`.
- **Certificate-based auth for Phase 7.5** — `New-PsadtEntraApp.ps1 -UseCertificate -CertThumbprint` uploads
  the cert's **public** key as an app `keyCredential`; `Get-GraphToken.ps1` signs an RFC 7523 JWT client
  assertion (RS256) with the private key (never exported). No secret at rest; config stores only the
  thumbprint. Client-secret path retained as fallback.
- **MSI Icon-table logo extraction** as a logo fallback (4-priority source list in Phase 7).

### Fixed
- Device-code polling `ScriptHalted` on the first poll (OAuth errors return a bare string, not a `.code`/`.message` object).

### Review hardening (applied on top of the PR before merge)
- Removed three junk `.gitignore` lines accidentally added by diff tooling.
- Dropped the unsubstantiated `offline_access` addition to `$WamScopes` (WAM is verified working without it; avoids
  MSAL reserved-scope risk; this one-shot bootstrap needs no refresh token).
- `Get-WinGetModule.ps1` now surfaces the **Authenticode trust state** of the third-party module (it executes on
  devices) and documents the supply-chain assumption.
- `Get-GraphToken.ps1` cert path: null-check `GetRSAPrivateKey` and dispose the RSA key.
- Made **WinGet's opt-in / never-default** rule explicit in SKILL.md (intake Q2 + anti-pattern).

## 0.3.2 — 2026-06-06 — Test-before-upload is now a binding gate

### Changed
- **Install + Uninstall must pass the Phase 5.5 SYSTEM test before any Phase 7.5 upload.** SKILL.md now makes
  this a binding prerequisite (Phase 7.5 callout, Phase 5.5 link, anti-pattern, conventions). If the test
  can't be run (no elevation / no VM), STOP before `-Execute` and hand the user the exact test command —
  never upload an untested package.

## 0.3.1 — 2026-06-06 — Script detection for non-MSI apps

### Added
- **PowerShell-script detection** in `Invoke-IntuneWin32Upload.ps1` via `-DetectionScriptPath` (+ optional
  `-DetectionRunAs32Bit`): builds a `win32LobAppPowerShellScriptRule` (ruleType=detection) for EXE / non-MSI
  installers (Vivaldi, Chrome-style, NSIS, Squirrel) that have no MSI ProductCode. Mutually exclusive with
  `-MsiProductCode`. Verified live by packaging + uploading Vivaldi 8.0.4033.44.

### Lessons baked in (do-not-repeat)
- A **detection** script rule accepts ONLY `ruleType, enforceSignatureCheck, runAs32Bit, scriptContent` —
  Graph rejects `displayName`/`runAsAccount`/`operationType`/`operator`/`comparisonValue` on detection rules
  ("The <X> property may not be set for Win32LobAppPowerShellScriptRule instances used for app detection").
- Reference guide **Appendix H.2** extended; SKILL.md Phase 7.5 + anti-patterns + troubleshooting updated.

## 0.3.0 — 2026-06-06 — Direct Intune upload (Microsoft Graph)

### Added
- **Direct Intune upload** — `scripts/Invoke-IntuneWin32Upload.ps1` (Phase 7.5): self-contained raw-Graph
  upload of a `.intunewin` as a `win32LobApp` (app + logo, **no group assignment**). 8-step flow: parse
  `.intunewin` → app-only token → read-only permission probe → idempotency check → build body →
  create/update → content version → register file → poll SAS → block-blob upload (HttpClient) → commit →
  activate → categories → optional supersedence. Read-only **dry-run by default**; `-Execute` performs the
  writes.
- **WAM Entra-app bootstrap** — `scripts/New-PsadtEntraApp.ps1` now signs the admin in via **WAM** (Windows
  Web Account Manager broker) using MSAL.NET (auto-located or downloaded to `%LOCALAPPDATA%\PsadtIntune\msal`),
  with automatic **device-code fallback**. Creates the `PSADT Intune Upload` app, grants + admin-consents
  `DeviceManagementApps.ReadWrite.All`, creates a client secret, and DPAPI-stores it.
- **App-only Graph token helper** — `scripts/Get-GraphToken.ps1` (client-credentials; DPAPI secret decrypted
  in-memory only).
- **Full App-information metadata** — the uploader fills `displayName, description, publisher, developer,
  owner, displayVersion, informationUrl, privacyInformationUrl, notes, largeIcon, msiInformation,
  returnCodes, rules, installExperience` instead of the bare minimum.
- **Coexistence-safe versioning** — `-OnExisting CreateNewCoexist` (default) uploads a new version as a
  **separate** app and never touches the existing one; `-UpdateAppId` for explicit in-place update;
  `-SupersedesAppId` wires "new replaces old". The script issues only POST/PATCH — **never DELETE**.
- **Logo guard** — refuses the PSADT default `Assets\AppIcon.png` (SHA256 blocklist) unless
  `-AllowDefaultLogo`; warns when no logo is supplied.
- **Reference guide Appendix H** — the hard-won Graph upload lessons (see below). README + SKILL.md updated;
  `references/app-registration.md` manual portal fallback.

### Fixed
- **Repair `-FilePath`→`-ProductCode`** — the `Repair-ADTDeployment` MSI example (and the 7-Zip package) used
  `-FilePath '{GUID}'`, which PSADT 4.1.x rejects with `InvalidFilePathParameterValue` (exit 60001). The
  Uninstall fix had been applied earlier but Repair was missed — now corrected in SKILL.md and the guide.

### Lessons baked in (do-not-repeat)
- Use the unified **`rules`** collection (`win32LobAppProductCodeRule`, `ruleType=detection`), **not** the
  legacy `detectionRules` — the current backend rejects the latter ("must have at least one detection rule").
- **`@odata.type` must serialise first** in polymorphic sub-objects (`[ordered]@{}`).
- Upload the encrypted blob with **HttpClient/ByteArrayContent**, not `Invoke-RestMethod -Body <byte[]>`
  (binary corruption → `commitFileFailed`).
- Write win32LobApp metadata on **`/beta`** — `/v1.0` silently drops `displayVersion` and others.
- **Never the default PSADT logo** as the app logo; `IsAlphaPixelFormat` is not proof of transparency.
- **Never auto-impose** category / branded notes / featured / group assignment; **never delete** an older
  version.

## 0.2.0 — Automated SYSTEM test loop

- **Automated SYSTEM test loop** (`scripts/Invoke-PsadtSystemTest.ps1`, Phase 5.5): install → uninstall →
  reinstall the package as the SYSTEM account via `Invoke-CommandAs`, with agent-driven auto-fix until green
  or a max-iteration cap. Opt-in; elevated session required.
- Phase 8 now prefers `Invoke-CommandAs -AsSystem` for SYSTEM-context testing (PsExec kept as a fallback).
- Self-re-exec to Windows PowerShell 5.1 when run under pwsh 7 (PSScheduledJob is 5.1-only). See guide
  Appendix G (2026-06-05).

## 0.1.0 — Initial release

- Guided PSADT v4 → Intune Win32 lifecycle: intake, autonomous research, scaffolding, all three deployment
  types (Install/Uninstall/Repair), pre-flight checks, packaging, dossier + logo, guided testing,
  troubleshooting.
- First-run setup writing a machine-local `config.json` (paths, language, author).
- Self-healing prerequisites: PSAppDeployToolkit module (PSGallery) and `IntuneWinAppUtil.exe` (auto-download
  + version check).
- HTML dossier document with a Markdown app-description block (the Intune description field is Markdown-only).
- English skill + reference guide; MIT licensed.

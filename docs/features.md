# Features in full

← back to the [README](../README.md)

The README names the highlights; this page is the complete list. Depth beyond it lives in
`references/` (see [`references/README.md`](../references/README.md) for the map).

## Setup and prerequisites

- **Setup doctor** - one idempotent script checks PowerShell 7, Windows PowerShell 5.1, elevation, git,
  PSAppDeployToolkit, the content-prep tool, `Invoke-CommandAs`, Pester, the config, a legacy config, the
  skill tree, a pending update and the Intune credentials. Each line carries a concrete fix; `-Fix` applies
  the ones that need no decision.
- **Self-healing prerequisites** - installs the PSAppDeployToolkit module from the PowerShell Gallery and
  downloads `IntuneWinAppUtil.exe`, keeping both current against their official sources.
- **Config outside the skill folder** - `config.json`, `secret.dpapi` and `tools/` live in
  `%LOCALAPPDATA%\psadt-deploy\` (override: `$env:PSADT_DEPLOY_HOME`), so a `git pull`, a re-clone or a
  re-install can no longer take your setup with it. A pre-0.19 config keeps working and is migrated on
  request, never deleted.
- **One-line install** - `npx psadt-deploy-skill` (Node 18+, zero dependencies) does clone-or-update plus
  the doctor run in one step.

## Build and verify

- **Guided intake** - the blocker questions up front as clickable options, pre-filled with researched
  defaults (app, latest version, installer type, package type).
- **Local evidence before the web** - `Get-PsadtLocalEvidence.ps1` walks a ladder (is it installed here?
  is the binary here? is it already written down in this repo?) and returns the questions it could NOT
  close, with a budget. Research agents are dispatched one per open question and never more, each handed
  what is already known so it confirms rather than rediscovers.
- **Switch catalog before the web** - identifies the installer engine from the *binary* (byte signatures in
  the PE overlay, resources and section table, not a filename guess) and serves that engine's documented
  silent / uninstall / log / no-reboot switches from a catalog that ships with the skill. Offline, and it
  reports every stage it checked including the misses. A candidate is still a claim until a run proves it.
- **Autonomous research** - checks the installed PSADT version against the latest release *and* whether
  commands changed; researches silent install / uninstall / repair switches and known Intune pitfalls.
- **All three deployment types from the start** - Install, Uninstall *and* Repair, acid-tested, so
  Company-Portal uninstalls actually work.
- **Pre-flight gate - 14 checks** - encoding/BOM, AST parse, v3-cmdlet scan, hook structure, the
  GUID-to-`-FilePath` anti-pattern, an uninstall that trusts a vendor EXE's exit code, top-level
  statements, the detection-script contract, the package manifest, the per-run log name and driver trust.
  GREEN or RED, with the failing file named.
- **SYSTEM test in a throwaway VM** *(binding before upload)* - `Invoke-PsadtSandboxTest.ps1` runs the
  whole loop inside Windows Sandbox with **every action executed as `NT AUTHORITY\SYSTEM`** through a
  scheduled task, exactly as the Intune Management Extension does. **No elevation on the host, and the
  host is never modified.** The verdict is keyed on the detection script - the same rule Intune evaluates
  - and every action snapshots the real Add/Remove-Programs entry, so hooks get written against the
  machine's actual strings instead of a guess. A red Install or Uninstall skips the remaining scenarios,
  which could only re-prove the same failure. `Invoke-PsadtSystemTest.ps1` remains the per-action DEV-VM
  route for applications the sandbox cannot host (domain join, a real TPM, GPU acceleration, a reboot).
- **Deterministic packaging** - `<outputRoot>\<Vendor>_<App>_<Version>_<Arch>\<same stem>.intunewin`,
  verified after the fact (`Detection.xml`, `SetupFile`, size, SHA256), with the detection script and the
  real logo beside it. It refuses an output folder inside the package, and never deletes a foreign
  `.intunewin` it finds there.
- **One PSADT log per run** - `<Vendor>_<App>_<Version>_<Arch>_<Install|Uninstall|Repair>_<timestamp>.log`
  instead of every run of every version appending to one unreadable file.

## Package types

The app's **native installer is always the default**. Everything else is opt-in and only on request:

- **MSI** - `New-MsiPackage.ps1` generates launcher, detection script, per-run log name and manifest.
- **EXE (Inno Setup, NSIS, electron-builder, InstallShield)** - `New-ExePackage.ps1`. It generates the
  three lessons that cost the most to learn: the uninstaller is resolved from the ARP entry **at run
  time** (never a hardcoded `unins000.exe`, which becomes `unins001.exe` the moment anything else
  installs beside it), the uninstall **waits for the application to actually disappear** instead of
  trusting an exit code, and detection uses a version **floor** over the ARP entry and the binary.
- **WinGet** - the full `PSAppDeployToolkit.WinGet` lifecycle: the extension module self-heals into the
  package, the Package ID is discovered with `Find-ADTWinGetPackage`, hooks use `*-ADTWinGet*`
  (`-Scope Machine`). Never selected on its own initiative.
- **Browser extensions** - force-install via the Edge/Chrome/Firefox policy keys (including the Firefox
  `REG_MULTI_SZ` trap), with selective removal on uninstall.
- **Windows features** - `Enable-WindowsOptionalFeature` and `Add-WindowsCapability`, offline source or a
  temporary WSUS bypass that is restored afterwards, `EnablePending` handled honestly.
- **Third-party drivers** - the trust situation is classified *before* anything is built: Microsoft-signed
  installs silently, vendor-signed needs the signer certificate owned in exactly one place, and a
  vendor-signed **kernel** driver is refused because `TrustedPublisher` satisfies the PnP prompt but never
  Code Integrity - it would install and then not load. Unsigned is refused outright, with three honest
  options and no testsigning. Staging is per-INF `pnputil`; uninstall resolves `oemNN.inf` by original name
  instead of a remembered index.
- **Script-only / remediation packages** - ESP-safe patterns for fix packages with no installer at all.

## Deliverables

- **HTML dossier - always generated**, uploaded or not. One self-contained file
  (`Intune-Dossier.html`) built from a fixed template, never hand-assembled: the **Intune dossier** (App
  Info, return-code map, detection rule, requirements, assignments, driver trust, and a ready-to-paste
  **Markdown** description for the Company-Portal field) plus a **technical package report** (the three
  hooks, PSADT cmdlets used, pre-flight and SYSTEM-test results, logo and `.intunewin` verification).
  Bilingual with a DE/EN toggle, browser-translatable, logo embedded as a data URI. It refuses to render
  for a package marked for upload whose SYSTEM test is not a full-gate GREEN.
- **Real logo only** - finds and downloads the actual application logo (vendor source or Wikimedia
  Commons), verifies real pixel transparency *and* looks at the image. The PSADT default `AppIcon.png` is
  blocked by hash.
- **Start Menu only** - creates Start Menu entries and removes stray desktop icons.

## Intune

- **Access as state, not as a 403** - `Test-PsadtIntuneAccess.ps1` answers before Phase 9 whether the app
  can upload, assign groups or create policies, and for how long the credential lives. Verified / refused /
  **unknown** are three different answers, and an offline check never overwrites what was verified before.
- **Direct upload via Microsoft Graph** *(opt-in)* - pushes the `.intunewin` as a `win32LobApp` (app +
  logo), self-contained raw Graph, no third-party module. Identity comes from the manifest, so Intune shows
  the same name and version as the artifact and the dossier. Read-only dry run → confirm → upload. Fills the
  whole App-information tab, **never deletes an older version** (new versions coexist, with optional
  supersedence wiring), never auto-assigns categories or notes.
- **One-time Entra bootstrap** - `New-PsadtEntraApp.ps1` signs in via **WAM**, creates the app, grants and
  admin-consents the roles and stores the credential: a **certificate** (preferred - nothing secret at rest,
  JWT client-assertion auth) or a DPAPI-encrypted client secret. Re-running it is normal: it finds the
  recorded app, merges requested permissions instead of replacing them, and never prompts.
- **Opt-in group assignment** - creates/reuses Entra security groups by a configured naming scheme and
  assigns Required / Available / Uninstall. Least-privilege (`Group.Create` + `GroupMember.Read.All`),
  dry run → confirm, idempotent, and it never deletes a group or another app's assignment.
- **Certificate + firewall policies** - Custom OMA-URI profiles for `TrustedPublisher` / `TrustedPeople`
  (the built-in template cannot reach those stores) and settings-catalog firewall-rule policies. Both
  scripts are self-contained deliverables: they can be copied to a test client that has no skill installed.

## Operations

- **Troubleshooting** - decodes Intune error/HRESULT codes, maps symptoms to root causes, and triages the
  right log (`AppWorkload.log`, the PSADT session log, `setupapi.dev.log` for drivers).
- **Self-update** - `scripts/Update-PsadtSkill.ps1` compares against GitHub, shows what changed, and
  updates in place on your confirmation (`git pull --ff-only` for a clone, otherwise a branch-zip overwrite
  of tracked files only). Machine-local state is never touched. Say *"psadt update"*.
- **824 Pester tests** over the helper scripts, including drift guards that fail when the docs and the code
  disagree - one of them reads the published landing page and compares its figures against the repository.

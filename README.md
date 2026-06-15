<h1 align="center">PSADT v4 → Intune Deployment Skill</h1>

<p align="center">
  <em>A Claude Code skill that drives the full lifecycle of a PowerShell App Deployment Toolkit (PSADT) v4.x Intune Win32 package — from first conversation to a tested, upload-ready <code>.intunewin</code>.</em>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square" alt="License: MIT" /></a>
  <img src="https://img.shields.io/badge/PSADT-v4.x-0a7bbb?style=flat-square" alt="PSADT v4.x" />
  <img src="https://img.shields.io/badge/Platform-Windows-0078d6?style=flat-square&logo=windows&logoColor=white" alt="Windows" />
  <img src="https://img.shields.io/badge/Claude%20Code-Skill-d97757?style=flat-square" alt="Claude Code Skill" />
</p>

<p align="center"><sub><a href="#roadmap">Roadmap</a> · <a href="#changelog">Changelog</a></sub></p>

---

## What is this?

This is a **Claude Code skill** (not a plugin): a reusable instruction package that teaches the agent
how to build, package, test, troubleshoot, and deploy a **PSADT v4.x Intune Win32 app**. You describe
the application; the skill runs the whole workflow — intake, web research, scaffolding, customizing all
three deployment types (Install / Uninstall / Repair), pre-flight checks, packaging with
IntuneWinAppUtil, dossier generation, testing, and rollout.

A skill is a folder with a `SKILL.md` (YAML frontmatter + Markdown instructions), optionally bundled
with `scripts/`, `references/`, and `tools/`. It loads progressively: the agent sees only the name and
description until a task makes it relevant, then the full body loads on demand.

<img width="1024" height="254" alt="image" src="https://github.com/user-attachments/assets/7c7931ba-dcae-4476-a648-11115eceb3b5" />

## Features

- **First-run setup** — a one-time wizard persists machine config (paths, language, author) so
  conventions are configured once, in one place.
- **Self-healing prerequisites** — auto-installs the PSAppDeployToolkit module from the PowerShell
  Gallery if missing, and auto-downloads `IntuneWinAppUtil.exe`, keeping both current against their
  official sources. No manual provisioning, no roadblocks.
- **Guided intake** — asks the blocker questions up front as clickable options, pre-filled with
  researched defaults (app, latest version, installer type).
- **Autonomous research** — checks the installed PSADT version against the latest release *and* whether
  commands changed; researches silent install / uninstall / repair switches and known Intune pitfalls.
- **Scaffolding & customizing** — runs `New-ADTTemplate` and fills all three deployment types (Install,
  Uninstall, Repair) from the start — acid-tested — so Company-Portal uninstalls actually work.
- **Pre-flight checks** — encoding/BOM, AST parse, launcher acid-test per deployment type, and a v3
  cmdlet scan before anything is packaged.
- **Packaging to `.intunewin`** — packs with IntuneWinAppUtil to the central output folder and verifies
  the package (correct `SetupFile`, size).
- **WinGet packaging** *(opt-in, never the default)* — full `PSAppDeployToolkit.WinGet` lifecycle when you
  *explicitly* choose the WinGet installer type: self-heals the extension module into the package
  (`scripts/Get-WinGetModule.ps1`), discovers the Package ID (`Find-ADTWinGetPackage`), and fills
  install/uninstall/repair via `*-ADTWinGet*` (`-Scope Machine`). The default stays the app's native
  installer (MSI/EXE/…) — WinGet is used only on explicit request.
- **App logo auto-fetch** — finds and downloads the **real** application logo (official vendor source or
  Wikimedia Commons) as a high-resolution PNG, verifies actual pixel transparency *and* visually confirms
  the brand. Never ships the PSADT default `AppIcon.png` (the upload script blocks it by hash).
- **HTML package report — always generated** — every finished package gets a single self-contained report
  (`Intune-Dossier.html`), **whether or not it is uploaded to Intune**. Built by `scripts/New-PsadtReport.ps1`
  from the fixed template `references/Report-Template.html` (never hand-assembled). It combines the **Intune
  dossier** (App Info, return-code map, detection rule, requirements, assignments, and a ready-to-paste
  **Markdown** app description for the Company-Portal field) with a **technical package report** (the three
  deployment hooks, PSADT cmdlets used, pre-flight + SYSTEM-test results, logo/`.intunewin` verification). The
  document is **bilingual with a DE/EN toggle** (and stays browser-translatable), Fluent-2 styled with a
  sticky header, embeds the logo as a data URI, and renders the description preview from its Markdown source.
- **Guided testing & staged rollout** — DEV-VM cycles (silent, `.exe` launcher, SYSTEM context via
  PsExec), an Intune test-group assignment, then pilot → staged production.
- **Troubleshooting** — decodes Intune error/HRESULT codes (e.g. `0x80070001`), maps symptoms to root
  causes, and triages the right logs (AppWorkload.log, PSADT session log).
- **Start Menu only** — creates Start Menu entries and removes stray desktop icons; keeps the desktop clean.
- **Automated SYSTEM test loop** *(opt-in)* — before packaging, installs/uninstalls/reinstalls the package
  as the **SYSTEM** account (via `Invoke-CommandAs`, mirroring the Intune Management Extension), evaluates
  logs + detection, and auto-fixes until green or a max-iteration cap. Runs locally and needs an elevated
  session; recommended on a VM/snapshot.
- **Direct Intune upload via Microsoft Graph** *(opt-in)* — pushes the `.intunewin` straight to Intune as a
  `win32LobApp` (app + logo; the uploader itself does **not** assign groups - that's the separate opt-in step
  below), self-contained raw Graph, no third-party module. A
  one-time `New-PsadtEntraApp.ps1` bootstrap signs in via **WAM** (Windows broker), creates the Entra app,
  grants + admin-consents `DeviceManagementApps.ReadWrite.All`, and stores the credential — a
  **certificate** (preferred; no secret at rest, JWT client-assertion auth) or a DPAPI-encrypted client
  secret. Read-only dry-run → confirm → upload. Fills the full App-information tab; **never deletes an older
  version** (new versions coexist, with optional supersedence wiring); never auto-assigns categories/notes.

- **Opt-in group assignment** — when you choose it, `scripts/Invoke-IntuneAppAssignment.ps1` creates/reuses
  Entra security groups by a configured naming scheme (`intune.groups`) and assigns the app
  (Required / Available / Uninstall). Least-privilege (`Group.Create` + `GroupMember.Read.All` via
  `New-PsadtEntraApp.ps1 -IncludeGroupManagement`), read-only dry-run → confirm → execute, idempotent, and it
  never deletes a group or another app's assignment. Version-independent names by default so a new version
  reuses the same audience for supersedence. Details: guide Appendix M.

- **Self-update** — `scripts/Update-PsadtSkill.ps1` checks GitHub for a newer skill version, shows what's new,
  and updates in place on your confirmation (`git pull` for a clone, otherwise a branch-zip overwrite of the
  tracked files only — your `config.json` / `secret.dpapi` / `tools/` are never touched). Say *"update skill"*,
  *"/update-skill"*, or *"psadt update"*.

> Planned features (GitHub package sync) live in the [Roadmap](#roadmap).

## Requirements

- Windows with PowerShell 5.1+ / PowerShell 7+
- [PSAppDeployToolkit](https://psappdeploytoolkit.com/) v4.x *(the skill installs/updates this
  automatically from the PowerShell Gallery if missing)*
- [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
  *(the skill provisions this automatically)*
- For the optional **automated SYSTEM test loop**: an **elevated** PowerShell session; the
  [`Invoke-CommandAs`](https://github.com/mkellerman/Invoke-CommandAs) module is installed automatically
  from the PowerShell Gallery
- For the optional **direct Intune upload**: an Entra app registration with the Graph **application**
  permission `DeviceManagementApps.ReadWrite.All` (admin consent granted) — created for you in one run by
  `scripts/New-PsadtEntraApp.ps1` (interactive WAM sign-in as Global Admin / Privileged Role Admin; device
  code fallback). Certificate or client-secret auth (cert via `-UseCertificate -CertThumbprint`). Manual
  portal route: `references/app-registration.md`.
- For the optional **WinGet packaging** path: nothing extra — `scripts/Get-WinGetModule.ps1` auto-downloads
  the `PSAppDeployToolkit.WinGet` extension into `tools/` (and into the package) the first time you choose WinGet.
- **Optional (recommended): the [superpowers](https://github.com/obra/superpowers) plugin.** If installed, the
  skill uses `superpowers:dispatching-parallel-agents` for the research fan-out and `superpowers:requesting-code-review`
  for the Reviewer gate. It is **not required** — without it the skill falls back to the native Agent tool and
  `/code-review`; nothing in the workflow depends on the plugin.

## Installation

Clone into your Claude Code skills directory (the repo root *is* the skill folder):

```bash
git clone https://github.com/pt1987/claude-code-psadt-skill.git ~/.claude/skills/psadt-deploy
```

On Windows (PowerShell):

```powershell
git clone https://github.com/pt1987/claude-code-psadt-skill.git "$env:USERPROFILE\.claude\skills\psadt-deploy"
```

The skill activates automatically when you ask Claude Code to build an Intune package, or when you work
in a folder containing `Invoke-AppDeployToolkit.ps1`.

## First-run setup

On the first run (or when you say *"psadt setup"*), the skill walks a short wizard and writes a local
`config.json`:

| Setting | Purpose |
|---|---|
| `paths.packageRoot` / `outputRoot` | Where packages live and where `.intunewin` files are written |
| `paths.intuneWinAppUtil` | Content-prep tool location (skill-managed by default) |
| `language.script` / `dossier` | Script language (EN) vs. dossier language (DE for the Company Portal) |
| `author.person` / `company` | Stamped into every package's `AppScriptAuthor` |
| `intune.*` *(optional)* | Direct-upload block (`clientId` / `tenantId` / credential ref) - written by `New-PsadtEntraApp.ps1`, validated when `intune.uploadEnabled` |
| `intune.groups.*` *(optional)* | Opt-in group assignment (`enabled` / `create` / `membershipType` / `naming`) - see guide Appendix M |

`config.json` and `tools/` are **machine-local** and are never committed.

## Project structure

Current (what ships today):

```
psadt-deploy/
├─ SKILL.md · README.md · CHANGELOG.md · LICENSE
├─ scripts/
│  ├─ Get-PsadtConfig.ps1           config read
│  ├─ Set-PsadtConfig.ps1           config write (+ DPAPI secret)
│  ├─ Get-PsadtModule.ps1           PSADT module (self-heal)
│  ├─ Get-IntuneWinAppUtil.ps1      content-prep tool (self-heal)
│  ├─ Get-WinGetModule.ps1          WinGet extension (opt-in)
│  ├─ Update-PsadtSkill.ps1         self-update from GitHub
│  ├─ Invoke-PsadtPreflight.ps1     pre-flight GREEN/RED gate (Phase 5)
│  ├─ Invoke-PsadtSystemTest.ps1    SYSTEM test loop (Phase 6)
│  ├─ New-PsadtReport.ps1           HTML package report (Phase 8, always)
│  ├─ New-MsiPackage.ps1            reusable MSI package generator (opt-in)
│  ├─ New-BrowserExtensionPackage.ps1  browser-extension force-install generator (opt-in)
│  ├─ New-WindowsFeaturePackage.ps1  windows optional-feature / capability generator (opt-in)
│  ├─ New-PsadtEntraApp.ps1         Entra app bootstrap (WAM)
│  ├─ Get-GraphToken.ps1            app-only Graph token (cert/DPAPI)
│  ├─ _GraphCommon.ps1              shared Graph helpers (3 upload scripts)
│  ├─ Invoke-IntuneWin32Upload.ps1  direct Intune upload (Phase 9)
│  └─ Invoke-IntuneAppAssignment.ps1 opt-in Entra group assignment (Phase 10)
├─ references/   guide (App. A-P) + Report-Template.html + app-registration.md
├─ tests/        Pester suite for the scripts
├─ tools/        (gitignored)  IntuneWinAppUtil.exe + WinGet module
├─ config.json   (gitignored)  machine-local settings (intune.* block)
└─ secret.dpapi  (gitignored)  DPAPI client secret (only without cert auth)
```

## Status

The core build/package/test/dossier workflow is in active use, and the **direct Intune upload** (Phase 9)
is implemented and verified against a live tenant. **Shipped:** first-run setup + config, self-healing
prerequisites (PSADT module + content-prep tool), HTML deliverables, the opt-in SYSTEM test loop, the WAM
Entra-app bootstrap, and the Graph win32LobApp uploader (coexistence-safe) — helper scripts verified via
the Pester suite in `tests/`.

## Roadmap

Planned features, in rough priority order. These are designed/specced and waiting to be built:

- **Sync finished packages to a GitHub repo** — a setup option (`output.target` = `local` / `git` /
  `both`) to push the per-app artifacts (`.intunewin`, dossier, detection, logo) to a Git repo instead
  of (or in addition to) a local folder — versioned and shareable, optionally not kept locally. Will use
  **Git LFS** for large `.intunewin` files (GitHub's 100 MB per-file limit).

Have a request? Open an issue.

## Contributing

Issues and pull requests are welcome. Keep `SKILL.md`, references, and docs in **English**. The only
non-English content is the generated end-user output (Intune dossier and Company-Portal app
description), whose language follows the `language.dossier` config value — **default German**, but
configurable per machine.

## License

[MIT](LICENSE) © Patrick Taubert, PHAT Consulting GmbH

## Acknowledgements

- [PSAppDeployToolkit](https://github.com/PSAppDeployToolkit/PSAppDeployToolkit)
- [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
- [`Invoke-CommandAs`](https://github.com/mkellerman/Invoke-CommandAs)
- README structure inspired by [ComposioHQ/awesome-claude-skills](https://github.com/ComposioHQ/awesome-claude-skills)

## Changelog

Notable changes to the skill, newest first. Append-only — entries are never removed. Also mirrored in
**[CHANGELOG.md](CHANGELOG.md)**.

### 0.15.1 - 15.06.2026
- **Generator hardening from a self-review (correctness + security).** All three generators now single-quote-escape
  values embedded in `$adtSession` literals, so an apostrophe in the App name/vendor/author (e.g. "Bob's App",
  "L'Oreal") no longer produces an unparseable package; the MSI `-AdditionalArgumentList` / `ProcessesToClose`
  literals are escaped too (also closing a SYSTEM code-injection path). Detection exit-code drift fixed:
  `New-MsiPackage.ps1` + the WinGet example now `exit 0` for "not installed" (a non-zero exit reads as a detection
  error), and a new **pre-flight Detection check** WARNs on a non-zero exit in `Detect*.ps1`. The WSUS bypass in
  `New-WindowsFeaturePackage.ps1` now saves all prior state before writing and runs inside the `try/finally`, so a
  partial failure can't leave `UseWUServer=0` permanently. Added input guards (`$Name` path-traversal, `__TOKEN__`
  leak), MSI `-Author` config fallback + `-InstallerPath` validation. Stale refs fixed (SKILL.md "A-M"->"A-P",
  `New-PsadtEntraApp.ps1` "Phase 7.5"->"Phase 9").

### 0.15.0 - 15.06.2026
- **Windows-feature packages (optional features + capabilities / FoD).** New `scripts/New-WindowsFeaturePackage.ps1`
  — one-call generator that enables Windows **Optional Features** (`Enable-WindowsOptionalFeature`: NetFx3,
  Hyper-V, WSL, TelnetClient, …) and **Capabilities / Features on Demand** (`Add-WindowsCapability`: RSAT.*,
  OpenSSH, …) from one typed list, multiple per package. Uninstall reverts (disable/remove); Repair re-enables
  (idempotent). Reboot surfaces **3010** via `$adtSession.SetExitCode(3010)` (`-NoRestart`); detection treats
  `EnablePending` as not-yet-done. Content comes from a bundled `-Source` (offline SxS) else Windows Update
  behind a **temporary** WSUS bypass (`RepairContentServerSource=2`, `UseWUServer=0`) whose exact prior state is
  restored. Guide **Appendix P**, SKILL.md Gate-1/anti-patterns/ref-lookup. Pre-flight GREEN; helper logic
  verified against an in-memory registry sim; ASCII-clean.

### 0.14.0 - 15.06.2026
- **Browser-extension force-install packages (Edge / Chrome / Firefox).** New
  `scripts/New-BrowserExtensionPackage.ps1` — one-call generator for force-installing browser extensions via
  enterprise **policy registry keys** (policy-only, no installer, ESP-safe). Multiple extensions per package.
  Chromium helper computes the **next free `ExtensionInstallForcelist` index** (never hard-codes `1`), dedupes by
  ID and removes only its own entry (coexistence); Firefox merges into the single `ExtensionSettings` JSON written
  as **`REG_MULTI_SZ`** (single-line `REG_SZ` is silently ignored — Mozilla bug 1750233). Guide **Appendix O**,
  SKILL.md Gate-1/anti-patterns/ref-lookup. Pre-flight GREEN; helpers validated against a scratch registry hive;
  ASCII-clean.

### 0.13.1 - 15.06.2026
- **Firewall policy body fixed against the live template (verified 201).** `New-IntuneFirewallPolicy.ps1`
  produced a body Graph rejected (400). Corrected via the **msgraph skill** (not guessed): the group id needs
  the `{firewallrulename}` token, the program path is the direct child `..._app_filepath`, action values are
  `_action_type_1`/`_0`, and a template-based policy requires `settingInstanceTemplateReference` per instance +
  `settingValueTemplateReference` per simple/choice value (profiles collection: instance ref only — a per-value
  ref is a duplicate). Confirmed by a live **201 Create**; tests assert the references. Mirrored into the
  MxManagementCenter Output deliverable.

### 0.13.0 - 15.06.2026
- **Self-contained firewall deliverable (copy-to-client safe).** `scripts/New-IntuneFirewallPolicy.ps1` is now
  fully self-contained — no dot-sourcing of `_GraphCommon`/`_GraphInteractive`, no skill path; WAM sign-in +
  policy body builder + console helpers are embedded. It runs on a test client that does **not** have the skill
  installed (`-Interactive` WAM, or `-GraphToken`). Fixes the "Skill script not found … -SkillRoot" failure when
  the deliverable was copied to another machine. New **binding SKILL.md convention "Self-contained deliverables"**
  + a Pester test that enforces it (no dot-source / no skill path / embeds WAM). Test-first per writing-skills.

### 0.12.0 - 15.06.2026
- **Interactive WAM sign-in for the Intune policy scripts.** `New-IntuneFirewallPolicy.ps1` and
  `New-IntuneTrustedCertPolicy.ps1` gain `-Interactive` (+ `-TenantId`): delegated sign-in via **WAM**
  (Windows Web Account Manager) when there is no app registration — **no device code**. The WAM machinery
  (`Initialize-MsalBroker` / `Get-WamToken` / new `Get-InteractiveGraphToken`) was extracted from
  `New-PsadtEntraApp.ps1` into a shared `scripts/_GraphInteractive.ps1` (one implementation, no copy-paste
  drift); the bootstrap now consumes it. The MxManagementCenter firewall deliverable became a thin wrapper
  over the generic script.

### 0.11.0 - 15.06.2026
- **Intune firewall-rules policy + app config-management permission.** New `scripts/New-IntuneFirewallPolicy.ps1`
  (Endpoint Security "Windows Firewall Rules" policy, one program-scoped rule; dry-run / `-Execute` / manual
  portal fallback) + Pester test. Suppresses the first-run Windows Firewall prompt for apps that listen inbound.
  New `New-PsadtEntraApp.ps1 -IncludeConfigurationManagement` consents `DeviceManagementConfiguration.ReadWrite.All`
  (needed by the firewall and trusted-cert policies for `-Execute`).

### 0.10.0 - 15.06.2026
- **Certificate store deployment (driver-trust / TrustedPublisher).** New `scripts/New-IntuneTrustedCertPolicy.ps1` —
  a Custom OMA-URI profile that places a certificate into a Windows machine store via the
  `RootCATrustedCertificates` CSP (the policy-based way to suppress the Windows "install device software?"
  driver-trust prompt). Guide Appendix N, dossier "Treiber-Zertifikat" row, SKILL.md convention + Pester test.

### 0.9.2 - 12.06.2026
- **Reconciled a diverged install copy back into the repo.** Fixed `Invoke-PsadtSystemTest.ps1` crashing at
  param binding under the WinPS 5.1 re-exec (`$SkillRoot` default is now fail-safe, so the SYSTEM Install/
  Uninstall gate works on a pwsh-7 host). Added per-field copy buttons + a `file://`-safe clipboard to the
  HTML dossier (`Report-Template.html`, token set unchanged). Added `scripts/New-MsiPackage.ps1` (reusable
  MSI package generator, `$PSScriptRoot`-relative, ASCII-only) + its Pester test.

### 0.9.1 - 12.06.2026
- **Applicability/portability drift cleanup** (docs + instructions; no script logic changed). Removed the
  phantom `test.maxIterations` / `test.endState` config keys from SKILL.md Phase 6 (the cap is a hard count of
  5 the orchestrator owns); fixed stale "Phase 7.5" -> **Phase 9** in SKILL.md + `app-registration.md`; fixed
  the README project tree (report **Phase 8**, added the 3 missing scripts `Invoke-PsadtPreflight`,
  `Invoke-IntuneAppAssignment`, `_GraphCommon`).
- **`superpowers` downgraded from hard `REQUIRED` to optional/preferred.** The Researcher/Reviewer roles now
  prefer `superpowers:*` if installed and otherwise fall back to the native Agent tool / `/code-review`; the
  Requirements list documents it as an optional (recommended) enhancement. The workflow no longer depends on it.

### 0.9.0 - 11.06.2026
- **Audit cleanup** (quality / content / applicability+compatibility / tests). Highlights: shared
  `scripts/_GraphCommon.ps1` (de-duplicates the 3 Graph scripts) + **28 new Pester tests** for the previously
  untested upload/assignment/Entra-app/token scripts (suite now 74); fixed an `Invoke-WithRetry` precedence
  bug (retried every error 6x) and PS7-fragile throttling reads; the HTML report no longer shows synthetic
  "passed" rows when no pre-flight/SYSTEM-test results are supplied (neutral "not run") and derives the PSADT
  version from the installed module; GUID `ValidatePattern` on the MSI codes.
- **Phase numbering unified** across SKILL.md + guide into one integer scheme **0-12**; every Phase/Appendix
  cross-reference re-verified. Anti-pattern list trimmed; SYSTEM-test prerequisites, `/beta` drift caveat,
  rollback step, logging convention, and config help added. Guide `$adtSession` template `1.0.0`->`0.1` +
  author-from-config; intro appendix index -> A-M.

### 0.8.1 - 11.06.2026
- **Docs consistency.** Fixed a stale cross-reference in SKILL.md (the guide range said **Appendix A-J** but
  the guide now runs through **M** — K/L were added in 0.7.0 and M in 0.8.0 without updating it). Restored the
  **0.5.3** entry that was missing from this README changelog mirror (it was present in `CHANGELOG.md`).

### 0.8.0 - 11.06.2026
- **Opt-in Entra group assignment, wired end-to-end.** New Phase 10 + `Invoke-IntuneAppAssignment.ps1`:
  create/reuse Entra security groups by a configured naming scheme (`intune.groups`) and assign the uploaded
  app (Required / Available / Uninstall). Read-only dry-run → confirm → execute; idempotent; never deletes a
  group or another app's assignment; ambiguous/duplicate names skipped. Least-privilege roles
  (`Group.Create` + `GroupMember.Read.All`) via `New-PsadtEntraApp.ps1 -IncludeGroupManagement`. Full
  reference in **guide Appendix M** (config schema, naming tokens, version-independent default vs `%version%`
  opt-in, permission model).
- **Upload min-OS fix.** `-MinWindowsRelease` is now a `ValidateSet` of backend-accepted release IDs
  (`1607..2004`) — `21H2`/`22H2` are server-rejected and used to kill the upload mid-flight with a Graph
  `BadRequest`. Fails fast at param binding instead; set a higher minimum in the portal. Guide **H.11**.

### 0.7.5 - 10.06.2026
- **Honest exit codes + detection (correctness fix).** Removed the dangerous "always `exit 0`" guidance from
  guide Appendix K — a blanket `exit 0` (or a detection tag written in a `finally`) reports GREEN on failure.
  New **K.7**: the exit code reflects whether the fix could RUN (couldn't-run -> non-zero; the 64-bit relaunch
  propagates the child's exit code), detection reflects the real END-STATE (tag only on success), with a
  per-package decision table; "never block enrollment" is now an explicit ESP-assignment + return-code-mapping
  choice, not a masked exit code. SKILL.md anti-pattern added.

### 0.7.0 - 10.06.2026
- **Value-adding extensions.** New `scripts/Invoke-PsadtPreflight.ps1` turns the Phase-5 Reviewer gate into one
  deterministic `GREEN/RED` tool (encoding/parse/v3-scan/top-level/structure/GUID-to-`-FilePath`), with a Pester
  suite. New guide **Appendix K** (script-only remediation / fix packages, ESP-safe — the debloat/Cisco pattern)
  and **Appendix L** (installer technologies + silent switches, a lookup consulted before web research). Expanded
  error-code catalogue (MSI 1603/1605/1619/1638/1639…, PSADT 60001/60008 + ranges) in guide Appendix A and the
  SKILL.md troubleshooting table. SKILL.md rewired to point at the pre-flight script and the new appendices.

### 0.6.2 - 10.06.2026
- **Audit & harden.** Agent-based audit + source-level verification (discarded ~8 false positives). Fixes: the
  guide's broken `New-ADTTemplate` "Extended scaffold" (passing app metadata params that v4.1.x rejects);
  the Graph uploader leaving its extracted work dir (with the AES keys in `Detection.xml`) in `%TEMP%` (now
  `try/finally` cleanup); the report `Notes` default `&middot;` double-escape; the fallback initials-SVG logo
  now XML-escapes + base64-encodes (no markup injection, with a regression test). Robustness: `Invoke-Graph`
  429/5xx retry with `Retry-After`; malformed-`config.json` safety in four scripts; WinGet 2-byte header read;
  symmetric temp cleanup in self-update. Graph request shapes left untouched.

### 0.6.1 - 10.06.2026
- **Report header flicker fixed** (`references/Report-Template.html`): at widths where the content height met
  the viewport edge, the vertical scrollbar toggled on/off and the header's `vw`-based `clamp()` padding and
  `h1` font-size reflowed on every toggle — a wild flicker loop. Reserving the scrollbar gutter
  (`html { overflow-y: scroll; scrollbar-gutter: stable; }`) keeps the width constant and breaks the loop.

### 0.6.0 - 10.06.2026
- **SKILL.md slimmed to a control plane** (733 → 244 lines, ~67% fewer tokens) via progressive disclosure:
  the long inline code moved into the reference guide (new **Appendix I** WinGet + **Appendix J** app-logo),
  loaded on demand. Intake restructured into **4 decision gates** (researchable facts become stated
  assumptions, not questions); explicit **sub-agent roles** (Researcher×3 / Builder / Reviewer) with GREEN
  handoff gates; a single **blockade protocol** for errors. No binding rule or behaviour dropped.

### 0.5.3 - 09.06.2026
- **Guide code-fences are now English/ASCII.** Anglicized every German comment, string literal and placeholder
  living **inside** PowerShell/text code fences in the guide (and the inline-code placeholders in the Appendix
  F.1 table) — snippets get copied verbatim into deployment scripts, where the binding rule is English + 7-bit
  ASCII. German explanatory **prose** and the **F.2 Company-Portal dossier template** deliberately stay German
  (legitimate `language.dossier` end-user text). No script/tooling code changed.

### 0.5.2 - 08.06.2026
- **HTML package report is now always generated** (upload or not) by `scripts/New-PsadtReport.ps1` from the
  fixed template `references/Report-Template.html`. One self-contained, **bilingual (DE/EN toggle)** document
  combining the Intune dossier + a technical package report; Fluent-2 styled, sticky shrink header, logo
  embedded as a data URI, description preview rendered from its Markdown source. New Pester test
  `tests/New-PsadtReport.Tests.ps1`.

### 0.5.1 - 06.06.2026
- Self-update now decides by **commit** (git `HEAD` vs `origin/main`, or the GitHub commits-API sha vs a
  recorded `tooling.skillCommit`) instead of the CHANGELOG version — no more CDN lag / circular version reads.
- README project-structure tree compacted so it renders without horizontal scroll.

### 0.5.0 - 06.06.2026
- **Skill self-update** — `scripts/Update-PsadtSkill.ps1` checks GitHub for a newer version, shows what's new,
  and updates in place on confirmation (`git pull` for a clone, else branch-zip overwrite of tracked files
  only; `config.json` / `secret.dpapi` / `tools/` preserved). Triggers: *"update skill"*, *"/update-skill"*,
  *"psadt update"*.

### 0.4.0 - 06.06.2026
- **WinGet packaging support** (strictly opt-in, never the default) + **certificate-based auth** for the Phase 9
  upload (no secret at rest) + MSI icon-table logo fallback + device-code first-poll fix. Contributed by
  **@joakim-i** (PR #4), reviewed and hardened before merge. See [CHANGELOG.md](CHANGELOG.md).

### 0.3.2 - 06.06.2026
- **Test-before-upload is now a binding gate:** Install + Uninstall must pass the Phase 6 SYSTEM test before
  any Phase 9 upload. If it can't be run (no elevation / VM), stop before upload and hand back the command.

### 0.3.1 - 06.06.2026
- `Invoke-IntuneWin32Upload.ps1` gains **`-DetectionScriptPath`** (PowerShell-script detection rule) for
  EXE / non-MSI installers without a ProductCode (e.g. Vivaldi). Verified live by uploading Vivaldi 8.0.4033.44.
- Lesson: a *detection* script rule accepts only `ruleType,enforceSignatureCheck,runAs32Bit,scriptContent`
  (guide Appendix H.2).

### 0.3.0 - 06.06.2026
- **Direct upload** (`scripts/Invoke-IntuneWin32Upload.ps1`, Phase 9): self-contained raw-Graph
  `win32LobApp` upload (parse `.intunewin` → token → probe → idempotency → create/update → content → SAS
  block-blob upload via HttpClient → commit → activate → categories → supersedence). Read-only dry-run by
  default; `-Execute` to write.
- **WAM Entra-app bootstrap** (`scripts/New-PsadtEntraApp.ps1`): interactive Windows-broker sign-in (device
  code fallback), creates the app + admin consent + secret, DPAPI-stored.
- **App-only token helper** (`scripts/Get-GraphToken.ps1`).
- **Coexistence-safe versioning:** never deletes an older version; new versions coexist; optional
  supersedence wiring. **Logo guard:** refuses the PSADT default `AppIcon.png`. Fills the full
  App-information tab; never auto-assigns category/notes/groups.
- Fixed the Repair `-FilePath`→`-ProductCode` example; reference guide gains **Appendix H**.

### 0.2.0 - 05.06.2026
- **Automated SYSTEM test loop** (`scripts/Invoke-PsadtSystemTest.ps1`, Phase 6): install → uninstall →
  reinstall the package as the SYSTEM account via `Invoke-CommandAs`, with agent-driven auto-fix until
  green or a max-iteration cap. Opt-in; elevated session required.
- Phase 8 now prefers `Invoke-CommandAs -AsSystem` for SYSTEM-context testing (PsExec kept as a fallback).

### 0.1.0 - 04.06.2026
- Initial release: guided PSADT v4 → Intune Win32 lifecycle (intake, autonomous research, scaffolding, all
  three deployment types, pre-flight checks, packaging, dossier + logo, guided testing, troubleshooting).
- First-run setup writing a machine-local `config.json` (paths, language, author).
- Self-healing prerequisites: PSAppDeployToolkit module (PSGallery) and `IntuneWinAppUtil.exe`
  (auto-download + version check).
- HTML dossier document with a Markdown app-description block (the Intune description field is
  Markdown-only).
- English skill + reference guide; MIT licensed.

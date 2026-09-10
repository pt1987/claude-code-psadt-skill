<h1 align="center">PSADT v4 → Intune Deployment Skill</h1>

<p align="center">
  <em>A Claude Code skill that drives the full lifecycle of a PowerShell App Deployment Toolkit (PSADT) v4.x Intune Win32 package — from first conversation to a tested, upload-ready <code>.intunewin</code>.</em>
</p>

<p align="center">
  <a href="https://github.com/pt1987/claude-code-psadt-skill/actions/workflows/tests.yml"><img src="https://github.com/pt1987/claude-code-psadt-skill/actions/workflows/tests.yml/badge.svg" alt="tests" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square" alt="License: MIT" /></a>
  <img src="https://img.shields.io/badge/PSADT-v4.x-0a7bbb?style=flat-square" alt="PSADT v4.x" />
  <img src="https://img.shields.io/badge/Platform-Windows-0078d6?style=flat-square&logo=windows&logoColor=white" alt="Windows" />
  <img src="https://img.shields.io/badge/Claude%20Code-Skill-d97757?style=flat-square" alt="Claude Code Skill" />
</p>

<p align="center"><sub><a href="#quick-start">Quick start</a> · <a href="#how-it-works">How it works</a> · <a href="#features">Features</a> · <a href="#first-run-setup">Setup</a> · <a href="#security">Security</a> · <a href="#roadmap">Roadmap</a> · <a href="#changelog">Changelog</a></sub></p>

---

## What is this?

A **Claude Code skill** (not a plugin): a reusable instruction package that teaches the agent how to build,
package, test, troubleshoot and deploy a **PSADT v4.x Intune Win32 app**. You describe the application; the
skill runs the workflow — intake, web research, scaffolding, all three deployment types
(Install / Uninstall / Repair), pre-flight checks, the SYSTEM test, packaging, the dossier, and the
optional Graph upload.

A skill is a folder with a `SKILL.md` (YAML frontmatter + Markdown instructions), here bundled with
`scripts/` and `references/`. It loads progressively: the agent sees only the name and description until a
task makes it relevant, then the full body loads on demand.

<img width="1024" height="254" alt="image" src="https://github.com/user-attachments/assets/7c7931ba-dcae-4476-a648-11115eceb3b5" />

## Quick start

```powershell
npx psadt-deploy-skill
```

That installs the skill into `~/.claude/skills/psadt-deploy` and runs the setup doctor, which provisions
everything it can and names the handful of values only you can supply (see
[First-run setup](#first-run-setup)). Then open Claude Code in any folder and say what you want:

> *"Create the Win32 Intune package for 7-Zip 24.09"* — or *"package Notepad++ for Intune"*

The skill asks at most **four decision gates** (scope · deployment semantics · SYSTEM-test consent ·
upload confirmation). Everything else it researches and states as an assumption instead of asking.

## How it works

Twelve phases, each owned by a script rather than by prose, so a step either passed or did not:

| Phase | What happens | Owner |
|---|---|---|
| **0** Setup | 13 prerequisite checks, GREEN/YELLOW/RED, `-Fix` provisions | `Initialize-PsadtSkill.ps1` |
| **1–2** Intake + research | blocker questions as clickable options; parallel research of version, silent switches, Intune pitfalls | agent (gates 1–2) |
| **3** Scaffold | a generator writes launcher + detection + per-run log name + manifest; `New-ADTTemplate` only when none fits | `New-MsiPackage` · `New-BrowserExtensionPackage` · `New-WindowsFeaturePackage` · `New-DriverPackage` |
| **4** Customize | all three hooks filled from the research, helpers in the Extensions module | agent |
| **5** Pre-flight | 10 checks (encoding, AST parse, v3 cmdlets, structure, detection contract, manifest, log name, driver trust …) → GREEN/RED | `Invoke-PsadtPreflight.ps1` |
| **6** SYSTEM test | installs/uninstalls as **SYSTEM** like the IME does; **binding before any upload** | `Invoke-PsadtSystemTest.ps1` |
| **7** Package | one command → verified `.intunewin`, named after the app | `Invoke-PsadtPackage.ps1` |
| **8** Dossier | always, uploaded or not: bilingual self-contained HTML | `New-PsadtReport.ps1` |
| **9** Upload *(opt-in)* | dry run → confirm → `win32LobApp` via raw Graph | `Invoke-IntuneWin32Upload.ps1` |
| **10** Assignment *(opt-in)* | create/reuse Entra groups by naming scheme | `Invoke-IntuneAppAssignment.ps1` |
| **11–12** Test + rollout | DEV-VM cycles, test group, pilot → staged production | agent |

**Everything one app knows lives in `<pkg>\psadt-package.json`** — identity, the decisions taken at the
gates, the research findings, every phase's result and the artifacts produced. The generators write it,
every later phase reads and updates it, and pre-flight fails without it. That is what stops two packages of
the same app from disagreeing about their own version.

Depth lives in `references/` (phases 0–12 + appendices A–Q, one file per domain — see
`references/README.md`); `SKILL.md` stays the
control plane.

## Features

### Setup and prerequisites

- **Setup doctor** — one idempotent script checks PowerShell 7, Windows PowerShell 5.1, elevation, git,
  PSAppDeployToolkit, the content-prep tool, `Invoke-CommandAs`, Pester, the config, a legacy config, the
  skill tree, a pending update and the Intune credentials. Each line carries a concrete fix; `-Fix` applies
  the ones that need no decision.
- **Self-healing prerequisites** — installs the PSAppDeployToolkit module from the PowerShell Gallery and
  downloads `IntuneWinAppUtil.exe`, keeping both current against their official sources.
- **Config outside the skill folder** — `config.json`, `secret.dpapi` and `tools/` live in
  `%LOCALAPPDATA%\psadt-deploy\` (override: `$env:PSADT_DEPLOY_HOME`), so a `git pull`, a re-clone or a
  re-install can no longer take your setup with it. A pre-0.19 config keeps working and is migrated on
  request, never deleted.
- **One-line install** — `npx psadt-deploy-skill` (Node 18+, zero dependencies) does clone-or-update plus
  the doctor run in one step.

### Build and verify

- **Guided intake** — the blocker questions up front as clickable options, pre-filled with researched
  defaults (app, latest version, installer type, package type).
- **Autonomous research** — checks the installed PSADT version against the latest release *and* whether
  commands changed; researches silent install / uninstall / repair switches and known Intune pitfalls.
- **All three deployment types from the start** — Install, Uninstall *and* Repair, acid-tested, so
  Company-Portal uninstalls actually work.
- **Pre-flight gate** — encoding/BOM, AST parse, launcher acid test, v3-cmdlet scan, hook structure,
  detection-script contract, the package manifest, the per-run log name and driver trust. GREEN or RED,
  with the failing file named.
- **Automated SYSTEM test loop** *(opt-in, binding before upload)* — installs, uninstalls and reinstalls as
  the **SYSTEM** account via `Invoke-CommandAs`, mirroring the Intune Management Extension; reads the fresh
  session log and the detection result, and hands back a structured verdict for the fix-and-retry loop.
  Needs an elevated session; belongs on a VM with a snapshot.
- **Deterministic packaging** — `<outputRoot>\<Vendor>_<App>_<Version>_<Arch>\<same stem>.intunewin`,
  verified after the fact (`Detection.xml`, `SetupFile`, size, SHA256), with the detection script and the
  real logo beside it. It refuses an output folder inside the package, and never deletes a foreign
  `.intunewin` it finds there.
- **One PSADT log per run** — `<Vendor>_<App>_<Version>_<Arch>_<Install|Uninstall|Repair>_<timestamp>.log`
  instead of every run of every version appending to one unreadable file.

### Package types

The app's **native installer is always the default**. Everything else is opt-in and only on request:

- **MSI / EXE** — the ordinary case, via `New-MsiPackage.ps1` or a hand-filled scaffold.
- **WinGet** — the full `PSAppDeployToolkit.WinGet` lifecycle: the extension module self-heals into the
  package, the Package ID is discovered with `Find-ADTWinGetPackage`, hooks use `*-ADTWinGet*`
  (`-Scope Machine`). Never selected on its own initiative.
- **Browser extensions** — force-install via the Edge/Chrome/Firefox policy keys (including the Firefox
  `REG_MULTI_SZ` trap), with selective removal on uninstall.
- **Windows features** — `Enable-WindowsOptionalFeature` and `Add-WindowsCapability`, offline source or a
  temporary WSUS bypass that is restored afterwards, `EnablePending` handled honestly.
- **Third-party drivers** — the trust situation is classified *before* anything is built: Microsoft-signed
  installs silently, vendor-signed needs the signer certificate owned in exactly one place, and a
  vendor-signed **kernel** driver is refused because `TrustedPublisher` satisfies the PnP prompt but never
  Code Integrity — it would install and then not load. Unsigned is refused outright, with three honest
  options and no testsigning. Staging is per-INF `pnputil`; uninstall resolves `oemNN.inf` by original name
  instead of a remembered index.
- **Script-only / remediation packages** — ESP-safe patterns for fix packages with no installer at all.

### Deliverables

- **HTML dossier — always generated**, uploaded or not. One self-contained file
  (`Intune-Dossier.html`) built from a fixed template, never hand-assembled: the **Intune dossier** (App
  Info, return-code map, detection rule, requirements, assignments, driver trust, and a ready-to-paste
  **Markdown** description for the Company-Portal field) plus a **technical package report** (the three
  hooks, PSADT cmdlets used, pre-flight and SYSTEM-test results, logo and `.intunewin` verification).
  Bilingual with a DE/EN toggle, browser-translatable, logo embedded as a data URI.
- **Real logo only** — finds and downloads the actual application logo (vendor source or Wikimedia
  Commons), verifies real pixel transparency *and* looks at the image. The PSADT default `AppIcon.png` is
  blocked by hash.
- **Start Menu only** — creates Start Menu entries and removes stray desktop icons.

### Intune

- **Access as state, not as a 403** — `Test-PsadtIntuneAccess.ps1` answers before Phase 9 whether the app
  can upload, assign groups or create policies, and for how long the credential lives. Verified / refused /
  **unknown** are three different answers, and an offline check never overwrites what was verified before.
- **Direct upload via Microsoft Graph** *(opt-in)* — pushes the `.intunewin` as a `win32LobApp` (app +
  logo), self-contained raw Graph, no third-party module. Identity comes from the manifest, so Intune shows
  the same name and version as the artifact and the dossier. Read-only dry run → confirm → upload. Fills the
  whole App-information tab, **never deletes an older version** (new versions coexist, with optional
  supersedence wiring), never auto-assigns categories or notes.
- **One-time Entra bootstrap** — `New-PsadtEntraApp.ps1` signs in via **WAM**, creates the app, grants and
  admin-consents the roles and stores the credential: a **certificate** (preferred — nothing secret at rest,
  JWT client-assertion auth) or a DPAPI-encrypted client secret. Re-running it is normal: it finds the
  recorded app, merges requested permissions instead of replacing them, and never prompts.
- **Opt-in group assignment** — creates/reuses Entra security groups by a configured naming scheme and
  assigns Required / Available / Uninstall. Least-privilege (`Group.Create` + `GroupMember.Read.All`),
  dry run → confirm, idempotent, and it never deletes a group or another app's assignment.
- **Certificate + firewall policies** — Custom OMA-URI profiles for `TrustedPublisher` / `TrustedPeople`
  (the built-in template cannot reach those stores) and settings-catalog firewall-rule policies. Both
  scripts are self-contained deliverables: they can be copied to a test client that has no skill installed.

### Operations

- **Troubleshooting** — decodes Intune error/HRESULT codes, maps symptoms to root causes, and triages the
  right log (`AppWorkload.log`, the PSADT session log, `setupapi.dev.log` for drivers).
- **Self-update** — `scripts/Update-PsadtSkill.ps1` compares against GitHub, shows what changed, and
  updates in place on your confirmation (`git pull --ff-only` for a clone, otherwise a branch-zip overwrite
  of tracked files only). Machine-local state is never touched. Say *"psadt update"*.
- **441 Pester tests** over the helper scripts, including drift guards that fail when the docs and the code
  disagree.

## Requirements

- Windows with PowerShell 5.1+ / PowerShell 7+
- For the `npx` installer only: **Node 18+** (the skill itself never needs Node)
- [PSAppDeployToolkit](https://psappdeploytoolkit.com/) v4.x *(installed/updated automatically from the
  PowerShell Gallery if missing)*
- [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
  *(provisioned automatically)*
- For the **SYSTEM test loop**: an **elevated** session; the
  [`Invoke-CommandAs`](https://github.com/mkellerman/Invoke-CommandAs) module is installed automatically
- For the **direct Intune upload**: an Entra app with the Graph application role
  `DeviceManagementApps.ReadWrite.All` (admin-consented) — created in one run by
  `scripts/New-PsadtEntraApp.ps1` (WAM sign-in as Global Admin / Privileged Role Admin, device-code
  fallback). Check what is actually in place with `scripts/Test-PsadtIntuneAccess.ps1`. Full permission
  matrix and the manual portal route: `references/app-registration.md`.
- For **Pester tests**: Pester 5+ (`Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser`)
- **Optional (recommended): the [superpowers](https://github.com/obra/superpowers) plugin** — if installed,
  the research fan-out and the reviewer gate use it. Not required: without it the skill falls back to the
  native Agent tool and `/code-review`, and nothing in the workflow depends on the plugin.

## Installation

```powershell
npx psadt-deploy-skill
```

Installs the **newest release** into `~/.claude/skills/psadt-deploy` and runs the setup doctor. Flags:
`--dir <path>` · `--project` (into `./.claude/skills`) · `--ref <tag|branch>` · `--no-setup`. Node 18+ and
Windows; the installer itself has zero dependencies and the package carries only `bin/` — the skill is
fetched from GitHub at install time.

### Which version you get

The default is the newest **release tag**, not `main`. This skill registers an Entra application with
admin consent and writes to an Intune tenant; installing whatever last landed on `main` is not a
defensible default for that.

```powershell
npx psadt-deploy-skill                 # newest release (default)
npx psadt-deploy-skill --ref v0.26.7   # pin an exact release
npx psadt-deploy-skill --ref main      # the development branch, deliberately
```

**For managed environments:** pin a tag, read the diff between it and the next one before moving, then
lift the pin. Releases are tagged `vX.Y.Z` and match the [Changelog](#changelog); tags exist from
**v0.24.0** onward — earlier versions predate the current history and cannot be tagged retroactively.

Re-running the installer updates an existing installation, and so does saying *"psadt update"* to Claude
Code. What counts as an update depends on what you installed: on a **pinned release** it is the next
release tag — unreleased work on `main` is deliberately invisible, because that is what pinning means. On
a **branch** installation it is the next commit, as before. Either way the update overwrites tracked
repository files only; `config.json`, `secret.dpapi` and `tools/` are never touched.

**Or clone it yourself** — the repo root *is* the skill folder:

```powershell
git clone https://github.com/pt1987/claude-code-psadt-skill.git "$env:USERPROFILE\.claude\skills\psadt-deploy"
pwsh "$env:USERPROFILE\.claude\skills\psadt-deploy\scripts\Initialize-PsadtSkill.ps1" -Fix
```

`npx skills add pt1987/claude-code-psadt-skill` works too, since `SKILL.md` sits in the repository root.

No git on the machine? The installer falls back to the GitHub tarball and Windows' own `tar.exe`, so the
one-liner still works — including with `--ref <tag>`, which is the combination a locked-down machine
actually needs.

The skill activates automatically when you ask Claude Code to build an Intune package, or when you work in
a folder containing `Invoke-AppDeployToolkit.ps1`.

### What is deliberately not in the skill frontmatter

`SKILL.md` declares `name`, `description` and `license`, and nothing else. The omissions are choices, not
oversights:

- **`paths`** would look like the right way to express "activates in a folder containing
  `Invoke-AppDeployToolkit.ps1`". It is the opposite: the field *limits* activation to files matching the
  globs. Setting it would switch the skill off for the most common request there is — packaging an app in
  an empty folder, where `Invoke-AppDeployToolkit.ps1` does not exist yet because Phase 3 is what creates
  it. The folder case is covered by the last sentence of the description instead.
- **`allowed-tools`** grants tools up front; it does not restrict them. For a skill that installs software
  as SYSTEM and writes to a tenant, being asked per call is the point. See [`SECURITY.md`](SECURITY.md).
- **`metadata.version`** is ignored by Claude Code, and the version already lives in `CHANGELOG.md`,
  `package.json` (kept in sync by a test) and on the website. A fourth place to forget on release day, for
  no behaviour, is not worth it.
- **`shell`** only matters for `!` command injection in `SKILL.md`, which this skill does not use — and a
  failing `!` command aborts the *entire* skill invocation, so an `Initialize-PsadtSkill` call wired up that
  way would be a single point of failure for every packaging request.
- **`context: fork` / `agent`** would isolate the skill in a subagent. It orchestrates its own sub-agents
  and needs the main context to hold the decision gates.

## First-run setup

`scripts/Initialize-PsadtSkill.ps1` (also reachable by saying *"psadt setup"* / *"psadt doctor"*) checks
every prerequisite in one pass and reports **GREEN / YELLOW / RED**. Every line comes with a concrete fix
hint, and `-Fix` applies the ones that need no decision (module installs, the tool download, the
`language.*` defaults, `paths.intuneWinAppUtil`, and migrating a pre-0.19 config). It is idempotent — run it
as often as you like.

Only four values genuinely need you; the doctor lists them in `.Missing` and takes them via `-Set`:

```powershell
pwsh scripts/Initialize-PsadtSkill.ps1 -Fix -Set @{
    'paths.packageRoot' = 'D:\Pakete'; 'paths.outputRoot' = 'D:\Intune'
    'author.person'     = 'Pat Taubert'; 'author.company' = 'PHAT Consulting'
}
```

| Setting | Purpose |
|---|---|
| `paths.packageRoot` / `outputRoot` | Where packages are built and where artifacts are written |
| `paths.intuneWinAppUtil` | Content-prep tool location — filled by `-Fix` |
| `language.script` / `dossier` | Script language (EN) vs. dossier language (DE for the Company Portal) — filled by `-Fix` |
| `author.person` / `company` | Stamped into every package's `AppScriptAuthor` |
| `intune.*` *(optional)* | Direct upload: tenant/client, credential reference, verified roles — written by `New-PsadtEntraApp.ps1` |
| `intune.groups.*` *(optional)* | Opt-in group assignment (`enabled` / `create` / `membershipType` / `naming`) — guide Appendix M |

### Where the setup is stored

`config.json`, `secret.dpapi` and `tools/` live in the **config home** — `%LOCALAPPDATA%\psadt-deploy\`,
overridable with `$env:PSADT_DEPLOY_HOME` — **not** in the skill folder, so they survive a `git pull`, a
re-clone and a re-install. They are machine-local and never committed. A `config.json` from a pre-0.19
install (beside `scripts/`) keeps working read-only; the doctor flags it and `-Fix` migrates it, renaming
the originals to `*.migrated` rather than deleting anything.

> DPAPI is bound to the Windows user profile: a re-installed OS invalidates a stored client secret. The
> doctor and `Test-PsadtIntuneAccess.ps1` both say so, and the fix is one `New-PsadtEntraApp.ps1` run.

## Project structure

```
psadt-deploy/
├─ SKILL.md · README.md · CHANGELOG.md · SECURITY.md · LICENSE
├─ package.json · bin/install.mjs        the npx installer (Node 18+, zero dependencies)
├─ scripts/
│  │  setup + config
│  ├─ Initialize-PsadtSkill.ps1          setup doctor (Phase 0, GREEN/YELLOW/RED, -Fix/-Set)
│  ├─ Get-PsadtConfig.ps1                config read + config-home resolver
│  ├─ Set-PsadtConfig.ps1                config write (deep merge, DPAPI secret, -Remove)
│  ├─ Get-PsadtModule.ps1                PSADT module (self-heal)
│  ├─ Get-IntuneWinAppUtil.ps1           content-prep tool (self-heal)
│  ├─ Get-WinGetModule.ps1               WinGet extension (opt-in)
│  ├─ Update-PsadtSkill.ps1              self-update from GitHub
│  │  per-package truth
│  ├─ Get-PsadtPackageManifest.ps1       manifest read (+ the artifact stem)
│  ├─ Set-PsadtPackageManifest.ps1       manifest write (merge / append)
│  │  package generators
│  ├─ New-MsiPackage.ps1                 MSI packages
│  ├─ New-BrowserExtensionPackage.ps1    browser-extension force-install (opt-in)
│  ├─ New-WindowsFeaturePackage.ps1      optional features / capabilities (opt-in)
│  ├─ New-DriverPackage.ps1              driver packages, pnputil staging (opt-in)
│  ├─ Get-DriverSignatureInfo.ps1        driver trust classifier (signed? kernel? deployable?)
│  │  gates + deliverables
│  ├─ Invoke-PsadtPreflight.ps1          pre-flight GREEN/RED gate (Phase 5, 10 checks)
│  ├─ Invoke-PsadtSystemTest.ps1         SYSTEM test (Phase 6)
│  ├─ Invoke-PsadtPackage.ps1            build the .intunewin (Phase 7, named + verified)
│  ├─ New-PsadtReport.ps1                HTML dossier (Phase 8, always)
│  │  intune / graph
│  ├─ New-PsadtEntraApp.ps1              Entra app bootstrap (WAM)
│  ├─ Get-GraphToken.ps1                 app-only Graph token (cert / DPAPI)
│  ├─ Test-PsadtIntuneAccess.ps1         access verdict (roles, capabilities, expiry)
│  ├─ Invoke-IntuneWin32Upload.ps1       direct upload (Phase 9)
│  ├─ Invoke-IntuneAppAssignment.ps1     group assignment (Phase 10, opt-in)
│  ├─ New-IntuneTrustedCertPolicy.ps1    Custom OMA-URI cert policy (self-contained)
│  ├─ New-IntuneFirewallPolicy.ps1       firewall-rule policy (self-contained)
│  ├─ _GraphCommon.ps1                   shared Graph helpers (retry, errors, token roles)
│  └─ _GraphInteractive.ps1              shared WAM sign-in
├─ references/
│  ├─ README.md                          the reference map (label -> file)
│  ├─ phases-0-6.md · phases-7-12.md     the twelve phases
│  ├─ appendix-a-errors.md … -q-drivers.md  one file per appendix
│  ├─ Report-Template.html               the fixed dossier template
│  └─ app-registration.md                THE Graph permission matrix + manual portal route
└─ tests/                                Pester suite, 441 tests
```

Machine-local state lives outside the skill folder:

```
%LOCALAPPDATA%\psadt-deploy\             ($env:PSADT_DEPLOY_HOME overrides)
├─ config.json                           settings incl. the optional intune.* block
├─ secret.dpapi                          DPAPI client secret (only without cert auth)
└─ tools/                                IntuneWinAppUtil.exe + WinGet module
```

And per package, next to `Invoke-AppDeployToolkit.ps1`:

```
psadt-package.json                       identity · gate decisions · research · results · artifacts
```

## Status

In active use for the full build → package → test → dossier workflow, with the direct Graph upload
verified against a live tenant. The helper scripts are covered by 441 Pester tests.

One open point, honestly: **the driver `pnputil` exit-code semantics are documented, not verified here.**
`0` / `259` / `3010` and the two `0xE...` failures come from Microsoft's documentation; confirming them
against `setupapi.dev.log` on a DEV VM with a real vendor-signed and a real Microsoft-signed driver is
still open.

## Security

This skill installs software as SYSTEM, researches on the open web, and writes to an Intune tenant
through an Entra app with admin consent. [`SECURITY.md`](SECURITY.md) states that risk surface next to
the control that already covers each part of it — the dry-run-before-execute rule, the three-valued
access check, never-delete, role assertion before the first write, certificate before DPAPI secret,
the config home outside the skill folder, and the self-containment rule for anything that ships to a
test client. Each control names the file that implements it and the test that enforces it, so a review
can check the claims rather than take them.

Two deliberate non-features are explained there as well: the skill does **not** declare
`allowed-tools` (that field pre-approves tools, it does not restrict them), and content fetched during
research is treated as data, never as instructions — see
[`references/research-trust.md`](references/research-trust.md).

## Roadmap

Designed and waiting to be built:

- **Sync finished packages to a GitHub repo** — a setup option (`output.target` = `local` / `git` / `both`)
  to push the per-app artifacts (`.intunewin`, dossier, detection, logo) to a Git repo instead of, or in
  addition to, a local folder — versioned and shareable. Will need **Git LFS** for large `.intunewin` files
  (GitHub's 100 MB per-file limit).

Have a request? Open an issue.

## Contributing

Issues and pull requests are welcome. Keep `SKILL.md`, the references and the docs in **English**. The only
non-English content is the generated end-user output (the Intune dossier and the Company-Portal app
description), whose language follows the `language.dossier` config value — **default German**, but
configurable per machine.

Two conventions worth knowing before you send a patch: generated `.ps1` content is **7-bit ASCII** (the
pre-flight fails on non-ASCII without a BOM), and anything that lands in a package's output folder must be
**self-contained** — it gets copied to test clients that have no skill installed.

## License

[MIT](LICENSE) © Patrick Taubert, PHAT Consulting GmbH

## Acknowledgements

- [PSAppDeployToolkit](https://github.com/PSAppDeployToolkit/PSAppDeployToolkit)
- [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
- [`Invoke-CommandAs`](https://github.com/mkellerman/Invoke-CommandAs)
- README structure inspired by [ComposioHQ/awesome-claude-skills](https://github.com/ComposioHQ/awesome-claude-skills)

## Changelog

The two most recent releases are below. **[CHANGELOG.md](CHANGELOG.md)** carries the complete history,
every release since 0.1.0, and nothing is ever removed from it - this section is a window onto it, not a
second copy to keep in sync.

### 0.27.1 - 10.09.2026
- **Fixed: das Dossier erfand Fakten über das Paket und druckte sie als Aussage.** Beim Paketieren zweier
  echter Apps zum Test von 0.27.0 aufgefallen. Ohne `-Metadata` behauptete der Report `_Beschreibung folgt._`
  als Company-Portal-Text — der wird unverändert nach Intune übernommen und liest sich wie ein fertiges Feld —
  sowie `Start-ADTMsiProcess` und „Nutzerdaten bleiben erhalten" als Hook-Inhalt, für welches Paket auch immer
  gerade berichtet wurde. Ein WinMerge-Paket, das ausschließlich `Start-ADTProcess` mit Inno-Switches aufruft,
  wurde so viermal mit einem Cmdlet beschrieben, das es nie verwendet. Nichts kennzeichnete das als Vermutung.
- **Hooks und Cmdlet-Liste werden jetzt per AST aus dem echten Launcher gelesen**, je `*-ADTDeployment`-Funktion.
  Kein Launcher vorhanden: „nicht ermittelbar" statt einer plausiblen Liste. Ein explizites `-Metadata` gewinnt
  weiterhin.
- **Eine fehlende Beschreibung warnt und wird sichtbar markiert — und wird bei `decisions.upload = true`
  verweigert**, in derselben Form wie das bestehende SYSTEM-Test-Gate. `-AllowMissingDescription` ist der
  bewusste, sichtbare Ausweg.
- **Der Header-Status wird aus den Belegen abgeleitet** statt auf „Upload-bereit · getestet" zu defaulten.
- **SKILL.md Phase 8** sagt jetzt, dass die Beschreibung Pflicht ist; vorher stand dort nur, wie sie zu
  formatieren wäre. Suite 474 → 484.
### 0.27.0 - 10.09.2026
- **Fixed: after auto-compaction, half of SKILL.md was gone.** Claude Code re-attaches only the **first
  5000 tokens** of an invoked skill after a summary. SKILL.md was ~10 10900, so the cut fell at line 198 — the
  middle of Phase 2. In exactly the sessions long enough to compact, the skill lost Phases 3–12, the whole
  troubleshooting table, every anti-pattern and the reference map. The fix is **ordering, not size**: the
  operating mode, the four gates, the conventions and Phases 0–6 now sit ahead of the cut, and Phase 6 ends
  at byte 17 457 of a 17 500-byte budget — with a test that fails if it ever crosses back.
- **Fixed: `--ref <tag>` returned HTTP 404 on the tarball route.** The installer built
  `tar.gz/refs/heads/<ref>`, and `refs/heads` only resolves *branches* — so pinning worked with git and failed
  on exactly the machines without it, which are the ones most likely to need a pinned release.
  `Update-PsadtSkill.ps1` had the same latent bug in its archive path.
- **Fixed: a failed install exited 127 instead of 1**, with a libuv assertion after the error message. A
  mistyped `--ref` printed a correct explanation and then looked like a crash.
- **Changed: the default install is the newest release tag, not `main`.** This skill registers an Entra app
  with admin consent and writes to a tenant; installing whatever last landed on a branch is not a defensible
  default for that. `--ref main` and `--ref v0.27.0` both remain. The update check now distinguishes a
  release-pinned installation (counts *releases* behind) from one following a branch.
- **Changed: the 2942-line deployment guide is now nineteen files**, one per domain, with
  `references/README.md` as the map. Section numbering is unchanged, so every "App. L.1" and "Phase 6.2"
  still resolves.
- **Changed (behaviour): Phase 11 no longer re-runs Phase 6.** Phase 6 answers *does the package work* (the
  gate, in a throwaway Sandbox); Phase 11 answers *does the delivery work* (Intune test group, real device,
  `AppWorkload.log`). A package that passes 6 and fails 11 now tells you something.
- **Changed: `"update skill"` is gone from the description** — un-namespaced, it made this skill answer for
  every other updatable skill on the machine. `"psadt update"` stays.
- **Added `SECURITY.md`** — the risk surface next to the control that covers each part of it, each naming the
  file and the test that implement it.
- **Added: researched content is data, never instructions** (`references/research-trust.md`) — Phase 2
  researches on the open web and the result runs as SYSTEM. The install4j case generalised.
- **Added three guards and CI**: rule anchors proving no binding rule was lost in the move, a two-directional
  doc cross-reference check that also reads `scripts/`, a context-budget test, and the suite on a clean
  Windows runner for every push. Suite 441 → 474.
- **Added `evals/`** — 20 trigger and behaviour cases. Not yet run: `claude plugin eval` is in early access.

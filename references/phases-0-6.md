# Phases 0-6: setup, research, build, the SYSTEM test

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Contents

- [0.1 Where the setup lives (config home)](#01-where-the-setup-lives-config-home)
- [0.2 The verdict](#02-the-verdict)
- [0.3 The four keys only a human can supply](#03-the-four-keys-only-a-human-can-supply)
- [0.4 Optional add-ons (not part of the verdict)](#04-optional-add-ons-not-part-of-the-verdict)
- [1.1 Check the current PSADT version](#11-check-the-current-psadt-version)
- [1.2 Intake questions about the app (before a single line of code exists)](#12-intake-questions-about-the-app-before-a-single-line-of-code-exists)
- [1.3 Web research on the specific installer](#13-web-research-on-the-specific-installer)
- [1.4 External runtime prerequisites the installer does not bundle](#14-external-runtime-prerequisites-the-installer-does-not-bundle)
- [3.1 Load the module, generate the scaffold](#31-load-the-module-generate-the-scaffold)
- [3.2 What the scaffold produces](#32-what-the-scaffold-produces)
- [3.3 First verification of the scaffold](#33-first-verification-of-the-scaffold)
- [4.1 Put the installer in `Files\`](#41-put-the-installer-in-files)
- [4.2 Finalize the `$adtSession` metadata](#42-finalize-the-adtsession-metadata)
- [4.3 Fill the Install/Uninstall/Repair hooks](#43-fill-the-installuninstallrepair-hooks)
- [4.4 Extensions module for helper functions](#44-extensions-module-for-helper-functions)
- [5.1 Encoding check (UTF-8 with BOM or ASCII-only)](#51-encoding-check-utf-8-with-bom-or-ascii-only)
- [5.2 Parse check](#52-parse-check)
- [5.3 Launcher simulation (acid test)](#53-launcher-simulation-acid-test)
- [5.4 Param block vs. v4 template](#54-param-block-vs-v4-template)
- [5.5 Leftover v3 cmdlets](#55-leftover-v3-cmdlets)
- [5.6 Top-level statements outside try/catch](#56-top-level-statements-outside-trycatch)
- [6.1 Default route: the whole loop in a Windows Sandbox](#61-default-route-the-whole-loop-in-a-windows-sandbox)
- [6.2 Per-action route (DEV VM, or an app the sandbox cannot host)](#62-per-action-route-dev-vm-or-an-app-the-sandbox-cannot-host)
- [6.3 Run it in parallel with Phases 7 and 8](#63-run-it-in-parallel-with-phases-7-and-8)
- [6.4 The manual interactive test a GREEN verdict cannot replace](#64-the-manual-interactive-test-a-green-verdict-cannot-replace)

## Phase 0: Setup (Doctor)

One script answers "is this machine ready?" - run it before anything else, and again whenever something
behaves oddly:

```powershell
pwsh scripts/Initialize-PsadtSkill.ps1          # read-only report
pwsh scripts/Initialize-PsadtSkill.ps1 -Fix     # + provision / migrate what needs no decision
```

It is idempotent: a second run with `-Fix` changes nothing.

### 0.1 Where the setup lives (config home)

`config.json`, `secret.dpapi` and `tools/` do **not** live in the skill folder. They live in the **config
home**, resolved in this order:

1. an explicitly passed `-SkillRoot` (tests and special cases only)
2. `$env:PSADT_DEPLOY_HOME`
3. `%LOCALAPPDATA%\psadt-deploy` (the default)

**Why:** the pre-0.19 layout kept everything inside the skill folder, so a `git pull`, a re-clone or a
re-install silently took the whole setup with it - and any script started from an output folder could not
find the config at all. A config beside `scripts/` from an older install still works, read-only: the doctor
reports it as `LegacyConfig WARN`, and `-Fix` migrates it (config and secret are copied to the home and the
originals renamed to `*.migrated` - nothing is deleted - `tools/*` is moved, and a recorded
`paths.intuneWinAppUtil` is rebased onto the new home).

### 0.2 The verdict

`Overall` is `GREEN` (all clear), `YELLOW` (only warnings - packaging works) or `RED` (a hard blocker).
Only a `FAIL` turns it red. Each check carries `Name`, `Status`, `Detail` and a `Fix` hint:

| Check | FAIL means | Fix |
|---|---|---|
| `PowerShell7` | host is 5.1 | re-run with `pwsh` |
| `PsadtModule` | PSAppDeployToolkit missing - no scaffold possible | `-Fix` (PSGallery) |
| `IntuneWinAppUtil` | content-prep tool missing - no `.intunewin` | `-Fix` (download) |
| `Config` | no config, malformed JSON, or required keys missing | `-Set` for human keys, `-Fix` for the rest |

Warn-only checks: `WindowsPowerShell51` and `Elevation` (both needed by the Phase 6 SYSTEM test, not by
packaging), `Git` (without it self-update falls back to the branch-zip route), `InvokeCommandAs` (self-heals
on first use), `Pester` (test suite only), `LegacyConfig`, `SkillLocation`, `SkillUpdate`, `IntuneAccess`.

### 0.3 The four keys only a human can supply

`.Missing` lists exactly the values the doctor cannot invent:

| Key | Purpose |
|---|---|
| `paths.packageRoot` | where packages are built |
| `paths.outputRoot` | where `.intunewin` + dossier are written |
| `author.person` | stamped into `AppScriptAuthor` |
| `author.company` | stamped into `AppScriptAuthor` |

Ask for these (and only these) via `AskUserQuestion`, then persist and re-check in one call:

```powershell
pwsh scripts/Initialize-PsadtSkill.ps1 -Fix -Set @{
    'paths.packageRoot' = 'D:\Pakete'
    'paths.outputRoot'  = 'D:\Intune'
    'author.person'     = 'Pat Taubert'
    'author.company'    = 'PHAT Consulting'
}
```

`language.script` (EN) / `language.dossier` (DE) and `paths.intuneWinAppUtil` never appear in `.Missing` -
`-Fix` fills them. Machine-readable output for other tooling: `-Json` (to stdout) or `-JsonPath <file>`.
`-SkipUpdateCheck` suppresses the only network call in the read-only path.

### 0.4 Optional add-ons (not part of the verdict)

- **WinGet packaging path**: `pwsh scripts/Get-WinGetModule.ps1` downloads the
  `PSAppDeployToolkit.WinGet` extension into the config home's `tools/` (and into the package). Only needed
  when the app is packaged from WinGet - see Appendix I.
- **Direct Intune upload** (Phase 9, opt-in): run `pwsh scripts/New-PsadtEntraApp.ps1` once. Interactive WAM
  sign-in with device-code fallback; creates the `PSADT Intune Upload` Entra app, admin-consents
  `DeviceManagementApps.ReadWrite.All` and stores the credential (DPAPI secret, or `-UseCertificate
  -CertThumbprint`). Needs Global Admin / Privileged Role Admin. Two opt-in flags widen the consent:
  - `-IncludeGroupManagement` adds the least-privilege group roles `Group.Create` + `GroupMember.Read.All`
    for opt-in group assignment (Phase 10 / Appendix M).
  - `-IncludeConfigurationManagement` adds `DeviceManagementConfiguration.ReadWrite.All` so the app can
    create config / Endpoint-Security policies app-only (`New-IntuneFirewallPolicy.ps1`,
    `New-IntuneTrustedCertPolicy.ps1`).

  Permission matrix + manual portal route: `references/app-registration.md`. The doctor's `IntuneAccess`
  check reports the local side (identity + credential present and decryptable). For the tenant's answer -
  which roles are actually consented, and how long the credential still lives - run the read-only verdict:

  ```powershell
  pwsh scripts/Test-PsadtIntuneAccess.ps1
  ```

  It reports `TokenOk` as `VERIFIED` / `REFUSED` / `UNKNOWN` plus a capability per feature
  (`Upload` / `Groups` / `Configuration`), each of which can be `unknown` rather than `no` - Graph tokens
  are opaque by contract, so "we could not tell" is a distinct answer from "not permitted". Verified roles
  are cached in `intune.roles` with a `intune.lastVerified` timestamp; an offline run never overwrites them.
  **Gate on `Capabilities.<X>` before Phase 9 / Phase 10 / a cert or firewall policy** instead of finding out
  from a 403 mid-upload.

---

## Phase 1-2: Research + Intake (DO NOT skip)

### 1.1 Check the current PSADT version

Before any package is built: is the local PSADT module still up to date? Breaking changes between minor versions do happen (4.0.x -> 4.1.x parameter renames).

`scripts/Get-PsadtLocalEvidence.ps1` already answers the *command-drift* half of this locally: it reads
the installed module's manifest with `Import-PowerShellDataFile` (never `Import-Module` - that has side
effects) and compares `FunctionsToExport` against the commands this skill uses. So no sub-agent is ever
spent on "did a cmdlet get renamed" - only the release-notes read below needs the network.

**Check commands (online + local):**

```powershell
# Local module version
Get-Module -ListAvailable -Name PSAppDeployToolkit | Select-Object Version,Path

# Latest release info from GitHub (API, no auth)
$rel = Invoke-RestMethod 'https://api.github.com/repos/PSAppDeployToolkit/PSAppDeployToolkit/releases/latest'
"Latest: $($rel.tag_name) from $($rel.published_at)"
$rel.body -split "`n" | Select-Object -First 40   # Changelog excerpt
```

**Check the documentation status:**
- Release notes: https://psappdeploytoolkit.com/docs/getting-started/release-notes
- Migration guide (v3 -> v4): https://psappdeploytoolkit.com/docs/migration/migrate-from-v3
- Reference index (all cmdlets): https://psappdeploytoolkit.com/docs/reference
- Blog (releases + community updates): https://psappdeploytoolkit.com/blog
- Discourse (forum): https://discourse.psappdeploytoolkit.com/latest

**Decision:**
- Local < latest minor: update the module (`Update-Module PSAppDeployToolkit -Force` or extract from the GitHub release) BEFORE building a new package
- Local == latest: continue
- Local > latest (beta): downgrade to stable, no beta in production

The module version in the package `<pkg>\PSAppDeployToolkit\PSAppDeployToolkit.psd1` `ModuleVersion = '<VER>'` must exactly match what the script declares in `$adtSession.DeployAppScriptVersion = '<VER>'` AND the `Invoke-AppDeployToolkit.exe` build version (right-click properties, details).

### 1.2 Intake questions about the app (before a single line of code exists)

Without answers to these points the package will be junk. Clarify with the stakeholder / user:

**App identity:**
- Exact product name and vendor (as it should appear in the Company Portal)
- Version (marketing version + file version in the MSI / Setup.exe)
- Language (EN, DE, Multi?)
- Architecture (x86 / x64 / ARM64 / Universal)
- Licensing model (Freeware, Pro, Enterprise, Named User, Device, Subscription? License key needed? Activation server?)

**Installer:**
- Source medium: MSI, EXE wrapper (around an MSI), InstallShield, NSIS, AppX/MSIX, Squirrel, self-built?
- Download URL of the official installer (for reproducibility) + hash
- Silent install switches known? (see 0.3)
- Uninstall method: MSI product code, uninstall string in the registry, custom uninstaller?
- Repair support?
- Reboot behavior (requires, recommends, never)
- Dependencies: .NET, VC++ Redist, Java, Edge WebView2, PowerShell version?

**Target environment:**
- Intune target audience (user- or device-based? AAD group, filter?)
- Install context: System (classic), User (rare), Available + Required?
- Minimum OS version, architecture filter
- Coexistence with previous versions: in-place upgrade, side-by-side, force-uninstall old versions?
- Conflicting apps: are there competing products that have to go?
- Roaming profiles / FSLogix / non-persistent VDI?

**Runtime behavior:**
- Processes that have to be closed (for `AppProcessesToClose` in `$adtSession`)
- Visible UI during install (Silent vs. NonInteractive)?
- User notifications desired (welcome dialog, defer button, countdown)?
- Required environment variables / registry policies
- Firewall rules / service accounts

**Configuration / customizing:**
- Default settings that should be overridden (startup behavior, telemetry opt-out, updater disablement, default folder)
- Registry keys / ADMX / XML / JSON to inject
- Files to copy into AppData / ProgramData
- Shortcuts (Desktop, Start Menu) to place or remove?

**Detection:**
- How do you prove unambiguously that it is installed? The MSI product code is usually enough; for EXE installers often file version + registry.
- A mandatory functional test (e.g. "DB reachable", "service running") or is a presence check sufficient?

**Uninstall / cleanup:**
- What MUST be cleaned up on uninstall (keep user data? remove registry leftovers?)
- What MUST NOT be deleted (shared components, user templates)?
- Should uninstall also kill previous versions or only the one it installed itself?

**Security:**
- Credentials needed in the installer (service account, API key, cert)? How are they passed to the install without ending up in the log/filesystem?
- PII / GDPR-relevant configuration?
- Signature check expected?

Use this list as an intake form; whatever stays open = risk in the deployment.

### 1.3 Research on the specific installer - gated

Without these answers there is no successful silent install. But most of them are already on this
machine, and Phase 2 used to pay three parallel sub-agents to go looking for them anyway.

**Run the ladder FIRST - before any query below, and before dispatching anything:**
```
pwsh scripts/Get-PsadtLocalEvidence.ps1 -Path <installer>
```
**Before the installer exists**, which is the normal Phase 1 state, run it on identity alone - it still
reads the registry and the corpus, and rung 1 can close the uninstall question outright:
```
pwsh scripts/Get-PsadtLocalEvidence.ps1 -ProductName '<App>' -Publisher '<Vendor>' -ProductVersion '<x.y>'
```
**Re-run it the moment the binary lands in `Files\`.** Everything rung 2 would have answered comes back
as `recheck-after-binary` in `Deferred[]` until then, and nothing else in the workflow goes back for it.

Four rungs, all deterministic, all offline (rung 0 is the toolchain check from 1.1):

| Rung | Question | What answers it |
|---|---|---|
| 1 | **Is it already installed here?** | the Uninstall registry (HKLM 64-bit + 32-bit views, HKCU). A `QuietUninstallString` is not a claim - it is the vendor's own registration of a silent uninstall that works. `UninstallString`, `InstallLocation`, `InstallSource`, the ProductCode in the key name and `HelpLink` come with it. |
| 2 | **Is the binary here?** | probe it, never search for it: `Get-PsadtSwitchCandidates.ps1` (engine, verified-switch store, ranked candidates - L.0) and, for an MSI, `Get-PsadtMsiFacts.ps1` - identity, signature, SHA256, features, decoded upgrade flags, shortcuts, file versions, registry rows and the Icon table in ONE call. Never hand-roll either (App. G). |
| 3 | **Is it already written down?** | this skill's own corpus (App. A / B / G / L), plus a vendor documentation URL taken from `HelpLink`, `URLInfoAbout` or the MSI's `ARPHELPLINK`. The ladder NAMES that URL and never fetches it - one direct fetch by you is the cheap middle step between the ladder and an agent. |

Rung 2 has two outcomes and both are useful. **Candidates returned** - the remaining search confirms a
specific switch on this build instead of discovering one from scratch. **No candidate** - the output
names the engine it could not resolve, and why; that is the sharper search term, and it says the probe
run is the only thing that will settle it.

The ladder returns every question in one of three states - `Closed` (local evidence answers it),
`Provisional` (a local claim exists, and the Phase 6 probe run settles it, not a web search) or
`Open` - plus three collections:

- `OpenQuestions[]` - the questions a sub-agent is the right tool for
- `AgentBudget` - their count
- `Deferred[]` - still open, but not worth an agent of its own: `probe-run`, `recheck-after-binary`,
  `accept-unanswered`, `folded`. Nothing is dropped silently.

**`AgentBudget` is the dispatch rule** (`rule:research-gate`, anchored in SKILL.md). Zero open
questions means zero sub-agents. N open questions
means at most N, one per question, and each agent gets that question's `KnownContext` - the engine, the
ProductCode, the provisional switch, the ARP row - so it searches to CONFIRM rather than to discover.
A fixed three-agent fan-out is an anti-pattern (App. B), and it is where a 400k-token research pass
came from.

Questions that one vendor page answers **fold**: on a binary the engine probe cannot identify, install,
uninstall and post-install config open together, and dispatching three agents for them would be worse
than the fan-out being replaced. The rider stays visible in `Deferred[]` as `folded` and the carrier's
prompt is told to answer it too. So the worst case is three agents, the common case two, and a
re-package the store already knows can be zero.

Two questions can **never** be closed locally, and the ladder says so with `CanCloseLocally = $false`:
the **external runtime prerequisite** (1.4) and **known Intune pitfalls**. A statement about other
people's fleets does not follow from this machine. Those are the agents worth spending.

**Query templates - for an OPEN question, never for a closed one:**
```
"<AppName>" "<Version>" silent install command line
"<AppName>" msi transform mst enterprise deployment
"<AppName>" uninstall silent /quiet /qn
"<AppName>" site:<vendor-docs-domain> deployment guide
"<AppName>" known issues intune win32
```

**Official sources always first:**
- Vendor admin guide / enterprise deployment guide (Adobe Admin Console, Autodesk Enterprise, Microsoft Docs, ...)
- Release notes for the specific version
- Knowledge base / support forum of the vendor

**Community sources (for validation):**
- `silentinstallhq.com` - silent switches for many apps
- `deploymentresearch.com` - Tim Mangan's archive
- PSADT Discourse: https://discourse.psappdeploytoolkit.com/search
- `/r/SCCM`, `/r/Intune` on Reddit
- GitHub: search for `<appname> intune win32` or `<appname> PSADT`

Whatever comes back is a CLAIM, whichever rung produced it. The ladder shortens the search; it never
ends it, and it never replaces Phase 6 (`research-is-data`, `references/research-trust.md`).

**Document the minimal result:**

| Question | Answer | Source | Closed by |
|---|---|---|---|
| Silent install CMD | `<...>` | | rung 2 - stage-0 hash match, or MSI |
| Silent uninstall CMD | `<...>` | | rung 1 - `QuietUninstallString`, or the ProductCode |
| Known exit codes (success, reboot, error) | `0, 3010, ...` | | `Get-PsadtReturnCodes.ps1`; an MSI closes the rest |
| Installer log file path | `<...>` | | rung 2 - engine default |
| Dependency installer (if separate) | `<...>` | | rung 2 for a Burn bundle; otherwise the Phase 6 run |
| External runtime prerequisite (1.4) | `<...>` | | **never locally - agent** |
| Known Intune pitfalls | `<...>` | | rung 3 narrows it; **otherwise agent** |
| Known post-install config (registry / XML) | `<...>` | | rung 2 - the MSI Property / Registry / Shortcut tables |
| Repair strategy (native verb, or uninstall + install) | `<...>` | | rung 2 for an MSI (`/f{omus}`); rung 1 `ModifyPath` is a claim, not a silent repair |

Without this table filled in - every row either answered, or explicitly `Closed` / `Deferred` by the
ladder: **do not package**.

**Example (Adobe Acrobat Pro):**
- Admin guide: https://www.adobe.com/devnet-docs/acrobatetk/
- Customization Wizard (build the MST): https://www.adobe.com/devnet-docs/acrobatetk/tools/Wizard/index.html
- Package via Adobe Admin Console (Creative Cloud): the official path for newer versions

**Example (Oracle Database XE):**
- Docs: https://docs.oracle.com/en/database/oracle/oracle-database/21/xeinw/
- Silent install: `setup.exe /s /f1"XEInstall.rsp"` + response file
- Known pitfall: `svc_oracle` must exist BEFORE install (which is why the script creates the service account)

### 1.4 External runtime prerequisites the installer does not bundle

<!-- rule:runtime-prerequisite -->
**Research whether the app needs a separate runtime it does not carry, and surface the answer at
Gate 1.** This is its own question because no later phase can ask it. Phase 5 parses the package,
Phase 6 drives Install/Detect/Uninstall/Repair against the detection script, and Phase 11 watches the
delivery - none of them ever launches the application. A package can therefore pass every gate GREEN
while the installed app is inert, and the first person to find out is the user it was assigned to.

The shape to look for: an app whose vendor ships the runtime as a *separate* download and expects it
to be present - R for RStudio, a JRE for several Java IDEs, a specific .NET Desktop Runtime version an
installer references but does not include. A bundled or chained runtime is not this case; the test is
whether a clean machine that ran only this installer can actually start the app.

Answer it from the vendor's system-requirements or enterprise-deployment page, not from a forum post -
and treat the answer as a claim until something confirms it (`research-is-data`, `references/research-trust.md`).

When one is found, it is a **Gate 1 option set**, never a silent decision:

| Option | When |
|---|---|
| Separate package + Intune app dependency | **Recommended.** The runtime is versioned, reusable across apps and visible in Intune. |
| Bundle the runtime installer into this package | One consumer, or the vendor pins an exact runtime build. |
| Document as a manual prerequisite | The runtime is already managed elsewhere and only needs recording. |
| Skip for now | A deliberate, recorded decision - it lands in the manifest and in the dossier. |

Record the choice in the manifest with the rest of the Gate 1 answers, so the dossier reports it.

---

## Phase 3: Scaffold via `New-ADTTemplate`

Do not create folders manually. The official cmdlet builds the correct structure.

### 3.1 Load the module, generate the scaffold

```powershell
# One-time - or when the installed version is outdated
Install-Module PSAppDeployToolkit -Scope CurrentUser -Force
# Alternative: download the .zip from the GitHub release and extract it manually to $HOME\Documents\PowerShell\Modules\PSAppDeployToolkit\<ver>\

Import-Module PSAppDeployToolkit
```

The values come from the intake in Phase 1.2 - replace `<...>` with the ACTUAL values of the app currently being packaged.

**Basic scaffold (only destination + name):**
```powershell
New-ADTTemplate -Destination '<RootFolder>' -Name '<AppName>'
# e.g. New-ADTTemplate -Destination '<paths.packageRoot from config>' -Name 'FooBar 10'
```

Creates `<RootFolder>\<AppName>\` with the complete v4 structure. `New-ADTTemplate` in v4.1.x takes ONLY
`-Destination` / `-Name` / `-Version` / `-Force` / `-Show` / `-PassThru` — it does NOT accept app-metadata
parameters. The default is `-Version 4` (current v4 style); `-Version 3` gives the v3 compatibility template
(you no longer need that in 2026).

**App metadata is NOT a `New-ADTTemplate` parameter** — do not pass `-AppVendor/-AppName/-AppVersion/-AppArch/...`
(v4.1.x throws "A parameter cannot be found that matches parameter name 'AppVendor'"). Instead, after scaffolding,
fill the metadata directly in the generated `Invoke-AppDeployToolkit.ps1`'s `$adtSession = @{ ... }` hashtable
(AppVendor / AppName / AppVersion / AppArch / AppLang / AppRevision / AppSuccessExitCodes / AppRebootExitCodes /
`AppScriptVersion = '0.1'` / AppScriptAuthor from config) plus the `.NOTES` changelog. See Phase 3 field details below.

> The `Adobe Acrobat Pro` and `Oracle XE` references further down in this document are illustration only - for every new package the app TO BE PACKAGED is inserted here, not Adobe or Oracle.

### 3.2 What the scaffold produces

```
<Destination>\<Name>\
  Invoke-AppDeployToolkit.exe          # 4.x Launcher
  Invoke-AppDeployToolkit.ps1          # Template with Pre/Install/Post hooks
  PSAppDeployToolkit\                  # Complete module (psd1 + psm1 + lib\)
  PSAppDeployToolkit.Extensions\       # Empty extension shell (your own code home)
  Files\                               # Installer binaries go here
  SupportFiles\                        # MST, INI, XML, Scripts
  Assets\                              # Icon (AppIcon.png), Logos
  Config\                              # PSADT Config-Overrides (optional)
  Strings\                             # Localization overrides (optional)
```

### 3.3 First verification of the scaffold

```powershell
$pkg = '<scaffold path>'   # e.g. '<paths.packageRoot from config>\<AppName>'
# the module version in the scaffold must match the installed version
(Import-PowerShellDataFile "$pkg\PSAppDeployToolkit\PSAppDeployToolkit.psd1").ModuleVersion
# Template version in the script
Select-String "$pkg\Invoke-AppDeployToolkit.ps1" -Pattern 'DeployAppScriptVersion' -List | Select-Object Line
```

Both must match (typically `4.1.8`). If they diverge -> reinstall the module + scaffold again.

---

## Phase 4: Script customizing

### 4.1 Put the installer in `Files\`

Everything that is `setup.exe`, `*.msi`, `*.mst`, response files, runtime assets lands under `<pkg>\Files\`.
In the script then use `$adtSession.DirFiles` as the root.

> Identify the installer technology and its silent/uninstall/no-reboot/log switches from **Appendix L**
> (consult it BEFORE web-searching). For a *script-only* fix/remediation/debloat package (no vendor installer),
> follow **Appendix K** instead.

### 4.2 Finalize the `$adtSession` metadata

In `Invoke-AppDeployToolkit.ps1` check the hashtable (see 0.2 Intake for the values):

```powershell
$adtSession = @{
    AppVendor                   = '<Vendor>'
    AppName                     = '<Product-ShortName>'
    AppVersion                  = '<Major.Minor.Build.Rev>'
    AppArch                     = '<x64|x86|ARM64>'
    AppLang                     = '<EN|DE|Multi>'
    AppRevision                 = '<01>'
    AppSuccessExitCodes         = @(0, 1707)                           # add installer-specific codes
    AppRebootExitCodes          = @(1641, 3010)
    AppProcessesToClose         = @('<process1>', '<process2>')        # names without .exe; from Phase 1.2
    AppScriptVersion            = '0.1'                                # ALWAYS start at 0.1 (never 1.0.0); bump with the .NOTES changelog
    AppScriptDate               = '<YYYY-MM-DD>'
    AppScriptAuthor             = '<author.person>, <author.company>'  # from config (Get-PsadtConfig), never hard-coded
    RequireAdmin                = $true
    InstallName                 = ''
    InstallTitle                = ''
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters   = $PSBoundParameters                    # or a sanitized dictionary if there are secrets
    DeployAppScriptVersion      = '<matching the ModuleVersion from the scaffold>'
}
```

### 4.3 Fill the Install/Uninstall/Repair hooks

The scaffold has three empty functions: `Install-ADTDeployment`, `Uninstall-ADTDeployment`, `Repair-ADTDeployment`. Each has Pre/Install/Post MARK sections.

**Minimal pattern for MSI:**
```powershell
function Install-ADTDeployment {
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"
    Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CheckDiskSpace -RequiredDiskSpace 3000
    Show-ADTInstallationProgress

    $adtSession.InstallPhase = $adtSession.DeploymentType
    # The .mst lives in Files\ next to the MSI: a bare name is resolved against the MSI folder, and PSADT
    # passes TRANSFORMSSECURE=1, whose rule is a transform source next to the package. A full path (e.g.
    # into SupportFiles\) is accepted, but then the transform is not at the package source.
    # No -ArgumentList: it REPLACES the config defaults (REBOOT=ReallySuppress /QN); the /L*V log is
    # appended separately either way. Extra MSI properties go into -AdditionalArgumentList 'PROP=value'.
    Start-ADTMsiProcess -FilePath "$($adtSession.DirFiles)\<installer>.msi" -Transforms '<transform>.mst'

    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"
    # clean up shortcuts, set registry keys, disable the update service, etc.
}
```

**Pattern for an EXE wrapper:**
```powershell
Start-ADTProcess -FilePath "$($adtSession.DirFiles)\setup.exe" -ArgumentList '/silent /allusers=1 /log="C:\Windows\Logs\Software\install.log"' -SuccessExitCodes @(0, 3010, 1641) -WaitForMsiExec
```

Always pass `-SuccessExitCodes` - otherwise Start-ADTProcess throws on anything != 0.

### 4.4 Extensions module for helper functions

Custom helpers belong in `<pkg>\PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1` - NOT directly in the main script. Reasons: reuse, clean namespaces, the main script stays readable.

```powershell
# PSAppDeployToolkit.Extensions.psm1
function Set-CompanyBranding { ... }
function Disable-AppUpdater    { ... }
Export-ModuleMember -Function Set-CompanyBranding, Disable-AppUpdater
```

The main script loads the extensions automatically (the block `Get-ChildItem ... -match 'PSAppDeployToolkit\..+$'` at the end of `Invoke-AppDeployToolkit.ps1`).

---

## Phase 5: Pre-flight checks

Run everything in this phase. Each failure = DO NOT continue.

> **Fast path:** `scripts/Invoke-PsadtPreflight.ps1 -PackagePath <pkg>` runs all of 3.1-3.6 in one shot and
> returns `{ Overall = 'GREEN'|'RED'; Checks = ... }` (GREEN required to proceed). The sub-sections below
> explain each check so you can diagnose a RED; the script is the gate, this is the reference.

### 5.1 Encoding check (UTF-8 with BOM or ASCII-only)

PowerShell 5.1 reads a .ps1 without a BOM as Windows-1252. UTF-8 multibytes (em-dash `—`, arrow `→`, umlauts, typographic quotes, ellipsis `…`) fall apart. In double-quoted strings a misinterpreted em-dash **closes** the string prematurely (UTF-8 `E2 80 94` -> CP1252 `â€"`, last byte = `"`). Parse error. The script NEVER runs. Intune shows `0x80070001`, no local logs.

```powershell
$s = '<path-to-ps1>'
$bytes = [System.IO.File]::ReadAllBytes($s)
$hasBom = $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$text = [System.IO.File]::ReadAllText($s, [System.Text.Encoding]::UTF8)
$nonAscii = [regex]::Matches($text, '[^\x00-\x7F]') | ForEach-Object { $_.Value } | Sort-Object -Unique
"HasBOM=$hasBom NonAscii=$($nonAscii -join ' ') Count=$(([regex]::Matches($text,'[^\x00-\x7F]')).Count)"
```

Acceptance criterion: `HasBOM=True` OR `Count=0`. Both = defense in depth.

Fix, if not:
```powershell
$text = [System.IO.File]::ReadAllText($s, [System.Text.Encoding]::UTF8)
$text = $text -replace [char]0x2014, '-'      # em-dash
$text = $text -replace [char]0x2013, '-'      # en-dash
$text = $text -replace [char]0x2192, '->'     # right arrow
$text = $text -replace [char]0x2018, "'"      # left single quote
$text = $text -replace [char]0x2019, "'"      # right single quote
$text = $text -replace [char]0x201C, '"'      # left double quote
$text = $text -replace [char]0x201D, '"'      # right double quote
$text = $text -replace [char]0x2026, '...'    # ellipsis
[System.IO.File]::WriteAllText($s, $text, [System.Text.UTF8Encoding]::new($true))
```

### 5.2 Parse check

```powershell
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($s, [ref]$null, [ref]$errs)
if ($errs) { $errs | Select Message,@{N='L';E={$_.Extent.StartLineNumber}} } else { 'PARSE_OK' }
```

IMPORTANT: `Parser::ParseFile` detects UTF-8-without-BOM correctly and often reports `PARSE_OK` even though powershell.exe via the launcher still blows up. The 3.3 test is the REAL gate.

### 5.3 Launcher simulation (acid test)

The `Invoke-AppDeployToolkit.exe` launcher calls PS5.1 with `-Command "try { & 'script.ps1' ... } catch { throw }; exit $Global:LASTEXITCODE"`. Replicate exactly that:

```powershell
Start-Process powershell.exe -ArgumentList `
    '-ExecutionPolicy','Bypass','-NonInteractive','-NoProfile','-NoLogo',`
    '-Command', "try { & '$s' -DeploymentType Install -DeployMode Silent } catch { throw }; exit `$Global:LASTEXITCODE" `
    -Wait -NoNewWindow -RedirectStandardError stderr.log
Get-Content stderr.log
```

Parse errors in stderr despite a green 3.2 = encoding bug, back to 3.1.

For scripts that trigger real installers: stub the Install-ADTDeployment body (see Appendix C).

### 5.4 Param block vs. v4 template

The param block in the main script must match `<pkg>\PSAppDeployToolkit\Frontend\v4\Invoke-AppDeployToolkit.ps1`. As of 4.1.8:

```powershell
[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)][ValidateSet('Install','Uninstall','Repair')][System.String]$DeploymentType,
    [Parameter(Mandatory=$false)][ValidateSet('Auto','Interactive','NonInteractive','Silent')][System.String]$DeployMode,
    [Parameter(Mandatory=$false)][System.Management.Automation.SwitchParameter]$SuppressRebootPassThru,
    [Parameter(Mandatory=$false)][System.Management.Automation.SwitchParameter]$TerminalServerMode,
    [Parameter(Mandatory=$false)][System.Management.Automation.SwitchParameter]$DisableLogging
)
```

NOT: `$AllowRebootPassThru` (v3 thinking). Append your own parameters (e.g. `$DbPassword`) at the end, and remove them from `$iadtParams` BEFORE `Open-ADTSession`.

### 5.5 Leftover v3 cmdlets

Forbidden in the code:

| v3 (gone) | v4 (correct) |
|---|---|
| `Execute-Process` | `Start-ADTProcess` |
| `Execute-MSI` | `Start-ADTMsiProcess` |
| `Write-Log` | `Write-ADTLogEntry` |
| `Show-InstallationWelcome` | `Show-ADTInstallationWelcome` |
| `Show-InstallationProgress` | `Show-ADTInstallationProgress` |
| `Show-InstallationPrompt` | `Show-ADTInstallationPrompt` |
| `Show-InstallationRestartPrompt` | `Show-ADTInstallationRestartPrompt` |
| `Get-InstalledApplication` | `Get-ADTApplication` |
| `Remove-MSIApplications` | `Uninstall-ADTApplication` |
| `Test-PowerPoint` | `Test-ADTPowerPoint` |
| `Get-LoggedOnUser` | `Get-ADTLoggedOnUser` |
| `Block-AppExecution` | `Block-ADTAppExecution` |
| `Refresh-Desktop` | `Update-ADTDesktop` |
| `Update-GroupPolicy` | `Update-ADTGroupPolicy` |

Scan:
```powershell
$v3 = @('Execute-Process','Execute-MSI','Write-Log','Show-InstallationWelcome','Show-InstallationProgress','Show-InstallationPrompt','Get-InstalledApplication','Remove-MSIApplications','Refresh-Desktop','Update-GroupPolicy','Block-AppExecution')
$t = [System.IO.File]::ReadAllText($s)
foreach ($fn in $v3) { $m = [regex]::Matches($t, "\b$fn\b"); if ($m.Count) { "V3_FOUND: $fn ($($m.Count)x)" } }
```

### 5.6 Top-level statements outside try/catch

Anything that is NOT inside a try/catch and throws = exit 1 = no log. At top level only the following are allowed: attributes, the param block, simple `$var = @{...}`, preference variables, `Set-StrictMode`, `try/catch`.

```powershell
$ast = [System.Management.Automation.Language.Parser]::ParseFile($s, [ref]$null, [ref]$null)
$ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] } |
    ForEach-Object { "L$($_.Extent.StartLineNumber): $($_.GetType().Name)" }
```

Anything that is not an `AssignmentStatementAst` / `PipelineAst` (for Set-StrictMode) / `TryStatementAst` = check it.

---

## Phase 6: SYSTEM test (the binding gate for upload)

Short by design - the mechanics live in `scripts/Invoke-PsadtSystemTest.ps1` (comment-based help) and the
lessons in Appendix G.

**It is BINDING before any upload, and skippable only when no upload is planned.** That is not a matter of
discipline any more: the decision is `decisions.upload` in the package manifest, and
`New-PsadtReport.ps1 -ManifestPath` throws on a missing SYSTEM test when it is `true`.

### 6.1 Default route: the loop in a Windows Sandbox

```powershell
# The default IS the gate - all five scenarios, the only route to GREEN.
pwsh scripts/Invoke-PsadtSandboxTest.ps1 -PackagePath '<pkg>' `
    -PathsPresentAfterInstall 'C:\Program Files\<App>\<app>.exe' `
    -PathsAbsentAfterUninstall 'C:\Program Files\<App>\<app>.exe'

# Deliberate iteration on a package already known to be broken: the binding pair only.
pwsh scripts/Invoke-PsadtSandboxTest.ps1 -PackagePath '<pkg>' -Quick -PathsPresentAfterInstall ...
```

One command, one throwaway VM, **every action as SYSTEM** through a scheduled task, exactly like the
Intune Management Extension. Returns
`{ Verdict, Steps, FailedAssertions, Assertions, InstalledAppFacts, ResultPath, LogFolder }`, writes
`results.sandboxTest` plus one `results.systemTest[]` entry per action, and copies the PSADT logs back
to the host.

**One run by default, because a VM run has a floor price.** Measured 2026-09-17 on the VS Code gate:
406 s total, of which **139 s is fixed overhead** - VM boot, guest prep, the two canaries, teardown -
before a single deployment action executes. So "test cheaply first, then gate" quietly buys a second
boot: ~2.3 minutes, plus the pair itself. A package that is right the first time pays that for nothing,
and with the evidence snapshot and the pre-flight checks in place, right-the-first-time is now the
common case (Audacity 4.0.0 and VS Code 1.138.0, both 2026-09-17, both green on the first attempt).

**Fail-fast is what makes a single full run safe.** The old objection to gating first - "iterating on
the full gate wastes minutes when the package is broken" - was real, and it is answered in the harness
rather than by a smaller default: the moment Install or Uninstall is red, Reinstall, Repair and the
final Uninstall are SKIPPED and the report says why. They assert against the machine the failed action
was supposed to leave behind, so they could only ever re-prove the same failure. Measured 2026-09-16 on
Firefox 156.0: four consecutive RED runs (**7.0 / 6.4 / 5.9 / 6.9 min**) each carried on through all
five scenarios after the uninstall had already failed - roughly 3 minutes of dead VM time per run.
A broken package therefore now costs about what the short pair costs, without anyone having to choose
in advance. `-Quick` remains for deliberate iteration; it reports `GREEN_PARTIAL`, which
`New-PsadtReport.ps1` refuses to build an upload dossier on, so a shortened run can never be mistaken
for the gate. `-Quick` together with an explicit `-Scenarios` throws rather than silently picking one.

**Every action snapshots the installed-application entry, successful ones included.** The Install
step's own ARP row - `DisplayName`, `DisplayVersion`, `UninstallString`, `QuietUninstallString`,
`InstallLocation`, and the property TYPES as PSADT hands them to the launcher - comes back as
`InstalledAppFacts` and lands under `<Output>\SandboxTest\installed-apps\`. **Write resolver hooks
against those strings, never against a guess.** This exists because guessing them cost four VM runs in
one session: the ARP `DisplayName` was `Mozilla Firefox (x64 en-US)` with the version in a SEPARATE
`DisplayVersion` property, and `InstallLocation` arrives as `[System.IO.DirectoryInfo]`, so a hook
calling `.TrimEnd()` on it threw `MethodNotFound` at run time. Before this, the dump ran only when a
detection result contradicted its action - and after a successful Install, nothing contradicts anything.

**A vendor-specific success code has to be in BOTH lists.** `-SuccessExitCodes` on this harness (default
`0, 1707, 3010, 1641`) is a DIFFERENT list from the `-SuccessExitCodes` on each `Start-ADTProcess` inside
the launcher. The launcher's list decides whether PSADT throws; the harness's list decides whether the step
is painted green. Put a code in only one of them and a cleanly deployed package reports a failure it does
not have. Measured on Citrix Workspace 26.3.10.69, whose Repair returns **40032** ("already at the current
version", CTX695019): the launcher accepted it, the run still came back RED, and the second fix attempt was
spent on the launcher that was already correct. When an action returns a documented non-zero success code,
change both places in the same edit.

Why this is the default:
- **No elevation on the host** and the host is never modified, so the test is available in an ordinary
  packaging session instead of being deferred to "a DEV VM later" - which in practice means never.
- **Every action starts from a machine that has never seen the app**, so "it passed because the previous
  run left something behind" cannot happen.
- The verdict is keyed on the **detection script**, which is what Intune evaluates. Package-specific facts
  (an updater that must be absent, a binary that must exist) are asserted through the `-Paths*` parameters.

**What the operator sees in the VM.** A SYSTEM scheduled task draws nothing on the interactive desktop,
and on some Sandbox builds the `<LogonCommand>` process gets no console window at all - so a healthy
15-minute install and a hang look identical. A separate top-most window in the guest therefore polls the
runner's `results\progress.json` and shows the WHOLE plan at once: every phase with a tick, a cross or a
live marker, and for the selected phase its exit code, duration, start and end, timeout, detection result
and its own transcript. It is passive - it never drives the run, and closing it stops nothing. If it did
not open, `SHOW-PROGRESS.cmd` in the work folder starts it by hand.

Prerequisite: the optional feature `Containers-DisposableClientVM`. The script checks it through
`Win32_OptionalFeature` (WMI, no elevation - deliberately not `Get-WindowsOptionalFeature`, which needs
admin) and prints the one-time enable command if it is off. Windows permits exactly ONE sandbox instance,
and a second launch silently attaches to the first, so the script refuses to start while one is running.

**An installer that stages a third-party driver needs `-TrustedPublisherCert`.** Pass the signer's `.cer`
and the harness imports it into the guest's `LocalMachine\TrustedPublisher` before any action runs, which
is what an Intune `RootCATrustedCertificates` profile does on the fleet (App. N). Without it Windows
raises the "install device software?" prompt - and that prompt is INVISIBLE here, because every action
runs as SYSTEM through a scheduled task and draws nothing on the desktop. The installer then waits for an
answer nobody can give and the phase burns its whole timeout, which looks exactly like a slow installer
unless you read the log tail. Measured on Time-Access 3010 / EDIsecure (2026-09-16): **25 minutes parked
in `CA.dll: InstallPrinterDriver` versus 43 seconds with the certificate present**, for a `.cer` that was
sitting in the package's own output folder. The import uses `certutil -addstore` - `Import-Certificate`
returns `E_ACCESSDENIED` in this guest even when elevated - and is verified by reading the store back by
thumbprint, because a failed import is indistinguishable from a successful one in a log that only records
the return value.

**Cancel a run with `STOP.txt`, never by killing the process.** The guest polls for that file in the work
folder and tears itself down cleanly; the script prints the exact command when it starts. Killing the host
process or closing the sandbox window instead orphans the `vmmemWindowsSandbox` worker, which survives
`Stop-Process` from an unelevated session and blocks every further run until an elevated
`Restart-Service vmcompute -Force` or a reboot.

**Scope it down further while iterating.** `-Scenarios Install` alone answers "does the install work at
all" and is right after a failed Install - Uninstall, Repair and the reinstall pass all need a
successfully installed machine to mean anything, so running them against a broken Install just re-proves
the same failure a few minutes at a time. What actually ran is recorded, so any short run reports
`GREEN_PARTIAL`.

When the sandbox is NOT the right host: the app needs domain join, a real TPM, GPU acceleration, a reboot
to complete (the VM is discarded), or hardware the VM does not have. Then use 6.2.

`-GenerateOnly` writes the runner and the `.wsb` without starting anything - for inspecting or hand-tuning
the configuration.

**Do not re-implement this by hand.** Three bugs in a hand-rolled version each burned a full VM run on
2026-09-05; all three surface as a timeout or a null-reference minutes after launch. Appendix G has them,
`tests/Invoke-PsadtSandboxTest.Tests.ps1` guards them.

### 6.2 Per-action route (DEV VM, or an app the sandbox cannot host)

```powershell
pwsh scripts/Invoke-PsadtSystemTest.ps1 -PackagePath '<pkg>' -DeploymentType Install -DetectionScript '<pkg>\Detect-<App>.ps1'
pwsh scripts/Invoke-PsadtSystemTest.ps1 -PackagePath '<pkg>' -DeploymentType Uninstall -DetectionScript '<pkg>\Detect-<App>.ps1'
```

Install AND Uninstall must both pass. Each run appends to `results.systemTest[]` and its log to
`artifacts.logs[]`, so the evidence is in the package rather than in someone's terminal scrollback.
Requires an elevated session (a SYSTEM scheduled task) and Windows PowerShell 5.1 (PSScheduledJob); the
script re-execs itself into 5.1 when started from pwsh. Cannot run either route? STOP before `-Execute` and
hand the exact command back - never upload untested.

The script returns `{ DeploymentType, ExitCode, Success, DetectionState, LogPath, LogTail, ErrorLines,
Elevated }` and **fixes nothing**. You drive the loop, and the loop is bounded:

```
Install -> verify detection -> Uninstall -> verify clean -> Reinstall
```

- **Hard cap: 5 iterations.** Not a suggestion - it is what keeps a failing package from turning into
  an unbounded edit-and-retry session against a VM.
- **Converged** -> run Uninstall once more and leave the machine uninstalled. A DEV VM left in the
  installed state makes the next package's "absent" baseline a lie.
- **Cap reached, or no elevation available** -> blockade protocol (PROBLEM / TRIED / OPTIONS), and STOP
  before any upload. A package whose Uninstall never ran is not a finished package.

Prerequisites and the diagnosis path for a failing action: Appendix A (error catalogue) and
Appendix G (the harness bugs, and why this is not ten lines of `schtasks`).

### 6.3 Run it in parallel with Phases 7 and 8

Packaging and the dossier do not depend on the test result; only the verdict *recorded in* the dossier
does. Start the sandbox test, build the `.intunewin` and the report while it runs, then fold the result in
and regenerate the dossier. Serialising them adds the whole test duration to the wall clock for nothing.

**This is an instruction, not a hint: start the VM and then keep working in the SAME turn.** It was
already written here and was still ignored for six consecutive runs on 2026-09-16, each one a ~6-minute
wait in which nothing else happened - roughly half an hour of wall clock spent watching a progress
counter. Anything that does not need the verdict belongs in that window: the `.intunewin`, the logo, the
return-code table, the Company-Portal description, the upload metadata. The harness prints the same
reminder when it starts.

### 6.4 The manual interactive test a GREEN verdict cannot replace

**After a GREEN verdict, offer a manual interactive test.** Situational, not a fifth gate: skip it
silently for a vendor or app family already packaged and understood. Offer it for an unfamiliar
app or vendor, for anything flagged in 1.4, and for the first package of a new app family.

What GREEN actually means is *the package installs, detects, uninstalls, reinstalls and repairs against
the detection script*. It does not mean the application works. Invisible to the loop by construction:
a missing external runtime (1.4), a first-run wizard that blocks on a click, an absent licence, a
default configuration that is broken in this environment. Every one of those leaves the package GREEN.

The cheap version: generate the artefacts without booting the automated loop, then hand the user a
sandbox with nothing in it but the installer.

```powershell
# Generate only - no VM is started, nothing runs, no automated loop.
pwsh scripts/Invoke-PsadtSandboxTest.ps1 -PackagePath <pkg> -GenerateOnly
```

Take the `.wsb` it writes, keep the package mapping, drop the work-folder mapping, and open it. The
user installs and clicks around by hand. That is the check no assertion in this skill can make for them.

---

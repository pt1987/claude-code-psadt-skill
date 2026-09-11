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

### 1.3 Web research on the specific installer

Research per app - without these answers there is no successful silent install:

**Mandatory search queries (examples):**
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

**Document the minimal result:**

| Question | Answer | Source |
|---|---|---|
| Silent install CMD | `<...>` | |
| Silent uninstall CMD | `<...>` | |
| Known exit codes (success, reboot, error) | `0, 3010, ...` | |
| Installer log file path | `<...>` | |
| Dependency installer (if separate) | `<...>` | |
| External runtime prerequisite (1.4) | `<...>` | |
| Known Intune pitfalls | `<...>` | |
| Known post-install config (registry / XML) | `<...>` | |

Without this table filled in: **do not package**.

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
    Start-ADTMsiProcess -FilePath "$($adtSession.DirFiles)\<installer>.msi" -Transforms "$($adtSession.DirSupportFiles)\<transform>.mst" -ArgumentList '/qn REBOOT=ReallySuppress'

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
| `Remove-MSIApplications` | `Remove-ADTApplication` |
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

### 6.1 Default route: the whole loop in a Windows Sandbox

```powershell
pwsh scripts/Invoke-PsadtSandboxTest.ps1 -PackagePath '<pkg>' `
    -PathsPresentAfterInstall 'C:\Program Files\<App>\<app>.exe' `
    -PathsAbsentAfterInstall  'C:\Program Files\<App>\updater\GUP.exe'
```

One command, one throwaway VM, ~6 minutes: Install -> detection -> Uninstall -> detection -> Reinstall ->
Repair -> final Uninstall, **every action as SYSTEM** through a scheduled task, exactly like the Intune
Management Extension. Returns `{ Verdict, Steps, FailedAssertions, Assertions, ResultPath, LogFolder }`,
writes `results.sandboxTest` plus one `results.systemTest[]` entry per action, and copies the PSADT logs
back to the host.

Why this is the default:
- **No elevation on the host** and the host is never modified, so the test is available in an ordinary
  packaging session instead of being deferred to "a DEV VM later" - which in practice means never.
- **Every action starts from a machine that has never seen the app**, so "it passed because the previous
  run left something behind" cannot happen.
- The verdict is keyed on the **detection script**, which is what Intune evaluates. Package-specific facts
  (an updater that must be absent, a binary that must exist) are asserted through the `-Paths*` parameters.

Prerequisite: the optional feature `Containers-DisposableClientVM`. The script checks it through
`Win32_OptionalFeature` (WMI, no elevation - deliberately not `Get-WindowsOptionalFeature`, which needs
admin) and prints the one-time enable command if it is off. Windows permits exactly ONE sandbox instance,
and a second launch silently attaches to the first, so the script refuses to start while one is running.

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
# Generate only - no run, no Startup trigger, no automated loop.
pwsh scripts/Invoke-PsadtSandboxTest.ps1 -PackagePath <pkg> -GenerateOnly
```

Take the `.wsb` it writes, keep the package mapping, drop the work-folder mapping, and open it. The
user installs and clicks around by hand. That is the check no assertion in this skill can make for them.

---

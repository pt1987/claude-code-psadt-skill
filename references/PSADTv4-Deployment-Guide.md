# PSADT v4.x Deployment Guide - Intune

Mandatory end-to-end guide for Intune Win32 packages with PSADT 4.x. Work through it in this order. Do not skip any phases.

- **Phase 0**: Setup (config bootstrap - see SKILL.md / `Get-PsadtConfig`)
- **Phases 1-2**: Intake + Research (BEFORE the first click)
- **Phase 3**: Scaffold via `New-ADTTemplate`
- **Phase 4**: Script customizing (the three hooks)
- **Phase 5**: Pre-flight checks (encoding, parse, launcher simulation)
- **Phase 6**: SYSTEM test (opt-in; binding gate for upload - Appendix A / G)
- **Phase 7**: Build the .intunewin
- **Phase 8**: Intune app configuration (+ dossier, Appendix F)
- **Phase 9**: Direct Graph upload (opt-in; Appendix H)
- **Phase 10**: Group assignment (opt-in; Appendix M)
- **Phase 11**: Test sequence
- **Phase 12**: Rollout
- **Appendices**: A Error reference / B Anti-patterns / C Test stub pattern / D Resources / E Final deploy checklist / F Package report (dossier + technical) / G Lessons learned / H Direct Intune upload (Graph) / I WinGet packaging / J App logo / K Script-only / remediation packages / L Installer technologies + silent switches / M Group assignment

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

## Phase 7: Build the .intunewin

### 7.1 Get IntuneWinAppUtil

Microsoft's official packaging tool. Always the current version:
- GitHub: https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool
- Direct download (releases/latest): `https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/latest`

```powershell
$tool = '<paths.intuneWinAppUtil from config>'   # skill-managed tools/ by default; provisioned by Get-IntuneWinAppUtil.ps1
if (-not (Test-Path $tool)) {
    New-Item (Split-Path $tool -Parent) -ItemType Directory -Force | Out-Null
    $latest = Invoke-RestMethod 'https://api.github.com/repos/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/latest'
    $asset = $latest.assets | Where-Object { $_.name -eq 'IntuneWinAppUtil.exe' } | Select-Object -First 1
    Invoke-WebRequest $asset.browser_download_url -OutFile $tool
}
& $tool -v
```

### 7.2 Package

```powershell
$src = '<package folder from phase 1>'              # e.g. '<paths.packageRoot>\<AppName>'
$setupFile = 'Invoke-AppDeployToolkit.exe'         # ALWAYS the .exe, NOT the .ps1
$out = '<output folder OUTSIDE $src>'               # from config: '<paths.outputRoot>\<AppName>' - NOT inside src!
New-Item $out -ItemType Directory -Force | Out-Null

& $tool -c $src -s $setupFile -o $out -q
```

Parameters:
- `-c <srcDir>` - the package folder with .exe + .ps1 + PSAppDeployToolkit + Files
- `-s <setupFile>` - relative path (to `-c`) to the entry .exe. ALWAYS `Invoke-AppDeployToolkit.exe`, **not** `.ps1` (the launcher needs WDAC compatibility and a 64-bit PS bootstrap)
- `-o <outDir>` - output folder for the .intunewin - **not** inside `-c`, otherwise a rebuild packs the old .intunewin in too (nested, double storage)
- `-q` - quiet, no input prompts
- `-a <catalogFolder>` - optional, catalog files for WDAC-signed environments
- `-e` - encryption output info (interesting for tooling, not for Intune)

Result plausibility:
```powershell
$iw = Get-ChildItem "$out\*.intunewin" | Select-Object -First 1
"Size: $([Math]::Round($iw.Length / 1MB, 1)) MB"
"Approx Files/-Size: $([Math]::Round(((Get-ChildItem "$src\Files" -Recurse -File | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)) MB"
```

Drastically larger than Files + 20-50 MB toolkit = nested .intunewin, `-o` was inside `-c`, repackage with an external output.

### 7.3 Check extractability (offline)

The .intunewin is an AES-encrypted ZIP. Not extractable without Intune, but the outer ZIP has a metadata XML that is accessible unencrypted:

```powershell
Expand-Archive -Path $iw.FullName -DestinationPath "$env:TEMP\iw-inspect" -Force
Get-Content "$env:TEMP\iw-inspect\IntuneWinPackage\Metadata\Detection.xml"
```

The XML must contain `<SetupFile>Invoke-AppDeployToolkit.exe</SetupFile>`. If something else is there: wrong `-s` during packaging.

---

## Phase 8: Intune app configuration

### 8.1 App Information
- Name / Version / Publisher: matches `$adtSession.AppName / AppVersion / AppVendor`
- Description: Markdown-capable, the first paragraph readable standalone (~200 characters are the short preview in the Company Portal)
- Category: choose it semantically correct (Development, Productivity, ...)
- Logo: `<pkg>\Assets\<App>-Logo.png` (the REAL downloaded application logo - NOT the PSADT default `AppIcon.png`), >=256x256 PNG

### 8.2 Program
- **Install command**: `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent`
- **Uninstall command**: `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent` (case does not matter, the ValidateSet is case-insensitive)
- **Install behavior**: `System` (default; the SYSTEM context is correct for Win32 apps)
- **Device restart behavior**:
  - `App install may force a device restart` - when the installer can return 1641
  - `Determine behavior based on return codes` - default, falls back to the return-code mapping
- **Allow available uninstall**: Yes (lets the user uninstall via the Company Portal)

### 8.3 Return codes (critical, never omit)

Mandatory mapping, otherwise Intune shows unknown exit codes as `0x80070000 + code`:

| Code | Type | Reason |
|---:|---|---|
| 0 | Success | OK |
| 1707 | Success | MSI success alternative |
| 3010 | Soft reboot | Reboot recommended |
| 1641 | Hard reboot | Reboot enforced |
| 1618 | Retry | A parallel MSI is running |
| 60001 | **Failed** | PSADT unhandled script error |
| 60008 | **Failed** | PSADT init failed (module import / Open-ADTSession) |

Additionally enter the installer-specific codes from 0.3.

### 8.4 Requirements
- **OS architecture**: `x64` when the script has `AppArch='x64'`, otherwise accordingly
- **Minimum OS**: realistic (Win11 22H2, Win10 22H2) - not `1607`, that is leaving it open to legacy
- **Disk space**: when the installer needs a lot - saves time on small disks
- **Physical memory**: only for genuinely memory-hungry installers
- **Additional requirement rules**: Registry / File / Script - for everything that goes beyond the standard requirements (e.g. domain-join check, specific build number)

### 8.5 Detection rules

Three options, ordered by robustness:

1. **Custom detection script** (preferred for complex installs):
   - Contract: `exit 0 + stdout non-empty` = installed; `exit 0 + stdout empty` = not installed; `exit != 0` = detection error, retry
   - Usually: `Enforce script signature check = No` (except in a strictly signed environment)
   - Usually: `Run as 32-bit on 64-bit = No` (otherwise the wrong registry view)

2. **MSI Product Code**: for pure MSI installers that keep their product code stable

3. **File / Registry / Version**: for simple cases - ONE criterion, not several mixed

**Mandatory**: the detection method is **unambiguous** - not a custom script PLUS a file rule; that gives contradictory answers.

### 8.6 Install time required
- The default of 60 min is enough for most installers
- Only when documented >45 min, raise it
- Don't reflexively set 120 min ("more is better" is not true here - Intune then keeps the process alive extremely long)

### 8.7 Assignments
- `Required` for a mandatory rollout to a device or user group
- `Available for enrolled devices` for self-service via the Company Portal
- `Uninstall` as a pseudo-assignment to deliberately remove apps again
- **Filter** to use for dynamic constraints (OS version, device-name regex, AzureAD join type)
- **Delivery Optimization**: enable peer-to-peer for large packages
- **Dependencies / Supersedence**: when the app requires other PSADT packages or replaces previous versions
- **App availability / Deadline / Grace period**: for required apps with a reboot impact

---

## Phase 11: Test sequence

In this order on a DEV VM (not prod).

### 11.1 Direct invoke (smoke test)
```powershell
.\Invoke-AppDeployToolkit.ps1 -DeploymentType Install -DeployMode Silent
```
Runs through = script logic OK.
Does not run through = your code bug, not an Intune problem.

### 11.2 Launcher invoke (acid test)
```powershell
.\Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent
```
Runs through = encoding / param-block sync OK.
Does not run through but 6.1 does = see 3.1 (encoding), 3.4 (params), 3.6 (top-level throws).

### 11.3 SYSTEM context (IME reality)
```cmd
psexec -s -accepteula cmd /c "cd /d <pkg> && Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent"
```
PsExec: https://learn.microsoft.com/en-us/sysinternals/downloads/psexec
Runs through = no dependency on a user session. This test must be green BEFORE upload.

### 11.4 Test-group deploy
A dedicated Intune test group with 1 VM. Observe the deployment:
- `C:\Windows\Logs\Software\*PSAppDeployToolkit_Install.log` must exist + contain `Close-ADTSession` with Exit 0
- `AppWorkload.log` shows `Status: Installed`
- the detection script returns `exit 0 + stdout non-empty`

Only after success: production rollout.

---

## Phase 12: Rollout

### 12.1 Staged rollout
- Run a pilot group (10-50 devices) for 24-48h
- Monitoring: Intune Admin Center -> Apps -> Oracle (example) -> Device install status
- At >5% failure rate: pause the rollout, find the cause

### 12.2 Production
- Expand the target audiences after pilot success
- Review the Company Portal description + support notes
- Known issues into the internal knowledge base

### 12.3 Ongoing
- Subscribe to the GitHub release feed (Releases -> Watch -> Releases only) so you don't miss PSADT updates
- Check with every new package: is the module in the scaffold still up to date (Phase 1.1)

---

## Appendix A: Error reference

### A.1 Intune HRESULT mapping

Intune converts unknown positive exit codes into an HRESULT: `0x80070000 + exitcode`.

| Intune shows | Actual exit | Meaning |
|---|---:|---|
| `0x80070001` | 1 | **The script did not run at all** (parse error, param binding, top-level throw) |
| `0x80070002` | 2 | FILE_NOT_FOUND, often: the launcher cannot find the .ps1 |
| `0x8000EA61` | 60001 | PSADT unhandled script error |
| `0x8000EA68` | 60008 | PSADT init / module load failed |
| `0x8007064B` | 1611 | MSI component qualifier not present |
| `0x80070642` | 1602 | User cancelled |
| `0x80070652` | 1618 | Another install in progress |
| `0x80070643` | 1603 | **Fatal error during installation** (perms, disk space, pending reboot, bad property) |
| `0x80070645` | 1605 | Product not installed (on UNINSTALL this is effectively success - already gone) |
| `0x80070653` | 1619 | Installation package could not be opened (path / permissions / corrupt) |
| `0x80070666` | 1638 | Another version is already installed (uninstall old ProductCode, or ship the upgrade) |
| `0x80070667` | 1639 | Invalid command-line argument (a property/switch is malformed - quoting!) |
| `0x0` | 0 | Success |

### A.2 Typical root causes by symptom

**0x80070001 + no local PSADT logs:**
1. Script encoding (em-dash in a double-quoted string, UTF-8 without BOM) -> parse error
2. Top-level code outside try/catch throws
3. The param block does not accept what the launcher passes
-> 3.1, 3.4, 3.6

**0x8000EA68 (60008) + PSADT log present, but empty after init:**
1. Import-Module error (version mismatch, broken path)
2. Open-ADTSession throws (invalid config, admin check failed)
3. Type-data collision (`System.Security.AccessControl`) - symptom `"AuditToString" ist bereits vorhanden`. The IME runs as SYSTEM with a machine-scope PSModulePath (clean), so it's rare in an Intune deploy - more likely in interactive tests. Workaround: clean PS7 paths out of `$env:PSModulePath`.

**0x8000EA61 (60001) + PSADT log with a stack trace:**
1. Runtime error in Install-ADTDeployment
2. An external command fails
-> the log itself has the stack, directly readable

**App stuck on "Installing" in the Company Portal:**
1. The script is still running (check the process ID, scheduled-task state)
2. The script crashed, the IME callback was not written
3. The GRS cache is in the way

Cleanup sequence (caution, check first):
```powershell
Get-Process | Where-Object { $_.ProcessName -match 'Invoke-AppDeployToolkit|setup|msiexec|dbca|sqlplus' } | Select Id,ProcessName,StartTime
Get-ScheduledTask -TaskName 'PSADT_*' -ErrorAction SilentlyContinue | Select TaskName,State

# only when nothing is running anymore for sure:
Stop-Service IntuneManagementExtension -Force
Remove-Item 'HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps\<UserSID>\<AppId>' -Recurse -Force -ErrorAction SilentlyContinue
Start-Service IntuneManagementExtension
```

### A.3 Log locations

| Log | Purpose |
|---|---|
| `C:\Windows\Logs\Software\<AppName>*PSAppDeployToolkit_Install.log` | PSADT session (after a successful init) |
| `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppWorkload.log` | **The truth** about exit codes + install commands |
| `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log` | IME service state |
| `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log` | Detection-script runs |
| `C:\Windows\IMECache\<AppId>_<Version>\` | Extracted package (only during install) |
| `C:\Program Files (x86)\Microsoft Intune Management Extension\Content\Incoming\` | .intunewin download (before extract) |

AppWorkload.log sequence:
- `Content cache miss for app (id = ..., name = ...)` - download starts
- `Downloading app ... via DO, bytes N/M` - progress
- `SetCurrentDirectory: C:\WINDOWS\IMECache\...` - extract done
- `Calling CreateProcessAsUser: '...Invoke-AppDeployToolkit.exe...'` - the real start
- `lpExitCode N` - exit code
- `Admin did NOT set mapping for lpExitCode: N` - the code was not in the return codes
- `EnforcementErrorCode: -<huge>` - HRESULT as a signed int

### A.4 Exit-code catalogue (cause -> reaction)

**Windows Installer (MSI):**
| Code | Meaning | Reaction |
|---:|---|---|
| 0 / 1707 | Success | map both as success |
| 3010 | Success, soft reboot required | `softReboot`; never force a reboot during ESP |
| 1641 | Success, installer initiated a reboot | `hardReboot`; avoid in silent/ESP - pass `/norestart` |
| 1603 | Fatal error during installation | check perms, free disk, a PENDING REBOOT (clear it), and the MSI `/l*v` log - a custom action likely failed |
| 1605 | Action valid only for installed products | on uninstall = already gone (treat as success); on repair = nothing to repair |
| 1618 | Another installation is in progress | `retry`; ensure nothing else is mid-install |
| 1619 | Package could not be opened | wrong path / no read access / corrupt download - re-fetch the MSI |
| 1620 | Package could not be opened (invalid) | corrupt or incomplete MSI |
| 1622 | Error opening the install log | the `/l*v` log path is not writable - fix the path |
| 1625 | Install forbidden by system policy | a `DisableMSI` / policy blocks it |
| 1635 | Patch package could not be opened | bad `.msp` path |
| 1638 | Another version is already installed | uninstall the old ProductCode first, or ship a proper upgrade (REINSTALLMODE / new UpgradeCode) |
| 1639 | Invalid command-line argument | a property/switch is malformed (quoting!) |
| 1101 / 1612 / 1636 | Source / media unavailable | the install source moved - repair the source list or re-deploy |

**PSADT v4 toolkit codes:**
| Code | Meaning | Reaction |
|---:|---|---|
| 60001 | Unhandled runtime error in a deployment hook | the PSADT session log has the stack trace - fix the line it names |
| 60002-60007 | Internal toolkit / session errors | check the PSADT log; usually a bad `$adtSession` value or a cmdlet misuse |
| 60008 | Init / Import-Module failed (session never opened) | encoding/parse, a broken module path, or a type-data collision (A.2) |
| 60012 | Deferral / a close-process still running | user deferred, or a `-CloseProcesses` app is still open |
| 69000-69999 | Your own custom codes (Invoke-AppDeployToolkit.ps1) | define + document them in the package return codes |
| 70000-79999 | Your own custom codes (Extensions module) | same |

**Map `1603, 1619, 60001, 60008` as `failed`** return codes in Intune so a real failure surfaces (instead of
"unknown exit code"); map `0 / 1707` success and `3010 / 1641` reboot. See Phase 8 / the upload `returnCodes`.

---

## Appendix B: Anti-pattern list

1. **Em-dash/smart quote in double-quoted strings**. `"Repair failed — DB status [$status]."` kills the entire script.
2. **UTF-8 without BOM + special characters**. Write a BOM or stick to pure ASCII.
3. **v3 cmdlet names** (see 3.5).
4. **Top-level code outside try/catch**.
5. **Single check without retry for async state** (services after msiexec need 30-60s; do not trigger fallback delete actions on the first negative answer).
6. **Intune return codes left at default only**. Enter 60001 + 60008 as Failed.
7. **Reflexively bumping the install time**. 60 min is almost always right.
8. **Thinking "runs locally = runs in Intune"**. The acid test is 6.2 + 6.3.
9. **Mixed detection** (custom script + file rule in parallel).
10. **Extensions in the main script instead of in `PSAppDeployToolkit.Extensions`**.
11. **-o inside -c with IntuneWinAppUtil** - nested .intunewin.
12. **No stakeholder intake (Phase 1.2)** - the most common reason for "the installer doesn't do what I want" after 2 weeks.

---

## Appendix C: Test stub pattern

Before the launcher test on a DEV box, when the install action is too big/expensive:

```powershell
$orig = '<path-to-ps1>'
$test = "$env:TEMP\test-Invoke-AppDeployToolkit.ps1"
$content = [System.IO.File]::ReadAllText($orig)
$stub = '"STUB_REACHED_INSTALL" | Out-File $env:TEMP\stub-reached.log -Encoding utf8; exit 77'
$modified = $content -replace '& "\$\(\$adtSession\.DeploymentType\)-ADTDeployment"', $stub
[System.IO.File]::WriteAllText($test, $modified, [System.Text.UTF8Encoding]::new($true))

Start-Process powershell.exe -ArgumentList `
    '-ExecutionPolicy','Bypass','-NonInteractive','-NoProfile','-NoLogo',`
    '-Command', "try { & '$test' -DeploymentType Install -DeployMode Silent } catch { throw }; exit `$Global:LASTEXITCODE" `
    -Wait -NoNewWindow
Get-Content "$env:TEMP\stub-reached.log" -ErrorAction SilentlyContinue
```

- Exit 77 + stub log = init + session open OK, the bug sits in Install-ADTDeployment
- Exit 1 = parse/encoding bug, see 3.1
- Exit 60008 = Import-Module / Open-ADTSession bug, see A.2

---

## Appendix D: Resources

### Official PSADT
- Main site + docs: https://psappdeploytoolkit.com/docs
- Latest release: https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/releases/latest
- Release notes: https://psappdeploytoolkit.com/docs/getting-started/release-notes
- Download: https://psappdeploytoolkit.com/docs/getting-started/download
- Creating a New Deployment: https://psappdeploytoolkit.com/docs/getting-started/creating-a-new-deployment
- Reference (all cmdlets): https://psappdeploytoolkit.com/docs/reference
- New-ADTTemplate: https://psappdeploytoolkit.com/docs/reference/functions/New-ADTTemplate
- Exit Codes: https://psappdeploytoolkit.com/docs/reference/exit-codes
- Migration v3 -> v4: https://psappdeploytoolkit.com/docs/migration/migrate-from-v3
- Blog: https://psappdeploytoolkit.com/blog
- Community Forum: https://discourse.psappdeploytoolkit.com
- GitHub: https://github.com/PSAppDeployToolkit/PSAppDeployToolkit
- Launcher source: https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/tree/main/src/PSADT.Invoke

### Microsoft
- Intune Win32 App Docs: https://learn.microsoft.com/en-us/mem/intune/apps/apps-win32-app-management
- IntuneWinAppUtil: https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool
- IntuneWinAppUtil Releases: https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/latest
- Intune Troubleshooting: https://learn.microsoft.com/en-us/mem/intune/apps/troubleshoot-app-install
- Company Portal Docs: https://learn.microsoft.com/en-us/mem/intune/apps/company-portal-app
- PowerShell 5.1 UTF-8-No-BOM bug: https://learn.microsoft.com/en-us/answers/questions/3850223/powershell-5-1-parser-bug-failure-to-parse-utf-8
- PowerShell File Encoding: https://learn.microsoft.com/en-us/powershell/scripting/dev-cross-plat/vscode/understanding-file-encoding
- about_Character_Encoding: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_character_encoding
- PsExec (SysInternals): https://learn.microsoft.com/en-us/sysinternals/downloads/psexec

### Silent-install research
- silentinstallhq.com - switch collection
- deploymentresearch.com - Tim Mangan archive
- PSADT Discourse Search: https://discourse.psappdeploytoolkit.com/search
- Reddit r/Intune: https://www.reddit.com/r/Intune/
- Reddit r/SCCM: https://www.reddit.com/r/SCCM/

### Third-party error-code docs
- Scappman Error Reference: https://support.scappman.com/support/error-code-reference
- xoap PSADT Exit Codes: https://docs.xoap.io/application-management/psadt/exit-codes
- netECM PSADT Exit Codes: https://docs.netecm.ch/launcher/troubleshooting/ps-app-deploy-toolkit-setup-exit-codes.html
- Anoop C Nair Intune Troubleshooting: https://www.anoopcnair.com/intune-management-extension-deep-dive-level-300/
- getpackit PSADT + Intune Issues: https://www.getpackit.com/blog/psadt-intune-apps-deployment-issues/

---

## Appendix E: Final deploy checklist

```
Phase 1-2 - Research + Intake
[ ] 0.1  PSADT version local == Latest (or update)
[ ] 0.2  Intake form complete (App, Installer, Environment, Sec)
[ ] 0.3  Silent install switches + uninstall switches documented

Phase 3 - Scaffold
[ ] 1.1  New-ADTTemplate -Destination ... -Name ... executed
[ ] 1.2  Folder layout complete
[ ] 1.3  Module version pinned in scaffold

Phase 4 - Script customizing
[ ] 2.1  Installer in Files\
[ ] 2.2  $adtSession with all metadata
[ ] 2.3  Install/Uninstall/Repair hooks filled in
[ ] 2.4  Custom helpers in PSAppDeployToolkit.Extensions, not in the main script

Phase 5 - Pre-Flight
[ ] 3.1  Encoding: HasBOM=True OR NonAscii=0
[ ] 3.2  ParseFile PARSE_OK
[ ] 3.3  Launcher simulation green
[ ] 3.4  Param block in sync with v4 template
[ ] 3.5  No v3 cmdlet remnants
[ ] 3.6  No top-level statements that can throw

Phase 7 - Build
[ ] 4.1  IntuneWinAppUtil latest
[ ] 4.2  -c / -s / -o correct, -o NOT inside -c
[ ] 4.3  Inspection: Detection.xml has SetupFile=Invoke-AppDeployToolkit.exe

Phase 8 - Intune config
[ ] 5.1  App Info + Logo
[ ] 5.2  Install/Uninstall command + Install Behavior=System
[ ] 5.3  Return codes complete (incl. 60001+60008=Failed)
[ ] 5.4  Requirements (OS, Arch, Disk, Memory)
[ ] 5.5  Detection method UNAMBIGUOUS
[ ] 5.6  Install time realistic
[ ] 5.7  Assignments + Filter + Delivery Opt

Phase 11 - Test
[ ] 6.1  Direct invoke on DEV
[ ] 6.2  Launcher invoke on DEV
[ ] 6.3  Psexec -s on DEV
[ ] 6.4  Test-group deploy -> PSADT log + Close-ADTSession Exit 0

Phase 12 - Rollout
[ ] 7.1  Pilot (24-48h)
[ ] 7.2  Production staged
[ ] 7.3  GitHub release watch subscribed
```

Only when ALL lines are green: production rollout.

---

## Appendix F: Package report (Intune dossier + technical report)

**The report is generated for EVERY package — uploaded or not — by `scripts/New-PsadtReport.ps1` from the fixed
template `references/Report-Template.html`. Do NOT hand-assemble the HTML.** Output is always
`Intune-Dossier.html` in `Output\<App>\`. It is one self-contained, **bilingual (DE/EN toggle)** document:
part 1 is the Intune dossier (the tables F.1–F.9 below), part 2 is the technical package report (deployment
hooks, PSADT cmdlets used, pre-flight results, the Phase 6 SYSTEM-test result, logo + `.intunewin`
verification). The logo is embedded as a base64 data URI; the description **preview is rendered client-side
from its Markdown source**. **Exception:** the F.2 description block is **Markdown**, because the Intune app
description field supports only Markdown (not HTML). The values come from Phase 1.2/1.3 and the test phases.

### F.0 Generator usage + `-Metadata` keys

```powershell
& scripts/New-PsadtReport.ps1 -Metadata $meta -LogoPath '<Output\<App>\<App>-Logo.png>' `
    -OutputPath '<Output\<App>\Intune-Dossier.html'
```

`$meta` is a hashtable. Every key is optional (sane defaults fill the rest, so the report is always complete):

| Key | Meaning |
|---|---|
| `Lang` | initial language `de` (default) / `en` — both are always embedded regardless |
| `AppName`, `AppVersion`, `Publisher`, `Developer`, `Owner` | header + App Info |
| `PkgRev`, `ScriptVersion`, `Created`, `Author`, `PsadtVersion`, `ModuleVersion` | header meta + cmdlet note |
| `SubDe`/`SubEn`, `StatusDe`/`StatusEn` | header subtitle + status pill (HTML entities allowed) |
| `Category` (null⇒"not preset"), `Featured` (bool), `InfoUrl`, `PrivacyUrl`, `Notes` | App Info |
| `DescMdDe`, `DescMdEn` | description **Markdown** per language (real umlauts here) |
| `InstallCmd`, `UninstallCmd`, `InstallBehavior`, `RestartBehaviorDe/En`, `RestartNoteDe/En`, `InstallTimeMin`, `AllowUninstall` | Program |
| `ReturnCodes` | array of `@{ Code; Cls=b-ok/b-warn/b-neut/b-fail; Label; De; En }` (defaults to the standard table) |
| `OsArch`, `MinOs`, `DiskMb`, `MemoryMb` | Requirements |
| `RuleFormat`, `DetectScript`, `RunAs32` (bool), `SignatureCheck` (bool) | Detection |
| `Dependencies`/`Supersedence` (+`*NoteDe/En`) | null ⇒ "none" + note |
| `Assignments` | array of `@{ Group; Type=Required/Available/Uninstall; Availability }` |
| `HookInstall`, `HookUninstall`, `HookRepair` | arrays of bullets: a string (technical, same both langs) or `@{ De; En }` |
| `Cmdlets` | array of cmdlet names (chips) |
| `Preflight` | array of `@{ Title; Cls=ok/warn/fail; De; En; BDe; BEn }` (defaults to 6 passing checks) |
| `SystemTest` (+`SystemTestNoteDe/En`) | array of `@{ StepDe; StepEn; Exit; Detection; Cls; Result }` |
| `LogoSource`, `LogoResolution`, `LogoGuardOk` (bool), `IntuneWin`, `SetupFile`, `Location` | Logo & package-file section |

The tables F.1–F.9 below are the source-of-truth field reference (what each value means); the generator maps
them onto the template. Keep them for depth and for the manual Admin-Center route.

### F.1 App information

| Intune field | Value | Notes |
|---|---|---|
| **Name** | `<AppName> <Version>` | exactly as visible in the Company Portal; version incl. build if there are updates |
| **Description** | see F.2 (Markdown block) | the first ~200 characters are the short preview in the CP |
| **Publisher** | `<Vendor>` | from Phase 1.2 (Adobe Inc., Oracle Corporation, ...) |
| **App version** | `<Major.Minor.Build.Rev>` | exact file version |
| **Category** | e.g. Business, Development, Productivity, Communication | for CP navigation |
| **Show this as a featured app in the Company Portal** | Yes/No | Yes only for recommended self-service apps |
| **Information URL** | `<vendor-product-page>` | official product homepage |
| **Privacy URL** | `<vendor-privacy-url>` | often the vendor's `/legal/privacy/` |
| **Developer** | `<Vendor-ShortName>` | usually == Publisher |
| **Owner** | `<internal-team>` | internal service owner (e.g. "Workplace-Services") |
| **Notes** | `PSADT 4.1.8 v<N> - pkg rev <NN> - YYYY-MM-DD` | package metadata for later troubleshooting |
| **Logo** | `<pkg>\Assets\<App>-Logo.png` (REAL app logo, NOT the PSADT default `AppIcon.png`) | >=256x256 PNG |
| **Role scope tags** | `<Default>` or custom | only with a delegated admin role structure |

### F.2 Description Markdown template (Company Portal)

The Intune app description field supports **only Markdown** (not HTML) and renders it in the Company Portal. Copy the block 1:1, replace `<...>`.

(end-user output — language.dossier, default German)

```markdown
**<AppName>** ist <Ein-Satz-Zweck>.

<Zwei-bis-drei-Sätze-Nutzenbeschreibung für Endbenutzer. Was bekommen sie, wofür brauchen sie das.>

**Was du bekommst**
- <Feature 1>
- <Feature 2>
- <Feature 3>
- <ggf. Config / Branding>

**Was du brauchst**
- Windows 11 (oder Windows 10 22H2+)
- ~<X> GB freier Speicherplatz auf `C:`
- Ca. **<N>-<M> Minuten** Installationsdauer
- *<ggf. Kein Neustart erforderlich / Neustart empfohlen>*

**Nach der Installation**

<Was findet der User vor? Startmenü-Eintrag, Desktop-Shortcut, Config-Datei, Zugangsdaten?>

**Deinstallation**

<Was passiert bei Deinstall? Bleiben User-Daten, werden sie entfernt, was soll der User vorher sichern?>

**Support**

Bei Problemen bitte ein Ticket beim **IT-Service-Desk** eröffnen und - wenn möglich - die Logdateien unter `C:\Windows\Logs\Software\` anhängen. Weitere Hinweise im [Support-Portal](<support-portal-url>).
```

Check: the first paragraph must also be readable on its own (200-character short preview).

### F.3 Program

| Intune field | Value |
|---|---|
| **Install command** | `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent` |
| **Install script** | - (do not use, the command is enough) |
| **Uninstall command** | `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent` |
| **Uninstall script** | - |
| **Installation time required (mins)** | Default 60; only raise if >45 min documented |
| **Allow available uninstall** | Yes (the user may uninstall via the CP) |
| **Install behavior** | **System** |
| **Device restart behavior** | `Determine behavior based on return codes` (default) OR `App install may force a device restart` when the installer can return 1641 |

### F.4 Return codes (mandatory table, copy exactly)

| Code | Type |
|---:|---|
| 0 | Success |
| 1707 | Success |
| 3010 | Soft reboot |
| 1641 | Hard reboot |
| 1618 | Retry |
| 60001 | **Failed** |
| 60008 | **Failed** |
| `<installer-success-nicht-0>` | Success |
| `<installer-known-error>` | Failed |

Add the installer-specific codes from Phase 1.3. Every unknown exit code produces `0x80070000+code` in the error display.

### F.5 Requirements

| Intune field | Value | Notes |
|---|---|---|
| **Operating system architecture** | x64 / x86 / Both | matches `$adtSession.AppArch` |
| **Minimum operating system** | Win11 22H2 / Win10 22H2 | realistic, not "Win10 1607" |
| **Disk space required (MB)** | `<MB>` | from the installer requirement, net + 20% reserve |
| **Physical memory required (MB)** | `<MB>` or empty | only for RAM-hungry installers |
| **Minimum number of logical processors required** | 1 / 2 / 4 | rarely relevant |
| **Minimum CPU speed required (MHz)** | empty | rarely relevant |
| **Additional requirement rules** | optional | Registry/File/Script - e.g. "Domain-Joined", "has Edge WebView2 installed" |

### F.6 Detection rules

**Rules format:** choose one way, do NOT mix:

**Option A - Custom script (preferred for complex installs):**
| Field | Value |
|---|---|
| **Rules format** | Use a custom detection script |
| **Script file** | `Detect-<AppName>.ps1` (shipped with the package) |
| **Run script as 32-bit process on 64-bit clients** | No (unless the script deliberately reads Wow6432Node) |
| **Enforce script signature check** | No (unless in a strictly signed environment) |

Detection-script contract:
- `exit 0 + stdout non-empty` -> INSTALLED
- `exit 0 + stdout empty` -> NOT INSTALLED
- `exit != 0` -> detection error (Intune retries)

**Option B - Manual, MSI Product Code:**
| Field | Value |
|---|---|
| **Rule type** | MSI |
| **MSI product code** | `{GUID}` |
| **MSI product version check** | No OR operator + version |

**Option C - Manual, File/Registry:**
ONE rule is enough if unambiguous. Mixing several rules: with care, all must match.

| Field | Value |
|---|---|
| **Rule type** | File / Registry / App version |
| **Path / Key** | `<konkret>` |
| **File/value** | `<konkret>` |
| **Detection method** | exists / string / version / size / date modified |
| **Associated with a 32-bit app on 64-bit clients** | No (almost always) |

### F.7 Dependencies

Other Win32 apps that must be installed FIRST.

| Field | Value |
|---|---|
| **Dependency app** | e.g. "VC++ 2015-2022 x64" |
| **Automatically install** | Yes (Intune installs it automatically afterwards) |

Avoid circular dependencies and >3 levels.

### F.8 Supersedence

Does this app replace a previous version or another product?

| Field | Value |
|---|---|
| **Superseded app** | the previous version (separate Intune entry) |
| **Uninstall previous version** | Yes/No (Yes for a true replace, No when parallel is possible) |

A maximum of **10 apps** as superseded; **at most 2 levels** deep (Intune limit).

### F.9 Assignments

One row per target group. At least one Required OR Available assignment, otherwise it never installs.

| Group (AzureAD / Entra) | Assignment type | Filter (include/exclude) | Install availability | Deadline | Restart grace period | Delivery Optimization |
|---|---|---|---|---|---|---|
| `<Grp-Devices-Required>` | Required | optional filter | As soon as possible / date | optional date | 1440 min + 15 min before reboot | Foreground / Background |
| `<Grp-Users-OptIn>` | Available | optional filter | - | - | - | Background |
| `<Grp-Cleanup>` | Uninstall | - | - | - | - | - |

**Hints:**
- Required for mandatory rollouts (security, compliance, standard tools)
- Available for self-service
- Uninstall for targeted removal from a group
- Filter: platform/version/device-name regex; for edge cases the IME checks cleanly whether the filter property exists
- Delivery Optimization Foreground for packages that have to arrive immediately; Background spares the network for large packages

**End user notifications** (per assignment):
- `Show all toast notifications` - default, the user sees download/install/reboot
- `Show toast notifications for computer restarts` - only the reboot prompt
- `Hide all toast notifications` - only for silent-only apps

### F.10 Review + Create

Before the `Create`, go through all tabs. After `Create`: Intune does not sync immediately — there is a 30-60 min wait until the client sees the package. Trigger it manually via Company Portal -> Settings -> Sync.

### F.11 Example filled-in (Oracle Database 21c XE from this project)

| Field | Value |
|---|---|
| Name | Oracle Database 21c Express Edition |
| Publisher | Oracle Corporation |
| App version | 21.0.0.0 |
| Category | Development, Database |
| Featured | Yes (for the developer audience) |
| Information URL | https://docs.oracle.com/en/database/oracle/oracle-database/21/xeinw/ |
| Privacy URL | https://www.oracle.com/legal/privacy/ |
| Developer | Oracle |
| Owner | Workplace-Services |
| Notes | PSADT v4.1.8 Wrapper v2 - Paketversion 02 - 2026-04-22 |
| Logo | `Assets/OracleXE-Logo.png` (real downloaded Oracle logo, NOT the PSADT default `AppIcon.png`) |
| Install command | `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent` |
| Uninstall command | `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent` |
| Install behavior | System |
| Device restart | App install may force a device restart |
| Installation time | 60 min |
| Return codes | 0/1707 Success; 3010/1641 reboot; 1618 retry; 60001/60008 Failed |
| OS architecture | x64 |
| Minimum OS | Windows 10 22H2 |
| Disk space required | 12288 MB |
| Physical memory | 4096 MB |
| Detection | Custom script `Detect-OracleXE.ps1`, Run as 32-bit=No, Signature=No |
| Dependencies | - (VCRedist is integrated in the PSADT pre-install hook) |
| Supersedence | - (first version) |
| Required group | Devices-OracleXE-Dev |
| Available group | Users-OracleXE-OptIn |
| Install availability | As soon as possible |
| Restart grace period | 1440 min (24h), 15 min countdown, snooze 240 min |

That is a complete dossier. Go through every new app the same way.

---

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

---

## Appendix H: Direct Intune upload via Microsoft Graph (win32LobApp) - hard-won lessons

Captured 2026-06-06 while implementing `scripts/Get-GraphToken.ps1` + `scripts/Invoke-IntuneWin32Upload.ps1` and uploading the 7-Zip package to a live tenant. All endpoints verified against the live Graph catalog (msgraph skill) and a real upload.

### H.0 Auth & bootstrap
- **Bootstrap (`New-PsadtEntraApp.ps1`) uses WAM** (Windows Web Account Manager broker) for the interactive admin sign-in, falling back to device code only if WAM is unavailable. WAM needs the MSAL.NET broker assemblies (`Microsoft.Identity.Client` + `.Broker` + `.NativeInterop` + native `msalruntime.dll`) - the script auto-locates them in the global NuGet cache or downloads a pinned set to `%LOCALAPPDATA%\PsadtIntune\msal`. **Pitfall:** `BrokerOptions` lives in namespace `Microsoft.Identity.Client` (NOT `Microsoft.Identity.Client.Broker`); `WithBroker` is the static `[Microsoft.Identity.Client.Broker.BrokerExtension]::WithBroker($builder,$opts)`. Also load the transitive `Microsoft.IdentityModel.Abstractions` or `WithAuthority` throws "Could not load file or assembly".
- **Uploads use app-only client credentials** (`Get-GraphToken.ps1`): scope `https://graph.microsoft.com/.default`, the DPAPI secret decrypted **in-memory only** (`SecureStringToBSTR` -> `PtrToStringBSTR` -> `ZeroFreeBSTR`), never logged.

### H.1 Use `/beta`, not `/v1.0`
The current Intune app-metadata backend (`StatelessAppMetadataFEService`, api-version 2025-07-02) on `/v1.0` **silently drops several win32LobApp write properties** - most visibly `displayVersion` (the portal "App Version" stays empty even after a PATCH that returns 200). The **same call on `/beta` persists them**. Do all win32LobApp metadata writes on `/beta`. **Drift caveat:** `/beta` is explicitly unversioned, so Microsoft can change the win32LobApp request shapes (the `@odata.type`-first / unified `rules` / detection-rule allowed-properties rules below) with no notice. This is a knowing trade-off for `displayVersion`; the upload-shape unit tests (`tests/Invoke-IntuneWin32Upload.Tests.ps1`) are the early-warning net, and the request bodies should be re-checked against the Graph changelog periodically.

### H.2 Detection: the unified `rules` collection, NOT `detectionRules`
`win32LobApp` exposes BOTH `detectionRules` (legacy `win32LobAppDetection`) and `rules` (unified `win32LobAppRule`). The current backend **ignores `detectionRules`** and rejects the create with `BadRequest: The Win32LobApp must have at least one detection rule specified` even though a perfectly valid `detectionRules` array was sent. Use `rules` with a `ruleType`:
```powershell
rules = @([ordered]@{
  '@odata.type'          = '#microsoft.graph.win32LobAppProductCodeRule'  # MUST be first (see H.3)
  ruleType               = 'detection'
  productCode            = '{<GUID>}'
  productVersionOperator = 'notConfigured'
  productVersion         = $null
})
```
Never send both `rules` and `detectionRules`/`requirementRules` together.

**Non-MSI apps (EXE installers: Vivaldi, Chrome-style, NSIS, Squirrel) → PowerShell-script detection rule.**
There is no ProductCode, so use a `win32LobAppPowerShellScriptRule` with `ruleType='detection'` and the
base64 of the detect script (classic contract: stdout + `exit 0` when installed). A **detection** script rule
accepts ONLY these properties — Graph rejects the others with `BadRequest: The <X> property may not be set for
Win32LobAppPowerShellScriptRule instances used for app detection`:
```powershell
$rules = @([ordered]@{
  '@odata.type'         = '#microsoft.graph.win32LobAppPowerShellScriptRule'  # first!
  ruleType              = 'detection'
  enforceSignatureCheck = $false
  runAs32Bit            = $false
  scriptContent         = [Convert]::ToBase64String([IO.File]::ReadAllBytes($detectPs1))
})
```
Do NOT set `displayName`, `runAsAccount`, `operationType`, `operator`, or `comparisonValue` on a *detection*
script rule — those are valid only on *requirement* script rules. `Invoke-IntuneWin32Upload.ps1` exposes this
as `-DetectionScriptPath` (use instead of `-MsiProductCode`). Verified live with the Vivaldi package (2026-06-06).

### H.3 `@odata.type` must serialise FIRST
For every polymorphic Graph sub-object (detection rule, `mimeContent` logo, `msiInformation`, supersedence relationship) build it with `[ordered]@{}` so `@odata.type` is the first key. A plain `@{}` hashtable serialises keys in an arbitrary order; when `@odata.type` lands later, the backend fails to bind the subtype and behaves as if the object were missing (this is a second cause of the "no detection rule" error).

### H.4 Content upload: relay EncryptionInfo, never re-encrypt
`IntuneWinAppUtil` already AES-encrypts the payload. The `.intunewin` is a ZIP containing `IntuneWinPackage/Contents/IntunePackage.intunewin` (the **already-encrypted** blob) and `IntuneWinPackage/Metadata/Detection.xml` (the `EncryptionInfo` + `UnencryptedContentSize` + `SetupFile`). Upload the inner blob verbatim and relay its `EncryptionInfo` to the `commit` call as `fileEncryptionInfo`. **Do NOT recompute** anything: `EncryptionInfo.FileDigest` is the SHA256 of the **plaintext** (not the ciphertext) - a local SHA256 of the encrypted blob will NOT match it, and that is correct/expected. Register the file with `size = UnencryptedContentSize` and `sizeEncrypted = (encrypted blob length)`.

### H.5 Block-blob upload MUST use HttpClient (binary fidelity)
Uploading the encrypted blob to the Azure SAS URI with `Invoke-RestMethod -Method Put -Body $bytes` **corrupts the binary** (it re-encodes the byte[]), so the blocks report "OK" but the later `commit` returns `uploadState=commitFileFailed` (MAC/digest mismatch on the decrypted content). Use raw bytes via `HttpClient`/`ByteArrayContent`:
```powershell
$client = [System.Net.Http.HttpClient]::new()
$req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Put, "$sas&comp=block&blockid=$enc")
$req.Content = [System.Net.Http.ByteArrayContent]::new($chunk)        # raw bytes, exact
$client.SendAsync($req).GetAwaiter().GetResult()
```
~4-6 MB blocks, base64 block ids of fixed width, then `PUT &comp=blocklist` with `<BlockList><Latest>..</Latest></BlockList>`. Do NOT add `x-ms-blob-type` to Put Block (only relevant to single Put Blob). Renew the SAS via `.../files/{id}/renewUpload` on long uploads. All poll loops (`azureStorageUriRequestSuccess`, `commitFileSuccess`) need timeout caps.

### H.6 Content sub-path needs the type-cast segment
After `/deviceAppManagement/mobileApps/{id}`, the content endpoints require the cast `/microsoft.graph.win32LobApp` before `contentVersions`: `.../mobileApps/{id}/microsoft.graph.win32LobApp/contentVersions/{cv}/files/{f}/...`. The 8 steps: create app -> contentVersion -> file (size+sizeEncrypted) -> poll SAS -> block upload -> commit(fileEncryptionInfo) -> poll -> PATCH `committedContentVersion`.

### H.7 Categories are a `$ref` relationship; supersedence is a relationship
`categories` is NOT a settable property. Resolve names from `/deviceAppManagement/mobileAppCategories`, then `POST .../mobileApps/{id}/categories/$ref` with `{ '@odata.id': '<base>/mobileAppCategories/<catId>' }`. Supersedence: `POST .../mobileApps/{newId}/relationships` with `{ '@odata.type':'#microsoft.graph.mobileAppSupersedence', supersedenceType:'replace', targetId:'<oldId>' }`.

### H.8 Coexistence & versioning (NEVER delete an older version)
Uploading a new version must **not** remove the existing one. `Invoke-IntuneWin32Upload.ps1` issues **only POST/PATCH, never DELETE**. Default `-OnExisting CreateNewCoexist` creates a NEW, separate app and leaves existing same-name version(s) fully intact, so supersedence can be wired and a rollback target remains. `-UpdateAppId <id>` is the explicit in-place path (replaces one app's content, keeps id/assignments). `-SupersedesAppId <oldId>` wires "new replaces old" (old retained). Same `displayName` for multiple versions is fine - they are distinct apps differentiated by `displayVersion`.

### H.9 Metadata completeness & boundaries
**Fill every objective field** - empty App-information tabs are a defect: `displayName, description (Markdown), publisher, developer, owner, displayVersion, informationUrl, privacyInformationUrl, notes, largeIcon, msiInformation (productCode+productVersion for MSI), returnCodes, rules, installExperience`. **But never auto-impose user/org choices**: no company branding in `notes` by default (empty, or config `intune.notes`), no category (`-Categories` empty by default - users assign categories themselves), no featured flag, no group assignment.

### H.10 Logo guard
The Company-Portal logo must be the REAL application logo. The PSADT template's `Assets\AppIcon.png` (generic coloured ">" mark) is NOT it - re-using it is a real mistake that slipped past a naive "square + alpha" check. The script keeps a SHA256 blocklist of PSADT default assets and refuses them unless `-AllowDefaultLogo`. When verifying a downloaded logo, `IsAlphaPixelFormat` is True even for opaque images - sample a real corner pixel and visually confirm the brand. An opaque-but-correct logo is acceptable (square it on its own background colour); the WRONG image is not.

### H.11 `minimumSupportedWindowsRelease` is a server-validated string - use a known-good release ID
The win32LobApp `minimumSupportedWindowsRelease` property is a free-form **string**, but the backend validates it against an internal list and rejects anything unknown with `BadRequest: "Unknown MinimumSupportedWindowsRelease: <value>"` **at the create step** (after the app body is assembled - an ugly mid-flight failure). The reliably-accepted values are the canonical Windows 10 release IDs: `1607, 1703, 1709, 1803, 1809, 1903, 1909, 2004` (confirmed: `1809` accepted; `21H2` rejected on a live tenant). Newer labels (`21H2`, `22H2`, Windows 11 IDs) are accepted by some tenant FE-service versions and rejected by others, so `Invoke-IntuneWin32Upload.ps1` constrains `-MinWindowsRelease` to a `ValidateSet` of the reliable IDs - it fails fast at param binding with the valid list instead of dying at create. Need a higher minimum than `2004`? Set it in the portal after upload (App > Properties > Requirements). Note: this is a different field from the dossier's free-text "Minimum OS" display string, which may say e.g. "Windows 10 22H2" for humans.

---

## Appendix I: WinGet packaging (opt-in, never the default)

WinGet is **strictly opt-in** (intake Q2). Use the app's native installer (MSI/EXE/...) unless the user
*explicitly* chose "WinGet package". Never assume, recommend, or auto-select it even if a WinGet package exists.
Everything below applies only after that explicit choice.

### I.1 Package discovery (replaces the Phase 1.3 silent-switch research)

`Find-ADTWinGetPackage` comes from `PSAppDeployToolkit.WinGet`. Import it explicitly before calling
(at discovery time on the build box — at deployment time the package's auto-loader handles it):
```powershell
Import-Module '<skillRoot>\tools\PSAppDeployToolkit.WinGet\PSAppDeployToolkit.WinGet.psd1' -ErrorAction SilentlyContinue
```
**Always search by name first** when the exact ID is not known with certainty. WinGet IDs follow
`Publisher.AppName` dot-notation, each word its own segment (`Valve.Steam`, `Microsoft.PowerShell.Preview`,
NOT `MicrosoftPowerShellPreview`). Guessing the concatenated form wastes a lookup.
```powershell
# Step 1: discover the exact ID by display name
Find-ADTWinGetPackage -Name '<AppName>' | Select-Object Id, Name, Version, Source | Format-Table -AutoSize
# Step 2: confirm the chosen ID resolves
Find-ADTWinGetPackage -Id '<ConfirmedPackageId>' | Format-List Id, Name, Version, Source
```
Not found after both steps → STOP and ask the user to correct the ID; never scaffold with an invalid ID.
**Fallback** if the module is unavailable on the build box: look up the ID at https://winstall.app/ (web UI over
winget-pkgs). Last resort only — `Find-ADTWinGetPackage` is preferred because it confirms the ID resolves at
runtime on this machine.

Research the manifest for detection hints (ProductCode, installer type, exe names, install path):
`https://github.com/microsoft/winget-pkgs/tree/master/manifests/<first-letter>/<publisher>/<app>/<version>/`.
For **portable** packages (`InstallerType: portable`) WinGet places files under
`%ProgramFiles%\WinGet\Packages\<Id>_<Arch>\` and shims in `%ProgramFiles%\WinGet\Links\`; the exact exe names
come from the manifest `.yaml` — guard shortcut creation with `if (Test-Path $exePath)`.
Add to the Intune-pitfalls stream: `"<AppName>" winget intune deployment known issues`.

### I.2 Scaffold: provision the extension module into the package

```powershell
pwsh scripts/Get-WinGetModule.ps1 -SkillRoot '<skillRoot>' -PackagePath '<pkg>'
(Import-PowerShellDataFile '<pkg>\PSAppDeployToolkit.WinGet\PSAppDeployToolkit.WinGet.psd1').ModuleVersion
```
PSADT's extension auto-loader discovers `PSAppDeployToolkit.WinGet\` by folder-name match and imports it
automatically — no `Import-Module` in the deployment script. `Files\` stays empty (nothing to bundle). Set
`AppVersion = 'Latest'` in `$adtSession` (or a pinned version); read `AppArch` from the manifest installer type.

### I.3 Hook patterns

```powershell
# Install-ADTDeployment
Repair-ADTWinGetPackageManager                                        # self-heal WinGet before every operation
Install-ADTWinGetPackage -Id '<WinGetId>' -Scope Machine -Mode Silent # add -Version '<ver>' if pinned

# Uninstall-ADTDeployment
Uninstall-ADTWinGetPackage -Id '<WinGetId>' -Mode Silent

# Repair-ADTDeployment
try {
    Repair-ADTWinGetPackage -Id '<WinGetId>'
} catch {
    Write-ADTLogEntry -Message "WinGet repair not supported; performing uninstall + reinstall."
    Uninstall-ADTWinGetPackage -Id '<WinGetId>' -Mode Silent
    Repair-ADTWinGetPackageManager
    Install-ADTWinGetPackage -Id '<WinGetId>' -Scope Machine -Mode Silent
}
```

### I.4 Pre-flight (in addition to 3.1–3.6)

```powershell
# Check 4: WinGet extension module present in the package
$mm = '<pkg>\PSAppDeployToolkit.WinGet\PSAppDeployToolkit.WinGet.psd1'
if (Test-Path $mm) { "WinGet module: $((Import-PowerShellDataFile $mm).ModuleVersion) - OK" }
else { "WinGet module MISSING - run: pwsh scripts/Get-WinGetModule.ps1 -PackagePath '<pkg>'" }
```
The acid test (3.3) WILL trigger a real install for WinGet — always use the Appendix C stub instead of skipping;
defer the live install/uninstall/repair verification to the SYSTEM test / Phase 6 on a DEV VM.

### I.5 Detection (registry/file only — the module is NOT on the device at detection time)

The `PSAppDeployToolkit.WinGet` module is bundled inside the `.intunewin` and extracted at install time only —
it is **not** present during Intune's detection phase. Never use `Get-ADTWinGetPackage` in a detection script.
```powershell
# Detect-<AppName>.ps1 - registry-based, works regardless of ProductCode stability
$regBases = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
foreach ($base in $regBases) {
    $match = Get-ChildItem $base -ErrorAction SilentlyContinue | Get-ItemProperty |
        Where-Object { $_.DisplayName -like '<AppName>*' } | Select-Object -First 1
    if ($match) { Write-Output "Detected: $($match.DisplayName) $($match.DisplayVersion)"; exit 0 }
}
exit 0   # not installed: no stdout + exit 0 (a non-zero exit reads as a detection error/retry, not "absent")
```
For a stable manifest `ProductCode`, use the direct GUID key (`HKLM:\...\Uninstall\{<ProductCode>}`).

### I.6 Dossier additions for WinGet

- Requirements table: add `Windows Package Manager (WinGet) >= 1.7.10582` — note that
  `Repair-ADTWinGetPackageManager` in the install hook self-heals this automatically.
- Detection note: registry/file detection only (the module is not present at detection time).

### I.7 WinGet anti-patterns

- Defaulting to / recommending / auto-selecting WinGet — it is strictly opt-in.
- `-Scope User` in Intune (SYSTEM has no mounted user hive) — always `-Scope Machine`.
- `Get-ADTWinGetPackage` in a detection script (module absent at detection time).
- Skipping `Repair-ADTWinGetPackageManager` before install.
- Mixing `Install-ADTWinGetPackage` with `Start-ADTProcess`/`Start-ADTMsiProcess` in one hook.
- Bare WinGet cmdlets without the `ADT` prefix (`Install-WinGetPackage`, `Repair-WinGetPackageManager`, ...) —
  those bypass logging/error-handling/the PSADT session; always use the `*-ADTWinGet*` extension cmdlets.

---

## Appendix J: App logo - acquisition + verification

The logo is uploaded separately (Intune **App information** tab / Phase 9); it is NOT part of the
`.intunewin` (no repack on logo change). Obtain the **REAL** application logo (PNG, transparent, >=512px,
square preferred) → `<pkg>\Assets\<App>-Logo.png` AND a copy in `Output\<App>\`. **Never** ship the PSADT
default `Assets\AppIcon.png`/`Banner.Classic.png` (see H.10 — the upload script blocks them by SHA256).

### J.1 License-clear sources, in priority order

1. **Microsoft products:** `https://learn.microsoft.com/en-us/<product>/media/index/<product>.png`
   (transparent PNG, direct download; `<product>` lowercase, e.g. `powershell`, `sqlserver`, `azure`).
2. **Other vendors:** official vendor/project source (e.g. `apache.org/logos/res/<project>/`).
3. **Wikimedia Commons** (stable URLs, SVG rendered server-side as transparent PNG):
   ```powershell
   $api = "https://commons.wikimedia.org/w/api.php?action=query&titles=$([uri]::EscapeDataString('File:<Logo>.svg'))&prop=imageinfo&iiprop=url&iiurlwidth=1024&format=json"
   $thumb = ((Invoke-RestMethod $api -Headers @{'User-Agent'='PSADT-pkg/1.0'}).query.pages.PSObject.Properties.Value).imageinfo[0].thumburl
   Invoke-WebRequest $thumb -OutFile '<pkg>\Assets\<App>-Logo.png' -Headers @{'User-Agent'='PSADT-pkg/1.0'}
   ```
   Avoid third-party PNG portals (stickpng, toppng, nicepng, ...) — hotlink protection/ads/poor quality.
4. **MSI Icon-table fallback** (when web download fails): MSI installers embed `.ico` files in an `Icon`
   table. `System.Drawing.Icon` silently falls back to 48x48 when the 256x256 frame is PNG-compressed inside
   the `.ico` on .NET 4.x — parse the raw ICO binary and extract the largest frame directly:
   ```powershell
   Add-Type -AssemblyName System.Drawing
   Add-Type -TypeDefinition @'
   using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
   public class IcoDibReader {
       public static Bitmap FromDib32(byte[] dib, int width, int height) {
           int pixelDataSize = width * height * 4;
           var pixels = new byte[pixelDataSize];
           Array.Copy(dib, 40, pixels, 0, pixelDataSize);
           var bmp = new Bitmap(width, height, PixelFormat.Format32bppArgb);
           var bd = bmp.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
           int rb = width * 4;
           for (int r = 0; r < height; r++) Marshal.Copy(pixels, (height-1-r)*rb, IntPtr.Add(bd.Scan0, r*bd.Stride), rb);
           bmp.UnlockBits(bd); return bmp;
       }
   }
   '@ -ReferencedAssemblies 'System.Drawing'
   $tmpDir = "$env:TEMP\MsiIconExport"; New-Item $tmpDir -ItemType Directory -Force | Out-Null
   $db = [System.Activator]::CreateInstance([System.Type]::GetTypeFromProgID('WindowsInstaller.Installer')).OpenDatabase('<path-to.msi>', 0)
   $db.Export('Icon', $tmpDir, 'Icon.idt')   # streams export as <IconName>.ico.ibd under a subfolder 'Icon'
   $icoPath = Get-ChildItem "$tmpDir\Icon" -Filter '*.ibd' | Sort-Object Length -Descending | Select-Object -ExpandProperty FullName -First 1
   $allBytes = [System.IO.File]::ReadAllBytes($icoPath)
   $count = [BitConverter]::ToUInt16($allBytes, 4); $bestW = 0; $bestOff = 0; $bestSize = 0
   for ($i = 0; $i -lt $count; $i++) {
       $base = 6 + $i * 16; $w = [int]$allBytes[$base]; if ($w -eq 0) { $w = 256 }
       if ($w -gt $bestW) { $bestW = $w; $bestOff = [BitConverter]::ToUInt32($allBytes, $base+12); $bestSize = [BitConverter]::ToUInt32($allBytes, $base+8) }
   }
   $frame = New-Object byte[] $bestSize; [Array]::Copy($allBytes, $bestOff, $frame, 0, $bestSize)
   if ($frame[0] -eq 0x89 -and $frame[1] -eq 0x50) {
       [System.IO.File]::WriteAllBytes('<output>.png', $frame)  # PNG-compressed frame: write directly
   } else {
       $biH = [Math]::Abs([BitConverter]::ToInt32($frame, 8)) / 2
       $bmp = [IcoDibReader]::FromDib32($frame, $bestW, [int]$biH)
       $bmp.Save('<output>.png', [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
   }
   Remove-Item $tmpDir -Recurse -Force
   ```

### J.2 Verify (resolution + ACTUAL transparency + correct brand)

`IsAlphaPixelFormat` only says the pixel *format* supports alpha — it is True even for a fully opaque image
(a 7-Zip SVG rendered with an opaque black background still reported `Alpha=True`). Sample a real corner pixel:
```powershell
Add-Type -AssemblyName System.Drawing
$b=[System.Drawing.Bitmap]::FromFile('<png>')
$c=$b.GetPixel(0,0); "{0}x{1}  cornerAlpha={2} (0=transparent,255=opaque) RGB=({3},{4},{5})" -f $b.Width,$b.Height,$c.A,$c.R,$c.G,$c.B; $b.Dispose()
```
Then **actually look at the image** to confirm it is the app's brand, not the PSADT default. Transparent
(cornerAlpha=0) is preferred; an opaque-but-correct logo is acceptable (square it on its own background colour).
The WRONG image is never acceptable.

---

## Appendix K: Script-only remediation / fix packages (ESP-safe)

Some "apps" are not vendor installers but a remediation script (debloat, a config/permissions fix, copying
files into place). They share one shape and a different detection/uninstall model from a normal app. Use this
recipe when the deliverable is a PowerShell script, not an MSI/EXE.

### K.1 The pattern
- Bundle the script in `Files\<Fix>.ps1` (keep it verbatim if it is already tested).
- **Install** = run the script via NATIVE 64-bit PowerShell (Appx/DISM cmdlets need 64-bit; the IME launches
  Win32 apps 32-bit). Put the launch in an Extensions helper so Install + Repair share it.
- **Repair** = re-run the same helper (idempotent).
- **Uninstall** = a NO-OP that only clears the package's own state (its log/tag dir). NEVER remove the fixed
  artifact - that would re-break what you fixed.
- **Detection** = a script rule that checks the real desired END-STATE (a file/registry value the fix
  establishes), so it is SELF-HEALING: if a later change breaks it again, detection goes negative and Intune
  re-applies the fix.
- **ESP-safe:** `DeployMode Silent`, no welcome/prompt, bound every external process with a timeout, never hang.
- **Exit code + detection: be HONEST (do NOT just `exit 0`).** See K.7. The exit code reflects whether the fix
  could RUN; detection reflects the real END-STATE. A blanket `exit 0` is a defect - it makes Intune report
  green on failure.

### K.2 64-bit relaunch guard (top of the bundled script)
```powershell
if ($env:PROCESSOR_ARCHITEW6432 -and -not [Environment]::Is64BitProcess) {
    $ps64 = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $ps64)) { Write-Error '64-bit PowerShell not found'; exit 1 }   # couldn't run -> non-zero
    & $ps64 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args
    exit $LASTEXITCODE   # propagate the child's HONEST exit code - do not hard-code 0 (K.7)
}
```
(Not needed when the script only touches literal `Program Files (x86)` paths and no Appx/DISM - but harmless.)

### K.3 Extensions helper (Install + Repair both call it)
```powershell
function Invoke-FixScript {
    [CmdletBinding()] param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FilesDirectory)
    begin { Initialize-ADTFunction -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState }
    process {
        try { try {
            $script = Join-Path $FilesDirectory 'Fix.ps1'
            if (-not (Test-Path -LiteralPath $script)) { throw "Fix script not found: $script" }
            $sysNative = Join-Path $env:WinDir 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
            $system32  = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $ps = if (([Environment]::Is64BitOperatingSystem) -and (-not [Environment]::Is64BitProcess) -and (Test-Path $sysNative)) { $sysNative } else { $system32 }
            Start-ADTProcess -FilePath $ps -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`"" -CreateNoWindow -SuccessExitCodes @(0)
        } catch { Write-Error -ErrorRecord $_ } }
        catch { Invoke-ADTFunctionErrorHandler -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState -ErrorRecord $_ }
    }
    end { Complete-ADTFunction -Cmdlet $PSCmdlet }
}
```

### K.4 Hooks
- **Install / Repair:** `Show-ADTInstallationProgress`; optionally `Show-ADTInstallationWelcome -CloseProcesses <proc> -Silent`
  when the fix replaces in-use files; then `Invoke-FixScript -FilesDirectory $adtSession.DirFiles`.
- **Uninstall:** `Remove-ADTFolder -LiteralPath "$env:ProgramData\<StateDir>"` (the package's own log/tag only).

### K.5 Detection (script rule, run as System, 64-bit)
Contract: write to stdout + `exit 0` when the fix is in place; emit nothing (still `exit 0`) when not.
```powershell
$marker = 'C:\path\to\the-real-end-state'   # e.g. the copied file, or the tag the fix writes
if (Test-Path -LiteralPath $marker) { Write-Output "Detected: $marker"; exit 0 }
exit 0
```
Prefer the **real end-state** (the file/registry value the fix establishes) as the marker, so detection
self-heals AND a failed fix shows as "not installed" (-> retry, and visible in Intune). If you must use a tag,
write it ONLY at the end of a SUCCESSFUL run - NEVER in a `finally` that also runs on a crash (that reports
green on failure).

### K.6 Intune + ESP wiring
- Install/Uninstall command: `Invoke-AppDeployToolkit.exe -DeploymentType Install|Uninstall -DeployMode Silent`;
  install behavior **System**; detection = the script rule (Run as 32-bit = No).
- For ESP: assign **Required**; add it as a **blocking app** ONLY if its success is genuinely a prerequisite for
  the device. A blocking app that fails (non-zero OR negative detection) holds the OOBE - which is CORRECT for a
  real malfunction. If a non-critical cleanup must never block enrollment, make that an explicit, documented
  choice: either do NOT mark it blocking, or map its "couldn't-run" code as a success return code in Intune.
  Never paper over failures with a blanket `exit 0`.

### K.7 Exit codes + detection - the honest model (READ THIS)
A blanket `exit 0` is a DEFECT: Intune then shows green even when the fix did nothing, and the only signal is the
log. Decouple two concerns:

- **Exit code = could the fix RUN?**
  - Ran to completion (even with tolerable, logged per-item best-effort failures) -> `0`.
  - Could NOT run / crashed (no admin, the 64-bit relaunch failed, enumeration threw, a required step failed) ->
    **non-zero** (e.g. `1`). Surfaces as "failed" + retry. If you relaunch into 64-bit, **propagate the child's
    exit code** (`& $ps64 ...; exit $LASTEXITCODE`) - do not hard-code `exit 0` in the launcher branch.
- **Detection = is the real END-STATE present?** Point it at what the fix establishes (the copied file, the
  registry value), NOT an unconditional tag. A failed fix -> end-state absent -> "not installed" -> retry, and
  visible in Intune. If you use a tag, write it ONLY on a successful run (never in a `finally`).
- **Log the truth regardless:** per-item PASS/FAIL + a final summary (failure count) under
  `%ProgramData%\<App>\...log`, so a best-effort partial is auditable.

Decision rule by package type:
| Type | Exit code | Detection |
|---|---|---|
| Real installer (MSI/EXE) | map real codes: `0/1707` ok, `3010/1641` reboot, **else failed** - never force 0 | MSI ProductCode / file version |
| Important fix (e.g. Cisco UI) | failure -> **non-zero** (Intune failed + retry) | the real end-state (e.g. the UI binary present) |
| Non-critical ESP cleanup (debloat) | couldn't-run -> **non-zero**; best-effort partial -> `0` (logged) | real end-state, or a tag written ONLY on success |

The "never block enrollment" goal is reached by the ESP assignment choice + return-code mapping (K.6), NOT by
lying about the exit code.

---

## Appendix L: Installer technologies + silent switches (consult BEFORE web research)

Phase 2 research checks THIS table first and only web-searches to confirm the exact build's quirks. "Identify"
= how to recognise the tech; switches are the common silent install / uninstall / no-reboot / log; "Detect" =
the natural detection rule.

### L.1 Identify the technology
- File metadata/strings: `(Get-Item setup.exe).VersionInfo`; a `strings`-style scan for marker text.
- **Inno Setup:** EXE contains `Inno Setup` / `JR.Inno.Setup`; uninstaller `unins000.exe`.
- **NSIS:** EXE contains `Nullsoft.NSIS` / `NullsoftInst`; uninstaller `Uninstall.exe` / `uninst.exe`.
- **InstallShield:** `setup.exe` + `*.cab` / `data1.hdr` / `0x0409.ini`; strings `InstallShield`.
- **WiX Burn bundle:** EXE strings `WixBundle` / `.wixburn`; has a `BundleProviderKey`.
- **MSI:** a `.msi` (or an EXE that strings-shows `Windows Installer` / extracts an MSI).
- **Squirrel:** `Update.exe` + `*.nupkg`; per-user `%LocalAppData%\<App>`.
- **MSIX/AppX:** `.msix` / `.appx` / `.msixbundle`.

### L.2 Switch reference
| Tech | Silent install | Silent uninstall | No reboot | Log | Detect | Notes |
|---|---|---|---|---|---|---|
| **MSI** | `msiexec /i pkg.msi /qn` | `msiexec /x {ProductCode} /qn` | `/norestart` | `/l*v "log"` | MSI ProductCode | props as `NAME=value`; `REBOOT=ReallySuppress` |
| **MSI-wrapped EXE** | vendor flag, often `/s /v"/qn /norestart"` | extracted MSI ProductCode | `/v"/norestart"` | `/v"/l*v log"` | ProductCode | prefer extracting the MSI (`/a` admin install or `setup.exe /extract`) |
| **InstallShield (Basic MSI)** | `setup.exe /s /v"/qn"` | ProductCode | `/v"/norestart"` | `/v"/l*v log"` | ProductCode | |
| **InstallShield (InstallScript)** | `setup.exe /s /f1"setup.iss"` | `setup.exe /s /x /f1"uninstall.iss"` | (ISS-driven) | `/f2"log"` | registry / file | record the `.iss` with `setup.exe /r /f1"setup.iss"` |
| **Inno Setup** | `setup.exe /VERYSILENT /SUPPRESSMSGBOXES /SP-` | `unins000.exe /VERYSILENT` | `/NORESTART` | `/LOG="log"` | QuietUninstallString / registry | `/SILENT` shows a progress bar, `/VERYSILENT` none |
| **NSIS** | `setup.exe /S` | `Uninstall.exe /S` | (installer-specific) | `/D=path` (last arg, unquoted) | registry / file | `/S` is case-SENSITIVE |
| **WiX Burn bundle** | `bundle.exe /quiet /norestart` | `bundle.exe /uninstall /quiet` | `/norestart` | `/log "log"` | registry (BundleProviderKey) / file version | wraps MSIs; a single ProductCode is unreliable |
| **Squirrel (Electron)** | `Setup.exe --silent` | `%LocalAppData%\<App>\Update.exe --uninstall -s` | n/a | n/a | file version under `%LocalAppData%` | usually PER-USER; a System/Win32 install needs care |
| **MSIX / AppX** | provisioning (`Add-AppxProvisionedPackage`) | `Remove-AppxPackage` | n/a | n/a | package name / version | different model; not a classic Win32 installer |
| **install4j / IzPack (Java)** | `installer.exe -q -overwrite` / `-options resp.txt` | uninstaller `-q` | n/a | `-Dinstall4j.logToStderr=true` | registry / file | response-file driven |
| **InstallAware / Wise** | `/s` or `/silent` | vendor-specific | varies | varies | registry / file | confirm per build; often MSI underneath |

### L.3 Detection-rule choice
- MSI / MSI-wrapped -> **MSI ProductCode** rule (upload `-MsiProductCode`).
- EXE / other -> a **PowerShell detection script** (file version / registry value), OR an Intune **file/registry
  version rule**. Never mix a script rule and a file/registry rule for the same app.
- Per-user installers (Squirrel) detect under `%LocalAppData%` - run detection in the right context.

---

## Appendix M: Group assignment (opt-in) - config-driven Entra groups + win32LobApp assignment

Assignment is **opt-in** and resolved at intake Gate 2 (target audience + AAD groups). The default is **no
assignment** - uploading an app NEVER auto-targets anyone. When the user does want the skill to manage the
assignment groups, `Invoke-IntuneAppAssignment.ps1` creates/reuses Entra security groups by a configured naming
scheme and assigns the uploaded `win32LobApp` to them (intents `required` / `available` / `uninstall`).
Read-only dry run by default; `-Execute` writes. It is **idempotent** and **never deletes** a group or another
app's assignment.

### M.1 Permissions (least-privilege)
The upload app (`PSADT Intune Upload`) needs two extra Graph **application** roles beyond the upload role:

| Action | Role |
|---|---|
| upload + assign the app | `DeviceManagementApps.ReadWrite.All` (already required for upload) |
| find a group by name | `GroupMember.Read.All` |
| create a group the app then OWNS | `Group.Create` (NOT the tenant-wide `Group.ReadWrite.All`) |

Grant them once (opt-in), needs Global Admin / Privileged Role Admin to consent:

```
pwsh scripts/New-PsadtEntraApp.ps1 -IncludeGroupManagement
```

This re-runs idempotently against the existing app and PATCHes its requested permissions. If consent is denied,
the app + credential still exist and the run reports the pending roles to grant in the portal.

### M.2 Config schema (`intune.groups`)
The feature is off unless `intune.groups.enabled` is `true`. Schema:

```
intune.groups = {
  enabled        = true            # master switch; off => the script throws "not enabled"
  create         = true            # true: create a missing group; false: assign-to-existing-only (report MISSING)
  membershipType = 'assigned'      # ONLY 'assigned' (static) is implemented; anything else throws
  naming         = {               # at least one of required/available/uninstall must be present
    required  = 'intune-win-app-required-%appname%'
    available = 'intune-win-app-available-%appname%'
    uninstall = 'intune-win-app-uninstall-%appname%'
  }
}
```

Write it with `Set-PsadtConfig.ps1` (dotted paths; the naming sub-tree is passed as one hashtable):

```
pwsh scripts/Set-PsadtConfig.ps1 -Updates @{
  'intune.groups.enabled'        = $true
  'intune.groups.create'         = $true
  'intune.groups.membershipType' = 'assigned'
  'intune.groups.naming'         = @{
      required  = 'intune-win-app-required-%appname%'
      available = 'intune-win-app-available-%appname%'
      uninstall = 'intune-win-app-uninstall-%appname%'
  }
}
```

`Get-PsadtConfig.ps1` validates this: when `enabled` is true it reports `intune.groups.naming` as Missing if no
template is present, or flags that at least one of required/available/uninstall is needed.

### M.3 Naming tokens + the rules that bite
`Resolve-GroupName` substitutes these tokens (case-insensitive; both `%token%` and `{Token}` forms work):

| Token | Source |
|---|---|
| `%appname%` | the `-AppName` passed to the assignment script |
| `%appvendor%` | the `-AppVendor` |
| `%apparch%` | the `-AppArch` (default `x64`) |
| `%version%` | the `-AppVersion` |

Two rules that are easy to get wrong:

- **There is NO `%intent%` token.** The intent (required/available/uninstall) is the *key* of the naming
  template, not a substitution. To put the intent in the name, bake it into each template literally
  (`intune-win-app-required-%appname%`, `...-available-...`, etc.). A `%intent%` placeholder would survive
  verbatim into the group name.
- **Group names contain NO spaces.** Every token value is space-stripped before substitution and the final name
  is space-stripped as a safety net. So `-AppName 'Norton Neo'` yields `NortonNeo` in the name.

**Version-independent by default (recommended).** Leave `%version%` OUT of the naming templates. Then a NEW app
version resolves the SAME groups, so on the next upload you assign the new app + wire supersedence
(`Invoke-IntuneWin32Upload.ps1 -SupersedesAppId <oldId>`) and the new version automatically targets the same
audience while the old app is retained for rollback. This is the whole point of config-driven naming.

**`%version%` opt-in (use deliberately).** Including `%version%` (e.g. `...-%appname%-%version%`) makes the group
names **version-specific**: every version creates its own groups and you must re-add members for each release.
This breaks the supersedence reuse above. Choose it only when you genuinely want per-version audiences.

### M.4 Workflow
Always dry-run first (read-only), confirm the planned group names + actions, then `-Execute`:

```
# dry run
pwsh scripts/Invoke-IntuneAppAssignment.ps1 -AppId <id> -AppName '<App>' -AppVendor '<Vendor>' `
    -AppVersion '<x.y.z>' -AppArch x64 -Intents required, available
# execute
pwsh scripts/Invoke-IntuneAppAssignment.ps1 -AppId <id> -AppName '<App>' -AppVendor '<Vendor>' `
    -AppVersion '<x.y.z>' -AppArch x64 -Intents required, available -Execute
```

Per intent the script resolves the group by `displayName` (directory read uses `ConsistencyLevel: eventual`)
and then:

| Found | create | Action |
|---|---|---|
| exactly 1 | - | **reuse** that group |
| 0 | true | **create** (assigned/static security group the app owns) |
| 0 | false | **MISSING** - skip (create it manually or set `create=true`) |
| >1 (name not unique) | - | **AMBIGUOUS** - skip, never guess |

The assignment itself is idempotent: an existing assignment for the same group + intent is left untouched.
`-Intents` defaults to every intent that has a naming template. Output is a structured object
(`Groups[{Intent,Name,Id,Action}]`, `Assignments[{Intent,GroupId,Action}]`) - feed `Groups` into the dossier's
Assignments table.

### M.5 Gotchas
- **`-SkillRoot` / config location.** The script reads config + acquires the token from `-SkillRoot` (default:
  the script's parent). The `intune.groups` block, the `intune` credentials, and `secret.dpapi` must all live in
  the SAME config the script resolves. The DPAPI secret is `CurrentUser`-bound per install, so the installed
  skill's `config.json` is the canonical one - point `-SkillRoot` at it if you run the script from a clone.
- **`membershipType` is `assigned` only.** Dynamic membership is not implemented; the script throws rather than
  silently creating a static group when you asked for a rule.
- **Never auto-impose.** Group assignment is only ever done when the user opted in at Gate 2 AND
  `intune.groups.enabled` is true. No default audience, no implicit "All Users/All Devices".

## Appendix N: Certificate store deployment (driver-trust / TrustedPublisher etc.)

When a package needs a certificate in a Windows **machine** certificate store, treat it as a first-class
deliverable - never an afterthought hidden inside the install hook. The classic trigger: an EXE/MSI that stages a
**third-party driver** (printer, label/card printer, scanner, USB device) makes Windows pop
**"Would you like to install this device software?"** under SYSTEM/Intune that you cannot click - so the silent
install stalls or the driver part fails. The fix is to pre-trust the driver publisher's **code-signing**
certificate in **`LocalMachine\TrustedPublisher`**. Same machinery covers Root/CA/TrustedPeople.

### N.1 Which mechanism for which store

| Target store | Mechanism |
|---|---|
| Root, Intermediate (CA) | Intune built-in **Trusted certificate** profile (template) - OR the CSP below |
| **TrustedPublisher**, **TrustedPeople** | **ONLY** the `RootCATrustedCertificates` CSP via a **Custom OMA-URI** profile. The built-in template canNOT target these. |

Do NOT claim "Intune can't do TrustedPublisher" - it can, just not via the template. The CSP is the answer.

### N.2 The recipe (what the skill prepares from itself)

1. **Get the cert.** A raw cert file (`.cer/.crt/.der`) loads directly; for a driver, extract the **Authenticode
   signer** from any signed payload file (the MSI, `Setup.exe`, a `.cat`/`.sys`/`.dll`). The signer subject must
   match the publisher shown in the Windows device-software prompt.
2. **Single-line base64** of the DER bytes - `[Convert]::ToBase64String($cert.RawData)`. **NO line breaks / no
   PEM headers** - the CSP rejects formatted base64 with **`0x87d1fde8`**.
3. **OMA-URI:** `./Device/Vendor/MSFT/RootCATrustedCertificates/<Store>/<SHA1-Thumbprint>/EncodedCertificate`
   - Thumbprint uppercase, hex only. It MUST match the cert in the value, or the CSP errors `0x87d1fde8`.
   - Data type **String**, value = the single-line base64.
4. An **expired** signing cert still works: the driver signature is timestamped, and TrustedPublisher matches by
   certificate identity, not validity date.

`scripts/New-IntuneTrustedCertPolicy.ps1` does all of this: pass `-CertPath <cert-or-signed-file>` (or
`-Thumbprint`), `-Store TrustedPublisher`. Dry-run prints the OMA-URI, the base64 length, and the manual portal
steps; `-Execute` creates the Custom profile via Graph.

### N.3 Ownership: policy OR package - exactly one

Pick ONE owner of the cert; never both (the package would remove it on uninstall while the policy re-adds it at
the next sync - they fight).

| Owner | How | Trade-off |
|---|---|---|
| **Intune policy (recommended, transparent)** | `New-IntuneTrustedCertPolicy.ps1` / Custom OMA-URI profile, assigned to the SAME device scope as the app | Visible config, separate lifecycle. First install can race the profile - the cert is device-wide + persistent, so Intune's app retry succeeds once the profile has applied. |
| **Package (script)** | `Import-Certificate -FilePath <cer> -CertStoreLocation Cert:\LocalMachine\TrustedPublisher` in the install hook, BEFORE the driver installer; remove it on uninstall | Guarantees the cert is present in the same session as the driver (no first-install race). But it is a "hidden" script action and couples cert lifecycle to the app. |

Surface this as a researched choice (it is NOT a default gate, but state the assumption + recommended option
and let the user redirect). Whatever the choice, still hand over the prepared OMA-URI + base64 in the dossier.

### N.4 Graph permission + manual fallback

Creating a configuration profile needs the Graph application role **`DeviceManagementConfiguration.ReadWrite.All`**
- the upload app (`PSADT Intune Upload`) only has `DeviceManagementApps.ReadWrite.All`, so `-Execute` may get
**403**. The script catches that and prints the manual portal steps instead of failing. Either grant the role
(Global Admin) and re-run, or create it by hand:

1. **Devices > Configuration > Create > New policy**; Platform **Windows 10 and later**, Profile type
   **Templates > Custom**.
2. Name it (e.g. `Cert - <Publisher> -> TrustedPublisher`).
3. Add OMA-URI setting: **OMA-URI** = the path from N.2, **Data type** = String, **Value** = the single-line base64.
4. **Assign to the same device scope as the app**, then Create.

### N.5 Gotchas
- **Thumbprint/value mismatch -> `0x87d1fde8`.** The thumbprint in the OMA-URI must be the SHA1 of the exact cert
  in the value. Re-export both from the same source.
- **Line breaks in the base64 -> `0x87d1fde8`.** Single line only.
- **Assignment scope.** Assign the cert profile to the SAME group/scope as the app, or the silent driver install
  races a device without the trust.
- **One owner only** (N.3). If you ship the policy, do NOT also import the cert in the package, and vice-versa.

---

## Appendix O: Browser extension force-install packages (opt-in)

A distinct, recurring package type: deploy a **browser extension** to Edge / Chrome / Firefox. In the
enterprise these are not "installed" - you set **policy registry keys** and each browser pulls the extension
from its own store. So this is a **policy-only** package: no vendor installer, `Files\` empty, ESP-safe, no
reboot. It is **opt-in** (Gate 1 package-type choice), never the default for a normal app.

Generate the whole package in one call: **`scripts/New-BrowserExtensionPackage.ps1`** writes the launcher
(data model + 3 hooks), the Extensions module (4 merge/remove helpers) and the detection script.

### O.1 The model

| | |
|---|---|
| Source | **Online store force-install only** (Chrome Web Store / Edge Add-ons / Firefox AMO). Self-hosted CRX/XPI is out of scope. |
| Mechanism | Policy registry keys (O.3). Browser applies them on its next start; nothing is launched, no process closed. |
| Deployment types | Install = set keys (merge), Uninstall = remove ONLY own keys, Repair = re-apply (idempotent). |
| Coexistence | Multiple extension packages share the same policy keys - **merge**, never clobber; remove only own entries (O.5). |
| Detection | Verifies the **policy is set** (registry), NOT that the browser actually loaded the extension (O.7). |

### O.2 Phase-2 research (replaces the silent-switch research)

Find the extension in each store the customer uses and capture the per-store ID:
- **Chrome Web Store** - ID = 32 chars `a-p`, from the URL `.../detail/<slug>/<ID>`.
- **Edge Add-ons** - ID = 32 chars `a-p`, from `microsoftedge.microsoft.com/addons/detail/<slug>/<ID>`. (Edge can also load Chrome Web Store IDs if the org allows other stores; default is the Edge ID.)
- **Firefox AMO** - ID = `name@domain` or a GUID (from the listing / the `.xpi` manifest), PLUS the **AMO slug** (`addons.mozilla.org/.../addon/<slug>/`). The install_url is `https://addons.mozilla.org/firefox/downloads/latest/<slug>/latest.xpi`.

Set only the browsers that actually carry the extension. Not in a store -> it cannot be force-installed this way
(only self-hosted, which is out of scope) - say so.

### O.3 Registry reference (verbatim - get these wrong and it silently fails)

| Browser | HKLM path | Value | Type | Format |
|---|---|---|---|---|
| Chrome | `SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist` | index `"1","2",...` | `REG_SZ` | `"<id>;https://clients2.google.com/service/update2/crx"` |
| Edge | `SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist` | index `"1","2",...` | `REG_SZ` | `"<id>;https://edge.microsoft.com/extensionwebstorebase/v1/crx"` |
| Firefox | `SOFTWARE\Policies\Mozilla\Firefox` | `ExtensionSettings` | **`REG_MULTI_SZ`** | JSON `{"<id>":{"installation_mode":"force_installed","install_url":"https://addons.mozilla.org/firefox/downloads/latest/<slug>/latest.xpi"}}` |

- **Firefox MUST be `REG_MULTI_SZ`.** A single-line `REG_SZ` is silently ignored by current Firefox
  (Mozilla bug 1750233). In PowerShell: `New-ItemProperty -PropertyType MultiString`.
- **Chrome/Edge values are keyed by index NAME but matched by VALUE.** The browser only reads the values, not
  the names - so the index is just a unique label.
- **Removing a Chrome/Edge forcelist entry makes the browser auto-uninstall the extension** - that IS the
  uninstall path. Firefox: remove the id from the JSON.
- HKLM policy keys are not WOW-redirected -> run detection 64-bit (Run as 32-bit = No).

### O.4 Generate the package (one call, in-process)

`-Extensions` is an array of hashtables, so call the generator **in-process** (not `pwsh -File`, which
stringifies the array):
```powershell
$exts = @(
    @{ Name='uBlock Origin'
       Edge   = @{ Id='odfafepnkmbhccpbejgmiehpchacaeak' }
       Chrome = @{ Id='cjpalhdlnbpafiamejdnhcphjbkeiagm' }
       Firefox= @{ Id='uBlock0@raymondhill.net'; Slug='ublock-origin' } }   # Slug -> AMO install_url is derived
    @{ Name='1Password'
       Edge   = @{ Id='dppgmdbiimibapkepcbdbmkaabgiofem' }
       Chrome = @{ Id='aeblfdkhhhdcdjpifhhbdiojplfjncoa' } }                 # Edge+Chrome only (no Firefox set)
)
& scripts/New-BrowserExtensionPackage.ps1 -Name 'BrowserExtensions-Standard' `
    -AppName 'Browser Extensions (Standard Set)' -Extensions $exts
```
The data model lands at the top of `Invoke-AppDeployToolkit.ps1` as `$script:BrowserExtensions` (the single
source of truth for all three hooks AND the detection script). Each entry sets at least one browser; Firefox
takes either `Slug` (install_url derived) or an explicit `InstallUrl`.

### O.5 Extensions helpers (merge + selective remove)

Written into `PSAppDeployToolkit.Extensions.psm1`:
- `Set-ADTChromiumForcelistEntry -Browser Edge|Chrome -ExtensionId <id>` - reads ALL existing values, **next
  free numeric index** (never hard-codes `1`), idempotent (skips if the id is already present), foreign entries
  untouched.
- `Remove-ADTChromiumForcelistEntry -Browser Edge|Chrome -ExtensionId <id>` - deletes only the value whose data
  is `"<id>;..."`.
- `Set-ADTFirefoxExtensionSetting -ExtensionId <id> -InstallUrl <xpi>` - reads `ExtensionSettings`
  (`REG_MULTI_SZ` -> join lines -> `ConvertFrom-Json`), merges the id as `force_installed`, writes back as
  `REG_MULTI_SZ`.
- `Remove-ADTFirefoxExtensionSetting -ExtensionId <id>` - removes the id from the JSON; deletes the whole value
  when it becomes empty. (Emptiness is tested via `ConvertTo-Json` == `{}`, NOT `PSObject.Properties.Count` - a
  PSCustomObject reports a phantom empty-named property after the last note property is removed.)

### O.6 Hooks

Install loops the data model and calls the matching `Set-` helper per browser; Uninstall calls the `Remove-`
helpers; Repair re-applies (idempotent). No `Show-ADTInstallationWelcome`/process-close (policy-only). Generated
for you - do not hand-roll.

### O.7 Detection + Intune wiring

`Detect-<Name>.ps1` embeds the same data model and checks every managed entry is present (forcelist contains
`"<id>;*"`; Firefox JSON has the id with `installation_mode=force_installed`). Contract: stdout + `exit 0` when
ALL present; no output + `exit 0` otherwise.

**Honest model:** detection proves the **policy is set**, not that each browser/profile has actually downloaded
the extension (that is online + per-user and outside the package's control). Do NOT write a detection that
claims "extension installed".

Intune: Install behavior **System**; `-DeployMode Silent`; detection = **script rule**, Run as 32-bit = No; no
reboot; ESP-safe (fast, registry-only). Pre-flight (Phase 5) passes unchanged - the acid-test sees the three
hooks + all four helpers called.

### O.8 Dossier additions

Reuse the standard `$meta` fields - no new template tokens:
- `DescMdDe/En`: list the managed extensions and which browsers each targets; note "managed by your
  organization" appears in the browser.
- `RuleFormat` / detection note: "policy present (registry); the browser pulls the extension from its store -
  requires network + store reachability."
- `DependenciesNote`: none (the extension is fetched online by the browser).

### O.9 Anti-patterns

- Firefox `ExtensionSettings` as `REG_SZ` (silently ignored) - it MUST be `REG_MULTI_SZ`.
- Clobbering the whole forcelist key / overwriting `ExtensionSettings` instead of merging - destroys other
  packages' extensions. Always next-free-index / JSON-merge, and remove ONLY own entries.
- Hard-coding forcelist index `1` - collides with other extension packages.
- Detection that asserts the extension is installed in the profile (it can only assert the policy is set).
- Self-hosted CRX/XPI dressed up as "store force-install" - different mechanism, out of scope here.

---

## Appendix P: Windows-feature packages (optional features + capabilities, opt-in)

Enable **additional Windows features** as an Intune Win32 app. Two mechanisms, one generator:
- **Optional Features** (DISM): `Enable-WindowsOptionalFeature` - e.g. `NetFx3`, `Microsoft-Hyper-V-All`,
  `Microsoft-Windows-Subsystem-Linux`, `TelnetClient`, `TFTP`, `Containers-DisposableClientVM` (Windows Sandbox).
- **Capabilities / Features on Demand (FoD)**: `Add-WindowsCapability` - e.g. `Rsat.*~~~~0.0.1.0`,
  `OpenSSH.Client~~~~0.0.1.0`.

Feature-only package: no vendor installer; `Files\` is empty unless you bundle an offline source. Built in one
call by **`scripts/New-WindowsFeaturePackage.ps1`** (launcher + Extensions helpers + detection). Opt-in
(Gate-1 package-type choice). Live example already in the repo: `Output\RSAT-1.0.0`.

### P.1 Model

| | |
|---|---|
| Source | Bundled offline `-Source` if present, else **Windows Update** (with a temporary WSUS bypass, P.8). |
| Reboot | Many optional features need a reboot -> `-NoRestart`, surface **3010** (P.6). So **NOT always ESP-safe** - if blocking during ESP, expect the OOBE reboot. |
| Deployment types | Install = enable, Uninstall = **revert** (disable/remove), Repair = re-enable (idempotent). |
| Coexistence | Feature state is global + idempotent (no shared-key merge like the forcelist). The risk is Uninstall: disabling a feature another product needs - scope the assignment. |
| Detection | Each feature in its target state: OptionalFeature -> `Enabled`, Capability -> `Installed` (P.7). |

### P.2 Phase-2 research (replaces the silent-switch research)

Capture the **exact** name and whether content/reboot is needed:
```powershell
Get-WindowsOptionalFeature -Online | Where-Object FeatureName -like '*<term>*' | Select FeatureName, State
Get-WindowsCapability -Online -Name '*<term>*' | Select Name, State            # FoD names end ~~~~0.0.1.0
```
Note per feature: exact `FeatureName`/capability `Name`, reboot expectation, and whether an offline source is
required (NetFx3 on locked-down/no-WU clients) or WU is reachable. Capability names are version-suffixed
(`Rsat.Dns.Tools~~~~0.0.1.0`) - copy them verbatim.

### P.3 Cmdlet + state reference

| Type | Enable | Disable / Remove | Detect cmdlet | Target state |
|---|---|---|---|---|
| OptionalFeature | `Enable-WindowsOptionalFeature -Online -FeatureName <n> -All -NoRestart [-Source <p> -LimitAccess]` | `Disable-WindowsOptionalFeature -Online -FeatureName <n> -NoRestart` | `Get-WindowsOptionalFeature -Online -FeatureName <n>` | `Enabled` |
| Capability | `Add-WindowsCapability -Online -Name <n> [-Source <p> -LimitAccess]` | `Remove-WindowsCapability -Online -Name <n>` | `Get-WindowsCapability -Online -Name <n>` | `Installed` |

`-All` pulls in parent/dependency features. The enable cmdlets return an object with `.RestartNeeded`.
`EnablePending` = enabled but awaiting reboot (detection treats it as not-yet-done, P.7).

### P.4 Generate the package (one call, in-process)

`-Features` is an array of hashtables, so call **in-process** (not `pwsh -File`, which stringifies the array):
```powershell
$feats = @(
    @{ Type='OptionalFeature'; Name='NetFx3'; Source='sxs' }   # Source optional: a relative path under Files\
    @{ Type='OptionalFeature'; Name='TelnetClient' }
    @{ Type='Capability';      Name='Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0' }
)
& scripts/New-WindowsFeaturePackage.ps1 -Name 'WinFeatures-Admin' `
    -AppName 'Windows Features: RSAT + .NET 3.5' -Features $feats
```
The model lands as `$script:WindowsFeatures` at the top of `Invoke-AppDeployToolkit.ps1` (single source of truth
for the three hooks AND the detection script). For an offline source, drop the SxS cabs under `Files\<Source>`
(e.g. `Files\sxs` from the ISO `sources\sxs`).

### P.5 Extensions helpers

Written into `PSAppDeployToolkit.Extensions.psm1`:
- `Enable-ADTWindowsFeatureItem -Type -Name [-SourcePath]` - dispatches OptionalFeature vs Capability;
  idempotent (skips if already `Enabled`/`Installed`); uses `-Source -LimitAccess` when `SourcePath` exists,
  else pulls from WU; **returns $true if a restart is needed**.
- `Disable-ADTWindowsFeatureItem -Type -Name` - disable/remove, idempotent; returns restart-needed.
- `Set-ADTWindowsUpdateFodAccess` / `Restore-ADTWindowsUpdateFodAccess` - temporary WSUS bypass
  (`RepairContentServerSource=2`, `UseWUServer=0`, restart `wuauserv`) that **records the exact prior state**
  and restores it (re-set prior value, or remove the value if it did not exist before).

### P.6 Hooks + reboot

Install wraps the enable loop in `try { ... } finally { Restore-ADTWindowsUpdateFodAccess }` (the bypass is set
only when at least one feature lacks a bundled source). If any feature reports `RestartNeeded`, the hook calls
**`$adtSession.SetExitCode(3010)`** - the launcher's trailing `Close-ADTSession` then returns 3010 and Intune
prompts the reboot. `AppRebootExitCodes=@(1641,3010)`. Uninstall reverts; Repair re-enables. Generated for you.

### P.7 Detection + Intune wiring

`Detect-<Name>.ps1` embeds the model and checks every feature is `Enabled`/`Installed`. Contract: stdout +
`exit 0` when ALL present; no output + `exit 0` otherwise. **`EnablePending` counts as not-yet-detected** -
honest: after the 3010 reboot the state flips to `Enabled`/`Installed` and detection passes. Intune: Install
behavior **System**; `-DeployMode Silent`; detection = **script rule, Run as 32-bit = No** (DISM cmdlets need
64-bit). Pre-flight (Phase 5) passes unchanged.

### P.8 Content source (bundled vs Windows Update)

- **Bundled (offline):** put the SxS cabs under `Files\<Source>`; the helper uses `-Source <path> -LimitAccess`
  (no WU contact). Best for NetFx3 on locked-down clients; the package grows and must match the Windows build.
- **Windows Update (default when no source):** WSUS-bound devices cannot fetch FoD/optional-feature content
  unless `RepairContentServerSource=2` (`...\Policies\Servicing`) and `UseWUServer=0` (`...\WindowsUpdate\AU`)
  are set. The helper sets these **temporarily** and restores them in `finally`. Symptom when missing:
  `0x800f0950` / `0x800f081f` "source files could not be found".

### P.9 Dossier additions

Reuse the standard `$meta` fields - no new template tokens:
- `DescMdDe/En`: list the features (type + name) and whether a reboot is expected.
- `RuleFormat` / detection note: "feature state (Enabled/Installed); reboot may be required before detection
  succeeds."
- Requirements: note the content source (bundled vs Windows Update / network needed).
- Reboot behaviour: 3010 soft reboot when a feature requests it.

### P.10 Anti-patterns

- Writing the detection to require `Enabled`/`Installed` but enabling **without `-NoRestart`** - the DISM call
  reboots the device mid-install instead of returning 3010.
- Forgetting the WSUS bypass on managed devices -> `0x800f0950` (content not found). And: setting the bypass but
  not restoring it (leaves the device pulling FoD directly from WU permanently).
- Detection run as 32-bit (DISM cmdlets unavailable / wrong view) - must be 64-bit.
- Disabling a **shared** feature on uninstall and breaking other software - scope the assignment, document it.
- Treating `EnablePending` as installed (it isn't yet) - rely on the 3010 reboot, then re-detect.

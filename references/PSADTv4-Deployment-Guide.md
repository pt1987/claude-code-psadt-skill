# PSADT v4.x Deployment Guide - Intune

Mandatory end-to-end guide for Intune Win32 packages with PSADT 4.x. Work through it in this order. Do not skip any phases.

- **Phase 0**: Research + Intake (BEFORE the first click)
- **Phase 1**: Scaffold via `New-ADTTemplate`
- **Phase 2**: Script customizing
- **Phase 3**: Pre-flight checks (encoding, parse, launcher simulation)
- **Phase 4**: Build the .intunewin
- **Phase 5**: Intune app configuration
- **Phase 6**: Test sequence
- **Phase 7**: Rollout
- **Appendices**: A Error Reference / B Anti-Patterns / C Stub Tricks / D Resources / E Final Checklist / F Intune Upload Dossier / G Lessons Learned

---

## Phase 0: Research + Intake (DO NOT skip)

### 0.1 Check the current PSADT version

Before any package is built: is the local PSADT module still up to date? Breaking changes between minor versions do happen (4.0.x -> 4.1.x parameter renames).

**Check commands (online + local):**

```powershell
# Lokale Modulversion
Get-Module -ListAvailable -Name PSAppDeployToolkit | Select-Object Version,Path

# Neueste Release-Info von GitHub (API, ohne Auth)
$rel = Invoke-RestMethod 'https://api.github.com/repos/PSAppDeployToolkit/PSAppDeployToolkit/releases/latest'
"Neueste: $($rel.tag_name) vom $($rel.published_at)"
$rel.body -split "`n" | Select-Object -First 40   # Changelog-Auszug
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

### 0.2 Intake questions about the app (before a single line of code exists)

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

### 0.3 Web research on the specific installer

Research per app - without these answers there is no successful silent install:

**Mandatory search queries (examples):**
```
"<AppName>" "<Version>" silent install command line
"<AppName>" msi transform mst enterprise deployment
"<AppName>" uninstall silent /quiet /qn
"<AppName>" site:<hersteller-docs-domain> deployment guide
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

## Phase 1: Scaffold via `New-ADTTemplate`

Do not create folders manually. The official cmdlet builds the correct structure.

### 1.1 Load the module, generate the scaffold

```powershell
# Einmalig - oder wenn Version veraltet
Install-Module PSAppDeployToolkit -Scope CurrentUser -Force
# Alternativ: vom GitHub-Release .zip runterladen und manuell nach $HOME\Documents\PowerShell\Modules\PSAppDeployToolkit\<ver>\ entpacken

Import-Module PSAppDeployToolkit
```

The values come from the intake in Phase 0.2 - replace `<...>` with the ACTUAL values of the app currently being packaged.

**Basic scaffold (only destination + name):**
```powershell
New-ADTTemplate -Destination '<Root-Ordner>' -Name '<AppName>'
# e.g. New-ADTTemplate -Destination '<paths.packageRoot from config>' -Name 'FooBar 10'
```

Creates `<Root-Ordner>\<AppName>\` with the complete v4 structure. The default is `-Version 4` (current v4 style). `-Version 3` gives the v3 compatibility template (you no longer need that in 2026).

**Extended scaffold (pre-populated with app metadata, values from Phase 0.2):**
```powershell
New-ADTTemplate -Destination '<Root-Ordner>' `
    -Name '<AppName>' `
    -AppVendor '<Hersteller>' `
    -AppName '<ProduktKurzname>' `
    -AppVersion '<Major.Minor.Build.Rev>' `
    -AppArch '<x64|x86|ARM64>' `
    -AppLang '<EN|DE|Multi>' `
    -AppRevision '<01>' `
    -AppSuccessExitCodes @(<0>, <1707>) `
    -AppRebootExitCodes @(<1641>, <3010>) `
    -AppScriptAuthor '<Vorname Nachname>'
```

The values land directly as `$adtSession = @{...}` in the generated `Invoke-AppDeployToolkit.ps1`. Less manual editing = fewer typos.

> The `Adobe Acrobat Pro` and `Oracle XE` references further down in this document are illustration only - for every new package the app TO BE PACKAGED is inserted here, not Adobe or Oracle.

### 1.2 What the scaffold produces

```
<Destination>\<Name>\
  Invoke-AppDeployToolkit.exe          # 4.x Launcher
  Invoke-AppDeployToolkit.ps1          # Template mit Pre/Install/Post-Hooks
  PSAppDeployToolkit\                  # Komplettes Modul (psd1 + psm1 + lib\)
  PSAppDeployToolkit.Extensions\       # Leere Extension-Shell (eigenes Code-Home)
  Files\                               # Hier kommen Installer-Binaries rein
  SupportFiles\                        # MST, INI, XML, Scripts
  Assets\                              # Icon (AppIcon.png), Logos
  Config\                              # PSADT Config-Overrides (optional)
  Strings\                             # Lokalisierungs-Overrides (optional)
```

### 1.3 First verification of the scaffold

```powershell
$pkg = '<scaffold path>'   # e.g. '<paths.packageRoot from config>\<AppName>'
# the module version in the scaffold must match the installed version
(Import-PowerShellDataFile "$pkg\PSAppDeployToolkit\PSAppDeployToolkit.psd1").ModuleVersion
# Template-Version im Script
Select-String "$pkg\Invoke-AppDeployToolkit.ps1" -Pattern 'DeployAppScriptVersion' -List | Select-Object Line
```

Both must match (typically `4.1.8`). If they diverge -> reinstall the module + scaffold again.

---

## Phase 2: Script customizing

### 2.1 Put the installer in `Files\`

Everything that is `setup.exe`, `*.msi`, `*.mst`, response files, runtime assets lands under `<pkg>\Files\`.
In the script then use `$adtSession.DirFiles` as the root.

### 2.2 Finalize the `$adtSession` metadata

In `Invoke-AppDeployToolkit.ps1` check the hashtable (see 0.2 Intake for the values):

```powershell
$adtSession = @{
    AppVendor                   = '<Hersteller>'
    AppName                     = '<Produkt-Kurzname>'
    AppVersion                  = '<Major.Minor.Build.Rev>'
    AppArch                     = '<x64|x86|ARM64>'
    AppLang                     = '<EN|DE|Multi>'
    AppRevision                 = '<01>'
    AppSuccessExitCodes         = @(0, 1707)                           # Installer-spezifisch ergaenzen
    AppRebootExitCodes          = @(1641, 3010)
    AppProcessesToClose         = @('<prozess1>', '<prozess2>')        # Namen ohne .exe; aus Phase 0.2
    AppScriptVersion            = '<1.0.0>'
    AppScriptDate               = '<YYYY-MM-DD>'
    AppScriptAuthor             = '<Vorname Nachname>'
    RequireAdmin                = $true
    InstallName                 = ''
    InstallTitle                = ''
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters   = $PSBoundParameters                    # oder sanitized Dictionary wenn Secrets
    DeployAppScriptVersion      = '<passend zur ModuleVersion im Scaffold>'
}
```

### 2.3 Fill the Install/Uninstall/Repair hooks

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
    # Shortcuts aufraeumen, Registry-Keys setzen, Update-Service deaktivieren, etc.
}
```

**Pattern for an EXE wrapper:**
```powershell
Start-ADTProcess -FilePath "$($adtSession.DirFiles)\setup.exe" -ArgumentList '/silent /allusers=1 /log="C:\Windows\Logs\Software\install.log"' -SuccessExitCodes @(0, 3010, 1641) -WaitForMsiExec
```

Always pass `-SuccessExitCodes` - otherwise Start-ADTProcess throws on anything != 0.

### 2.4 Extensions module for helper functions

Custom helpers belong in `<pkg>\PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1` - NOT directly in the main script. Reasons: reuse, clean namespaces, the main script stays readable.

```powershell
# PSAppDeployToolkit.Extensions.psm1
function Set-CompanyBranding { ... }
function Disable-AppUpdater    { ... }
Export-ModuleMember -Function Set-CompanyBranding, Disable-AppUpdater
```

The main script loads the extensions automatically (the block `Get-ChildItem ... -match 'PSAppDeployToolkit\..+$'` at the end of `Invoke-AppDeployToolkit.ps1`).

---

## Phase 3: Pre-flight checks

Run everything in this phase. Each failure = DO NOT continue.

### 3.1 Encoding check (UTF-8 with BOM or ASCII-only)

PowerShell 5.1 reads a .ps1 without a BOM as Windows-1252. UTF-8 multibytes (em-dash `—`, arrow `→`, umlauts, typographic quotes, ellipsis `…`) fall apart. In double-quoted strings a misinterpreted em-dash **closes** the string prematurely (UTF-8 `E2 80 94` -> CP1252 `â€"`, last byte = `"`). Parse error. The script NEVER runs. Intune shows `0x80070001`, no local logs.

```powershell
$s = '<pfad-zur-ps1>'
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

### 3.2 Parse check

```powershell
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($s, [ref]$null, [ref]$errs)
if ($errs) { $errs | Select Message,@{N='L';E={$_.Extent.StartLineNumber}} } else { 'PARSE_OK' }
```

IMPORTANT: `Parser::ParseFile` detects UTF-8-without-BOM correctly and often reports `PARSE_OK` even though powershell.exe via the launcher still blows up. The 3.3 test is the REAL gate.

### 3.3 Launcher simulation (acid test)

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

### 3.4 Param block vs. v4 template

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

### 3.5 Leftover v3 cmdlets

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

### 3.6 Top-level statements outside try/catch

Anything that is NOT inside a try/catch and throws = exit 1 = no log. At top level only the following are allowed: attributes, the param block, simple `$var = @{...}`, preference variables, `Set-StrictMode`, `try/catch`.

```powershell
$ast = [System.Management.Automation.Language.Parser]::ParseFile($s, [ref]$null, [ref]$null)
$ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] } |
    ForEach-Object { "L$($_.Extent.StartLineNumber): $($_.GetType().Name)" }
```

Anything that is not an `AssignmentStatementAst` / `PipelineAst` (for Set-StrictMode) / `TryStatementAst` = check it.

---

## Phase 4: Build the .intunewin

### 4.1 Get IntuneWinAppUtil

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

### 4.2 Package

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

### 4.3 Check extractability (offline)

The .intunewin is an AES-encrypted ZIP. Not extractable without Intune, but the outer ZIP has a metadata XML that is accessible unencrypted:

```powershell
Expand-Archive -Path $iw.FullName -DestinationPath "$env:TEMP\iw-inspect" -Force
Get-Content "$env:TEMP\iw-inspect\IntuneWinPackage\Metadata\Detection.xml"
```

The XML must contain `<SetupFile>Invoke-AppDeployToolkit.exe</SetupFile>`. If something else is there: wrong `-s` during packaging.

---

## Phase 5: Intune app configuration

### 5.1 App Information
- Name / Version / Publisher: matches `$adtSession.AppName / AppVersion / AppVendor`
- Description: Markdown-capable, the first paragraph readable standalone (~200 characters are the short preview in the Company Portal)
- Category: choose it semantically correct (Development, Productivity, ...)
- Logo: `<pkg>\Assets\AppIcon.png`, 256x256 PNG transparent

### 5.2 Program
- **Install command**: `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent`
- **Uninstall command**: `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent` (case does not matter, the ValidateSet is case-insensitive)
- **Install behavior**: `System` (default; the SYSTEM context is correct for Win32 apps)
- **Device restart behavior**:
  - `App install may force a device restart` - when the installer can return 1641
  - `Determine behavior based on return codes` - default, falls back to the return-code mapping
- **Allow available uninstall**: Yes (lets the user uninstall via the Company Portal)

### 5.3 Return codes (critical, never omit)

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

### 5.4 Requirements
- **OS architecture**: `x64` when the script has `AppArch='x64'`, otherwise accordingly
- **Minimum OS**: realistic (Win11 22H2, Win10 22H2) - not `1607`, that is leaving it open to legacy
- **Disk space**: when the installer needs a lot - saves time on small disks
- **Physical memory**: only for genuinely memory-hungry installers
- **Additional requirement rules**: Registry / File / Script - for everything that goes beyond the standard requirements (e.g. domain-join check, specific build number)

### 5.5 Detection rules

Three options, ordered by robustness:

1. **Custom detection script** (preferred for complex installs):
   - Contract: `exit 0 + stdout non-empty` = installed; `exit 0 + stdout empty` = not installed; `exit != 0` = detection error, retry
   - Usually: `Enforce script signature check = No` (except in a strictly signed environment)
   - Usually: `Run as 32-bit on 64-bit = No` (otherwise the wrong registry view)

2. **MSI Product Code**: for pure MSI installers that keep their product code stable

3. **File / Registry / Version**: for simple cases - ONE criterion, not several mixed

**Mandatory**: the detection method is **unambiguous** - not a custom script PLUS a file rule; that gives contradictory answers.

### 5.6 Install time required
- The default of 60 min is enough for most installers
- Only when documented >45 min, raise it
- Don't reflexively set 120 min ("more is better" is not true here - Intune then keeps the process alive extremely long)

### 5.7 Assignments
- `Required` for a mandatory rollout to a device or user group
- `Available for enrolled devices` for self-service via the Company Portal
- `Uninstall` as a pseudo-assignment to deliberately remove apps again
- **Filter** to use for dynamic constraints (OS version, device-name regex, AzureAD join type)
- **Delivery Optimization**: enable peer-to-peer for large packages
- **Dependencies / Supersedence**: when the app requires other PSADT packages or replaces previous versions
- **App availability / Deadline / Grace period**: for required apps with a reboot impact

---

## Phase 6: Test sequence

In this order on a DEV VM (not prod).

### 6.1 Direct invoke (smoke test)
```powershell
.\Invoke-AppDeployToolkit.ps1 -DeploymentType Install -DeployMode Silent
```
Runs through = script logic OK.
Does not run through = your code bug, not an Intune problem.

### 6.2 Launcher invoke (acid test)
```powershell
.\Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent
```
Runs through = encoding / param-block sync OK.
Does not run through but 6.1 does = see 3.1 (encoding), 3.4 (params), 3.6 (top-level throws).

### 6.3 SYSTEM context (IME reality)
```cmd
psexec -s -accepteula cmd /c "cd /d <pkg> && Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent"
```
PsExec: https://learn.microsoft.com/en-us/sysinternals/downloads/psexec
Runs through = no dependency on a user session. This test must be green BEFORE upload.

### 6.4 Test-group deploy
A dedicated Intune test group with 1 VM. Observe the deployment:
- `C:\Windows\Logs\Software\*PSAppDeployToolkit_Install.log` must exist + contain `Close-ADTSession` with Exit 0
- `AppWorkload.log` shows `Status: Installed`
- the detection script returns `exit 0 + stdout non-empty`

Only after success: production rollout.

---

## Phase 7: Rollout

### 7.1 Staged rollout
- Run a pilot group (10-50 devices) for 24-48h
- Monitoring: Intune Admin Center -> Apps -> Oracle (example) -> Device install status
- At >5% failure rate: pause the rollout, find the cause

### 7.2 Production
- Expand the target audiences after pilot success
- Review the Company Portal description + support notes
- Known issues into the internal knowledge base

### 7.3 Ongoing
- Subscribe to the GitHub release feed (Releases -> Watch -> Releases only) so you don't miss PSADT updates
- Check with every new package: is the module in the scaffold still up to date (Phase 0.1)

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

# Nur wenn sicher nichts mehr laeuft:
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
12. **No stakeholder intake (Phase 0.2)** - the most common reason for "the installer doesn't do what I want" after 2 weeks.

---

## Appendix C: Test stub pattern

Before the launcher test on a DEV box, when the install action is too big/expensive:

```powershell
$orig = '<pfad-zur-ps1>'
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
Phase 0 - Research + Intake
[ ] 0.1  PSADT version local == Latest (or update)
[ ] 0.2  Intake form complete (App, Installer, Environment, Sec)
[ ] 0.3  Silent install switches + uninstall switches documented

Phase 1 - Scaffold
[ ] 1.1  New-ADTTemplate -Destination ... -Name ... executed
[ ] 1.2  Folder layout complete
[ ] 1.3  Module version pinned in scaffold

Phase 2 - Script customizing
[ ] 2.1  Installer in Files\
[ ] 2.2  $adtSession with all metadata
[ ] 2.3  Install/Uninstall/Repair hooks filled in
[ ] 2.4  Custom helpers in PSAppDeployToolkit.Extensions, not in the main script

Phase 3 - Pre-Flight
[ ] 3.1  Encoding: HasBOM=True OR NonAscii=0
[ ] 3.2  ParseFile PARSE_OK
[ ] 3.3  Launcher simulation green
[ ] 3.4  Param block in sync with v4 template
[ ] 3.5  No v3 cmdlet remnants
[ ] 3.6  No top-level statements that can throw

Phase 4 - Build
[ ] 4.1  IntuneWinAppUtil latest
[ ] 4.2  -c / -s / -o correct, -o NOT inside -c
[ ] 4.3  Inspection: Detection.xml has SetupFile=Invoke-AppDeployToolkit.exe

Phase 5 - Intune config
[ ] 5.1  App Info + Logo
[ ] 5.2  Install/Uninstall command + Install Behavior=System
[ ] 5.3  Return codes complete (incl. 60001+60008=Failed)
[ ] 5.4  Requirements (OS, Arch, Disk, Memory)
[ ] 5.5  Detection method UNAMBIGUOUS
[ ] 5.6  Install time realistic
[ ] 5.7  Assignments + Filter + Delivery Opt

Phase 6 - Test
[ ] 6.1  Direct invoke on DEV
[ ] 6.2  Launcher invoke on DEV
[ ] 6.3  Psexec -s on DEV
[ ] 6.4  Test-group deploy -> PSADT log + Close-ADTSession Exit 0

Phase 7 - Rollout
[ ] 7.1  Pilot (24-48h)
[ ] 7.2  Production staged
[ ] 7.3  GitHub release watch subscribed
```

Only when ALL lines are green: production rollout.

---

## Appendix F: Intune deployment dossier (upload template, to be filled in per app)

Place this template as a full HTML file per app next to the `.intunewin` (`Intune-Dossier.html`). **Exception:** the F.2 description block is **Markdown**, because the Intune app description field supports only Markdown (not HTML). Without a filled-in dossier: **no upload**. The values come from Phase 0.2/0.3.

### F.1 App information

| Intune field | Value | Notes |
|---|---|---|
| **Name** | `<AppName> <Version>` | exactly as visible in the Company Portal; version incl. build if there are updates |
| **Description** | see F.2 (Markdown block) | the first ~200 characters are the short preview in the CP |
| **Publisher** | `<Hersteller>` | from Phase 0.2 (Adobe Inc., Oracle Corporation, ...) |
| **App version** | `<Major.Minor.Build.Rev>` | exact file version |
| **Category** | e.g. Business, Development, Productivity, Communication | for CP navigation |
| **Show this as a featured app in the Company Portal** | Yes/No | Yes only for recommended self-service apps |
| **Information URL** | `<hersteller-produktseite>` | official product homepage |
| **Privacy URL** | `<hersteller-privacy-url>` | often the vendor's `/legal/privacy/` |
| **Developer** | `<Hersteller-Kurzname>` | usually == Publisher |
| **Owner** | `<internes-Team>` | internal service owner (e.g. "Workplace-Services") |
| **Notes** | `PSADT 4.1.8 v<N> - pkg rev <NN> - YYYY-MM-DD` | package metadata for later troubleshooting |
| **Logo** | `<pkg>\Assets\AppIcon.png` | 256x256 PNG transparent |
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

Add the installer-specific codes from Phase 0.3. Every unknown exit code produces `0x80070000+code` in the error display.

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
| Logo | `Assets/AppIcon.png` |
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

2. **`Start-ADTMsiProcess -Action Uninstall -FilePath '{GUID}'` -> exit 60001 (`InvalidFilePathParameterValue`)**: once the SYSTEM loop actually ran, Install was green but Uninstall failed with `FullyQualifiedErrorId : InvalidFilePathParameterValue,Start-ADTMsiProcess` (exit 60001, app stayed installed). **Cause**: in **PSADT 4.1.x** `Start-ADTMsiProcess` split the target into two parameters - `-FilePath` is now validated as a **real .msi file path**, and a **ProductCode GUID must be passed via the dedicated `-ProductCode` parameter**. Older v4.0 patterns (and earlier versions of this skill's own examples) used `-FilePath '{<ProductCode>}'`, which now throws. **Fix**: `Start-ADTMsiProcess -Action Uninstall -ProductCode '{<GUID>}'` (same for `-Action Repair`). **General lesson**: this is exactly the "newer PSADT version changed a command" trap from Phase 2 - verify cmdlet parameters against the **installed** module (`(Get-Command Start-ADTMsiProcess).Parameters.Keys`) instead of trusting a remembered pattern; `-ProductCode` for GUIDs, `-FilePath` for actual files.

---
name: psadt-deploy
description: Use this skill when the user wants to build, package, test, troubleshoot, or deploy a PowerShell App Deployment Toolkit (PSADT) v4.x Intune Win32 app package. Triggers include "PSADT paket bauen", "intune paket fuer <app>", "<app> via intune paketieren", "PSADT v4 deploy", "PSADT troubleshooting", "Invoke-AppDeployToolkit.ps1 debug", "IntuneWinAppUtil", or when working inside a folder that contains Invoke-AppDeployToolkit.ps1 / .exe or a PSAppDeployToolkit module.
---

# PSADT v4.x Deployment Skill

## Summary

This skill guides the complete lifecycle of a **PSADT v4.x Intune Win32 package** - from the first conversation to a tested, upload-ready `.intunewin`. It is intended for **build, packaging, test, troubleshooting, and deployment** (triggers include "PSADT paket bauen", "intune paket fuer <App>", "PSADT v4 deploy", or working in a folder that contains `Invoke-AppDeployToolkit.ps1`).

**Workflow (9 phases):** 1) Intake (8 kill questions, ALWAYS via click options) - 2) Web research (PSADT version + command changes, silent/uninstall/repair of the app, Intune pitfalls) - 3) Scaffold (`New-ADTTemplate`) - 4) Customizing all three deployment types (Install/Uninstall/Repair) - 5) Pre-flight (encoding/parse/acid test) - 6) Packaging (IntuneWinAppUtil) - 7) Dossier + logo - 8) Test - 9) Rollout.

**Binding conventions (details in the block below):**
- ALWAYS ask the user via `AskUserQuestion` (click options), never as free text
- Output `.intunewin` ALWAYS centrally to `paths.outputRoot`/<App>\ - the output root is configured by the user during setup (NO hard-coded default); read it from config via `Get-PsadtConfig`
- Intune dossier ALWAYS `Intune-Dossier.html` (full HTML), language from `language.dossier` (**default German with real umlauts**) - BUT the **app description block** for the Company Portal field is **Markdown** (that field supports only Markdown, not HTML); scripts on the other hand **English/ASCII**
- Author ALWAYS assembled from config (`author.person` + `author.company`, set during setup - no hard-coded default); first script version `0.1`; changelog in the `.NOTES` header is mandatory
- Obtain app logo (PNG, transparent, high resolution) -> `Assets\` + `Output\<App>\`
- Start Menu entries only, NO desktop icons
- Build all three deployment types (Install/Uninstall/Repair) from the start and verify them via acid test

Per-topic depth in the reference guide `references/PSADTv4-Deployment-Guide.md` (appendices A-G).

---

You guide the user through the complete lifecycle of a PSADT v4.x Intune package: intake, research, scaffold, customizing, pre-flight, packaging, Intune upload, test, rollout. Behavior rules:

- **Actively drive the conversation** - do not dump a question list; ask targeted blocker questions, research what can be researched, show the user intermediate results
- **ALWAYS ask questions via `AskUserQuestion` (click options), never as plain free text** - every decision question to the user goes through the `AskUserQuestion` tool with pre-filled, clickable options. Always put the recommended option first and mark it with the suffix "(recommended)". Offer researched defaults as options. The tool automatically adds an "Other" free-text option - so there is no need to build a manual free-text alternative. Plain text is only allowed for intermediate results / status messages, not for questions.
- **Do not assume Adobe/Oracle as default** - the app to be packaged always comes from the user; examples from the guide are illustration
- **Reference**: The complete reference guide is at `references/PSADTv4-Deployment-Guide.md` - point to specific appendices (A-G) there when depth is needed, do NOT dump the whole guide into the conversation

## Conventions (BINDING)

- **Language - split by target:**
  - **Intune dossier (`Intune-Dossier.html`, full HTML) - but the app description block for the Company Portal field is Markdown** (that field supports only Markdown, not HTML). **Language from `language.dossier`, default GERMAN with real umlauts** (ä, ö, ü, ß) - this is end-user text for the Company Portal, where umlauts are correct and desired (do NOT spell out ae/oe/ue). The dossier language is a config value, not a fixed rule.
  - **In the scripts themselves (Invoke-AppDeployToolkit.ps1, Extensions, Detection): EVERYTHING in ENGLISH** - especially all comments. Keep script strings in English too, so that no umlauts/non-ASCII end up in the PS1 (encoding cleanliness, see pre-flight). Umlauts belong ONLY in the dossier HTML, never in the script.
- **Author ALWAYS from config:** compose `AppScriptAuthor` (in `$adtSession`) from `author.person` + `author.company`, which the user sets during setup (`Get-PsadtConfig`). No hard-coded author.
- **Script versioning (`AppScriptVersion` in `$adtSession`):**
  - The first version of a script is ALWAYS **`0.1`** (not 1.0.0).
  - Every substantively justified change increases the version number (small fixes/clarifications -> patch/minor, larger functional changes -> bigger jump). Purely cosmetic edits without functional relevance do not necessarily need to bump.
- **Changelog is mandatory:** Every change to a script is documented in a **changelog in the script header (`.NOTES` block)** - one line per version: `Version (date, author): What was changed`. On every change, update the changelog entry AND `AppScriptVersion` together. Format:
  ```
  Changelog:
  - 0.1 (YYYY-MM-DD, <author.person>): Initial version.
  - 0.2 (YYYY-MM-DD, <author.person>): <what was changed>.
  ```

## Workflow (execute in this order)

### 0. Setup (Phase 0 — run before intake)

Before anything else happens: make sure the skill is configured and the prerequisites are in place.

1. Run `pwsh scripts/Get-PsadtConfig.ps1`. If `Exists` is true and `Missing` is empty, go straight to intake.
2. If the config is missing/incomplete, run the **setup wizard** — ask only for the missing values, ALWAYS via `AskUserQuestion` (click options), recommended option first:
   - **Paths**: `paths.packageRoot`, `paths.outputRoot`, `paths.intuneWinAppUtil` (offer the current values as defaults).
   - **Languages**: `language.script` (EN), `language.dossier` (DE as default — but a config value, not fixed).
   - **Author**: `author.person`, `author.company`.
   - **Intune upload** *(planned for a future version — NOT active in this version)*: mention that it is coming; do NOT ask for tenant/client ID/secret, do NOT set `intune.uploadEnabled`. For now the finished `.intunewin` is uploaded manually in the Admin Center.
3. Persist answers with `scripts/Set-PsadtConfig.ps1 -Updates @{ ... }` (in this version without `-Secret`).
4. Provision prerequisites (never block the user):
   - `pwsh scripts/Get-PsadtModule.ps1` — installs/updates PSAppDeployToolkit.
   - `pwsh scripts/Get-IntuneWinAppUtil.ps1` — downloads/updates the content-prep tool into `tools/`.
5. Re-triggerable at any time via "psadt setup" to change individual values.

### 1. Intake (right at the start, before anything else)

Critical: A PSADT v4 package ALWAYS serves three deployment types — **Install, Uninstall, Repair**. All three must be planned from the start, not only at the end.

Ask the **8 kill questions exclusively via the `AskUserQuestion` tool** (clickable options), NOT as a free-text list. Since the tool allows max. 4 questions per call, bundle them into **two `AskUserQuestion` calls** (4 + 4). Wherever possible, lightly probe what is researchable beforehand (app, latest version, installer type) and offer the findings as pre-selected options - the user then only clicks confirm or correct. Each question gets sensible default options; the recommended one first with the suffix "(recommended)". The tool automatically appends an "Other" free-text option.

The 8 substantive questions that must be covered (spread across the two calls):
1. **App + exact version** - options: detected/latest version (recommended), known previous version(s), from context.
2. **Installer type** - options: MSI, EXE wrapper, MSIX, InstallShield, Squirrel/ZIP/portable, other.
3. **Installer source** - options: available locally (path follows), download + bundle into the package (recommended), download at runtime.
4. **Target audience** - options: Required on devices, Available in Company Portal, both; pull in AAD groups as free text if needed.
5. **Special config** - options: none (recommended default if nothing is known), registry keys, XML/JSON/settings file, license key, service account, branding (multiSelect: true makes sense).
6. **Reboot behavior** - options: never (recommended), recommended (3010), forced (1641).
7. **Uninstall semantics** - options for "what must go": app files only, + registry leftovers, + scheduled tasks/services/firewall, + user data (multiSelect). Plus a separate question/option for what definitely must be KEPT (user data, shared components, neighboring products from the same vendor). Uninstall method (MSI ProductCode / registry UninstallString / custom uninstaller) as a separate question if unclear.
8. **Repair semantics** - options: no repair needed, MSI /fa, config reset to default, complete reinstall (recommended for ZIP/EXE), service restart.

Optionally follow up depending on context via a further `AskUserQuestion` call: co-existence with previous versions, processes-to-close list, language (EN/DE/Multi), architecture (x64/x86/ARM64). Not all 30 questions from guide Phase 0.2 at once - the rest comes situationally, also via click options.

### 2. Web research (parallel, autonomous)

After intake, without asking back, immediately run **three parallel research streams**:

**a) Check PSADT version sync AND command changes:**
```powershell
$local = (Get-Module -ListAvailable -Name PSAppDeployToolkit | Sort-Object Version -Descending | Select-Object -First 1).Version
$rel = Invoke-RestMethod 'https://api.github.com/repos/PSAppDeployToolkit/PSAppDeployToolkit/releases/latest'
"local=$local latest=$($rel.tag_name)"
```
If divergent: inform the user + recommend `Update-Module PSAppDeployToolkit -Force` BEFORE scaffold.

**Mandatory, do NOT just compare the version number:** On a divergent (newer) version ALWAYS check whether
**commands have changed** - new, renamed, deprecated, or with changed parameters. Otherwise you build a
package with outdated syntax that breaks at the launcher acid test or only later in Intune. Sources in this order:
- Release notes of the latest release: `$rel.body` (already loaded above) scanned for "Breaking", "renamed", "deprecated", "removed", "new function"
- Changelog/migration docs: https://psappdeploytoolkit.com/docs (v3->v4 function mapping and version changelogs)
- GitHub releases overview: https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/releases
- When in doubt, verify the actually used cmdlets against the installed module:
  `Get-Command -Module PSAppDeployToolkit -Name Start-ADTProcess,Start-ADTMsiProcess,Show-ADTInstallationWelcome,New-ADTShortcut,Remove-ADTFolder | Select Name,Version`
  and if needed `Get-Help <Cmdlet> -Parameter *` for changed parameters.
Show the finding to the user (which commands are new/changed/deprecated and what that means for the package) BEFORE building.

**b) Silent install / uninstall / repair research on the app** via WebSearch — ALL THREE, not just install:
- Query 1: `"<AppName>" "<Version>" silent install command line`
- Query 2: `"<AppName>" msi transform enterprise deployment`
- Query 3: `"<AppName>" uninstall silent /quiet /qn msiexec`
- Query 4: `"<AppName>" repair reinstall command line` (often `msiexec /fa <ProductCode>` for MSIs; for EXE wrappers: reinstall via the same installer)
- Query 5: `"<AppName>" "uninstall" "registry" "leftover"` — documented leftovers from the community
- Official vendor docs first, then silentinstallhq.com, then community (Reddit r/Intune, PSADT Discourse)

Record per deployment type: switch, expected exit codes, log path, known leftovers.

**c) Known Intune pitfalls:**
- Query: `"<AppName>" intune win32 known issues`
- Query: `"<AppName>" PSADT package github` (in case someone already built a package)

Put the result into the Phase-0.3 table from the guide and show it to the user BEFORE the scaffold is built.

### 3. Scaffold (`New-ADTTemplate`)

Insert values from intake + research. **Do NOT hardcode**, **do not use Adobe/Oracle**.

```powershell
Import-Module PSAppDeployToolkit
# IMPORTANT: In 4.1.x, New-ADTTemplate ONLY accepts -Destination/-Name/-Version (module version)/-Force/-Show/-PassThru.
# It takes NO app metadata (-AppVendor/-AppName/-AppVersion/-AppScriptAuthor ...). Those go AFTER the scaffold
# into the $adtSession hashtable in Invoke-AppDeployToolkit.ps1.
New-ADTTemplate -Destination '<root-from-user-input>' -Name '<AppName from intake>'
```

Then fill the `$adtSession` hashtable in the generated `Invoke-AppDeployToolkit.ps1` - including the binding conventions:
```powershell
AppVendor = '<vendor>'
AppName = '<short product name>'
AppVersion = '<version>'
AppArch = '<x64|x86|ARM64>'
AppLang = 'EN'
AppRevision = '01'
AppSuccessExitCodes = @(0, 1707)
AppRebootExitCodes = @(1641, 3010)
AppScriptVersion = '0.1'                              # first version ALWAYS 0.1, see conventions
AppScriptAuthor = '<author.person>, <author.company>'   # from config (Get-PsadtConfig), set during setup
```
And in the header comment (`.NOTES`) create the changelog: `- 0.1 (YYYY-MM-DD, <author.person>): Initial version.`

Verify right after scaffold:
```powershell
$pkg = '<scaffold path>'
(Import-PowerShellDataFile "$pkg\PSAppDeployToolkit\PSAppDeployToolkit.psd1").ModuleVersion
Select-String "$pkg\Invoke-AppDeployToolkit.ps1" -Pattern 'DeployAppScriptVersion' -List | Select-Object Line
```
Both must match.

### 4. Script customizing — all three deployment types

The user places the installer in `<pkg>\Files\`. Then fill **all three hooks** in `Invoke-AppDeployToolkit.ps1`: `Install-ADTDeployment`, `Uninstall-ADTDeployment`, `Repair-ADTDeployment`. Even if only install is needed today: later user uninstalls via Company Portal only work with a filled uninstall block.

**4a. `Install-ADTDeployment`** — pattern depending on installer type from the research:

- MSI: `Start-ADTMsiProcess -FilePath "$($adtSession.DirFiles)\<installer>.msi" -Transforms "$($adtSession.DirSupportFiles)\<transform>.mst" -ArgumentList '/qn REBOOT=ReallySuppress'`
- EXE wrapper: `Start-ADTProcess -FilePath "$($adtSession.DirFiles)\<setup>.exe" -ArgumentList '<researched silent switches>' -SuccessExitCodes @(0, 3010, 1641)`
- InstallShield with `setup.exe /s /f1"<response>.iss"`: response file in `SupportFiles\`
- Squirrel (`<app>-<ver>-full.nupkg`-based .exe): often `/silent /quiet`

Mandatory before install: `Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CheckDiskSpace -RequiredDiskSpace <MB>` (no-op in silent, active in interactive). Then `Show-ADTInstallationProgress` for the welcome-replacement display.

**Shortcuts - ONLY Start Menu, NEVER desktop:** If the app needs a shortcut, create exclusively a
Start Menu entry for all users (`$envCommonStartMenuPrograms`, e.g.
`New-ADTShortcut -Path "$envCommonStartMenuPrograms\<App>\<App>.lnk" -TargetPath ...`). **No desktop icons**
(`$envCommonDesktop` / `$envUserDesktop`) - that clutters the desktop and is unwanted in the enterprise.
If the installer creates a desktop icon on its own: remove it again specifically in post-install
(`Remove-Item "$envCommonDesktop\<App>.lnk"`). In uninstall, clean up the Start Menu entry as well.

**4b. `Uninstall-ADTDeployment`** — values from intake question 7 (what goes, what stays):

- MSI with known ProductCode: `Start-ADTMsiProcess -Action Uninstall -ProductCode '{<ProductCode>}' -ArgumentList '/qn'` (in PSADT 4.1.x a GUID MUST go to `-ProductCode`; `-FilePath` is validated as a real file path and throws `InvalidFilePathParameterValue` -> exit 60001)
- MSI via DisplayName match (when ProductCode varies): `Remove-ADTApplication -Name '<AppName>' -NameMatch Exact` (not `Contains` - that accidentally removes neighboring products with a name prefix)
- EXE with its own uninstaller: `Start-ADTProcess -FilePath '<uninstallstring-from-registry>' -ArgumentList '<silent uninstall switches>'`
- Squirrel: `Start-ADTProcess -FilePath "$env:LocalAppData\<app>\update.exe" -ArgumentList '--uninstall -s'`

Post-uninstall cleanup (based on intake question 7):
- `Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60` (not `-Silent` - uninstalls should be allowed to kill processes)
- Scheduled tasks: `Get-ScheduledTask -TaskName '<Prefix>_*' | Unregister-ScheduledTask -Confirm:$false`
- Services: `Stop-Service <Name>` + `sc.exe delete <Name>` for services the installer does not clean up itself
- Firewall rules: `Get-NetFirewallRule -DisplayName '<App>*' | Remove-NetFirewallRule`
- Registry leftovers: delete specifically only under the APP-specific key, NEVER under `HKLM\SOFTWARE\<vendor>\` wholesale (other products of the same company suffer)
- Install directory `Remove-Item -Recurse` if the installer does not clean up on its own
- User data (AppData, documents, templates): DEFAULT **keep**, only remove on explicit intake-7 instruction (and then specifically via `Invoke-ADTAllUsersRegistryAction` / `$envProfilesDirectory` iteration per user)

Counter-example to warn about: NEVER do `Remove-Item 'HKLM:\SOFTWARE\<vendor>' -Recurse`. Always the APP sub-key.

**4c. `Repair-ADTDeployment`** — values from intake question 8:

- If intake says "not needed": leave the hook empty or abort with `Write-ADTLogEntry -Message 'Repair not supported - please use Uninstall + Install.'` + `throw`
- MSI: `Start-ADTMsiProcess -Action Repair -ProductCode '{<ProductCode>}' -ArgumentList '/fa /qn'` (`/fa` = all files reinstalled, shortcuts + registry are set again; a GUID goes to `-ProductCode`, NOT `-FilePath` - see Uninstall note above)
- EXE wrapper without a dedicated repair mode: uninstall followed by install in the same hook; preserve user config if possible (backup-restore logic if needed)
- Config-only repair: stop the service, copy the config files back from `SupportFiles\`, start the service - without reinstalling the app (faster, less invasive)

**Custom helpers** ALWAYS in `<pkg>\PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1`, never in the main script.

### 5. Pre-flight checks (mandatory before packaging)

Three green per deployment type, otherwise do not proceed:

```powershell
$s = '<path-to-ps1>'

# Check 1: Encoding
$bytes = [System.IO.File]::ReadAllBytes($s)
$hasBom = $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$text = [System.IO.File]::ReadAllText($s, [System.Text.Encoding]::UTF8)
$nonAscii = ([regex]::Matches($text, '[^\x00-\x7F]')).Count
"HasBOM=$hasBom NonAscii=$nonAscii"   # Requirement: HasBOM=True OR NonAscii=0

# Check 2: Parse
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($s, [ref]$null, [ref]$errs)
if ($errs) { $errs | Select Message,@{N='L';E={$_.Extent.StartLineNumber}} | Format-List } else { 'PARSE_OK' }

# Check 3: Launcher acid test per deployment type (once each)
foreach ($dt in 'Install','Uninstall','Repair') {
    "--- Acid-Test $dt ---"
    Start-Process powershell.exe -ArgumentList `
        '-ExecutionPolicy','Bypass','-NonInteractive','-NoProfile','-NoLogo',`
        '-Command', "try { & '$s' -DeploymentType $dt -DeployMode Silent } catch { throw }; exit `$Global:LASTEXITCODE" `
        -Wait -NoNewWindow -RedirectStandardError "stderr-$dt.log"
    Get-Content "stderr-$dt.log"   # Must show no parse errors
}
```

If one of the three types turns red: that is NOT ok even if install is green. Otherwise the Company Portal user gets 0x80070001 when clicking uninstall.

On an encoding bug (check 1 red or check 3 parse errors): replace em-dashes / smart quotes + UTF-8 BOM:
```powershell
$text = [System.IO.File]::ReadAllText($s, [System.Text.Encoding]::UTF8)
$text = $text -replace [char]0x2014, '-' -replace [char]0x2013, '-' -replace [char]0x2192, '->' `
              -replace [char]0x2018, "'" -replace [char]0x2019, "'" `
              -replace [char]0x201C, '"' -replace [char]0x201D, '"' -replace [char]0x2026, '...'
[System.IO.File]::WriteAllText($s, $text, [System.Text.UTF8Encoding]::new($true))
```

If check 3 is too dangerous because a real install would start: use the test stub from guide appendix C (replace the Install-ADTDeployment call with an `exit 77` stub, launcher test, expects exit 77).

Additionally scan:
```powershell
# v3 leftovers
$v3 = 'Execute-Process','Execute-MSI','Write-Log','Show-InstallationWelcome','Show-InstallationProgress','Show-InstallationPrompt','Get-InstalledApplication','Remove-MSIApplications','Refresh-Desktop','Update-GroupPolicy','Block-AppExecution'
$t = [System.IO.File]::ReadAllText($s)
foreach ($fn in $v3) { $m = [regex]::Matches($t, "\b$fn\b"); if ($m.Count) { "V3_FOUND: $fn ($($m.Count)x)" } }

# Top-level statements that could throw
$ast = [System.Management.Automation.Language.Parser]::ParseFile($s, [ref]$null, [ref]$null)
$ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] } |
    ForEach-Object { "L$($_.Extent.StartLineNumber): $($_.GetType().Name)" }
```

### 5.5 Automated SYSTEM test loop (opt-in, BEFORE packaging)

Validate the package's Install/Uninstall scripts in a real **SYSTEM** context (mirroring the Intune
Management Extension) BEFORE packing, so bugs are caught early. Runs on the package **source folder** (no
`.intunewin` needed yet — fixes to the `.ps1` take effect on the next run, and you pack the validated
scripts afterward). Requires an **elevated** PowerShell session.

Only run when `test.systemTestEnabled` is true OR the user opts in for this package.

**Hands:** `scripts/Invoke-PsadtSystemTest.ps1` runs ONE action as SYSTEM (via the `Invoke-CommandAs`
module, self-healed from PSGallery) and returns
`{ DeploymentType, ExitCode, Success, DetectionState, LogPath, LogTail, ErrorLines, Elevated }`. It fixes
nothing — YOU (the agent) drive the loop and apply fixes between runs.

**Safety (this installs the REAL software on THIS machine as SYSTEM):**
- Before the FIRST install, confirm via `AskUserQuestion` and recommend a VM/snapshot.
- Hard cap `test.maxIterations` (default 5) — never loop forever.
- After a green run, leave the machine in `test.endState` (default `uninstalled`, leftover-clean).
- Keep each iteration's PSADT log in the output folder for an audit trail.

**Loop (max `test.maxIterations`):**
1. **Install:** `pwsh scripts/Invoke-PsadtSystemTest.ps1 -PackagePath <pkg> -DeploymentType Install -DetectionScript <detect>` (elevated). If not `Success`: read `LogTail`/`ErrorLines`, map to a root cause via the Troubleshooting quick-reference + guide Appendix A, fix `Install-ADTDeployment` (or Extensions), re-run.
2. **Uninstall:** run with `-DeploymentType Uninstall`. Verify `DetectionState = not-installed` AND the leftover checks (services, scheduled tasks, app registry key, install dir, firewall rules; neighbour products of the same vendor still present). On failure: fix `Uninstall-ADTDeployment`, re-run.
3. **Reinstall:** run `Install` again; verify installed. On failure: fix, re-run.
4. **Converged** (all three green) → leave the machine per `test.endState`, then proceed to Packaging (Phase 6) with the validated scripts.
5. **Cap reached** without convergence → STOP, present the diagnosis (last error, log tail, what was tried) and hand back to the user. Never loop forever.

### 6. Packaging with IntuneWinAppUtil

**Tool path and version are config-driven** (`paths.intuneWinAppUtil`) and are provisioned and kept current by `scripts/Get-IntuneWinAppUtil.ps1` (the inline download below stays as a manual fallback).

**Output folder convention (BINDING, not somewhere different each time):** ALWAYS place the finished `.intunewin` into
`<paths.outputRoot>\<AppName[-Version]>\` - the output root comes from config (set by the user during setup, no hard-coded path),
with a sub-folder per app underneath (e.g. `<outputRoot>\EclipseJEE\`, `<outputRoot>\RSAT-1.0.0\`, `<outputRoot>\ApacheMaven-3.9.16\`).
NEVER create a separate `_IntuneOutput`/`<App>-IntuneOutput` folder next to the package. The app sub-folder holds,
besides the `.intunewin`, also the detection script and the Intune dossier (1 place per app, everything together).
Important: `-c` (source) is the PACKAGE folder, `-o` (output) is the central output sub-folder - the two are
different trees, so `-o` automatically lies OUTSIDE `-c`.

```powershell
# All paths come from config - nothing hard-coded.
$cfg  = & scripts/Get-PsadtConfig.ps1
$tool = $cfg.Config.paths.intuneWinAppUtil    # provisioned + kept current by Get-IntuneWinAppUtil.ps1 (skill-managed tools/ by default)
if (-not (Test-Path $tool)) {
    # manual fallback if the tool was not provisioned yet (the GitHub release has NO assets - exe lives in the repo tree)
    New-Item (Split-Path $tool -Parent) -ItemType Directory -Force | Out-Null
    $tag = (Invoke-RestMethod 'https://api.github.com/repos/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/latest').tag_name
    Invoke-WebRequest "https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/$tag/IntuneWinAppUtil.exe" -OutFile $tool
}

$src = '<pkgFolder>'                                            # package folder with Invoke-AppDeployToolkit.ps1/.exe
$out = Join-Path $cfg.Config.paths.outputRoot '<AppName[-Version]>'   # CENTRAL, per-app sub-folder (from config)
New-Item $out -ItemType Directory -Force | Out-Null
& $tool -c $src -s 'Invoke-AppDeployToolkit.exe' -o $out -q
# Place the detection script + dossier alongside (dossier ALWAYS as Intune-Dossier.html):
Copy-Item '<pkgFolder>\Detect-*.ps1' $out -Force -ErrorAction SilentlyContinue
Copy-Item '<pkgFolder>\Intune-Dossier.html' $out -Force -ErrorAction SilentlyContinue
```

**Critical**: NEVER choose `-o` INSIDE `-c` - otherwise the old .intunewin lands recursively in the package on rebuild.
The central `Output\` folder lies outside every package folder anyway, which is exactly the reason for the convention.

Verify the .intunewin:
```powershell
$iw = Get-ChildItem "$out\*.intunewin" | Select-Object -First 1
"Size: $([Math]::Round($iw.Length / 1MB, 1)) MB"
Expand-Archive $iw.FullName -DestinationPath "$env:TEMP\iw-check" -Force
Get-Content "$env:TEMP\iw-check\IntuneWinPackage\Metadata\Detection.xml" | Select-String 'SetupFile'
# Must show: <SetupFile>Invoke-AppDeployToolkit.exe</SetupFile>
```

### 7. Intune dossier

Use appendix F from the reference guide as a template: ALWAYS name the file **`Intune-Dossier.html`** (fixed name, NOT `<App>-IntuneDossier.html` or `Intune-App-Metadata.html` - the app name is already in the output sub-folder) and place it in the central `Output\<App>\` folder. The dossier document is **full HTML**, with ONE exception: the **app description block** is **Markdown**, because the Intune app description field for the Company Portal supports only Markdown (no HTML) - see below. Fill all tables (App Info, description (Markdown block), Program, Return Codes incl. 60001/60008=Failed, Requirements, Detection, Dependencies, Supersedence, Assignments). Let the user review, then he/she transfers the values 1:1 into the Intune Admin Center.

The dossier language follows `language.dossier` (default German), and its umlauts stay (real ä, ö, ü, ß), because it is end-user output for the Company Portal.

**Note: direct Graph upload is planned for a future skill version.** For now the user uploads the generated `.intunewin` manually in the Intune Admin Center.

**Obtain the app logo automatically (mandatory):** Search for and download a suitable logo of the app - **PNG, transparent background, high resolution** (guideline >= 512px, more is better; square is best for the Company Portal tile). Place it under `<pkg>\Assets\<App>-Logo.png` AND a copy into `Output\<App>\`. Reference the filename in the logo row of the dossier.
- **Choose a license-clear source:** first the official vendor/project source (e.g. `apache.org/logos/res/<project>/` for Apache projects), otherwise **Wikimedia Commons** (stable URLs, SVG is rendered server-side as a transparent PNG):
  ```powershell
  # Wikimedia: SVG -> transparent PNG at the desired width (here 1024)
  $api = "https://commons.wikimedia.org/w/api.php?action=query&titles=$([uri]::EscapeDataString('File:<Logo>.svg'))&prop=imageinfo&iiprop=url&iiurlwidth=1024&format=json"
  $thumb = ((Invoke-RestMethod $api -Headers @{'User-Agent'='PSADT-pkg/1.0'}).query.pages.PSObject.Properties.Value).imageinfo[0].thumburl
  Invoke-WebRequest $thumb -OutFile '<pkg>\Assets\<App>-Logo.png' -Headers @{'User-Agent'='PSADT-pkg/1.0'}
  ```
  Avoid third-party PNG portals (stickpng, toppng, nicepng ...) - hotlink protection/ads/questionable quality.
- **Verify** (transparency + resolution) and show the user that it is the right logo:
  ```powershell
  Add-Type -AssemblyName System.Drawing
  $i=[System.Drawing.Image]::FromFile('<png>'); "{0}x{1} Alpha={2}" -f $i.Width,$i.Height,[System.Drawing.Image]::IsAlphaPixelFormat($i.PixelFormat); $i.Dispose()
  ```
  Alpha MUST be True (otherwise no transparent background -> look for another file). The logo is uploaded separately in Intune in the **App information tab**, it is NOT part of the `.intunewin` (no repack needed).

**App description ALWAYS in the dossier language with real umlauts (ä, ö, ü, ß)** - this is end-user text in the Company Portal, do NOT spell out ae/oe/ue. (Applies to the dossier/description output; the scripts stay English/ASCII - see conventions.)

**App description ALWAYS formatted as Markdown** - the Intune app description field for the Company Portal supports **only Markdown, NOT HTML**, and renders the Markdown formatted in the Company Portal. NO plain free-text wall. Deliver the description block in the dossier as ready Markdown that the user can paste 1:1 into the description field. Supported feature set (safe to use):
- **bold** and *italic* for emphasis
- bulleted lists (`-`) and numbered lists (`1.`) - ideal for requirements, set variables, what-happens steps
- Links `[Text](https://...)` for vendor/docs pages
- Short paragraphs instead of a block
- Use sparingly: headings and tables (rendering in the Company Portal varies) - prefer a bold line + list

Recommended description structure (end-user output — language.dossier, default German; adapt per app):
```markdown
**<AppName> <Version>** - <one-sentence value>.

**What this deployment does:**
- <install target / path>
- <environment variables / registry / config set>
- <notable side effects>

**Requirements:**
- <e.g. JDK, .NET, prior version>

**On uninstall:**
- <what is removed> / <what is kept>

More info: [Vendor page](https://...)
```

Mandatory return codes that must always be included: `0 Success, 1707 Success, 3010 Soft reboot, 1641 Hard reboot, 1618 Retry, 60001 Failed, 60008 Failed` + installer-specific codes from the research.

### 8. Test sequence (BEFORE production rollout) — all three deployment types

On a DEV VM in this order. After each successful install comes the uninstall test on **the same VM** (not a new VM) - so that uninstall actually has something to clean up.

**Install cycle:**
1. `.\Invoke-AppDeployToolkit.ps1 -DeploymentType Install -DeployMode Silent` (smoke test)
2. `.\Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent` (launcher acid test)
3. SYSTEM context: preferred is `scripts/Invoke-PsadtSystemTest.ps1` (uses the `Invoke-CommandAs` module, returns a structured result; see Phase 5.5 for the automated loop). Fallback: `psexec -s cmd /c "cd /d <pkg> && Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent"` (PsExec: https://learn.microsoft.com/en-us/sysinternals/downloads/psexec)

**Uninstall cycle (on the same VM, app must be installed):**
4. `.\Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent`
5. Verification checks after uninstall:
   - Detection script (see Phase 5 guide) must return `exit 0 + stdout empty` (app = not installed)
   - `Get-Service '<App-Service>' -ErrorAction SilentlyContinue` - empty
   - `Get-ScheduledTask '<App-Prefix>*' -ErrorAction SilentlyContinue` - empty
   - Install directory: gone (or only user-config leftovers if intake-7 wanted it so)
   - Registry under `HKLM:\SOFTWARE\<vendor>\<App>` - gone
   - Firewall rules `Get-NetFirewallRule -DisplayName '<App>*'` - empty
   - IMPORTANT: neighboring products of the same vendor still present (not accidentally deleted too)

**Repair cycle (reinstall the VM again, then repair):**
6. Repeat install (step 1)
7. `.\Invoke-AppDeployToolkit.exe -DeploymentType Repair -DeployMode Silent`
8. Detection must still show = installed afterwards; smoke-test app functionality manually

**Intune test group (after all three cycles are green):**
9. Assign the package as Required → 1 test device → check the PSADT install log + AppWorkload.log
10. Uninstall from the device: assign as "Uninstall" in the Admin Center OR have the user uninstall via Company Portal → check the PSADT uninstall log

Check in every Intune test:
- `C:\Windows\Logs\Software\<AppName>*PSAppDeployToolkit_Install.log` / `*_Uninstall.log` exists
- `Close-ADTSession` with exit 0 in it
- AppWorkload.log shows the matching status (`Installed` / `Uninstalled`)

After a successful test of all three types: pilot group 24-48h, then production staged.

## Troubleshooting quick reference

On user reports, check in this order:

| Symptom | Primary suspect | Verification |
|---|---|---|
| `0x80070001` + no local PSADT logs | Encoding (em-dash in "-string") or top-level throw | Phase 5 checks + appendix A.2 |
| `0x8000EA68` (60008) + PSADT log present but empty after init | Import-Module / Open-ADTSession throws | PSADT log directly readable, stack in appendix A.2 |
| `0x8000EA61` (60001) + stacktrace in the PSADT log | Runtime error in Install-ADTDeployment | Stack shows the line directly |
| App stuck on "Installing" in Company Portal | IME state cache or process hangs | Appendix A.2 cleanup sequence |
| `0x80070002` | Launcher does not find the .ps1 | `-s` during packaging was wrong |
| Detection failed after successful install | Detection script bug (contract violation, 32/64-bit registry) | Manually on target: `.\Detect-*.ps1; $LASTEXITCODE` |
| SYSTEM test: `New-ScheduledJobOption`/`PSScheduledJob` could not be loaded; every step `ExitCode=0 Success=False not-installed` | Running `Invoke-PsadtSystemTest.ps1` under pwsh 7 - PSScheduledJob (used by Invoke-CommandAs) is WinPS-5.1-only, blocked in Core | Re-run under `powershell.exe` 5.1; the harness now self-re-execs to 5.1 (Appendix G 2026-06-05 #1) |
| `60001` (`InvalidFilePathParameterValue,Start-ADTMsiProcess`) on Uninstall/Repair | ProductCode GUID passed to `-FilePath` instead of `-ProductCode` (PSADT 4.1.x) | Use `-ProductCode '{<GUID>}'`; verify `(Get-Command Start-ADTMsiProcess).Parameters.Keys` (Appendix G 2026-06-05 #2) |

HRESULT conversion: Intune shows unknown positive exit codes as `0x80070000 + code`. So `0x80070001` = exit 1 = script did not run at all. Always recompute, don't be misled by the "ERROR_INVALID_FUNCTION" text.

Check logs in this order:
1. `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppWorkload.log` (what IME actually did + exit code)
2. `C:\Windows\Logs\Software\<AppName>*PSAppDeployToolkit_Install.log` (PSADT session, if init was OK)
3. `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log` (IME service state)

## Anti-patterns (never do)

- v3 cmdlet names (`Execute-Process`, `Write-Log`, `Show-InstallationWelcome`, ...)
- Em-dash/smart quote in double-quoted strings
- Saving UTF-8 without BOM when non-ASCII is present
- Top-level code outside try/catch
- `-o` inside `-c` for IntuneWinAppUtil
- Not mapping return codes 60001/60008 as Failed
- Assuming "runs locally = runs in Intune" - the launcher acid test is mandatory
- Mixed detection (custom script + file rule in parallel)
- Putting Extensions functions into the main script instead of the Extensions module
- Formatting the Intune app description field with HTML - that field supports ONLY Markdown (the dossier document is HTML, but the description block pasted into the Intune field must be Markdown)
- Reflexively setting install time to 120 min - 60 min is almost always right
- Triggering fallback delete actions on the first negative async response (services need 30-60s after msiexec, build a retry loop)
- Creating desktop icons (or leaving ones created by the installer) - Start Menu entries only, keep the desktop clean
- Recognizing a newer PSADT version only by its number and adopting it blindly - always check the release notes/changelog for changed/deprecated commands

## Reference lookup

For depth on every topic: `references/PSADTv4-Deployment-Guide.md`
- Phase 0.2: Complete intake question list
- Phase 0.3: Web research pattern
- Phase 3.1: Encoding fix details
- Phase 5: Intune config fields
- Appendix A: Error codes + root causes
- Appendix B: Anti-pattern list
- Appendix C: Test stub patterns
- Appendix D: All resource URLs
- Appendix E: Final deploy checklist
- Appendix F: Complete Intune upload dossier template (all fields, all tabs)
- Appendix G: Lessons from the Oracle XE project

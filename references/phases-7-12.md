# Phases 7-12: packaging, upload, rollout

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Contents

- [7.1 Get IntuneWinAppUtil](#71-get-intunewinapputil)
- [7.2 Package](#72-package)
- [7.3 Check extractability (offline)](#73-check-extractability-offline)
- [8.1 App Information](#81-app-information)
- [8.2 Program](#82-program)
- [8.3 Return codes (critical, never omit)](#83-return-codes-critical-never-omit)
- [8.4 Requirements](#84-requirements)
- [8.5 Detection rules](#85-detection-rules)
- [8.6 Install time required](#86-install-time-required)
- [8.7 Assignments](#87-assignments)
- [11.1 Direct invoke (smoke test)](#111-direct-invoke-smoke-test)
- [11.2 Launcher invoke (acid test)](#112-launcher-invoke-acid-test)
- [11.3 SYSTEM context (IME reality)](#113-system-context-ime-reality)
- [11.4 Test-group deploy](#114-test-group-deploy)
- [12.1 Staged rollout](#121-staged-rollout)
- [12.2 Production](#122-production)
- [12.3 Ongoing](#123-ongoing)

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

Since 0.21.0 this is ONE command, and it is the only supported route:

```powershell
pwsh scripts/Invoke-PsadtPackage.ps1 -PackagePath '<package folder>'
```

It reads the identity from `psadt-package.json`, packs with `-o` pointing at a private temp folder,
verifies the archive, and lands the result as
`<paths.outputRoot>\<Vendor>_<App>_<Version>_<Arch>\<same stem>.intunewin` with the detection script and
the logo beside it, recording `artifacts.*` + `results.package` in the manifest.

**Why the name matters.** IntuneWinAppUtil names its output after `-s`, which is always
`Invoke-AppDeployToolkit.exe` - so before 0.21.0 every app produced
`Invoke-AppDeployToolkit.intunewin`. That name reached Intune as `win32LobApp.fileName`, and every
concurrent upload collided in the same `%TEMP%\iwup-Invoke-AppDeployToolkit` working folder. Renaming is
safe: the upload reads `setupFilePath` from the archive's INNER `Detection.xml`; the outer file name only
feeds `fileName` and that temp folder.

The raw tool call below is documented for understanding and for the rare manual case - not as the
workflow:

```powershell
$src = '<package folder>'
$setupFile = 'Invoke-AppDeployToolkit.exe'         # ALWAYS the .exe, NOT the .ps1
$out = '<output folder OUTSIDE $src>'               # NOT inside src!
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

Result plausibility (after `Invoke-PsadtPackage.ps1` take the path from the manifest -
`artifacts.intunewin` - instead of guessing with a wildcard; several `.intunewin` files can legitimately
sit in one folder):
```powershell
$iw = Get-Item ((Get-Content "$src\psadt-package.json" -Raw | ConvertFrom-Json).artifacts.intunewin)
# manual fallback only, when there is no manifest yet:
# $iw = Get-ChildItem "$out\*.intunewin" | Select-Object -First 1
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

## Phase 9: Direct Graph upload (opt-in)

Mechanics and the hard-won Graph lessons: Appendix H. Permissions: `references/app-registration.md`.

```powershell
# ALWAYS dry-run first (read-only), show the summary, confirm, only then -Execute:
pwsh scripts/Invoke-IntuneWin32Upload.ps1 -IntuneWinPath '<artifacts.intunewin>' -ManifestPath '<pkg>\psadt-package.json'
```

`-ManifestPath` supplies DisplayName / Publisher / AppVersion / Architecture, so the app in Intune carries
the same identity as the artifact and the dossier; anything passed explicitly still wins. After a
successful `-Execute` the app id, content version, portal URL and tenant land in `results.upload`. Check
`Capabilities.Upload` first (`Test-PsadtIntuneAccess.ps1`) instead of discovering a missing role from a 403
mid-upload.

## Phase 10: Group assignment (opt-in)

Config, naming rules and the permission model: Appendix M. Only runs when the user chose it at Gate 2 AND
`intune.groups.enabled` is set. Needs BOTH group roles (`Capabilities.Groups`), which
`Invoke-IntuneAppAssignment.ps1` asserts before it creates anything. Dry-run first, like every write.

---

## Phase 11: Test sequence

> **Scope, since 0.27.0:** the local loop (11.1-11.3) belongs to **Phase 6**, which runs Install,
> detection, Uninstall, detection, Reinstall and Repair as SYSTEM in a throwaway Sandbox and whose
> verdict is the gate that allowed the upload at all. Phase 11 is about the **delivery path** - what
> Phase 6 cannot see - and that is 11.4. Sections 11.1-11.3 are kept below as the manual fallback for a
> machine where the Sandbox route is not available and you are driving the loop by hand; they are not a
> second round of testing to perform after Phase 6 has passed.

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
- `C:\Windows\Logs\Software\<Vendor>_<App>_<Version>_<Arch>_Install_<yyyyMMdd-HHmmss>.log` (0.21.0+; a
  pre-0.21 package still writes `*PSAppDeployToolkit_Install.log` and APPENDS to it) must exist and contain
  `Close-ADTSession` with Exit 0
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

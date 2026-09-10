# Appendix P: Windows-feature packages (optional features + capabilities, opt-in)

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Contents

- [P.1 Model](#p1-model)
- [P.2 Phase-2 research (replaces the silent-switch research)](#p2-phase-2-research-replaces-the-silent-switch-research)
- [P.3 Cmdlet + state reference](#p3-cmdlet--state-reference)
- [P.4 Generate the package (one call, in-process)](#p4-generate-the-package-one-call-in-process)
- [P.5 Extensions helpers](#p5-extensions-helpers)
- [P.6 Hooks + reboot](#p6-hooks--reboot)
- [P.7 Detection + Intune wiring](#p7-detection--intune-wiring)
- [P.8 Content source (bundled vs Windows Update)](#p8-content-source-bundled-vs-windows-update)
- [P.9 Dossier additions](#p9-dossier-additions)
- [P.10 Anti-patterns](#p10-anti-patterns)

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

---

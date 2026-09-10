# Appendix I: WinGet packaging (opt-in, never the default)

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Contents

- [I.1 Package discovery (replaces the Phase 1.3 silent-switch research)](#i1-package-discovery-replaces-the-phase-13-silent-switch-research)
- [I.2 Scaffold: provision the extension module into the package](#i2-scaffold-provision-the-extension-module-into-the-package)
- [I.3 Hook patterns](#i3-hook-patterns)
- [I.4 Pre-flight (in addition to 3.1–3.6)](#i4-pre-flight-in-addition-to-3136)
- [I.5 Detection (registry/file only — the module is NOT on the device at detection time)](#i5-detection-registryfile-only--the-module-is-not-on-the-device-at-detection-time)
- [I.6 Dossier additions for WinGet](#i6-dossier-additions-for-winget)
- [I.7 WinGet anti-patterns](#i7-winget-anti-patterns)

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

# Appendix A: Error reference

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Contents

- [A.1 Intune HRESULT mapping](#a1-intune-hresult-mapping)
- [A.2 Typical root causes by symptom](#a2-typical-root-causes-by-symptom)
- [A.3 Log locations](#a3-log-locations)
- [A.4 Exit-code catalogue (cause -> reaction)](#a4-exit-code-catalogue-cause---reaction)

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
| `C:\Windows\Logs\Software\<Vendor>_<App>_<Version>_<Arch>_Install_<timestamp>.log` | PSADT session, ONE file per run (0.21.0+). Pre-0.21: `<AppName>*PSAppDeployToolkit_Install.log`, appended across runs |
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

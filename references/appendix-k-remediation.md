# Appendix K: Script-only remediation / fix packages (ESP-safe)

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Contents

- [K.1 The pattern](#k1-the-pattern)
- [K.2 64-bit relaunch guard (top of the bundled script)](#k2-64-bit-relaunch-guard-top-of-the-bundled-script)
- [K.3 Extensions helper (Install + Repair both call it)](#k3-extensions-helper-install--repair-both-call-it)
- [K.4 Hooks](#k4-hooks)
- [K.5 Detection (script rule, run as System, 64-bit)](#k5-detection-script-rule-run-as-system-64-bit)
- [K.6 Intune + ESP wiring](#k6-intune--esp-wiring)
- [K.7 Exit codes + detection - the honest model (READ THIS)](#k7-exit-codes--detection---the-honest-model-read-this)

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

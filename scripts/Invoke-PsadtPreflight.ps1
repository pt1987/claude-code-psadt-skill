<#
.SYNOPSIS
    Pre-flight verifier for a scaffolded PSADT v4 package - the Phase 5 Reviewer gate as ONE deterministic check.

.DESCRIPTION
    Read-only. Runs the binding pre-flight checks over a package folder and returns a structured GREEN/RED verdict
    instead of the agent re-implementing the checks by hand each time:

      1. Encoding   - each .ps1/.psm1 is 7-bit ASCII OR carries a UTF-8 BOM (non-ASCII WITHOUT a BOM = FAIL).
      2. Parse      - AST ParseFile succeeds (no syntax errors).
      3. v3-cmdlets - none of the PSADT v3 legacy names appear in the LAUNCHER or the Extensions module. Bundled
                      standalone scripts under Files\ are scanned for encoding + parse ONLY - they legitimately
                      define their own helpers (e.g. a private Write-Log), which is the known false positive.
      4. TopLevel   - the launcher has no unexpected executable statement at script top level (outside param /
                      functions / the template's preference-sets + Set-StrictMode + the init/invocation try-blocks).
                      WARN only (informational) - the real RED signals are encoding + parse.
      5. Structure  - Install/Uninstall/Repair-ADTDeployment are all defined; every Extensions helper that is
                      defined is actually called by the launcher (else WARN).
      6. ProductCode- no `Start-ADTMsiProcess -FilePath '{GUID}'` (a GUID belongs on -ProductCode; a GUID on
                      -FilePath throws InvalidFilePathParameterValue -> 60001). Checked in all hooks.
      7. Detection  - any Detect*.ps1 in the package: the "not installed" path should be `exit 0` + empty stdout
                      (Intune reads a non-zero exit as a detection error/retry, not "absent"). Non-zero exit = WARN.
      8. Manifest   - psadt-package.json exists and its identity is complete (app.vendor/name/version/arch,
                      package.type). FAIL: the artifact name is derived from that identity, so a package
                      that cannot say what it is cannot be packed, reported on or uploaded consistently.
      9. LogName    - the launcher sets a per-run LogName. WARN only: a pre-0.21 scaffold works, it just
                      appends every run of every version into one PSADT log.
     10. DriverTrust- ONLY when the package ships an .inf under Files\ (any package type - a vendor
                      installer staging a driver is the case nobody declares). FAIL on an unsigned driver,
                      and on a vendor-signed one whose signer certificate has no owner in the manifest
                      (driverTrust.owner) - the PnP prompt would block the silent install. WARN for a
                      vendor-signed KERNEL driver: TrustedPublisher does not satisfy Code Integrity.
                      Guide Appendix Q.

    GREEN = no FAIL checks. WARN does not flip the verdict. Works under Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER PackagePath
    The scaffolded package folder (the one containing Invoke-AppDeployToolkit.ps1).

.PARAMETER SkillRoot
    Config home override; default = the resolved config home.

.OUTPUTS
    PSCustomObject: Overall('GREEN'|'RED'), Checks(@{Name,Status,Detail,File}[]), Files(string[]), PackagePath
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $PackagePath)) { throw "PackagePath not found: $PackagePath" }
# Normalize to an absolute provider path before anything reads a file. The checks below use .NET file
# APIs, and .NET does NOT follow PowerShell's current location - so `-PackagePath .` from a session whose
# location is elsewhere made ReadAllBytes look beside the SHELL's directory and report a missing
# launcher for a package that is perfectly fine. Measured 2026-09-14.
$PackagePath = (Resolve-Path -LiteralPath $PackagePath).ProviderPath.TrimEnd('\')
$launcher = Join-Path $PackagePath 'Invoke-AppDeployToolkit.ps1'
if (-not (Test-Path -LiteralPath $launcher)) { throw "Not a PSADT package (no Invoke-AppDeployToolkit.ps1): $PackagePath" }

$checks = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$Name, [string]$Status, [string]$Detail, [string]$File) {
    $checks.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; File = $File })
}
function Get-Ast([string]$Path) {
    $t = $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$t, [ref]$e)
    [pscustomobject]@{ Ast = $ast; Errors = $e }
}

# --- Files in scope -------------------------------------------------------------------------------
$extDir   = Join-Path $PackagePath 'PSAppDeployToolkit.Extensions'
$extFiles = @(Get-ChildItem -Path $extDir -Filter '*.psm1' -ErrorAction SilentlyContinue | ForEach-Object FullName)
$filesDir = Join-Path $PackagePath 'Files'
$bundled  = @(Get-ChildItem -Path $filesDir -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object FullName)

$psadtFiles = @($launcher) + $extFiles      # PSADT-authored: full check incl. the v3 scan
$allPsFiles = $psadtFiles + $bundled        # everything: encoding + parse

# --- 1 + 2: encoding + parse (all .ps1/.psm1) -----------------------------------------------------
foreach ($f in $allPsFiles) {
    $leaf  = Split-Path $f -Leaf
    $bytes = [System.IO.File]::ReadAllBytes($f)
    $bom   = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $na = 0; $start = if ($bom) { 3 } else { 0 }
    for ($i = $start; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { $na++ } }
    if ($na -eq 0) { Add-Check 'Encoding' 'PASS' 'ASCII-clean' $leaf }
    elseif ($bom)  { Add-Check 'Encoding' 'PASS' "$na non-ASCII byte(s), UTF-8 BOM present" $leaf }
    else           { Add-Check 'Encoding' 'FAIL' "$na non-ASCII byte(s) and NO UTF-8 BOM (add a BOM or make it 7-bit ASCII)" $leaf }

    $p = Get-Ast $f
    if ($p.Errors -and $p.Errors.Count) { Add-Check 'Parse' 'FAIL' "$($p.Errors.Count) syntax error(s); first: $($p.Errors[0].Message)" $leaf }
    else { Add-Check 'Parse' 'PASS' 'PARSE_OK' $leaf }
}

# --- 3: v3 cmdlet scan (launcher + Extensions only) -----------------------------------------------
$v3 = @(
    'Execute-Process','Execute-MSI','Execute-ProcessAsUser','Execute-ServiceStartMode',
    'Show-InstallationWelcome','Show-InstallationProgress','Show-InstallationPrompt','Show-InstallationRestartPrompt','Show-DialogBox',
    'Refresh-Desktop','Update-Desktop','Refresh-SessionEnvironmentVariables','Block-AppExecution',
    'Copy-File','Remove-File','New-Folder','Remove-Folder',
    'Set-RegistryKey','Remove-RegistryKey','Get-RegistryKey',
    'Write-Log','Get-InstalledApplication','Remove-MSIApplications','Set-ActiveSetup','Get-LoggedOnUser','Test-Battery'
)
foreach ($f in $psadtFiles) {
    $leaf = Split-Path $f -Leaf
    $txt  = Get-Content $f -Raw
    $hits = @($v3 | Where-Object { $txt -match "(?<![\w-])$([regex]::Escape($_))(?![\w-])" })
    if ($hits.Count) { Add-Check 'v3-cmdlets' 'FAIL' "v3 legacy name(s): $($hits -join ', ')" $leaf }
    else { Add-Check 'v3-cmdlets' 'PASS' 'no v3 names' $leaf }
}

# --- 4 + 5 + 6: structure on the launcher AST -----------------------------------------------------
$lp = Get-Ast $launcher
if ($lp.Errors -and $lp.Errors.Count) {
    Add-Check 'Structure' 'FAIL' 'launcher does not parse - cannot inspect structure' 'Invoke-AppDeployToolkit.ps1'
}
else {
    $last      = $lp.Ast
    $funcNames = @($last.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)

    foreach ($hook in 'Install-ADTDeployment', 'Uninstall-ADTDeployment', 'Repair-ADTDeployment') {
        if ($funcNames -contains $hook) { Add-Check 'Structure' 'PASS' "$hook defined" 'Invoke-AppDeployToolkit.ps1' }
        else { Add-Check 'Structure' 'FAIL' "$hook MISSING (Company-Portal $($hook.Split('-')[0]) would fail)" 'Invoke-AppDeployToolkit.ps1' }
    }

    # Extension helpers defined-but-not-called
    $calls = @($last.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    foreach ($ef in $extFiles) {
        $ep = Get-Ast $ef
        if ($ep.Errors -and $ep.Errors.Count) { continue }
        $efuncs = @($ep.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name | Where-Object { $_ -ne 'New-ADTExampleFunction' })
        foreach ($fn in $efuncs) {
            if ($calls -contains $fn) { Add-Check 'Structure' 'PASS' "extension helper $fn is called" (Split-Path $ef -Leaf) }
            else { Add-Check 'Structure' 'WARN' "extension helper $fn is defined but never called by the launcher" (Split-Path $ef -Leaf) }
        }
    }

    # 6: GUID -> -FilePath anti-pattern on Start-ADTMsiProcess
    $guidRe  = '^\{?[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}?$'
    $badGuid = $false
    foreach ($c in $last.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        if ($c.GetCommandName() -ne 'Start-ADTMsiProcess') { continue }
        $els = $c.CommandElements
        for ($i = 0; $i -lt $els.Count; $i++) {
            $el = $els[$i]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -ieq 'FilePath') {
                $val = if ($el.Argument) { $el.Argument.Extent.Text } elseif (($i + 1) -lt $els.Count) { $els[$i + 1].Extent.Text } else { $null }
                if ($val) {
                    $v = $val.Trim('"', "'")
                    if ($v -match $guidRe) { $badGuid = $true; Add-Check 'ProductCode' 'FAIL' "Start-ADTMsiProcess -FilePath '$v' is a GUID -> use -ProductCode (a GUID on -FilePath throws 60001)" 'Invoke-AppDeployToolkit.ps1' }
                }
            }
        }
    }
    if (-not $badGuid) { Add-Check 'ProductCode' 'PASS' 'no GUID passed to -FilePath' 'Invoke-AppDeployToolkit.ps1' }

    # 6b: a vendor uninstaller launched with /S alone, when it is the NSIS-style kind that relaunches
    # itself from %TEMP% and returns immediately. The launcher then waits on a process that has already
    # exited, sees exit 0, and reports a completed uninstall that deleted nothing - the single most
    # expensive failure shape this skill knows, because it is invisible in every log and only a
    # file-existence assertion catches it. Measured 2026-09-16 on Firefox 156.0: helper.exe /S returned
    # in 116 ms with exit 0 and the whole installation still on disk; one full VM run to see it, another
    # to explain it. The engine catalog has carried the fix for this since it was written
    # (references/switch-catalog/engine-defaults.json, nsis: "_?=<installdir> makes it synchronous").
    # Deliberately engine-agnostic: it keys off the CALL SHAPE, so it fires for a wrapper MSI whose inner
    # engine was never classified - which is exactly the case that got past everything else.
    # Two remedies are accepted, because only one of them works everywhere. "_?=<installdir>" is the
    # documented NSIS switch and makes the uninstaller run in place - but Mozilla's customised build
    # ignores it (verified in the same session: still ~1.7 s, files still present). What always works is
    # refusing to return until the app is actually gone. A hook that verifies absence and throws is
    # therefore just as correct as one that passes _?=, and must not be failed for it.
    $verifiesAbsence = {
        param($fnAst)
        $hasTest = @($fnAst.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -in @('Test-Path', 'Get-Item', 'Get-ChildItem')
                }, $true)).Count -gt 0
        $hasThrow = @($fnAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst] }, $true)).Count -gt 0
        $hasTest -and $hasThrow
    }

    # Scan the launcher AND the Extensions module. The skill's own convention puts custom helpers in
    # PSAppDeployToolkit.Extensions.psm1, so the real uninstall call almost never sits in the launcher -
    # a launcher-only scan would miss the exact shape this check exists for. Every function is scanned,
    # not just the uninstall hooks: an Install hook that removes a legacy version hits the same trap.
    $asyncScanTargets = @(, @('Invoke-AppDeployToolkit.ps1', $last))
    foreach ($ef in $extFiles) {
        $ep = Get-Ast $ef
        if ($ep.Errors -and $ep.Errors.Count) { continue }
        $asyncScanTargets += , @((Split-Path $ef -Leaf), $ep.Ast)
    }

    # The rule is about the CALL, not the file name: -FilePath is almost always a variable resolved at
    # run time ($helper, from the ARP UninstallString), so matching "helper.exe" statically finds
    # nothing - verified against the real Firefox package, where the name never appears as a literal.
    # What IS decidable: an uninstall that runs a raw vendor EXE through Start-ADTProcess and then
    # trusts its exit code. msiexec is exempt - it returns synchronously and its exit code means
    # something - which keeps this off the overwhelming majority of packages that use Start-ADTMsiProcess.
    $asyncUninst = @()
    foreach ($target in $asyncScanTargets) {
      $srcName = $target[0]
      foreach ($fn in $target[1].FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        # UNINSTALL paths only - the launcher's uninstall hook and the extension helpers it delegates
        # to, which is where the convention puts them. Repair is deliberately excluded: for most
        # packages a repair means re-running the INSTALLER (7-Zip, Notepad++ and PyCharm all do exactly
        # that with /S), and demanding "verify the app is gone" there is the opposite of correct.
        if ($fn.Name -notmatch '(?i)(^Uninstall-ADTDeployment$|uninstall)') { continue }
        foreach ($c in $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            if ($c.GetCommandName() -ne 'Start-ADTProcess') { continue }
            $els = $c.CommandElements
            $args = ''
            for ($i = 0; $i -lt $els.Count; $i++) {
                $el = $els[$i]
                if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                if ($el.ParameterName -ieq 'ArgumentList') {
                    $args = if ($el.Argument) { $el.Argument.Extent.Text } elseif (($i + 1) -lt $els.Count) { $els[$i + 1].Extent.Text } else { '' }
                }
            }
            if ($args -match '_\?=') { continue }
            if (& $verifiesAbsence $fn) { continue }
            $asyncUninst += "$srcName/$($fn.Name): $($c.Extent.Text.Split("`n")[0].Trim())"
        }
      }
    }
    if ($asyncUninst.Count -gt 0) {
        # WARN, not FAIL: absence is genuinely PROVEN one phase later, by the sandbox run's
        # -PathsAbsentAfterUninstall assertion, and a package that passed that gate is correct even
        # with a bare exit-code check. Failing it here would turn working, gate-verified packages red
        # and buy nothing. The warning exists to be read BEFORE the first VM run, which is the moment
        # it is worth minutes.
        Add-Check 'AsyncUninstall' 'WARN' ("the uninstall runs a vendor EXE through Start-ADTProcess and trusts its exit code. The NSIS-style uninstaller family relaunches itself from %TEMP% and returns instantly: measured on Firefox 156.0, helper.exe /S came back in 116 ms with exit 0 and the entire installation still on disk - invisible in every log, two VM runs to find. Either pass '_?=<installdir>', or wait for the binary to disappear and throw if it does not. At minimum, assert it: -PathsAbsentAfterUninstall on the Phase 6 run. " + (($asyncUninst | Select-Object -First 2) -join ' | ')) 'Invoke-AppDeployToolkit.ps1'
    }
    else { Add-Check 'AsyncUninstall' 'PASS' 'uninstall verifies removal, or does not shell out to a vendor uninstaller' 'Invoke-AppDeployToolkit.ps1' }

    # 4: top-level statements (heuristic, WARN-only). Allow the template's own top-level content.
    $suspect = @()
    if ($last.EndBlock -and $last.EndBlock.Statements) {
        foreach ($st in $last.EndBlock.Statements) {
            if ($st -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
            if ($st -is [System.Management.Automation.Language.TryStatementAst])       { continue }
            if ($st -is [System.Management.Automation.Language.AssignmentStatementAst]) { continue }   # $ErrorActionPreference / $adtSession / ...
            # allow Set-StrictMode (the only top-level command the template emits)
            if ($st -is [System.Management.Automation.Language.PipelineAst]) {
                $first = $st.PipelineElements | Select-Object -First 1
                if ($first -is [System.Management.Automation.Language.CommandAst] -and $first.GetCommandName() -eq 'Set-StrictMode') { continue }
            }
            $suspect += $st.Extent.Text.Split("`n")[0].Trim()
        }
    }
    if ($suspect.Count -gt 0) { Add-Check 'TopLevel' 'WARN' "$($suspect.Count) unexpected top-level statement(s) - review: $((($suspect | Select-Object -First 3) -join ' | '))" 'Invoke-AppDeployToolkit.ps1' }
    else { Add-Check 'TopLevel' 'PASS' 'no unexpected top-level statements' 'Invoke-AppDeployToolkit.ps1' }
}

# --- 7: detection script exit-code contract (WARN-only) -------------------------------------------
$detectFiles = @(Get-ChildItem -Path $PackagePath -Filter 'Detect*.ps1' -ErrorAction SilentlyContinue | ForEach-Object FullName)
foreach ($df in $detectFiles) {
    $leaf = Split-Path $df -Leaf
    $dtxt = Get-Content $df -Raw
    if ($dtxt -match '(?m)^\s*exit\s+[1-9]') {
        Add-Check 'Detection' 'WARN' 'non-zero exit in detection script - the "not installed" path should be exit 0 + empty stdout (Intune reads a non-zero exit as a detection error/retry, not "absent")' $leaf
    }
    else {
        Add-Check 'Detection' 'PASS' 'exit-code contract OK (exit 0 paths only)' $leaf
    }
}

# --- 8: manifest (the package's own identity) -----------------------------------------------------
# A package that cannot say what it is cannot be packed (the artifact name is derived from the identity),
# cannot be reported on and cannot be uploaded consistently. So this is a hard gate, not advice.
$mf = & (Join-Path $PSScriptRoot 'Get-PsadtPackageManifest.ps1') -PackagePath $PackagePath
if (-not $mf.Exists) {
    Add-Check 'Manifest' 'FAIL' 'no psadt-package.json - run a generator, or write the identity with Set-PsadtPackageManifest.ps1' 'psadt-package.json'
} elseif ($mf.Error) {
    Add-Check 'Manifest' 'FAIL' $mf.Error 'psadt-package.json'
} elseif ($mf.Missing) {
    Add-Check 'Manifest' 'FAIL' "incomplete identity: $($mf.Missing -join ', ')" 'psadt-package.json'
} else {
    Add-Check 'Manifest' 'PASS' "identity complete, artifact stem '$($mf.Stem)'" 'psadt-package.json'
}

# --- 8b: the manifest's switches must match what the launcher actually runs -----------------------
# rule:manifest-is-truth says the manifest IS the truth for a package, and the verified-switch store
# takes it at its word: Set-PsadtVerifiedSwitch.ps1 records research.switches.installArgs as the switch
# a GREEN gate proved. A generator writes that field at SCAFFOLD time, so any hand-patched launcher
# silently makes both the manifest and the store describe a package that was never tested.
# Measured 2026-09-20, twice in one run of eleven packages:
#   Thunderbird ESR  manifest '/S'   launcher '/S /INI=<SupportFiles>\thunderbird-install.ini'
#   WinSCP           manifest without /MERGETASKS, launcher with it
# The Thunderbird entry is the instructive one: '/S' installs WITHOUT the configuration file, so the
# store would have served a switch that leaves the self-updater on. A manifest that LIES is worse than
# one that is missing, and pre-flight already FAILs on a missing one - so this fails too.
if ($mf.Exists -and -not $mf.Error -and $mf.Manifest.research -and $mf.Manifest.research.switches) {
    $declared = [string]$mf.Manifest.research.switches.installArgs
    if (-not [string]::IsNullOrWhiteSpace($declared)) {
        # Only the Install hook: Uninstall and Repair legitimately differ.
        # $launcherText is not assigned until section 9, so read it here.
        $launcherSrc = Get-Content $launcher -Raw
        $installBody = ''
        if ($launcherSrc -match '(?s)function\s+Install-ADTDeployment(.*?)function\s+Uninstall-ADTDeployment') {
            $installBody = $Matches[1]
        }
        $actual = $null
        $isMsi  = $installBody -match 'Start-ADTMsiProcess'
        if ($isMsi) {
            # An MSI records "/qn /norestart <additional>"; only the additional half is the launcher's.
            if ($installBody -match "-AdditionalArgumentList\s+(?:'([^']*)'|`"([^`"]*)`")") {
                $actual = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
            }
            else { $actual = '' }
            $declared = ($declared -replace '^\s*/qn\s+/norestart\s*', '')
        }
        elseif ($installBody -match "-ArgumentList\s+(?:'([^']*)'|`"([^`"]*)`")") {
            $actual = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        }

        if ($null -eq $actual) {
            Add-Check 'SwitchSync' 'WARN' 'could not read the install arguments out of the launcher, so the manifest could not be checked against it - verify by hand that research.switches.installArgs matches' 'psadt-package.json'
        }
        else {
            # The launcher builds run-time paths the manifest records as placeholders.
            $norm = {
                param([string]$s)
                $s = $s -replace '\$\(\$adtSession\.DirSupportFiles\)', '<SupportFiles>'
                $s = $s -replace '\$\(\$adtSession\.DirFiles\)', '<Files>'
                ($s -replace '\s+', ' ').Trim()
            }
            $nd = & $norm $declared
            $na = & $norm $actual
            if ($nd -eq $na) {
                Add-Check 'SwitchSync' 'PASS' 'manifest install switches match the launcher' 'psadt-package.json'
            }
            else {
                Add-Check 'SwitchSync' 'FAIL' "manifest and launcher disagree on the install switches, and the verified-switch store records the MANIFEST. manifest='$nd' launcher='$na'. Fix with Set-PsadtPackageManifest.ps1 -Updates @{ 'research.switches.installArgs' = '<what the launcher runs>' }" 'psadt-package.json'
            }
        }
    }
}

# --- 9: per-run log name (WARN only) --------------------------------------------------------------
# Without LogName the launcher inherits PSADT's fixed default name AND LogAppend, so every run of every
# version piles into one file. Packages scaffolded before 0.21.0 are in that state; they still work.
$launcherText = Get-Content $launcher -Raw
if ($launcherText -match '(?m)^\s*LogName\s*=') {
    Add-Check 'LogName' 'PASS' 'launcher sets a per-run log name' 'Invoke-AppDeployToolkit.ps1'
} else {
    Add-Check 'LogName' 'WARN' 'launcher sets no LogName - every run appends to the same PSADT log (pre-0.21 scaffold); re-generate or add LogName to $adtSession' 'Invoke-AppDeployToolkit.ps1'
}

# --- 10: driver trust (only when the package actually ships drivers) ------------------------------
# Deliberately independent of package.type: a vendor installer that stages a driver under Files\ is the
# common case, and it is exactly the case nobody declares as a "driver package".
$infFiles = @(Get-ChildItem -LiteralPath $filesDir -Filter '*.inf' -File -Recurse -ErrorAction SilentlyContinue)
if ($infFiles.Count) {
    try {
        $assumeOff = $false
        if ($mf.Exists -and -not $mf.Error -and $mf.Manifest.driverTrust) {
            $assumeOff = [bool]$mf.Manifest.driverTrust.assumeSecureBootOff
        }
        $trust = & (Join-Path $PSScriptRoot 'Get-DriverSignatureInfo.ps1') -Path $filesDir -AssumeSecureBootOff:$assumeOff
        $owner = if ($mf.Exists -and -not $mf.Error) { [string]$mf.Manifest.driverTrust.owner } else { '' }

        $unsigned = @($trust.Drivers | Where-Object { $_.Classification -eq 'Unsigned' })
        $vendor   = @($trust.Drivers | Where-Object { $_.Classification -eq 'VendorSigned' })
        $kernel   = @($vendor | Where-Object { $_.KernelMode })

        if ($unsigned.Count) {
            Add-Check 'DriverTrust' 'FAIL' "$($unsigned.Count) unsigned driver(s) ($(($unsigned | ForEach-Object { $_.Inf }) -join ', ')) - this cannot install silently on a managed machine. See guide Appendix Q." 'Files'
        } elseif ($vendor.Count -and [string]::IsNullOrWhiteSpace($owner)) {
            Add-Check 'DriverTrust' 'FAIL' "$($vendor.Count) vendor-signed driver(s) but driverTrust.owner is not set in the manifest - the signer certificate has no owner, so the PnP prompt will block the silent install. Set it to 'policy' or 'package'." 'psadt-package.json'
        } elseif ($kernel.Count -and -not $assumeOff) {
            Add-Check 'DriverTrust' 'WARN' "$($kernel.Count) KERNEL-mode driver(s) with a vendor signature - TrustedPublisher removes the PnP prompt but does NOT satisfy Code Integrity, so with Secure Boot on the driver installs and then does not load (guide Appendix Q)." 'Files'
        } else {
            $detail = "$($trust.Drivers.Count) driver(s), $($trust.Overall)"
            if ($owner) { $detail += ", certificate owner '$owner'" }
            Add-Check 'DriverTrust' 'PASS' $detail 'Files'
        }
    } catch {
        Add-Check 'DriverTrust' 'WARN' "Driver classification failed: $($_.Exception.Message)" 'Files'
    }
}

# --- Verdict --------------------------------------------------------------------------------------
$overall = if (@($checks | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) { 'RED' } else { 'GREEN' }

# Record the verdict in the manifest (the ONLY thing this script writes). The dossier and Appendix E read
# it from there instead of the operator retyping "pre-flight was green" three phases later.
if ($mf.Exists -and -not $mf.Error) {
    try {
        & (Join-Path $PSScriptRoot 'Set-PsadtPackageManifest.ps1') -PackagePath $PackagePath -Updates @{
            'results.preflight' = @{
                verdict = $overall
                fails   = @($checks | Where-Object { $_.Status -eq 'FAIL' }).Count
                warns   = @($checks | Where-Object { $_.Status -eq 'WARN' }).Count
                at      = (Get-Date).ToUniversalTime().ToString('o')
            }
        } | Out-Null
    } catch { Write-Warning "Could not record the pre-flight verdict in the manifest: $($_.Exception.Message)" }
}
foreach ($c in $checks) { Write-Verbose ("[{0}] {1} ({2}): {3}" -f $c.Status, $c.Name, $c.File, $c.Detail) }

[pscustomobject]@{
    Overall     = $overall
    Checks      = $checks.ToArray()
    Files       = @($allPsFiles | ForEach-Object { Split-Path $_ -Leaf })
    PackagePath = $PackagePath
}

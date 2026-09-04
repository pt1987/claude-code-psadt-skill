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

# --- Verdict --------------------------------------------------------------------------------------
$overall = if (@($checks | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) { 'RED' } else { 'GREEN' }
foreach ($c in $checks) { Write-Verbose ("[{0}] {1} ({2}): {3}" -f $c.Status, $c.Name, $c.File, $c.Detail) }

[pscustomobject]@{
    Overall     = $overall
    Checks      = $checks.ToArray()
    Files       = @($allPsFiles | ForEach-Object { Split-Path $_ -Leaf })
    PackagePath = $PackagePath
}

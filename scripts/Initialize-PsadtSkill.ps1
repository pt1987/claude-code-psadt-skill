<#
.SYNOPSIS
    Setup doctor: verifies every psadt-deploy prerequisite in ONE pass and reports GREEN / YELLOW / RED.

.DESCRIPTION
    Replaces the Phase 0 prose wizard. Read-only unless -Fix or -Set is given, and idempotent - running it
    twice changes nothing the second time. Config, secret and tools live in the config home (see
    Get-PsadtConfig.ps1), NOT in the skill folder, so they survive a re-clone or a re-install of the skill.

    Checks (Status PASS | WARN | FAIL | SKIP; only FAIL turns the verdict RED):
      PowerShell7          host is PowerShell 7+                                         FAIL
      WindowsPowerShell51  powershell.exe 5.1 present (the SYSTEM test re-execs into it)  WARN
      Elevation            session is elevated (required by the Phase 6 SYSTEM test)      WARN
      Git                  git on PATH (else Update-PsadtSkill uses the zip route)        WARN
      PsadtModule          PSAppDeployToolkit installed               -Fix: PSGallery     FAIL
      IntuneWinAppUtil     packaging tool present                    -Fix: download      FAIL
      InvokeCommandAs      module present (SYSTEM test)              -Fix: PSGallery     WARN
      Pester               Pester 5+ present (test suite only)                           WARN
      Config               config.json exists and is complete        -Fix: defaults      FAIL
      LegacyConfig         config still sits inside the skill folder  -Fix: migrate       WARN
      SkillLocation        the skill tree looks complete                                 WARN
      SkillUpdate          no pending skill update (-SkipUpdateCheck skips it)           WARN
      IntuneAccess         upload credentials configured (config-only until 0.20)        WARN

    .Missing lists ONLY the keys a human has to supply: paths.packageRoot, paths.outputRoot, author.person,
    author.company (plus intune.* once uploadEnabled). The keys this script can fill itself
    (language.script, language.dossier, paths.intuneWinAppUtil) never show up there - run -Fix for those.

.PARAMETER Fix
    Provision and repair whatever needs no decision: migrate a legacy config home, install the
    PSAppDeployToolkit / Invoke-CommandAs modules, download IntuneWinAppUtil.exe, fill the language
    defaults (script EN / dossier DE) and record paths.intuneWinAppUtil.

.PARAMETER Set
    Config values to persist BEFORE checking, dotted keys as accepted by Set-PsadtConfig.ps1, e.g.
    @{ 'paths.packageRoot' = 'D:\pkg'; 'author.person' = 'Pat' }.

.PARAMETER Json
    Emit the result as JSON instead of the object (for non-PowerShell callers).

.PARAMETER JsonPath
    Additionally write the JSON result to this file.

.PARAMETER SkipUpdateCheck
    Skip the SkillUpdate check (no network call).

.PARAMETER SkillRoot
    Config home override; default = the home resolved by Get-PsadtConfig.ps1.

.OUTPUTS
    PSCustomObject: Overall('GREEN'|'YELLOW'|'RED'), Checks(@{Name,Status,Detail,Fix}[]), Missing(string[]),
    Home(string), ConfigPath(string), Migrated(bool)

.EXAMPLE
    pwsh scripts/Initialize-PsadtSkill.ps1
    Read-only health report.

.EXAMPLE
    pwsh scripts/Initialize-PsadtSkill.ps1 -Fix -Set @{ 'paths.packageRoot' = 'D:\pkg' }
    Persists the value, then migrates/provisions everything it can and reports what is still missing.
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [hashtable]$Set,
    [switch]$Json,
    [string]$JsonPath,
    [switch]$SkipUpdateCheck,
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'

$skillTree = Split-Path $PSScriptRoot -Parent
$getCfg    = Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1'
$setCfg    = Join-Path $PSScriptRoot 'Set-PsadtConfig.ps1'

$checks = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$Name, [string]$Status, [string]$Detail, [string]$FixHint) {
    $checks.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; Fix = $FixHint })
}
function Get-LatestModule([string]$Name) {
    Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending | Select-Object -First 1
}

# --- 0. -Set first: the user's own values are persisted before anything gets judged ----------------
if ($Set -and $Set.Count) { & $setCfg -SkillRoot $SkillRoot -Updates $Set | Out-Null }

$probe = & $getCfg -SkillRoot $SkillRoot

# --- 1. Migration (-Fix only): legacy config / secret / tools -> the config home -------------------
$migrated = $false
if ($Fix -and $probe.LegacyInUse) {
    $legacyHome = $probe.Home
    $target     = $probe.DefaultHome
    New-Item $target -ItemType Directory -Force | Out-Null

    Copy-Item $probe.Path (Join-Path $target 'config.json') -Force
    Rename-Item $probe.Path 'config.json.migrated' -Force

    $legacySecret = Join-Path $legacyHome 'secret.dpapi'
    if (Test-Path $legacySecret) {
        Copy-Item $legacySecret (Join-Path $target 'secret.dpapi') -Force
        Rename-Item $legacySecret 'secret.dpapi.migrated' -Force
    }

    # tools\ holds reproducible downloads, so this one really moves (config/secret are only renamed).
    $legacyTools = Join-Path $legacyHome 'tools'
    if (Test-Path $legacyTools) {
        $newTools = Join-Path $target 'tools'
        New-Item $newTools -ItemType Directory -Force | Out-Null
        foreach ($item in Get-ChildItem $legacyTools -Force) {
            Copy-Item $item.FullName $newTools -Recurse -Force
            if (Test-Path (Join-Path $newTools $item.Name)) { Remove-Item $item.FullName -Recurse -Force }
        }
    }

    $migrated = $true
    $probe = & $getCfg -SkillRoot $SkillRoot

    # A recorded tool path that still points into the old location has to follow.
    $recorded = [string]$probe.Config.paths.intuneWinAppUtil
    if ($recorded -and $recorded.StartsWith($legacyHome, [StringComparison]::OrdinalIgnoreCase)) {
        $rebased = Join-Path $target $recorded.Substring($legacyHome.Length).TrimStart('\', '/')
        & $setCfg -SkillRoot $SkillRoot -Updates @{ 'paths.intuneWinAppUtil' = $rebased } | Out-Null
        $probe = & $getCfg -SkillRoot $SkillRoot
    }
}

# --- 2. Provisioning (-Fix only) -------------------------------------------------------------------
if ($Fix) {
    try { & (Join-Path $PSScriptRoot 'Get-PsadtModule.ps1') -SkillRoot $SkillRoot | Out-Null }
    catch { Write-Warning "PSAppDeployToolkit provisioning failed: $($_.Exception.Message)" }

    try {
        $tool = & (Join-Path $PSScriptRoot 'Get-IntuneWinAppUtil.ps1') -SkillRoot $SkillRoot
        if ($tool.Path -and (Test-Path $tool.Path)) {
            & $setCfg -SkillRoot $SkillRoot -Updates @{ 'paths.intuneWinAppUtil' = $tool.Path } | Out-Null
        }
    } catch { Write-Warning "IntuneWinAppUtil provisioning failed: $($_.Exception.Message)" }

    if (-not (Get-LatestModule 'Invoke-CommandAs')) {
        try { Install-Module -Name 'Invoke-CommandAs' -Scope CurrentUser -Force -AllowClobber }
        catch { Write-Warning "Invoke-CommandAs install failed: $($_.Exception.Message)" }
    }

    $langDefaults = @{}
    if ([string]::IsNullOrWhiteSpace([string]$probe.Config.language.script))  { $langDefaults['language.script']  = 'EN' }
    if ([string]::IsNullOrWhiteSpace([string]$probe.Config.language.dossier)) { $langDefaults['language.dossier'] = 'DE' }
    if ($langDefaults.Count) { & $setCfg -SkillRoot $SkillRoot -Updates $langDefaults | Out-Null }

    $probe = & $getCfg -SkillRoot $SkillRoot
}

# --- 3. Environment --------------------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Add-Check 'PowerShell7' 'PASS' "PowerShell $($PSVersionTable.PSVersion)" $null
} else {
    Add-Check 'PowerShell7' 'FAIL' "host is PowerShell $($PSVersionTable.PSVersion) - the skill scripts target 7+" 'install PowerShell 7 (winget install Microsoft.PowerShell), then re-run with pwsh'
}

$winPs = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path $winPs) { Add-Check 'WindowsPowerShell51' 'PASS' $winPs $null }
else { Add-Check 'WindowsPowerShell51' 'WARN' 'powershell.exe (5.1) not found - the SYSTEM test cannot re-exec into it' 'no fix - Phase 6 has to run on another box' }

$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isElevated) { Add-Check 'Elevation' 'PASS' 'session is elevated' $null }
else { Add-Check 'Elevation' 'WARN' 'not elevated - the Phase 6 SYSTEM test needs an elevated session' 'reopen the shell as administrator when you reach Phase 6' }

if (Get-Command git -ErrorAction SilentlyContinue) { Add-Check 'Git' 'PASS' 'git on PATH' $null }
else { Add-Check 'Git' 'WARN' 'git missing - skill updates fall back to the branch-zip route' 'winget install Git.Git' }

# --- 4. Modules and tools --------------------------------------------------------------------------
$psadt = Get-LatestModule 'PSAppDeployToolkit'
if ($psadt) { Add-Check 'PsadtModule' 'PASS' "PSAppDeployToolkit $($psadt.Version)" $null }
else { Add-Check 'PsadtModule' 'FAIL' 'PSAppDeployToolkit not installed - no package can be scaffolded' 'Initialize-PsadtSkill.ps1 -Fix (installs from PSGallery)' }

$toolPath = [string]$probe.Config.paths.intuneWinAppUtil
if ([string]::IsNullOrWhiteSpace($toolPath)) { $toolPath = Join-Path $probe.Home 'tools/IntuneWinAppUtil.exe' }
if (Test-Path $toolPath) { Add-Check 'IntuneWinAppUtil' 'PASS' $toolPath $null }
else { Add-Check 'IntuneWinAppUtil' 'FAIL' "not found: $toolPath" 'Initialize-PsadtSkill.ps1 -Fix (downloads it into the config home)' }

$ica = Get-LatestModule 'Invoke-CommandAs'
if ($ica) { Add-Check 'InvokeCommandAs' 'PASS' "Invoke-CommandAs $($ica.Version)" $null }
else { Add-Check 'InvokeCommandAs' 'WARN' 'Invoke-CommandAs missing - the Phase 6 SYSTEM test self-heals it on first use' 'Initialize-PsadtSkill.ps1 -Fix' }

$pester = Get-LatestModule 'Pester'
if ($pester -and $pester.Version.Major -ge 5) { Add-Check 'Pester' 'PASS' "Pester $($pester.Version)" $null }
elseif ($pester) { Add-Check 'Pester' 'WARN' "Pester $($pester.Version) is too old for tests/ (needs 5+)" 'Install-Module Pester -MinimumVersion 5.0 -Force -Scope CurrentUser' }
else { Add-Check 'Pester' 'WARN' 'Pester not installed - the test suite cannot run (packaging is unaffected)' 'Install-Module Pester -MinimumVersion 5.0 -Force -Scope CurrentUser' }

# --- 5. Config -------------------------------------------------------------------------------------
$fillable     = @('language.script', 'language.dossier', 'paths.intuneWinAppUtil')
$missingHuman = @($probe.Missing | Where-Object { $fillable -notcontains $_ })
$missingAuto  = @($probe.Missing | Where-Object { $fillable -contains $_ })

if (-not $probe.Exists) {
    Add-Check 'Config' 'FAIL' "no config.json at $($probe.Path)" 'Initialize-PsadtSkill.ps1 -Fix -Set @{ ... } (see .Missing for the keys)'
} elseif ($probe.Error) {
    Add-Check 'Config' 'FAIL' $probe.Error 'fix the JSON by hand, or delete the file and re-run with -Fix'
} elseif ($missingHuman.Count) {
    Add-Check 'Config' 'FAIL' "$($missingHuman.Count) key(s) need a human: $($missingHuman -join ', ')" 'Initialize-PsadtSkill.ps1 -Set @{ ... } with the listed keys'
} elseif ($missingAuto.Count) {
    Add-Check 'Config' 'FAIL' "$($missingAuto.Count) key(s) missing but fillable: $($missingAuto -join ', ')" 'Initialize-PsadtSkill.ps1 -Fix'
} else {
    Add-Check 'Config' 'PASS' "complete: $($probe.Path)" $null
}

if ($probe.LegacyInUse) {
    Add-Check 'LegacyConfig' 'WARN' "config still lives in the skill folder ($($probe.Home)) - a re-clone or re-install loses it" 'Initialize-PsadtSkill.ps1 -Fix (migrates it; the old file is kept as config.json.migrated)'
} else {
    Add-Check 'LegacyConfig' 'PASS' "config home: $($probe.Home)" $null
}

# --- 6. Skill tree ---------------------------------------------------------------------------------
$expected = @('SKILL.md', 'scripts', 'references/PSADTv4-Deployment-Guide.md')
$absent   = @($expected | Where-Object { -not (Test-Path (Join-Path $skillTree $_)) })
if ($absent.Count) { Add-Check 'SkillLocation' 'WARN' "incomplete skill tree at $skillTree (missing: $($absent -join ', '))" 're-install the skill, or run the scripts from a full checkout' }
else { Add-Check 'SkillLocation' 'PASS' $skillTree $null }

if ($SkipUpdateCheck) {
    Add-Check 'SkillUpdate' 'SKIP' 'skipped (-SkipUpdateCheck)' $null
} else {
    try {
        $upd = & (Join-Path $PSScriptRoot 'Update-PsadtSkill.ps1') -SkillRoot $skillTree
        if ($upd.UpdateAvailable) { Add-Check 'SkillUpdate' 'WARN' "update available: $($upd.LocalVersion) -> $($upd.RemoteVersion)" 'Update-PsadtSkill.ps1 -Apply' }
        elseif ($upd.Action -eq 'CheckFailed') { Add-Check 'SkillUpdate' 'WARN' "check failed (offline?): $($upd.Error)" 'retry when GitHub is reachable' }
        else { Add-Check 'SkillUpdate' 'PASS' "up to date ($($upd.LocalVersion))" $null }
    } catch {
        Add-Check 'SkillUpdate' 'WARN' "check failed: $($_.Exception.Message)" 'retry when GitHub is reachable'
    }
}

# --- 7. Intune access (config-only until 0.20 turns this into real state) --------------------------
$intune = $probe.Config.intune
if (-not $intune -or -not $intune.uploadEnabled) {
    Add-Check 'IntuneAccess' 'SKIP' 'direct upload not enabled (optional)' 'New-PsadtEntraApp.ps1 to set it up'
} else {
    $gaps = @()
    foreach ($f in 'tenantId', 'clientId') { if ([string]::IsNullOrWhiteSpace([string]$intune.$f)) { $gaps += "intune.$f" } }
    if (-not [string]::IsNullOrWhiteSpace([string]$intune.certThumbprint)) {
        if (-not (Test-Path "Cert:\CurrentUser\My\$($intune.certThumbprint)")) { $gaps += 'intune.certThumbprint (not in Cert:\CurrentUser\My)' }
    } else {
        $ref = if ($intune.secretRef) { $intune.secretRef } else { 'secret.dpapi' }
        if (-not (Test-Path (Join-Path $probe.Home $ref))) { $gaps += "intune.secret ($ref)" }
    }
    if ($gaps.Count) { Add-Check 'IntuneAccess' 'WARN' "upload enabled but incomplete: $($gaps -join ', ')" 'New-PsadtEntraApp.ps1 (re-runs against the existing app)' }
    else { Add-Check 'IntuneAccess' 'PASS' "tenant $($intune.tenantId), client $($intune.clientId)" $null }
}

# --- Verdict ---------------------------------------------------------------------------------------
$overall =
    if (@($checks | Where-Object { $_.Status -eq 'FAIL' }).Count) { 'RED' }
    elseif (@($checks | Where-Object { $_.Status -eq 'WARN' }).Count) { 'YELLOW' }
    else { 'GREEN' }

$result = [pscustomobject]@{
    Overall    = $overall
    Checks     = $checks.ToArray()
    Missing    = $missingHuman
    Home       = $probe.Home
    ConfigPath = $probe.Path
    Migrated   = $migrated
}

if (-not $Json) {
    $colors = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; SKIP = 'DarkGray' }
    $head   = if ($overall -eq 'GREEN') { 'Green' } elseif ($overall -eq 'YELLOW') { 'Yellow' } else { 'Red' }
    Write-Host ''
    Write-Host "psadt-deploy setup - $overall" -ForegroundColor $head
    Write-Host "  config home : $($probe.Home)"
    Write-Host "  config file : $($probe.Path)$(if ($migrated) { '   (just migrated)' })"
    foreach ($c in $checks) {
        Write-Host ("  {0,-6} {1,-19} {2}" -f $c.Status, $c.Name, $c.Detail) -ForegroundColor $colors[$c.Status]
        if ($c.Fix -and ($c.Status -eq 'FAIL' -or $c.Status -eq 'WARN')) { Write-Host "         -> $($c.Fix)" -ForegroundColor DarkGray }
    }
    if ($missingHuman.Count) { Write-Host "  needs your input: $($missingHuman -join ', ')" -ForegroundColor Yellow }
    Write-Host ''
}

if ($JsonPath) {
    $parent = Split-Path $JsonPath -Parent
    if ($parent) { New-Item $parent -ItemType Directory -Force | Out-Null }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
}
if ($Json) { $result | ConvertTo-Json -Depth 5 } else { $result }

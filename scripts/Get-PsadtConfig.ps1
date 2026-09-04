<#
.SYNOPSIS
    Reads the PSADT skill config (config.json) and reports any missing required fields.

.DESCRIPTION
    Read-only. Resolves the config home, loads config.json from it and validates the required keys
    (paths.*, language.*, author.*). When intune.uploadEnabled is set, the credential reference is also
    checked; when intune.groups.enabled is set, the group naming scheme (intune.groups.naming) is
    validated. Returns a structured object - it never throws on a missing field, it lists them in
    .Missing for the caller to act on.

    Resolution order for the config home:
      1. an explicitly passed, non-empty -SkillRoot (wins unconditionally; used by the tests)
      2. $env:PSADT_DEPLOY_HOME
      3. %LOCALAPPDATA%\psadt-deploy
    If no -SkillRoot was given and the resolved home holds no config.json, a legacy config.json next to
    scripts\ (the pre-0.19 location inside the skill folder) is used read-only and .LegacyInUse is $true.

.PARAMETER SkillRoot
    Config home override. Default empty = resolve as described above.

.OUTPUTS
    PSCustomObject: Exists(bool), Config(object|null), Missing(string[]), Path(string), Home(string),
    DefaultHome(string), LegacyInUse(bool)

.EXAMPLE
    $c = & Get-PsadtConfig.ps1
    if (-not $c.Exists -or $c.Missing) { ... run Initialize-PsadtSkill.ps1 ... }
#>
[CmdletBinding()]
param([string]$SkillRoot)

$defaultHome =
    if (-not [string]::IsNullOrWhiteSpace($SkillRoot))              { $SkillRoot }
    elseif (-not [string]::IsNullOrWhiteSpace($env:PSADT_DEPLOY_HOME)) { $env:PSADT_DEPLOY_HOME }
    else { Join-Path $env:LOCALAPPDATA 'psadt-deploy' }

$configHome = $defaultHome
$configPath = Join-Path $configHome 'config.json'
$legacyInUse = $false
if ([string]::IsNullOrWhiteSpace($SkillRoot) -and -not (Test-Path -LiteralPath $configPath)) {
    $legacyHome = Split-Path $PSScriptRoot -Parent
    $legacyPath = Join-Path $legacyHome 'config.json'
    if (Test-Path -LiteralPath $legacyPath) {
        $configHome  = $legacyHome
        $configPath  = $legacyPath
        $legacyInUse = $true
    }
}

$required = @(
    'paths.packageRoot','paths.outputRoot','paths.intuneWinAppUtil',
    'language.script','language.dossier','author.person','author.company'
)
function Get-ByPath($obj, [string]$path) {
    $cur = $obj
    foreach ($seg in ($path -split '\.')) {
        if ($null -eq $cur) { return $null }
        $cur = $cur.$seg
    }
    return $cur
}
function New-Result([bool]$exists, $config, $missing, [string]$err) {
    $o = [ordered]@{
        Exists = $exists; Config = $config; Missing = $missing; Path = $configPath
        Home = $configHome; DefaultHome = $defaultHome; LegacyInUse = $legacyInUse
    }
    if ($err) { $o['Error'] = $err }
    [pscustomobject]$o
}

if (-not (Test-Path -LiteralPath $configPath)) { return (New-Result $false $null $required $null) }

try { $cfg = Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
catch { return (New-Result $true $null $required "config.json is malformed: $($_.Exception.Message)") }
$missing = [System.Collections.Generic.List[string]]::new()
foreach ($key in $required) {
    if ([string]::IsNullOrWhiteSpace([string](Get-ByPath $cfg $key))) { $missing.Add($key) }
}
if ($cfg.intune -and $cfg.intune.uploadEnabled) {
    foreach ($f in 'tenantId','clientId') {
        if ([string]::IsNullOrWhiteSpace([string]$cfg.intune.$f)) { $missing.Add("intune.$f") }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$cfg.intune.certThumbprint)) {
        if (-not (Test-Path "Cert:\CurrentUser\My\$($cfg.intune.certThumbprint)")) {
            $missing.Add("intune.certThumbprint (cert not found in Cert:\CurrentUser\My)")
        }
    } else {
        $ref = if ($cfg.intune.secretRef) { $cfg.intune.secretRef } else { 'secret.dpapi' }
        if (-not (Test-Path (Join-Path $configHome $ref))) { $missing.Add('intune.secret') }
    }
}
if ($cfg.intune -and $cfg.intune.groups -and $cfg.intune.groups.enabled) {
    $nm = $cfg.intune.groups.naming
    if (-not $nm) { $missing.Add('intune.groups.naming') }
    elseif (-not ($nm.required -or $nm.available -or $nm.uninstall)) {
        $missing.Add('intune.groups.naming (need at least one of required/available/uninstall)')
    }
}
New-Result $true $cfg $missing.ToArray() $null

<#
.SYNOPSIS
    Read-only verdict on the configured Intune access: can this app actually do the job, and for how long?

.DESCRIPTION
    Turns "403 three phases in" into an answer you can get before Phase 9. Reads the config, acquires an
    app-only token and reports what the token says it is allowed to do. Nothing is created or changed in
    the tenant; the only write is back into the local config (the verified roles + a timestamp), which
    -NoPersist suppresses.

    TokenOk is deliberately three-valued, because "no" and "could not ask" are different facts:
      $true  - a token was issued for the configured app
      $false - Entra refused (expired/invalid secret, unknown app, Conditional Access, ...)
      $null  - nobody was asked: not configured, or the endpoint could not be reached

    A $null verdict NEVER overwrites persisted state - being offline is not evidence that the app lost its
    permissions. Capabilities are three-valued for the same reason: $null means the token could not be
    introspected (Graph tokens are opaque by contract), which is not the same as "not permitted".

    This checks the CREDENTIAL and the granted app roles. It does not replace the read probe inside
    Invoke-IntuneWin32Upload.ps1, which proves the permission is effective against the real endpoint.

.PARAMETER Json
    Emit the verdict as JSON instead of the object.

.PARAMETER JsonPath
    Additionally write the JSON verdict to this file.

.PARAMETER NoPersist
    Do not write intune.roles / intune.lastVerified back to the config.

.PARAMETER SkillRoot
    Config home override; default = the home resolved by Get-PsadtConfig.ps1.

.OUTPUTS
    PSCustomObject: Configured(bool), AuthMethod(string|null), TenantId, ClientId, AppDisplayName,
    TokenOk(bool|null), Roles(string[]), Capabilities(hashtable: Upload/Groups/Configuration, each
    bool|null), CredExpires(datetime|null), DaysToExpiry(int|null), LastVerified(datetime|null), Hints(string[])

.EXAMPLE
    pwsh scripts/Test-PsadtIntuneAccess.ps1
.EXAMPLE
    pwsh scripts/Test-PsadtIntuneAccess.ps1 -Json -NoPersist
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [string]$JsonPath,
    [switch]$NoPersist,
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_GraphCommon.ps1')

# The app roles behind each capability. Groups needs BOTH: creating a group the app cannot then read
# members of is a half-finished assignment.
$RoleUpload = 'DeviceManagementApps.ReadWrite.All'
$RoleGroups = @('Group.Create', 'GroupMember.Read.All')
$RoleConfig = 'DeviceManagementConfiguration.ReadWrite.All'

$hints = [System.Collections.Generic.List[string]]::new()
$probe  = & (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1') -SkillRoot $SkillRoot
$intune = $probe.Config.intune

$configured = ($probe.IntuneState -eq 'Configured')
if (-not $configured) {
    if ($probe.IntuneState -eq 'NotConfigured') {
        $hints.Add('Direct upload is not configured - run New-PsadtEntraApp.ps1 (optional; packaging works without it).')
    } else {
        $gaps = @($probe.Missing | Where-Object { $_ -like 'intune.*' -and $_ -notlike 'intune.groups*' })
        $hints.Add("The upload config is incomplete: $($gaps -join ', '). Re-run New-PsadtEntraApp.ps1.")
    }
}

function ConvertTo-DateTimeOrNull($value) {
    # ConvertFrom-Json silently turns an ISO-8601 string into a [datetime], so a config field can arrive
    # as either shape depending on how it was written. Normalise instead of assuming.
    if ($null -eq $value -or '' -eq $value) { return $null }
    if ($value -is [datetime]) { return $value }
    try {
        return [datetime]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
    } catch { return $null }
}

# Persisted state is the fallback answer for everything the token cannot tell us right now.
$storedRoles  = if ($null -eq $intune.roles) { @() } else { @($intune.roles) }
$lastVerified = ConvertTo-DateTimeOrNull $intune.lastVerified
$credExpires  = ConvertTo-DateTimeOrNull $intune.credExpires
$daysToExpiry = $null
if ($credExpires) {
    $daysToExpiry = [int][Math]::Floor(($credExpires - (Get-Date)).TotalDays)
    if ($daysToExpiry -lt 0) {
        $hints.Add("The credential EXPIRED $([Math]::Abs($daysToExpiry)) day(s) ago ($($credExpires.ToString('yyyy-MM-dd'))) - re-run New-PsadtEntraApp.ps1.")
    } elseif ($daysToExpiry -lt 30) {
        $hints.Add("The credential expires in $daysToExpiry day(s) ($($credExpires.ToString('yyyy-MM-dd'))) - re-run New-PsadtEntraApp.ps1 before it does.")
    }
}

$tokenOk    = $null
$roles      = $storedRoles
$authMethod = $null

if ($configured) {
    try {
        $tok        = & (Join-Path $PSScriptRoot 'Get-GraphToken.ps1') -SkillRoot $SkillRoot
        $tokenOk    = $true
        $authMethod = $tok.AuthMethod
        if (@($tok.Roles).Count) { $roles = @($tok.Roles) }
        else { $hints.Add('The token was issued but its roles could not be read (opaque token) - capabilities are unknown, not denied.') }
    } catch {
        $msg  = $_.Exception.Message
        $hint = Get-GraphAuthErrorHint $msg
        # UNKNOWN is reserved for "we never got to ask" - a transport failure and nothing else. Everything
        # else (Entra said no, or the local credential is unusable at all: undecryptable DPAPI blob, missing
        # certificate, no private key) is a real REFUSED that has to surface, not hide as "unknown".
        $transport = -not $hint -and $msg -match 'No such host|actively refused|timed out|timeout|Unable to connect|could not be resolved|name or service not known|SSL|TLS|Connection reset'
        if ($transport) {
            $tokenOk = $null
            $hints.Add("Entra could not be reached ($msg) - verdict unknown, the last known state is kept.")
        } else {
            $tokenOk = $false
            $hints.Add($(if ($hint) { $hint } else { $msg }))
        }
    }
}

# Capabilities: $null = the token said nothing about roles, so we do NOT claim a denial.
$rolesKnown = @($roles).Count -gt 0
$caps = [ordered]@{
    Upload        = if ($rolesKnown) { $roles -contains $RoleUpload } else { $null }
    Groups        = if ($rolesKnown) { -not @($RoleGroups | Where-Object { $roles -notcontains $_ }).Count } else { $null }
    Configuration = if ($rolesKnown) { $roles -contains $RoleConfig } else { $null }
}
if ($rolesKnown) {
    if (-not $caps.Upload) {
        $hints.Add("The app has no '$RoleUpload' - Phase 9 upload is not possible. Re-run New-PsadtEntraApp.ps1.")
    }
    $missingGroupRoles = @($RoleGroups | Where-Object { $roles -notcontains $_ })
    if ($missingGroupRoles.Count -and $missingGroupRoles.Count -lt $RoleGroups.Count) {
        $hints.Add("Group assignment is half-granted - missing: $($missingGroupRoles -join ', '). Re-run New-PsadtEntraApp.ps1 -IncludeGroupManagement.")
    }
}

# Persist only a verified result: an offline or refused check must not rewrite what we know.
if ($tokenOk -eq $true -and -not $NoPersist) {
    $lastVerified = (Get-Date).ToUniversalTime()
    & (Join-Path $PSScriptRoot 'Set-PsadtConfig.ps1') -SkillRoot $SkillRoot -Updates @{
        'intune.roles'        = $roles
        'intune.lastVerified' = $lastVerified.ToString('o')
    } | Out-Null
}

$result = [pscustomobject]@{
    Configured     = $configured
    AuthMethod     = $authMethod
    TenantId       = [string]$intune.tenantId
    ClientId       = [string]$intune.clientId
    AppDisplayName = [string]$intune.appDisplayName
    TokenOk        = $tokenOk
    Roles          = @($roles)
    Capabilities   = $caps
    CredExpires    = $credExpires
    DaysToExpiry   = $daysToExpiry
    LastVerified   = $lastVerified
    Hints          = $hints.ToArray()
}

if (-not $Json) {
    $verdict = if ($tokenOk -eq $true) { 'VERIFIED' } elseif ($tokenOk -eq $false) { 'REFUSED' } else { 'UNKNOWN' }
    $color   = if ($tokenOk -eq $true) { 'Green' } elseif ($tokenOk -eq $false) { 'Red' } else { 'Yellow' }
    Write-Host ''
    Write-Host "Intune access - $verdict" -ForegroundColor $color
    if ($result.TenantId) { Write-Host "  tenant/client : $($result.TenantId) / $($result.ClientId)" }
    if ($result.AppDisplayName) { Write-Host "  app           : $($result.AppDisplayName)" }
    if ($authMethod) { Write-Host "  auth          : $authMethod" }
    foreach ($k in $caps.Keys) {
        $v = $caps[$k]
        $txt = if ($null -eq $v) { 'unknown' } elseif ($v) { 'yes' } else { 'NO' }
        $c   = if ($null -eq $v) { 'DarkGray' } elseif ($v) { 'Green' } else { 'Red' }
        Write-Host ("  {0,-14}: {1}" -f $k.ToLower(), $txt) -ForegroundColor $c
    }
    if ($null -ne $daysToExpiry) { Write-Host "  credential    : expires $($credExpires.ToString('yyyy-MM-dd')) (in $daysToExpiry day(s))" }
    if ($lastVerified) { Write-Host "  last verified : $lastVerified" }
    foreach ($h in $hints) { Write-Host "  -> $h" -ForegroundColor Yellow }
    Write-Host ''
}

if ($JsonPath) {
    $parent = Split-Path $JsonPath -Parent
    if ($parent) { New-Item $parent -ItemType Directory -Force | Out-Null }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
}
if ($Json) { $result | ConvertTo-Json -Depth 5 } else { $result }

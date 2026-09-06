<#
.SYNOPSIS
    Creates/reuses Entra security groups by the configured naming scheme and assigns a win32LobApp to them
    (intents required / available / uninstall) via Microsoft Graph. Read-only dry-run by default; -Execute writes.

.DESCRIPTION
    Opt-in, config-driven group assignment. The naming scheme lives in config.json (intune.groups.naming) and is
    version-INDEPENDENT, so a NEW app version resolves the SAME groups: assign the new app + wire supersedence on
    upload (Invoke-IntuneWin32Upload -SupersedesAppId) and the new version targets the same audience while the old
    one is retained for rollback.

    Group names come from templates with tokens {AppName} {AppVendor} {AppArch}. For each intent:
      - exactly one existing group with that displayName  -> REUSE it
      - none, and create=true                             -> CREATE it (assigned/static security group)
      - none, and create=false                            -> report MISSING, skip the assignment
      - more than one (displayName is NOT unique in Entra) -> report AMBIGUOUS, skip (never guess)
    Existing app assignments are read first; one that already targets the same group+intent is skipped
    (idempotent). The script NEVER deletes a group or another app's assignment.

    Least-privilege Graph APPLICATION permissions (grant via New-PsadtEntraApp.ps1 -IncludeGroupManagement):
      - find a group by name : GroupMember.Read.All
      - create a group       : Group.Create   (the app owns what it creates; NOT the tenant-wide Group.ReadWrite.All)
      - assign the app       : DeviceManagementApps.ReadWrite.All (already required for upload)

.PARAMETER AppId        The win32LobApp id (from the upload).
.PARAMETER AppName      App name for the {AppName} token.
.PARAMETER AppVendor    Optional {AppVendor} token.
.PARAMETER AppArch      Optional {AppArch} token (default x64).
.PARAMETER Intents      Subset of required/available/uninstall. Default = every intent that has a template.
.PARAMETER Execute      Perform the writes. Without it the script is a read-only dry run.
.PARAMETER GraphToken   Optional bearer token (testing / reuse). Default: Get-GraphToken.ps1.
.PARAMETER SkillRoot    Config home override; default = the resolved config home.

.OUTPUTS
    PSCustomObject: Executed, AppId, Groups(@{Intent,Name,Id,Action}), Assignments(@{Intent,GroupId,Action}), DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppId,
    [Parameter(Mandatory)][string]$AppName,
    [string]$AppVendor = '',
    [string]$AppVersion = '',
    [ValidateSet('x64', 'x86', 'arm64')][string]$AppArch = 'x64',
    # Deliberately NOT [ValidateSet]: that validates at BIND time, and `pwsh script.ps1 -Intents a,b` (the
    # -File form, which is what a bare `pwsh scripts/...ps1` invocation uses) hands the whole string over as
    # ONE element. The caller then gets "the argument 'required,available,uninstall' does not belong to the
    # set" - an error about a value they never typed. Split and validate in the body instead, where a
    # comma-separated list can simply be accepted.
    [string[]]$Intents,
    [switch]$Execute,
    [string]$GraphToken,
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'
$GraphBase = 'https://graph.microsoft.com/beta'

# --- Shared Graph helpers (Write-*, Get-GraphErr, Invoke-Graph; retry + PS7-safe) ----------------
. (Join-Path $PSScriptRoot '_GraphCommon.ps1')
$script:step = 0

# --- Config --------------------------------------------------------------------------------------
$cfg = (& (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1') -SkillRoot $SkillRoot).Config
if (-not ($cfg.intune -and $cfg.intune.groups -and $cfg.intune.groups.enabled)) {
    throw "Group assignment is not enabled. Configure intune.groups in config.json (guide Appendix M / run setup)."
}
$g = $cfg.intune.groups
$naming = $g.naming
if (-not $naming) { throw "intune.groups.naming is missing in config.json." }
$create     = [bool]$g.create
$membership = if ($g.membershipType) { [string]$g.membershipType } else { 'assigned' }

# --- Token ---------------------------------------------------------------------------------------
$token = if ($GraphToken) { $GraphToken } else { (& (Join-Path $PSScriptRoot 'Get-GraphToken.ps1') -SkillRoot $SkillRoot).Token }
$H  = @{ Authorization = "Bearer $token" }
$Hc = @{ Authorization = "Bearer $token"; ConsistencyLevel = 'eventual' }   # directory reads

# Group assignment needs BOTH roles, and a half-granted app is the nastiest case: it creates the group and
# then cannot read its members. Name the missing half before anything is created.
foreach ($role in 'Group.Create', 'GroupMember.Read.All') {
    Assert-GraphRole -Token $token -Role $role `
        -Hint 'Run New-PsadtEntraApp.ps1 -IncludeGroupManagement (Global Admin), then Test-PsadtIntuneAccess.ps1 to verify.' | Out-Null
}

# --- Intents -------------------------------------------------------------------------------------
$validIntents = @('required', 'available', 'uninstall')

# Accept both real arrays (@('required','available'), from -Command or a dot-source) and the single
# comma-separated string that the -File binder produces. Trailing/leading spaces are tolerated because
# "-Intents required, available" is what the documentation used to show.
$requestedIntents = @($Intents | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })

$unknown = @($requestedIntents | Where-Object { $validIntents -notcontains $_ })
if ($unknown.Count -gt 0) {
    throw "Unknown intent(s): $($unknown -join ', '). Valid values are: $($validIntents -join ', ')."
}

$configured = $validIntents | Where-Object { $naming.$_ }
$targetIntents = if ($requestedIntents.Count -gt 0) { @($requestedIntents | Where-Object { $configured -contains $_ }) } else { $configured }
if (-not $targetIntents) { throw "No intents to process (no matching naming template in config.intune.groups.naming)." }

function Resolve-GroupName([string]$tmpl) {
    # BINDING: group names contain NO spaces. Token values are space-stripped before substitution, and the
    # final name is space-stripped as a safety net. Tokens use the %token% form (and {Token} as an alias),
    # case-insensitive: %appname% %appvendor% %apparch% %version%.
    $tokens = [ordered]@{
        appname   = ($AppName    -replace '\s', '')
        appvendor = ($AppVendor  -replace '\s', '')
        apparch   = ($AppArch    -replace '\s', '')
        version   = ($AppVersion -replace '\s', '')
    }
    $n = $tmpl
    foreach ($k in $tokens.Keys) {
        $val = [string]$tokens[$k]
        $n = [regex]::Replace($n, "%$k%",   { $val }.GetNewClosure(), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $n = [regex]::Replace($n, "\{$k\}", { $val }.GetNewClosure(), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    return ($n -replace '\s', '')
}
function Get-MailNickname([string]$name) {
    $n = ($name -replace '[^a-zA-Z0-9]', ''); if (-not $n) { $n = 'grp' }
    if ($n.Length -gt 60) { $n = $n.Substring(0, 60) }; return $n
}

Write-Host "Intune app assignment (Graph) - app $AppId" -ForegroundColor White
Write-Info "Mode: $(if($create){'create + assign'}else{'assign to existing only'}) | membership: $membership | intents: $($targetIntents -join ', ')"

# Existing assignments (idempotency)
$existing = @((Invoke-Graph GET "$GraphBase/deviceAppManagement/mobileApps/$AppId/assignments" -Headers $H).value)

$groupResults  = New-Object System.Collections.Generic.List[object]
$assignResults = New-Object System.Collections.Generic.List[object]

foreach ($intent in $targetIntents) {
    $name = Resolve-GroupName ([string]$naming.$intent)
    Write-Step "[$intent] group '$name'"

    # Resolve (find / create / report)
    $esc = $name.Replace("'", "''")
    try {
        $found = @((Invoke-Graph GET "$GraphBase/groups?`$filter=displayName eq '$esc'&`$select=id,displayName" -Headers $Hc).value)
    } catch {
        $e = Get-GraphErr $_
        if ($e.code -match 'Authorization|Forbidden' -or "$($e.message)" -match 'privile|permission|scope') {
            throw "Graph denied the group lookup ($($e.code)). The Entra app likely lacks GroupMember.Read.All / Group.Create - re-run New-PsadtEntraApp.ps1 -IncludeGroupManagement (Global Admin)."
        }
        throw
    }

    $groupId = $null; $action = $null
    if ($found.Count -eq 1) { $groupId = $found[0].id; $action = 'reuse'; Write-Ok "reuse existing group ($groupId)" }
    elseif ($found.Count -gt 1) { $action = 'ambiguous'; Write-Info "AMBIGUOUS: $($found.Count) groups named '$name' - skipping (resolve manually)" }
    elseif ($create) {
        $action = 'create'
        if ($Execute) {
            if ($membership -ne 'assigned') { throw "membershipType '$membership' needs a membership rule; only 'assigned' is implemented." }
            $grp = Invoke-Graph POST "$GraphBase/groups" -Headers $H -Body @{
                displayName = $name; description = "PSADT app assignment ($intent) for $AppName"
                mailEnabled = $false; mailNickname = (Get-MailNickname $name); securityEnabled = $true; groupTypes = @()
            }
            $groupId = $grp.id; Write-Ok "created group ($groupId)"
        } else { Write-Info "would CREATE group '$name' (assigned/static)" }
    } else { $action = 'missing'; Write-Info "MISSING and create=false - skipping (create it manually or enable create)" }

    $groupResults.Add([pscustomobject]@{ Intent = $intent; Name = $name; Id = $groupId; Action = $action })
    if ($action -in 'ambiguous', 'missing') { continue }

    # Assignment (idempotent)
    $already = $existing | Where-Object {
        $_.intent -eq $intent -and "$($_.target.'@odata.type')" -match 'groupAssignmentTarget' -and $_.target.groupId -eq $groupId
    }
    if ($already -and $groupId) { $assignResults.Add([pscustomobject]@{ Intent = $intent; GroupId = $groupId; Action = 'exists' }); Write-Ok "already assigned"; continue }

    if ($Execute -and $groupId) {
        $null = Invoke-Graph POST "$GraphBase/deviceAppManagement/mobileApps/$AppId/assignments" -Headers $H -Body @{
            '@odata.type' = '#microsoft.graph.mobileAppAssignment'
            intent        = $intent
            target        = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $groupId }
            settings      = @{
                '@odata.type'                = '#microsoft.graph.win32LobAppAssignmentSettings'
                notifications                = 'showAll'
                restartSettings              = $null
                installTimeSettings          = $null
                deliveryOptimizationPriority = 'notConfigured'
                autoUpdateSettings           = $null
            }
        }
        Write-Ok "assigned ($intent)"
        $assignResults.Add([pscustomobject]@{ Intent = $intent; GroupId = $groupId; Action = 'assigned' })
    } else {
        $assignResults.Add([pscustomobject]@{ Intent = $intent; GroupId = $groupId; Action = 'would-assign' })
    }
}

if (-not $Execute) {
    Write-Host "`n--- DRY RUN (read-only). Re-run with -Execute to create groups + assign. ---" -ForegroundColor Yellow
    foreach ($gr in $groupResults) { Write-Host ("  [{0,-9}] {1,-40} group: {2}{3}" -f $gr.Intent, $gr.Name, $gr.Action, $(if ($gr.Id) { " ($($gr.Id))" } else { '' })) }
}
else {
    Write-Host "`nDone. Groups + assignments are set (app NOT removed/modified beyond assignments)." -ForegroundColor Green
}

[pscustomobject]@{
    Executed    = [bool]$Execute
    AppId       = $AppId
    Groups      = $groupResults.ToArray()
    Assignments = $assignResults.ToArray()
    DryRun      = (-not $Execute)
}

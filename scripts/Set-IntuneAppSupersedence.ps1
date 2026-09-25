<#
.SYNOPSIS
    Declares that one win32LobApp supersedes one or more others. Read-only dry-run by default; -Execute writes.

.DESCRIPTION
    Supersedence is how a new version replaces an old one in Intune. It is an admin-declared edge in a
    graph, NOT a version comparison: Intune never looks at displayVersion to decide which app is newer,
    and it will happily accept a chain pointing the wrong way. Direction is therefore validated here,
    not by the service.

    Two modes, Microsoft's own two scenarios:
      update  - "the child app should be updated by the internal logic of the parent app". The portal's
                "Uninstall previous version" = No. Correct for a newer version of the same product whose
                installer performs its own upgrade, e.g. an MSI carrying an Upgrade row for its
                predecessor.
      replace - "the child app should be uninstalled before installing the parent app". Toggle = Yes.
                Correct when the new app is a different product, or the installer will not upgrade over
                the old one.
    The default is 'update' because that is the ordinary case this skill produces and it is the less
    destructive of the two; 'replace' uninstalls software from devices before installing the new build.

    WHY updateRelationships AND NOT POST .../relationships
    The documented create path, POST to the relationships collection, is reported to answer "No OData
    route exists that match template ~/singleton/navigation/key/navigation with http verb POST"; the
    admin center uses the updateRelationships action instead. That action has REPLACE semantics - it
    sets the app's entire relationship set - so the current relationships are read first and merged
    (Merge-AppRelationships in _GraphCommon.ps1). Sending only the new edge would silently delete every
    other relationship the app had.

    What it never does: delete an app, delete an assignment, or remove a relationship it did not merge.
    Relationship management exists only in Graph /beta - v1.0's mobileAppRelationship has neither
    supersedenceType nor targetType - so this script uses /beta like the rest of the family.

    Permission: DeviceManagementApps.ReadWrite.All, already required for upload; no new consent. The
    signed-in ADMIN additionally needs the Intune RBAC permission "Relate" under Mobile apps (service
    release 2202+), which is a different failure from a missing Graph scope and is named as such.

.PARAMETER AppId            The superseding app - the NEW version. Receives the relationship.
.PARAMETER SupersedesAppId  One or more app ids this app replaces - the OLD version(s).
.PARAMETER SupersedenceType update (installer upgrades in place) or replace (uninstall the old first).
.PARAMETER MaxGraphNodes    Refuse when the resulting graph would exceed this many related nodes. Intune
                            documents a maximum of 10 related nodes (11 including the root).
.PARAMETER Force            Proceed although the declared direction looks backwards by displayVersion.
.PARAMETER ManifestPath     Record the outcome in this package's psadt-package.json.
.PARAMETER Execute          Perform the write. Without it the script is a read-only dry run.
.PARAMETER GraphToken       Optional bearer token (testing / reuse). Default: Get-GraphToken.ps1.
.PARAMETER SkillRoot        Config home override; default = the resolved config home.

.OUTPUTS
    PSCustomObject: Executed, AppId, Supersedes, SupersedenceType, RelationshipsBefore,
    RelationshipsAfter, Verified, DryRun

.EXAMPLE
    pwsh scripts/Set-IntuneAppSupersedence.ps1 -AppId '<new>' -SupersedesAppId '<old>'

.EXAMPLE
    pwsh scripts/Set-IntuneAppSupersedence.ps1 -AppId '<new>' -SupersedesAppId '<old>' -SupersedenceType replace -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$AppId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string[]]$SupersedesAppId,

    [ValidateSet('update', 'replace')][string]$SupersedenceType = 'update',
    [ValidateRange(1, 10)][int]$MaxGraphNodes = 10,
    [switch]$Force,
    # The note on the superseded app is written by default. It is the only trace of the supersedence that
    # is visible to someone who opens the OLD app in the portal - the relationship itself shows on the
    # superseding app's blade, so the version that stopped installing explains itself nowhere.
    [switch]$NoAnnotate,
    [string]$ManifestPath,
    [switch]$Execute,
    [string]$GraphToken,
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'
$GraphBase = 'https://graph.microsoft.com/beta'

# --- Shared Graph helpers (Write-*, Get-GraphErr, Invoke-Graph, Merge-AppRelationships) ----------
. (Join-Path $PSScriptRoot '_GraphCommon.ps1')
$script:step = 0

# --- Cheap refusals, before any network call --------------------------------------------------------
$targets = @($SupersedesAppId | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
if (-not $targets) { throw "No -SupersedesAppId given: there is nothing for $AppId to supersede." }
if ($targets -contains $AppId) {
    throw "An app cannot supersede itself ($AppId). Intune rejects the self-edge with an opaque 400; this is the same refusal with a reason attached."
}
if ($targets.Count -gt $MaxGraphNodes) {
    throw "$($targets.Count) superseded apps requested, but Intune allows a maximum of $MaxGraphNodes related nodes in one supersedence graph."
}

if ($ManifestPath -and -not (Test-Path -LiteralPath $ManifestPath)) { throw "ManifestPath not found: $ManifestPath" }

# --- Token ------------------------------------------------------------------------------------------
$token = if ($GraphToken) { $GraphToken } else { (& (Join-Path $PSScriptRoot 'Get-GraphToken.ps1') -SkillRoot $SkillRoot).Token }
$H = @{ Authorization = "Bearer $token" }

Assert-GraphRole -Token $token -Role 'DeviceManagementApps.ReadWrite.All' `
    -Hint 'Run New-PsadtEntraApp.ps1, then Test-PsadtIntuneAccess.ps1 to verify.' | Out-Null

# --- Read the apps, so the summary names them instead of printing bare GUIDs ---------------------------
Write-Step 'Read the apps (read-only)'
function Get-App([string]$id, [string]$label) {
    try { return Invoke-Graph GET "$GraphBase/deviceAppManagement/mobileApps/$id" -Headers $H }
    catch {
        $e = Get-GraphErr $_
        if ($e.code -eq 404 -or "$($e.message)" -match 'not found|does not exist') {
            throw "The $label app $id is not in this tenant. Check the id (Get-IntuneAppVersions.ps1 lists them)."
        }
        throw "Could not read the $label app $id ($($e.code)): $($e.message)"
    }
}
$newApp = Get-App $AppId 'superseding'
Write-Info ("superseding : {0}  v={1}" -f $newApp.displayName, $newApp.displayVersion)
$oldApps = foreach ($t in $targets) {
    $o = Get-App $t 'superseded'
    Write-Info ("superseded  : {0}  v={1}" -f $o.displayName, $o.displayVersion)
    $o
}

# --- Direction: ours to validate, because Intune does not ---------------------------------------------
# displayVersion is cosmetic to the service: it is not an input to any enforcement decision, and a
# backwards chain is accepted without complaint and then quietly re-installs the older build.
function ConvertTo-ComparableVersion([string]$v) {
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    $clean = ($v -replace '[^0-9.]', '').Trim('.')
    if (-not $clean) { return $null }
    $parts = @($clean -split '\.' | Where-Object { $_ -ne '' } | Select-Object -First 4)
    try { return [version](($parts + @('0', '0', '0', '0'))[0..3] -join '.') } catch { return $null }
}
$newV = ConvertTo-ComparableVersion $newApp.displayVersion
$backwards = @()
foreach ($o in $oldApps) {
    $oldV = ConvertTo-ComparableVersion $o.displayVersion
    if ($newV -and $oldV -and $newV -lt $oldV) { $backwards += "$($o.displayName) $($o.displayVersion)" }
}
if ($backwards.Count -and -not $Force) {
    throw ("Direction looks backwards: $($newApp.displayName) $($newApp.displayVersion) would supersede a NEWER version ($($backwards -join '; ')). " +
        "Intune never compares versions, so it would accept this and roll devices back. Pass -Force if the direction is deliberate.")
}
if ($backwards.Count) { Write-Warn2 "Direction is backwards by displayVersion; proceeding because -Force was given." }

# --- The current relationships, and the merge ----------------------------------------------------------
Write-Step 'Read the current relationships (read-only)'
$before = @((Invoke-Graph GET "$GraphBase/deviceAppManagement/mobileApps/$AppId/relationships" -Headers $H).value)
Write-Info "$($before.Count) relationship(s) on the superseding app today."

$merged = Merge-AppRelationships -Existing $before -SupersedeTargetIds $targets -SupersedenceType $SupersedenceType

# The ceiling Intune enforces spans the whole connected graph, and a node shared with another graph
# merges the two - so this count is a floor. Refusing on the floor is still worth doing: it catches the
# common case locally instead of as a service-side 400 with no explanation.
if ($merged.Count -gt $MaxGraphNodes) {
    throw ("The merge would leave $($merged.Count) relationships on this app, above the documented maximum of $MaxGraphNodes related nodes. " +
        "Prune the chain first (Get-IntuneAppVersions.ps1 shows it).")
}

# --- Dry run -------------------------------------------------------------------------------------------
Write-Step 'Plan'
Write-Host "  App         : $($newApp.displayName) [$AppId]" -ForegroundColor White
Write-Host "  Supersedes  : $($targets -join ', ')" -ForegroundColor White
Write-Host "  Mode        : $SupersedenceType $(if ($SupersedenceType -eq 'replace') { '(the old version is UNINSTALLED first)' } else { '(the installer upgrades in place)' })" -ForegroundColor White
Write-Host "  Relationships: $($before.Count) now -> $($merged.Count) after (the full set is re-sent; updateRelationships replaces it)" -ForegroundColor White
# Not a warning about tidiness. Microsoft: "Superseding apps that aren't targeted are ignored by the
# agent." Without an assignment on the NEW app this relationship does nothing at all.
#
# The app's own isAssigned property is NOT usable for this. Measured against a live tenant 2026-09-25:
# for the same Chrome app, GET /mobileApps/{id} returns isAssigned=False while
# GET /mobileApps?$filter=... returns isAssigned=True. The single-entity value is simply wrong, and
# trusting it warned about an app with two live assignments. Count the assignments instead.
$assignmentCount = $null
try { $assignmentCount = @((Invoke-Graph GET "$GraphBase/deviceAppManagement/mobileApps/$AppId/assignments" -Headers $H).value).Count }
catch { Write-Warn2 "Could not read the assignments of the superseding app; the precondition below is unverified." }
if ($assignmentCount -eq 0) {
    Write-Warn2 "The superseding app has NO assignment. Supersedence only takes effect for an assigned superseding app - assign it (Phase 10) or nothing will happen on any device."
} elseif ($null -ne $assignmentCount) {
    Write-Info "Superseding app has $assignmentCount assignment(s) - the precondition for supersedence to take effect."
}

# The other half of the same precondition, and the one nothing surfaces. Supersedence only reaches
# devices targeted by the SUPERSEDING app. A device sitting in the SUPERSEDED app's Required group and
# not in the superseding app's therefore installs the OLD version and is never moved forward - an app
# declared superseded while still being Required is a contradiction, and it is invisible unless you open
# both blades. Reported, not refused: during a staged rollout both are legitimately assigned for a while.
function Get-AppIntents([string]$id) {
    try {
        $v = @((Invoke-Graph GET "$GraphBase/deviceAppManagement/mobileApps/$id/assignments" -Headers $H).value | ForEach-Object { [string]$_.intent })
        # The leading comma is load-bearing. PowerShell unwraps an EMPTY array on the way out of a
        # function, so a bare `return @()` arrives at the caller as $null - indistinguishable from the
        # catch below. That turned "this app targets nobody", which is the desired end state, into
        # "assignment state could not be read", and wrote exactly that into the audit note on the app.
        return , $v
    }
    catch { return $null }
}
$supersededStillRequired = @()
foreach ($o in $oldApps) {
    $intents = Get-AppIntents $o.id
    if ($null -eq $intents) { Write-Warn2 "Could not read the assignments of the superseded app $($o.id)."; continue }
    if ($intents -contains 'required') {
        $supersededStillRequired += [pscustomobject]@{ id = [string]$o.id; displayName = [string]$o.displayName; displayVersion = [string]$o.displayVersion; intents = $intents }
    }
}
foreach ($s in $supersededStillRequired) {
    Write-Warn2 ("The superseded app '$($s.displayName) $($s.displayVersion)' is STILL assigned as required. A device in that group and not in the superseding app's group installs the OLD version, " +
        "and supersedence will not move it forward - it only reaches devices targeted by the superseding app. Narrow or remove that required assignment (App. R.7); this script never touches another app's assignments.")
}

if (-not $Execute) {
    Write-Host "`nDRY RUN - nothing was changed. Re-run with -Execute to apply." -ForegroundColor Yellow
    return [pscustomobject]@{
        Executed = $false; AppId = $AppId; Supersedes = $targets; SupersedenceType = $SupersedenceType
        RelationshipsBefore = $before.Count; RelationshipsAfter = $merged.Count; Verified = $null
        SupersededStillRequired = @($supersededStillRequired); DryRun = $true
    }
}

# ============================== WRITES BELOW THIS LINE ==============================
# Only updateRelationships is ever called. No DELETE is issued here or anywhere in this script: an app,
# an assignment and a relationship this script did not merge are all left alone.

Write-Step 'Set the relationships'
$null = Invoke-Graph POST "$GraphBase/deviceAppManagement/mobileApps/$AppId/updateRelationships" -Headers $H -Body @{ relationships = @($merged) }
Write-Ok "updateRelationships accepted."

# --- Verify: a 204 is an acknowledgement, not evidence -------------------------------------------------
Write-Step 'Read the chain back'
$after = @((Invoke-Graph GET "$GraphBase/deviceAppManagement/mobileApps/$AppId/relationships" -Headers $H).value)
$wired = @($after | Where-Object { $_.'@odata.type' -match 'mobileAppSupersedence' -and $_.targetType -eq 'child' } | ForEach-Object { [string]$_.targetId })
$missing = @($targets | Where-Object { $wired -notcontains $_ })
$verified = ($missing.Count -eq 0)

if ($verified) { Write-Ok "Verified: $AppId supersedes $($targets -join ', ') ($SupersedenceType)." }
else { Write-Fail "Read-back does not show: $($missing -join ', '). The call was accepted but the chain is not what was asked for." }

# --- Annotate the superseded app, so the OLD version explains itself in the portal -------------------
if (-not $NoAnnotate) {
    Write-Step 'Record the supersedence in the superseded app notes'
    $stamp = (Get-Date).ToString('yyyy-MM-dd')
    foreach ($o in $oldApps) {
        try {
            # Read first: notes is a free-text field an admin may already be using, and a supersedence
            # record is not worth destroying someone's operational note.
            $cur = Invoke-Graph GET "$GraphBase/deviceAppManagement/mobileApps/$($o.id)" -Headers $H
            $existingNotes = [string]$cur.notes

            $intentsNow = Get-AppIntents $o.id
            $assignmentNote = if ($null -eq $intentsNow) { 'assignment state could not be read' }
            elseif (@($intentsNow).Count -eq 0) { 'this version no longer targets any group; the superseding app carries the assignments' }
            else { "this version is STILL assigned ($((@($intentsNow) | Sort-Object -Unique) -join ', ')) - devices in those groups keep receiving it" }

            $line = "[psadt-deploy $stamp] Superseded by '$($newApp.displayName) $($newApp.displayVersion)' (app id $AppId), mode '$SupersedenceType'" +
            $(if ($SupersedenceType -eq 'replace') { ' - the previous version is uninstalled before the new one installs' } else { ' - the installer upgrades in place, no uninstall command is sent' }) +
            ". Groups: $assignmentNote. This app is retained as a rollback target and was not deleted."

            if ($existingNotes -and $existingNotes.Contains($line)) { Write-Info "Note already present on $($o.id)."; continue }
            $notes = if ([string]::IsNullOrWhiteSpace($existingNotes)) { $line } else { $existingNotes.TrimEnd() + "`n" + $line }

            # Intune caps notes at 1024 characters; a refused PATCH would lose the record silently.
            if ($notes.Length -gt 1024) { $notes = $notes.Substring($notes.Length - 1024) }

            $null = Invoke-Graph PATCH "$GraphBase/deviceAppManagement/mobileApps/$($o.id)" -Headers $H -Body @{ '@odata.type' = [string]$cur.'@odata.type'; notes = $notes }
            Write-Ok "Noted on '$($o.displayName) $($o.displayVersion)'."
        } catch {
            $e = Get-GraphErr $_
            Write-Warn2 "Could not write the note on $($o.id): $($e.message). The supersedence itself is unaffected."
        }
    }
}

# --- Record it ------------------------------------------------------------------------------------------
if ($ManifestPath) {
    try {
        & (Join-Path $PSScriptRoot 'Set-PsadtPackageManifest.ps1') -PackagePath (Split-Path -Parent (Resolve-Path -LiteralPath $ManifestPath).Path) -Updates @{
            'results.supersedence' = @{
                appId            = $AppId
                supersedes       = @($targets)
                supersedenceType = $SupersedenceType
                verified         = $verified
                at               = (Get-Date).ToUniversalTime().ToString('o')
            }
        } | Out-Null
        Write-Info "Recorded in results.supersedence."
    } catch { Write-Warn2 "Manifest not updated: $($_.Exception.Message)" }
}

if (-not $verified) {
    throw "Supersedence was not verified after the write: $($missing -join ', ') is missing from the chain. Check the app in the portal before relying on this deployment."
}

[pscustomobject]@{
    Executed = $true; AppId = $AppId; Supersedes = $targets; SupersedenceType = $SupersedenceType
    RelationshipsBefore = $before.Count; RelationshipsAfter = $after.Count; Verified = $verified
    SupersededStillRequired = @($supersededStillRequired); DryRun = $false
}

<#
.SYNOPSIS
    Lists every win32LobApp in the tenant that carries one displayName, with its version, its publishing
    state and the supersedence relationships it already has. Read-only; there is no -Execute.

.DESCRIPTION
    The predecessor problem, solved once. Invoke-IntuneWin32Upload.ps1 already finds the older version
    during its idempotency check and prints "found: id=..." - but it cannot consume that id in the same
    run, so wiring supersedence meant aborting, copying a GUID out of the console, and re-invoking. This
    script is the half that was missing: ask which versions exist, get their ids back as data.

    It also reads each app's relationships, because the interesting question is rarely "which versions
    are there" on its own. It is "which of them already replaces which", and whether the chain is
    already at Intune's node ceiling.

    Direction is read from targetType, not guessed: on a relationship held by app X, targetType 'child'
    means X supersedes the target, and 'parent' means the target supersedes X. Getting that backwards
    produces a chain that looks right in a report and does nothing on a device.

    Relationship management lives only in Graph /beta - v1.0's mobileAppRelationship is List/Get with no
    supersedenceType and no targetType at all - so this script uses /beta like the rest of the family.

    Permission: DeviceManagementApps.ReadWrite.All, already required for upload. Nothing new to consent.

.PARAMETER DisplayName
    The Intune app display name, e.g. 'Google LLC Google Chrome'. Mutually exclusive with -ManifestPath.

.PARAMETER ManifestPath
    A package's psadt-package.json; the display name is derived from app.vendor + app.name exactly as
    Invoke-IntuneWin32Upload.ps1 derives it, so both scripts look for the same app.

.PARAMETER Json
    Emit JSON to stdout instead of the object.

.PARAMETER JsonPath
    Also write the JSON to this path.

.PARAMETER GraphToken
    Optional bearer token (testing / reuse). Default: Get-GraphToken.ps1.

.PARAMETER SkillRoot
    Config home override; default = the resolved config home.

.OUTPUTS
    PSCustomObject: DisplayName, Count, Versions(@{ id, displayVersion, publishingState, isAssigned,
    createdDateTime, lastModifiedDateTime, supersedes[], supersededBy[] }), GraphNodeCount

.EXAMPLE
    pwsh scripts/Get-IntuneAppVersions.ps1 -DisplayName 'Google LLC Google Chrome'

.EXAMPLE
    pwsh scripts/Get-IntuneAppVersions.ps1 -ManifestPath 'C:\PSADT\Packages\Chrome\psadt-package.json' -Json
#>
[CmdletBinding()]
param(
    # Deliberately NOT Mandatory, and deliberately not two parameter sets: a missing mandatory parameter
    # makes PowerShell PROMPT, and with stdin redirected that is a silent hang rather than an error
    # (measured at 19 minutes on the 0.46.0 benchmark before the run was killed). Both are validated in
    # the body, where the message can name the fix.
    [string]$DisplayName,
    [string]$ManifestPath,
    [switch]$Json,
    [string]$JsonPath,
    [string]$GraphToken,
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'
$GraphBase = 'https://graph.microsoft.com/beta'

# --- Shared Graph helpers (Write-*, Get-GraphErr, Invoke-Graph; retry + PS7-safe) ----------------
. (Join-Path $PSScriptRoot '_GraphCommon.ps1')
$script:step = 0

# --- Identity ------------------------------------------------------------------------------------
if ($DisplayName -and $ManifestPath) {
    throw "Pass -DisplayName or -ManifestPath, not both - two sources of identity cannot be reconciled."
}
if (-not $DisplayName -and -not $ManifestPath) {
    throw "Name the app: pass -DisplayName '<Vendor> <App>', or -ManifestPath <pkg>\psadt-package.json to take it from the package."
}
if ($ManifestPath) {
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "ManifestPath not found: $ManifestPath" }
    try { $mf = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "psadt-package.json is malformed: $($_.Exception.Message)" }
    if (-not $mf.app.name) { throw "The manifest has no app.name, so the Intune display name cannot be derived: $ManifestPath" }
    # Same derivation as Invoke-IntuneWin32Upload.ps1:136. If these two ever disagree, this script
    # reports "no versions found" for an app that is plainly in the tenant.
    $DisplayName = if ($mf.app.vendor) { "$($mf.app.vendor) $($mf.app.name)" } else { [string]$mf.app.name }
}

# --- Token ---------------------------------------------------------------------------------------
$token = if ($GraphToken) { $GraphToken } else { (& (Join-Path $PSScriptRoot 'Get-GraphToken.ps1') -SkillRoot $SkillRoot).Token }
$H = @{ Authorization = "Bearer $token" }

Assert-GraphRole -Token $token -Role 'DeviceManagementApps.ReadWrite.All' `
    -Hint 'Run New-PsadtEntraApp.ps1, then Test-PsadtIntuneAccess.ps1 to verify.' | Out-Null

# --- The apps ------------------------------------------------------------------------------------
Write-Step "Find win32LobApp versions named '$DisplayName'"
# Apostrophe doubling is not cosmetic: an OData string literal ends at the first unescaped quote, so
# "Igor's" would either 400 or - worse - match a different filter than the one intended, and a
# supersedence would then be wired to whatever that returned.
$escaped = $DisplayName.Replace("'", "''")
$apps = @((Invoke-Graph GET "$GraphBase/deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.win32LobApp') and displayName eq '$escaped'" -Headers $H).value)

if (-not $apps) {
    Write-Info "No win32LobApp with that display name is in the tenant."
} else {
    Write-Ok "$($apps.Count) version(s) found."
}

# --- The relationships, per app --------------------------------------------------------------------
$rows = @()
foreach ($a in $apps) {
    $rels = @()
    try { $rels = @((Invoke-Graph GET "$GraphBase/deviceAppManagement/mobileApps/$($a.id)/relationships" -Headers $H).value) }
    catch {
        # A readable app whose relationships cannot be read is reported as unknown, never as none: an
        # empty list here would look exactly like "safe to wire" and could silently exceed the ceiling.
        $e = Get-GraphErr $_
        Write-Warn2 "Relationships for $($a.id) could not be read ($($e.message)); reported as unknown."
        $rels = $null
    }

    $sup = @($rels | Where-Object { $_.'@odata.type' -match 'mobileAppSupersedence' })
    $rows += [pscustomobject]@{
        id                   = [string]$a.id
        displayVersion       = [string]$a.displayVersion
        publishingState      = [string]$a.publishingState
        isAssigned           = [bool]$a.isAssigned
        createdDateTime      = [string]$a.createdDateTime
        lastModifiedDateTime = [string]$a.lastModifiedDateTime
        relationshipsKnown   = ($null -ne $rels)
        # targetType 'child' = the target is BELOW this app, i.e. this app supersedes it.
        supersedes           = @($sup | Where-Object { $_.targetType -eq 'child' } | ForEach-Object {
                [pscustomobject]@{ targetId = [string]$_.targetId; targetDisplayName = [string]$_.targetDisplayName
                    targetDisplayVersion = [string]$_.targetDisplayVersion; supersedenceType = [string]$_.supersedenceType } })
        supersededBy         = @($sup | Where-Object { $_.targetType -eq 'parent' } | ForEach-Object {
                [pscustomobject]@{ targetId = [string]$_.targetId; targetDisplayName = [string]$_.targetDisplayName
                    targetDisplayVersion = [string]$_.targetDisplayVersion; supersedenceType = [string]$_.supersedenceType } })
    }
}

foreach ($r in $rows | Sort-Object displayVersion) {
    $tail = if (-not $r.relationshipsKnown) { 'relationships unknown' }
    elseif ($r.supersedes.Count -or $r.supersededBy.Count) { "supersedes $($r.supersedes.Count), superseded by $($r.supersededBy.Count)" }
    else { 'no relationships' }
    Write-Info ("{0}  v={1,-16} {2,-10} assigned={3,-5} {4}" -f $r.id, $r.displayVersion, $r.publishingState, $r.isAssigned, $tail)
}

# The node count Intune enforces is over the whole connected graph, not this display name - a shared
# node merges graphs. This is therefore a FLOOR, and is labelled as one wherever it is shown.
$nodeIds = New-Object System.Collections.Generic.HashSet[string]
foreach ($r in $rows) {
    [void]$nodeIds.Add($r.id)
    foreach ($t in @($r.supersedes) + @($r.supersededBy)) { if ($t.targetId) { [void]$nodeIds.Add([string]$t.targetId) } }
}

$result = [pscustomobject]@{
    DisplayName        = $DisplayName
    Count              = $rows.Count
    Versions           = @($rows)
    GraphNodeCountFloor = $nodeIds.Count
}

if ($JsonPath) {
    $dir = Split-Path -Parent $JsonPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
    Write-Info "JSON written: $JsonPath"
}
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $result }

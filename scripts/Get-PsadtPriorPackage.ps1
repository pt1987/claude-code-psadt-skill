<#
.SYNOPSIS
    Finds the most recent package this machine built for the same application, and returns what it
    learned. Read-only; there is no -Execute.

.DESCRIPTION
    Every store this skill writes is keyed by the installer's SHA256, which changes with every new
    version by definition. So the knowledge recorded while packaging version 3.1.0 - the silent switches
    that took an afternoon to find, the uninstaller that has to be renamed first, the app mutex, the
    leftovers, both decision gates - is unreachable when 3.2.0 arrives. It sits in a manifest in a folder
    that nothing opens.

    This is the lookup that opens it. It matches on the identity the operator chose (app.vendor +
    app.name, normalised by _AppKey.ps1) rather than on the folder name or the binary's ProductName,
    because neither of those is stable across versions: the same application lives in 'GoogleChrome' and
    'GoogleChrome_154.0.8037.58' on this machine, and the store's ProductName field carries versions
    ('LibreOffice 26.2.6.3') and PE padding.

    It OFFERS; it never applies. The caller shows the carried values as stated assumptions the operator
    corrects - the same pattern the research ladder already uses for its findings. A vendor can change
    their uninstaller between versions, and last year's workaround applied unseen is worse than one
    re-made.

    Index first, scan as fallback. The index is fast and survives a package folder being archived; the
    scan finds packages built before the index existed, or a folder handed over by a colleague, and
    backfills them.

.PARAMETER Vendor         app.vendor of the application being packaged.
.PARAMETER Name           app.name of the application being packaged.
.PARAMETER ManifestPath   Take Vendor/Name/Version from this manifest instead of passing them.
.PARAMETER Version        The version being packaged now; it is never returned as its own predecessor.
.PARAMETER PackageRoot    Where packages live. Default: config paths.packageRoot.
.PARAMETER NoIndex        Skip the index and scan only (used by the tests, and when the index is suspect).
.PARAMETER Json           Emit JSON instead of the object.
.PARAMETER SkillRoot      Config home override.

.OUTPUTS
    PSObject: Found, AppKey, Version, CarriedFrom, PackagePath, ManifestPath, PackagedAt, Carry

.EXAMPLE
    pwsh scripts/Get-PsadtPriorPackage.ps1 -Vendor 'AOMEI' -Name 'Partition Assistant'

.EXAMPLE
    pwsh scripts/Get-PsadtPriorPackage.ps1 -ManifestPath '<pkg>\psadt-package.json' -Json
#>
[CmdletBinding()]
param(
    [string]$Vendor,
    [string]$Name,
    [string]$ManifestPath,
    [string]$Version,
    [string]$PackageRoot,
    [switch]$NoIndex,
    [switch]$Json,
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_AppKey.ps1')

# --- Identity -------------------------------------------------------------------------------------
if ($ManifestPath) {
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "ManifestPath not found: $ManifestPath" }
    try { $cur = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "psadt-package.json is malformed: $($_.Exception.Message)" }
    if (-not $Vendor) { $Vendor = [string]$cur.app.vendor }
    if (-not $Name) { $Name = [string]$cur.app.name }
    if (-not $Version) { $Version = [string]$cur.app.version }
}

$appKey = ConvertTo-PsadtAppKey -Vendor $Vendor -Name $Name
$none = [pscustomobject]@{
    Found = $false; AppKey = $appKey; Version = $null; CarriedFrom = $null
    PackagePath = $null; ManifestPath = $null; PackagedAt = $null; Carry = $null
}
function Out-Result($r) { if ($Json) { $r | ConvertTo-Json -Depth 10 } else { $r } }

# No identity, no lookup. This is not an error: a caller may simply not know yet.
if (-not $appKey) { Out-Result $none; return }

# --- Where to look --------------------------------------------------------------------------------
if (-not $PackageRoot) {
    try { $PackageRoot = [string](& (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1') -SkillRoot $SkillRoot).Config.paths.packageRoot } catch { $PackageRoot = $null }
}

# Sorting versions as STRINGS puts 3.10.0 before 3.2.0, which would inherit from a version older than
# the one before it. Parse where possible; fall back to a string compare only for genuinely unparseable
# values, so an odd version never takes the whole lookup down.
function ConvertTo-SortableVersion([string]$v) {
    if ([string]::IsNullOrWhiteSpace($v)) { return [version]'0.0.0.0' }
    $clean = ($v -replace '[^0-9.]', '').Trim('.')
    if (-not $clean) { return [version]'0.0.0.0' }
    $parts = @($clean -split '\.' | Where-Object { $_ -ne '' } | Select-Object -First 4)
    try { return [version](($parts + @('0', '0', '0', '0'))[0..3] -join '.') } catch { return [version]'0.0.0.0' }
}

$candidates = [System.Collections.Generic.List[object]]::new()
function Add-Candidate($manifestPath) {
    if (-not $manifestPath -or -not (Test-Path -LiteralPath $manifestPath)) { return }
    $dir = Split-Path -Parent $manifestPath
    # A manifest beside no launcher is not a package - a stray JSON, a backup, an export.
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'Invoke-AppDeployToolkit.ps1'))) { return }
    # A malformed manifest must not fail the lookup; skipping one is better than finding none.
    try { $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
    if ((Get-PsadtAppKeyFromManifest -Manifest $m) -ne $appKey) { return }
    $v = [string]$m.app.version
    # Never inherit from itself. Same version = the package being (re-)built right now.
    if ($Version -and $v -eq $Version) { return }
    $candidates.Add([pscustomobject]@{
            Version = $v; Sort = (ConvertTo-SortableVersion $v); PackagePath = $dir
            ManifestPath = $manifestPath; PackagedAt = [string]$m.results.package.packedAt; Manifest = $m
        })
}

# 1) the index
if (-not $NoIndex) {
    try {
        $home_ = [string](& (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1') -SkillRoot $SkillRoot).Home
        $idxPath = if ($home_) { Join-Path $home_ 'package-index.json' } else { '' }
        if ($idxPath -and (Test-Path -LiteralPath $idxPath)) {
            $idx = Get-Content -LiteralPath $idxPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($e in @($idx.entries)) {
                if ([string]$e.appKey -ne $appKey) { continue }
                Add-Candidate ([string]$e.manifestPath)
            }
        }
    } catch { }   # an unreadable index degrades to a scan, never to a failure
}

# 2) the scan - also the backfill for anything the index never saw
if ($PackageRoot -and (Test-Path -LiteralPath $PackageRoot)) {
    foreach ($f in @(Get-ChildItem -LiteralPath $PackageRoot -Filter 'psadt-package.json' -File -Recurse -Depth 1 -ErrorAction SilentlyContinue)) {
        if ($candidates.ManifestPath -contains $f.FullName) { continue }
        Add-Candidate $f.FullName
    }
}

if (-not $candidates.Count) { Out-Result $none; return }

$best = $candidates | Sort-Object -Property Sort -Descending | Select-Object -First 1
$m = $best.Manifest

# What travels. Deliberately the whole research and decisions nodes rather than a hand-picked list: the
# manifest is free-form by design (one package records appMutex, another records license) and a fixed
# field list would quietly drop whatever this particular app needed most.
$carry = [pscustomobject]@{
    research    = $m.research
    decisions   = $m.decisions
    description = $m.app.description
    # Recorded by the generator and, until a live run caught it, not offered back - which made it the
    # one value this lookup exists to stop people retyping. It is a generator PARAMETER on the next run,
    # so it has to leave here or it is lost again.
    processesToClose = @($m.package.processesToClose)
    # Lets the caller tell a genuine new build from a re-pack of the same bytes: identical hash means
    # the switches proven last time apply exactly, not merely probably.
    installerSha256  = [string]$m.package.installerSha256
}

Out-Result ([pscustomobject]@{
        Found        = $true
        AppKey       = $appKey
        Version      = $best.Version
        CarriedFrom  = $best.Version
        PackagePath  = $best.PackagePath
        ManifestPath = $best.ManifestPath
        PackagedAt   = $best.PackagedAt
        Carry        = $carry
    })

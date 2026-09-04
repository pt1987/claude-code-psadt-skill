<#
.SYNOPSIS
    Creates/updates a package's psadt-package.json (deep partial merge, dotted paths, array append).

.DESCRIPTION
    The write side of the per-package manifest. Same contract as Set-PsadtConfig.ps1 - dotted-path keys set
    a single leaf or a whole sub-tree without rewriting the file, siblings survive, -Remove deletes leaves
    after -Updates - plus -Append for the results arrays, because a second SYSTEM test must add to the
    record rather than erase the first one.

    A malformed manifest is a hard stop, never a silent overwrite: it is the only record of the decisions
    taken for this package.

.PARAMETER PackagePath
    The package folder (the one containing Invoke-AppDeployToolkit.ps1).

.PARAMETER Updates
    Hashtable of dotted-path -> value, e.g. @{ 'app.version' = '2.9.1'; 'decisions.gate2' = @{...} }.
    Intermediate nodes are created as needed.

.PARAMETER Append
    Hashtable of dotted-path -> value where the target is an ARRAY; the value is appended. A missing key
    becomes a one-element array. Use for results.systemTest and artifacts.logs.

.PARAMETER Remove
    Dotted-path keys to delete. A key that does not exist is a no-op. Applied after -Updates and -Append.

.OUTPUTS
    PSCustomObject: Path(string), Schema(int)

.EXAMPLE
    Set-PsadtPackageManifest.ps1 -PackagePath D:\Pakete\MxMC -Updates @{ 'app.version' = '2.9.1' }

.EXAMPLE
    Set-PsadtPackageManifest.ps1 -PackagePath D:\Pakete\MxMC -Append @{ 'results.systemTest' = @{ type = 'Install'; verdict = 'GREEN' } }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [hashtable]$Updates = @{},
    [hashtable]$Append = @{},
    [string[]]$Remove = @()
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $PackagePath)) { throw "PackagePath not found: $PackagePath" }
if (-not (Test-Path -LiteralPath (Join-Path $PackagePath 'Invoke-AppDeployToolkit.ps1'))) {
    throw "Not a PSADT package (no Invoke-AppDeployToolkit.ps1): $PackagePath"
}
$manifestPath = Join-Path $PackagePath 'psadt-package.json'

function ConvertTo-HashtableDeep($obj) {
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }
        return $h
    }
    if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) {
        return @(foreach ($item in $obj) { ConvertTo-HashtableDeep $item })
    }
    return $obj
}
function Get-ParentNode($root, [string[]]$segs, [bool]$Create) {
    $node = $root
    for ($i = 0; $i -lt $segs.Count - 1; $i++) {
        if (-not ($node[$segs[$i]] -is [hashtable])) {
            if (-not $Create) { return $null }
            $node[$segs[$i]] = @{}
        }
        $node = $node[$segs[$i]]
    }
    return $node
}

$manifest = if (Test-Path -LiteralPath $manifestPath) {
    try { ConvertTo-HashtableDeep (Get-Content $manifestPath -Raw | ConvertFrom-Json) }
    catch { throw "psadt-package.json is malformed and cannot be safely updated: $($_.Exception.Message). Fix or delete it, then re-run." }
} else { @{ schema = 1 } }
if (-not $manifest.ContainsKey('schema')) { $manifest['schema'] = 1 }

foreach ($key in $Updates.Keys) {
    $segs = $key -split '\.'
    $node = Get-ParentNode $manifest $segs $true
    $node[$segs[-1]] = $Updates[$key]
}

foreach ($key in $Append.Keys) {
    $segs = $key -split '\.'
    $node = Get-ParentNode $manifest $segs $true
    $leaf = $segs[-1]
    # Deliberately statements, not `$x = if (...) {...}`: PowerShell unwraps a single-element array on the
    # way out of a block, and a lone hashtable would make the next line a hashtable MERGE (which throws on
    # a duplicate key) instead of an array append. @() on both sides keeps it concatenation.
    $existing = @()
    if ($null -ne $node[$leaf]) { $existing = @($node[$leaf]) }
    $node[$leaf] = @() + $existing + @($Append[$key])
}

foreach ($key in $Remove) {
    if ([string]::IsNullOrWhiteSpace($key)) { continue }
    $segs = $key -split '\.'
    $node = Get-ParentNode $manifest $segs $false
    if ($node -is [hashtable]) { $node.Remove($segs[-1]) }
}

# Depth 12: results/artifacts nest arrays of objects, and a truncated manifest is a silent data loss.
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestPath -Encoding UTF8

[pscustomobject]@{ Path = $manifestPath; Schema = $manifest['schema'] }

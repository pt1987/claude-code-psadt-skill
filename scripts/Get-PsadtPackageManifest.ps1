<#
.SYNOPSIS
    Reads a package's psadt-package.json (the per-app single source of truth) and reports what is missing.

.DESCRIPTION
    Read-only, and it never throws on an incomplete manifest - gaps are listed in .Missing for the caller to
    act on, exactly like Get-PsadtConfig.ps1 does for the machine config. One app, one file, one truth:
    identity, the decisions taken at the gates, the research findings, the results of every phase and the
    artifacts produced. Before 0.21 this lived in the operator's head and in $meta arguments, which is why
    two packages of the same app could disagree about their own version.

    Schema 1 sections:
      app        vendor, name, version, arch, lang, revision
      package    name, type (installer|winget|script|browser-extension|windows-feature|driver),
                 installerTech, sourceStrategy
      decisions  gate1, gate2{audience,uninstallScope,repair,reboot}, systemTest, upload
      research   switches, exitCodes, logPaths, leftovers, returnCodes[] ({ code, type, de, en } -
                 installer-specific Intune return codes; type is one of success/softReboot/hardReboot/
                 retry/failed and is validated by Get-PsadtReturnCodes.ps1)
      driverTrust classification, owner, thumbprint
      results    preflight, systemTest[], package, report, upload
      artifacts  outputFolder, intunewin, detection, dossier, logo, logs[]

    .Stem is the BINDING artifact name, ALWAYS derived from the identity: <Vendor>_<App>_<Version>_<Arch>,
    spaces to underscores, reduced to [A-Za-z0-9._-], ASCII. It is $null while the identity is incomplete -
    a partial identity must never produce a half-named file. package.name is where that stem gets recorded
    for other tools to read; it is never read back as the source, or a stale cache would win over a version
    bump.

.PARAMETER PackagePath
    The package folder (the one containing Invoke-AppDeployToolkit.ps1).

.PARAMETER Identity
    Derive a stem WITHOUT a package on disk: @{ vendor=..; name=..; version=..; arch=.. }. The generators
    need the stem while they are still writing the launcher, and the sanitizing rule must exist exactly
    once - a second copy would drift and rename an app behind everyone's back.

.OUTPUTS
    PSCustomObject: Exists(bool), Manifest(object|null), Missing(string[]), Path(string), Stem(string|null),
    Error(string, only when the file is malformed)

.EXAMPLE
    $m = & Get-PsadtPackageManifest.ps1 -PackagePath D:\Pakete\MxMC
    if ($m.Missing) { ... Set-PsadtPackageManifest.ps1 ... }
#>
[CmdletBinding(DefaultParameterSetName = 'Package')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Package')][string]$PackagePath,
    [Parameter(Mandatory, ParameterSetName = 'Identity')][hashtable]$Identity
)
$ErrorActionPreference = 'Stop'

function ConvertTo-NameToken([string]$value) {
    # File-name safety is not cosmetic here: the stem becomes a folder name, a file name and the
    # win32LobApp fileName, and IntuneWinAppUtil is unforgiving about the last one.
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    $t = $value.Trim() -replace '\s+', '_'
    $t = $t -replace '[^A-Za-z0-9._-]', '_'
    $t = $t -replace '_{2,}', '_'
    return $t.Trim('_', '.')
}

if ($PSCmdlet.ParameterSetName -eq 'Identity') {
    $parts = @('vendor', 'name', 'version', 'arch') |
        ForEach-Object { ConvertTo-NameToken ([string]$Identity[$_]) } |
        Where-Object { $_ }
    return [pscustomobject]@{ Stem = ($parts -join '_') }
}

if (-not (Test-Path -LiteralPath $PackagePath)) { throw "PackagePath not found: $PackagePath" }
$launcher = Join-Path $PackagePath 'Invoke-AppDeployToolkit.ps1'
if (-not (Test-Path -LiteralPath $launcher)) { throw "Not a PSADT package (no Invoke-AppDeployToolkit.ps1): $PackagePath" }

$manifestPath = Join-Path $PackagePath 'psadt-package.json'

# The identity floor: everything the artifact name and the dossier header are built from.
$required = @('app.vendor', 'app.name', 'app.version', 'app.arch', 'package.type')

function Get-ByPath($obj, [string]$path) {
    $cur = $obj
    foreach ($seg in ($path -split '\.')) {
        if ($null -eq $cur) { return $null }
        $cur = $cur.$seg
    }
    return $cur
}
function New-Result([bool]$exists, $manifest, $missing, [string]$stem, [string]$err) {
    $o = [ordered]@{
        Exists = $exists; Manifest = $manifest; Missing = $missing; Path = $manifestPath; Stem = $stem
    }
    if ($err) { $o['Error'] = $err }
    [pscustomobject]$o
}

if (-not (Test-Path -LiteralPath $manifestPath)) { return (New-Result $false $null $required $null $null) }

try { $m = Get-Content $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
catch { return (New-Result $true $null $required $null "psadt-package.json is malformed: $($_.Exception.Message)") }

$missing = [System.Collections.Generic.List[string]]::new()
foreach ($key in $required) {
    if ([string]::IsNullOrWhiteSpace([string](Get-ByPath $m $key))) { $missing.Add($key) }
}

$stem = $null
if ($missing.Count -eq 0) {
    # ALWAYS derived from the identity, never read back from package.name. package.name is where the
    # derived stem gets recorded for other tools; if the two ever disagree, the identity is the truth and
    # the cached name is stale. Letting the cache win would silently rename an app after a version bump.
    $parts = @('app.vendor', 'app.name', 'app.version', 'app.arch') |
        ForEach-Object { ConvertTo-NameToken ([string](Get-ByPath $m $_)) } |
        Where-Object { $_ }
    $stem = ($parts -join '_')
}

New-Result $true $m $missing.ToArray() $stem $null

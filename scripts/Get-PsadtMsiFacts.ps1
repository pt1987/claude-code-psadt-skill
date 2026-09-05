<#
.SYNOPSIS  Reads EVERYTHING a packaging decision needs out of an MSI in ONE pass: identity, signature, features, shortcuts, upgrade rules, files, registry.
.DESCRIPTION
  Phase 2/4 needs the same facts from every MSI: ProductCode and UpgradeCode, whether the vendor put the
  auto-updater in its own feature, whether the Shortcut table creates a desktop icon, whether an upgrade
  migrates feature states, what the installed binary's file version is for the detection script. Gathering
  them as separate probes costs a process start and a COM handshake each and invites the four traps below.

  This opens the database once and returns one object. Feed it to the manifest and the dossier.

  Four things here are load-bearing (each was a real failure on 2026-09-05, see guide Appendix G):
    1. OpenDatabase is called as a DIRECT method call. The
       $inst.GetType().InvokeMember('OpenDatabase', ...) form - which works for most COM members - throws
       DISP_E_TYPEMISMATCH (0x80020005) against the Windows Installer automation object on some hosts.
    2. Execute/Close return $null through InvokeMember, and an unswallowed $null lands in the function's
       output. The caller then iterates over a $null and gets "cannot index into a null array" - a symptom
       that points at the loop, not at the query.
    3. Rows are returned as PSCustomObjects with NAMED columns, not as arrays of arrays. Returning nested
       arrays forces the caller into `return ,$rows` / `$_[0]` gymnastics that break silently when a table
       has exactly one row.
    4. A freshly downloaded MSI can still be locked by the on-access scanner, so OpenDatabase is retried
       briefly instead of failing the whole probe on a race.

  Every table except Property is optional: a minimal MSI has no Upgrade, Shortcut, Icon or Registry table,
  and asking for one that does not exist is an error, not an empty result. Missing tables come back empty.
.OUTPUTS
  PSCustomObject: Path, SizeBytes, Sha256, SignatureStatus, Signer, ProductCode, UpgradeCode, ProductName,
  ProductVersion, Manufacturer, Platform, Language, Properties (hashtable), Features, FeatureComponents,
  Directories, Shortcuts, Upgrades, Files, Registry, Icons, Tables
.EXAMPLE
  Get-PsadtMsiFacts.ps1 -Path .\app.msi

  Returns the facts object.
.EXAMPLE
  Get-PsadtMsiFacts.ps1 -Path .\app.msi -AsText

  Prints a readable dump of every section - the form to read when deciding how to build the package.
.EXAMPLE
  $f = Get-PsadtMsiFacts.ps1 -Path .\app.msi
  $f.Features | Where-Object { $_.Title -match 'update' }

  Finds the auto-updater feature, which is what makes ADDLOCAL possible instead of post-install cleanup.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,

    # Print a readable dump instead of returning the object.
    [switch]$AsText,

    # Regex applied to File.FileName; only matching files are listed. Default lists executables and
    # libraries, because that is what a detection rule or a cleanup step ever cares about.
    [string]$FileFilter = '\.(exe|dll|msix|appx|sys|inf)$',

    # Unused downstream; accepted so callers can pass it through.
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) { throw "MSI not found: $Path" }
$Path = (Resolve-Path -LiteralPath $Path).ProviderPath
if ([System.IO.Path]::GetExtension($Path) -notin '.msi', '.msp') {
    throw "Not an MSI/MSP file: $Path"
}

$item = Get-Item -LiteralPath $Path
$sha = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
$sig = Get-AuthenticodeSignature -LiteralPath $Path

$installer = New-Object -ComObject WindowsInstaller.Installer

# Retry: a file that finished downloading seconds ago can still be held by the on-access scanner, and the
# failure looks exactly like a malformed database.
$db = $null
$lastError = $null
foreach ($attempt in 1..5) {
    try { $db = $installer.OpenDatabase($Path, 0); break }
    catch { $lastError = $_; Start-Sleep -Milliseconds 600 }
}
if (-not $db) { throw "Could not open '$Path' as a Windows Installer database after 5 attempts: $($lastError.Exception.Message)" }

function Get-MsiTableNames {
    $names = New-Object System.Collections.Generic.List[string]
    $view = $db.OpenView('SELECT `Name` FROM `_Tables`')
    $view.Execute() | Out-Null
    while ($true) {
        $record = $view.Fetch()
        if (-not $record) { break }
        $names.Add([string]$record.StringData(1))
    }
    $view.Close() | Out-Null
    return $names
}

$tables = Get-MsiTableNames

function Get-MsiRows {
    # Returns PSCustomObjects with the requested column names. A table that does not exist yields nothing
    # rather than throwing, because most MSI tables are optional.
    param([Parameter(Mandatory)][string]$Table, [Parameter(Mandatory)][string[]]$Columns)

    if ($tables -notcontains $Table) { return @() }

    $select = ($Columns | ForEach-Object { '`' + $_ + '`' }) -join ','
    $rows = New-Object System.Collections.Generic.List[object]
    $view = $db.OpenView("SELECT $select FROM ``$Table``")
    $view.Execute() | Out-Null
    while ($true) {
        $record = $view.Fetch()
        if (-not $record) { break }
        $ordered = [ordered]@{}
        for ($i = 0; $i -lt $Columns.Count; $i++) { $ordered[$Columns[$i]] = [string]$record.StringData($i + 1) }
        $rows.Add([pscustomobject]$ordered)
    }
    $view.Close() | Out-Null
    return $rows.ToArray()
}

$properties = @{}
foreach ($row in (Get-MsiRows -Table 'Property' -Columns 'Property', 'Value')) { $properties[$row.Property] = $row.Value }

$features = Get-MsiRows -Table 'Feature' -Columns 'Feature', 'Title', 'Level', 'Attributes'
$featureComponents = Get-MsiRows -Table 'FeatureComponents' -Columns 'Feature_', 'Component_'
$featureSummary = $featureComponents | Group-Object -Property 'Feature_' | ForEach-Object {
    [pscustomobject]@{ Feature = $_.Name; ComponentCount = $_.Count; Components = @($_.Group | ForEach-Object { $_.Component_ }) }
}

$allFiles = Get-MsiRows -Table 'File' -Columns 'File', 'FileName', 'Version', 'FileSize'
$files = @($allFiles | Where-Object { $_.FileName -match $FileFilter } | ForEach-Object {
        # A short|long pair is stored as "8dot3|Long Name"; the long name is the one on disk.
        $long = if ($_.FileName -match '\|') { $_.FileName.Split('|')[-1] } else { $_.FileName }
        [pscustomobject]@{ Key = $_.File; FileName = $long; Version = $_.Version; SizeBytes = $_.FileSize }
    })

$shortcuts = @(Get-MsiRows -Table 'Shortcut' -Columns 'Shortcut', 'Directory_', 'Name', 'Target' | ForEach-Object {
        $long = if ($_.Name -match '\|') { $_.Name.Split('|')[-1] } else { $_.Name }
        [pscustomobject]@{ Shortcut = $_.Shortcut; Directory = $_.Directory_; Name = $long; Target = $_.Target }
    })

$upgrades = @(Get-MsiRows -Table 'Upgrade' -Columns 'UpgradeCode', 'VersionMin', 'VersionMax', 'Attributes', 'ActionProperty' | ForEach-Object {
        $attr = 0; [void][int]::TryParse($_.Attributes, [ref]$attr)
        $flags = @()
        # msidbUpgradeAttributes*: the two that change how a package must be built are MigrateFeatures
        # (a previously selected feature can come back past ADDLOCAL) and OnlyDetect (no removal happens).
        if ($attr -band 1) { $flags += 'MigrateFeatures' }
        if ($attr -band 2) { $flags += 'OnlyDetect' }
        if ($attr -band 4) { $flags += 'IgnoreRemoveFailure' }
        if ($attr -band 256) { $flags += 'VersionMinInclusive' }
        if ($attr -band 512) { $flags += 'VersionMaxInclusive' }
        if ($attr -band 1024) { $flags += 'LanguagesExclusive' }
        [pscustomobject]@{
            UpgradeCode = $_.UpgradeCode; VersionMin = $_.VersionMin; VersionMax = $_.VersionMax
            Attributes = $attr; Flags = $flags; ActionProperty = $_.ActionProperty
        }
    })

$directories = Get-MsiRows -Table 'Directory' -Columns 'Directory', 'Directory_Parent', 'DefaultDir'
$registry = Get-MsiRows -Table 'Registry' -Columns 'Root', 'Key', 'Name', 'Value'
$icons = @(Get-MsiRows -Table 'Icon' -Columns 'Name' | ForEach-Object { $_.Name })

$template = ''
$title = ''
try {
    $summary = $installer.SummaryInformation($Path, 0)
    $template = [string]$summary.Property(7)
    $title = [string]$summary.Property(3)
} catch {
    Write-Verbose "SummaryInformation unavailable: $($_.Exception.Message)"
}
$platform = if ($template -match '^([^;]*)') { $Matches[1] } else { '' }
$language = if ($template -match ';(.*)$') { $Matches[1] } else { '' }

$facts = [pscustomobject]@{
    Path              = $Path
    SizeBytes         = $item.Length
    Sha256            = $sha
    SignatureStatus   = [string]$sig.Status
    Signer            = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { $null }
    ProductCode       = $properties['ProductCode']
    UpgradeCode       = $properties['UpgradeCode']
    ProductName       = $properties['ProductName']
    ProductVersion    = $properties['ProductVersion']
    Manufacturer      = $properties['Manufacturer']
    AllUsers          = $properties['ALLUSERS']
    Reboot            = $properties['REBOOT']
    SecureCustomProps = $properties['SecureCustomProperties']
    Platform          = $platform
    Language          = $language
    Title             = $title
    Properties        = $properties
    Features          = $features
    FeatureComponents = $featureSummary
    Directories       = $directories
    Shortcuts         = $shortcuts
    Upgrades          = $upgrades
    Files             = $files
    Registry          = $registry
    Icons             = $icons
    Tables            = $tables
}

if (-not $AsText) { return $facts }

$w = { param($label, $value) Write-Output ("  {0,-24} {1}" -f $label, $value) }
Write-Output "=== Identity ==="
& $w 'ProductName' $facts.ProductName
& $w 'ProductVersion' $facts.ProductVersion
& $w 'Manufacturer' $facts.Manufacturer
& $w 'ProductCode' $facts.ProductCode
& $w 'UpgradeCode' $facts.UpgradeCode
& $w 'Platform / Language' "$($facts.Platform) / $($facts.Language)"
& $w 'ALLUSERS / REBOOT' "$($facts.AllUsers) / $($facts.Reboot)"
& $w 'SecureCustomProps' $facts.SecureCustomProps
& $w 'Size / SHA256' "$($facts.SizeBytes) bytes / $($facts.Sha256)"
& $w 'Signature' "$($facts.SignatureStatus) | $($facts.Signer)"

Write-Output ''
Write-Output "=== Features (Level 0 or above the INSTALLLEVEL are NOT installed by default) ==="
foreach ($f in $facts.Features) {
    $count = ($facts.FeatureComponents | Where-Object { $_.Feature -eq $f.Feature }).ComponentCount
    Write-Output ("  {0,-24} Level={1,-3} Attr={2,-4} components={3,-4} {4}" -f $f.Feature, $f.Level, $f.Attributes, $count, $f.Title)
}

Write-Output ''
Write-Output "=== Upgrade rules ==="
foreach ($u in $facts.Upgrades) {
    Write-Output ("  {0} min={1} max={2} -> {3}  [{4}]" -f $u.UpgradeCode, $u.VersionMin, $u.VersionMax, $u.ActionProperty, ($u.Flags -join ', '))
}

Write-Output ''
Write-Output "=== Shortcuts ==="
foreach ($s in $facts.Shortcuts) { Write-Output ("  {0,-22} dir={1,-22} name={2,-24} -> {3}" -f $s.Shortcut, $s.Directory, $s.Name, $s.Target) }

Write-Output ''
Write-Output "=== Directories ==="
foreach ($d in $facts.Directories) { Write-Output ("  {0,-26} parent={1,-24} {2}" -f $d.Directory, $d.Directory_Parent, $d.DefaultDir) }

Write-Output ''
Write-Output "=== Files matching '$FileFilter' ==="
foreach ($f in $facts.Files) { Write-Output ("  {0,-30} {1}" -f $f.FileName, $f.Version) }

Write-Output ''
Write-Output "=== Registry ($($facts.Registry.Count) rows) ==="
foreach ($r in $facts.Registry) { Write-Output ("  root={0} {1} | {2} = {3}" -f $r.Root, $r.Key, $r.Name, $r.Value) }

Write-Output ''
Write-Output "=== Icons (fallback source for the app logo, guide Appendix J) ==="
foreach ($i in $facts.Icons) { Write-Output ("  $i") }

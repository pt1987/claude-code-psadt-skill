<#
.SYNOPSIS  Identifies the installer technology behind a file by its DEFINITIVE fingerprint, and reports what it matched and where.
.DESCRIPTION
  Appendix L.1 carries a BINDING rule: "a single string match is a HINT, not proof". It was written after
  an install4j installer (Aperio) was identified as NSIS from a coincidental substring; the package shipped
  /S, which shows the language dialog and hangs forever. Until now that rule had no tool behind it - the
  research-trust table names a verifying script for every kind of value EXCEPT "installer engine", where it
  could only say "the definitive fingerprint from Appendix L.1, not a string match". This is that script.

  Four things here are load-bearing:
    1. Markers are classified as DEFINITIVE or HINT, and a definitive marker always wins. install4j is
       ranked ahead of NSIS and InstallShield on purpose: its parameter file is unambiguous, and being
       wrong in that direction is the expensive failure.
    2. The WHOLE file is scanned, in ONE streaming pass. Only MSI (compound-file magic at offset 0) and
       WiX Burn (a section NAME) are visible in the first pages; NSIS, Inno, InstallShield, install4j and
       the SFX formats keep their markers in the overlay or the resources, and a big vendor bootstrapper
       can carry them hundreds of megabytes in. A bounded scan cannot tell "no marker" from "did not
       look", which is the one distinction this probe exists to make. Measured: 460 MB in 1.1 s.
    3. Offsets are FILE-absolute and reported, so the answer can be re-checked instead of believed.
    4. Nothing is guessed. A file that matches no marker comes back as engine 'unknown' with empty
       evidence, which is a usable answer: it routes the caller to the probe run and the Researcher.
       A custom vendor bootstrapper - Citrix Workspace is one - legitimately lands here.

  This script decides the ENGINE. It does not decide the switch - Get-PsadtSwitchCandidates.ps1 does that,
  and the switch stays a CLAIM until a run proves it.
.OUTPUTS
  PSCustomObject: Path, SizeBytes, Sha256, Engine, Confidence (high|low|unknown), Evidence
  (Marker, Offset, Region, Kind)[], IsMsi, ProductName, ProductVersion, Publisher, FileDescription,
  SectionNames, OverlayOffset, ScannedBytes, SignatureStatus, Signer
.EXAMPLE
  Get-PsadtInstallerEngine.ps1 -Path .\Files\setup.exe

  Returns the engine object.
.EXAMPLE
  Get-PsadtInstallerEngine.ps1 -Path .\Files\setup.exe -Json

  Emits the same object as JSON, for a caller that wants to pipe it somewhere.
.NOTES
  Author: psadt-deploy
  Changelog:
    - 0.1 (2026-09-14, Patrick Taubert): first version. Region-aware fingerprinting for Appendix L.1,
      single-pass whole-file scan.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,

    # Emit JSON instead of the object.
    [switch]$Json,

    # Additionally write the JSON to this file. Preferred over -Json when stdout is inherited.
    [string]$JsonPath,

    # Hard ceiling on how much of the file is scanned. The default covers any realistic installer; it
    # exists so a pathological input cannot turn a probe into a long-running job, not to save time.
    [long]$MaxScanBytes = 4294967296,

    # Unused downstream; accepted so callers can pass it through.
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) { throw "Installer not found: $Path" }
$Path = (Resolve-Path -LiteralPath $Path).ProviderPath
$item = Get-Item -LiteralPath $Path
if ($item.PSIsContainer) { throw "Installer not found (path is a directory): $Path" }

$sha = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
$ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
$len = $item.Length

# ---------------------------------------------------------------------------------------------------
# Marker table. Priority: LOWER wins among definitive matches. install4j sits ahead of NSIS and
# InstallShield deliberately - see the Aperio incident in App. B anti-pattern 13.
# ---------------------------------------------------------------------------------------------------
$markers = @(
    @{ Engine = 'install4j'; Text = 'i4jparams.conf'; Kind = 'definitive'; Priority = 10 }
    @{ Engine = 'install4j'; Text = 'com/install4j/runtime'; Kind = 'definitive'; Priority = 11 }
    @{ Engine = 'installshield'; Text = 'ISSetupStream'; Kind = 'definitive'; Priority = 20 }
    @{ Engine = 'advanced-installer'; Text = 'aicustact.dll'; Kind = 'definitive'; Priority = 22 }
    @{ Engine = 'inno'; Text = 'Inno Setup Setup Data'; Kind = 'definitive'; Priority = 30 }
    @{ Engine = 'nsis'; Text = 'NullsoftInst'; Kind = 'definitive'; Priority = 40 }
    @{ Engine = 'bitrock'; Text = 'BitRock Installer'; Kind = 'definitive'; Priority = 45 }
    @{ Engine = 'izpack'; Text = 'com/izforge/izpack'; Kind = 'definitive'; Priority = 46 }
    @{ Engine = 'squirrel'; Text = 'Squirrel.Windows'; Kind = 'definitive'; Priority = 50 }
    @{ Engine = 'sfx-7zip'; Magic = [byte[]](0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C); Kind = 'definitive'; Priority = 60; Region = 'overlay' }
    @{ Engine = 'sfx-winrar'; Magic = [byte[]](0x52, 0x61, 0x72, 0x21, 0x1A, 0x07); Kind = 'definitive'; Priority = 61; Region = 'overlay' }

    @{ Engine = 'install4j'; Text = 'install4j'; Kind = 'hint'; Priority = 110 }
    @{ Engine = 'installshield'; Text = 'InstallShield'; Kind = 'hint'; Priority = 120 }
    @{ Engine = 'advanced-installer'; Text = 'Advanced Installer'; Kind = 'hint'; Priority = 122 }
    @{ Engine = 'inno'; Text = 'JR.Inno.Setup'; Kind = 'hint'; Priority = 130 }
    @{ Engine = 'inno'; Text = 'Inno Setup'; Kind = 'hint'; Priority = 131 }
    @{ Engine = 'nsis'; Text = 'Nullsoft.NSIS'; Kind = 'hint'; Priority = 140 }
    @{ Engine = 'nsis'; Text = 'Nullsoft Install System'; Kind = 'hint'; Priority = 141 }
    @{ Engine = 'installaware'; Text = 'InstallAware'; Kind = 'hint'; Priority = 150 }
    @{ Engine = 'wise'; Text = 'Wise Installation'; Kind = 'hint'; Priority = 151 }
    @{ Engine = 'squirrel'; Text = 'Squirrel'; Kind = 'hint'; Priority = 152 }
    @{ Engine = 'bitrock'; Text = 'BitRock'; Kind = 'hint'; Priority = 153 }
)

# Extra needles that are not engines but answer follow-up questions during refinement.
$extraNeedles = @(
    @{ Key = 'cfb'; Magic = [byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1) }
    @{ Key = 'appxmanifest'; Text = 'AppxManifest.xml' }
    @{ Key = 'electron-builder'; Text = 'electron-builder' }
)

# ---------------------------------------------------------------------------------------------------
# Needles. Latin1 maps bytes 0-255 to chars 0-255 one to one, so a byte magic and a text marker can be
# searched the same way - with String.IndexOf, which is native and orders of magnitude faster than a
# byte loop in PowerShell. Text markers are searched in BOTH encodings, because PE resources store the
# same string as ASCII or as UTF-16LE and a miss there reads as "engine unknown".
# ---------------------------------------------------------------------------------------------------
$latin1 = [System.Text.Encoding]::Latin1
$needles = New-Object System.Collections.Generic.List[object]
function Add-Needle([string]$Key, [byte[]]$Bytes) {
    $needles.Add([pscustomobject]@{ Key = $Key; Pattern = $latin1.GetString($Bytes); Length = $Bytes.Length })
}
for ($i = 0; $i -lt $markers.Count; $i++) {
    $m = $markers[$i]
    if ($m.Text) {
        Add-Needle "m$i" ([System.Text.Encoding]::ASCII.GetBytes($m.Text))
        Add-Needle "m$i" ([System.Text.Encoding]::Unicode.GetBytes($m.Text))
    }
    else { Add-Needle "m$i" $m.Magic }
}
foreach ($e in $extraNeedles) {
    if ($e.Text) {
        Add-Needle $e.Key ([System.Text.Encoding]::ASCII.GetBytes($e.Text))
        Add-Needle $e.Key ([System.Text.Encoding]::Unicode.GetBytes($e.Text))
    }
    else { Add-Needle $e.Key $e.Magic }
}

# ---------------------------------------------------------------------------------------------------
# One streaming pass over the file. Chunks overlap by the longest needle so a marker straddling a chunk
# boundary is still found; hits are recorded per key (capped, because only the first few ever matter).
# ---------------------------------------------------------------------------------------------------
$hits = @{}
$maxNeedle = ($needles | Measure-Object -Property Length -Maximum).Maximum
$overlap = [int]$maxNeedle
$chunkSize = 16777216
$head = $null
$scanned = 0L

$fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
try {
    $buffer = New-Object byte[] ($chunkSize + $overlap)
    $carry = 0
    $chunkStart = 0L
    while ($scanned -lt $MaxScanBytes) {
        $read = $fs.Read($buffer, $carry, $chunkSize)
        if ($read -le 0) { break }
        $valid = $carry + $read
        if ($null -eq $head) {
            $headLen = [Math]::Min(65536, $valid)
            $head = New-Object byte[] $headLen
            [Array]::Copy($buffer, 0, $head, 0, $headLen)
        }
        $text = $latin1.GetString($buffer, 0, $valid)
        foreach ($n in $needles) {
            $from = 0
            while ($true) {
                $idx = $text.IndexOf($n.Pattern, $from, [StringComparison]::Ordinal)
                if ($idx -lt 0) { break }
                if (-not $hits.ContainsKey($n.Key)) { $hits[$n.Key] = New-Object System.Collections.Generic.List[long] }
                if ($hits[$n.Key].Count -lt 16) { $hits[$n.Key].Add($chunkStart + $idx) }
                if ($hits[$n.Key].Count -ge 16) { break }
                $from = $idx + 1
            }
        }
        $scanned += $read
        # Carry the tail forward so the next chunk can complete a marker cut in half.
        $keep = [Math]::Min($overlap, $valid)
        [Array]::Copy($buffer, $valid - $keep, $buffer, 0, $keep)
        $chunkStart += ($valid - $keep)
        $carry = $keep
    }
}
finally { $fs.Dispose() }
if ($null -eq $head) { $head = New-Object byte[] 0 }

function Get-Hits([string]$Key) {
    if ($hits.ContainsKey($Key)) { return @($hits[$Key] | Sort-Object) }
    return @()
}

# ---------------------------------------------------------------------------------------------------
# PE navigation: section names, and where the overlay begins. Needed to label an offset's region and to
# spot WiX Burn, which announces itself in the section table rather than in the payload.
# ---------------------------------------------------------------------------------------------------
$sectionNames = @()
$sectionNameOffsets = @{}
$overlayOffset = 0L
$headersEnd = 4096L

if ($head.Length -gt 0x40 -and $head[0] -eq 0x4D -and $head[1] -eq 0x5A) {
    $peOff = [BitConverter]::ToInt32($head, 0x3C)
    if ($peOff -gt 0 -and ($peOff + 24) -lt $head.Length -and $head[$peOff] -eq 0x50 -and $head[$peOff + 1] -eq 0x45) {
        $coff = $peOff + 4
        $numSections = [BitConverter]::ToUInt16($head, $coff + 2)
        $optSize = [BitConverter]::ToUInt16($head, $coff + 16)
        $sectTable = $coff + 20 + $optSize
        if ($numSections -gt 0 -and $numSections -le 96 -and ($sectTable + (40 * $numSections)) -le $head.Length) {
            $headersEnd = [long]($sectTable + (40 * $numSections))
            for ($i = 0; $i -lt $numSections; $i++) {
                $off = $sectTable + ($i * 40)
                # The slice must be re-typed: a PowerShell range index over a byte[] yields Object[],
                # and Encoding.GetString has no Object[] overload - it fails with "argument types do
                # not match", which reads like a corrupt PE rather than a type slip.
                $raw = [byte[]]($head[$off..($off + 7)])
                $name = ([System.Text.Encoding]::ASCII.GetString($raw)).TrimEnd([char]0)
                if ($name) {
                    $sectionNames += $name
                    if (-not $sectionNameOffsets.ContainsKey($name)) { $sectionNameOffsets[$name] = [long]$off }
                }
                $sizeOfRaw = [BitConverter]::ToUInt32($head, $off + 16)
                $ptrToRaw = [BitConverter]::ToUInt32($head, $off + 20)
                if ($ptrToRaw -gt 0) {
                    $end = [long]$ptrToRaw + [long]$sizeOfRaw
                    if ($end -gt $overlayOffset) { $overlayOffset = $end }
                }
            }
        }
    }
}
if ($overlayOffset -gt $len) { $overlayOffset = 0L }

function Get-Region([long]$Offset) {
    if ($overlayOffset -gt 0 -and $Offset -ge $overlayOffset) { return 'overlay' }
    if ($Offset -lt $headersEnd) { return 'headers' }
    return 'sections'
}

$evidence = New-Object System.Collections.Generic.List[object]
$engine = 'unknown'
$confidence = 'unknown'
$isMsi = $false

# --- Container formats decide on their own, before any marker ranking. -----------------------------
$cfbHits = Get-Hits 'cfb'
$isCfbAtStart = ($cfbHits.Count -gt 0 -and $cfbHits[0] -eq 0)
$isZipAtStart = ($head.Length -ge 4 -and $head[0] -eq 0x50 -and $head[1] -eq 0x4B -and $head[2] -eq 0x03 -and $head[3] -eq 0x04)
$appxHits = Get-Hits 'appxmanifest'

if ($isCfbAtStart) {
    $engine = if ($ext -eq '.msp') { 'msp' } else { 'msi' }
    $confidence = 'high'
    $isMsi = $true
    $evidence.Add([pscustomobject]@{ Marker = 'compound-file header D0CF11E0'; Offset = 0L; Region = 'headers'; Kind = 'definitive' })
}
elseif ($isZipAtStart -and $appxHits.Count -gt 0) {
    $engine = 'msix'
    $confidence = 'high'
    $evidence.Add([pscustomobject]@{ Marker = 'zip container + AppxManifest.xml'; Offset = $appxHits[0]; Region = (Get-Region $appxHits[0]); Kind = 'definitive' })
}
else {
    $matched = New-Object System.Collections.Generic.List[object]

    # WiX Burn announces itself in the section table, not in the payload. It enters the same ranking as
    # everything else rather than short-circuiting, so that a Burn bundle carrying the markers of the
    # MSIs it wraps still resolves to Burn on priority alone.
    if ($sectionNameOffsets.ContainsKey('.wixburn')) {
        $evidence.Add([pscustomobject]@{ Marker = '.wixburn section'; Offset = $sectionNameOffsets['.wixburn']; Region = 'section-table'; Kind = 'definitive' })
        $matched.Add(@{ Engine = 'wix-burn'; Kind = 'definitive'; Priority = 25 })
    }

    for ($i = 0; $i -lt $markers.Count; $i++) {
        $m = $markers[$i]
        $offsets = Get-Hits "m$i"
        if ($m.Region) { $offsets = @($offsets | Where-Object { (Get-Region $_) -eq $m.Region }) }
        if ($offsets.Count -eq 0) { continue }
        $label = if ($m.Text) { $m.Text } else { ($m.Magic | ForEach-Object { $_.ToString('X2') }) -join '' }
        $evidence.Add([pscustomobject]@{ Marker = $label; Offset = $offsets[0]; Region = (Get-Region $offsets[0]); Kind = $m.Kind })
        $matched.Add($m)
    }

    # THE rule from App. L.1: a definitive marker beats every hint, whatever their priorities. Only
    # when nothing definitive matched does a hint get to name the engine - and then at low confidence.
    $definitiveMatches = @($matched | Where-Object { $_.Kind -eq 'definitive' })
    $chosen = if ($definitiveMatches.Count -gt 0) { @($definitiveMatches | Sort-Object { $_.Priority })[0] }
    elseif ($matched.Count -gt 0) { @($matched | Sort-Object { $_.Priority })[0] }
    else { $null }

    if ($chosen) {
        $engine = $chosen.Engine
        $confidence = if ($chosen.Kind -eq 'definitive') { 'high' } else { 'low' }
    }

    # --- Refinements that need a second look. ------------------------------------------------------
    if ($engine -eq 'installshield') {
        $isOffset = @($evidence | Where-Object { $_.Marker -eq 'ISSetupStream' } | Select-Object -First 1).Offset
        $embedded = @($cfbHits | Where-Object { $_ -gt $isOffset } | Select-Object -First 1)
        if ($embedded.Count -gt 0) {
            $engine = 'installshield-basic-msi'
            $evidence.Add([pscustomobject]@{ Marker = 'embedded MSI (compound-file header after ISSetupStream)'; Offset = $embedded[0]; Region = (Get-Region $embedded[0]); Kind = 'definitive' })
        }
        else { $engine = 'installshield-installscript' }
    }

    if ($engine -eq 'nsis') {
        $eb = Get-Hits 'electron-builder'
        if ($eb.Count -gt 0) {
            $engine = 'electron-builder'
            $evidence.Add([pscustomobject]@{ Marker = 'electron-builder'; Offset = $eb[0]; Region = (Get-Region $eb[0]); Kind = 'definitive' })
        }
    }
}

# ---------------------------------------------------------------------------------------------------
# Metadata. Best effort: a synthetic or stripped binary has none, and that is not a probe failure.
# ---------------------------------------------------------------------------------------------------
$vi = $null
try { $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path) } catch { $vi = $null }

# An MSI is a compound file, not a PE, so FileVersionInfo returns nothing for it and the identity fields
# above would all be null for a file that plainly carries a name and a version. That is not cosmetic:
# the verified-switch store keys its "earlier build of the same product" fallback on ProductName, so a
# null here makes that path unreachable for every MSI ever probed. Three properties, read from the
# database the file already is. Best effort, like the block around it.
$msiProps = @{}
if ($isMsi) {
    try {
        $inst = New-Object -ComObject WindowsInstaller.Installer
        $db = $inst.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $inst, @($Path, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db,
            @("SELECT ``Property``,``Value`` FROM ``Property`` WHERE ``Property`` = 'ProductName' OR ``Property`` = 'ProductVersion' OR ``Property`` = 'Manufacturer'"))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
        while ($true) {
            $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if (-not $rec) { break }
            $k = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(1))
            $v = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(2))
            if ($k) { $msiProps[[string]$k] = [string]$v }
        }
        $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null
    }
    catch {
        # A damaged or password-protected database is not a probe failure. The engine is already known
        # from the header; only the friendly name is missing.
        $msiProps = @{}
    }
}

function Get-Identity {
    param([string]$MsiKey, $FromVersionInfo)
    if ($msiProps.ContainsKey($MsiKey) -and $msiProps[$MsiKey]) { return $msiProps[$MsiKey] }
    if ($FromVersionInfo) { return $FromVersionInfo }
    return $null
}
$sigStatus = $null
$signer = $null
try {
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    $sigStatus = [string]$sig.Status
    if ($sig.SignerCertificate) { $signer = $sig.SignerCertificate.Subject }
}
catch { $sigStatus = 'NotChecked' }

# $evidence is materialised with ToArray(), never with @(). Wrapping an EMPTY
# System.Collections.Generic.List in the array subexpression operator throws "Argument types do not
# match" - in Windows PowerShell 5.1 and in pwsh 7 alike - and the exception surfaces at the object
# literal, pointing at whatever key happens to sit there rather than at the list. The empty case is the
# normal one here: it is exactly what an unrecognised installer returns.
$result = [pscustomobject]@{
    Path            = $Path
    SizeBytes       = $len
    Sha256          = $sha
    Engine          = $engine
    Confidence      = $confidence
    Evidence        = $evidence.ToArray()
    IsMsi           = $isMsi
    ProductName     = Get-Identity 'ProductName'    $(if ($vi) { $vi.ProductName })
    ProductVersion  = Get-Identity 'ProductVersion' $(if ($vi) { $vi.ProductVersion })
    Publisher       = Get-Identity 'Manufacturer'   $(if ($vi) { $vi.CompanyName })
    FileDescription = if ($vi) { $vi.FileDescription } else { $null }
    SectionNames    = @($sectionNames)
    OverlayOffset   = $overlayOffset
    ScannedBytes    = $scanned
    SignatureStatus = $sigStatus
    Signer          = $signer
}

if ($JsonPath) { $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonPath -Encoding UTF8 }
if ($Json) { return ($result | ConvertTo-Json -Depth 6) }
return $result

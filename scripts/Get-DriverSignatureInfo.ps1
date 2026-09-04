<#
.SYNOPSIS
    Classifies the trust situation of a driver folder (or a single .inf): can this be deployed silently?

.DESCRIPTION
    A third-party driver is the classic reason a SYSTEM-silent install stalls: Windows puts up an "install
    device software?" prompt that nobody can click. Whether that is fixable - and how - depends entirely on
    WHO signed the driver, and this script answers that before a package is built.

    Per INF: reads Class / Provider / DriverVer / CatalogFile from [Version], then checks the signature of
    the CATALOG (.cat), not the .sys. That order matters: a dual-signed .sys reports only its primary
    signature, so checking it would misclassify exactly the drivers that are hardest to get right. The
    catalog is what PnP itself validates.

    Classification per INF:
      MicrosoftSigned  the signer is 'CN=Microsoft Windows Hardware Compatibility Publisher' (WHQL or
                       Attestation) or an inbox 'CN=Microsoft Windows*'. Installs silently, nothing to do.
      VendorSigned     a valid non-Microsoft signature. USER mode: the TrustedPublisher route works (import
                       the signer cert, then the PnP prompt is gone). KERNEL mode: RED - see below.
      Unsigned         no catalog, NotSigned, or HashMismatch. Hard stop; three honest options, and
                       testsigning is not one of them.

    Why VendorSigned + kernel mode is RED and not a warning: since Windows 10 1607 (and on Windows 11),
    with Secure Boot on, the kernel loads only drivers carrying a Microsoft Dev-Portal signature.
    TrustedPublisher satisfies the PnP INSTALLATION check - it does nothing for Code Integrity. So the
    driver installs and then does not load, which looks like a working deployment and is not one.
    -AssumeSecureBootOff downgrades this to YELLOW, because in-place-upgraded machines, Secure Boot off and
    cross-signed drivers from before 2015-07-29 are real exceptions - but that is a fleet-wide decision,
    so it belongs in the manifest (driverTrust) rather than in an assumption.

.PARAMETER Path
    A folder containing driver files (searched recursively) or a single .inf.

.PARAMETER AssumeSecureBootOff
    Treat a vendor-signed kernel driver as YELLOW instead of RED. Only for a fleet where Secure Boot is
    genuinely off or the driver is legitimately cross-signed; record the reason in driverTrust.

.PARAMETER Json
    Emit the result as JSON instead of the object.

.OUTPUTS
    PSCustomObject: Overall('GREEN'|'YELLOW'|'RED'), Drivers(@{Inf,Path,Class,Provider,DriverVer,
    CatalogFile,CatalogPath,KernelMode,SignatureStatus,SignerSubject,SignerThumbprint,SignerCert,
    Classification}[]), Hints(string[]), Options(string[] - only for Unsigned), SuggestedCertOwner

.EXAMPLE
    pwsh scripts/Get-DriverSignatureInfo.ps1 -Path 'D:\src\MobotixPrinter'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$AssumeSecureBootOff,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) { throw "Path not found: $Path" }
$item = Get-Item -LiteralPath $Path

$infs = if ($item.PSIsContainer) {
    @(Get-ChildItem -LiteralPath $item.FullName -Filter '*.inf' -File -Recurse -ErrorAction SilentlyContinue)
} elseif ($item.Extension -eq '.inf') {
    @($item)
} else {
    @()
}
if (-not $infs.Count) { throw "Found no *.inf under: $Path (a driver package always has at least one)." }

# Microsoft's driver-signing identities. The first is what WHQL and Attestation signing both produce; the
# second covers drivers that ship in the box.
$MsWhqlPublisher = 'CN=Microsoft Windows Hardware Compatibility Publisher'
$MsInboxPrefix   = 'CN=Microsoft Windows'

function Get-InfValue([string[]]$Lines, [string]$Key) {
    # INF [Version] entries are 'Key=Value', case-insensitive, optionally quoted, with %tokens% resolved
    # from [Strings]. Only the keys we actually need are handled - this is not a general INF parser.
    foreach ($line in $Lines) {
        $t = $line.Trim()
        if ($t -match "^$([regex]::Escape($Key))\s*=\s*(.+)$") {
            return $Matches[1].Trim().Trim('"')
        }
    }
    return $null
}
function Resolve-InfToken([string]$Value, [string[]]$Lines) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if ($Value -notmatch '^%(.+)%$') { return $Value }
    $token = $Matches[1]
    $resolved = Get-InfValue $Lines $token
    if ($resolved) { return $resolved }
    return $Value
}

$drivers = [System.Collections.Generic.List[object]]::new()
foreach ($inf in $infs) {
    $lines = @(Get-Content -LiteralPath $inf.FullName -ErrorAction SilentlyContinue)
    $dir   = Split-Path -Parent $inf.FullName

    $class     = Resolve-InfToken (Get-InfValue $lines 'Class') $lines
    $provider  = Resolve-InfToken (Get-InfValue $lines 'Provider') $lines
    $driverVer = Get-InfValue $lines 'DriverVer'
    if ($driverVer -and $driverVer -match ',') { $driverVer = ($driverVer -split ',', 2)[1].Trim() }

    # No CatalogFile entry -> the convention is a .cat with the INF's own basename.
    $catalogFile = Get-InfValue $lines 'CatalogFile'
    if ([string]::IsNullOrWhiteSpace($catalogFile)) { $catalogFile = [IO.Path]::GetFileNameWithoutExtension($inf.Name) + '.cat' }
    $catalogPath = Join-Path $dir $catalogFile

    # Kernel mode = the package brings a .sys. That is what Code Integrity cares about.
    $kernel = [bool](@(Get-ChildItem -LiteralPath $dir -Filter '*.sys' -File -ErrorAction SilentlyContinue).Count)

    $status = 'NoCatalog'; $subject = $null; $thumb = $null; $cert = $null
    if (Test-Path -LiteralPath $catalogPath) {
        try {
            $sig = Get-AuthenticodeSignature -FilePath $catalogPath
            $status = [string]$sig.Status
            if ($sig.SignerCertificate) {
                $cert    = $sig.SignerCertificate
                $subject = [string]$sig.SignerCertificate.Subject
                $thumb   = [string]$sig.SignerCertificate.Thumbprint
            }
        } catch {
            $status = "SignatureCheckFailed: $($_.Exception.Message)"
        }
    }

    $classification =
        if ($status -ne 'Valid' -or -not $subject) { 'Unsigned' }
        elseif ($subject.StartsWith($MsWhqlPublisher, [StringComparison]::OrdinalIgnoreCase) -or
                $subject.StartsWith($MsInboxPrefix,   [StringComparison]::OrdinalIgnoreCase)) { 'MicrosoftSigned' }
        else { 'VendorSigned' }

    $drivers.Add([pscustomobject]@{
        Inf              = $inf.Name
        Path             = $inf.FullName
        Class            = $class
        Provider         = $provider
        DriverVer        = $driverVer
        CatalogFile      = $catalogFile
        CatalogPath      = if (Test-Path -LiteralPath $catalogPath) { $catalogPath } else { $null }
        KernelMode       = $kernel
        SignatureStatus  = $status
        SignerSubject    = $subject
        SignerThumbprint = $thumb
        SignerCert       = $cert
        Classification   = $classification
    })
}

# --- Verdict ---------------------------------------------------------------------------------------
$hints   = [System.Collections.Generic.List[string]]::new()
$options = @()

$unsigned     = @($drivers | Where-Object { $_.Classification -eq 'Unsigned' })
$vendorKernel = @($drivers | Where-Object { $_.Classification -eq 'VendorSigned' -and $_.KernelMode })
$vendorUser   = @($drivers | Where-Object { $_.Classification -eq 'VendorSigned' -and -not $_.KernelMode })

if ($unsigned.Count) {
    $hints.Add("$($unsigned.Count) driver(s) carry no usable signature ($(($unsigned | ForEach-Object { "$($_.Inf) [$($_.SignatureStatus)]" }) -join ', ')). This cannot be deployed: Windows will not install it silently, and no client-side setting fixes that without disabling integrity checks on every target machine.")
    # English on purpose - this text is quoted verbatim into packages and hand-offs.
    $options = @(
        'Ask the vendor for a signed driver (WHQL or Attestation-signed) - the only route that works unchanged on a managed fleet.',
        'Ask the vendor to have THIS driver Attestation-signed via the Microsoft Partner Center dashboard - fast and free for the vendor, and the result installs silently.',
        'Use it in an isolated lab only, on machines that are not part of the fleet and are never treated as trusted. The skill never enables testsigning or disables integrity checks on a production machine.'
    )
}
if ($vendorKernel.Count) {
    $msg = "$($vendorKernel.Count) KERNEL-mode driver(s) carry a valid vendor signature ($(($vendorKernel | ForEach-Object { $_.Inf }) -join ', ')). With Secure Boot on (Windows 10 1607+ / 11) the kernel loads only Microsoft Dev-Portal-signed drivers: importing the signer certificate into TrustedPublisher removes the PnP install prompt but does NOT satisfy Code Integrity, so the driver installs and then fails to load."
    if ($AssumeSecureBootOff) {
        $hints.Add("$msg -AssumeSecureBootOff was passed, so this is a warning: record WHY (Secure Boot off / in-place-upgraded fleet / cross-signed before 2015-07-29) in the manifest under driverTrust, because it is a fleet-wide decision and not an assumption this script can make for you.")
    } else {
        $hints.Add("$msg Ask the vendor for a Dev-Portal-signed driver, or pass -AssumeSecureBootOff if this fleet genuinely runs without Secure Boot and record the reason in driverTrust.")
    }
}
if ($vendorUser.Count) {
    $hints.Add("$($vendorUser.Count) user-mode driver(s) carry a valid vendor signature - the TrustedPublisher route applies: import the signer certificate (Intune policy via New-IntuneTrustedCertPolicy.ps1, or in the package's pre-install hook) and the PnP prompt is gone. Own the certificate in exactly ONE place.")
}
if (-not $unsigned.Count -and -not $vendorKernel.Count -and -not $vendorUser.Count) {
    $hints.Add('All drivers are Microsoft-signed (WHQL/Attestation or inbox) - they install silently, no certificate work needed.')
}

$overall =
    if ($unsigned.Count) { 'RED' }
    elseif ($vendorKernel.Count -and -not $AssumeSecureBootOff) { 'RED' }
    elseif ($vendorKernel.Count -or $vendorUser.Count) { 'YELLOW' }
    else { 'GREEN' }

# What New-DriverPackage.ps1 should default -CertOwner to.
$suggestedOwner =
    if ($unsigned.Count) { $null }
    elseif ($vendorKernel.Count -or $vendorUser.Count) { 'policy' }
    else { 'none' }

$result = [pscustomobject]@{
    Overall            = $overall
    Drivers            = $drivers.ToArray()
    Hints              = $hints.ToArray()
    Options            = $options
    SuggestedCertOwner = $suggestedOwner
}

if (-not $Json) {
    $color = switch ($overall) { 'GREEN' { 'Green' } 'YELLOW' { 'Yellow' } default { 'Red' } }
    Write-Host ''
    Write-Host "Driver trust - $overall" -ForegroundColor $color
    foreach ($d in $drivers) {
        $c = switch ($d.Classification) { 'MicrosoftSigned' { 'Green' } 'VendorSigned' { 'Yellow' } default { 'Red' } }
        $mode = if ($d.KernelMode) { 'kernel' } else { 'user' }
        Write-Host ("  {0,-28} {1,-16} {2,-7} {3}" -f $d.Inf, $d.Classification, $mode, ($d.Provider)) -ForegroundColor $c
    }
    foreach ($h in $hints) { Write-Host "  -> $h" -ForegroundColor Gray }
    if ($options.Count) {
        Write-Host '  Options:' -ForegroundColor Yellow
        for ($i = 0; $i -lt $options.Count; $i++) { Write-Host "    $($i + 1)) $($options[$i])" -ForegroundColor Yellow }
    }
    Write-Host ''
}
if ($Json) { $result | ConvertTo-Json -Depth 6 } else { $result }

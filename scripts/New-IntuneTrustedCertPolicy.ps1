<#
.SYNOPSIS
    Prepares (and optionally creates in the tenant) an Intune Custom OMA-URI configuration profile that places a
    certificate into a Windows machine certificate store via the RootCATrustedCertificates CSP. Read-only dry-run
    by default; -Execute creates the profile via Microsoft Graph. Always emits ready-to-paste manual portal values.

.DESCRIPTION
    The built-in Intune "Trusted certificate" template can ONLY target the Root / Intermediate (CA) stores. To put
    a cert into TrustedPublisher (e.g. to suppress the Windows "install device software?" driver prompt so an
    EXE/MSI that stages a 3rd-party driver runs fully silent), TrustedPeople, Root or CA, use the
    RootCATrustedCertificates CSP through a Custom OMA-URI profile:

        ./Device/Vendor/MSFT/RootCATrustedCertificates/<Store>/<Thumbprint>/EncodedCertificate
        Data type: String   Value: single-line base64 of the DER certificate (NO line breaks -> else 0x87d1fde8)

    This is the transparent, policy-based alternative to importing the cert from inside the install script. Own the
    cert in EXACTLY ONE place: either this policy OR the package - never both (the package would remove it on
    uninstall and the policy would re-add it on the next sync).

    Certificate source (-CertPath): a raw cert (.cer/.crt/.der/.pem) is loaded directly; a SIGNED file
    (.exe/.msi/.dll/.sys/.cat) has its Authenticode signer certificate extracted. Or pass -Thumbprint to read an
    already-installed cert from -SourceStore.

    -Execute needs the Graph application role DeviceManagementConfiguration.ReadWrite.All. Grant it to the upload app
    via: New-PsadtEntraApp.ps1 -Force -IncludeConfigurationManagement (Global Admin). If the token/role is unavailable
    the script does NOT fail the run - it prints the exact manual portal steps + values and returns them.

.PARAMETER CertPath      Path to a cert file OR a signed binary to extract the signer cert from.
.PARAMETER Thumbprint    Alternative to -CertPath: SHA1 thumbprint of an already-installed certificate.
.PARAMETER SourceStore   Where -Thumbprint lives (default Cert:\LocalMachine\TrustedPublisher).
.PARAMETER Store         Target store on the device. Root | CA | TrustedPublisher | TrustedPeople (default TrustedPublisher).
.PARAMETER ProfileName   Intune profile displayName (default derived from the cert subject + store).
.PARAMETER Execute       Create the profile via Graph. Without it the script is a read-only dry run.
.PARAMETER Interactive   Sign in interactively via WAM (delegated) instead of the app-only upload credential.
                         Use when there is no app registration (maximum compatibility). No device code.
.PARAMETER TenantId      Tenant for interactive sign-in (default: config intune.tenantId, else 'organizations').
.PARAMETER GraphToken    Optional bearer token (testing / reuse). Default: app-only Get-GraphToken.ps1.
.PARAMETER SkillRoot     Config home override; default = the resolved config home.

.OUTPUTS
    PSCustomObject: Executed, ProfileName, Store, Thumbprint, OmaUri, Base64Length, ProfileId, DryRun, ManualSteps
#>
[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')][string]$CertPath,
    [Parameter(Mandatory, ParameterSetName = 'Thumbprint')][string]$Thumbprint,
    [Parameter(ParameterSetName = 'Thumbprint')][string]$SourceStore = 'Cert:\LocalMachine\TrustedPublisher',
    [ValidateSet('Root', 'CA', 'TrustedPublisher', 'TrustedPeople')][string]$Store = 'TrustedPublisher',
    [string]$ProfileName,
    [switch]$Execute,
    [switch]$Interactive,
    [string]$TenantId,
    [string]$GraphToken,
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'
$GraphBase = 'https://graph.microsoft.com/beta'
$ConfigScope = 'https://graph.microsoft.com/DeviceManagementConfiguration.ReadWrite.All'

# --- Shared Graph helpers (Write-*, Get-GraphErr, Invoke-Graph) + WAM interactive sign-in --------
. (Join-Path $PSScriptRoot '_GraphCommon.ps1')
. (Join-Path $PSScriptRoot '_GraphInteractive.ps1')
$script:step = 0

# --- Testable helpers ----------------------------------------------------------------------------
function Get-CertFromSource {
    # Returns an X509Certificate2 from either a raw cert file or the Authenticode signer of a signed binary.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Certificate source not found: $Path" }
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -in '.cer', '.crt', '.der', '.pem') {
        return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new((Resolve-Path -LiteralPath $Path).Path)
    }
    # Signed binary (.exe/.msi/.dll/.sys/.cat/...) -> extract the signer certificate.
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if (-not $sig.SignerCertificate) { throw "No Authenticode signer certificate found in: $Path (status: $($sig.Status))" }
    return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($sig.SignerCertificate)
}

function ConvertTo-CertBase64 {
    # Single-line base64 of the DER bytes. NO line breaks - the RootCATrustedCertificates CSP rejects
    # formatted base64 with 0x87d1fde8.
    param([Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    return [System.Convert]::ToBase64String($Cert.RawData)
}

function Get-CertStoreOmaUri {
    # Builds the RootCATrustedCertificates CSP OMA-URI for a store + thumbprint.
    param(
        [Parameter(Mandatory)][ValidateSet('Root', 'CA', 'TrustedPublisher', 'TrustedPeople')][string]$Store,
        [Parameter(Mandatory)][string]$Thumbprint
    )
    $t = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    return "./Device/Vendor/MSFT/RootCATrustedCertificates/$Store/$t/EncodedCertificate"
}

function New-CustomOmaProfileBody {
    # Builds the Graph windows10CustomConfiguration request body for one EncodedCertificate OMA setting.
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$OmaUri,
        [Parameter(Mandatory)][string]$Base64Value
    )
    return [ordered]@{
        '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'
        displayName   = $DisplayName
        description   = $Description
        omaSettings   = @(
            [ordered]@{
                '@odata.type' = '#microsoft.graph.omaSettingString'
                displayName   = $DisplayName
                omaUri        = $OmaUri
                value         = $Base64Value
            }
        )
    }
}

function Get-CertPolicyManualSteps {
    # Ready-to-paste portal instructions (the Graph-unavailable fallback).
    param([string]$ProfileName, [string]$OmaUri, [int]$Base64Length, [string]$Subject)
    return @"
Manual creation (Intune portal) - if Graph is unavailable or the app lacks DeviceManagementConfiguration.ReadWrite.All:
  1. Devices > Configuration > Create > New policy
       Platform = Windows 10 and later ; Profile type = Templates > Custom
  2. Name: $ProfileName
  3. Add an OMA-URI setting:
       Name      = $ProfileName
       OMA-URI   = $OmaUri
       Data type = String
       Value     = the single-line base64 of '$Subject' ($Base64Length chars, NO line breaks)
                   (see the EncodedCertificate value printed above / the exported .b64 file)
  4. Assign to the SAME device scope as the app, then Create.
Note: the built-in 'Trusted certificate' template canNOT target this store - the Custom OMA-URI route is required.
"@
}

# --- Resolve the certificate ---------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Thumbprint') {
    $t = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    $cert = Get-ChildItem -Path $SourceStore -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $t } | Select-Object -First 1
    if (-not $cert) { throw "No certificate with thumbprint $t found in $SourceStore." }
} else {
    $cert = Get-CertFromSource -Path $CertPath
}

$thumb  = $cert.Thumbprint.ToUpperInvariant()
$b64    = ConvertTo-CertBase64 -Cert $cert
$omaUri = Get-CertStoreOmaUri -Store $Store -Thumbprint $thumb
$subjectCN = ($cert.Subject -split ',')[0]
if (-not $ProfileName) { $ProfileName = "Cert - $($subjectCN -replace '^CN=','') -> $Store" }
$description = "PSADT skill: $subjectCN into LocalMachine\$Store via RootCATrustedCertificates CSP. Thumbprint $thumb."
$manual = Get-CertPolicyManualSteps -ProfileName $ProfileName -OmaUri $omaUri -Base64Length $b64.Length -Subject $subjectCN

Write-Host "Intune TrustedPublisher/cert policy (Custom OMA-URI)" -ForegroundColor White
Write-Info "Cert    : $subjectCN"
Write-Info "Thumb   : $thumb (expires $($cert.NotAfter.ToString('yyyy-MM-dd')))"
Write-Info "Store   : $Store"
Write-Info "OMA-URI : $omaUri"
Write-Info "Value   : <base64 EncodedCertificate, $($b64.Length) chars, single line>"

$profileId = $null
if (-not $Execute) {
    Write-Host "`n--- DRY RUN (read-only). Re-run with -Execute to create the profile via Graph. ---" -ForegroundColor Yellow
    Write-Host $manual -ForegroundColor Gray
} else {
    Write-Step "Creating Custom OMA-URI profile '$ProfileName' via Graph"
    $token = $null
    try {
        if ($GraphToken) {
            $token = $GraphToken
        } elseif ($Interactive) {
            # WAM (delegated) sign-in - works with no app registration. Tenant from config if not passed.
            $tenant = $TenantId
            if (-not $tenant) {
                try { $tenant = (& (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1') -SkillRoot $SkillRoot).Config.intune.tenantId } catch { }
            }
            if (-not $tenant) { $tenant = 'organizations' }
            $token = Get-InteractiveGraphToken -Scopes @($ConfigScope) -TenantId $tenant
        } else {
            $token = (& (Join-Path $PSScriptRoot 'Get-GraphToken.ps1') -SkillRoot $SkillRoot).Token
        }
    } catch {
        Write-Warn2 "No Graph token ($($_.Exception.Message)). Falling back to manual instructions."
    }

    if ($token) {
        $H = @{ Authorization = "Bearer $token" }
        $body = New-CustomOmaProfileBody -DisplayName $ProfileName -Description $description -OmaUri $omaUri -Base64Value $b64
        try {
            $created = Invoke-Graph POST "$GraphBase/deviceManagement/deviceConfigurations" -Headers $H -Body $body
            $profileId = $created.id
            Write-Ok "Profile created ($profileId). Assign it to the app's device scope in the portal (or via assignments API)."
        } catch {
            $e = Get-GraphErr $_
            if ($e.code -match 'Authorization|Forbidden' -or "$($e.message)" -match 'privile|permission|scope') {
                Write-Warn2 "Graph denied profile creation ($($e.code)). The upload app lacks DeviceManagementConfiguration.ReadWrite.All."
                Write-Info  "Grant it (Global Admin): New-PsadtEntraApp.ps1 -Force -IncludeConfigurationManagement"
                Write-Info  "  - or sign in interactively (no app needed): re-run this script with -Interactive"
                Write-Info  "  - or create the profile manually:"
                Write-Host $manual -ForegroundColor Gray
            } else { throw }
        }
    } else {
        Write-Host $manual -ForegroundColor Gray
    }
}

[pscustomobject]@{
    Executed     = [bool]$Execute -and $null -ne $profileId
    ProfileName  = $ProfileName
    Store        = $Store
    Thumbprint   = $thumb
    OmaUri       = $omaUri
    Base64Length = $b64.Length
    ProfileId    = $profileId
    DryRun       = (-not $Execute)
    ManualSteps  = $manual
}

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

    SELF-CONTAINED (0.22.0): this script dot-sources nothing and reads no config, because it is one of the
    deliverables that gets copied to a test client which has no skill installed. Console helpers and the WAM
    sign-in are embedded (mirroring New-IntuneFirewallPolicy.ps1; a test asserts the two copies match). Credentials
    come in from outside: -Interactive for WAM, or -GraphToken (& scripts/Get-GraphToken.ps1).Token for app-only
    from the authoring machine.

.PARAMETER CertPath      Path to a cert file OR a signed binary to extract the signer cert from.
.PARAMETER Thumbprint    Alternative to -CertPath: SHA1 thumbprint of an already-installed certificate.
.PARAMETER SourceStore   Where -Thumbprint lives (default Cert:\LocalMachine\TrustedPublisher).
.PARAMETER Store         Target store on the device. Root | CA | TrustedPublisher | TrustedPeople (default TrustedPublisher).
.PARAMETER ProfileName   Intune profile displayName (default derived from the cert subject + store).
.PARAMETER Execute       Create the profile via Graph. Without it the script is a read-only dry run.
.PARAMETER Interactive   Sign in interactively via WAM (delegated) instead of the app-only upload credential.
                         Use when there is no app registration (maximum compatibility). No device code.
.PARAMETER TenantId      Tenant for interactive sign-in (default 'organizations').
.PARAMETER GraphToken    Bearer token for -Execute. From the authoring machine: (& scripts/Get-GraphToken.ps1).Token
.PARAMETER SkillRoot     Accepted for call-site compatibility and UNUSED: this script reads no config.

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

# --- Console + sign-in helpers, EMBEDDED on purpose ----------------------------------------------
# This script gets copied to test clients that do not have the skill installed, so it dot-sources
# NOTHING. The block below mirrors New-IntuneFirewallPolicy.ps1 - a drift test compares them.

# --- console helpers (embedded) ------------------------------------------------------------------
function Write-Info([string]$m) { Write-Host "    $m" -ForegroundColor Gray }
function Write-Warn2([string]$m) { Write-Host "    !   $m" -ForegroundColor Yellow }

# ============================ WAM interactive sign-in (embedded, self-contained) ============================
$script:MsalVersions  = @{ Client = '4.66.2'; Broker = '4.66.2'; Native = '0.16.2'; Abstractions = '6.35.0' }
$script:MsalCacheRoot = Join-Path $env:LOCALAPPDATA 'PsadtIntune\msal'
$script:MsalReady = $false

function Save-NuGetPackage {
    param([string]$Id, [string]$Version, [string]$DestDir)
    $idl = $Id.ToLower(); $verl = $Version.ToLower()
    $url = "https://api.nuget.org/v3-flatcontainer/$idl/$verl/$idl.$verl.nupkg"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "$idl.$verl.nupkg"
    Write-Info "downloading $Id $Version ..."
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $DestDir) { Remove-Item $DestDir -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($tmp, $DestDir)
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}
function Get-PackageDir {
    param([string]$Id, [string]$Version, [string]$LocalRoot)
    $global = Join-Path $env:USERPROFILE ".nuget\packages\$Id\$Version"
    if (Test-Path $global) { return $global }
    $local = Join-Path $LocalRoot "$Id\$Version"
    if ((Test-Path $local) -and (Get-ChildItem $local -ErrorAction SilentlyContinue)) { return $local }
    Save-NuGetPackage -Id $Id -Version $Version -DestDir $local
    return $local
}
function Initialize-MsalBroker {
    param([hashtable]$Versions = $script:MsalVersions, [string]$CacheRoot = $script:MsalCacheRoot)
    if ($script:MsalReady) { return $true }
    if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        throw "WAM is only available on Windows."
    }
    $isCore = $PSVersionTable.PSEdition -eq 'Core'
    $clientTfm = if ($isCore) { 'net6.0' }        else { 'net462' }
    $brokerTfm = if ($isCore) { 'netstandard2.0' } else { 'net462' }
    $nativeTfm = if ($isCore) { 'netstandard2.0' } else { 'net461' }
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture) {
        'Arm64' { 'win-arm64' } 'X86' { 'win-x86' } default { 'win-x64' }
    }
    $clientVer = $Versions.Client
    $cb = Join-Path $env:USERPROFILE ".nuget\packages\microsoft.identity.client"
    if (-not (Test-Path (Join-Path $cb $clientVer)) -and (Test-Path $cb)) {
        $newer = Get-ChildItem $cb -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '4.66.*' -and (Test-Path (Join-Path $_.FullName "lib\$clientTfm\Microsoft.Identity.Client.dll")) } |
            Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
        if ($newer) { $clientVer = $newer.Name }
    }
    $abstrDll  = Join-Path (Get-PackageDir 'microsoft.identitymodel.abstractions'    $Versions.Abstractions $CacheRoot) "lib\$clientTfm\Microsoft.IdentityModel.Abstractions.dll"
    $clientDll = Join-Path (Get-PackageDir 'microsoft.identity.client'              $clientVer        $CacheRoot) "lib\$clientTfm\Microsoft.Identity.Client.dll"
    $brokerDll = Join-Path (Get-PackageDir 'microsoft.identity.client.broker'       $Versions.Broker  $CacheRoot) "lib\$brokerTfm\Microsoft.Identity.Client.Broker.dll"
    $nativePkg =           (Get-PackageDir 'microsoft.identity.client.nativeinterop' $Versions.Native  $CacheRoot)
    $nativeMgr = Join-Path $nativePkg "lib\$nativeTfm\Microsoft.Identity.Client.NativeInterop.dll"
    $nativeRun = Join-Path $nativePkg "runtimes\$arch\native"
    foreach ($f in @($abstrDll, $clientDll, $brokerDll, $nativeMgr)) {
        if (-not (Test-Path $f)) { throw "MSAL assembly not found: $f" }
    }
    if (-not (Test-Path $nativeRun)) { throw "MSAL native runtime folder not found: $nativeRun" }
    $runDir = Join-Path $CacheRoot "native\$arch"
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    Get-ChildItem $nativeRun -Filter 'msalruntime*.dll' | ForEach-Object { Copy-Item $_.FullName (Join-Path $runDir $_.Name) -Force }
    if (-not (Test-Path (Join-Path $runDir 'msalruntime.dll'))) {
        $alt = Get-ChildItem $runDir -Filter 'msalruntime*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($alt) { Copy-Item $alt.FullName (Join-Path $runDir 'msalruntime.dll') -Force }
    }
    if ($env:PATH -notlike "*$runDir*") { $env:PATH = "$runDir;$env:PATH" }
    [System.Reflection.Assembly]::LoadFrom($abstrDll)  | Out-Null
    [System.Reflection.Assembly]::LoadFrom($clientDll) | Out-Null
    [System.Reflection.Assembly]::LoadFrom($nativeMgr) | Out-Null
    [System.Reflection.Assembly]::LoadFrom($brokerDll) | Out-Null
    if (-not ([System.Management.Automation.PSTypeName]'PsadtNative.Win').Type) {
        Add-Type -Namespace PsadtNative -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]   public static extern System.IntPtr GetForegroundWindow();
'@
    }
    $script:MsalReady = $true
    return $true
}

# --- Embedded role assertion (kept LOCAL on purpose: this script must stay self-contained) -----------
function Get-InteractiveGraphToken {
    param([string[]]$Scopes = @($ConfigScope), [string]$TenantId = 'organizations', [string]$ClientId = $GraphCliClientId)
    Initialize-MsalBroker | Out-Null
    Write-Info "Interactive sign-in: WAM (Windows Web Account Manager)."
    $authority = "https://login.microsoftonline.com/$TenantId"
    $builder = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create($ClientId).WithAuthority($authority)
    $bo = New-Object 'Microsoft.Identity.Client.BrokerOptions' -ArgumentList ([Microsoft.Identity.Client.BrokerOptions+OperatingSystems]::Windows)
    $builder = [Microsoft.Identity.Client.Broker.BrokerExtension]::WithBroker($builder, $bo)
    $pca = $builder.Build()
    $hwnd = [PsadtNative.Win]::GetConsoleWindow()
    if ($hwnd -eq [System.IntPtr]::Zero) { $hwnd = [PsadtNative.Win]::GetForegroundWindow() }
    Write-Host "    A Windows sign-in window (Web Account Manager) will open ..." -ForegroundColor Gray
    $req = $pca.AcquireTokenInteractive([string[]]$Scopes).WithParentActivityOrWindow($hwnd).WithPrompt([Microsoft.Identity.Client.Prompt]::SelectAccount)
    return $req.ExecuteAsync().GetAwaiter().GetResult().AccessToken
}

# --- Graph error text (embedded; PS5.1 + PS7 response shapes) --------------------------------------
function Get-GraphErrText($err) {
    # PS7 puts the response body in ErrorDetails.Message; PS5.1 needs the response stream. Returns the
    # Graph error message when it can be parsed, otherwise the raw exception text.
    $body = $null
    if ($err.ErrorDetails -and $err.ErrorDetails.Message) { $body = [string]$err.ErrorDetails.Message }
    elseif ($err.Exception.Response -is [System.Net.HttpWebResponse]) {
        try { $body = (New-Object System.IO.StreamReader($err.Exception.Response.GetResponseStream())).ReadToEnd() } catch { }
    }
    if ($body) {
        try { $e = (ConvertFrom-Json $body).error; if ($e.message) { return "$($e.code): $($e.message)" } } catch { }
        return $body
    }
    return $err.Exception.Message
}

# --- Step/status helpers (embedded) ---------------------------------------------------------------
function Write-Step([string]$m) { if ($null -eq $script:step) { $script:step = 0 }; $script:step++; Write-Host "`n[$script:step] $m" -ForegroundColor Cyan }
function Write-Ok  ([string]$m) { Write-Host "    OK  $m" -ForegroundColor Green }
function Write-Fail([string]$m) { Write-Host "    X   $m" -ForegroundColor Red }

# --- Embedded role assertion (kept LOCAL on purpose: this script must stay self-contained) -----------
function Assert-ConfigRole([string]$Token) {
    # An app-only token carries its granted roles in the 'roles' claim, so the missing permission can be
    # named BEFORE the first write instead of surfacing as a 403 afterwards - and it costs no request.
    # Graph tokens are opaque by contract: anything undecodable, and any token without a roles claim
    # (delegated -Interactive sign-in, whose Intune RBAC is not in the token at all), falls through and
    # lets Graph decide.
    $role = 'DeviceManagementConfiguration.ReadWrite.All'
    try {
        $p = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
    } catch { return }
    $roles = if ($null -eq $claims.roles) { @() } else { @($claims.roles) }
    if ($roles.Count -eq 0 -or $roles -contains $role) { return }
    throw "The app-only token has no '$role', so this policy cannot be created (it has: $($roles -join ', ')). Run New-PsadtEntraApp.ps1 -IncludeConfigurationManagement as Global Admin, or re-run with -Interactive."
}
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
            # App-only from the authoring machine:
            #   -GraphToken (& scripts/Get-GraphToken.ps1).Token
            # Passed IN rather than fetched here, because this script also runs on clients that have no
            # skill config and no sibling scripts.
            $token = $GraphToken
        } elseif ($Interactive) {
            # WAM (delegated) sign-in - works with no app registration at all.
            $tenant = if ($TenantId) { $TenantId } else { 'organizations' }
            $token = Get-InteractiveGraphToken -Scopes @($ConfigScope) -TenantId $tenant
        } else {
            Write-Warn2 "No credential: this self-contained script reads no config. Re-run with -Interactive (WAM), or pass -GraphToken (& scripts/Get-GraphToken.ps1).Token from the authoring machine."
        }
    } catch {
        Write-Warn2 "No Graph token ($($_.Exception.Message)). Falling back to manual instructions."
    }

    if ($token) {
        Assert-ConfigRole $token
        $H = @{ Authorization = "Bearer $token" }
        $body = New-CustomOmaProfileBody -DisplayName $ProfileName -Description $description -OmaUri $omaUri -Base64Value $b64
        try {
            # Raw Invoke-RestMethod, like the firewall script: one POST needs no retry wrapper, and a
            # wrapper would be one more thing to embed.
            $created = Invoke-RestMethod -Method Post -Uri "$GraphBase/deviceManagement/deviceConfigurations" `
                -Headers $H -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 20) -ErrorAction Stop
            $profileId = $created.id
            Write-Ok "Profile created ($profileId). Assign it to the app's device scope in the portal (or via assignments API)."
        } catch {
            $errText = Get-GraphErrText $_
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            if ($status -eq 403 -or $status -eq 401 -or $errText -match 'Authorization|Forbidden|privile|permission|scope') {
                Write-Warn2 "Graph denied profile creation ($errText). The app lacks DeviceManagementConfiguration.ReadWrite.All."
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

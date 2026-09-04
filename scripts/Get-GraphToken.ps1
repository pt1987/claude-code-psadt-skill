<#
.SYNOPSIS
    Acquires an app-only (client-credentials) Microsoft Graph token for the configured tenant/client.

.DESCRIPTION
    Reads intune.tenantId / intune.clientId from config.json and authenticates using whichever credential
    is configured: if intune.certThumbprint is present the cert in Cert:\CurrentUser\My is used to sign a
    JWT client assertion (RFC 7523); otherwise the DPAPI-stored client secret (intune.secretRef, default
    secret.dpapi) is decrypted IN-MEMORY ONLY - the plaintext is never written back, never logged, and is
    zeroed from unmanaged memory immediately after the token request. Returns
    { Token, ExpiresOn, TenantId, ClientId }.

.PARAMETER SkillRoot
    Config home override (folder with config.json + secret.dpapi). Default empty = resolved home.

.OUTPUTS
    PSCustomObject: Token(string), ExpiresOn(datetime), TenantId(string), ClientId(string)
#>
[CmdletBinding()]
param([string]$SkillRoot)

$ErrorActionPreference = 'Stop'

$probe = & (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1') -SkillRoot $SkillRoot
$cfg = $probe.Config
if (-not $cfg.intune) { throw "config.json has no 'intune' block - run New-PsadtEntraApp.ps1 first." }
$tenantId = $cfg.intune.tenantId
$clientId = $cfg.intune.clientId
if ([string]::IsNullOrWhiteSpace($tenantId) -or [string]::IsNullOrWhiteSpace($clientId)) {
    throw "intune.tenantId / intune.clientId missing in config.json."
}

$resp = $null

if (-not [string]::IsNullOrWhiteSpace([string]$cfg.intune.certThumbprint)) {
    # --- Certificate path (RFC 7523 signed JWT client assertion) ---
    $thumbprint = [string]$cfg.intune.certThumbprint
    $cert = Get-Item "Cert:\CurrentUser\My\$thumbprint" -ErrorAction SilentlyContinue
    if (-not $cert) { throw "Certificate Cert:\CurrentUser\My\$thumbprint not found. Re-run New-PsadtEntraApp.ps1 or restore the cert." }

    $now = [DateTimeOffset]::UtcNow
    $thumbBytes = [byte[]]::new(20)
    for ($i = 0; $i -lt 40; $i += 2) { $thumbBytes[$i / 2] = [Convert]::ToByte($thumbprint.Substring($i, 2), 16) }

    function ConvertTo-B64Url([string]$json) {
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
    $x5t = [Convert]::ToBase64String($thumbBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $hdr = ConvertTo-B64Url (([ordered]@{ alg = 'RS256'; typ = 'JWT'; x5t = $x5t } | ConvertTo-Json -Compress))
    $pay = ConvertTo-B64Url (([ordered]@{
        aud = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
        iss = $clientId; sub = $clientId
        jti = [guid]::NewGuid().ToString()
        nbf = [Int64]$now.ToUnixTimeSeconds()
        iat = [Int64]$now.ToUnixTimeSeconds()
        exp = [Int64]$now.AddMinutes(5).ToUnixTimeSeconds()
    } | ConvertTo-Json -Compress))
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    if (-not $rsa) { throw "Certificate Cert:\CurrentUser\My\$thumbprint has no usable RSA private key - cannot sign the client assertion." }
    try {
        $sigBytes = $rsa.SignData([Text.Encoding]::UTF8.GetBytes("$hdr.$pay"),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally { $rsa.Dispose() }
    $assertion = "$hdr.$pay.$([Convert]::ToBase64String($sigBytes).TrimEnd('=').Replace('+','-').Replace('/','_'))"

    $resp = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body @{
        client_id             = $clientId
        scope                 = 'https://graph.microsoft.com/.default'
        grant_type            = 'client_credentials'
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = $assertion
    } -ErrorAction Stop

} else {
    # --- DPAPI client secret path ---
    $secretRef = if ($cfg.intune.secretRef) { $cfg.intune.secretRef } else { 'secret.dpapi' }
    $secretPath = Join-Path $probe.Home $secretRef
    if (-not (Test-Path $secretPath)) { throw "Encrypted secret not found: $secretPath (run New-PsadtEntraApp.ps1)." }

    $secure = ConvertTo-SecureString (Get-Content $secretPath -Raw)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $resp = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body @{
            client_id     = $clientId
            scope         = 'https://graph.microsoft.com/.default'
            grant_type    = 'client_credentials'
            client_secret = $plain
        } -ErrorAction Stop
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $plain = $null
    }
}

[pscustomobject]@{
    Token     = $resp.access_token
    ExpiresOn = (Get-Date).AddSeconds([int]$resp.expires_in)
    TenantId  = $tenantId
    ClientId  = $clientId
}

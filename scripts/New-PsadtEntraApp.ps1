<#
.SYNOPSIS
    One-time bootstrap of the Entra app registration used for direct Intune upload.

.DESCRIPTION
    Runs interactively against Microsoft Graph and, in a single pass:
      1. signs the admin in via the well-known "Microsoft Graph Command Line Tools" public client.
         By default it uses WAM (the Windows Web Account Manager broker) so the native Windows sign-in
         window appears and SSO / a Primary Refresh Token can be reused - no code to type on a phone.
         WAM needs the MSAL.NET broker assemblies; the script auto-locates them (global NuGet cache /
         downloaded once to %LOCALAPPDATA%\PsadtIntune\msal). If WAM cannot run (non-Windows, no broker,
         MSAL unavailable) it falls back to the device-code flow. Force device code with -UseDeviceCode.
      2. creates the app registration "PSADT Intune Upload" + its service principal,
      3. grants the application permission DeviceManagementApps.ReadWrite.All and admin-consents it
         (the appRoleAssignment IS the consent - no separate portal click). Optional add-on permissions:
         -IncludeGroupManagement (Group.Create + GroupMember.Read.All) and -IncludeConfigurationManagement
         (DeviceManagementConfiguration.ReadWrite.All, for firewall/config policies),
      4. creates a client secret (returned once),
      5. writes intune.tenantId / clientId / uploadEnabled to config.json and DPAPI-stores the secret
         via Set-PsadtConfig.ps1 - the secret is never printed and never typed by hand.

    Requirement: the signed-in user must be able to create an app AND grant admin consent - i.e.
    Global Administrator or Privileged Role Administrator. Application Administrator alone cannot perform
    the consent step; the script detects that and points to the manual fallback (references/app-registration.md).

    Runs on Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER SkillRoot
    Skill root (folder containing scripts/ and config.json). Defaults to the parent of this script.

.PARAMETER TenantId
    Optional tenant id or domain to sign in against. Default 'organizations' - the real tenant id is then
    read from the issued token and stored. Pass this if your account can access several tenants.

.PARAMETER SecretValidMonths
    Lifetime of the generated client secret, in months. Default 12.

.PARAMETER Force
    If an app named "PSADT Intune Upload" already exists, reuse it without prompting (a fresh secret is
    still created).

.PARAMETER UseDeviceCode
    Skip WAM and sign in with the device-code flow instead. Useful on machines without the Windows broker
    (e.g. some Server Core / non-interactive hosts) or to avoid the one-time MSAL download.

.OUTPUTS
    PSCustomObject: TenantId, ClientId, AppObjectId, ConsentGranted(bool), SecretExpires(datetime), ConfigPath.

.EXAMPLE
    pwsh scripts/New-PsadtEntraApp.ps1
.EXAMPLE
    powershell -File scripts/New-PsadtEntraApp.ps1 -TenantId contoso.onmicrosoft.com -SecretValidMonths 24
#>
[CmdletBinding()]
param(
    [string]$SkillRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$TenantId = 'organizations',
    [ValidateRange(1, 24)][int]$SecretValidMonths = 12,
    [switch]$Force,
    [switch]$UseDeviceCode,
    # Add the least-privilege group-management permissions (Group.Create + GroupMember.Read.All) so the app can
    # find/create Entra groups for assignment (Invoke-IntuneAppAssignment.ps1). Off by default - opt in only when
    # you want the skill to manage assignment groups. Group.Create lets the app create groups it then OWNS; it is
    # NOT the tenant-wide Group.ReadWrite.All.
    [switch]$IncludeGroupManagement,
    # Add DeviceManagementConfiguration.ReadWrite.All so the app can create/manage Intune device-configuration
    # & Endpoint Security policies app-only (e.g. firewall-rule policies, or the trusted-certificate /
    # driver-trust policy via New-IntuneTrustedCertPolicy.ps1). Off by default - opt in only when you want
    # the skill to manage device-configuration / firewall / certificate policies.
    [switch]$IncludeConfigurationManagement,
    # Certificate-based auth (preferred over client secret): pass the thumbprint of a cert already in
    # Cert:\CurrentUser\My. The cert's public key is uploaded to the app; no client secret is created.
    [switch]$UseCertificate,
    [string]$CertThumbprint
)

$ErrorActionPreference = 'Stop'

# Validate cert early (fail before any network calls)
$certObj = $null
if ($UseCertificate) {
    if ([string]::IsNullOrWhiteSpace($CertThumbprint)) {
        throw "-CertThumbprint is required with -UseCertificate. List available certs: Get-ChildItem Cert:\CurrentUser\My | Select Subject,Thumbprint,NotAfter"
    }
    $certObj = Get-Item "Cert:\CurrentUser\My\$CertThumbprint" -ErrorAction SilentlyContinue
    if (-not $certObj) { throw "Certificate not found: Cert:\CurrentUser\My\$CertThumbprint" }
    if ($certObj.NotAfter -lt (Get-Date)) { throw "Certificate has expired ($($certObj.NotAfter.ToString('yyyy-MM-dd'))). Create a new cert." }
    if (-not $certObj.HasPrivateKey) { throw "Certificate Cert:\CurrentUser\My\$CertThumbprint has no private key - cannot sign client assertions." }
}

# --- Constants ---------------------------------------------------------------------------------------
$AppDisplayName = 'PSADT Intune Upload'                       # fixed by design
$DeviceCodeClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'  # "Microsoft Graph Command Line Tools" (public)
$GraphResourceAppId = '00000003-0000-0000-c000-000000000000'  # Microsoft Graph
$RequiredAppRoles = @('DeviceManagementApps.ReadWrite.All')
if ($IncludeGroupManagement) { $RequiredAppRoles += @('Group.Create', 'GroupMember.Read.All') }
if ($IncludeConfigurationManagement) { $RequiredAppRoles += @('DeviceManagementConfiguration.ReadWrite.All') }
$Scopes = 'Application.ReadWrite.All AppRoleAssignment.ReadWrite.All offline_access openid profile'
$GraphBase = 'https://graph.microsoft.com/v1.0'

# WAM (Windows broker) is the preferred interactive sign-in; device code is the fallback.
# MSAL adds the reserved OIDC scopes (openid/profile/offline_access) itself - passing them here is
# unnecessary and can trip MSAL's reserved-scope validation. This one-shot bootstrap uses the token
# immediately and needs no refresh token. (Verified: WAM sign-in works without offline_access.)
$WamScopes = @(
    'https://graph.microsoft.com/Application.ReadWrite.All'
    'https://graph.microsoft.com/AppRoleAssignment.ReadWrite.All'
)
# --- Shared Graph helpers (Write-*, Get-GraphErr, Invoke-Graph; retry + PS7-safe) --------------------
# This script keeps its own Invoke-WithRetry below (replication-lag retries, a different concern from the
# shared HTTP-transient retry inside Invoke-Graph). _GraphInteractive provides the shared WAM sign-in
# (Initialize-MsalBroker / Get-WamToken / Get-InteractiveGraphToken + the pinned MSAL version set).
. (Join-Path $PSScriptRoot '_GraphCommon.ps1')
. (Join-Path $PSScriptRoot '_GraphInteractive.ps1')
$script:step = 0

function ConvertFrom-JwtPayload([string]$jwt) {
    $payload = $jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}

# --- Device-code sign-in -----------------------------------------------------------------------------
function Get-DeviceCodeToken([string]$Tenant, [string]$Scope) {
    $authority = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0"
    $dc = Invoke-RestMethod -Method Post -Uri "$authority/devicecode" -Body @{
        client_id = $DeviceCodeClientId; scope = $Scope
    } -ErrorAction Stop

    Write-Host ""
    Write-Host "    To sign in, open: " -NoNewline; Write-Host $dc.verification_uri -ForegroundColor White
    Write-Host "    Enter code:       " -NoNewline; Write-Host $dc.user_code -ForegroundColor White
    Write-Host "    (waiting for you to complete sign-in and consent in the browser ...)" -ForegroundColor Gray

    $interval = [int]$dc.interval; if ($interval -lt 1) { $interval = 5 }
    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            return Invoke-RestMethod -Method Post -Uri "$authority/token" -Body @{
                grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
                client_id  = $DeviceCodeClientId
                device_code = $dc.device_code
            } -ErrorAction Stop
        } catch {
            # OAuth token endpoint errors return { "error": "<string>", "error_description": "..." }
            # so Get-GraphErr returns the string directly (not a .code/.message object).
            $e = Get-GraphErr $_
            $eCode = if ($e -is [string]) { $e } else { [string]$e.error }
            switch ($eCode) {
                'authorization_pending'  { continue }
                'slow_down'              { $interval += 5; continue }
                'authorization_declined' { throw "Sign-in was declined in the browser." }
                'expired_token'          { throw "The device code expired before sign-in completed. Re-run the script." }
                default                  { if ($eCode -match 'pending') { continue }; throw ($e | Out-String) }
            }
        }
    }
    throw "Timed out waiting for sign-in."
}

# WAM (Windows broker) sign-in - Initialize-MsalBroker / Get-WamToken / Get-InteractiveGraphToken + the
# pinned MSAL version set - is provided by the shared _GraphInteractive.ps1 (dot-sourced above).

# Pick WAM, fall back to device code. Returns an object exposing .access_token (a Graph JWT).
function Get-AdminToken {
    if (-not $UseDeviceCode) {
        try {
            Initialize-MsalBroker | Out-Null
            Write-Info "Sign-in method: WAM (Windows Web Account Manager)."
            return Get-WamToken -Tenant $TenantId -GraphScopes $WamScopes -ClientId $DeviceCodeClientId
        } catch {
            Write-Warn2 "WAM sign-in unavailable: $($_.Exception.Message)"
            Write-Info  "Falling back to device-code sign-in."
        }
    }
    Write-Info "Sign-in method: device code."
    return Get-DeviceCodeToken -Tenant $TenantId -Scope $Scopes
}

# --- Retry wrapper for replication lag (new SP not yet visible) --------------------------------------
function Invoke-WithRetry([scriptblock]$Action, [int]$Tries = 6, [int]$DelaySec = 5) {
    for ($i = 1; $i -le $Tries; $i++) {
        try { return & $Action }
        catch {
            $e = Get-GraphErr $_
            # NOTE the parentheses: -in binds tighter than -and, so without them the array literal makes
            # this an always-truthy expression (it would retry EVERY error, including real denials).
            $transient = (($e.code -in @('Request_ResourceNotFound', 'ResourceNotFound', 'Authorization_RequestDenied')) -and ($i -lt $Tries))
            if (-not $transient) { throw }
            Write-Info "  ... not replicated yet ($($e.code)), retry $i/$Tries in ${DelaySec}s"
            Start-Sleep -Seconds $DelaySec
        }
    }
}

# =====================================================================================================
Write-Host "PSADT Intune upload - Entra app bootstrap" -ForegroundColor White
Write-Host "Creates the app registration '$AppDisplayName' and configures direct upload." -ForegroundColor Gray
Write-Host "You must sign in as Global Administrator or Privileged Role Administrator." -ForegroundColor Gray

# 1. Sign in -------------------------------------------------------------------------------------------
Write-Step "Sign in"
$tok = Get-AdminToken
$claims = ConvertFrom-JwtPayload $tok.access_token
$realTenant = $claims.tid
$who = if ($claims.preferred_username) { $claims.preferred_username } elseif ($claims.upn) { $claims.upn } else { '(unknown)' }
$H = @{ Authorization = "Bearer $($tok.access_token)" }
Write-Ok "Signed in as $who"
Write-Info "Tenant: $realTenant"

# 2. Resolve the Microsoft Graph SP + the app-role id(s) -----------------------------------------------
Write-Step "Resolve Graph permission(s): $($RequiredAppRoles -join ', ')"
$graphSp = (Invoke-Graph GET "$GraphBase/servicePrincipals?`$filter=appId eq '$GraphResourceAppId'" -Headers $H).value | Select-Object -First 1
if (-not $graphSp) { throw "Could not find the Microsoft Graph service principal in this tenant." }
$roles = foreach ($rv in $RequiredAppRoles) {
    $r = $graphSp.appRoles | Where-Object { $_.value -eq $rv -and $_.allowedMemberTypes -contains 'Application' } | Select-Object -First 1
    if (-not $r) { throw "App role '$rv' not found on the Graph service principal." }
    $r
}
Write-Ok "Resolved $(@($roles).Count) app role(s)."

# 3. Create (or reuse) the app registration ------------------------------------------------------------
Write-Step "Create app registration '$AppDisplayName'"
$existing = (Invoke-Graph GET "$GraphBase/applications?`$filter=displayName eq '$AppDisplayName'" -Headers $H).value | Select-Object -First 1
if ($existing) {
    if (-not $Force) {
        Write-Warn2 "An app named '$AppDisplayName' already exists (appId $($existing.appId))."
        $ans = Read-Host "    Reuse it and just create a new secret? [y/N]"
        if ($ans -notmatch '^(y|yes|j|ja)$') { Write-Fail "Aborted by user."; return }
    }
    $app = $existing
    Write-Ok "Reusing existing app (objectId $($app.id))"
    if ($IncludeGroupManagement -or $IncludeConfigurationManagement) {
        # Reflect the (possibly newly added) optional roles in the app's requested permissions too.
        Invoke-WithRetry { Invoke-Graph PATCH "$GraphBase/applications/$($app.id)" -Headers $H -Body @{
            requiredResourceAccess = @(@{ resourceAppId = $GraphResourceAppId; resourceAccess = @($roles | ForEach-Object { @{ id = $_.id; type = 'Role' } }) })
        } } | Out-Null
        Write-Ok "Updated requested permissions to include the requested optional role(s)."
    }
} else {
    $appBody = @{
        displayName = $AppDisplayName
        signInAudience = 'AzureADMyOrg'
        requiredResourceAccess = @(@{
            resourceAppId  = $GraphResourceAppId
            resourceAccess = @($roles | ForEach-Object { @{ id = $_.id; type = 'Role' } })
        })
    }
    $app = Invoke-Graph POST "$GraphBase/applications" -Body $appBody -Headers $H
    Write-Ok "Created app (objectId $($app.id), appId $($app.appId))"
}

# 3b. Upload certificate public key (if -UseCertificate) -----------------------------------------------
if ($UseCertificate) {
    Write-Info "Uploading certificate credential (thumbprint $CertThumbprint)..."
    Invoke-WithRetry { Invoke-Graph PATCH "$GraphBase/applications/$($app.id)" -Headers $H -Body @{
        keyCredentials = @(@{
            type        = 'AsymmetricX509Cert'
            usage       = 'Verify'
            key         = [Convert]::ToBase64String($certObj.GetRawCertData())
            displayName = 'PSADT Intune Automation'
        })
    } } | Out-Null
    Write-Ok "Certificate uploaded (expires $($certObj.NotAfter.ToString('yyyy-MM-dd')))."
}

# 4. Ensure a service principal for the app ------------------------------------------------------------
Write-Step "Ensure service principal"
$sp = (Invoke-Graph GET "$GraphBase/servicePrincipals?`$filter=appId eq '$($app.appId)'" -Headers $H).value | Select-Object -First 1
if (-not $sp) {
    $sp = Invoke-WithRetry { Invoke-Graph POST "$GraphBase/servicePrincipals" -Body @{ appId = $app.appId } -Headers $H }
    Write-Ok "Created service principal ($($sp.id))"
} else {
    Write-Ok "Service principal exists ($($sp.id))"
}

# 5. Grant the application permission(s) + admin consent -----------------------------------------------
Write-Step "Grant permission(s) + admin consent"
$existingGrants = (Invoke-Graph GET "$GraphBase/servicePrincipals/$($sp.id)/appRoleAssignments" -Headers $H).value
$pending = 0
foreach ($r in $roles) {
    $has = $existingGrants | Where-Object { $_.appRoleId -eq $r.id -and $_.resourceId -eq $graphSp.id }
    if ($has) { Write-Ok "$($r.value): already granted."; continue }
    try {
        # Short retry: tolerate brief replication lag on the just-created SP, but surface a real
        # permission denial quickly instead of looping for half a minute.
        Invoke-WithRetry -Tries 3 -DelaySec 4 -Action {
            Invoke-Graph POST "$GraphBase/servicePrincipals/$($sp.id)/appRoleAssignments" -Headers $H -Body @{
                principalId = $sp.id; resourceId = $graphSp.id; appRoleId = $r.id
            }
        } | Out-Null
        Write-Ok "$($r.value): granted and admin-consented."
    } catch {
        $e = Get-GraphErr $_
        if ($e.code -eq 'Authorization_RequestDenied') {
            $pending++
            Write-Fail "$($r.value): cannot grant consent (need Global Admin or Privileged Role Admin)."
        } else {
            throw $e.message
        }
    }
}
$consentGranted = ($pending -eq 0)
if ($pending -gt 0) {
    Write-Warn2 "$pending permission(s) still need admin consent. The app and credential are created; grant later:"
    Write-Info  "Entra admin center > App registrations > '$AppDisplayName' > API permissions > Grant admin consent,"
    Write-Info  "or follow references/app-registration.md."
}

# 6. Credential: certificate (preferred) or client secret ----------------------------------------------
$secret = $null
$credExpires = $null
if ($UseCertificate) {
    Write-Step "Credential: certificate (uploaded in step 3b - no client secret created)"
    $credExpires = $certObj.NotAfter
    Write-Ok "Auth will use certificate $CertThumbprint (expires $($credExpires.ToString('yyyy-MM-dd')))."
} else {
    Write-Step "Create client secret (valid $SecretValidMonths month(s))"
    $credExpires = (Get-Date).AddMonths($SecretValidMonths)
    $pwdResult = Invoke-Graph POST "$GraphBase/applications/$($app.id)/addPassword" -Headers $H -Body @{
        passwordCredential = @{ displayName = 'PSADT upload secret'; endDateTime = $credExpires.ToString('o') }
    }
    $secret = ConvertTo-SecureString $pwdResult.secretText -AsPlainText -Force
    Write-Ok "Secret created (expires $($credExpires.ToString('yyyy-MM-dd'))). It is never displayed - stored encrypted."
}

# 7. Persist to config ---------------------------------------------------------------------------------
$setCfg = Join-Path $PSScriptRoot 'Set-PsadtConfig.ps1'
$cfgUpdates = @{
    'intune.tenantId'      = $realTenant
    'intune.clientId'      = $app.appId
    'intune.uploadEnabled' = $true
}
if ($UseCertificate) {
    Write-Step "Write config (config.json - thumbprint stored, no secret file)"
    $cfgUpdates['intune.certThumbprint'] = $CertThumbprint
    & $setCfg -SkillRoot $SkillRoot -Updates $cfgUpdates
} else {
    Write-Step "Write config (config.json + DPAPI secret.dpapi)"
    $cfgUpdates['intune.secretRef'] = 'secret.dpapi'
    & $setCfg -SkillRoot $SkillRoot -Secret $secret -Updates $cfgUpdates
}
Write-Ok "Saved to $(Join-Path $SkillRoot 'config.json')"

# --- Summary -----------------------------------------------------------------------------------------
Write-Host "`n----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "Done. Direct Intune upload is configured." -ForegroundColor Green
Write-Host "  Tenant    : $realTenant"
Write-Host "  Client    : $($app.appId)   ('$AppDisplayName')"
Write-Host "  Permissions: $($RequiredAppRoles -join ', ')  (consent: $(if($consentGranted){'granted'}else{'PENDING - grant in portal'}))"
if ($UseCertificate) {
    Write-Host "  Auth      : certificate ($CertThumbprint), expires $($credExpires.ToString('yyyy-MM-dd'))" -ForegroundColor Cyan
} else {
    Write-Host "  Auth      : client secret, DPAPI-encrypted, expires $($credExpires.ToString('yyyy-MM-dd'))"
}
if (-not $consentGranted) {
    Write-Host "  ACTION    : grant admin consent in the portal before the first upload." -ForegroundColor Yellow
}
Write-Host "Next: build a package; the upload step (Phase 9) will use this app." -ForegroundColor Gray
Write-Host "----------------------------------------------------------------`n" -ForegroundColor DarkGray

[pscustomobject]@{
    TenantId       = $realTenant
    ClientId       = $app.appId
    AppObjectId    = $app.id
    ConsentGranted = $consentGranted
    AuthMethod     = if ($UseCertificate) { 'Certificate' } else { 'ClientSecret' }
    CredExpires    = $credExpires
    ConfigPath     = (Join-Path $SkillRoot 'config.json')
}

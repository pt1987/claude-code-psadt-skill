# Entra app registration — permission matrix + manual portal fallback

The direct Intune upload (SKILL.md Phase 9) authenticates as an **app-only** Entra application with the
Microsoft Graph **application** permission `DeviceManagementApps.ReadWrite.All`.

## 0. The permission matrix (single source of truth)

Every permission this skill can use, and nothing else. Guide Appendix M.1 and N.4 point here rather than
repeating it. Only the first row is required; the rest are opt-in and off by default.

**Application roles** — what the app-only credential carries in its token (`roles` claim). These are what
`scripts/Test-PsadtIntuneAccess.ps1` reports as capabilities.

| Role | Capability | Needed for | How to grant |
|---|---|---|---|
| `DeviceManagementApps.ReadWrite.All` | `Upload` | Phase 9 direct upload, app assignment | required — `New-PsadtEntraApp.ps1` |
| `Group.Create` | `Groups` (half) | create an assignment group the app then **owns** (NOT tenant-wide `Group.ReadWrite.All`) | `New-PsadtEntraApp.ps1 -IncludeGroupManagement` |
| `GroupMember.Read.All` | `Groups` (half) | find an existing group by name | `New-PsadtEntraApp.ps1 -IncludeGroupManagement` |
| `DeviceManagementConfiguration.ReadWrite.All` | `Configuration` | firewall-rule policy, TrustedPublisher / driver-trust cert profile | `New-PsadtEntraApp.ps1 -IncludeConfigurationManagement` |

The `Groups` capability needs **both** group roles: an app that can create a group but not read its members
produces a half-finished assignment. `Test-PsadtIntuneAccess.ps1` reports which half is missing.

**Delegated scopes** — used only by the one-time bootstrap sign-in (you, as an admin, in
`New-PsadtEntraApp.ps1`). They are never stored and never used for packaging or upload.

| Scope | Needed for |
|---|---|
| `Application.ReadWrite.All` | create / update the app registration |
| `AppRoleAssignment.ReadWrite.All` | grant + admin-consent the application roles above |

Granting the application roles requires **Global Administrator** or **Privileged Role Administrator**. A
non-admin sign-in can create the app but not consent it: `New-PsadtEntraApp.ps1` then leaves
`intune.uploadEnabled` at `false` and says which roles are still pending.

Check what is actually in place at any time — read-only, no writes to the tenant:

```powershell
pwsh scripts/Test-PsadtIntuneAccess.ps1
```

**Preferred path:** run `pwsh scripts/New-PsadtEntraApp.ps1` once. It signs you in interactively via **WAM**
(the Windows Web Account Manager broker; device-code fallback), creates the app, grants + admin-consents the
permission, and stores the credential automatically. Use the manual steps below only when you cannot run
that script (locked-down host, policy, etc.).

**Certificate vs client secret:** certificate auth is preferred for personal use — no DPAPI portability
constraint, no secret to rotate on a tight schedule, and the private key never leaves your machine.
If you already have a cert in `Cert:\CurrentUser\My`, pass `-UseCertificate -CertThumbprint <thumb>`:

```powershell
# Create a self-signed cert (one time, 10-year expiry)
$c = New-SelfSignedCertificate -Subject 'CN=<you> - Intune Automation' `
     -CertStoreLocation 'Cert:\CurrentUser\My' -KeyAlgorithm RSA -KeyLength 4096 `
     -KeyUsage DigitalSignature -NotAfter (Get-Date).AddYears(10) -HashAlgorithm SHA256
$c.Thumbprint   # note this value

# Bootstrap the Entra app with the cert (no secret created)
pwsh scripts/New-PsadtEntraApp.ps1 -UseCertificate -CertThumbprint $c.Thumbprint
```

The script uploads the cert's public key to the app registration, stores the thumbprint in `config.json`
(gitignored), and configures `Get-GraphToken.ps1` to sign JWT client assertions with the private key at
upload time. No secret file is created; `secret.dpapi` is not needed.

You must sign in as **Global Administrator** or **Privileged Role Administrator** — granting admin consent
for an application permission requires it. Application Administrator alone cannot complete the consent step.

## 1. Create the app registration

1. [Entra admin center](https://entra.microsoft.com) → **Identity → Applications → App registrations → New registration**.
2. **Name:** `PSADT Intune Upload` (fixed by convention). **Supported account types:** *Accounts in this
   organizational directory only*. No redirect URI needed (app-only/client-credentials). **Register**.
3. From the **Overview** blade, copy the **Application (client) ID** and the **Directory (tenant) ID**.

## 2. Add the application permission + grant admin consent

1. App → **API permissions → Add a permission → Microsoft Graph → Application permissions**.
2. Search `DeviceManagementApps.ReadWrite.All`, tick it, **Add permissions**.
3. Click **Grant admin consent for &lt;tenant&gt;** and confirm. The permission row must show
   **Granted for &lt;tenant&gt;** (green check). Without this the upload's read-only probe returns `403`.

## 3. Create a credential (choose one)

### Option A — Certificate (preferred)

1. Export the public key of your cert as a `.cer` file:

   ```powershell
   Export-Certificate -Cert "Cert:\CurrentUser\My\<Thumbprint>" -FilePath "$env:TEMP\intune-auth.cer"
   ```

2. App → **Certificates & secrets → Certificates → Upload certificate** → select `intune-auth.cer`. **Add**.
3. The thumbprint shown in the portal must match your cert's thumbprint. No value to copy.

### Option B — Client secret

1. App → **Certificates & secrets → Client secrets → New client secret**.
2. Description `PSADT upload secret`, pick an expiry (e.g. 12 months). **Add**.
3. Copy the secret **Value** immediately (shown once). Do **not** paste it into chat or any file.

## 4. Feed it into the skill config

**Option A — Certificate:** store only the thumbprint (not sensitive):

```powershell
& scripts/Set-PsadtConfig.ps1 -Updates @{
    'intune.tenantId'      = '<tenant-guid>'
    'intune.clientId'      = '<client-guid>'
    'intune.uploadEnabled' = $true
    'intune.certThumbprint' = '<thumbprint>'
}
```

**Option B — Client secret:** store tenant/client in `config.json` and DPAPI-encrypt the secret to `secret.dpapi` — the plaintext is never written to any file and is zeroed from memory after each token request:

```powershell
$secret = Read-Host -AsSecureString 'Paste the client secret value'   # typed in the terminal, never in chat
& scripts/Set-PsadtConfig.ps1 -Secret $secret -Updates @{
    'intune.tenantId'      = '<tenant-guid>'
    'intune.clientId'      = '<client-guid>'
    'intune.uploadEnabled' = $true
    'intune.secretRef'     = 'secret.dpapi'
}
```

## 5. Verify

```powershell
$tok = & scripts/Get-GraphToken.ps1
Invoke-RestMethod -Headers @{ Authorization = "Bearer $($tok.Token)" } `
  -Uri 'https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps?$top=1' | Out-Null
'OK - DeviceManagementApps.ReadWrite.All is effective.'
```

A `403` here means consent/permission is missing — revisit step 2. Then proceed with Phase 9
(`Invoke-IntuneWin32Upload.ps1`, dry-run first).

> Rotation: when the secret expires, create a new one (step 3) and re-run step 4. The app, its consent, and
> any supersedence/assignments are unaffected.

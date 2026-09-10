# Appendix H: Direct Intune upload via Microsoft Graph (win32LobApp) - hard-won lessons

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Appendix H: Direct Intune upload via Microsoft Graph (win32LobApp) - hard-won lessons

Captured 2026-06-06 while implementing `scripts/Get-GraphToken.ps1` + `scripts/Invoke-IntuneWin32Upload.ps1` and uploading the 7-Zip package to a live tenant. All endpoints verified against the live Graph catalog (msgraph skill) and a real upload.

### H.0 Auth & bootstrap
- **Bootstrap (`New-PsadtEntraApp.ps1`) uses WAM** (Windows Web Account Manager broker) for the interactive admin sign-in, falling back to device code only if WAM is unavailable. WAM needs the MSAL.NET broker assemblies (`Microsoft.Identity.Client` + `.Broker` + `.NativeInterop` + native `msalruntime.dll`) - the script auto-locates them in the global NuGet cache or downloads a pinned set to `%LOCALAPPDATA%\PsadtIntune\msal`. **Pitfall:** `BrokerOptions` lives in namespace `Microsoft.Identity.Client` (NOT `Microsoft.Identity.Client.Broker`); `WithBroker` is the static `[Microsoft.Identity.Client.Broker.BrokerExtension]::WithBroker($builder,$opts)`. Also load the transitive `Microsoft.IdentityModel.Abstractions` or `WithAuthority` throws "Could not load file or assembly".
- **Uploads use app-only client credentials** (`Get-GraphToken.ps1`): scope `https://graph.microsoft.com/.default`, the DPAPI secret decrypted **in-memory only** (`SecureStringToBSTR` -> `PtrToStringBSTR` -> `ZeroFreeBSTR`), never logged.

### H.1 Use `/beta`, not `/v1.0`
The current Intune app-metadata backend (`StatelessAppMetadataFEService`, api-version 2025-07-02) on `/v1.0` **silently drops several win32LobApp write properties** - most visibly `displayVersion` (the portal "App Version" stays empty even after a PATCH that returns 200). The **same call on `/beta` persists them**. Do all win32LobApp metadata writes on `/beta`. **Drift caveat:** `/beta` is explicitly unversioned, so Microsoft can change the win32LobApp request shapes (the `@odata.type`-first / unified `rules` / detection-rule allowed-properties rules below) with no notice. This is a knowing trade-off for `displayVersion`; the upload-shape unit tests (`tests/Invoke-IntuneWin32Upload.Tests.ps1`) are the early-warning net, and the request bodies should be re-checked against the Graph changelog periodically.

### H.2 Detection: the unified `rules` collection, NOT `detectionRules`
`win32LobApp` exposes BOTH `detectionRules` (legacy `win32LobAppDetection`) and `rules` (unified `win32LobAppRule`). The current backend **ignores `detectionRules`** and rejects the create with `BadRequest: The Win32LobApp must have at least one detection rule specified` even though a perfectly valid `detectionRules` array was sent. Use `rules` with a `ruleType`:
```powershell
rules = @([ordered]@{
  '@odata.type'          = '#microsoft.graph.win32LobAppProductCodeRule'  # MUST be first (see H.3)
  ruleType               = 'detection'
  productCode            = '{<GUID>}'
  productVersionOperator = 'notConfigured'
  productVersion         = $null
})
```
Never send both `rules` and `detectionRules`/`requirementRules` together.

**Non-MSI apps (EXE installers: Vivaldi, Chrome-style, NSIS, Squirrel) → PowerShell-script detection rule.**
There is no ProductCode, so use a `win32LobAppPowerShellScriptRule` with `ruleType='detection'` and the
base64 of the detect script (classic contract: stdout + `exit 0` when installed). A **detection** script rule
accepts ONLY these properties — Graph rejects the others with `BadRequest: The <X> property may not be set for
Win32LobAppPowerShellScriptRule instances used for app detection`:
```powershell
$rules = @([ordered]@{
  '@odata.type'         = '#microsoft.graph.win32LobAppPowerShellScriptRule'  # first!
  ruleType              = 'detection'
  enforceSignatureCheck = $false
  runAs32Bit            = $false
  scriptContent         = [Convert]::ToBase64String([IO.File]::ReadAllBytes($detectPs1))
})
```
Do NOT set `displayName`, `runAsAccount`, `operationType`, `operator`, or `comparisonValue` on a *detection*
script rule — those are valid only on *requirement* script rules. `Invoke-IntuneWin32Upload.ps1` exposes this
as `-DetectionScriptPath` (use instead of `-MsiProductCode`). Verified live with the Vivaldi package (2026-06-06).

### H.3 `@odata.type` must serialise FIRST
For every polymorphic Graph sub-object (detection rule, `mimeContent` logo, `msiInformation`, supersedence relationship) build it with `[ordered]@{}` so `@odata.type` is the first key. A plain `@{}` hashtable serialises keys in an arbitrary order; when `@odata.type` lands later, the backend fails to bind the subtype and behaves as if the object were missing (this is a second cause of the "no detection rule" error).

### H.4 Content upload: relay EncryptionInfo, never re-encrypt
`IntuneWinAppUtil` already AES-encrypts the payload. The `.intunewin` is a ZIP containing `IntuneWinPackage/Contents/IntunePackage.intunewin` (the **already-encrypted** blob) and `IntuneWinPackage/Metadata/Detection.xml` (the `EncryptionInfo` + `UnencryptedContentSize` + `SetupFile`). Upload the inner blob verbatim and relay its `EncryptionInfo` to the `commit` call as `fileEncryptionInfo`. **Do NOT recompute** anything: `EncryptionInfo.FileDigest` is the SHA256 of the **plaintext** (not the ciphertext) - a local SHA256 of the encrypted blob will NOT match it, and that is correct/expected. Register the file with `size = UnencryptedContentSize` and `sizeEncrypted = (encrypted blob length)`.

### H.5 Block-blob upload MUST use HttpClient (binary fidelity)
Uploading the encrypted blob to the Azure SAS URI with `Invoke-RestMethod -Method Put -Body $bytes` **corrupts the binary** (it re-encodes the byte[]), so the blocks report "OK" but the later `commit` returns `uploadState=commitFileFailed` (MAC/digest mismatch on the decrypted content). Use raw bytes via `HttpClient`/`ByteArrayContent`:
```powershell
$client = [System.Net.Http.HttpClient]::new()
$req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Put, "$sas&comp=block&blockid=$enc")
$req.Content = [System.Net.Http.ByteArrayContent]::new($chunk)        # raw bytes, exact
$client.SendAsync($req).GetAwaiter().GetResult()
```
~4-6 MB blocks, base64 block ids of fixed width, then `PUT &comp=blocklist` with `<BlockList><Latest>..</Latest></BlockList>`. Do NOT add `x-ms-blob-type` to Put Block (only relevant to single Put Blob). Renew the SAS via `.../files/{id}/renewUpload` on long uploads. All poll loops (`azureStorageUriRequestSuccess`, `commitFileSuccess`) need timeout caps.

### H.6 Content sub-path needs the type-cast segment
After `/deviceAppManagement/mobileApps/{id}`, the content endpoints require the cast `/microsoft.graph.win32LobApp` before `contentVersions`: `.../mobileApps/{id}/microsoft.graph.win32LobApp/contentVersions/{cv}/files/{f}/...`. The 8 steps: create app -> contentVersion -> file (size+sizeEncrypted) -> poll SAS -> block upload -> commit(fileEncryptionInfo) -> poll -> PATCH `committedContentVersion`.

### H.7 Categories are a `$ref` relationship; supersedence is a relationship
`categories` is NOT a settable property. Resolve names from `/deviceAppManagement/mobileAppCategories`, then `POST .../mobileApps/{id}/categories/$ref` with `{ '@odata.id': '<base>/mobileAppCategories/<catId>' }`. Supersedence: `POST .../mobileApps/{newId}/relationships` with `{ '@odata.type':'#microsoft.graph.mobileAppSupersedence', supersedenceType:'replace', targetId:'<oldId>' }`.

### H.8 Coexistence & versioning (NEVER delete an older version)
Uploading a new version must **not** remove the existing one. `Invoke-IntuneWin32Upload.ps1` issues **only POST/PATCH, never DELETE**. Default `-OnExisting CreateNewCoexist` creates a NEW, separate app and leaves existing same-name version(s) fully intact, so supersedence can be wired and a rollback target remains. `-UpdateAppId <id>` is the explicit in-place path (replaces one app's content, keeps id/assignments). `-SupersedesAppId <oldId>` wires "new replaces old" (old retained). Same `displayName` for multiple versions is fine - they are distinct apps differentiated by `displayVersion`.

### H.9 Metadata completeness & boundaries
**Fill every objective field** - empty App-information tabs are a defect: `displayName, description (Markdown), publisher, developer, owner, displayVersion, informationUrl, privacyInformationUrl, notes, largeIcon, msiInformation (productCode+productVersion for MSI), returnCodes, rules, installExperience`. **But never auto-impose user/org choices**: no company branding in `notes` by default (empty, or config `intune.notes`), no category (`-Categories` empty by default - users assign categories themselves), no featured flag, no group assignment.

### H.10 Logo guard
The Company-Portal logo must be the REAL application logo. The PSADT template's `Assets\AppIcon.png` (generic coloured ">" mark) is NOT it - re-using it is a real mistake that slipped past a naive "square + alpha" check. The script keeps a SHA256 blocklist of PSADT default assets and refuses them unless `-AllowDefaultLogo`. When verifying a downloaded logo, `IsAlphaPixelFormat` is True even for opaque images - sample a real corner pixel and visually confirm the brand. An opaque-but-correct logo is acceptable (square it on its own background colour); the WRONG image is not.

### H.11 `minimumSupportedWindowsRelease` is a server-validated string - use a known-good release ID
The win32LobApp `minimumSupportedWindowsRelease` property is a free-form **string**, but the backend validates it against an internal list and rejects anything unknown with `BadRequest: "Unknown MinimumSupportedWindowsRelease: <value>"` **at the create step** (after the app body is assembled - an ugly mid-flight failure). The reliably-accepted values are the canonical Windows 10 release IDs: `1607, 1703, 1709, 1803, 1809, 1903, 1909, 2004` (confirmed: `1809` accepted; `21H2` rejected on a live tenant). Newer labels (`21H2`, `22H2`, Windows 11 IDs) are accepted by some tenant FE-service versions and rejected by others, so `Invoke-IntuneWin32Upload.ps1` constrains `-MinWindowsRelease` to a `ValidateSet` of the reliable IDs - it fails fast at param binding with the valid list instead of dying at create. Need a higher minimum than `2004`? Set it in the portal after upload (App > Properties > Requirements). Note: this is a different field from the dossier's free-text "Minimum OS" display string, which may say e.g. "Windows 10 22H2" for humans.

---

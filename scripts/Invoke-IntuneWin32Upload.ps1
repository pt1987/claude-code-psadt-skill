<#
.SYNOPSIS
    Uploads a PSADT .intunewin package to Intune as a win32LobApp via Microsoft Graph (app + logo, NO
    assignment). Self-contained raw Graph; relays the IntuneWinAppUtil EncryptionInfo (never re-implements AES).

.DESCRIPTION
    Read-only by default: acquires a token, probes the permission, checks for an existing app with the same
    displayName, builds the request body and prints a summary - then STOPS. Pass -Execute to perform the
    writes. Pass -UpdateAppId <id> to update an existing app in place (preserves assignments/history) instead
    of creating a new one.

    8-step flow (all endpoints verified against the live Graph catalog, 2026-06-06; note the type-cast
    segment 'microsoft.graph.win32LobApp' in the content sub-paths):
      1. parse .intunewin (Detection.xml -> EncryptionInfo, unencrypted size, SetupFile; extract enc blob)
      2. idempotency check (GET mobileApps filtered by displayName)
      3. create or reuse the win32LobApp
      4. create a contentVersion
      5. register the file (size + sizeEncrypted), poll for the Azure SAS URI
      6. block-blob upload the encrypted blob to the SAS URI (4 MB blocks, retry + SAS renew)
      7. commit with the fileEncryptionInfo, poll for commitFileSuccess
      8. PATCH committedContentVersion (+ largeIcon) and print the portal deep-link

.PARAMETER IntuneWinPath            Path to the .intunewin file.
.PARAMETER DisplayName              App name shown in Intune / Company Portal.
.PARAMETER Description              Markdown description (Company Portal field supports Markdown only).
.PARAMETER Publisher                Publisher string.
.PARAMETER Developer                Developer (optional).
.PARAMETER AppVersion               displayVersion shown in the portal (e.g. 26.01).
.PARAMETER InstallCommandLine       Install command (PSADT launcher).
.PARAMETER UninstallCommandLine     Uninstall command (PSADT launcher).
.PARAMETER MsiProductCode           MSI ProductCode GUID for the detection rule (MSI product-code detection).
.PARAMETER Architecture             applicableArchitectures (x64/x86/arm64). Default x64.
.PARAMETER MinWindowsRelease        minimumSupportedWindowsRelease (e.g. 1607). Default 1607.
.PARAMETER RestartBehavior          deviceRestartBehavior. Default basedOnReturnCode.
.PARAMETER MaxRunTimeMinutes        installExperience.maxRunTimeInMinutes. 0 (default) omits the field and
                                    keeps the service default of 60 min. Raise it for long-running
                                    installs (e.g. 240 for an OS in-place upgrade) or the IME kills them.
.PARAMETER LogoPath                 PNG (transparent, square) used as largeIcon.
.PARAMETER Execute                  Perform the writes. Without it the script is a read-only dry run.
.PARAMETER UpdateAppId              Update this existing app id in place instead of creating a new one.
.PARAMETER ManifestPath             psadt-package.json to take DisplayName / Publisher / AppVersion /
                                    Architecture from. Explicit parameters always win; results.upload is
                                    written back after a successful -Execute.
.PARAMETER SkillRoot                Config home override; default = the resolved config home.

.OUTPUTS
    PSCustomObject summarising the run (AppId, ContentVersion, PortalUrl, Executed, Existing[]).
#>
[CmdletBinding(DefaultParameterSetName = 'Explicit')]
param(
    [Parameter(Mandatory)][string]$IntuneWinPath,
    # Either name the app explicitly, or point at the package manifest and let it supply the identity.
    # Anything passed explicitly always wins over the manifest.
    [Parameter(Mandatory, ParameterSetName = 'Explicit')]
    [Parameter(ParameterSetName = 'Manifest')]
    [string]$DisplayName,
    [Parameter(Mandatory, ParameterSetName = 'Manifest')]
    [string]$ManifestPath,
    [string]$Description = '',
    [string]$Publisher = '',
    [string]$Developer = '',
    [string]$Owner = '',
    [string]$Notes = '',
    [string]$InformationUrl = '',
    [string]$PrivacyUrl = '',
    [string[]]$Categories = @(),
    [switch]$Featured,
    [string[]]$RoleScopeTagIds = @(),
    [string]$AppVersion = '',
    [string]$InstallCommandLine   = 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent',
    [string]$UninstallCommandLine = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent',
    # MSI GUIDs: accept the bare or brace-wrapped 8-4-4-4-12 form; reject anything else at param binding
    # (a malformed ProductCode otherwise only fails later, server-side, as an opaque detection-rule error).
    [ValidatePattern('^\{?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}?$')]
    [string]$MsiProductCode,
    [ValidatePattern('^\{?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}?$')]
    [string]$MsiUpgradeCode,
    [ValidateSet('perMachine','perUser','dualPurpose')][string]$MsiPackageType = 'perMachine',
    # Detection alternative for non-MSI apps (EXE installers etc.): a PowerShell detection script
    # (contract: write to stdout + exit 0 when installed; no stdout when not). Mutually exclusive with -MsiProductCode.
    [string]$DetectionScriptPath,
    [switch]$DetectionRunAs32Bit,
    [ValidateSet('x64','x86','arm64')][string]$Architecture = 'x64',
    # minimumSupportedWindowsRelease: a Windows 10 release ID. These are the values the Graph backend reliably
    # accepts (the canonical windowsMinimumOperatingSystem release tokens). Newer labels such as '21H2'/'22H2'
    # are rejected by some tenant FE service versions ("Unknown MinimumSupportedWindowsRelease" -> BadRequest),
    # so they are intentionally NOT offered here - the ValidateSet fails fast at param binding with the valid
    # list instead of letting the upload die mid-flight at the create step. Need a newer minimum? Set it in the
    # portal after upload. See guide Appendix H.
    [ValidateSet('1607','1703','1709','1803','1809','1903','1909','2004')]
    [string]$MinWindowsRelease = '1607',
    [int]$MinFreeDiskSpaceMB = 0,
    [int]$MinMemoryMB = 0,
    [ValidateSet('basedOnReturnCode','allow','suppress','force')][string]$RestartBehavior = 'basedOnReturnCode',
    # Installer-specific return codes researched in Phase 1.3, e.g. @{ Code = 1603; Type = 'failed' }.
    # Merged OVER the mandatory Appendix F.4 table (Get-PsadtReturnCodes.ps1); an entry whose code is
    # already canonical overrides that row. Without this parameter a researched code could only ever be
    # documented in the dossier and never actually reached the app.
    [object[]]$ReturnCodes = @(),
    # installExperience.maxRunTimeInMinutes - how long the IME lets the install run before killing it.
    # The service default is 60 minutes, which is fine for ordinary installers but kills long-running ones
    # (OS in-place upgrades, large suites). 0 = do not send the field, keeping the service default and the
    # previous behaviour of this script unchanged. Intune's portal maximum is 1440.
    [ValidateRange(0,1440)][int]$MaxRunTimeMinutes = 0,
    [string]$LogoPath,
    [switch]$AllowDefaultLogo,
    [switch]$Execute,
    # Coexistence/versioning. DEFAULT = CreateNewCoexist: a new version is uploaded as a SEPARATE app and the
    # existing version is LEFT UNTOUCHED (never deleted), so you can wire supersedence. UpdateInPlace replaces
    # the content of -UpdateAppId (keeps its id/assignments). The script NEVER deletes an app under any mode.
    [ValidateSet('CreateNewCoexist','UpdateInPlace','Abort')][string]$OnExisting = 'CreateNewCoexist',
    [string]$UpdateAppId,
    [string]$SupersedesAppId,   # optional: wire 'new supersedes old' (replace) after the new app is created
    [string]$SkillRoot
)

$ErrorActionPreference = 'Stop'

# --- Identity from the package manifest (0.21.0) ---------------------------------------------------
# So the app in Intune carries the same name/version as the artifact and the dossier, instead of whatever
# was typed at the command line this time.
$manifestPackagePath = $null
if ($ManifestPath) {
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "ManifestPath not found: $ManifestPath" }
    try { $mfUp = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "psadt-package.json is malformed: $($_.Exception.Message)" }
    $manifestPackagePath = Split-Path -Parent (Resolve-Path -LiteralPath $ManifestPath).Path

    if (-not $PSBoundParameters.ContainsKey('DisplayName') -and $mfUp.app.name) {
        $DisplayName = if ($mfUp.app.vendor) { "$($mfUp.app.vendor) $($mfUp.app.name)" } else { [string]$mfUp.app.name }
    }
    if (-not $PSBoundParameters.ContainsKey('Publisher')  -and $mfUp.app.vendor)  { $Publisher  = [string]$mfUp.app.vendor }
    # Installer-specific codes researched in Phase 1.3 and recorded once in the manifest, so the dossier
    # and the uploaded app cannot document different mappings.
    if (-not $PSBoundParameters.ContainsKey('ReturnCodes') -and $mfUp.research.returnCodes) { $ReturnCodes = @($mfUp.research.returnCodes) }
    if (-not $PSBoundParameters.ContainsKey('AppVersion') -and $mfUp.app.version) { $AppVersion = [string]$mfUp.app.version }
    if (-not $PSBoundParameters.ContainsKey('Architecture') -and $mfUp.app.arch -in @('x64', 'x86', 'arm64')) {
        $Architecture = [string]$mfUp.app.arch
    }
    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        throw "The manifest has no app.name and no -DisplayName was passed. Fill the identity with Set-PsadtPackageManifest.ps1."
    }
}

# The SAME canonical table the dossier renders - see Get-PsadtReturnCodes.ps1. Resolved HERE, before the
# token is acquired and before any Graph call, so an invalid return code fails at validation time instead
# of after authenticating against the tenant.
$returnCodes = @(& (Join-Path $PSScriptRoot 'Get-PsadtReturnCodes.ps1') -Custom $ReturnCodes -AsGraphBody)

# Use beta: the v1.0 Intune app-metadata backend (StatelessAppMetadataFEService) silently DROPS several
# win32LobApp properties on write - most visibly displayVersion (the portal "App Version"). beta persists them.
$GraphBase = 'https://graph.microsoft.com/beta'

# Notes/Categories are user/organisation decisions - NEVER hard-code a default here (no company branding,
# no auto category). A company MAY opt into a default note via config (intune.notes); still not forced.
if ([string]::IsNullOrWhiteSpace($Notes)) {
    try {
        $cfgN = (& (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1') -SkillRoot $SkillRoot).Config
        if ($cfgN.intune -and $cfgN.intune.notes) { $Notes = [string]$cfgN.intune.notes }
    } catch {}
}

# --- Shared Graph helpers (Write-*, Get-GraphErr, Invoke-Graph; retry + PS7-safe) -------------------
. (Join-Path $PSScriptRoot '_GraphCommon.ps1')
$script:step = 0

# =====================================================================================================
Write-Host "Intune Win32 upload (Graph) - $DisplayName" -ForegroundColor White

# 1. Parse the .intunewin --------------------------------------------------------------------------
Write-Step "Parse .intunewin"
if (-not (Test-Path $IntuneWinPath)) { throw "Not found: $IntuneWinPath" }
$work = Join-Path ([IO.Path]::GetTempPath()) ("iwup-" + [IO.Path]::GetFileNameWithoutExtension($IntuneWinPath))
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
# Everything from here runs inside try/finally so the extracted work dir - whose Detection.xml holds the
# AES encryptionKey/macKey/IV/mac - is ALWAYS removed from %TEMP%, on success, dry-run return, or throw.
try {
Expand-Archive -Path $IntuneWinPath -DestinationPath $work -Force
$detXml = Join-Path $work 'IntuneWinPackage\Metadata\Detection.xml'
$encBlob = Join-Path $work 'IntuneWinPackage\Contents\IntunePackage.intunewin'
if (-not (Test-Path $detXml))  { throw "Detection.xml missing inside the .intunewin." }
if (-not (Test-Path $encBlob)) { throw "Encrypted content blob missing inside the .intunewin." }
[xml]$det = Get-Content $detXml
$ai = $det.ApplicationInfo
$setupFile = $ai.SetupFile
$unencSize = [int64]$ai.UnencryptedContentSize
$encSize   = (Get-Item $encBlob).Length
$ei = $ai.EncryptionInfo
$fileEncryptionInfo = @{
    encryptionKey        = $ei.EncryptionKey
    macKey               = $ei.MacKey
    initializationVector = $ei.InitializationVector
    mac                  = $ei.Mac
    profileIdentifier    = $ei.ProfileIdentifier
    fileDigest           = $ei.FileDigest
    fileDigestAlgorithm  = $ei.FileDigestAlgorithm
}
$fileName = [IO.Path]::GetFileName($IntuneWinPath)
Write-Ok "SetupFile=$setupFile  unencrypted=$unencSize  encrypted=$encSize bytes"

# --- Token ----------------------------------------------------------------------------------------
Write-Step "Acquire Graph token (app-only)"
$tok = & (Join-Path $PSScriptRoot 'Get-GraphToken.ps1') -SkillRoot $SkillRoot
$H = @{ Authorization = "Bearer $($tok.Token)" }
Write-Ok "Token for tenant $($tok.TenantId) (expires $($tok.ExpiresOn.ToString('HH:mm')))"

# --- Permission gate ------------------------------------------------------------------------------
# Two layers, cheapest first: the token itself says which roles were granted (no request, names the exact
# missing permission), then the read probe proves the permission is effective against the real endpoint.
Assert-GraphRole -Token $tok.Token -Role 'DeviceManagementApps.ReadWrite.All' `
    -Hint 'Run New-PsadtEntraApp.ps1 (Global Admin) to grant and consent it, then Test-PsadtIntuneAccess.ps1 to verify.' | Out-Null

# --- Permission probe (read-only) -----------------------------------------------------------------
Write-Step "Probe permission (read-only)"
try { $null = Invoke-Graph GET "$GraphBase/deviceAppManagement/mobileApps?`$top=1" -Headers $H; Write-Ok "DeviceManagementApps.ReadWrite.All effective." }
catch { $e = Get-GraphErr $_; throw "Graph probe failed ($($e.code)): $($e.message). Check app consent." }

# 2. Idempotency check -----------------------------------------------------------------------------
Write-Step "Check for existing app named '$DisplayName'"
$escaped = $DisplayName.Replace("'","''")
$existing = (Invoke-Graph GET "$GraphBase/deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.win32LobApp') and displayName eq '$escaped'" -Headers $H).value
if ($existing) { foreach ($a in $existing) { Write-Info "found: id=$($a.id)  v=$($a.displayVersion)  modified=$($a.lastModifiedDateTime)" } }
else { Write-Info "none found - this would be a new app." }

# --- Build the win32LobApp body -------------------------------------------------------------------
# $returnCodes was resolved above, before authentication.
# Detection: the newer Intune app-metadata backend uses the unified 'rules' collection (win32LobAppRule with a
# ruleType), NOT the legacy 'detectionRules' - submitting detectionRules is silently ignored and the create
# fails with "must have at least one detection rule". @odata.type MUST be first so the subtype binds.
if ($MsiProductCode -and $DetectionScriptPath) {
    throw "Specify EITHER -MsiProductCode OR -DetectionScriptPath, not both."
} elseif ($DetectionScriptPath) {
    if (-not (Test-Path $DetectionScriptPath)) { throw "Detection script not found: $DetectionScriptPath" }
    $scriptB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($DetectionScriptPath))
    # A *detection* script rule accepts ONLY these props - displayName/runAsAccount/operationType/operator/
    # comparisonValue are valid only on *requirement* script rules and Graph rejects them here. Detection uses
    # the classic contract: the script writes to stdout + exits 0 when installed.
    $rules = @([ordered]@{
        '@odata.type'         = '#microsoft.graph.win32LobAppPowerShellScriptRule'
        ruleType              = 'detection'
        enforceSignatureCheck = $false
        runAs32Bit            = [bool]$DetectionRunAs32Bit
        scriptContent         = $scriptB64
    })
} elseif ($MsiProductCode) {
    $rules = @([ordered]@{
        '@odata.type'           = '#microsoft.graph.win32LobAppProductCodeRule'
        ruleType                = 'detection'
        productCode             = $MsiProductCode
        productVersionOperator  = 'notConfigured'
        productVersion          = $null
    })
} else { throw "No detection rule supplied - pass -MsiProductCode (MSI apps) or -DetectionScriptPath (EXE/other)." }

# MSI metadata (drives supersedence + version metadata) when this is an MSI-backed package.
$msiInfo = $null
if ($MsiProductCode) {
    $msiInfo = [ordered]@{
        '@odata.type'  = '#microsoft.graph.win32LobAppMsiInformation'
        productCode    = $MsiProductCode
        productVersion = $AppVersion
        productName    = $DisplayName
        publisher      = $Publisher
        packageType    = $MsiPackageType
        requiresReboot = ($RestartBehavior -eq 'force')
        upgradeCode    = $(if ($MsiUpgradeCode) { $MsiUpgradeCode } else { $null })
    }
}

$body = [ordered]@{
    '@odata.type'                  = '#microsoft.graph.win32LobApp'
    displayName                    = $DisplayName
    description                    = $Description
    publisher                      = $Publisher
    developer                      = $Developer
    owner                          = $Owner
    notes                          = $Notes
    informationUrl                 = $InformationUrl
    privacyInformationUrl          = $PrivacyUrl
    isFeatured                     = [bool]$Featured
    roleScopeTagIds                = $RoleScopeTagIds
    displayVersion                 = $AppVersion
    fileName                       = $fileName
    setupFilePath                  = $setupFile
    installCommandLine             = $InstallCommandLine
    uninstallCommandLine           = $UninstallCommandLine
    applicableArchitectures        = $Architecture
    minimumSupportedWindowsRelease = $MinWindowsRelease
    allowAvailableUninstall        = $true
    installExperience              = @{ runAsAccount = 'system'; deviceRestartBehavior = $RestartBehavior }
    returnCodes                    = $returnCodes
    rules                          = $rules
    msiInformation                 = $msiInfo
}
if ($MinFreeDiskSpaceMB -gt 0) { $body.minimumFreeDiskSpaceInMB = $MinFreeDiskSpaceMB }
if ($MinMemoryMB        -gt 0) { $body.minimumMemoryInMB        = $MinMemoryMB }
# Only send maxRunTimeInMinutes when explicitly asked for, so omitting the parameter leaves the service
# default (60) in place exactly as before.
if ($MaxRunTimeMinutes  -gt 0) { $body.installExperience.maxRunTimeInMinutes = $MaxRunTimeMinutes }
if ($LogoPath -and (Test-Path $LogoPath)) {
    # GUARD: never ship the PSADT template's default Assets\AppIcon.png (or Banner) as the app logo.
    # The Company Portal tile must show the REAL application logo - this is a hard rule, not a preference.
    $PsadtDefaultAssetHashes = @(
        '76188486017BCB8594D23CCC6309C655361941B603122D523975D9D44B3DBFF8'  # PSADT 4.1.x default Assets\AppIcon.png
    )
    $logoHash = (Get-FileHash $LogoPath -Algorithm SHA256).Hash
    if ($PsadtDefaultAssetHashes -contains $logoHash -and -not $AllowDefaultLogo) {
        throw "Refusing to upload: '$LogoPath' is the PSADT DEFAULT icon, not the real $DisplayName logo. " +
              "Download the actual application logo (see SKILL.md Phase 7) and pass it via -LogoPath. " +
              "Override only if you truly intend the PSADT icon: -AllowDefaultLogo."
    }
    if (([System.IO.Path]::GetFileName($LogoPath)) -ieq 'AppIcon.png' -and -not $AllowDefaultLogo) {
        Write-Host "    !   WARNING: logo file is named 'AppIcon.png' (the PSADT template asset name). Verify it is the real $DisplayName logo." -ForegroundColor Yellow
    }
    $body.largeIcon = [ordered]@{ '@odata.type' = '#microsoft.graph.mimeContent'; type = 'image/png'; value = [Convert]::ToBase64String([IO.File]::ReadAllBytes($LogoPath)) }
} else {
    Write-Host "    !   WARNING: no -LogoPath supplied - the app will have NO custom logo in the Company Portal." -ForegroundColor Yellow
}

if (-not $Execute) {
    Write-Host "`n--- DRY RUN (read-only). Re-run with -Execute to upload. ---" -ForegroundColor Yellow
    Write-Host "  Tenant      : $($tok.TenantId)"
    Write-Host "  App         : $DisplayName  $AppVersion  ($Architecture)"
    Write-Host "  Publisher   : $Publisher"
    Write-Host "  Install     : $InstallCommandLine"
    Write-Host "  Uninstall   : $UninstallCommandLine"
    Write-Host "  Developer   : $Developer"
    Write-Host "  Owner       : $Owner"
    Write-Host "  Notes       : $(if($Notes){'set'}else{'(empty)'})"
    Write-Host "  Info URL    : $InformationUrl"
    Write-Host "  Privacy URL : $PrivacyUrl"
    Write-Host "  Categories  : $(if($Categories){ $Categories -join ', ' } else { '(none)' })"
    Write-Host "  Featured    : $([bool]$Featured)"
    Write-Host "  Detection   : $(if($DetectionScriptPath){"PowerShell script ($([IO.Path]::GetFileName($DetectionScriptPath)))"}else{"MSI ProductCode $MsiProductCode"})"
    Write-Host "  Content     : $fileName ($([Math]::Round($encSize/1MB,1)) MB encrypted)"
    Write-Host "  Logo        : $(if($body.largeIcon){'yes'}else{'NO - WARNING'})"
    Write-Host "  Return codes: $($returnCodes.Count) ($(($returnCodes | ForEach-Object { "$($_.returnCode)=$($_.type)" }) -join ', '))"
    Write-Host "  Existing    : $(if($existing){ ($existing | ForEach-Object { "$($_.id) (v$($_.displayVersion))" }) -join ', ' } else { 'none' })"
    $action = if ($UpdateAppId) { "UPDATE IN PLACE app $UpdateAppId (content replaced; id/assignments kept)" }
              elseif ($existing -and $OnExisting -eq 'Abort') { "ABORT (existing app present, -OnExisting Abort)" }
              elseif ($existing) { "CREATE NEW coexisting app (existing version(s) left INTACT - never deleted)" }
              else { "CREATE NEW app" }
    Write-Host "  On -Execute : $action" -ForegroundColor White
    if ($SupersedesAppId) { Write-Host "  Supersedes  : will mark new app as replacing $SupersedesAppId (old app retained)" }
    return [pscustomobject]@{ Executed=$false; Existing=@($existing); PlannedAction=$action; PlannedBody=$body; EncSize=$encSize; UnencSize=$unencSize }
}

# ====================== WRITES BELOW THIS LINE ======================
# This script issues ONLY POST (create) and PATCH (update). It NEVER issues DELETE - an existing/older
# version of an app is therefore never removed. Uploading a new version creates a SEPARATE, coexisting app
# by default, so supersedence can be configured and a rollback target remains. (Cleanup of an old version,
# if ever wanted, is a deliberate MANUAL action in the Intune portal - never automated here.)

# 3. Create or update the app (coexistence-safe) ---------------------------------------------------
Write-Step "Create / update win32LobApp"
if ($existing -and -not $UpdateAppId -and $OnExisting -eq 'Abort') {
    throw "App '$DisplayName' already exists (id(s): $(($existing | ForEach-Object { $_.id }) -join ', ')). Aborted per -OnExisting Abort. Use -OnExisting CreateNewCoexist (default) or -UpdateAppId <id>."
}
if ($UpdateAppId) {
    # Explicit in-place update of ONE existing app: replaces its content + metadata, KEEPS its id/assignments.
    # Still never deletes. Use this only when you intentionally want to overwrite that exact app.
    $appId = $UpdateAppId
    $null = Invoke-Graph PATCH "$GraphBase/deviceAppManagement/mobileApps/$appId" -Headers $H -Body $body
    Write-Ok "Updating existing app $appId IN PLACE (id + assignments preserved; previous content replaced)."
} else {
    # DEFAULT (CreateNewCoexist): create a NEW, SEPARATE app. Any existing same-name version is left
    # completely untouched -> the old and new versions COEXIST in Intune.
    if ($existing) {
        Write-Host "    !   $($existing.Count) existing '$DisplayName' app(s) found - they are NOT modified and NOT deleted." -ForegroundColor Yellow
        Write-Info "Creating a NEW, coexisting app (so you can set up supersedence + keep a rollback target)."
        foreach ($a in $existing) { Write-Info "  existing: id=$($a.id)  version=$($a.displayVersion)" }
    }
    $app = Invoke-Graph POST "$GraphBase/deviceAppManagement/mobileApps" -Headers $H -Body $body
    $appId = $app.id
    Write-Ok "Created NEW app $appId$(if($existing){' (coexists with the existing version(s) above)'})."
}
$appType = "$GraphBase/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp"

# 4. Content version -------------------------------------------------------------------------------
Write-Step "Create content version"
$cv = Invoke-Graph POST "$appType/contentVersions" -Headers $H -Body @{}
$cvId = $cv.id
Write-Ok "contentVersion $cvId"

# 5. Register file + poll for SAS ------------------------------------------------------------------
Write-Step "Register file + get upload URI"
$fileBody = @{ '@odata.type'='#microsoft.graph.mobileAppContentFile'; name=$fileName; size=$unencSize; sizeEncrypted=$encSize; manifest=$null; isDependency=$false }
$file = Invoke-Graph POST "$appType/contentVersions/$cvId/files" -Headers $H -Body $fileBody
$fileId = $file.id
$sas = $null
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $f = Invoke-Graph GET "$appType/contentVersions/$cvId/files/$fileId" -Headers $H
    if ($f.uploadState -eq 'azureStorageUriRequestSuccess') { $sas = $f.azureStorageUri; break }
    if ($f.uploadState -eq 'azureStorageUriRequestFailed') { throw "Azure storage URI request failed." }
}
if (-not $sas) { throw "Timed out waiting for the Azure upload URI." }
Write-Ok "SAS URI acquired."

# 6. Block-blob upload -----------------------------------------------------------------------------
Write-Step "Upload encrypted content (block blob)"
# Use HttpClient/ByteArrayContent so the encrypted bytes go up byte-perfect. Invoke-RestMethod with a
# byte[] body re-encodes binary content and corrupts the blob, which then fails the commit's MAC/digest check.
$blockSize = 4 * 1024 * 1024
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromMinutes(10)
function Invoke-BlobPut {
    param([string]$Uri, [byte[]]$Bytes)
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Put, $Uri)
    $req.Content = [System.Net.Http.ByteArrayContent]::new($Bytes)
    $req.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) { throw "Blob PUT $([int]$resp.StatusCode): $($resp.Content.ReadAsStringAsync().GetAwaiter().GetResult())" }
}
$blockIds = New-Object System.Collections.Generic.List[string]
$fs = [IO.File]::OpenRead($encBlob)
try {
    $buf = New-Object byte[] $blockSize
    $idx = 0
    while (($read = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
        $chunk = New-Object byte[] $read; [Array]::Copy($buf, $chunk, $read)
        $blockId = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($idx.ToString('D6')))
        $blockIds.Add($blockId)
        $uri = "$sas&comp=block&blockid=$([uri]::EscapeDataString($blockId))"
        $done = $false
        for ($try = 1; $try -le 3 -and -not $done; $try++) {
            try { Invoke-BlobPut -Uri $uri -Bytes $chunk; $done = $true }
            catch {
                if ($try -eq 3) { throw }
                # SAS may have expired on a long upload - renew and retry.
                try { $null = Invoke-Graph POST "$appType/contentVersions/$cvId/files/$fileId/renewUpload" -Headers $H; Start-Sleep 2
                      $rf = Invoke-Graph GET "$appType/contentVersions/$cvId/files/$fileId" -Headers $H
                      if ($rf.azureStorageUri) { $sas = $rf.azureStorageUri; $uri = "$sas&comp=block&blockid=$([uri]::EscapeDataString($blockId))" } } catch {}
                Start-Sleep -Seconds 2
            }
        }
        Write-Info "block $idx uploaded ($read bytes)"
        $idx++
    }
} finally { $fs.Close() }
$blockListXml = "<?xml version='1.0' encoding='utf-8'?><BlockList>" + (($blockIds | ForEach-Object { "<Latest>$_</Latest>" }) -join '') + "</BlockList>"
$blReq = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Put, "$sas&comp=blocklist")
$blReq.Content = [System.Net.Http.StringContent]::new($blockListXml, [Text.Encoding]::UTF8, 'text/plain')
$blResp = $client.SendAsync($blReq).GetAwaiter().GetResult()
if (-not $blResp.IsSuccessStatusCode) { throw "Block list commit $([int]$blResp.StatusCode): $($blResp.Content.ReadAsStringAsync().GetAwaiter().GetResult())" }
Write-Ok "$($blockIds.Count) block(s) committed to blob storage."

# 7. Commit + poll ---------------------------------------------------------------------------------
Write-Step "Commit file"
$null = Invoke-Graph POST "$appType/contentVersions/$cvId/files/$fileId/commit" -Headers $H -Body @{ fileEncryptionInfo = $fileEncryptionInfo }
$committed = $false
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 4
    $f = Invoke-Graph GET "$appType/contentVersions/$cvId/files/$fileId" -Headers $H
    if ($f.uploadState -eq 'commitFileSuccess') { $committed = $true; break }
    if ($f.uploadState -eq 'commitFileFailed')  { throw "Commit failed (uploadState=commitFileFailed)." }
}
if (-not $committed) { throw "Timed out waiting for commitFileSuccess." }
Write-Ok "Content committed."

# 8. Activate (committedContentVersion) ------------------------------------------------------------
Write-Step "Activate content version"
$null = Invoke-Graph PATCH "$GraphBase/deviceAppManagement/mobileApps/$appId" -Headers $H -Body @{ '@odata.type'='#microsoft.graph.win32LobApp'; committedContentVersion = $cvId }
$portal = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$appId"
Write-Ok "Activated content version $cvId."

# 9. Categories (a $ref relationship, NOT a plain property) -----------------------------------------
$assignedCats = @()
if ($Categories.Count -gt 0) {
    Write-Step "Assign categories"
    $catalog = (Invoke-Graph GET "$GraphBase/deviceAppManagement/mobileAppCategories" -Headers $H).value
    foreach ($name in $Categories) {
        $cat = $catalog | Where-Object { $_.displayName -ieq $name } | Select-Object -First 1
        if (-not $cat) { Write-Info "skip unknown category '$name' (valid: $(( $catalog.displayName ) -join ', '))"; continue }
        try {
            $null = Invoke-Graph POST "$GraphBase/deviceAppManagement/mobileApps/$appId/categories/`$ref" -Headers $H -Body @{ '@odata.id' = "$GraphBase/deviceAppManagement/mobileAppCategories/$($cat.id)" }
            $assignedCats += $cat.displayName; Write-Ok "category '$($cat.displayName)'"
        } catch { $e = Get-GraphErr $_; if ($e.message -match 'already exist') { $assignedCats += $cat.displayName } else { Write-Info "category '$name' failed: $($e.message)" } }
    }
}

# 10. Supersedence (optional) - wire 'new app supersedes old app'. NEVER deletes the old app; Intune
#     stops offering the old one to NEW installs while keeping it for rollback/coexistence.
$supersededWired = $null
if ($SupersedesAppId -and -not $UpdateAppId) {
    Write-Step "Configure supersedence (new supersedes old)"
    try {
        $null = Invoke-Graph POST "$GraphBase/deviceAppManagement/mobileApps/$appId/relationships" -Headers $H -Body ([ordered]@{
            '@odata.type'    = '#microsoft.graph.mobileAppSupersedence'
            supersedenceType = 'replace'
            targetId         = $SupersedesAppId
        })
        $supersededWired = $SupersedesAppId
        Write-Ok "Supersedence set: $appId replaces $SupersedesAppId (old app retained, not deleted)."
    } catch { $e = Get-GraphErr $_; Write-Host "    !   Supersedence not set automatically: $($e.message). Configure it manually in the portal." -ForegroundColor Yellow }
}

Write-Host "`nDone. App is in Intune (NOT assigned to groups - assign to Entra groups manually)." -ForegroundColor Green
Write-Host "  Portal: $portal" -ForegroundColor White
if ($existing -and -not $UpdateAppId) {
    Write-Host "  Coexistence: the existing version(s) [$(($existing | ForEach-Object { $_.id }) -join ', ')] were left intact." -ForegroundColor Gray
    if (-not $supersededWired) {
        Write-Host "  Supersedence: set it in the portal (new app > Supersedence > add the old app), or re-run with -SupersedesAppId <oldId>." -ForegroundColor Gray
    }
}

# Record the upload in the manifest: which app id in which tenant now carries this artifact. Best effort -
# the app IS uploaded at this point, so a manifest write failure must not turn that into an error.
if ($manifestPackagePath) {
    try {
        & (Join-Path $PSScriptRoot 'Set-PsadtPackageManifest.ps1') -PackagePath $manifestPackagePath -Updates @{
            'results.upload' = @{
                appId          = $appId
                contentVersion = $cvId
                portalUrl      = $portal
                displayName    = $DisplayName
                fileName       = $fileName
                tenantId       = $tok.TenantId
                at             = (Get-Date).ToUniversalTime().ToString('o')
            }
        } | Out-Null
    } catch { Write-Warning "Uploaded, but could not record it in the manifest: $($_.Exception.Message)" }
}

[pscustomobject]@{ Executed=$true; AppId=$appId; ContentVersion=$cvId; PortalUrl=$portal; Categories=$assignedCats; Supersedes=$supersededWired; CoexistsWith=@($existing | ForEach-Object { $_.id }); Existing=@($existing) }
}
finally {
    # Remove the extracted work dir - its Detection.xml holds the AES keys; never leave it in %TEMP%.
    if ($work -and (Test-Path $work)) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}

<#
.SYNOPSIS
    SELF-CONTAINED: prepares (and optionally creates via Graph) an Intune Endpoint Security "Windows Firewall
    Rules" policy with ONE program-scoped rule. Read-only dry-run by default; -Execute creates it.

    This script has NO external dependencies (no dot-sourcing of skill helpers, no hardcoded skill path): it is
    copied into an app's Output folder and run on test clients that do NOT have the skill installed. Everything
    it needs - WAM interactive sign-in, the policy body builder, console helpers - is embedded. See SKILL.md,
    binding convention "Self-contained deliverables".

.DESCRIPTION
    Some apps listen for inbound connections and trigger the Windows Defender Firewall prompt on first launch,
    which a non-admin user cannot approve. Pre-creating an inbound ALLOW rule centrally suppresses that prompt.
    Own the rule in EXACTLY ONE place: this policy OR the package install hook - never both.

    Auth for -Execute:
      - -Interactive : WAM (Windows Web Account Manager) delegated sign-in. No app registration, no device code.
                       The signed-in user needs the delegated Intune permission (an Intune admin). Works on any
                       client. WAM downloads the MSAL broker assemblies once to %LOCALAPPDATA%\PsadtIntune\msal.
      - -GraphToken  : pass an existing bearer token (e.g. the skill's app-only Get-GraphToken on the authoring
                       machine: -GraphToken (& scripts/Get-GraphToken.ps1).Token).
    Without either, -Execute prints the manual portal steps (no silent failure).

.PARAMETER FilePath      Program the rule scopes to (mandatory), e.g. C:\Program Files\Vendor\App\app.exe
.PARAMETER RuleName      Firewall rule display name (default derived from the program file name + direction).
.PARAMETER Direction     In | Out (default In).
.PARAMETER Action        Allow | Block (default Allow).
.PARAMETER Profiles      Any of Domain, Private, Public (default all three).
.PARAMETER PolicyName    Intune policy displayName (default derived from the rule name).
.PARAMETER Execute       Create the policy via Graph. Without it the script is a read-only dry run.
.PARAMETER Interactive   WAM (delegated) sign-in. Recommended on a client without the skill / app registration.
.PARAMETER TenantId      Tenant for interactive sign-in (default 'organizations' - pick the account at sign-in).
.PARAMETER GraphToken    Optional bearer token instead of interactive sign-in.

.OUTPUTS
    PSCustomObject: Executed, PolicyName, RuleName, FilePath, Direction, Action, Profiles, PolicyId, DryRun, ManualSteps
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FilePath,
    [string]$RuleName,
    [ValidateSet('In', 'Out')][string]$Direction = 'In',
    [ValidateSet('Allow', 'Block')][string]$Action = 'Allow',
    [ValidateSet('Domain', 'Private', 'Public')][string[]]$Profiles = @('Domain', 'Private', 'Public'),
    [string]$PolicyName,
    [switch]$Execute,
    [switch]$Interactive,
    [string]$TenantId = 'organizations',
    [string]$GraphToken
)
$ErrorActionPreference = 'Stop'

$GraphCliClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'   # "Microsoft Graph Command Line Tools" (public)
$FirewallRulesTemplateId = '19c8aa67-f286-4861-9aa0-f23541d31680_1'
$ConfigScope = 'https://graph.microsoft.com/DeviceManagementConfiguration.ReadWrite.All'

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

# ============================ Testable helpers (pure) ============================
function Get-FirewallProfileMask {
    # Windows firewall profile flags: Domain=1, Private=2, Public=4. Returns the sorted mask integers.
    param([Parameter(Mandatory)][string[]]$Profiles)
    $map = @{ Domain = 1; Private = 2; Public = 4 }
    return @($Profiles | ForEach-Object { $map[$_] } | Sort-Object)
}

function New-FirewallRuleChildren {
    # Builds the child setting instances for one firewall rule (settings-catalog firewall-rules template).
    # The literal token {firewallrulename} in the definition IDs is REQUIRED by the template.
    param(
        [Parameter(Mandatory)][string]$RuleName,
        [Parameter(Mandatory)][string]$FilePath,
        [ValidateSet('In', 'Out')][string]$Direction = 'In',
        [ValidateSet('Allow', 'Block')][string]$Action = 'Allow',
        [string[]]$Profiles = @('Domain', 'Private', 'Public')
    )
    $base = 'vendor_msft_firewall_mdmstore_firewallrules_{firewallrulename}'
    $dirVal = if ($Direction -eq 'In') { "${base}_direction_in" } else { "${base}_direction_out" }
    # Action choice values are numeric: _0 = Block, _1 = Allow (verified against the live template definitions).
    $actVal = if ($Action -eq 'Allow') { "${base}_action_type_1" } else { "${base}_action_type_0" }
    $profMasks = Get-FirewallProfileMask -Profiles $Profiles

    # Template-reference GUIDs from the live "Windows Firewall Rules" template (19c8aa67-...). REQUIRED: a
    # template-based settings-catalog policy needs settingInstanceTemplateReference on each instance and
    # settingValueTemplateReference on each simple/choice value. The profiles COLLECTION carries the instance
    # ref only - a per-value ref there is rejected as a duplicate. Verified by a live 201 Create.
    $T = @{
        name_i = '116a696a-3270-493e-9938-c336cf05ea98'; name_v = '12994a33-6185-4c3d-a0e8-69316f6293ea'
        en_i   = '4e150e1a-6a10-49b2-a20c-911bf44ea767'; en_v   = '7562f243-f281-4f6f-b7e6-ecdb76dc1f1b'
        dir_i  = '2114ad3d-157c-47d3-b646-60fcf50949c7'; dir_v  = '8b45e13b-952d-4164-bbac-37f4e97b7985'
        act_i  = '0565cfd1-21c2-4965-b87f-6bde2b8d2cbd'; act_v  = '419773d8-bffe-4d6f-a91f-286871963f5c'
        fp_i   = 'dd825fa0-961b-4fcc-a6b3-4d2dc0419d4e'; fp_v   = '8c94fefa-67e5-40b5-8d97-6fca4f0c1e98'
        prof_i = '7dc9b243-cdd2-4359-b5f5-0c48edb8fd34'
    }

    $children = @(
        [ordered]@{
            '@odata.type'                    = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
            settingDefinitionId              = "${base}_name"
            settingInstanceTemplateReference = @{ settingInstanceTemplateId = $T.name_i }
            simpleSettingValue               = [ordered]@{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'; settingValueTemplateReference = @{ settingValueTemplateId = $T.name_v }; value = $RuleName }
        },
        [ordered]@{
            '@odata.type'                    = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
            settingDefinitionId              = "${base}_enabled"
            settingInstanceTemplateReference = @{ settingInstanceTemplateId = $T.en_i }
            choiceSettingValue               = [ordered]@{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'; settingValueTemplateReference = @{ settingValueTemplateId = $T.en_v }; value = "${base}_enabled_1"; children = @() }
        },
        [ordered]@{
            '@odata.type'                    = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
            settingDefinitionId              = "${base}_direction"
            settingInstanceTemplateReference = @{ settingInstanceTemplateId = $T.dir_i }
            choiceSettingValue               = [ordered]@{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'; settingValueTemplateReference = @{ settingValueTemplateId = $T.dir_v }; value = $dirVal; children = @() }
        },
        [ordered]@{
            '@odata.type'                    = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
            settingDefinitionId              = "${base}_action_type"
            settingInstanceTemplateReference = @{ settingInstanceTemplateId = $T.act_i }
            choiceSettingValue               = [ordered]@{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'; settingValueTemplateReference = @{ settingValueTemplateId = $T.act_v }; value = $actVal; children = @() }
        },
        [ordered]@{
            # Program path: DIRECT child (id ..._app_filepath), verified against the live template.
            '@odata.type'                    = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
            settingDefinitionId              = "${base}_app_filepath"
            settingInstanceTemplateReference = @{ settingInstanceTemplateId = $T.fp_i }
            simpleSettingValue               = [ordered]@{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'; settingValueTemplateReference = @{ settingValueTemplateId = $T.fp_v }; value = $FilePath }
        },
        [ordered]@{
            '@odata.type'                    = '#microsoft.graph.deviceManagementConfigurationChoiceSettingCollectionInstance'
            settingDefinitionId              = "${base}_profiles"
            settingInstanceTemplateReference = @{ settingInstanceTemplateId = $T.prof_i }
            choiceSettingCollectionValue     = @($profMasks | ForEach-Object {
                [ordered]@{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'; value = "${base}_profiles_$_"; children = @() }
            })
        }
    )
    return $children
}

function New-FirewallPolicyBody {
    # Builds the Graph configurationPolicies request body wrapping one firewall rule's children.
    param(
        [Parameter(Mandatory)][string]$PolicyName,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][object[]]$RuleChildren,
        [string]$TemplateId = '19c8aa67-f286-4861-9aa0-f23541d31680_1'
    )
    return [ordered]@{
        name              = $PolicyName
        description       = $Description
        platforms         = 'windows10'
        technologies      = 'mdm'
        roleScopeTagIds   = @('0')
        templateReference = [ordered]@{ templateId = $TemplateId }
        settings          = @(
            [ordered]@{
                '@odata.type'   = '#microsoft.graph.deviceManagementConfigurationSetting'
                settingInstance = [ordered]@{
                    '@odata.type'                    = '#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance'
                    settingDefinitionId              = 'vendor_msft_firewall_mdmstore_firewallrules_{firewallrulename}'
                    settingInstanceTemplateReference = @{ settingInstanceTemplateId = '76c7a8be-67d2-44bf-81a5-38c94926b1a1' }
                    groupSettingCollectionValue      = @([ordered]@{ children = $RuleChildren })
                }
            }
        )
    }
}

function Get-FirewallPolicyManualSteps {
    # Ready-to-paste portal instructions (the Graph-unavailable fallback).
    param([string]$PolicyName, [string]$RuleName, [string]$FilePath, [string]$Direction, [string]$Action, [string[]]$Profiles)
    $dirText = if ($Direction -eq 'In') { 'In' } else { 'Out' }
    return @"
Manual creation (Intune portal):
  1. Endpoint security > Firewall > Create Policy   (Platform = Windows ; Profile = Windows Firewall Rules)
  2. Policy name: $PolicyName
  3. Add a Firewall rule:
       Firewall Rule Name = $RuleName
       Enabled            = Enabled
       Action             = $Action
       Direction          = $dirText
       File Path          = $FilePath
       Network Types      = $($Profiles -join ', ')
       (leave Interface Types, Protocol, ports, addresses = Not configured)
  4. Assign to the SAME device scope as the app, then Create.
Note: own the rule in ONE place only - this policy OR the package, never both.
"@
}

# ============================ main ============================
$leaf = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
if (-not $RuleName)   { $RuleName = "$leaf ($Direction $Action)" }
if (-not $PolicyName) { $PolicyName = "Firewall - $RuleName" }
$description = "PSADT skill: $Direction $Action firewall rule for $FilePath on $($Profiles -join '/'). Suppresses the first-run firewall prompt (no user admin rights)."

$children = New-FirewallRuleChildren -RuleName $RuleName -FilePath $FilePath -Direction $Direction -Action $Action -Profiles $Profiles
$manual   = Get-FirewallPolicyManualSteps -PolicyName $PolicyName -RuleName $RuleName -FilePath $FilePath -Direction $Direction -Action $Action -Profiles $Profiles

Write-Host "Intune firewall-rules policy (Endpoint Security)" -ForegroundColor White
Write-Info "Policy   : $PolicyName"
Write-Info "Rule     : $RuleName"
Write-Info "Program  : $FilePath"
Write-Info "Direction: $Direction   Action: $Action   Profiles: $($Profiles -join ', ')"

$policyId = $null
if (-not $Execute) {
    Write-Host "`n--- DRY RUN (read-only). Re-run with -Execute (and -Interactive for WAM sign-in) to create it. ---" -ForegroundColor Yellow
    Write-Host $manual -ForegroundColor Gray
} else {
    $token = $null
    try {
        if ($GraphToken)      { $token = $GraphToken }
        elseif ($Interactive) { $token = Get-InteractiveGraphToken -Scopes @($ConfigScope) -TenantId $TenantId }
        else {
            Write-Warn2 "No credential: this self-contained script has no app registration. Re-run with -Interactive (WAM) or pass -GraphToken."
            Write-Host $manual -ForegroundColor Gray
        }
    } catch {
        Write-Warn2 "Sign-in failed: $($_.Exception.Message)"
    }

    if ($token) {
        Assert-ConfigRole $token
        $headers = @{ Authorization = "Bearer $token" }
        $body = New-FirewallPolicyBody -PolicyName $PolicyName -Description $description -RuleChildren $children -TemplateId $FirewallRulesTemplateId
        $json = $body | ConvertTo-Json -Depth 20
        try {
            $created = Invoke-RestMethod -Method Post -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies' -Headers $headers -ContentType 'application/json' -Body $json -ErrorAction Stop
            $policyId = $created.id
            Write-Host "    OK  Policy created ($policyId). Assign it to a device group in the portal." -ForegroundColor Green
        } catch {
            $resp = $_.Exception.Response
            $code = if ($resp) { try { [int]$resp.StatusCode } catch { 0 } } else { 0 }
            $detail = ''
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
            if ($code -eq 403) {
                Write-Warn2 "403 Forbidden - the account/app lacks DeviceManagementConfiguration.ReadWrite.All (Intune admin needed)."
            }
            Write-Host "    Graph error ($code): $detail" -ForegroundColor Red
            Write-Host $manual -ForegroundColor Gray
        }
    }
}

[pscustomobject]@{
    Executed    = [bool]$Execute -and $null -ne $policyId
    PolicyName  = $PolicyName
    RuleName    = $RuleName
    FilePath    = $FilePath
    Direction   = $Direction
    Action      = $Action
    Profiles    = $Profiles
    PolicyId    = $policyId
    DryRun      = (-not $Execute)
    ManualSteps = $manual
}

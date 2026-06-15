<#
.SYNOPSIS
    Prepares (and optionally creates in the tenant) an Intune Endpoint Security "Windows Firewall Rules" policy
    with ONE program-scoped firewall rule. Read-only dry-run by default; -Execute creates it via Microsoft Graph.
    Always emits ready-to-paste manual portal values.

.DESCRIPTION
    Some apps (e.g. MxManagementCenter) listen for inbound connections and trigger the Windows Defender Firewall
    prompt on first launch - which a non-admin user cannot approve. Pre-creating an inbound ALLOW rule centrally
    suppresses that prompt. This builds a settings-catalog firewall-rules policy (template
    19c8aa67-f286-4861-9aa0-f23541d31680_1) with a single program-scoped rule on -FilePath.

    Own the rule in EXACTLY ONE place: either this policy OR the package (Add-NetFirewallRule in the install hook)
    - never both, or they fight on uninstall/sync.

    -Execute needs the Graph application role DeviceManagementConfiguration.ReadWrite.All. The upload app gets it
    via: New-PsadtEntraApp.ps1 -Force -IncludeConfigurationManagement (Global Admin). If the token/role is
    unavailable the script does NOT fail the run - it prints the exact manual portal steps + values and returns them.

.PARAMETER FilePath      Program the rule scopes to, e.g. C:\Program Files\Mobotix\MxManagementCenter\MxManagementCenter.exe
.PARAMETER RuleName      Firewall rule display name (default derived from the program file name + direction).
.PARAMETER Direction     In | Out (default In).
.PARAMETER Action        Allow | Block (default Allow).
.PARAMETER Profiles      Any of Domain, Private, Public (default all three).
.PARAMETER PolicyName    Intune policy displayName (default derived from the rule name).
.PARAMETER Execute       Create the policy via Graph. Without it the script is a read-only dry run.
.PARAMETER GraphToken    Optional bearer token (testing / reuse). Default: Get-GraphToken.ps1.
.PARAMETER SkillRoot     Skill root (config.json). Default: parent of this script.

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
    [string]$GraphToken,
    [string]$SkillRoot = (Split-Path $PSScriptRoot -Parent)
)
$ErrorActionPreference = 'Stop'
$GraphBase = 'https://graph.microsoft.com/beta'
$FirewallRulesTemplateId = '19c8aa67-f286-4861-9aa0-f23541d31680_1'

# --- Shared Graph helpers (Write-*, Get-GraphErr, Invoke-Graph; retry + PS7-safe) ----------------
. (Join-Path $PSScriptRoot '_GraphCommon.ps1')
$script:step = 0

# --- Testable helpers ----------------------------------------------------------------------------
function Get-FirewallProfileMask {
    # Windows firewall profile flags: Domain=1, Private=2, Public=4. Returns the settings-catalog
    # choice-value suffixes for the requested profiles.
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
    $actVal = if ($Action -eq 'Allow') { "${base}_action_type_allow" } else { "${base}_action_type_block" }
    $profMasks = Get-FirewallProfileMask -Profiles $Profiles

    $children = @(
        [ordered]@{
            '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
            settingDefinitionId = "${base}_name"
            simpleSettingValue  = [ordered]@{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'; value = $RuleName }
        },
        [ordered]@{
            '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
            settingDefinitionId = "${base}_enabled"
            choiceSettingValue  = [ordered]@{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'; value = "${base}_enabled_1"; children = @() }
        },
        [ordered]@{
            '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
            settingDefinitionId = "${base}_direction"
            choiceSettingValue  = [ordered]@{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'; value = $dirVal; children = @() }
        },
        [ordered]@{
            '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
            settingDefinitionId = "${base}_action_type"
            choiceSettingValue  = [ordered]@{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'; value = $actVal; children = @() }
        },
        [ordered]@{
            '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
            settingDefinitionId = "${base}_filepath"
            simpleSettingValue  = [ordered]@{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'; value = $FilePath }
        },
        [ordered]@{
            '@odata.type'                = '#microsoft.graph.deviceManagementConfigurationChoiceSettingCollectionInstance'
            settingDefinitionId          = "${base}_profiles"
            choiceSettingCollectionValue = @($profMasks | ForEach-Object {
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
                    '@odata.type'               = '#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance'
                    settingDefinitionId         = 'vendor_msft_firewall_mdmstore_firewallrules'
                    groupSettingCollectionValue = @([ordered]@{ children = $RuleChildren })
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
Manual creation (Intune portal) - if Graph is unavailable or the app lacks DeviceManagementConfiguration.ReadWrite.All:
  1. Endpoint security > Firewall > Create Policy
       Platform = Windows ; Profile = Windows Firewall Rules
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

# --- Resolve names -------------------------------------------------------------------------------
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
    Write-Host "`n--- DRY RUN (read-only). Re-run with -Execute to create the policy via Graph. ---" -ForegroundColor Yellow
    Write-Host $manual -ForegroundColor Gray
} else {
    Write-Step "Creating firewall-rules policy '$PolicyName' via Graph"
    $token = $null
    try {
        $token = if ($GraphToken) { $GraphToken } else { (& (Join-Path $PSScriptRoot 'Get-GraphToken.ps1') -SkillRoot $SkillRoot).Token }
    } catch {
        Write-Warn2 "No Graph token ($($_.Exception.Message)). Falling back to manual instructions."
    }

    if ($token) {
        $H = @{ Authorization = "Bearer $token" }
        $body = New-FirewallPolicyBody -PolicyName $PolicyName -Description $description -RuleChildren $children -TemplateId $FirewallRulesTemplateId
        try {
            $created = Invoke-Graph POST "$GraphBase/deviceManagement/configurationPolicies" -Headers $H -Body $body
            $policyId = $created.id
            Write-Ok "Policy created ($policyId). Assign it to the app's device scope in the portal (or via assignments API)."
        } catch {
            $e = Get-GraphErr $_
            if ($e.code -match 'Authorization|Forbidden' -or "$($e.message)" -match 'privile|permission|scope') {
                Write-Warn2 "Graph denied policy creation ($($e.code)). The upload app lacks DeviceManagementConfiguration.ReadWrite.All."
                Write-Info  "Grant it (Global Admin): New-PsadtEntraApp.ps1 -Force -IncludeConfigurationManagement   - or create the policy manually:"
                Write-Host $manual -ForegroundColor Gray
            } else { throw }
        }
    } else {
        Write-Host $manual -ForegroundColor Gray
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

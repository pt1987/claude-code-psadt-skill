#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/New-IntuneFirewallPolicy.ps1 - the profile mask mapping, the firewall-rule child setting
    instances (name/direction/action/filepath/profiles), the settings-catalog policy body shape, the manual
    portal fallback text, and the read-only dry run (no token / no Graph call).
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:FwScript = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\New-IntuneFirewallPolicy.ps1')).Path

    foreach ($fn in 'Get-FirewallProfileMask', 'New-FirewallRuleChildren', 'New-FirewallPolicyBody', 'Get-FirewallPolicyManualSteps', 'Assert-ConfigRole') {
        . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:FwScript -Name $fn)))
    }
    $script:exe = 'C:\Program Files\Mobotix\MxManagementCenter\MxManagementCenter.exe'
}

Describe 'Get-FirewallProfileMask' {
    It 'maps Domain/Private/Public to 1/2/4 (sorted)' {
        Get-FirewallProfileMask -Profiles @('Public', 'Domain', 'Private') | Should -Be @(1, 2, 4)
    }
    It 'maps a single profile' {
        Get-FirewallProfileMask -Profiles @('Public') | Should -Be @(4)
    }
}

Describe 'New-FirewallRuleChildren' {
    BeforeAll {
        $script:children = New-FirewallRuleChildren -RuleName 'MxMC In' -FilePath $script:exe -Direction In -Action Allow -Profiles @('Domain', 'Private', 'Public')
    }
    It 'sets the rule name on the _name simple setting' {
        $n = $script:children | Where-Object { $_.settingDefinitionId -like '*_name' }
        $n.simpleSettingValue.value | Should -Be 'MxMC In'
    }
    It 'sets the program on the _app_filepath simple setting (direct child, verified against the template)' {
        $f = $script:children | Where-Object { $_.settingDefinitionId -like '*_app_filepath' }
        $f.simpleSettingValue.value | Should -Be $script:exe
        $f.'@odata.type' | Should -Be '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
    }
    It 'encodes direction=in and action=allow as the verified choice values (_direction_in / _action_type_1)' {
        ($script:children | Where-Object { $_.settingDefinitionId -like '*_direction' }).choiceSettingValue.value   | Should -Match '_direction_in$'
        ($script:children | Where-Object { $_.settingDefinitionId -like '*_action_type' }).choiceSettingValue.value | Should -Match '_action_type_1$'
    }
    It 'emits one profile choice per requested profile' {
        $p = $script:children | Where-Object { $_.settingDefinitionId -like '*_profiles' }
        $p.choiceSettingCollectionValue.Count | Should -Be 3
    }
    It 'attaches the template references required by the firewall template (verified by live 201)' {
        # Each instance needs settingInstanceTemplateReference; each simple/choice value a settingValueTemplateReference.
        $act = $script:children | Where-Object { $_.settingDefinitionId -like '*_action_type' }
        $act.settingInstanceTemplateReference.settingInstanceTemplateId | Should -Not -BeNullOrEmpty
        $act.choiceSettingValue.settingValueTemplateReference.settingValueTemplateId | Should -Not -BeNullOrEmpty
        # The profiles COLLECTION carries the instance ref only - a per-value ref is rejected as a duplicate.
        $prof = $script:children | Where-Object { $_.settingDefinitionId -like '*_profiles' }
        $prof.settingInstanceTemplateReference.settingInstanceTemplateId | Should -Not -BeNullOrEmpty
        ([bool]$prof.choiceSettingCollectionValue[0].Contains('settingValueTemplateReference')) | Should -BeFalse
    }
    It 'encodes Block + Out direction when requested (_direction_out / _action_type_0)' {
        $c = New-FirewallRuleChildren -RuleName 'r' -FilePath $script:exe -Direction Out -Action Block -Profiles @('Public')
        ($c | Where-Object { $_.settingDefinitionId -like '*_direction' }).choiceSettingValue.value   | Should -Match '_direction_out$'
        ($c | Where-Object { $_.settingDefinitionId -like '*_action_type' }).choiceSettingValue.value | Should -Match '_action_type_0$'
        ($c | Where-Object { $_.settingDefinitionId -like '*_profiles' }).choiceSettingCollectionValue.Count | Should -Be 1
    }
}

Describe 'New-FirewallPolicyBody' {
    It 'wraps the children in a firewall-rules settings-catalog policy (mdm, templateRef, group instance)' {
        $children = New-FirewallRuleChildren -RuleName 'r' -FilePath $script:exe
        $body = New-FirewallPolicyBody -PolicyName 'P' -Description 'D' -RuleChildren $children
        $body.technologies | Should -Be 'mdm'
        $body.platforms | Should -Be 'windows10'
        $body.templateReference.templateId | Should -Be '19c8aa67-f286-4861-9aa0-f23541d31680_1'
        $body.settings[0].settingInstance.settingDefinitionId | Should -Be 'vendor_msft_firewall_mdmstore_firewallrules_{firewallrulename}'
        $body.settings[0].settingInstance.settingInstanceTemplateReference.settingInstanceTemplateId | Should -Be '76c7a8be-67d2-44bf-81a5-38c94926b1a1'
        $body.settings[0].settingInstance.groupSettingCollectionValue[0].children.Count | Should -Be $children.Count
    }
}

Describe 'Get-FirewallPolicyManualSteps' {
    It 'includes File Path, Network Types and points at the Windows Firewall Rules profile' {
        $m = Get-FirewallPolicyManualSteps -PolicyName 'P' -RuleName 'r' -FilePath $script:exe -Direction In -Action Allow -Profiles @('Domain', 'Private')
        $m | Should -Match 'Windows Firewall Rules'
        $m | Should -Match ([regex]::Escape($script:exe))
        $m | Should -Match 'Network Types\s*=\s*Domain, Private'
    }
}

Describe 'Dry run (read-only, no Graph)' {
    It 'returns DryRun=true / Executed=false with no policy id and the chosen fields' {
        $r = & $script:FwScript -FilePath $script:exe -Direction In -Action Allow
        $r.DryRun | Should -BeTrue
        $r.Executed | Should -BeFalse
        $r.PolicyId | Should -BeNullOrEmpty
        $r.FilePath | Should -Be $script:exe
        $r.Direction | Should -Be 'In'
        $r.Action | Should -Be 'Allow'
        $r.Profiles | Should -Be @('Domain', 'Private', 'Public')
    }
    It 'accepts -Interactive without touching auth in dry-run (no WAM/Graph call)' {
        # Dry run returns before any token acquisition, so -Interactive must not trigger a sign-in here.
        $r = & $script:FwScript -FilePath $script:exe -Interactive
        $r.DryRun | Should -BeTrue
        $r.Executed | Should -BeFalse
    }
}

Describe 'Self-contained deliverable (copy-to-client safety)' {
    # This script is copied into an app Output folder and run on arbitrary test clients that do NOT have the
    # skill installed. It must therefore carry everything it needs - no dot-sourcing of skill helpers and no
    # hardcoded skill/user path. (Binding convention: SKILL.md "self-contained deliverables".)
    BeforeAll { $script:src = Get-Content -LiteralPath $script:FwScript -Raw }
    It 'does not dot-source shared skill helpers (_GraphCommon / _GraphInteractive)' {
        $script:src | Should -Not -Match '_GraphCommon\.ps1'
        $script:src | Should -Not -Match '_GraphInteractive\.ps1'
    }
    It 'has no hardcoded skill/user path' {
        $script:src | Should -Not -Match 'PatrickTaubert'
        $script:src | Should -Not -Match 'skills[\\/]psadt-deploy'
    }
    It 'embeds its own WAM interactive sign-in (no external dependency)' {
        $script:src | Should -Match 'function Initialize-MsalBroker'
        $script:src | Should -Match 'function Get-InteractiveGraphToken'
    }
}

Describe 'Assert-ConfigRole (the embedded copy - this script stays self-contained)' {
    BeforeAll {
        function New-RoleToken([object]$Roles) {
            $claims = if ($null -eq $Roles) { @{ idtyp = 'app' } } else { @{ idtyp = 'app'; roles = $Roles } }
            $json = $claims | ConvertTo-Json -Compress
            $b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
            return "eyJhbGciOiJSUzI1NiJ9.$b64.signature"
        }
    }
    It 'passes silently when the token carries the config role' {
        { Assert-ConfigRole (New-RoleToken @('DeviceManagementConfiguration.ReadWrite.All')) } | Should -Not -Throw
    }
    It 'names the missing permission and the way to get it' {
        { Assert-ConfigRole (New-RoleToken @('DeviceManagementApps.ReadWrite.All')) } |
            Should -Throw -ExpectedMessage '*DeviceManagementConfiguration.ReadWrite.All*IncludeConfigurationManagement*'
    }
    It 'falls through for a roleless token - a delegated -Interactive sign-in carries no roles claim' {
        { Assert-ConfigRole (New-RoleToken $null) } | Should -Not -Throw
    }
    It 'falls through for an opaque token instead of blocking - Graph tokens are opaque by contract' {
        { Assert-ConfigRole 'not-a-jwt' } | Should -Not -Throw
    }
}

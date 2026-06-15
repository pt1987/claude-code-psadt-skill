#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/New-IntuneFirewallPolicy.ps1 - the profile mask mapping, the firewall-rule child setting
    instances (name/direction/action/filepath/profiles), the settings-catalog policy body shape, the manual
    portal fallback text, and the read-only dry run (no token / no Graph call).
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:FwScript = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\New-IntuneFirewallPolicy.ps1')).Path

    foreach ($fn in 'Get-FirewallProfileMask', 'New-FirewallRuleChildren', 'New-FirewallPolicyBody', 'Get-FirewallPolicyManualSteps') {
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
    It 'sets the program on the _filepath simple setting' {
        $f = $script:children | Where-Object { $_.settingDefinitionId -like '*_filepath' }
        $f.simpleSettingValue.value | Should -Be $script:exe
    }
    It 'encodes direction=in and action=allow as the right choice values' {
        ($script:children | Where-Object { $_.settingDefinitionId -like '*_direction' }).choiceSettingValue.value   | Should -Match '_direction_in$'
        ($script:children | Where-Object { $_.settingDefinitionId -like '*_action_type' }).choiceSettingValue.value | Should -Match '_action_type_allow$'
    }
    It 'emits one profile choice per requested profile' {
        $p = $script:children | Where-Object { $_.settingDefinitionId -like '*_profiles' }
        $p.choiceSettingCollectionValue.Count | Should -Be 3
    }
    It 'encodes Block + Out direction when requested' {
        $c = New-FirewallRuleChildren -RuleName 'r' -FilePath $script:exe -Direction Out -Action Block -Profiles @('Public')
        ($c | Where-Object { $_.settingDefinitionId -like '*_direction' }).choiceSettingValue.value   | Should -Match '_direction_out$'
        ($c | Where-Object { $_.settingDefinitionId -like '*_action_type' }).choiceSettingValue.value | Should -Match '_action_type_block$'
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
        $body.settings[0].settingInstance.settingDefinitionId | Should -Be 'vendor_msft_firewall_mdmstore_firewallrules'
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

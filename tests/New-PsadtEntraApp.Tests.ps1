#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/New-PsadtEntraApp.ps1 internal helpers - importantly
    Invoke-WithRetry, which carried the operator-precedence bug (retried EVERY error, including real
    denials). The WAM / device-code sign-in paths are interactive and intentionally not unit-tested.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    . (Join-Path $PSScriptRoot '..\scripts\_GraphCommon.ps1')   # provides Get-GraphErr + Write-Info used by Invoke-WithRetry
    $entra = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\New-PsadtEntraApp.ps1')).Path
    . ([scriptblock]::Create((Get-ScriptFunctionText -Path $entra -Name 'Invoke-WithRetry')))
    . ([scriptblock]::Create((Get-ScriptFunctionText -Path $entra -Name 'Merge-RequiredResourceAccess')))
    . ([scriptblock]::Create((Get-ScriptFunctionText -Path $entra -Name 'Get-StaleCredentialKeys')))
    $script:GraphAppId = '00000003-0000-0000-c000-000000000000'

    function New-CodedError([string]$Code) {
        $ex = [System.Exception]::new($Code)
        $err = [System.Management.Automation.ErrorRecord]::new($ex, $Code, 'NotSpecified', $null)
        $err.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":{"code":"' + $Code + '","message":"x"}}')
        return $err
    }
}

Describe 'Invoke-WithRetry (precedence-fix regression guard)' {
    It 'does NOT retry a non-replication error - throws after a single attempt' {
        $script:n = 0
        { Invoke-WithRetry -Action { $script:n++; throw (New-CodedError 'BadRequest') } -Tries 6 -DelaySec 0 } | Should -Throw
        $script:n | Should -Be 1   # with the bug this was 6
    }
    It 'retries a replication-lag error (Request_ResourceNotFound) then succeeds' {
        $script:n = 0
        $r = Invoke-WithRetry -Action {
            $script:n++
            if ($script:n -lt 3) { throw (New-CodedError 'Request_ResourceNotFound') }
            'ok'
        } -Tries 6 -DelaySec 0
        $r | Should -Be 'ok'
        $script:n | Should -Be 3
    }
    It 'retries a just-granted-permission denial (Authorization_RequestDenied) - replication lag' {
        $script:n = 0
        { Invoke-WithRetry -Action { $script:n++; throw (New-CodedError 'Authorization_RequestDenied') } -Tries 3 -DelaySec 0 } | Should -Throw
        $script:n | Should -Be 3   # tried, retried, gave up after Tries
    }
}

Describe 'Merge-RequiredResourceAccess (never revoke what an earlier run requested)' {
    It 'keeps existing roles and adds the new one' {
        $existing = @(@{ resourceAppId = $script:GraphAppId; resourceAccess = @(@{ id = 'role-upload'; type = 'Role' }) })
        $m = Merge-RequiredResourceAccess -Existing $existing -ResourceAppId $script:GraphAppId -RoleIds @('role-upload', 'role-config')
        $graph = @($m | Where-Object { $_.resourceAppId -eq $script:GraphAppId })
        $graph.Count | Should -Be 1
        @($graph[0].resourceAccess.id) | Should -Contain 'role-upload'
        @($graph[0].resourceAccess.id) | Should -Contain 'role-config'
    }
    It 'does NOT drop a role the current run did not ask for' {
        # The old code replaced the array: a run without -IncludeConfigurationManagement revoked the
        # config role from the app's requested permissions.
        $existing = @(@{ resourceAppId = $script:GraphAppId; resourceAccess = @(
            @{ id = 'role-upload'; type = 'Role' }, @{ id = 'role-config'; type = 'Role' }) })
        $m = Merge-RequiredResourceAccess -Existing $existing -ResourceAppId $script:GraphAppId -RoleIds @('role-upload')
        @(($m | Where-Object { $_.resourceAppId -eq $script:GraphAppId }).resourceAccess.id) | Should -Contain 'role-config'
    }
    It 'never duplicates an id' {
        $existing = @(@{ resourceAppId = $script:GraphAppId; resourceAccess = @(@{ id = 'role-upload'; type = 'Role' }) })
        $m = Merge-RequiredResourceAccess -Existing $existing -ResourceAppId $script:GraphAppId -RoleIds @('role-upload', 'role-upload')
        @(($m | Where-Object { $_.resourceAppId -eq $script:GraphAppId }).resourceAccess).Count | Should -Be 1
    }
    It 'leaves another resource (non-Graph) untouched' {
        $existing = @(
            @{ resourceAppId = 'other-api'; resourceAccess = @(@{ id = 'x'; type = 'Scope' }) }
            @{ resourceAppId = $script:GraphAppId; resourceAccess = @(@{ id = 'role-upload'; type = 'Role' }) }
        )
        $m = Merge-RequiredResourceAccess -Existing $existing -ResourceAppId $script:GraphAppId -RoleIds @('role-groups')
        $other = @($m | Where-Object { $_.resourceAppId -eq 'other-api' })
        $other.Count | Should -Be 1
        $other[0].resourceAccess[0].type | Should -Be 'Scope'
    }
    It 'creates the Graph entry when the app has no requested permissions yet' {
        # NOTE the @(): PowerShell unwraps a single-element array on return, so the caller MUST re-wrap
        # before putting this in a request body - Graph needs a JSON array, not a bare object.
        $m = @(Merge-RequiredResourceAccess -Existing @() -ResourceAppId $script:GraphAppId -RoleIds @('role-upload'))
        $m.Count | Should -Be 1
        $m[0].resourceAppId | Should -Be $script:GraphAppId
        $m[0].resourceAccess[0].type | Should -Be 'Role'
    }
    It 'survives the single-entry round trip through ConvertTo-Json as an ARRAY' {
        $m = @(Merge-RequiredResourceAccess -Existing @() -ResourceAppId $script:GraphAppId -RoleIds @('role-upload'))
        $json = @{ requiredResourceAccess = $m } | ConvertTo-Json -Depth 10
        # A bare object here is the bug: Graph rejects requiredResourceAccess that is not an array.
        $json | Should -Match '"requiredResourceAccess":\s*\['
    }
}

Describe 'Get-StaleCredentialKeys (a method switch must not leave the other pointer behind)' {
    It 'removes the secret reference when switching to a certificate' {
        Get-StaleCredentialKeys $true | Should -Be @('intune.secretRef')
    }
    It 'removes the certificate thumbprint when switching to a client secret' {
        Get-StaleCredentialKeys $false | Should -Be @('intune.certThumbprint')
    }
}

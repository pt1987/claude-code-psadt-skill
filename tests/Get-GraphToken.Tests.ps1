#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/Get-GraphToken.ps1 (DPAPI client-secret path). Verifies the DPAPI round-trip
    (Set -> stored -> decrypted -> used in the token request) and that the decrypted secret is NEVER
    part of the returned object. The token endpoint is mocked - no network.

    Note: DPAPI is CurrentUser-bound, so this round-trips only as the user running the test (by design).
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:TokenScript = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Get-GraphToken.ps1')).Path

    function New-FakeJwt([hashtable]$Claims) {
        $json = $Claims | ConvertTo-Json -Compress
        $b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        return "eyJhbGciOiJSUzI1NiJ9.$b64.signature"
    }
    function New-SecretConfig([string]$Root) {
        @{ version = 1; intune = @{ tenantId = 'tenant-123'; clientId = 'client-456'; secretRef = 'secret.dpapi'; uploadEnabled = $true } } |
            ConvertTo-Json | Set-Content -Path (Join-Path $Root 'config.json') -Encoding UTF8
        ConvertFrom-SecureString (ConvertTo-SecureString 'super-secret-value' -AsPlainText -Force) |
            Set-Content -Path (Join-Path $Root 'secret.dpapi') -Encoding ASCII -NoNewline
    }
}

Describe 'Get-GraphToken (DPAPI secret path)' {
    It 'decrypts the DPAPI secret, requests a token, and returns Token/Tenant/Client (no secret leak)' {
        $tmp = New-TempSkillRoot
        try {
            @{ version = 1; intune = @{ tenantId = 'tenant-123'; clientId = 'client-456'; secretRef = 'secret.dpapi'; uploadEnabled = $true } } |
                ConvertTo-Json | Set-Content -Path (Join-Path $tmp 'config.json') -Encoding UTF8
            # Store a DPAPI secret exactly as Set-PsadtConfig would.
            $secret = 'super-secret-value'
            ConvertFrom-SecureString (ConvertTo-SecureString $secret -AsPlainText -Force) |
                Set-Content -Path (Join-Path $tmp 'secret.dpapi') -Encoding ASCII -NoNewline

            Mock Invoke-RestMethod {
                return [pscustomobject]@{ access_token = 'fake-access-token'; expires_in = 3600 }
            } -ParameterFilter { $Uri -like '*oauth2/v2.0/token' }

            $result = & $script:TokenScript -SkillRoot $tmp

            $result.Token | Should -Be 'fake-access-token'
            $result.TenantId | Should -Be 'tenant-123'
            $result.ClientId | Should -Be 'client-456'
            # The decrypted secret must have reached the token request (proves the DPAPI round-trip).
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Body.client_secret -eq 'super-secret-value' }
            # ...but must NOT be exposed on the returned object.
            ($result.PSObject.Properties.Value -join '|') | Should -Not -Match ([regex]::Escape($secret))
        }
        finally { Remove-TempSkillRoot $tmp }
    }

    It 'throws a clear error when tenantId/clientId are missing' {
        $tmp = New-TempSkillRoot
        try {
            @{ version = 1; intune = @{ uploadEnabled = $true } } | ConvertTo-Json |
                Set-Content -Path (Join-Path $tmp 'config.json') -Encoding UTF8
            { & $script:TokenScript -SkillRoot $tmp -ErrorAction Stop } | Should -Throw -ExpectedMessage '*missing*'
        }
        finally { Remove-TempSkillRoot $tmp }
    }
}

Describe 'Get-GraphToken (access state, 0.20.0)' {
    It 'reports the granted app roles and the auth method used' {
        $tmp = New-TempSkillRoot
        try {
            New-SecretConfig $tmp
            $jwt = New-FakeJwt @{ idtyp = 'app'; roles = @('DeviceManagementApps.ReadWrite.All', 'Group.Create') }
            Mock Invoke-RestMethod { [pscustomobject]@{ access_token = $jwt; expires_in = 3600 } } -ParameterFilter { $Uri -like '*oauth2/v2.0/token' }

            $r = & $script:TokenScript -SkillRoot $tmp
            $r.AuthMethod | Should -Be 'ClientSecret'
            $r.Roles      | Should -Contain 'DeviceManagementApps.ReadWrite.All'
            $r.Roles      | Should -Contain 'Group.Create'
        }
        finally { Remove-TempSkillRoot $tmp }
    }

    It 'reports no roles (not an error) when the token is opaque' {
        $tmp = New-TempSkillRoot
        try {
            New-SecretConfig $tmp
            Mock Invoke-RestMethod { [pscustomobject]@{ access_token = 'opaque-token'; expires_in = 3600 } } -ParameterFilter { $Uri -like '*oauth2/v2.0/token' }

            $r = & $script:TokenScript -SkillRoot $tmp
            $r.Token       | Should -Be 'opaque-token'
            @($r.Roles).Count | Should -Be 0
        }
        finally { Remove-TempSkillRoot $tmp }
    }

    It 'turns an expired-secret AADSTS code into an actionable message' {
        $tmp = New-TempSkillRoot
        try {
            New-SecretConfig $tmp
            Mock Invoke-RestMethod { throw 'AADSTS7000222: The provided client secret keys for app are expired.' } -ParameterFilter { $Uri -like '*oauth2/v2.0/token' }

            { & $script:TokenScript -SkillRoot $tmp -ErrorAction Stop } | Should -Throw -ExpectedMessage '*EXPIRED*New-PsadtEntraApp*'
        }
        finally { Remove-TempSkillRoot $tmp }
    }

    It 'rethrows an unmapped token failure unchanged' {
        $tmp = New-TempSkillRoot
        try {
            New-SecretConfig $tmp
            Mock Invoke-RestMethod { throw 'socket closed' } -ParameterFilter { $Uri -like '*oauth2/v2.0/token' }

            { & $script:TokenScript -SkillRoot $tmp -ErrorAction Stop } | Should -Throw -ExpectedMessage '*socket closed*'
        }
        finally { Remove-TempSkillRoot $tmp }
    }
}

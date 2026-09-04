#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/Test-PsadtIntuneAccess.ps1 - the read-only Intune access verdict. The real
    Get-GraphToken.ps1 runs (DPAPI round-trip included); only the token endpoint is mocked, so these tests
    cover the whole chain config -> token -> roles -> capabilities without touching the network.

    The three-valued TokenOk is the point of this script: $true verified, $false AAD said no, $null we
    could not ask (offline / not configured). $null must never overwrite persisted state.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:Access = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Test-PsadtIntuneAccess.ps1')).Path

    function New-FakeJwt([hashtable]$Claims) {
        $json = $Claims | ConvertTo-Json -Compress
        $b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        return "eyJhbGciOiJSUzI1NiJ9.$b64.signature"
    }

    # A config whose upload block is complete, plus the DPAPI secret it points at.
    function Set-UploadConfig {
        param([string]$Root, [hashtable]$Extra)
        $intune = @{ tenantId = 'tenant-123'; clientId = 'client-456'; secretRef = 'secret.dpapi'; uploadEnabled = $true }
        if ($Extra) { foreach ($k in $Extra.Keys) { $intune[$k] = $Extra[$k] } }
        @{
            version  = 1
            paths    = @{ packageRoot = 'c:\p'; outputRoot = 'c:\o'; intuneWinAppUtil = 'c:\t\x.exe' }
            language = @{ script = 'EN'; dossier = 'DE' }
            author   = @{ person = 'Pat'; company = 'PHAT' }
            intune   = $intune
        } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Root 'config.json')
        ConvertFrom-SecureString (ConvertTo-SecureString 'super-secret-value' -AsPlainText -Force) |
            Set-Content -Path (Join-Path $Root 'secret.dpapi') -Encoding ASCII -NoNewline
    }
    function Get-Cfg([string]$Root) { Get-Content (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json }
}

Describe 'Test-PsadtIntuneAccess' {
    BeforeEach { $script:root = New-TempSkillRoot }
    AfterEach  { Remove-TempSkillRoot $script:root }

    It 'reports NotConfigured without asking anyone, and persists nothing' {
        @{ version = 1; author = @{ person = 'Pat' } } | ConvertTo-Json | Set-Content (Join-Path $script:root 'config.json')
        Mock Invoke-RestMethod { throw 'the network must not be touched' }

        $r = & $script:Access -SkillRoot $script:root

        $r.Configured | Should -BeFalse
        $r.TokenOk    | Should -BeNullOrEmpty
        $r.Hints      | Should -Not -BeNullOrEmpty
        Should -Invoke Invoke-RestMethod -Times 0
        (Get-Cfg $script:root).intune | Should -BeNullOrEmpty
    }

    It 'reports Incomplete as not-configured and names the gap' {
        # uploadEnabled with no credential file -> the resolver calls it Incomplete.
        @{
            version  = 1
            paths    = @{ packageRoot = 'c:\p'; outputRoot = 'c:\o'; intuneWinAppUtil = 'c:\t\x.exe' }
            language = @{ script = 'EN'; dossier = 'DE' }
            author   = @{ person = 'Pat'; company = 'PHAT' }
            intune   = @{ tenantId = 't'; clientId = 'c'; secretRef = 'secret.dpapi'; uploadEnabled = $true }
        } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:root 'config.json')

        $r = & $script:Access -SkillRoot $script:root
        $r.Configured | Should -BeFalse
        $r.TokenOk    | Should -BeNullOrEmpty
        ($r.Hints -join ' ') | Should -BeLike '*intune.secret*'
    }

    It 'verifies a working app-only token and derives the capabilities' {
        Set-UploadConfig -Root $script:root
        $jwt = New-FakeJwt @{ idtyp = 'app'; roles = @('DeviceManagementApps.ReadWrite.All') }
        Mock Invoke-RestMethod { [pscustomobject]@{ access_token = $jwt; expires_in = 3600 } } -ParameterFilter { $Uri -like '*oauth2/v2.0/token' }

        $r = & $script:Access -SkillRoot $script:root

        $r.Configured                | Should -BeTrue
        $r.TokenOk                   | Should -BeTrue
        $r.AuthMethod                | Should -Be 'ClientSecret'
        $r.TenantId                  | Should -Be 'tenant-123'
        $r.Capabilities.Upload       | Should -BeTrue
        $r.Capabilities.Groups       | Should -BeFalse
        $r.Capabilities.Configuration| Should -BeFalse
        $r.LastVerified              | Should -Not -BeNullOrEmpty

        $cfg = Get-Cfg $script:root
        $cfg.intune.roles        | Should -Contain 'DeviceManagementApps.ReadWrite.All'
        $cfg.intune.lastVerified | Should -Not -BeNullOrEmpty
    }

    It 'needs BOTH group roles before it claims the Groups capability' {
        Set-UploadConfig -Root $script:root
        $jwt = New-FakeJwt @{ idtyp = 'app'; roles = @('DeviceManagementApps.ReadWrite.All', 'Group.Create') }
        Mock Invoke-RestMethod { [pscustomobject]@{ access_token = $jwt; expires_in = 3600 } } -ParameterFilter { $Uri -like '*oauth2/v2.0/token' }

        $r = & $script:Access -SkillRoot $script:root
        $r.Capabilities.Groups | Should -BeFalse
        ($r.Hints -join ' ')   | Should -BeLike '*GroupMember.Read.All*'
    }

    It 'leaves every capability unknown when the token cannot be introspected' {
        Set-UploadConfig -Root $script:root
        Mock Invoke-RestMethod { [pscustomobject]@{ access_token = 'opaque-token'; expires_in = 3600 } } -ParameterFilter { $Uri -like '*oauth2/v2.0/token' }

        $r = & $script:Access -SkillRoot $script:root
        $r.TokenOk                  | Should -BeTrue
        $r.Capabilities.Upload      | Should -BeNullOrEmpty   # unknown, NOT false
        ($r.Hints -join ' ')        | Should -BeLike '*could not be read*'
    }

    It 'reports TokenOk=$false with the actionable hint when AAD refuses' {
        Set-UploadConfig -Root $script:root -Extra @{ roles = @('DeviceManagementApps.ReadWrite.All') }
        Mock Invoke-RestMethod { throw 'AADSTS7000222: The provided client secret keys for app are expired.' } -ParameterFilter { $Uri -like '*oauth2/v2.0/token' }

        $r = & $script:Access -SkillRoot $script:root
        $r.TokenOk           | Should -BeFalse
        ($r.Hints -join ' ') | Should -BeLike '*EXPIRED*'
        # A refusal is not a reason to forget what the app was granted.
        (Get-Cfg $script:root).intune.roles | Should -Contain 'DeviceManagementApps.ReadWrite.All'
    }

    It 'reports TokenOk=$null when offline and keeps the persisted roles' {
        Set-UploadConfig -Root $script:root -Extra @{ roles = @('DeviceManagementApps.ReadWrite.All'); lastVerified = '2026-09-01T10:00:00Z' }
        Mock Invoke-RestMethod { throw 'No such host is known.' } -ParameterFilter { $Uri -like '*oauth2/v2.0/token' }

        $r = & $script:Access -SkillRoot $script:root
        $r.TokenOk      | Should -BeNullOrEmpty
        $r.Roles        | Should -Contain 'DeviceManagementApps.ReadWrite.All'   # from config, not the token
        $r.LastVerified.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss') | Should -Be '2026-09-01T10:00:00'
        ($r.Hints -join ' ') | Should -BeLike '*could not be reached*'
        # The stored timestamp must be untouched: being offline proves nothing about the app.
        ([datetime](Get-Cfg $script:root).intune.lastVerified).ToUniversalTime().ToString('yyyy-MM-dd') | Should -Be '2026-09-01'
    }

    It 'calls an undecryptable DPAPI secret REFUSED, not unknown' {
        # What a re-installed Windows leaves behind: the file is there, the DPAPI master key is not.
        Set-UploadConfig -Root $script:root -Extra @{ roles = @('DeviceManagementApps.ReadWrite.All') }
        Set-Content (Join-Path $script:root 'secret.dpapi') 'not-a-dpapi-blob' -NoNewline
        Mock Invoke-RestMethod { throw 'the token endpoint must not be reached' } -ParameterFilter { $Uri -like '*oauth2/v2.0/token' }

        $r = & $script:Access -SkillRoot $script:root
        $r.TokenOk           | Should -BeFalse
        ($r.Hints -join ' ') | Should -BeLike '*cannot be decrypted*New-PsadtEntraApp*'
        Should -Invoke Invoke-RestMethod -Times 0
    }

    It 'writes nothing with -NoPersist' {
        Set-UploadConfig -Root $script:root
        $jwt = New-FakeJwt @{ idtyp = 'app'; roles = @('DeviceManagementApps.ReadWrite.All') }
        Mock Invoke-RestMethod { [pscustomobject]@{ access_token = $jwt; expires_in = 3600 } } -ParameterFilter { $Uri -like '*oauth2/v2.0/token' }

        $r = & $script:Access -SkillRoot $script:root -NoPersist
        $r.TokenOk | Should -BeTrue
        $cfg = Get-Cfg $script:root
        $cfg.intune.roles        | Should -BeNullOrEmpty
        $cfg.intune.lastVerified | Should -BeNullOrEmpty
    }

    It 'counts down to the credential expiry and warns inside 30 days' {
        $soon = (Get-Date).AddDays(10)
        Set-UploadConfig -Root $script:root -Extra @{ credExpires = $soon.ToString('o'); appDisplayName = 'PSADT Intune Upload' }
        $jwt = New-FakeJwt @{ idtyp = 'app'; roles = @('DeviceManagementApps.ReadWrite.All') }
        Mock Invoke-RestMethod { [pscustomobject]@{ access_token = $jwt; expires_in = 3600 } } -ParameterFilter { $Uri -like '*oauth2/v2.0/token' }

        $r = & $script:Access -SkillRoot $script:root
        $r.AppDisplayName | Should -Be 'PSADT Intune Upload'
        $r.DaysToExpiry   | Should -BeIn @(9, 10)
        ($r.Hints -join ' ') | Should -BeLike '*expires in*'
    }

    It 'writes the verdict to -JsonPath' {
        Set-UploadConfig -Root $script:root
        $jwt = New-FakeJwt @{ idtyp = 'app'; roles = @('DeviceManagementApps.ReadWrite.All') }
        Mock Invoke-RestMethod { [pscustomobject]@{ access_token = $jwt; expires_in = 3600 } } -ParameterFilter { $Uri -like '*oauth2/v2.0/token' }

        $out = Join-Path $script:root 'report/access.json'
        $r = & $script:Access -SkillRoot $script:root -JsonPath $out
        (Test-Path $out) | Should -BeTrue
        (Get-Content $out -Raw | ConvertFrom-Json).TokenOk | Should -Be $r.TokenOk
    }
}

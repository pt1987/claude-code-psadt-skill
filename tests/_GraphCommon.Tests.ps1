#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/_GraphCommon.ps1 - the shared Graph helpers (extracted from the three Graph scripts).
    These are the safety net for the de-duplication refactor: they prove Invoke-Graph still retries only
    transient failures and that the PS7-safe Retry-After / StatusCode reads work for both header shapes.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\_GraphCommon.ps1')

    # Build an ErrorRecord-like object whose .Exception.Response mimics a failed HTTP response.
    function New-FakeHttpError {
        param([int]$Status, $Headers)
        $resp = [pscustomobject]@{ StatusCode = [System.Net.HttpStatusCode]$Status; Headers = $Headers }
        $ex = [System.Exception]::new("HTTP $Status")
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue $resp -Force
        # An ErrorRecord wraps the exception; Get-Graph* read $_.Exception.*
        return [System.Management.Automation.ErrorRecord]::new($ex, 'FakeHttp', 'NotSpecified', $null)
    }

    # Build a JWT whose payload carries the given claims. Only the payload matters - nothing here
    # verifies signatures, and Graph access tokens are officially opaque anyway.
    function New-FakeJwt([hashtable]$Claims) {
        $json = $Claims | ConvertTo-Json -Compress
        $b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        return "eyJhbGciOiJSUzI1NiJ9.$b64.signature"
    }
}

Describe 'Get-GraphStatusCode' {
    It 'returns the integer status when a response is present' {
        (Get-GraphStatusCode (New-FakeHttpError -Status 429 -Headers @{})) | Should -Be 429
        (Get-GraphStatusCode (New-FakeHttpError -Status 503 -Headers @{})) | Should -Be 503
    }
    It 'returns $null when there is no response (e.g. raw HttpRequestException)' {
        $ex = [System.Exception]::new('boom')
        $err = [System.Management.Automation.ErrorRecord]::new($ex, 'NoResp', 'NotSpecified', $null)
        (Get-GraphStatusCode $err) | Should -BeNullOrEmpty
    }
}

Describe 'Get-GraphRetryAfterSeconds' {
    It 'parses the PS5.1 string header form (Headers[''Retry-After''])' {
        $err = New-FakeHttpError -Status 429 -Headers @{ 'Retry-After' = '5' }
        (Get-GraphRetryAfterSeconds $err) | Should -Be 5
    }
    It 'parses the PS7 strongly-typed RetryAfter.Delta form' {
        $headers = [pscustomobject]@{ RetryAfter = [pscustomobject]@{ Delta = [TimeSpan]::FromSeconds(7); Date = $null } }
        $err = New-FakeHttpError -Status 429 -Headers $headers
        (Get-GraphRetryAfterSeconds $err) | Should -Be 7
    }
    It 'returns 0 when no Retry-After is present' {
        (Get-GraphRetryAfterSeconds (New-FakeHttpError -Status 500 -Headers @{})) | Should -Be 0
    }
}

Describe 'Invoke-Graph retry behaviour' {
    BeforeEach { Mock Start-Sleep {} -ModuleName $null }

    It 'retries a 429 then succeeds (transient)' {
        $script:calls = 0
        Mock Invoke-RestMethod {
            $script:calls++
            if ($script:calls -lt 3) { throw (New-FakeHttpError -Status 429 -Headers @{ 'Retry-After' = '1' }) }
            return [pscustomobject]@{ ok = $true }
        }
        $r = Invoke-Graph -Method GET -Uri 'https://graph/x' -Headers @{}
        $r.ok | Should -BeTrue
        $script:calls | Should -Be 3
    }

    It 'retries 5xx as transient' {
        $script:calls = 0
        Mock Invoke-RestMethod {
            $script:calls++
            if ($script:calls -lt 2) { throw (New-FakeHttpError -Status 503 -Headers @{}) }
            return [pscustomobject]@{ ok = $true }
        }
        (Invoke-Graph -Method GET -Uri 'https://graph/x' -Headers @{}).ok | Should -BeTrue
        $script:calls | Should -Be 2
    }

    It 'does NOT retry a 4xx (e.g. 403) - throws immediately' {
        $script:calls = 0
        Mock Invoke-RestMethod { $script:calls++; throw (New-FakeHttpError -Status 403 -Headers @{}) }
        { Invoke-Graph -Method POST -Uri 'https://graph/x' -Body @{ a = 1 } -Headers @{} } | Should -Throw
        $script:calls | Should -Be 1
    }

    It 'gives up after 4 attempts on persistent 5xx' {
        $script:calls = 0
        Mock Invoke-RestMethod { $script:calls++; throw (New-FakeHttpError -Status 500 -Headers @{}) }
        { Invoke-Graph -Method GET -Uri 'https://graph/x' -Headers @{} } | Should -Throw
        $script:calls | Should -Be 4
    }
}

Describe 'Get-GraphErr' {
    It 'extracts the .error object from a JSON body in ErrorDetails (PS7 path)' {
        $ex = [System.Exception]::new('bad')
        $err = [System.Management.Automation.ErrorRecord]::new($ex, 'X', 'NotSpecified', $null)
        $err.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":{"code":"BadRequest","message":"nope"}}')
        $e = Get-GraphErr $err
        $e.code | Should -Be 'BadRequest'
        $e.message | Should -Be 'nope'
    }
    It 'falls back to a synthetic object when there is no parseable body' {
        $ex = [System.Exception]::new('raw failure')
        $err = [System.Management.Automation.ErrorRecord]::new($ex, 'X', 'NotSpecified', $null)
        (Get-GraphErr $err).code | Should -Be 'Unknown'
    }
}

# --- Token introspection (0.20.0) -----------------------------------------------------------------
Describe 'ConvertFrom-JwtPayload' {
    It 'decodes a base64url JWT payload (with padding restored)' {
        $payloadJson = @{ aud = 'aud-x'; roles = @('r1', 'r2') } | ConvertTo-Json -Compress
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payloadJson)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $jwt = "eyJhbGciOiJSUzI1NiJ9.$b64.signature"
        $p = ConvertFrom-JwtPayload $jwt
        $p.aud | Should -Be 'aud-x'
        $p.roles.Count | Should -Be 2
    }
}

Describe 'Get-GraphTokenRoles' {
    It 'returns the roles claim of an app-only token' {
        $t = New-FakeJwt @{ idtyp = 'app'; roles = @('DeviceManagementApps.ReadWrite.All', 'Group.Create') }
        $r = Get-GraphTokenRoles $t
        $r.Count | Should -Be 2
        $r | Should -Contain 'Group.Create'
    }
    It 'returns an empty list when the claim is absent' {
        (Get-GraphTokenRoles (New-FakeJwt @{ idtyp = 'app' })).Count | Should -Be 0
    }
    It 'returns an empty list for an opaque/undecodable token instead of throwing' {
        (Get-GraphTokenRoles 'not-a-jwt').Count | Should -Be 0
        (Get-GraphTokenRoles '').Count           | Should -Be 0
    }
}

Describe 'Assert-GraphRole' {
    It 'returns $true when the app-only token carries the role' {
        $t = New-FakeJwt @{ idtyp = 'app'; roles = @('DeviceManagementApps.ReadWrite.All') }
        Assert-GraphRole -Token $t -Role 'DeviceManagementApps.ReadWrite.All' | Should -BeTrue
    }
    It 'throws with the hint when an app-only token demonstrably lacks the role' {
        $t = New-FakeJwt @{ idtyp = 'app'; roles = @('DeviceManagementApps.ReadWrite.All') }
        { Assert-GraphRole -Token $t -Role 'Group.Create' -Hint 'run New-PsadtEntraApp.ps1 -IncludeGroupManagement' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*Group.Create*IncludeGroupManagement*'
    }
    It 'throws when an app-only token has no roles at all (consent never granted)' {
        { Assert-GraphRole -Token (New-FakeJwt @{ idtyp = 'app' }) -Role 'Group.Create' -ErrorAction Stop } | Should -Throw
    }
    It 'is advisory for a delegated token (scp instead of roles) and does not throw' {
        $t = New-FakeJwt @{ idtyp = 'user'; scp = 'Application.ReadWrite.All AppRoleAssignment.ReadWrite.All' }
        Assert-GraphRole -Token $t -Role 'DeviceManagementApps.ReadWrite.All' | Should -BeFalse
    }
    It 'falls through open on a decode error - Graph tokens are opaque by contract' {
        Assert-GraphRole -Token 'opaque-blob' -Role 'Group.Create' | Should -BeFalse
    }
}

Describe 'Get-GraphAuthErrorHint' {
    It 'maps the AADSTS codes that actually strand a user' {
        (Get-GraphAuthErrorHint 'AADSTS7000222: The provided client secret keys are expired.') | Should -BeLike '*EXPIRED*'
        (Get-GraphAuthErrorHint 'AADSTS7000215: Invalid client secret provided.')               | Should -BeLike '*INVALID*'
        (Get-GraphAuthErrorHint 'AADSTS700016: Application with identifier x was not found.')    | Should -BeLike '*not found in this tenant*'
        (Get-GraphAuthErrorHint 'AADSTS90002: Tenant x not found.')                              | Should -BeLike '*tenant*'
        (Get-GraphAuthErrorHint 'AADSTS53003: Access has been blocked by Conditional Access.')   | Should -BeLike '*Conditional Access*'
    }
    It 'returns $null for an unrelated message' {
        (Get-GraphAuthErrorHint 'HTTP 500 boom') | Should -BeNullOrEmpty
        (Get-GraphAuthErrorHint '')              | Should -BeNullOrEmpty
    }
}

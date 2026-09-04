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

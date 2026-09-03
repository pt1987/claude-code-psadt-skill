#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/Invoke-IntuneWin32Upload.ps1 parameter guards. These validate at PARAM BINDING (before
    any Graph call), so no network / .intunewin fixture is needed: a bad value must fail fast, a good value
    must pass binding (the body then fails on the dummy path, which proves binding let it through).
#>

BeforeAll {
    $script:Upload = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Invoke-IntuneWin32Upload.ps1')).Path
    $script:DummyWin = 'C:\__nonexistent__\nope.intunewin'
}

Describe '-MinWindowsRelease ValidateSet' {
    It 'rejects a server-unknown release label (21H2) at binding' {
        { & $script:Upload -IntuneWinPath $script:DummyWin -DisplayName 'X' -MinWindowsRelease '21H2' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*MinWindowsRelease*'
    }
    It 'accepts a backend-valid release (1809) - passes binding, then fails on the dummy path' {
        { & $script:Upload -IntuneWinPath $script:DummyWin -DisplayName 'X' -MinWindowsRelease '1809' -DetectionScriptPath $script:DummyWin -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*not found*'
    }
}

Describe '-MaxRunTimeMinutes (installExperience.maxRunTimeInMinutes)' {
    It 'rejects a value above the Intune maximum of 1440 at binding' {
        { & $script:Upload -IntuneWinPath $script:DummyWin -DisplayName 'X' -MaxRunTimeMinutes 1441 -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*MaxRunTimeMinutes*'
    }
    It 'rejects a negative value at binding' {
        { & $script:Upload -IntuneWinPath $script:DummyWin -DisplayName 'X' -MaxRunTimeMinutes -1 -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*MaxRunTimeMinutes*'
    }
    It 'accepts 240 - passes binding, then fails on the dummy path' {
        { & $script:Upload -IntuneWinPath $script:DummyWin -DisplayName 'X' -MaxRunTimeMinutes 240 -DetectionScriptPath $script:DummyWin -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*not found*'
    }

    # The request body is built at top level (not in a function), so the shape is asserted statically:
    # the field must be written ONLY behind a "> 0" guard, otherwise omitting the parameter would send
    # maxRunTimeInMinutes = 0 and the service default of 60 would be replaced by an invalid value.
    Context 'body shape' {
        BeforeAll { $script:src = Get-Content -LiteralPath $script:Upload -Raw }

        It 'writes maxRunTimeInMinutes only when the parameter is greater than zero' {
            $script:src | Should -Match 'if\s*\(\s*\$MaxRunTimeMinutes\s+-gt\s+0\s*\)\s*\{\s*\$body\.installExperience\.maxRunTimeInMinutes\s*=\s*\$MaxRunTimeMinutes\s*\}'
        }
        It 'assigns maxRunTimeInMinutes exactly once' {
            ([regex]::Matches($script:src, '\$body\.installExperience\.maxRunTimeInMinutes\s*=')).Count | Should -Be 1
        }
        It 'still sets runAsAccount and deviceRestartBehavior in installExperience' {
            $script:src | Should -Match "installExperience\s*=\s*@\{\s*runAsAccount\s*=\s*'system';\s*deviceRestartBehavior\s*=\s*\`$RestartBehavior\s*\}"
        }
        It 'defaults the parameter to 0 so existing callers are unaffected' {
            $script:src | Should -Match '\[ValidateRange\(0,1440\)\]\[int\]\$MaxRunTimeMinutes\s*=\s*0'
        }
    }
}

Describe '-MsiProductCode / -MsiUpgradeCode GUID ValidatePattern' {
    It 'rejects a non-GUID ProductCode at binding' {
        { & $script:Upload -IntuneWinPath $script:DummyWin -DisplayName 'X' -MsiProductCode 'not-a-guid' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*MsiProductCode*'
    }
    It 'accepts a brace-wrapped GUID ProductCode (passes binding)' {
        { & $script:Upload -IntuneWinPath $script:DummyWin -DisplayName 'X' -MsiProductCode '{12345678-1234-1234-1234-123456789abc}' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*not found*'
    }
    It 'accepts a bare GUID UpgradeCode (passes binding)' {
        { & $script:Upload -IntuneWinPath $script:DummyWin -DisplayName 'X' -MsiProductCode '12345678-1234-1234-1234-123456789abc' -MsiUpgradeCode '87654321-4321-4321-4321-cba987654321' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*not found*'
    }
}

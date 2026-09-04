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

Describe '-ManifestPath (0.21.0): identity comes from the package, not the command line' {
    BeforeEach {
        $script:pkgDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item $script:pkgDir -ItemType Directory -Force | Out-Null
        $script:mf = Join-Path $script:pkgDir 'psadt-package.json'
    }

    It 'still accepts the explicit form without a manifest' {
        # Reaches the .intunewin parse step, i.e. binding succeeded in the Explicit set.
        { & $script:Upload -IntuneWinPath $script:DummyWin -DisplayName 'X' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*Not found*'
    }

    It 'accepts a manifest INSTEAD of -DisplayName' {
        @{ schema = 1; app = @{ vendor = 'Mobotix'; name = 'MxManagementCenter'; version = '2.9.1'; arch = 'x64' } } |
            ConvertTo-Json -Depth 8 | Set-Content $script:mf -Encoding UTF8
        # No -DisplayName: binding must succeed and the run must get as far as the missing artifact.
        { & $script:Upload -IntuneWinPath $script:DummyWin -ManifestPath $script:mf -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*Not found*'
    }

    It 'accepts -DisplayName together with a manifest (explicit wins)' {
        @{ schema = 1; app = @{ vendor = 'Mobotix'; name = 'MxManagementCenter'; version = '2.9.1' } } |
            ConvertTo-Json -Depth 8 | Set-Content $script:mf -Encoding UTF8
        { & $script:Upload -IntuneWinPath $script:DummyWin -ManifestPath $script:mf -DisplayName 'Override' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*Not found*'
    }

    It 'throws for a manifest path that does not exist' {
        { & $script:Upload -IntuneWinPath $script:DummyWin -ManifestPath (Join-Path $TestDrive 'nope.json') -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*ManifestPath not found*'
    }

    It 'refuses a malformed manifest instead of uploading something unnamed' {
        Set-Content $script:mf '{ not json' -NoNewline
        { & $script:Upload -IntuneWinPath $script:DummyWin -ManifestPath $script:mf -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*malformed*'
    }

    It 'refuses a manifest with no app.name when no -DisplayName was passed' {
        @{ schema = 1; app = @{ vendor = 'Mobotix' } } | ConvertTo-Json -Depth 8 | Set-Content $script:mf -Encoding UTF8
        { & $script:Upload -IntuneWinPath $script:DummyWin -ManifestPath $script:mf -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*no app.name*'
    }

    Context 'source contract' {
        BeforeAll { $script:src = Get-Content -LiteralPath $script:Upload -Raw }
        It 'takes the identity only when the parameter was not bound explicitly' {
            $script:src | Should -Match "PSBoundParameters\.ContainsKey\('DisplayName'\)"
            $script:src | Should -Match "PSBoundParameters\.ContainsKey\('Publisher'\)"
            $script:src | Should -Match "PSBoundParameters\.ContainsKey\('AppVersion'\)"
        }
        It 'writes results.upload back after a successful run' {
            $script:src | Should -Match "'results\.upload'"
            $script:src | Should -Match 'Set-PsadtPackageManifest\.ps1'
        }
        It 'treats the manifest write as best effort - the app is already uploaded by then' {
            $script:src | Should -Match 'Uploaded, but could not record it in the manifest'
        }
        It 'sends the real artifact name as fileName' {
            $script:src | Should -Match '\$fileName = \[IO\.Path\]::GetFileName\(\$IntuneWinPath\)'
        }
    }
}

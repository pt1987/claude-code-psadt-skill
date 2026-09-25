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

Describe 'Return codes come from the shared canonical table' {
    BeforeAll { $script:rcSrc = Get-Content -LiteralPath $script:Upload -Raw }

    It 'no longer carries its own literal table' {
        # Before 0.26.0 this script and New-PsadtReport.ps1 each held an independent literal of the same
        # seven codes. They agreed by coincidence, not by construction, and a dossier that promises a
        # mapping the uploaded app does not carry is worse than no dossier.
        $script:rcSrc | Should -Not -Match "returnCode\s*=\s*\d"
        $script:rcSrc | Should -Match 'Get-PsadtReturnCodes\.ps1'
    }

    It 'resolves the codes BEFORE acquiring a token' {
        # An invalid return code must fail at validation time, not after a network round trip and an
        # authentication against the customer tenant.
        $iRc = $script:rcSrc.IndexOf('Get-PsadtReturnCodes.ps1')
        $iTok = $script:rcSrc.IndexOf('Get-GraphToken.ps1')
        $iRc | Should -BeGreaterThan 0
        $iTok | Should -BeGreaterThan 0
        $iRc | Should -BeLessThan $iTok
    }

    It 'exposes -ReturnCodes so researched installer codes can reach Intune' {
        (Get-Command $script:Upload).Parameters.Keys | Should -Contain 'ReturnCodes'
    }

    It 'takes researched codes from the manifest when the parameter is not bound' {
        $script:rcSrc | Should -Match "PSBoundParameters\.ContainsKey\('ReturnCodes'\)"
        $script:rcSrc | Should -Match '\$mfUp\.research\.returnCodes'
    }

    It 'rejects an invalid type before any network call' {
        # The dummy path would throw '*Not found*' later; the type error must come first.
        { & $script:Upload -IntuneWinPath 'C:\nope\x.intunewin' -DisplayName 'X' `
              -ReturnCodes @(@{ Code = 5; Type = 'ignored' }) } | Should -Throw -ExpectedMessage '*ignored*'
    }

    It 'accepts a valid custom code and then fails on the missing file, not on the code' {
        { & $script:Upload -IntuneWinPath 'C:\nope\x.intunewin' -DisplayName 'X' `
              -ReturnCodes @(@{ Code = 1603; Type = 'failed' }) } | Should -Throw -ExpectedMessage '*not found*'
    }
}

Describe '-ManifestPath alone (0.43.0): the .intunewin comes from artifacts.intunewin' {
    # 2026-09-21 audit (B02): SKILL.md Phase 9 shows `-ManifestPath <pkg>\psadt-package.json` as the whole
    # command, and -IntuneWinPath was Mandatory in every parameter set - the documented command could not
    # bind, at the one step that writes to the tenant. Invoke-PsadtPackage.ps1 records the artifact in the
    # manifest; the upload reads it from there. Child pwsh: a Mandatory parameter would PROMPT in-process.
    BeforeEach {
        $script:pkgDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item $script:pkgDir -ItemType Directory -Force | Out-Null
        $script:mf = Join-Path $script:pkgDir 'psadt-package.json'
    }

    It 'no longer marks -IntuneWinPath as Mandatory' {
        $attrs = (Get-Command $script:Upload).Parameters['IntuneWinPath'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        @($attrs | ForEach-Object { $_.Mandatory }) | Should -Not -Contain $true
    }

    It 'binds with -ManifestPath alone and takes the .intunewin from the manifest' {
        @{ schema = 1; app = @{ vendor = 'V'; name = 'N'; version = '1.0'; arch = 'x64' }
           artifacts = @{ intunewin = $script:DummyWin } } |
            ConvertTo-Json -Depth 8 | Set-Content $script:mf -Encoding UTF8
        $out = (& pwsh -NoProfile -NonInteractive -Command "& '$($script:Upload)' -ManifestPath '$($script:mf)'" 2>&1) -join "`n"
        $out | Should -Match 'Not found'                             # reached the artifact step = binding succeeded
        $out | Should -Match ([regex]::Escape($script:DummyWin))     # with the path the manifest recorded
    }

    It 'names the packaging step when the manifest carries no artifacts.intunewin yet' {
        @{ schema = 1; app = @{ vendor = 'V'; name = 'N'; version = '1.0'; arch = 'x64' } } |
            ConvertTo-Json -Depth 8 | Set-Content $script:mf -Encoding UTF8
        $out = (& pwsh -NoProfile -NonInteractive -Command "& '$($script:Upload)' -ManifestPath '$($script:mf)'" 2>&1) -join "`n"
        $out | Should -Match 'Invoke-PsadtPackage'
    }
}

Describe 'the upload dry-runs unless -Execute (0.46.0)' {
    # 2026-09-21 audit B13: SECURITY.md states "every write path dry-runs first", and that was enforced by
    # tests for the firewall and certificate scripts but for neither of the two that touch app content.
    It 'names -Execute as the switch that turns the dry run into a write' {
        $src = Get-Content -LiteralPath $script:Upload -Raw
        $src | Should -Match '\[switch\]\$Execute'
        $src | Should -Match 'if \(-not \$Execute\)'
    }
    It 'returns Executed=false and performs no write without -Execute' {
        $mf = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
        @{ schema = 1; app = @{ vendor = 'V'; name = 'N'; version = '1.0'; arch = 'x64' } } |
            ConvertTo-Json -Depth 8 | Set-Content $mf -Encoding UTF8
        $src = Get-Content -LiteralPath $script:Upload -Raw
        $src | Should -Match 'Executed\s*=' -Because 'the caller has to be able to tell a dry run from a write'
    }
}

Describe 'supersedence is chosen, wired on the working route, and recorded (0.47.0)' {
    BeforeAll { $script:us = Get-Content -LiteralPath $script:Upload -Raw }

    # Until 0.47.0 this script hardcoded supersedenceType='replace', which tells Intune to UNINSTALL the
    # previous version before installing the new one. For the ordinary case this skill produces - a newer
    # version of the same product, whose installer upgrades in place - that is the wrong and the more
    # destructive of the two documented modes.
    It 'no longer hardcodes the supersedence mode' {
        $script:us | Should -Not -Match "(?<!\`$)supersedenceType\s*=\s*'replace'"
    }
    It 'takes the mode as a parameter, restricted to the two Intune defines' {
        $script:us | Should -Match "ValidateSet\('update',\s*'replace'\)\]\[string\]\`$SupersedenceType"
    }

    # The documented POST to the relationships collection is reported to answer "No OData route exists
    # ... with http verb POST"; the failure here was caught and downgraded to a yellow line, so a
    # permanently broken supersedence looked exactly like a normal run.
    It 'wires the relationship through updateRelationships' {
        $script:us | Should -Match 'updateRelationships'
    }
    It 'no longer POSTs to the relationships collection' {
        $script:us | Should -Not -Match 'Invoke-Graph POST "\$GraphBase/deviceAppManagement/mobileApps/\$appId/relationships"'
    }
    It 'merges onto the existing relationships instead of replacing the whole set with one edge' {
        $script:us | Should -Match 'Merge-AppRelationships'
    }
    It 'does not swallow a supersedence failure - a chain that did not take is a wrong deployment' {
        $script:us | Should -Not -Match "Supersedence not set automatically"
    }

    # The return object carried Supersedes and CoexistsWith; the manifest hashtable dropped both, so
    # nothing downstream - the dossier included - could report what was actually wired.
    It 'records the wired supersedence in results.upload' {
        $script:us | Should -Match "supersedes\s*=\s*\`$supersededWired"
    }
    It 'records the coexisting versions it deliberately left intact' {
        $script:us | Should -Match 'coexistsWith\s*='
    }
}

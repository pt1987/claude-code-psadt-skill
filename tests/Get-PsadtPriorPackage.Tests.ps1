#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/Get-PsadtPriorPackage.ps1 - the lookup that makes version 2 of an app cost less
    than version 1.

    These are real functional tests against real package folders under TestDrive, not source contract:
    the whole point of the script is which manifest it picks, and a regex over the source cannot tell.
#>

BeforeAll {
    $script:Prior = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Get-PsadtPriorPackage.ps1')).Path

    function New-Pkg {
        param(
            [string]$Root, [string]$Folder, [string]$Vendor, [string]$Name, [string]$Version,
            [hashtable]$Research = @{}, [hashtable]$Decisions = @{}, [string]$PackagedAt = ''
        )
        $dir = Join-Path $Root $Folder
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        # Both scripts in this family refuse a folder that is not a PSADT package.
        Set-Content (Join-Path $dir 'Invoke-AppDeployToolkit.ps1') -Value '# stub' -Encoding UTF8
        $mf = @{
            schema  = 1
            app     = @{ vendor = $Vendor; name = $Name; version = $Version; arch = 'x64' }
            package = @{ type = 'installer' }
        }
        if ($Research.Count) { $mf.research = $Research }
        if ($Decisions.Count) { $mf.decisions = $Decisions }
        if ($PackagedAt) { $mf.results = @{ package = @{ packedAt = $PackagedAt } } }
        $mf | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $dir 'psadt-package.json') -Encoding UTF8
        return $dir
    }
}

Describe 'finding the previous package' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
    }

    It 'reports Found=false for an app nobody has packaged, instead of throwing' {
        $r = & $script:Prior -Vendor 'Acme' -Name 'Reader' -PackageRoot $script:root
        $r.Found | Should -BeFalse
    }

    It 'finds the prior package of the same app' {
        New-Pkg -Root $script:root -Folder 'AcmeReader' -Vendor 'Acme' -Name 'Reader' -Version '3.1.0' | Out-Null
        $r = & $script:Prior -Vendor 'Acme' -Name 'Reader' -PackageRoot $script:root
        $r.Found | Should -BeTrue
        $r.Version | Should -Be '3.1.0'
    }

    It 'ignores a different application entirely' {
        New-Pkg -Root $script:root -Folder 'Other' -Vendor 'Contoso' -Name 'Tool' -Version '1.0' | Out-Null
        (& $script:Prior -Vendor 'Acme' -Name 'Reader' -PackageRoot $script:root).Found | Should -BeFalse
    }

    It 'matches across differently named folders - the folder name is not an identity' {
        # Measured on the authoring machine: the same application lives in 'GoogleChrome' and
        # 'GoogleChrome_154.0.8037.58'. Keying on the folder would have missed it.
        New-Pkg -Root $script:root -Folder 'GoogleChrome' -Vendor 'Google LLC' -Name 'Google Chrome' -Version '153.0.8010.53' | Out-Null
        $r = & $script:Prior -Vendor 'Google LLC' -Name 'Google Chrome' -PackageRoot $script:root
        $r.Found | Should -BeTrue
        $r.Version | Should -Be '153.0.8010.53'
    }

    It 'picks the NEWEST prior version when several exist' {
        New-Pkg -Root $script:root -Folder 'R1' -Vendor 'Acme' -Name 'Reader' -Version '3.1.0' | Out-Null
        New-Pkg -Root $script:root -Folder 'R2' -Vendor 'Acme' -Name 'Reader' -Version '3.10.0' | Out-Null
        New-Pkg -Root $script:root -Folder 'R3' -Vendor 'Acme' -Name 'Reader' -Version '3.2.0' | Out-Null
        # 3.10.0 beats 3.2.0 - a string sort would get this backwards, which is how a package inherits
        # decisions from a version older than the one before it.
        (& $script:Prior -Vendor 'Acme' -Name 'Reader' -PackageRoot $script:root).Version | Should -Be '3.10.0'
    }

    It 'never returns the version being packaged right now' {
        New-Pkg -Root $script:root -Folder 'R1' -Vendor 'Acme' -Name 'Reader' -Version '3.1.0' | Out-Null
        New-Pkg -Root $script:root -Folder 'R2' -Vendor 'Acme' -Name 'Reader' -Version '3.2.0' | Out-Null
        $r = & $script:Prior -Vendor 'Acme' -Name 'Reader' -Version '3.2.0' -PackageRoot $script:root
        $r.Version | Should -Be '3.1.0' -Because 'a package must not inherit from itself'
    }

    It 'skips a folder that is not a PSADT package' {
        $stray = Join-Path $script:root 'NotAPackage'
        New-Item -ItemType Directory -Path $stray -Force | Out-Null
        '{ "app": { "vendor": "Acme", "name": "Reader", "version": "9.9" } }' |
            Set-Content (Join-Path $stray 'psadt-package.json') -Encoding UTF8
        (& $script:Prior -Vendor 'Acme' -Name 'Reader' -PackageRoot $script:root).Found | Should -BeFalse
    }

    It 'survives a malformed manifest instead of failing the whole lookup' {
        $bad = Join-Path $script:root 'Broken'
        New-Item -ItemType Directory -Path $bad -Force | Out-Null
        Set-Content (Join-Path $bad 'Invoke-AppDeployToolkit.ps1') -Value '# stub' -Encoding UTF8
        Set-Content (Join-Path $bad 'psadt-package.json') -Value '{ not json' -Encoding UTF8
        New-Pkg -Root $script:root -Folder 'Good' -Vendor 'Acme' -Name 'Reader' -Version '3.1.0' | Out-Null
        (& $script:Prior -Vendor 'Acme' -Name 'Reader' -PackageRoot $script:root).Version | Should -Be '3.1.0'
    }
}

Describe 'what it carries forward' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        New-Pkg -Root $script:root -Folder 'Aomei' -Vendor 'AOMEI' -Name 'Partition Assistant' -Version '10.12.1' `
            -Research @{
                appMutex          = 'AOMEI_TECHNOLOGY_PARTITION_ASSISTANT'
                knownIssues       = 'UninstallFB.exe blocks the silent uninstall'
                leftovers         = 'ProgramData\AOMEIPA remains'
                uninstallSwitches = 'rename UninstallFB.exe, then unins000.exe /VERYSILENT'
            } `
            -Decisions @{
                gate1 = @{ licenseHandling = 'seed KEY= into cfg.ini post-install' }
                gate2 = @{ repairStrategy = 'reinstall over the top'; uninstallScope = 'vendor uninstaller + ProgramData' }
            } | Out-Null
    }

    It 'carries the research findings that cost the most to establish' {
        $c = (& $script:Prior -Vendor 'AOMEI' -Name 'Partition Assistant' -PackageRoot $script:root).Carry
        $c.research.appMutex | Should -Be 'AOMEI_TECHNOLOGY_PARTITION_ASSISTANT'
        $c.research.knownIssues | Should -Match 'UninstallFB'
        $c.research.uninstallSwitches | Should -Match 'VERYSILENT'
    }

    It 'carries both decision gates' {
        $c = (& $script:Prior -Vendor 'AOMEI' -Name 'Partition Assistant' -PackageRoot $script:root).Carry
        $c.decisions.gate1.licenseHandling | Should -Match 'cfg.ini'
        $c.decisions.gate2.repairStrategy | Should -Match 'reinstall'
    }

    It 'stamps every carried value with the version it came from' {
        # A carried value that looks like a fresh finding is worse than no carried value: the operator
        # cannot tell what still needs checking against the new build.
        $r = & $script:Prior -Vendor 'AOMEI' -Name 'Partition Assistant' -PackageRoot $script:root
        $r.CarriedFrom | Should -Be '10.12.1'
    }

    It 'carries the process list - the value that was retyped from memory every time' {
        # Found by running it, not by reading it: package.processesToClose was recorded correctly by the
        # generator and then left out of the Carry object, so the lookup knew it and never offered it.
        # That is the one value this whole feature was supposed to stop people retyping.
        $dir = Join-Path $script:root 'WithProcs'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content (Join-Path $dir 'Invoke-AppDeployToolkit.ps1') -Value '# stub' -Encoding UTF8
        @{
            schema  = 1
            app     = @{ vendor = 'Igor Pavlov'; name = '7-Zip'; version = '26.03'; arch = 'x64' }
            package = @{ type = 'installer'; processesToClose = @('7zFM', '7zG'); installerSha256 = 'c0680064' }
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $dir 'psadt-package.json') -Encoding UTF8

        $c = (& $script:Prior -Vendor 'Igor Pavlov' -Name '7-Zip' -Version '26.04' -PackageRoot $script:root).Carry
        @($c.processesToClose) | Should -Contain '7zFM'
        @($c.processesToClose) | Should -Contain '7zG'
    }

    It 'carries the previous installer hash, so the caller can tell a re-pack from a new build' {
        $dir = Join-Path $script:root 'WithSha'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content (Join-Path $dir 'Invoke-AppDeployToolkit.ps1') -Value '# stub' -Encoding UTF8
        @{
            schema  = 1
            app     = @{ vendor = 'Acme'; name = 'Thing'; version = '1.0'; arch = 'x64' }
            package = @{ type = 'installer'; installerSha256 = 'abc123' }
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $dir 'psadt-package.json') -Encoding UTF8
        (& $script:Prior -Vendor 'Acme' -Name 'Thing' -Version '2.0' -PackageRoot $script:root).Carry.installerSha256 |
            Should -Be 'abc123'
    }

    It 'carries nothing at all when there is no prior package' {
        $r = & $script:Prior -Vendor 'Nobody' -Name 'Nothing' -PackageRoot $script:root
        $r.Carry | Should -BeNullOrEmpty
    }
}

Describe 'it is read-only' {
    BeforeAll { $script:Src = Get-Content -LiteralPath $script:Prior -Raw }

    It 'has no -Execute switch - there is nothing to gate' {
        $script:Src | Should -Not -Match '\[switch\]\$Execute'
    }
    It 'never writes a manifest' {
        $script:Src | Should -Not -Match 'Set-PsadtPackageManifest'
    }
    It 'never deletes anything' {
        $script:Src | Should -Not -Match 'Remove-Item'
    }
}

Describe 'the package index (0.49.0)' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:home2 = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root, $script:home2 -Force | Out-Null
    }

    It 'finds a package through the index even when it sits outside the package root' {
        # The point of the index: a package folder that was archived, moved, or handed over by a
        # colleague is still findable. A scan of paths.packageRoot alone would miss it.
        $elsewhere = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
        $dir = New-Pkg -Root $elsewhere -Folder 'Archived' -Vendor 'Acme' -Name 'Reader' -Version '3.1.0'
        @{ schemaVersion = 1; entries = @(@{
                    appKey = 'acme reader'; version = '3.1.0'
                    manifestPath = (Join-Path $dir 'psadt-package.json')
                }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:home2 'package-index.json') -Encoding UTF8

        $r = & $script:Prior -Vendor 'Acme' -Name 'Reader' -PackageRoot $script:root -SkillRoot $script:home2
        $r.Found | Should -BeTrue
        $r.Version | Should -Be '3.1.0'
    }

    It 'falls back to the scan when the index is corrupt, instead of failing the lookup' {
        Set-Content (Join-Path $script:home2 'package-index.json') -Value '{ not json' -Encoding UTF8
        New-Pkg -Root $script:root -Folder 'R1' -Vendor 'Acme' -Name 'Reader' -Version '3.1.0' | Out-Null
        (& $script:Prior -Vendor 'Acme' -Name 'Reader' -PackageRoot $script:root -SkillRoot $script:home2).Version |
            Should -Be '3.1.0'
    }

    It 'does not return the same package twice when it is both indexed and scannable' {
        $dir = New-Pkg -Root $script:root -Folder 'R1' -Vendor 'Acme' -Name 'Reader' -Version '3.1.0'
        @{ schemaVersion = 1; entries = @(@{ appKey = 'acme reader'; version = '3.1.0'
                    manifestPath = (Join-Path $dir 'psadt-package.json') }) } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:home2 'package-index.json') -Encoding UTF8
        $r = & $script:Prior -Vendor 'Acme' -Name 'Reader' -PackageRoot $script:root -SkillRoot $script:home2
        $r.Found | Should -BeTrue
        $r.Version | Should -Be '3.1.0'
    }
}

Describe 'Invoke-PsadtPackage appends to the index (0.49.0)' {
    BeforeAll { $script:pkgSrc = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Invoke-PsadtPackage.ps1') -Raw }

    It 'writes the index through the atomic JSON store, not with a bare Set-Content' {
        # Two packaging runs can finish close together; the index is shared state like the manifest and
        # the switch store, and _JsonStore.ps1 is what makes a torn write impossible.
        $script:pkgSrc | Should -Match 'package-index\.json'
        $script:pkgSrc | Should -Match 'Write-JsonAtomic'
    }
    It 'keys the entry by the app key, not by the folder name' {
        $script:pkgSrc | Should -Match 'ConvertTo-PsadtAppKey|Get-PsadtAppKeyFromManifest'
    }
    It 'never fails the packaging run because the index could not be written' {
        # The .intunewin exists by this point. An index is a convenience; losing it must not turn a
        # finished package into an error.
        $script:pkgSrc | Should -Match '(?s)package-index.{0,800}?catch'
    }
}

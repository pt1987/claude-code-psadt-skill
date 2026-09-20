# Tests for the write side of the verified-switch store.
#
# The store's whole value is that an entry carries the word 'verified' and outranks every other stage in
# Get-PsadtSwitchCandidates.ps1. So most of what follows tests REFUSALS: the cases where this script must
# write nothing. A writer that is easy to talk into recording an unproven switch is worse than no writer,
# because the next package adopts its answer without asking.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:src = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Set-PsadtVerifiedSwitch.ps1')).Path
    $script:made = @()

    # Source guards match against the CODE with comments blanked out. Matching raw source would flag the
    # comment in which the script explains the very trap it avoids. Same idiom as the reader's tests.
    $raw = Get-Content -LiteralPath $script:src -Raw
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$tokens, [ref]$null) | Out-Null
    $builder = [System.Text.StringBuilder]::new($raw)
    foreach ($t in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $len = $t.Extent.EndOffset - $t.Extent.StartOffset
        [void]$builder.Remove($t.Extent.StartOffset, $len)
        [void]$builder.Insert($t.Extent.StartOffset, (' ' * $len))
    }
    $script:code = $builder.ToString()

    $script:AllFive = @('Install', 'Uninstall', 'Reinstall', 'Repair', 'FinalUninstall')

    # A package folder the writer will accept: an EXE installer, a manifest that names it, and
    # machine-readable switches.
    function New-FixturePackage {
        param(
            [string]$InstallerTech = 'exe',
            [string]$PackageType = 'installer',
            [string]$AppName = 'Contoso Widget',
            [switch]$NoInstallerFile,
            [switch]$NoInstallArgs,
            [int]$ExtraFiles = 0,
            [byte[]]$Overlay = @(),
            [string]$AppVersion = '1.2.3',
            [string]$InstallArgsOverride
        )
        $pkg = Join-Path ([System.IO.Path]::GetTempPath()) ('vsw_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $pkg 'Files') -Force | Out-Null
        # Get-PsadtPackageManifest refuses a folder without a launcher, so the fixture needs one.
        Set-Content -LiteralPath (Join-Path $pkg 'Invoke-AppDeployToolkit.ps1') -Value '# fixture' -Encoding UTF8

        $pe = New-TestPe -Overlay $Overlay
        $installerName = 'setup.exe'
        Move-Item -LiteralPath $pe -Destination (Join-Path $pkg "Files\$installerName") -Force

        for ($i = 1; $i -le $ExtraFiles; $i++) {
            Set-Content -LiteralPath (Join-Path $pkg "Files\extra$i.dat") -Value 'x' -Encoding ascii
        }

        $switches = @{ install = "$installerName /S"; repair = 'Re-run' }
        if (-not $NoInstallArgs) {
            $switches['installArgs'] = if ($InstallArgsOverride) { $InstallArgsOverride } else { '/S /NORESTART' }
            $switches['uninstallArgs'] = '/S'
        }

        $m = [ordered]@{
            schema   = 1
            app      = [ordered]@{ vendor = 'Contoso'; name = $AppName; version = $AppVersion; arch = 'x64' }
            package  = [ordered]@{ name = 'Contoso_Widget'; type = $PackageType; installerTech = $InstallerTech }
            research = [ordered]@{ switches = $switches; returnCodes = @() }
        }
        if (-not $NoInstallerFile) { $m.package['installerFile'] = $installerName }

        $m | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $pkg 'psadt-package.json') -Encoding UTF8
        $script:made += $pkg
        return $pkg
    }
}

AfterAll {
    foreach ($p in $script:made) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Set-PsadtVerifiedSwitch' {

    BeforeEach {
        $script:oldHome = $env:PSADT_DEPLOY_HOME
        $script:tempHome = Join-Path ([System.IO.Path]::GetTempPath()) ('vswhome_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tempHome -Force | Out-Null
        $env:PSADT_DEPLOY_HOME = $script:tempHome
        $script:store = Join-Path $script:tempHome 'verified-switches.json'
    }

    AfterEach {
        $env:PSADT_DEPLOY_HOME = $script:oldHome
        if ($script:tempHome -and (Test-Path $script:tempHome)) {
            Remove-Item $script:tempHome -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'house conventions' {
        It 'parses' {
            $err = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($script:src, [ref]$null, [ref]$err)
            @($err).Count | Should -Be 0
        }

        It 'is 7-bit ASCII' {
            $bytes = [System.IO.File]::ReadAllBytes($script:src)
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }

        It 'resolves the store through the config home, never through LOCALAPPDATA directly' {
            # rule:config-home. Reading $env:LOCALAPPDATA here would ignore PSADT_DEPLOY_HOME and write
            # into the user's real profile during a test run.
            $script:code | Should -Not -Match '\$env:LOCALAPPDATA'
            $script:code | Should -Match 'Get-PsadtConfig\.ps1'
        }

        It 'never calls exit' {
            $script:code | Should -Not -Match '(?m)^\s*exit\b'
        }
    }

    Context 'the gate' {
        It 'refuses every verdict that is not GREEN' -ForEach @(
            @{ Verdict = 'GREEN_PARTIAL' }
            @{ Verdict = 'RED' }
            @{ Verdict = 'STOPPED' }
            @{ Verdict = 'ERROR' }
            @{ Verdict = 'UNKNOWN' }
        ) {
            $pkg = New-FixturePackage
            $r = & $script:src -PackagePath $pkg -Verdict $Verdict -Scenarios $script:AllFive
            $r.Written | Should -BeFalse
            $r.Action | Should -Be 'skipped'
            $r.Reason | Should -Match 'not GREEN'
            Test-Path $script:store | Should -BeFalse
        }

        It 'refuses a GREEN that did not run all five scenarios' {
            # -Quick reports GREEN_PARTIAL, but a caller could pass GREEN with a short list by mistake.
            # The second half of the gate is what stops that.
            $pkg = New-FixturePackage
            $r = & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios @('Install', 'Uninstall')
            $r.Written | Should -BeFalse
            $r.Reason | Should -Match 'Reinstall'
            $r.Reason | Should -Match 'not a full gate'
            Test-Path $script:store | Should -BeFalse
        }

        It 'writes on a GREEN full gate' {
            $pkg = New-FixturePackage
            $r = & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive
            $r.Written | Should -BeTrue
            $r.Action | Should -Be 'added'
            $r.EntryCount | Should -Be 1
            Test-Path $script:store | Should -BeTrue
        }

        It 'offers no -Force bypass' {
            (Get-Command $script:src).Parameters.Keys | Should -Not -Contain 'Force'
        }
    }

    Context 'what it declines to record' {
        It 'refuses install arguments that look like they carry a secret' -ForEach @(
            @{ Args = '/qn /norestart LICENSEKEY=ABC-123' }
            @{ Args = '/qn /norestart SERIAL=99999' }
            @{ Args = '/qn /norestart APITOKEN=zzz' }
            @{ Args = '/qn /norestart PASSWORD=hunter2' }
        ) {
            # The store is a plain file in the profile, and replaying one tenant's key as a verified
            # switch for the next package would be worse than having no entry.
            $pkg = New-FixturePackage -InstallArgsOverride $Args
            $r = & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive
            $r.Written | Should -BeFalse
            $r.Reason | Should -Match 'secret'
        }

        It 'records an MSI package, because its properties are researched and its switch is not' {
            # The first version of the writer skipped MSI outright. That confused the deterministic
            # silent switch with the researched ADDLOCAL properties, which are the expensive half.
            $pkg = New-FixturePackage -InstallerTech 'msi' -InstallArgsOverride '/qn /norestart ADDLOCAL=MainApplication'
            $r = & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive
            $r.Written | Should -BeTrue
            $entry = (Get-Content $script:store -Raw | ConvertFrom-Json).entries[0]
            $entry.installerTech | Should -Be 'msi'
            $entry.install | Should -Match 'ADDLOCAL=MainApplication'
        }

        It 'skips a package type that has no single installer binary' -ForEach @(
            @{ Type = 'browser-extension' }
            @{ Type = 'windows-feature' }
            @{ Type = 'script' }
            @{ Type = 'driver' }
        ) {
            $pkg = New-FixturePackage -PackageType $Type
            $r = & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive
            $r.Written | Should -BeFalse
            $r.Reason | Should -Match ([regex]::Escape($Type))
        }

        It 'skips when the manifest carries no machine-readable install arguments' {
            # The prose research.switches.install field is deliberately not parsed.
            $pkg = New-FixturePackage -NoInstallArgs
            $r = & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive
            $r.Written | Should -BeFalse
            $r.Reason | Should -Match 'installArgs'
        }

        It 'skips rather than guess when Files\ is ambiguous and the manifest names nothing' {
            $pkg = New-FixturePackage -NoInstallerFile -ExtraFiles 2
            $r = & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive
            $r.Written | Should -BeFalse
            $r.Reason | Should -Match 'cannot tell which file'
            $r.Reason | Should -Match 'extra1\.dat'
        }

        It 'falls back to the single file in Files\ when the manifest names none' {
            $pkg = New-FixturePackage -NoInstallerFile
            $r = & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive
            $r.Written | Should -BeTrue
        }
    }

    Context 'the entry it writes' {
        It 'hashes the file the manifest names, even when Files\ holds others' {
            $pkg = New-FixturePackage -ExtraFiles 3
            $r = & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive
            $expected = (Get-FileHash (Join-Path $pkg 'Files\setup.exe') -Algorithm SHA256).Hash.ToLower()
            $r.Sha256 | Should -Be $expected
        }

        It 'stores the ProductName the binary reports, never the manifest app.name' {
            # The reader compares productName against the probed file's PE metadata. A friendly name from
            # the manifest would leave the same-product fallback permanently dead.
            $pkg = New-FixturePackage -AppName 'Contoso Widget'
            & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive | Out-Null
            $entry = (Get-Content $script:store -Raw | ConvertFrom-Json).entries[0]
            $entry.productName | Should -Not -Be 'Contoso Widget'
        }

        It 'carries every field the reader reads' {
            $pkg = New-FixturePackage
            & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive -EvidenceRef 'C:\evidence\result.json' | Out-Null
            $entry = (Get-Content $script:store -Raw | ConvertFrom-Json).entries[0]
            foreach ($f in 'sha256', 'productName', 'productVersion', 'appVersion', 'installerTech', 'productCode',
                'install', 'uninstall', 'installLog',
                'noReboot', 'detectHint', 'returnCodes', 'notes', 'scenarios', 'verifiedAt', 'verifiedBy') {
                $entry.PSObject.Properties.Name | Should -Contain $f
            }
            $entry.install | Should -Be '/S /NORESTART'
            $entry.uninstall | Should -Be '/S'
            $entry.scenarios | Should -HaveCount 5
            $entry.verifiedAt | Should -Match '^\d{4}-\d{2}-\d{2}$'
            ($entry.notes -join ' ') | Should -Match 'result\.json'
        }

        It 'records the detection hint from the ARP row the run observed' {
            $pkg = New-FixturePackage
            $arp = [pscustomobject]@{ DisplayName = 'Contoso Widget 1.2.3'; DisplayVersion = '1.2.3' }
            & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive -InstalledApp $arp | Out-Null
            $entry = (Get-Content $script:store -Raw | ConvertFrom-Json).entries[0]
            $entry.detectHint.note | Should -Match 'Contoso Widget 1\.2\.3'
        }

        It 'validates against schema.verified-switches.json' {
            $pkg = New-FixturePackage
            & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive | Out-Null
            $schema = (Resolve-Path (Join-Path $PSScriptRoot '..\references\switch-catalog\schema.verified-switches.json')).Path
            { Get-Content $script:store -Raw | Test-Json -SchemaFile $schema -ErrorAction Stop } | Should -Not -Throw
        }
    }

    Context 'upsert and invalidation' {
        It 'replaces rather than appends when the same hash is proven again' {
            # The reader takes [0] of the match, so a duplicate would make the winner depend on
            # insertion order.
            $pkg = New-FixturePackage
            & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive | Out-Null
            $second = & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive
            $second.Action | Should -Be 'updated'
            $second.EntryCount | Should -Be 1
            (Get-Content $script:store -Raw | ConvertFrom-Json).entries | Should -HaveCount 1
        }

        It 'appends a genuinely different installer' {
            $a = New-FixturePackage -Overlay ([byte[]](1, 2, 3))
            $b = New-FixturePackage -Overlay ([byte[]](9, 9, 9, 9))
            & $script:src -PackagePath $a -Verdict 'GREEN' -Scenarios $script:AllFive | Out-Null
            $r = & $script:src -PackagePath $b -Verdict 'GREEN' -Scenarios $script:AllFive
            $r.Action | Should -Be 'added'
            $r.EntryCount | Should -Be 2
        }

        It 'removes exactly the named entry and leaves its sibling' {
            $a = New-FixturePackage -Overlay ([byte[]](1, 2, 3))
            $b = New-FixturePackage -Overlay ([byte[]](9, 9, 9, 9))
            $ra = & $script:src -PackagePath $a -Verdict 'GREEN' -Scenarios $script:AllFive
            $rb = & $script:src -PackagePath $b -Verdict 'GREEN' -Scenarios $script:AllFive
            $r = & $script:src -Remove $ra.Sha256
            $r.Action | Should -Be 'removed'
            $r.EntryCount | Should -Be 1
            (Get-Content $script:store -Raw | ConvertFrom-Json).entries[0].sha256 | Should -Be $rb.Sha256
        }

        It 'is idempotent when asked to remove a hash that is not there' {
            $r = & $script:src -Remove ('0' * 64)
            $r.Written | Should -BeFalse
            $r.Action | Should -Be 'removed'
        }
    }

    Context 'version history' {
        It 'keeps one entry per version, because each build has its own hash' {
            $v1 = New-FixturePackage -AppVersion '1.0.0' -Overlay ([byte[]](1, 1, 1))
            $v2 = New-FixturePackage -AppVersion '2.0.0' -Overlay ([byte[]](2, 2, 2))
            & $script:src -PackagePath $v1 -Verdict 'GREEN' -Scenarios $script:AllFive | Out-Null
            & $script:src -PackagePath $v2 -Verdict 'GREEN' -Scenarios $script:AllFive | Out-Null
            $entries = (Get-Content $script:store -Raw | ConvertFrom-Json).entries
            $entries | Should -HaveCount 2
            @($entries | ForEach-Object { $_.appVersion }) | Should -Contain '1.0.0'
            @($entries | ForEach-Object { $_.appVersion }) | Should -Contain '2.0.0'
        }

        It 'puts the most recently proven version first, so the reader does not serve the oldest' {
            # Get-PsadtSwitchCandidates takes [0] of the same-product matches. Appending would hand a
            # future package the switches of the FIRST version ever recorded.
            $v1 = New-FixturePackage -AppVersion '1.0.0' -Overlay ([byte[]](1, 1, 1))
            $v2 = New-FixturePackage -AppVersion '2.0.0' -Overlay ([byte[]](2, 2, 2))
            & $script:src -PackagePath $v1 -Verdict 'GREEN' -Scenarios $script:AllFive | Out-Null
            & $script:src -PackagePath $v2 -Verdict 'GREEN' -Scenarios $script:AllFive | Out-Null
            $entries = (Get-Content $script:store -Raw | ConvertFrom-Json).entries
            $entries[0].appVersion | Should -Be '2.0.0'
        }

        It 'moves a re-proven entry back to the front' {
            $v1 = New-FixturePackage -AppVersion '1.0.0' -Overlay ([byte[]](1, 1, 1))
            $v2 = New-FixturePackage -AppVersion '2.0.0' -Overlay ([byte[]](2, 2, 2))
            & $script:src -PackagePath $v1 -Verdict 'GREEN' -Scenarios $script:AllFive | Out-Null
            & $script:src -PackagePath $v2 -Verdict 'GREEN' -Scenarios $script:AllFive | Out-Null
            $again = & $script:src -PackagePath $v1 -Verdict 'GREEN' -Scenarios $script:AllFive
            $again.Action | Should -Be 'updated'
            $again.EntryCount | Should -Be 2
            (Get-Content $script:store -Raw | ConvertFrom-Json).entries[0].appVersion | Should -Be '1.0.0'
        }

        It 'records the declared version alongside the one the binary reports' {
            $pkg = New-FixturePackage -AppVersion '4.5.6'
            & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive | Out-Null
            $entry = (Get-Content $script:store -Raw | ConvertFrom-Json).entries[0]
            $entry.appVersion | Should -Be '4.5.6'
            $entry.PSObject.Properties.Name | Should -Contain 'productVersion'
        }
    }

    Context 'a malformed store' {
        It 'throws instead of silently overwriting it' {
            # It is the only record of what was proven on this machine. Replacing it to fix a parse error
            # would destroy that record.
            Set-Content -LiteralPath $script:store -Value '{ not json' -Encoding UTF8
            $pkg = New-FixturePackage
            { & $script:src -PackagePath $pkg -Verdict 'GREEN' -Scenarios $script:AllFive } |
                Should -Throw -ExpectedMessage '*not readable JSON*'
            (Get-Content $script:store -Raw) | Should -Match 'not json'
        }
    }
}

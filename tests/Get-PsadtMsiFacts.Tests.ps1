# SCOPE NOTE: the guard tests run anywhere. The functional tests need a real MSI and are skipped when none
# is present - CI machines have no vendor installer to hand, and shipping one in the repo is not an option.
#
# The source-inspecting tests are REGRESSION GUARDS, not style checks. Each corresponds to a way this exact
# probe failed on 2026-09-05 while being written by hand four times in a row; all four fail far from their
# cause (a COM type mismatch, a "cannot index into a null array" inside the caller's loop, a table that
# only breaks when it has exactly one row, and a file the scanner still holds).
#
# The guards match against the script's CODE with comments stripped. Matching raw source would flag the
# comment block in which those very traps are documented - the guard would fail on a correct file purely
# because the file explains what it is avoiding.

# Discovery-time: -Skip is evaluated before BeforeAll runs, so the sample lookup has to happen out here.
$script:sampleMsi = @(
    Get-ChildItem -Path 'C:\PSADT\Packages' -Filter '*.msi' -Recurse -ErrorAction SilentlyContinue
    Get-ChildItem -Path "$env:LOCALAPPDATA\psadt-deploy" -Filter '*.msi' -Recurse -ErrorAction SilentlyContinue
) | Select-Object -First 1 -ExpandProperty FullName

BeforeAll {
    . "$PSScriptRoot/_helpers.ps1"
    $script:src = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Get-PsadtMsiFacts.ps1')).ProviderPath

    # Code with every comment blanked out, so a guard cannot be satisfied - or defeated - by prose.
    # Comment extents are overwritten with spaces rather than the tokens being re-joined: re-joining
    # inserts whitespace between every token ("$installer . OpenDatabase ("), which no realistic pattern
    # matches, and a guard that cannot match anything is not a guard.
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
}

Describe 'Get-PsadtMsiFacts' {
    Context 'guards' {
        It 'throws when the file does not exist' {
            { & $script:src -Path 'C:\nope\missing.msi' } | Should -Throw -ExpectedMessage '*MSI not found*'
        }

        It 'refuses a file that is not an MSI or MSP' {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('facts_' + [guid]::NewGuid().ToString('N') + '.exe')
            Set-Content -LiteralPath $tmp -Value 'not an msi'
            try { { & $script:src -Path $tmp } | Should -Throw -ExpectedMessage '*Not an MSI/MSP file*' }
            finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'regression guards on the code' {
        It 'opens the database with a direct method call, not InvokeMember' {
            # $installer.GetType().InvokeMember('OpenDatabase', ...) throws DISP_E_TYPEMISMATCH (0x80020005)
            # against the Windows Installer automation object on some hosts, while the direct call works.
            $script:code | Should -Match '\$installer\.OpenDatabase\('
            $script:code | Should -Not -Match "InvokeMember"
        }

        It 'swallows the null returned by Execute and Close' {
            # An unswallowed $null lands in the function's output; the caller then indexes into it and gets
            # "cannot index into a null array", pointing at the loop instead of at the query.
            $script:code | Should -Match '\$view\.Execute\(\) \| Out-Null'
            $script:code | Should -Match '\$view\.Close\(\) \| Out-Null'
        }

        It 'returns rows as objects with named columns, never as nested arrays' {
            # Nested arrays force "return ,$rows" / "$_[0]" gymnastics that break when a table has exactly
            # one row, because PowerShell unrolls the outer array.
            $script:code | Should -Match '\[pscustomobject\]\$ordered'
            $script:code | Should -Not -Match 'return ,\$'
        }

        It 'retries opening the database, because a fresh download can still be scanner-locked' {
            $script:code | Should -Match '1\.\.5'
        }

        It 'treats every table except Property as optional' {
            $script:code | Should -Match '\$tables -notcontains \$Table'
        }

        It 'decodes the upgrade attribute that changes how a package must be built' {
            # MigrateFeatures is why ADDLOCAL alone is not always enough on an upgrade.
            $script:code | Should -Match 'MigrateFeatures'
            $script:code | Should -Match '\$attr -band 1\b'
        }

        It 'is ASCII-clean' {
            $bytes = [System.IO.File]::ReadAllBytes($script:src)
            $body = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF) { $bytes[3..($bytes.Length - 1)] } else { $bytes }
            @($body | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }

        It 'parses without errors' {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($script:src, [ref]$null, [ref]$errors) | Out-Null
            @($errors).Count | Should -Be 0
        }
    }

    Context 'against a real MSI' -Skip:(-not $script:sampleMsi) {
        BeforeAll {
            $script:msiPath = @(
                Get-ChildItem -Path 'C:\PSADT\Packages' -Filter '*.msi' -Recurse -ErrorAction SilentlyContinue
                Get-ChildItem -Path "$env:LOCALAPPDATA\psadt-deploy" -Filter '*.msi' -Recurse -ErrorAction SilentlyContinue
            ) | Select-Object -First 1 -ExpandProperty FullName
            $script:facts = & $script:src -Path $script:msiPath
        }

        It 'returns a ProductCode that looks like a GUID' {
            $script:facts.ProductCode | Should -Match '^\{[0-9A-Fa-f-]{36}\}$'
        }

        It 'returns identity, hash and signature status' {
            $script:facts.ProductVersion | Should -Not -BeNullOrEmpty
            $script:facts.Sha256 | Should -Match '^[0-9a-f]{64}$'
            $script:facts.SignatureStatus | Should -Not -BeNullOrEmpty
        }

        It 'returns feature rows with named columns' {
            @($script:facts.Features).Count | Should -BeGreaterThan 0
            @($script:facts.Features)[0].PSObject.Properties.Name | Should -Contain 'Feature'
            @($script:facts.Features)[0].PSObject.Properties.Name | Should -Contain 'Level'
        }

        It 'survives a table the MSI does not have' {
            # Property always exists; Upgrade, Shortcut, Icon and Registry frequently do not. Whatever is
            # missing must come back empty rather than throw.
            $script:facts.Properties.Count | Should -BeGreaterThan 0
            { @($script:facts.Upgrades).Count } | Should -Not -Throw
            { @($script:facts.Icons).Count } | Should -Not -Throw
        }

        It 'renders the text form without throwing' {
            { & $script:src -Path $script:msiPath -AsText | Out-Null } | Should -Not -Throw
        }
    }
}

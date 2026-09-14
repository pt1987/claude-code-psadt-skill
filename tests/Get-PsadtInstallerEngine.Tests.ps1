# SCOPE NOTE: these tests run anywhere. They synthesise minimal PE files at runtime instead of shipping
# real installer headers, because tests/ carries no binary fixtures (the same reason
# Get-PsadtMsiFacts.Tests skips instead of shipping an MSI) - and because a 4 KB header slice would not
# prove anything anyway: apart from MSI (CFB magic at offset 0) and WiX Burn (a section NAME), every
# engine marker this probe looks for lives in the PE OVERLAY or the resources, far past the first pages.
#
# The Aperio guard is the load-bearing one. On a real package an install4j installer was identified as
# NSIS from a coincidental substring, /S was used, and the install hung on the language dialog forever
# (App. L.1 blockquote, App. B anti-pattern 13). A definitive marker must beat a hint every time.

BeforeAll {
    . "$PSScriptRoot/_helpers.ps1"
    $script:src = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Get-PsadtInstallerEngine.ps1')).ProviderPath

    # New-TestPe, New-TestCfb, Join-Bytes, New-Pad, New-Ascii and New-Blob come from _helpers.ps1,
    # so the engine tests and the candidate tests build their fixtures from one definition.
    $script:made = New-Object System.Collections.Generic.List[string]
    function Track([string]$p) { $script:made.Add($p); return $p }
}

AfterAll {
    foreach ($p in $script:made) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-PsadtInstallerEngine' {

    Context 'guards' {
        It 'throws when the file does not exist' {
            { & $script:src -Path 'C:\nope\missing.exe' } | Should -Throw -ExpectedMessage '*not found*'
        }
    }

    Context 'definitive markers' {
        It 'identifies an MSI by the compound-file header, not by extension' {
            $p = Track (Join-Path ([System.IO.Path]::GetTempPath()) ('engine_' + [guid]::NewGuid().ToString('N') + '.bin'))
            $cfb = Join-Bytes (0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1) (New-Pad 256)
            [System.IO.File]::WriteAllBytes($p, $cfb)
            $r = & $script:src -Path $p
            $r.Engine | Should -Be 'msi'
            $r.Confidence | Should -Be 'high'
            $r.IsMsi | Should -BeTrue
        }

        It 'identifies a WiX Burn bundle by the .wixburn section name' {
            $p = Track (New-TestPe -SectionNames @('.text', '.wixburn'))
            $r = & $script:src -Path $p
            $r.Engine | Should -Be 'wix-burn'
            $r.Confidence | Should -Be 'high'
            @($r.Evidence | Where-Object { $_.Region -eq 'section-table' }).Count | Should -BeGreaterThan 0
        }

        It 'identifies NSIS by the first-header magic in the overlay' {
            $p = Track (New-TestPe -Overlay (New-Blob 'NullsoftInst'))
            $r = & $script:src -Path $p
            $r.Engine | Should -Be 'nsis'
            $r.Confidence | Should -Be 'high'
            @($r.Evidence | Where-Object { $_.Region -eq 'overlay' }).Count | Should -BeGreaterThan 0
        }

        It 'identifies Inno Setup by its setup-data marker' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data (6.2.0)'))
            $r = & $script:src -Path $p
            $r.Engine | Should -Be 'inno'
            $r.Confidence | Should -Be 'high'
        }

        It 'separates InstallShield Basic MSI from InstallScript by the embedded database' {
            $cfb = 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1
            $withMsi = Track (New-TestPe -Overlay (Join-Bytes (New-Ascii 'ISSetupStream') (New-Pad 32) $cfb))
            (& $script:src -Path $withMsi).Engine | Should -Be 'installshield-basic-msi'

            $noMsi = Track (New-TestPe -Overlay (New-Blob 'ISSetupStream'))
            (& $script:src -Path $noMsi).Engine | Should -Be 'installshield-installscript'
        }

        It 'identifies install4j by i4jparams.conf' {
            $p = Track (New-TestPe -Overlay (New-Blob 'i4jparams.conf'))
            $r = & $script:src -Path $p
            $r.Engine | Should -Be 'install4j'
            $r.Confidence | Should -Be 'high'
        }

        It 'identifies a 7-Zip self-extractor by the archive magic' {
            $p = Track (New-TestPe -Overlay (Join-Bytes (New-Pad 8) (0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C)))
            (& $script:src -Path $p).Engine | Should -Be 'sfx-7zip'
        }

        It 'identifies MSIX by the zip container plus AppxManifest.xml' {
            $p = Track (Join-Path ([System.IO.Path]::GetTempPath()) ('engine_' + [guid]::NewGuid().ToString('N') + '.msix'))
            $bytes = Join-Bytes (0x50, 0x4B, 0x03, 0x04) (New-Pad 64) (New-Ascii 'AppxManifest.xml')
            [System.IO.File]::WriteAllBytes($p, $bytes)
            $r = & $script:src -Path $p
            $r.Engine | Should -Be 'msix'
            $r.Confidence | Should -Be 'high'
        }
    }

    Context 'a hint is not proof (App. L.1, BINDING)' {
        It 'prefers the definitive install4j marker over an NSIS hint in the same file' {
            # The Aperio incident in one test. The file carries the NSIS branding string AND the install4j
            # parameter file. Answering nsis here means shipping /S, which shows the language dialog and
            # hangs forever. The hint must lose to the definitive marker even though both matched.
            $overlay = Join-Bytes (New-Ascii 'Nullsoft.NSIS wrapper text') (New-Pad 32) (New-Ascii 'i4jparams.conf')
            $p = Track (New-TestPe -Overlay $overlay)
            $r = & $script:src -Path $p
            $r.Engine | Should -Be 'install4j'
            $r.Confidence | Should -Be 'high'
            # Both markers are reported - the caller can see what was rejected and why.
            @($r.Evidence | Where-Object { $_.Kind -eq 'hint' }).Count | Should -BeGreaterThan 0
        }

        It 'reports low confidence when only a hint matched' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Built with InstallAware Setup'))
            $r = & $script:src -Path $p
            $r.Engine | Should -Be 'installaware'
            $r.Confidence | Should -Be 'low'
            @($r.Evidence | Where-Object { $_.Kind -eq 'hint' }).Count | Should -BeGreaterThan 0
        }

        It 'returns unknown rather than guessing on an unrecognised binary' {
            $p = Track (New-TestPe -Overlay (New-Blob 'nothing interesting here at all'))
            $r = & $script:src -Path $p
            $r.Engine | Should -Be 'unknown'
            $r.Confidence | Should -Be 'unknown'
            @($r.Evidence).Count | Should -Be 0
        }
    }

    Context 'output contract' {
        It 'always reports hash and size, whatever the engine' {
            $p = Track (New-TestPe -Overlay (New-Blob 'NullsoftInst'))
            $r = & $script:src -Path $p
            $r.Sha256 | Should -Match '^[0-9a-f]{64}$'
            $r.SizeBytes | Should -BeGreaterThan 0
            $r.Path | Should -Be $p
        }

        It 'records where each marker was found' {
            $p = Track (New-TestPe -Overlay (New-Blob 'i4jparams.conf'))
            $e = @((& $script:src -Path $p).Evidence)[0]
            $e.Marker | Should -Not -BeNullOrEmpty
            $e.Offset | Should -BeGreaterThan 0
            $e.Region | Should -Not -BeNullOrEmpty
            $e.Kind | Should -Be 'definitive'
        }

        It 'emits valid JSON under -Json' {
            $p = Track (New-TestPe -Overlay (New-Blob 'NullsoftInst'))
            $json = & $script:src -Path $p -Json
            { $json | ConvertFrom-Json } | Should -Not -Throw
            ($json | ConvertFrom-Json).Engine | Should -Be 'nsis'
        }
    }

    Context 'house conventions' {
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

        It 'never calls exit' {
            (Get-Content -LiteralPath $script:src -Raw) | Should -Not -Match '(?m)^\s*exit\s'
        }
    }
}

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

    It 'reports ProductName for an MSI, which FileVersionInfo cannot give' {
        # A compound file is not a PE, so FileVersionInfo returns nothing and every MSI used to come
        # back with a null product name. The verified-switch store keys its same-product fallback on
        # that field, so the whole MSI class could never reach it.
        $msi = 'C:\PSADT\Packages\VLC\Files\vlc-3.0.23-win64.msi'
        if (-not (Test-Path $msi)) { Set-ItResult -Skipped -Because 'the fixture MSI is not on this machine'; return }
        $r = & $script:src -Path $msi
        $r.IsMsi | Should -BeTrue
        $r.ProductName | Should -Not -BeNullOrEmpty
        $r.ProductVersion | Should -Not -BeNullOrEmpty
    }
}

Describe 'identity strings come out trimmed (0.49.3)' {
    # Measured 2026-09-27 on a real Inno Setup installer: its version resource pads ProductName,
    # ProductVersion and CompanyName to a fixed width with trailing spaces - the product name was followed
    # by 49 of them. FileVersionInfo hands that over verbatim, and every consumer inherited it: the switch
    # candidates, the research ladder (whose search queries then carried the padding), the verified-switch
    # store and the logo lookup's miss message. Trimmed once, here, where the value enters the skill.
    BeforeAll {
        . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:src -Name 'Get-Identity')))
    }

    It 'trims a padded version-resource value' {
        $msiProps = @{}
        Get-Identity 'ProductName' ('Widget Pro' + (' ' * 49)) | Should -BeExactly 'Widget Pro'
    }

    It 'trims a padded MSI property' {
        $msiProps = @{ ProductName = "  Widget`t " }
        Get-Identity 'ProductName' $null | Should -BeExactly 'Widget'
    }

    It 'falls back to the version resource when the MSI property is only whitespace' {
        $msiProps = @{ ProductName = '    ' }
        Get-Identity 'ProductName' 'Widget ' | Should -BeExactly 'Widget'
    }

    It 'returns nothing for a value that is only whitespace' {
        $msiProps = @{}
        Get-Identity 'ProductName' '     ' | Should -BeNullOrEmpty
    }

    It 'trims the real installer it was found on' {
        $exe = 'C:\PSADT\Packages\CPU-Z_3.01\Files\cpu-z_3.01-en.exe'
        if (-not (Test-Path $exe)) { Set-ItResult -Skipped -Because 'the real installer is not on this machine'; return }
        $r = & $script:src -Path $exe
        $r.ProductName | Should -BeExactly 'CPUID CPU-Z'
        $r.ProductVersion | Should -BeExactly '3.01'
        $r.Publisher | Should -BeExactly 'CPUID, Inc.'
    }
}


Describe 'Get-PsadtInstallerEngine: portable payloads (0.50.0)' {
    # Terraform 1.16.5 (2026-10-13) was reported as installshield-installscript off ONE word in .rdata, and
    # the research ladder budgeted three agents for an installer that does not exist. A Go build ID in the
    # code sections names the binary as the application itself.
    BeforeAll {
        . "$PSScriptRoot/_helpers.ps1"
        $script:src2 = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Get-PsadtInstallerEngine.ps1')).ProviderPath
        $script:made2 = New-Object System.Collections.Generic.List[string]
    }
    AfterAll { foreach ($p in $script:made2) { Remove-Item $p -Force -ErrorAction SilentlyContinue } }

    It 'calls a Go program with only an installer HINT portable-binary, at high confidence' {
        $p = New-TestPe -FirstSectionData (Join-Bytes (New-Ascii 'Go build ID: "abc/def"') (New-Pad 16) (New-Ascii 'InstallShield'))
        $script:made2.Add($p)
        $r = & $script:src2 -Path $p
        $r.Engine | Should -Be 'portable-binary'
        $r.Confidence | Should -Be 'high'
        $r.IsGoBinary | Should -BeTrue
        @($r.Evidence | Where-Object { $_.Marker -eq 'Go build ID' -and $_.Kind -eq 'definitive' }).Count | Should -Be 1
    }

    It 'still lets a DEFINITIVE installer marker win over a Go build ID' {
        # A Go-built bootstrapper that really is an NSIS installer stays NSIS.
        $p = New-TestPe -FirstSectionData (New-Ascii 'Go build ID: "x"') -Overlay (New-Blob 'NullsoftInst')
        $script:made2.Add($p)
        (& $script:src2 -Path $p).Engine | Should -Be 'nsis'
    }

    It 'ignores a Go build ID that sits in the overlay - that is payload, not the program' {
        $p = New-TestPe -Overlay (New-Blob 'Go build ID: "x"')
        $script:made2.Add($p)
        $r = & $script:src2 -Path $p
        $r.Engine | Should -Not -Be 'portable-binary'
        $r.IsGoBinary | Should -BeFalse
    }

    It 'calls a plain ZIP zip-archive, lists its entries and finds the Go program inside' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('zipsrc_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'tool.exe'), (Join-Bytes (New-Pad 64) (New-Ascii 'Go build ID: "x"') (New-Pad 64)))
        Set-Content -LiteralPath (Join-Path $dir 'LICENSE.txt') -Value 'license'
        $zip = Join-Path ([System.IO.Path]::GetTempPath()) ('engine_' + [guid]::NewGuid().ToString('N') + '.zip')
        [System.IO.Compression.ZipFile]::CreateFromDirectory($dir, $zip)
        Remove-Item $dir -Recurse -Force
        $script:made2.Add($zip)

        $r = & $script:src2 -Path $zip
        $r.Engine | Should -Be 'zip-archive'
        $r.Confidence | Should -Be 'high'
        $r.ArchiveEntries | Should -Contain 'tool.exe'
        $r.IsGoBinary | Should -BeTrue
    }
}
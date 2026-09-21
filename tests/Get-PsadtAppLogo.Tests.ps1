# SCOPE NOTE: this script is the only one in the skill whose PURPOSE is to fetch from the open web, so
# the rules it is held to are the opposite way round from its siblings.
#
#   - The tests never touch the network. Everything asserted here is the part that decides WHAT to
#     fetch and WHETHER to accept the result - a lookup, a refusal, and an image operation - and all of
#     that runs offline against a fixture catalog and a synthesised bitmap. Asserting that logo.wine
#     serves a Firefox SVG today would be a test of logo.wine.
#   - It must never build a source URL from a product name. A guessed slug that 404s costs a minute; a
#     guessed slug that RESOLVES gives a confident wrong logo, and nothing downstream looks at the
#     picture. The source guard below enforces that as behaviour, not as prose.
#   - Border-keying is the one piece of real logic here, and the thing it must NOT do is the obvious
#     implementation. Keying every white pixel erases the white envelope inside the Thunderbird mark, so
#     the test puts white INSIDE the artwork and asserts it survived.

BeforeAll {
    . "$PSScriptRoot/_helpers.ps1"
    $script:src = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Get-PsadtAppLogo.ps1')).ProviderPath
    $script:catalog = (Resolve-Path (Join-Path $PSScriptRoot '..\references\switch-catalog\logo-sources.json')).ProviderPath

    # Source guards match against the CODE with comments blanked out: the file explains the very trap it
    # avoids, and matching raw source would flag a correct file for documenting the rule.
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

    function New-Catalog {
        param([object[]]$Entries)
        $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
        ([pscustomobject]@{ schemaVersion = 1; entries = $Entries } | ConvertTo-Json -Depth 8) |
            Set-Content -LiteralPath $p -Encoding UTF8
        return $p
    }
}

Describe 'Get-PsadtAppLogo' {

    Context 'guards' {
        It 'throws when given neither a product name nor a binary' {
            { & $script:src } | Should -Throw -ExpectedMessage '*Nothing to go on*'
        }

        It 'reports a miss for a product the catalog does not know, and writes nothing' {
            $out = Join-Path $TestDrive 'should-not-exist.png'
            $r = & $script:src -ProductName 'No Such Product' -OutFile $out -CatalogPath (New-Catalog @())
            $r.Found | Should -BeFalse
            ($r.Misses -join ' ') | Should -Match 'No Such Product'
            Test-Path -LiteralPath $out | Should -BeFalse
        }

        It 'hands the reader a way to look it up instead of guessing one' {
            $r = & $script:src -ProductName 'No Such Product' -CatalogPath (New-Catalog @())
            ($r.Warnings -join ' ') | Should -Match 'logo\.wine'
            ($r.Warnings -join ' ') | Should -Match 'LOOK at the image'
        }

        It 'degrades to a miss when the catalog is not readable JSON' {
            $p = Join-Path $TestDrive 'broken.json'
            Set-Content -LiteralPath $p -Value '{ not json' -Encoding UTF8
            $r = & $script:src -ProductName 'Firefox' -CatalogPath $p
            $r.Found | Should -BeFalse
            ($r.Misses -join ' ') | Should -Match 'not readable JSON'
        }

        It 'refuses a fetch mode it does not implement rather than doing something plausible' {
            $c = New-Catalog @(@{ productName = 'X'; source = 's'; url = 'https://example.invalid/x'; fetch = 'telepathy' })
            { & $script:src -ProductName 'X' -OutFile (Join-Path $TestDrive 'x.png') -CatalogPath $c } |
                Should -Throw -ExpectedMessage "*unknown fetch mode*"
        }

        It 'refuses a postProcess it does not implement' {
            $c = New-Catalog @(@{ productName = 'X'; source = 's'; url = 'https://example.invalid/x'; fetch = 'png-direct'; postProcess = 'enhance' })
            # png-direct will fail on the unreachable host first; what matters is that the mode is not
            # silently ignored, so assert on the source instead of provoking a download.
            $script:code | Should -Match "unknown postProcess"
        }

        It 'returns the entry without writing when no -OutFile is given' {
            $r = & $script:src -ProductName 'Firefox' -CatalogPath $script:catalog
            $r.Found | Should -BeTrue
            $r.OutFile | Should -BeNullOrEmpty
            ($r.Warnings -join ' ') | Should -Match 'nothing was written'
        }
    }

    Context 'it reads the catalog, it does not invent sources' {
        It 'never builds a source URL out of the product name' {
            # The failure this prevents is not a 404. It is a slug that RESOLVES to the wrong product,
            # served with full confidence to a tile nobody inspects.
            $script:code | Should -Not -Match '\$ProductName[^\r\n]*logo\.wine'
            $script:code | Should -Not -Match 'logo\.wine[^\r\n]*\$ProductName'
            $script:code | Should -Not -Match '-replace[^\r\n]*\$ProductName[^\r\n]*https'
        }

        It 'takes the url verbatim from the entry' {
            $c = New-Catalog @(@{ productName = 'X'; source = 'fixture'; url = 'https://example.invalid/exact.svg'; fetch = 'svg-rasterize' })
            $r = & $script:src -ProductName 'X' -CatalogPath $c
            $r.Url | Should -BeExactly 'https://example.invalid/exact.svg'
        }

        It 'resolves the config home through the sibling script, never LOCALAPPDATA directly' {
            $script:code | Should -Not -Match 'LOCALAPPDATA'
        }
    }

    Context 'the shipped catalog' {
        It 'is readable JSON with a schema version' {
            $c = Get-Content -LiteralPath $script:catalog -Raw | ConvertFrom-Json
            $c.schemaVersion | Should -Be 1
            @($c.entries).Count | Should -BeGreaterThan 0
        }

        It 'gives every entry a product name, a url, a fetch mode and a date it was checked' {
            $c = Get-Content -LiteralPath $script:catalog -Raw | ConvertFrom-Json
            foreach ($e in $c.entries) {
                $e.productName | Should -Not -BeNullOrEmpty
                $e.url | Should -Match '^https://'
                $e.fetch | Should -BeIn @('svg-rasterize', 'png-direct', 'webp-decode')
                $e.verifiedAt | Should -Match '^\d{4}-\d{2}-\d{2}$'
            }
        }

        It 'records WHY each entry was chosen, because the next reader cannot see the image' {
            # Both traps this catalog exists for are name traps: the Firefox brand mark versus the
            # browser logo, and a Thunderbird source that is clean but years out of date. An entry
            # without that sentence is an entry that will be replaced by the wrong file eventually.
            $c = Get-Content -LiteralPath $script:catalog -Raw | ConvertFrom-Json
            foreach ($e in $c.entries) {
                ([string]$e.note).Length | Should -BeGreaterThan 40 -Because "$($e.productName) needs its reason recorded"
            }
        }

        It 'names no product twice' {
            $c = Get-Content -LiteralPath $script:catalog -Raw | ConvertFrom-Json
            $names = @($c.entries | ForEach-Object { $_.productName })
            @($names | Sort-Object -Unique).Count | Should -Be $names.Count
        }
    }

    Context 'border-key: the background is what touches the edge' {
        BeforeAll {
            # Rebuild the function out of the script so the algorithm can be exercised without a download.
            $fnText = Get-ScriptFunctionText -Path $script:src -Name 'Invoke-BorderKey'
            . ([scriptblock]::Create($fnText))
        }

        It 'clears the border white but keeps white that is INSIDE the artwork' {
            # This is the Thunderbird envelope in miniature: a white square enclosed by solid colour,
            # sitting on a white background. A global white key erases both; only a flood from the edge
            # erases the right one.
            Add-Type -AssemblyName System.Drawing.Common
            $size = 90
            $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.Clear([System.Drawing.Color]::White)
            $g.FillRectangle([System.Drawing.Brushes]::Blue, 20, 20, 50, 50)   # the artwork
            $g.FillRectangle([System.Drawing.Brushes]::White, 35, 35, 20, 20)  # white INSIDE it
            $g.Dispose()
            $p = Join-Path $TestDrive 'key.png'
            $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()

            Invoke-BorderKey -Path $p -Tolerance 12 | Out-Null

            $out = [System.Drawing.Bitmap]::FromFile($p)
            try {
                $out.GetPixel(0, 0).A | Should -Be 0 -Because 'the corner is background'
                $out.GetPixel($size - 1, $size - 1).A | Should -Be 0
                $out.GetPixel(45, 45).A | Should -Be 255 -Because 'that white is the envelope, not the background'
                $out.GetPixel(25, 25).A | Should -Be 255 -Because 'the artwork itself must be untouched'
            } finally { $out.Dispose() }
        }

        It 'reaches into a concave notch, which a scanline pass would leave filled' {
            # A U shape: the background reaches the middle only by going around. Four edge scans would
            # stop at the arms and leave the inside of the U opaque.
            Add-Type -AssemblyName System.Drawing.Common
            $size = 90
            $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.Clear([System.Drawing.Color]::White)
            $g.FillRectangle([System.Drawing.Brushes]::Red, 20, 20, 12, 50)   # left arm
            $g.FillRectangle([System.Drawing.Brushes]::Red, 58, 20, 12, 50)   # right arm
            $g.FillRectangle([System.Drawing.Brushes]::Red, 20, 58, 50, 12)   # base
            $g.Dispose()
            $p = Join-Path $TestDrive 'notch.png'
            $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()

            Invoke-BorderKey -Path $p -Tolerance 12 | Out-Null

            $out = [System.Drawing.Bitmap]::FromFile($p)
            try {
                $out.GetPixel(45, 30).A | Should -Be 0 -Because 'the notch opens to the top, so it is background'
                $out.GetPixel(25, 30).A | Should -Be 255 -Because 'the arm is artwork'
            } finally { $out.Dispose() }
        }
    }

    Context 'house conventions' {
        It 'is ASCII-clean' {
            $bytes = [System.IO.File]::ReadAllBytes($script:src)
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }

        It 'parses without errors' {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($script:src, [ref]$null, [ref]$errors) | Out-Null
            @($errors).Count | Should -Be 0
        }

        It 'never calls exit' {
            $script:code | Should -Not -Match '(?m)^\s*exit\b'
        }
    }
}

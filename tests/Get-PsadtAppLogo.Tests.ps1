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

        It 'gives every entry a key to be found by, a url, a fetch mode and a date it was checked' {
            # A product name, an app key (0.49.2: vendor + name, the identity that survives a version
            # bump), or both. An entry with neither can never be matched.
            $c = Get-Content -LiteralPath $script:catalog -Raw | ConvertFrom-Json
            foreach ($e in $c.entries) {
                ([string]$e.productName + [string]$e.appKey) | Should -Not -BeNullOrEmpty
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

        It 'names no product twice, and no app key twice' {
            $c = Get-Content -LiteralPath $script:catalog -Raw | ConvertFrom-Json
            $names = @($c.entries | Where-Object { $_.productName } | ForEach-Object { $_.productName })
            @($names | Sort-Object -Unique).Count | Should -Be $names.Count
            $keys = @($c.entries | Where-Object { $_.appKey } | ForEach-Object { $_.appKey })
            @($keys | Sort-Object -Unique).Count | Should -Be $keys.Count
        }

        It 'stores every app key in the normalised form the lookup computes' {
            . (Join-Path $PSScriptRoot '..\scripts\_AppKey.ps1')
            $c = Get-Content -LiteralPath $script:catalog -Raw | ConvertFrom-Json
            foreach ($e in @($c.entries | Where-Object { $_.appKey })) {
                $e.appKey | Should -BeExactly ($e.appKey.ToLowerInvariant() -replace '\s+', ' ').Trim()
            }
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

Describe 'the logo lookup finds the next version and checks what it rendered (0.49.2)' {
    # Measured 2026-09-27 on a real second version:
    #   * headless Edge's launcher returned after 169 ms and the screenshot landed ~1.5 s later, so the
    #     script reported "no screenshot" for a render that was still running;
    #   * the vendor SVG had width/height but no viewBox, rendered 68 px inside a 1024 px canvas, and
    #     passed every check - size, squareness, corner alpha - because none of them looks at the content;
    #   * the catalog matched productName exactly, and the MSI ProductName carries the version.
    BeforeAll {
        foreach ($fn in 'Repair-SvgViewBox', 'Measure-ContentBox', 'Wait-FileStable', 'Find-LogoCatalogEntry') {
            . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:src -Name $fn)))
        }
        . (Join-Path $PSScriptRoot '..\scripts\_AppKey.ps1')
        Add-Type -AssemblyName System.Drawing.Common
        function New-Canvas {
            param([int]$Size, [System.Drawing.Color]$Ground, [int]$SquareAt = -1, [int]$SquareSize = 0)
            $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.Clear($Ground)
            if ($SquareSize -gt 0) { $g.FillRectangle([System.Drawing.Brushes]::Blue, $SquareAt, $SquareAt, $SquareSize, $SquareSize) }
            $g.Dispose()
            $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.png')
            $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            return $p
        }
    }

    Context 'the catalog entry is found across versions' {
        It 'matches on the app identity when the product name carries the version' {
            $c = New-Catalog @(@{ appKey = 'acme widget'; productName = 'Widget'; source = 'fixture'; url = 'https://example.invalid/w.svg'; fetch = 'svg-rasterize' })
            $r = & $script:src -ProductName 'Widget 2.1' -Vendor 'ACME' -Name 'Widget' -CatalogPath $c
            $r.Found     | Should -BeTrue
            $r.MatchedBy | Should -Be 'appKey'
            $r.AppKey    | Should -Be 'acme widget'
        }

        It 'takes the identity from a package manifest' {
            $c = New-Catalog @(@{ appKey = 'acme widget'; source = 'fixture'; url = 'https://example.invalid/w.svg'; fetch = 'svg-rasterize' })
            $mf = Join-Path $TestDrive 'psadt-package.json'
            @{ schema = 1; app = @{ vendor = 'ACME'; name = 'Widget'; version = '2.1' } } | ConvertTo-Json | Set-Content $mf -Encoding UTF8
            $r = & $script:src -ManifestPath $mf -CatalogPath $c
            $r.Found     | Should -BeTrue
            $r.MatchedBy | Should -Be 'appKey'
        }

        It 'ignores padding and doubled spaces in the product name' {
            $c = New-Catalog @(@{ productName = 'Widget Pro'; source = 'fixture'; url = 'https://example.invalid/w.svg'; fetch = 'svg-rasterize' })
            $r = & $script:src -ProductName '  Widget   Pro      ' -CatalogPath $c
            $r.Found     | Should -BeTrue
            $r.MatchedBy | Should -Be 'productName'
        }

        It 'still refuses to guess: a versioned name without an identity is a miss' {
            $c = New-Catalog @(@{ productName = 'Widget'; source = 'fixture'; url = 'https://example.invalid/w.svg'; fetch = 'svg-rasterize' })
            (& $script:src -ProductName 'Widget 2.1' -CatalogPath $c).Found | Should -BeFalse
        }
    }

    Context 'an SVG without a viewBox is given one' {
        It 'adds viewBox from numeric width and height, so the mark scales to the canvas' {
            $svg = '<svg xmlns="http://www.w3.org/2000/svg" width="68.26667" height="68.26667" id="svg1" version="1.1"><rect width="10" height="10"/></svg>'
            $out = Repair-SvgViewBox -SvgText $svg
            $out | Should -Match 'viewBox="0 0 68\.26667 68\.26667"'
            ([xml]$out).svg.viewBox | Should -Be '0 0 68.26667 68.26667'
        }
        It 'accepts a px unit on the dimensions' {
            (Repair-SvgViewBox -SvgText '<svg width="512px" height="256px"></svg>') | Should -Match 'viewBox="0 0 512 256"'
        }
        It 'leaves an SVG that already has a viewBox alone' {
            $svg = '<svg viewBox="0 0 10 10" width="68" height="68"></svg>'
            Repair-SvgViewBox -SvgText $svg | Should -BeExactly $svg
        }
        It 'leaves relative dimensions alone - a percentage says nothing about the drawing' {
            $svg = '<svg width="100%" height="100%"></svg>'
            Repair-SvgViewBox -SvgText $svg | Should -BeExactly $svg
        }
        It 'touches only the root element, never a nested svg' {
            $svg = '<svg viewBox="0 0 10 10"><svg width="5" height="5"></svg></svg>'
            Repair-SvgViewBox -SvgText $svg | Should -BeExactly $svg
        }
    }

    Context 'what the picture actually holds is measured' {
        It 'measures a small mark in a large canvas and warns about it' {
            $p = New-Canvas -Size 1024 -Ground ([System.Drawing.Color]::Transparent) -SquareAt 476 -SquareSize 72
            $m = Measure-ContentBox -Path $p
            $m.Fill | Should -BeGreaterThan 0.06
            $m.Fill | Should -BeLessThan 0.08
            $m.Warning | Should -Match 'fills'
        }
        It 'accepts a mark that fills the tile' {
            $p = New-Canvas -Size 512 -Ground ([System.Drawing.Color]::Transparent) -SquareAt 32 -SquareSize 448
            $m = Measure-ContentBox -Path $p
            $m.Fill | Should -BeGreaterThan 0.8
            $m.Warning | Should -BeNullOrEmpty
        }
        It 'measures against the ground colour on an opaque image' {
            $p = New-Canvas -Size 400 -Ground ([System.Drawing.Color]::White) -SquareAt 100 -SquareSize 200
            $m = Measure-ContentBox -Path $p
            $m.ContentBox.Width | Should -Be 200
            $m.ContentBox.X     | Should -Be 100
        }
        It 'warns about a mark that sits far off centre' {
            $p = New-Canvas -Size 512 -Ground ([System.Drawing.Color]::Transparent) -SquareAt 0 -SquareSize 330
            (Measure-ContentBox -Path $p).Warning | Should -Match 'centre'
        }
        It 'refuses an image with nothing in it' {
            $p = New-Canvas -Size 256 -Ground ([System.Drawing.Color]::Transparent)
            { Measure-ContentBox -Path $p } | Should -Throw -ExpectedMessage '*nothing visible*'
        }
    }

    Context 'the render is waited for, not assumed' {
        It 'returns only once a file that arrives late has stopped growing' {
            $p = Join-Path $TestDrive 'late.png'
            $job = Start-ThreadJob -ScriptBlock {
                param($p)
                Start-Sleep -Milliseconds 700
                $fs = [System.IO.File]::Open($p, 'Create', 'Write', 'Read')
                try { foreach ($i in 1..4) { $fs.Write((New-Object byte[] 4096), 0, 4096); $fs.Flush(); Start-Sleep -Milliseconds 300 } }
                finally { $fs.Dispose() }
            } -ArgumentList $p
            try {
                Wait-FileStable -Path $p -TimeoutSeconds 20 | Should -BeTrue
                (Get-Item -LiteralPath $p).Length | Should -Be 16384 -Because 'a half-written screenshot must not count'
            } finally { $job | Wait-Job | Remove-Job }
        }
        It 'gives up after its timeout for a file that never comes' {
            Wait-FileStable -Path (Join-Path $TestDrive 'never.png') -TimeoutSeconds 1 | Should -BeFalse
        }
    }

    Context 'the output is written once, after the checks' {
        It 'does all fetching and post-processing in its scratch folder, never in -OutFile' {
            $script:code | Should -Not -Match 'Invoke-WebRequest[^\r\n]*-OutFile \$OutFile'
            $script:code | Should -Not -Match 'Copy-Item[^\r\n]*-Destination \$OutFile'
            $script:code | Should -Not -Match 'Invoke-BorderKey -Path \$OutFile'
        }
        It 'commits with a replace that throws, instead of Move-Item -Force' {
            # \b: -Match ignores case, and 'Remove-Item' ends in 'move-Item'.
            $script:code | Should -Not -Match '\bMove-Item[^\r\n]*-Force'
            $script:code | Should -Match 'File\]::Replace'
        }
        It 'measures the content before the file is committed' {
            $script:code.IndexOf('Measure-ContentBox -Path') | Should -BeLessThan $script:code.IndexOf('Save-LogoOutput -Source')
        }
        It 'waits for the screenshot and cleans up the Edge processes it started' {
            $script:code | Should -Match 'Wait-FileStable -Path \$shot'
            $script:code | Should -Match 'Win32_Process'
            $script:code | Should -Match 'Stop-Process'
        }
    }
}

Describe 'an opaque tile is not a defect, and a padded name is not a name (0.49.3)' {
    # Measured 2026-09-27 on a real app whose icon IS a coloured tile: the catalog entry said
    # transparent:false, no postProcess, and a note explaining that the tile is the mark. The lookup
    # still warned "the corners are not transparent ... add postProcess border-key" - advice that, taken,
    # floods the tile away and leaves a chip floating on nothing. `transparent` describes the SOURCE: with
    # border-key it says "opaque, key it"; without one it says "opaque by design, keep it".
    BeforeAll {
        . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:src -Name 'Get-LogoGroundWarning')))
    }

    It 'says nothing about an opaque result when the entry declares the tile opaque by design' {
        Get-LogoGroundWarning -Entry ([pscustomobject]@{ transparent = $false; postProcess = $null }) -Transparent $false |
            Should -BeNullOrEmpty
    }

    It 'still recommends border-key for an entry that says nothing about its ground' {
        Get-LogoGroundWarning -Entry ([pscustomobject]@{ postProcess = $null }) -Transparent $false |
            Should -Match 'border-key'
    }

    It 'names a render that lost the transparency its entry promised' {
        $w = Get-LogoGroundWarning -Entry ([pscustomobject]@{ transparent = $true; postProcess = $null }) -Transparent $false
        $w | Should -Match 'transparent'
        $w | Should -Not -Match 'add postProcess'
    }

    It 'names a border-key that did not clear the corners' {
        Get-LogoGroundWarning -Entry ([pscustomobject]@{ transparent = $false; postProcess = 'border-key' }) -Transparent $false |
            Should -Match 'border-key did not'
    }

    It 'is silent when the result is transparent' {
        Get-LogoGroundWarning -Entry ([pscustomobject]@{ postProcess = $null }) -Transparent $true | Should -BeNullOrEmpty
    }

    It 'reports a padded product name without its padding' {
        $r = & $script:src -ProductName ('No Such Product' + (' ' * 49)) -CatalogPath (New-Catalog @())
        $r.ProductName | Should -BeExactly 'No Such Product'
        ($r.Misses -join ' ') | Should -Match "product 'No Such Product'"
    }

    It 'ships the entry the tile case was found on, found by its app key' {
        $r = & $script:src -Vendor 'CPUID' -Name 'CPU-Z' -CatalogPath $script:catalog
        $r.Found | Should -BeTrue
        $r.MatchedBy | Should -Be 'appKey'
        $r.Fetch | Should -Be 'svg-rasterize'
    }
}

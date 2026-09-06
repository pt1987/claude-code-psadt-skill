# Guards for references/Report-Template.html.
#
# WHY THIS FILE EXISTS: on 2026-09-06 a patch turned "\n" inside a JS string literal into a REAL newline.
# That is a syntax error, so the browser discarded the ENTIRE <script> block - language toggle, copy
# buttons and the condensing sticky header all stopped working at once. Every Pester test still passed,
# because they only assert on rendered HTML strings, and the dossier still LOOKS finished. A generated
# document whose interactivity is silently dead is exactly the failure a test suite should not miss.

BeforeAll {
    $script:Tpl = (Resolve-Path (Join-Path $PSScriptRoot '..\references\Report-Template.html')).Path
    $script:Html = Get-Content -LiteralPath $script:Tpl -Raw
    $script:Js = [regex]::Match($script:Html, '(?s)<script>(.*?)</script>').Groups[1].Value
    $script:Node = (Get-Command node -ErrorAction SilentlyContinue)
}

Describe 'Report template JavaScript' {
    It 'has exactly one script block' {
        ([regex]::Matches($script:Html, '<script')).Count | Should -Be 1
        $script:Js | Should -Not -BeNullOrEmpty
    }

    It 'contains no raw newline inside a single-quoted string literal' {
        # The concrete 2026-09-06 breakage, checked without node so it runs everywhere. A heuristic: line
        # comments are stripped first (this template has no '//' inside a string literal) and escaped
        # quotes are removed, then an odd number of quotes means a literal ran past the end of the line.
        $bs = [string][char]92
        foreach ($line in ($script:Js -split "`n")) {
            $code = ($line -replace '//.*$', '')
            $code = $code.Replace($bs + "'", '')
            $quotes = ([regex]::Matches($code, "'")).Count
            $quotes % 2 | Should -Be 0 -Because "unbalanced single quotes mean a string literal runs past the end of the line: $line"
        }
    }

    It 'parses as valid JavaScript' -Skip:(-not (Get-Command node -ErrorAction SilentlyContinue)) {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tpl_" + [guid]::NewGuid().ToString('N') + '.js')
        Set-Content -LiteralPath $tmp -Value $script:Js -Encoding UTF8
        try {
            & node --check $tmp 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0 -Because 'a syntax error silently disables the whole script block'
        } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'still wires up every interactive feature at boot' {
        # A syntax error is not the only way to lose these - deleting a boot call is just as quiet.
        foreach ($fn in 'renderPreviews()', 'setLang(', 'addRowCopy()') {
            $script:Js | Should -BeLike "*$fn*"
        }
    }

    It 'keeps the sticky-header condense logic' {
        $script:Js | Should -Match 'scrollY'
    }

    It 'copies every table by clicking the row, with no hover icons left' {
        # One interaction for the whole document. The per-cell icon was a 24px target for the value the
        # table exists to hand over; it is gone, and nothing may reintroduce it.
        $script:Js | Should -Match 'function addRowCopy'
        $script:Js | Should -Not -Match 'copy-ic'
        $script:Js | Should -Not -Match 'addFieldCopyButtons'
    }

    It 'covers every table section and picks the right cell for each' {
        $spec = [regex]::Match($script:Js, "(?s)var COPY_ROWS = \[(.*?)\];").Groups[1].Value
        foreach ($id in 'appinfo', 'program', 'requirements', 'detection', 'deps', 'logo', 'returncodes', 'assign', 'systemtest') {
            $spec | Should -BeLike "*id: '$id'*"
        }
        # Key/value tables hand over the VALUE; a return code and a group name are the FIRST cell.
        $spec | Should -Match "id: 'returncodes', mode: 'first'"
        $spec | Should -Match "id: 'assign', mode: 'first'"
        $spec | Should -Match "id: 'appinfo', mode: 'value'"
    }

    It 'leaves a row own interactive elements clickable' {
        # The detection script sits behind a <summary>; swallowing that click would make the fold
        # impossible to open.
        $script:Js | Should -Match "summary, details, a, button, input"
    }

    It 'does not hijack a text selection when the row is clicked' {
        $script:Js | Should -Match 'getSelection'
    }
}

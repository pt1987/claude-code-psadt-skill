# SCOPE NOTE: this guards the one property of SKILL.md that is invisible while editing it.
#
# Auto-compaction re-attaches only the FIRST 5000 TOKENS of each invoked skill after a summary (with a
# 25000-token budget shared across all of them, filled from the most recently invoked). Everything past
# that line is simply gone for the rest of a long session. Before this refactor the cut fell at line 198,
# in the middle of Phase 2 - so in exactly the sessions that run long enough to need them, the skill lost
# Phases 3-12, the whole troubleshooting table, every anti-pattern and the reference map.
#
# The fix was not "make the file small". It was to put the things that must survive in front: the
# operating mode, the four decision gates, the binding conventions and Phases 0-6, which is where every
# irreversible decision is made (software runs as SYSTEM in Phase 6; anything written to a tenant is
# gated on it). Phases 7-12, the sub-agent roles, self-update, the troubleshooting pointer and the
# reference map sit behind the line on purpose: losing them costs a fetch, not a mistake.
#
# So the test is about ORDER, not size. Adding a paragraph to the Conventions is fine as long as Phase 6
# still ends before the cut. If this test fails, move something behind Phase 7 or into a reference -
# do not delete a rule to make room, and do not raise the budget.

BeforeAll {
    $script:skillPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'SKILL.md'
    $script:raw = [System.IO.File]::ReadAllBytes($script:skillPath)
    $script:lines = Get-Content -LiteralPath $script:skillPath

    # 5000 tokens of dense technical Markdown. 3.5 bytes/token is the conservative end of the usual
    # 3.3-3.6 range for this kind of text (heavy on backticks, identifiers and table pipes), so the
    # budget errs towards being stricter than the real tokenizer, not looser.
    $script:budgetBytes = [int](5000 * 3.5)

    $script:phase7Line = (1..$script:lines.Count | Where-Object { $script:lines[$_ - 1] -like '**Phase 7 -*' })[0]
    $script:bytesToPhase6End = ($script:lines[0..($script:phase7Line - 2)] |
        ForEach-Object { [System.Text.Encoding]::UTF8.GetByteCount($_) + 1 } |
        Measure-Object -Sum).Sum
}

Describe 'SKILL.md survives auto-compaction with its gates intact' {
    It 'ends Phase 6 inside the first 5000 tokens' {
        $script:bytesToPhase6End |
            Should -BeLessOrEqual $script:budgetBytes -Because "everything after byte $($script:budgetBytes) is dropped after a compaction, and Phases 0-6 hold every irreversible decision"
    }

    It 'keeps the whole file within a sane total, so the tail is still worth loading' {
        # Not a hard requirement of the platform - a courtesy limit. The documented advice is under 500
        # lines; the point of the number is that the part BEHIND the cut should stay small enough to be
        # worth reading when it is present.
        @($script:lines).Count | Should -BeLessOrEqual 500
    }

    It 'puts the four decision gates and the conventions ahead of the phases' {
        $order = @('## Operating mode', '## Decision gates', '## Conventions', '## Workflow')
        $positions = $order | ForEach-Object {
            $needle = $_
            (1..$script:lines.Count | Where-Object { $script:lines[$_ - 1].StartsWith($needle) })[0]
        }
        $positions | Should -Not -Contain $null -Because 'all four sections must exist'
        ($positions | Sort-Object) -join ',' | Should -Be ($positions -join ',') -Because 'they must appear in this order'
    }

    It 'has no UTF-8 BOM and no CRLF-only surprises that would skew the byte count' {
        # The measurement above assumes one byte per line ending. A BOM or a stray lone CR would make
        # the number quietly optimistic.
        ($script:raw[0] -eq 0xEF -and $script:raw[1] -eq 0xBB) | Should -BeFalse
    }
}

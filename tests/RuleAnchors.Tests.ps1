# SCOPE NOTE: this file is the mechanical answer to "did the refactor lose a rule?".
#
# SKILL.md is a control plane that routes into references/. Moving depth out of it is the right
# move - after auto-compaction only the first 5000 tokens of a skill come back, so anything past
# that line is gone in a long session and belongs in a reference the agent can fetch on demand.
# The risk in moving it is that a binding rule quietly stops existing, or keeps existing in a file
# nothing points at, which is the same thing from the agent's side.
#
# So every binding rule carries an anchor: <!-- rule:<slug> --> on the line above it. The inventory
# lives in tests/rule-inventory.txt. This test asserts that each id is still findable EITHER in
# SKILL.md OR in a references/ file that SKILL.md actually routes to. Content may move between
# those freely; it may not vanish, and it may not become unreachable.
#
# The reachability half matters as much as the presence half. A rule parked in
# references/appendix-z.md that SKILL.md never mentions passes a naive grep and fails in practice -
# the agent has no reason to open the file. That failure has already happened once in this repo
# (Appendix L gained MSIX sections that SKILL.md never learned about; see tests/SKILL.Tests.ps1).

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:skillMd = Get-Content -LiteralPath (Join-Path $script:root 'SKILL.md') -Raw

    $invPath = Join-Path $PSScriptRoot 'rule-inventory.txt'
    $script:rules = Get-Content -LiteralPath $invPath |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' } |
        ForEach-Object { ($_ -split '\s+', 2)[0] }

    # References SKILL.md routes to: a file under references/ whose NAME appears in SKILL.md.
    # Naming the file is what makes it reachable, so that is the test for reachability.
    $refDir = Join-Path $script:root 'references'
    $script:routedFiles = @(
        Get-ChildItem -LiteralPath $refDir -Filter '*.md' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $script:skillMd -like ('*' + $_.Name + '*') }
    )
    $script:reachable = $script:skillMd + "`n" + (
        ($script:routedFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    )

    # Every anchor that physically exists anywhere in the docs, routed or not.
    $script:anchorsEverywhere = @(
        @(Get-ChildItem -LiteralPath $refDir -Filter '*.md' -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) + $script:skillMd |
            ForEach-Object { [regex]::Matches($_, '<!--\s*rule:([a-z0-9-]+)\s*-->') } |
            ForEach-Object { $_ } | ForEach-Object { $_.Groups[1].Value }
    ) | Sort-Object -Unique
}

Describe 'the binding-rule inventory' {
    It 'is not empty - an empty inventory would make every other test in this file vacuous' {
        @($script:rules).Count | Should -BeGreaterThan 20
    }

    It 'has no duplicate ids' {
        @($script:rules).Count | Should -Be (@($script:rules | Sort-Object -Unique).Count)
    }
}

Describe 'every binding rule is still present and still reachable' {
    It 'finds an anchor for every id in the inventory' {
        # Reported as one list rather than one failure at a time: after a move you want to see
        # everything that fell out, not the first thing alphabetically.
        $lost = @($script:rules | Where-Object { $script:reachable -notmatch [regex]::Escape("rule:$_") })
        $lost -join ', ' | Should -BeNullOrEmpty -Because 'these rule ids exist in no routed document any more'
    }

    It 'has no anchor sitting in a reference SKILL.md does not route to' {
        # Present but unreachable is the failure mode this repo has actually hit. A rule the agent
        # cannot find is a rule the agent does not follow.
        $stranded = @($script:anchorsEverywhere | Where-Object { $script:reachable -notmatch [regex]::Escape("rule:$_") })
        $stranded -join ', ' | Should -BeNullOrEmpty -Because 'these anchors exist in a file nothing points at'
    }

    It 'has no anchor that is missing from the inventory' {
        # Catches a typo in a slug, and catches someone adding a rule without recording it.
        $unlisted = @($script:anchorsEverywhere | Where-Object { $_ -notin $script:rules })
        $unlisted -join ', ' | Should -BeNullOrEmpty -Because 'every anchor must be listed in tests/rule-inventory.txt'
    }
}

Describe 'the gates specifically stay in SKILL.md itself' {
    # These are not reference material. They decide whether software runs as SYSTEM and whether
    # anything is written to a tenant, and they have to survive auto-compaction, which keeps only
    # the first 5000 tokens of the skill. A gate that moved into a reference would still pass the
    # reachability test above and would still be wrong.
    It '<_> is in the control plane, not in a reference' -ForEach @(
        'gate-scope-confirm', 'gate-deployment-semantics', 'gate-system-test-consent', 'gate-upload-confirm',
        'test-before-upload', 'preflight-green-gate', 'phase6-system-test', 'upload-dry-run-first',
        'research-is-data'
    ) {
        $script:skillMd | Should -Match ([regex]::Escape("rule:$_"))
    }
}

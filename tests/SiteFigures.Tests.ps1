# SCOPE NOTE: the landing page counts things, and nothing was checking that it counted right.
#
# index.html carries a row of stat tiles - phases, scripts, reference files, installer engines - plus
# a few inline figures. They are hand-maintained, they live on the gh-pages branch, and they sit
# entirely outside the tests that guard everything else in this repo. The page even claims
# "Figures as of vX.Y.Z and verified against the repository at that version", which is exactly the
# kind of promise that rots quietly.
#
# It had already rotted twice when this file was written (2026-09-16, found by a reader, not by CI):
# the Phase 2 step still said the installer engine was "1 of 14" while the catalog had grown to 19 -
# contradicting the tile on the same screen - and the script count was one behind, because
# Get-PsadtLocalEvidence.ps1 arrived in 0.33.0 and nobody retyped the number.
#
# So: every figure that can be DERIVED from the repository is derived and compared. The ones that
# cannot are named at the bottom with the reason, rather than silently omitted - an untested figure
# that looks tested is worse than an obvious gap.
#
# The page is not in this branch's working tree, so it is read out of the gh-pages ref. Two things
# about HOW that is done, both learned the hard way:
#   * The read happens in BeforeAll, not at discovery scope. Running git while Pester is discovering
#     the file aborts the whole container with "a 'break' or 'continue' statement ... escaped from
#     your code" (pester/Pester#2669) - a message that says nothing about the actual cause.
#   * Each test skips ITSELF when the ref is missing, rather than -Skip on the Describe. -Skip is
#     evaluated during discovery, before BeforeAll has run, so it would report every test as skipped
#     whether or not the page was reachable.
# CI fetches the ref explicitly (see .github/workflows/tests.yml) so the guard is real there too; a
# developer who has never fetched gh-pages sees skips instead of failures they cannot act on.

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent

    $script:site = $null
    foreach ($ref in @('origin/gh-pages', 'gh-pages')) {
        if ($null -eq $script:site) {
            $text = & git -C $script:root show "${ref}:index.html" 2>$null
            if ($LASTEXITCODE -eq 0 -and $text) { $script:site = ($text -join "`n") }
        }
    }

    # --- the expected values, all derived from the repository ------------------------------------
    $scripts = @(Get-ChildItem -LiteralPath (Join-Path $script:root 'scripts') -Filter '*.ps1' -File)
    $script:scriptCount = $scripts.Count
    # A leading underscore marks a shared include: dot-sourced by the others, never invoked directly.
    $script:invocableCount = @($scripts | Where-Object { $_.Name -notlike '_*' }).Count
    $script:includeCount = $script:scriptCount - $script:invocableCount

    $script:referenceCount = @(Get-ChildItem -LiteralPath (Join-Path $script:root 'references') -Filter '*.md' -File).Count
    $script:appendixCount = @(Get-ChildItem -LiteralPath (Join-Path $script:root 'references') -Filter 'appendix-*.md' -File).Count

    $catalog = Get-Content -LiteralPath (Join-Path $script:root 'references/switch-catalog/engine-defaults.json') -Raw | ConvertFrom-Json
    # engines is an ARRAY. Counting $catalog.engines.PSObject.Properties instead returns 8 - the
    # properties of the array object itself - which is a wrong number that looks entirely plausible.
    $script:engineCount = @($catalog.engines).Count

    $skill = Get-Content -LiteralPath (Join-Path $script:root 'SKILL.md') -Raw
    $script:gateCount = @([regex]::Matches($skill, '<!--\s*rule:gate-[a-z-]+\s*-->')).Count


    function Test-SiteAvailable {
        if ($script:site) { return $true }
        Set-ItResult -Skipped -Because 'no gh-pages ref in this clone - fetch it to run this guard'
        return $false
    }

    function Get-Tile {
        param([string]$Label)
        $m = [regex]::Match($script:site, "value:\s*'(\d+)',\s*label:\s*'$([regex]::Escape($Label))'(?:,\s*note:\s*'([^']*)')?")
        if (-not $m.Success) { return $null }
        [pscustomobject]@{ Value = [int]$m.Groups[1].Value; Note = $m.Groups[2].Value }
    }
}

Describe 'the landing page counts what the repository actually contains' {

    It 'the installer-engine tile matches the switch catalog' {
        if (-not (Test-SiteAvailable)) { return }
        (Get-Tile 'installer engines').Value | Should -Be $script:engineCount
    }

    It 'the Phase 2 step agrees with that tile' {
        # This is the one that broke: a second place naming the same number, on the same screen.
        if (-not (Test-SiteAvailable)) { return }
        $m = [regex]::Match($script:site, "label:\s*'Installer engine',\s*meta:\s*'1 of (\d+)'")
        $m.Success | Should -BeTrue -Because 'the Phase 2 step list should still name the engine count'
        [int]$m.Groups[1].Value | Should -Be $script:engineCount
    }

    It 'the script tile matches scripts/, including its invocable/include split' {
        if (-not (Test-SiteAvailable)) { return }
        $tile = Get-Tile 'PowerShell scripts'
        $tile.Value | Should -Be $script:scriptCount
        $tile.Note | Should -Be "$($script:invocableCount) invocable, plus $($script:includeCount) shared includes"
    }

    It 'the reference tile matches references/' {
        if (-not (Test-SiteAvailable)) { return }
        (Get-Tile 'reference files').Value | Should -Be $script:referenceCount
    }

    It 'the appendix count in the prose matches references/appendix-*.md' {
        if (-not (Test-SiteAvailable)) { return }
        $m = [regex]::Match($script:site, '(\d+)\s+reference appendices')
        $m.Success | Should -BeTrue
        [int]$m.Groups[1].Value | Should -Be $script:appendixCount
    }

    It 'the decision-gate tile matches the gate anchors in SKILL.md' {
        if (-not (Test-SiteAvailable)) { return }
        (Get-Tile 'decision gates').Value | Should -Be $script:gateCount
    }

    It 'the page agrees with itself about which version it describes' {
        # The page names a version in three places - the changelog link, the figures footnote and the
        # colophon - and one of them getting missed is the same class of bug as the engine count.
        #
        # Deliberately NOT compared against package.json: the release commit lands before the site is
        # deployed, so equality would fail on every release and teach everyone to ignore this file.
        # Internal agreement is the part that is always true when the page is correct.
        if (-not (Test-SiteAvailable)) { return }
        $versions = @([regex]::Matches($script:site, 'v(\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $versions.Count | Should -Be 1 -Because "the page should name one version, found: $($versions -join ', ')"
    }

    # NOT asserted, on purpose:
    #   'phases'       - 13 is the shape of the workflow, not a count of anything countable. A regex
    #                    over "Phase N" headings would pass while the page said something wrong about
    #                    what those phases ARE, so it would test the wrong thing.
    #   'Pester tests' - would have to run this suite to know, from inside this suite. That figure is
    #                    updated by the release that changes it, and the changelog records both numbers.
}

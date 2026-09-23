# SCOPE NOTE: the figures the docs quote about this repository, checked against the repository.
#
# WHY THIS FILE EXISTS: counts written as prose rot at the cadence this project releases at. The 2026-09-21
# audit found "11 pre-flight checks" in three files while the script emitted 13; two days and one release
# later the script emitted 14 and all three files still said 11. The same release added scripts and tests
# without touching "35 files: 32 invocable" or "657 tests". None of the existing guards cover a number:
# DocCrossRefs checks labels and paths, SiteFigures checks the published page, RuleAnchors checks rule ids.
#
# So the rule here is: a figure about this repo is either DERIVED from the repo, or it is asserted against
# the thing that owns it. The Pester total is owned by the CHANGELOG's `Suite <old> -> <new>` line, because
# that is where the release routine already records it and a live count would make this file slow and
# circular. Everything else is counted from the files themselves.

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent

    # --- derived from the repository -------------------------------------------------------------
    $preflight = Get-Content -LiteralPath (Join-Path $script:root 'scripts/Invoke-PsadtPreflight.ps1') -Raw
    $script:checkCount = @([regex]::Matches($preflight, "Add-Check\s+'([^']+)'") |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique).Count

    $scripts = @(Get-ChildItem -LiteralPath (Join-Path $script:root 'scripts') -Filter '*.ps1' -File)
    $script:scriptCount    = $scripts.Count
    $script:invocableCount = @($scripts | Where-Object { $_.Name -notlike '_*' }).Count
    $script:includeCount   = $script:scriptCount - $script:invocableCount
    $script:referenceCount = @(Get-ChildItem -LiteralPath (Join-Path $script:root 'references') -Filter '*.md' -File).Count

    # --- owned by the CHANGELOG ------------------------------------------------------------------
    $script:changelog = Get-Content -LiteralPath (Join-Path $script:root 'CHANGELOG.md') -Raw
    $suite = [regex]::Match($script:changelog, 'Suite\s+\d+\s*->\s*(\d+)')
    $script:suiteTotal = if ($suite.Success) { [int]$suite.Groups[1].Value } else { $null }

    # --- the documents that quote them ------------------------------------------------------------
    $script:docs = @(
        foreach ($rel in 'README.md', 'docs/features.md', 'docs/setup-and-structure.md', 'docs/installation.md') {
            $p = Join-Path $script:root $rel
            if (Test-Path -LiteralPath $p) {
                [pscustomobject]@{ Name = $rel; Text = (Get-Content -LiteralPath $p -Raw) }
            }
        }
    )

    # Every "<n> <unit>" claim in the docs, so a NEW wrong number is caught as well as a stale one.
    function Get-Claims([string]$pattern) {
        foreach ($d in $script:docs) {
            foreach ($m in [regex]::Matches($d.Text, $pattern)) {
                [pscustomobject]@{ Doc = $d.Name; Value = [int]$m.Groups[1].Value; Text = $m.Value.Trim() }
            }
        }
    }
}

Describe 'figures the docs quote about this repository' {
    It 'counts pre-flight checks the way the script does' {
        $script:checkCount | Should -BeGreaterThan 0 -Because 'the check names are read out of Invoke-PsadtPreflight.ps1'
        $claims = @(Get-Claims '(\d+)\s+checks')
        $claims | Should -Not -BeNullOrEmpty -Because 'the pre-flight gate is a headline feature and the docs quote its size'
        foreach ($c in $claims) {
            $c.Value | Should -Be $script:checkCount -Because "$($c.Doc) says '$($c.Text)' and the script emits $($script:checkCount) distinct checks"
        }
    }

    It 'counts the helper scripts the way the folder does' {
        $claims = @(Get-Claims '(\d+) files: \d+ invocable')
        foreach ($c in $claims) {
            $c.Value | Should -Be $script:scriptCount -Because "$($c.Doc) says '$($c.Text)' and scripts/ holds $($script:scriptCount) .ps1 files"
        }
        foreach ($c in @(Get-Claims '\d+ files: (\d+) invocable')) {
            $c.Value | Should -Be $script:invocableCount -Because "$($c.Doc) says '$($c.Text)' and $($script:invocableCount) of them are invocable (the rest are _-prefixed includes)"
        }
    }

    It 'counts the reference files the way the folder does' {
        foreach ($c in @(Get-Claims '(\d+) files, the agent-facing depth')) {
            $c.Value | Should -Be $script:referenceCount -Because "$($c.Doc) says '$($c.Text)' and references/ holds $($script:referenceCount) .md files"
        }
    }

    It 'quotes the Pester total the newest release recorded' {
        $script:suiteTotal | Should -Not -BeNullOrEmpty -Because 'the CHANGELOG owns this figure via its `Suite <old> -> <new>` line'
        $claims = @(Get-Claims '(\d+) Pester tests') + @(Get-Claims 'Pester suite, (\d+) tests')
        $claims | Should -Not -BeNullOrEmpty
        foreach ($c in $claims) {
            $c.Value | Should -Be $script:suiteTotal -Because "$($c.Doc) says '$($c.Text)' and the newest recorded suite total is $($script:suiteTotal)"
        }
    }

    It 'records the suite total in the newest release entry' {
        # The lapse this catches is real: 0.36.0 through 0.40.0 added cases while the figure stood still,
        # and 0.44.0 shipped with no Suite line at all - so the "newest recorded total" silently aged.
        $newest = [regex]::Match($script:changelog, '(?ms)^## \d+\.\d+\.\d+ - .*?(?=^## \d+\.\d+\.\d+ - |\z)')
        $newest.Success | Should -BeTrue -Because 'the CHANGELOG must open with a release entry'
        $newest.Value | Should -Match 'Suite\s+\d+\s*->\s*\d+' -Because 'every release records what the suite counted, or the figure the docs mirror goes stale'
    }
}

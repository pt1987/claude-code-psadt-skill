# SCOPE NOTE: these tests guard the COHERENCE of the control plane against the reference guide. SKILL.md is
# what an agent reads first and routes from; the guide is where the depth lives. The failure mode this file
# exists for is real and happened on 2026-09-08: Appendix L gained sections L.8 (MSIX/AppX) and L.9 (App-V)
# while SKILL.md never learned that MSIX exists at all - so a .msix would have been routed down the "native
# installer" path and wrapped in PSADT with the exact cmdlets L.8 documents as broken under SYSTEM.
#
# A missing pointer in the control plane makes new research unreachable. Content that nothing routes to is
# not documentation, it is dead weight.
BeforeAll {
    $script:skillRoot = Split-Path $PSScriptRoot -Parent
    $script:skillMd = Get-Content -LiteralPath (Join-Path $script:skillRoot 'SKILL.md') -Raw
    # The guide used to be one file. It is now one file per appendix, but each still opens with its
    # original "## Appendix X: ..." heading, so this guard keeps working on the concatenation and
    # keeps meaning the same thing: does SKILL.md point at appendices that exist?
    $script:guide = (
        Get-ChildItem -LiteralPath (Join-Path $script:skillRoot 'references') -Filter 'appendix-*.md' |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
    ) -join "`n"
}

Describe 'SKILL.md routes to appendices that actually exist' {
    It 'references no appendix the guide does not have' {
        # Catches the cheap half of the drift: a pointer to "App. R" that was never written.
        $referenced = [regex]::Matches($script:skillMd, 'App(?:endix|\.) ([A-Z])\b') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $present = [regex]::Matches($script:guide, '(?m)^## Appendix ([A-Z])') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

        $referenced | Should -Not -BeNullOrEmpty -Because 'the control plane must route into the guide at all'
        foreach ($letter in $referenced) {
            $present | Should -Contain $letter -Because "SKILL.md points at Appendix $letter"
        }
    }
}

Describe 'the Gate 1 package-type decision covers every model the guide documents' {
    It 'knows that MSIX/AppX is a package type, not a native installer' {
        # The expensive half of the drift. Without this, an MSIX is treated as "native installer (default)",
        # which is how it ends up wrapped in PSADT calling Add-AppxPackage as SYSTEM - registered for the
        # SYSTEM account, reported as a success, launchable by nobody.
        $script:skillMd | Should -Match 'MSIX'
    }

    It 'sends MSIX to Appendix L.8 rather than the generic switch table' {
        $script:skillMd | Should -Match 'L\.8'
    }

    It 'states that Intune takes MSIX natively, so wrapping is the exception' {
        # This is the decision itself, and it must be in the control plane: the default for a .msix is
        # Intune's own line-of-business app type, NOT a PSADT package.
        $script:skillMd | Should -Match '(?s)MSIX.*line-of-business|(?s)line-of-business.*MSIX'
    }
}

Describe 'every script invocation SKILL.md shows can bind' {
    # 2026-09-21 audit (B02): the Phase 9 example named a script whose Mandatory parameter the example did
    # not pass. Prose examples rot when parameter sets change; this guard binds each one against the real
    # param block: every -Name must exist, and at least one parameter set must have all of its mandatory
    # parameters supplied by the example. Values are placeholders and are not inspected.
    It 'names only real parameters and satisfies one parameter set per example' {
        $spans = [regex]::Matches($script:skillMd, '`(?:pwsh\s+)?(?:scripts/)?([A-Z][A-Za-z0-9-]+\.ps1)([^`]*)`')
        $examples = @($spans | Where-Object { $_.Groups[2].Value -match '(^|\s)-[A-Za-z]' })
        $examples.Count | Should -BeGreaterThan 5 -Because 'SKILL.md is the control plane and shows real invocations'
        $problems = foreach ($m in $examples) {
            $script = $m.Groups[1].Value
            $names  = @([regex]::Matches($m.Groups[2].Value, '(?:^|\s)-([A-Za-z][A-Za-z0-9]*)') | ForEach-Object { $_.Groups[1].Value })
            $path   = Join-Path $script:skillRoot "scripts/$script"
            if (-not (Test-Path -LiteralPath $path)) { "$script - not in scripts/"; continue }
            $cmd = Get-Command -Name $path -ErrorAction Stop
            $unknown = @($names | Where-Object { -not $cmd.Parameters.ContainsKey($_) })
            if ($unknown) { "$script - unknown parameter(s): $($unknown -join ', ')"; continue }
            $satisfied = @($cmd.ParameterSets | Where-Object {
                $set = $_
                $valid = @($names | Where-Object { $set.Parameters.Name -notcontains $_ }).Count -eq 0
                $mandatory = @($set.Parameters | Where-Object { $_.IsMandatory } | ForEach-Object { $_.Name })
                $valid -and (@($mandatory | Where-Object { $names -notcontains $_ }).Count -eq 0)
            })
            if (-not $satisfied) {
                $need = @($cmd.ParameterSets | ForEach-Object { $_.Parameters | Where-Object IsMandatory | ForEach-Object Name } | Sort-Object -Unique)
                "$script - example passes [$($names -join ', ')] but every parameter set needs more; mandatory across sets: [$($need -join ', ')]"
            }
        }
        $problems | Should -BeNullOrEmpty -Because "each example in SKILL.md must bind as written`n$($problems -join "`n")"
    }
}

Describe 'Phase 3 routes to every generator that ships' {
    # 2026-09-21 audit (B10): New-ExePackage.ps1 appeared nowhere in SKILL.md or references/, so Phase 3
    # sent all fifteen EXE engines to New-ADTTemplate and a hand-scaffold - the exact cost 0.35.0 built the
    # generator to remove. New-DriverPackage.ps1 was named at Gate 1 and in the reference table, but not in
    # the generator list an agent reads when it reaches Phase 3.
    It 'names each New-*Package.ps1 in the Phase 3 paragraph' {
        $phase3 = [regex]::Match($script:skillMd, '(?ms)^\*\*Phase 3 - Scaffold.*?(?=^\*\*Phase 4 )').Value
        $phase3 | Should -Not -BeNullOrEmpty -Because 'Phase 3 is the scaffold step'
        $generators = @(Get-ChildItem -LiteralPath (Join-Path $script:skillRoot 'scripts') -Filter 'New-*Package.ps1' -File |
            ForEach-Object { $_.Name })
        $generators.Count | Should -BeGreaterThan 3
        foreach ($g in $generators) {
            $phase3 | Should -Match ([regex]::Escape($g)) -Because "Phase 3 decides how a package is scaffolded, and $g exists to be chosen there"
        }
    }
}

Describe 'the description names every package type Gate 1 offers (0.46.0)' {
    # 2026-09-21 audit B11: two eval cases score 0 of 3 because the description mentions neither browser
    # extensions nor Windows features, while the skill ships a generator and an appendix for each and
    # lists both at Gate 1. A request for either never reaches the skill at all.
    BeforeAll {
        $script:frontMatter = [regex]::Match($script:skillMd, '(?ms)\A---\s*$.*?^---\s*$').Value
        $script:descLine    = [regex]::Match($script:skillMd, '(?m)^description:\s*(.+)$').Groups[1].Value
    }
    It 'mentions browser extensions' {
        $script:frontMatter | Should -Match '(?i)browser.?extension'
    }
    It 'mentions Windows features' {
        $script:frontMatter | Should -Match '(?i)windows.?feature'
    }
    It 'keeps the description inside the 1024-character limit' {
        $script:descLine.Length | Should -BeLessOrEqual 1024
    }
}

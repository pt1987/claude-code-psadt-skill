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

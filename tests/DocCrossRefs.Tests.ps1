# SCOPE NOTE: the reference guide used to be one 2942-line file, so "Appendix L.1" could not be a
# broken link - there was only ever one file to be in. Splitting it into a file per domain makes the
# label a real pointer, and a real pointer can rot.
#
# So this file resolves every "App. X" / "Appendix X" / "Phase N" label and every references/<file>
# path mentioned anywhere in the docs or in a script's comment-based help, and fails when one does
# not land on something that exists.
#
# It also checks the OTHER direction, which is the one that has actually bitten this repo: a
# reference nothing routes to is not documentation. Appendix L grew MSIX sections that SKILL.md
# never learned about, and for two releases a .msix was sent down the native-installer path because
# of it. A file that no map names is invisible to the agent regardless of what is in it.
#
# CHANGELOG.md and README.md's changelog section are excluded on purpose: they describe the repo as
# it was at each release, so they legitimately name files that no longer exist.

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:refDir = Join-Path $script:root 'references'

    $script:refFiles = @(Get-ChildItem -LiteralPath $script:refDir -File | Where-Object { $_.Extension -in '.md', '.html' })

    # Documents that must be internally consistent right now, and the scripts' comment-based help.
    $sources = @(
        Get-Item (Join-Path $script:root 'SKILL.md')
        Get-Item (Join-Path $script:root 'SECURITY.md')
        Get-ChildItem -LiteralPath $script:refDir -Filter '*.md' -File
        Get-ChildItem -LiteralPath (Join-Path $script:root 'scripts') -Filter '*.ps1' -File
        Get-ChildItem -LiteralPath (Join-Path $script:root 'evals') -Filter '*.md' -Recurse -File
    )
    # The README carries a full copy of the changelog after "## Changelog"; only the part above it
    # describes the current repo.
    $readme = Get-Content -LiteralPath (Join-Path $script:root 'README.md') -Raw
    $cut = $readme.IndexOf("`n## Changelog")
    $readmeCurrent = if ($cut -gt 0) { $readme.Substring(0, $cut) } else { $readme }

    $script:docs = @(
        foreach ($f in $sources) {
            [pscustomobject]@{ Name = $f.Name; Text = (Get-Content -LiteralPath $f.FullName -Raw) }
        }
        [pscustomobject]@{ Name = 'README.md (above the changelog)'; Text = $readmeCurrent }
    )

    $script:appendixLetters = @(
        $script:refFiles | ForEach-Object { if ($_.Name -match '^appendix-([a-z])-') { $Matches[1].ToUpper() } }
    ) | Sort-Object -Unique
}

Describe 'every appendix label resolves to a file' {
    It 'has no reference to an appendix that does not exist' {
        $bad = foreach ($d in $script:docs) {
            foreach ($m in [regex]::Matches($d.Text, 'App(?:endix|\.)\s+([A-Z])\b')) {
                $letter = $m.Groups[1].Value
                if ($letter -notin $script:appendixLetters) { '{0}: Appendix {1}' -f $d.Name, $letter }
            }
        }
        @($bad | Sort-Object -Unique) -join '; ' | Should -BeNullOrEmpty
    }

    It 'covers A through Q with one file each' {
        # Q was the live drift this catches: SKILL.md said "Appendix A-P" while Q existed and was
        # referenced three times.
        $expected = 65..81 | ForEach-Object { [char]$_ }   # A..Q
        ($script:appendixLetters -join '') | Should -Be ($expected -join '')
    }
}

Describe 'every phase label resolves to a file' {
    It 'has a phases file covering every referenced phase number' {
        $covered = @{}
        foreach ($f in $script:refFiles) {
            if ($f.Name -match '^phases-(\d+)-(\d+)\.md$') {
                [int]$Matches[1]..[int]$Matches[2] | ForEach-Object { $covered[$_] = $f.Name }
            }
        }
        $covered.Keys.Count | Should -BeGreaterThan 0 -Because 'there must be at least one phases file'

        $bad = foreach ($d in $script:docs) {
            foreach ($m in [regex]::Matches($d.Text, '(?<![\w.])Phase\s+(\d+)(?:\.\d+)?\b')) {
                $n = [int]$m.Groups[1].Value
                if (-not $covered.ContainsKey($n)) { '{0}: Phase {1}' -f $d.Name, $n }
            }
        }
        @($bad | Sort-Object -Unique) -join '; ' | Should -BeNullOrEmpty
    }
}

Describe 'every references/ path that is written down exists' {
    It 'has no dead references/ path' {
        $names = @($script:refFiles.Name)
        $bad = foreach ($d in $script:docs) {
            foreach ($m in [regex]::Matches($d.Text, 'references/([A-Za-z0-9._-]+)')) {
                # Trim a sentence-ending period: "see references/app-registration.md." captures the
                # full stop as part of the name and would report a file that is perfectly fine.
                $name = $m.Groups[1].Value.TrimEnd('.')
                if ($name -notin $names) { '{0}: references/{1}' -f $d.Name, $name }
            }
        }
        @($bad | Sort-Object -Unique) -join '; ' | Should -BeNullOrEmpty
    }
}

Describe 'every reference is routed to' {
    It 'has no reference file that no map names' {
        # "Routed to" means SKILL.md or references/README.md names the file. Anything else is a file
        # the agent has no reason to open.
        $maps = @(
            Get-Content -LiteralPath (Join-Path $script:root 'SKILL.md') -Raw
            Get-Content -LiteralPath (Join-Path $script:refDir 'README.md') -Raw
        ) -join "`n"
        $orphans = @(
            $script:refFiles | Where-Object { $_.Name -ne 'README.md' -and $maps -notlike ('*' + $_.Name + '*') }
        )
        ($orphans.Name -join ', ') | Should -BeNullOrEmpty -Because 'a reference nothing points at is invisible to the agent'
    }

    It 'routes to every appendix from SKILL.md itself, not only from the reference index' {
        # The index is one hop away. The control plane is what the agent reads first, and the failure
        # this repo hit was precisely a reference the control plane never mentioned.
        $skillMd = Get-Content -LiteralPath (Join-Path $script:root 'SKILL.md') -Raw
        $missing = @(
            $script:refFiles | Where-Object { $_.Name -like 'appendix-*' -and $skillMd -notlike ('*' + $_.Name + '*') }
        )
        ($missing.Name -join ', ') | Should -BeNullOrEmpty
    }
}

Describe 'the split kept the documents navigable' {
    It 'gives every reference over 100 lines a table of contents' {
        $bad = foreach ($f in $script:refFiles | Where-Object { $_.Extension -eq '.md' -and $_.Name -ne 'README.md' }) {
            $lines = @(Get-Content -LiteralPath $f.FullName)
            if ($lines.Count -gt 100 -and -not ($lines -contains '## Contents')) { $f.Name }
        }
        @($bad) -join ', ' | Should -BeNullOrEmpty
    }
}

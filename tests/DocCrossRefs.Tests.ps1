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

    # references/ gained its first SUBDIRECTORY in 0.30.0 (switch-catalog/, data rather than prose).
    # A path like "references/switch-catalog/engine-defaults.json" captures only the first segment, so
    # directory names have to count as valid targets or every mention of the catalog reads as a dead link.
    $script:refDirs = @(Get-ChildItem -LiteralPath $script:refDir -Directory)

    # Documents that must be internally consistent right now, and the scripts' comment-based help.
    # docs/ is included deliberately. When the README was split (0.36.0) its reference-grade sections
    # moved there, and with them every "App. X" / "Phase N" / references/<file> label they carry. Left
    # out of this list those labels would sit in an unchecked corner and rot quietly - which is the
    # exact condition this file exists to prevent.
    $docsDir = Join-Path $script:root 'docs'
    $sources = @(
        Get-Item (Join-Path $script:root 'SKILL.md')
        Get-Item (Join-Path $script:root 'SECURITY.md')
        Get-ChildItem -LiteralPath $script:refDir -Filter '*.md' -File
        Get-ChildItem -LiteralPath (Join-Path $script:root 'scripts') -Filter '*.ps1' -File
        Get-ChildItem -LiteralPath (Join-Path $script:root 'evals') -Filter '*.md' -Recurse -File
        if (Test-Path -LiteralPath $docsDir) { Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File }
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
        $names = @($script:refFiles.Name) + @($script:refDirs.Name)
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

# Discovery-time: -Skip is evaluated before BeforeAll runs, so the toolkit lookup has to happen out here.
$script:psadtManifest = Get-Module -ListAvailable PSAppDeployToolkit | Sort-Object Version -Descending | Select-Object -First 1

Describe 'the Phase 5.5 v3 -> v4 table points at cmdlets that exist' {
    # Found 2026-09-14 while reviewing an external patch: the table sent readers from Remove-MSIApplications
    # to Remove-ADTApplication, which v4 does not have (it is Uninstall-ADTApplication). A "forbidden ->
    # correct" table whose right column names nothing is worse than no table, and nothing here read it.
    # The manifest is READ with Import-PowerShellDataFile, never imported - importing PSADT has side effects.
    BeforeAll {
        $text = Get-Content -LiteralPath (Join-Path $script:refDir 'phases-0-6.md') -Raw
        $section = [regex]::Match($text, '(?s)### 5\.5 .*?(?=\r?\n### )').Value
        $script:v4Names = @([regex]::Matches($section, '(?m)^\| `[^`]+` \| `([^`]+)` \|\s*$') | ForEach-Object { $_.Groups[1].Value })
        $script:manifest = Get-Module -ListAvailable PSAppDeployToolkit | Sort-Object Version -Descending | Select-Object -First 1
    }

    It 'still finds the table' {
        # Guards the regex: a table that moved or changed shape must fail here, not pass vacuously below.
        $script:v4Names.Count | Should -BeGreaterOrEqual 10
        $script:v4Names | Should -Contain 'Uninstall-ADTApplication'
    }

    It 'names only functions the installed PSAppDeployToolkit exports' -Skip:(-not $script:psadtManifest) {
        $exported = @((Import-PowerShellDataFile -LiteralPath $script:manifest.Path).FunctionsToExport)
        $exported.Count | Should -BeGreaterThan 100
        $unknown = @($script:v4Names | Where-Object { $exported -notcontains $_ })
        ($unknown -join ', ') | Should -BeNullOrEmpty -Because "PSADT $($script:manifest.Version) exports no such command"
    }
}

Describe 'the documented harness success codes match the harness' {
    # Added 2026-09-14. Guide 6.1 tells the reader the harness default list so they can see that it is a
    # DIFFERENT list from PSADT's -SuccessExitCodes in the launcher - the distinction that cost three
    # sandbox runs on Citrix Workspace (App. G, fault 5). A documented list that has drifted from the
    # parameter default would teach exactly the wrong thing, silently.
    BeforeAll {
        $script:doc = Get-Content -LiteralPath (Join-Path $script:refDir 'phases-0-6.md') -Raw
        $script:script61 = Get-Content -LiteralPath (Join-Path (Split-Path $script:refDir -Parent) 'scripts\Invoke-PsadtSandboxTest.ps1') -Raw

        $m = [regex]::Match($script:doc, '(?s)has to be in BOTH lists.*?`([0-9, ]+)`')
        $script:documented = @($m.Groups[1].Value -split ',' | ForEach-Object { [int]$_.Trim() })

        $p = [regex]::Match($script:script61, '\[int\[\]\]\$SuccessExitCodes\s*=\s*@\(([0-9, ]+)\)')
        $script:actual = @($p.Groups[1].Value -split ',' | ForEach-Object { [int]$_.Trim() })
    }

    It 'still finds both lists' {
        # Anti-vacuity: if either regex stops matching, this fails instead of comparing two empty arrays.
        $script:documented.Count | Should -BeGreaterOrEqual 3
        $script:actual.Count | Should -BeGreaterOrEqual 3
    }

    It 'documents exactly the parameter default' {
        ($script:documented -join ', ') | Should -Be ($script:actual -join ', ') -Because 'guide 6.1 quotes the harness default so the reader can tell the two lists apart'
    }
}

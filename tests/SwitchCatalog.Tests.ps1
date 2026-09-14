# SCOPE NOTE: this file guards the switch catalog as DATA - the JSON shape, and the agreement between
# references/switch-catalog/engine-defaults.json and the Appendix L.2 table.
#
# Both have to exist. The table is what the agent reads in Phase 2 (it reads Markdown, not JSON), the JSON
# is what Get-PsadtSwitchCandidates.ps1 reads. Two copies of the same knowledge drift; commit 0.29.1 is the
# in-repo precedent - a mapping table quietly pointed at a cmdlet that does not exist, and nothing read it.
# So the two are bound here in BOTH directions, with an anti-vacuity check in front so that a table which
# moves or changes shape fails loudly instead of passing on zero matches.

BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
    $script:catalogPath = Join-Path $script:root 'references\switch-catalog\engine-defaults.json'
    $script:schemaPath = Join-Path $script:root 'references\switch-catalog\schema.catalog.json'
    $script:appendixL = Join-Path $script:root 'references\appendix-l-installers.md'

    $script:catalogRaw = Get-Content -LiteralPath $script:catalogPath -Raw
    $script:catalog = $script:catalogRaw | ConvertFrom-Json
    $script:jsonEngines = @($script:catalog.engines.engine) | Sort-Object

    # Every L.2 row that names an engine carries its catalog id as a code span right after the bold
    # display name. A row without an id (MSI-wrapped EXE) is a packaging PATTERN, not an engine, and is
    # deliberately exempt.
    $lText = Get-Content -LiteralPath $script:appendixL -Raw
    $script:tableIds = @(
        [regex]::Matches($lText, '(?m)^\|\s\*\*[^*]+\*\*\s`([a-z0-9-]+)`\s\|') |
            ForEach-Object { $_.Groups[1].Value }
    ) | Sort-Object
}

Describe 'switch catalog data' {

    Context 'engine-defaults.json' {
        It 'validates against schema.catalog.json' {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            { Test-Json -Json $script:catalogRaw -Schema $schema -ErrorAction Stop } | Should -Not -Throw
        }

        It 'has no duplicate engine id' {
            $dupes = @($script:jsonEngines | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
            $dupes -join ', ' | Should -BeNullOrEmpty
        }

        It 'gives every entry a dated source reference' {
            # An entry nobody has checked against its source is a liability, not a catalog. The schema
            # enforces the FORMAT of verifiedAt; this enforces that it is not a placeholder date.
            foreach ($e in $script:catalog.engines) {
                $e.sourceRef | Should -Not -BeNullOrEmpty -Because "$($e.engine) must say where its values came from"
                [datetime]::Parse($e.verifiedAt) | Should -BeGreaterThan ([datetime]'2020-01-01')
            }
        }

        It 'never promises a log switch it does not have' {
            # "(none)" is an answer. An empty string reads as "no value recorded yet" and would be
            # pasted into a command line as nothing at all.
            foreach ($e in $script:catalog.engines) {
                $e.installLog | Should -Not -BeNullOrEmpty -Because "$($e.engine) must state its log switch or say there is none"
            }
        }

        It 'is ASCII-clean' {
            $bytes = [System.IO.File]::ReadAllBytes($script:catalogPath)
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }
    }

    Context 'drift guard: Appendix L.2 and the JSON name the same engines' {
        It 'still finds the L.2 table' {
            # Guards the regex itself: a table that moved or changed shape must fail HERE, not pass
            # vacuously in the comparisons below.
            $script:tableIds.Count | Should -BeGreaterOrEqual 15
            $script:tableIds | Should -Contain 'inno'
            $script:tableIds | Should -Contain 'install4j'
        }

        It 'has a JSON entry for every engine the table names' {
            $missing = @($script:tableIds | Where-Object { $_ -notin $script:jsonEngines })
            $missing -join ', ' | Should -BeNullOrEmpty -Because 'App. L.2 must not advertise an engine the catalog cannot serve'
        }

        It 'has a table row for every engine in the JSON' {
            $missing = @($script:jsonEngines | Where-Object { $_ -notin $script:tableIds })
            $missing -join ', ' | Should -BeNullOrEmpty -Because 'a catalog entry the agent never sees in Phase 2 is invisible knowledge'
        }
    }

    Context 'the engine probe and the catalog agree' {
        It 'can serve every engine Get-PsadtInstallerEngine.ps1 is able to return' {
            # The probe naming an engine the catalog has never heard of would produce a hit with no
            # switch - the worst of both worlds, because it looks like an answer.
            $probe = Get-Content -LiteralPath (Join-Path $script:root 'scripts\Get-PsadtInstallerEngine.ps1') -Raw
            $returned = @(
                [regex]::Matches($probe, "Engine\s*=\s*'([a-z0-9-]+)'") | ForEach-Object { $_.Groups[1].Value }
            ) | Sort-Object -Unique | Where-Object { $_ -ne 'unknown' -and $_ -ne 'installshield' }

            $returned.Count | Should -BeGreaterOrEqual 10 -Because 'the marker table must still be parseable'
            $unknown = @($returned | Where-Object { $_ -notin $script:jsonEngines })
            $unknown -join ', ' | Should -BeNullOrEmpty
        }
    }

    Context 'exclusions' {
        It 'mentions Chocolatey nowhere in the repository' {
            # A deliberate, permanent exclusion: Chocolatey is not a source, not a fallback and not a
            # reference. This test file is the only place the word may appear, so that the rule can be
            # written down without breaking itself.
            $hits = Get-ChildItem -LiteralPath $script:root -Recurse -File -Include *.md, *.ps1, *.json, *.html, *.mjs, *.yml |
                Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.Name -ne 'SwitchCatalog.Tests.ps1' } |
                Select-String -Pattern 'chocolatey|choco\b' -SimpleMatch:$false -List |
                ForEach-Object { $_.Path.Replace($script:root, '') }
            $hits -join ', ' | Should -BeNullOrEmpty
        }
    }
}

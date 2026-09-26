# SCOPE NOTE: the candidate lookup is the thing Phase 2 calls BEFORE any web research, so the tests that
# matter most are about what it does when it finds nothing, and about what it refuses to do on its own.
#
# Two rules are enforced here as behaviour, not as prose:
#   - The default path is OFFLINE. The winget stage is opt-in (-WithWinget) because WinGet is opt-in
#     everywhere else in this skill (SKILL.md gate 1, App. I: "never recommended or auto-selected"), and
#     a lookup that quietly reached for the network on every app would make it the default by the back
#     door. Without the switch the stage must not even be attempted.
#   - The script REPORTS, it does not decide. It never writes psadt-package.json; the agent does that
#     after choosing, so that what landed in the manifest is always a choice someone made.
#
# The config home is redirected per test. Without that the suite would create - and leave behind - a
# verified-switch store under the real %LOCALAPPDATA%\psadt-deploy.

BeforeAll {
    . "$PSScriptRoot/_helpers.ps1"
    $script:src = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Get-PsadtSwitchCandidates.ps1')).ProviderPath
    $script:made = New-Object System.Collections.Generic.List[string]
    function Track([string]$p) { $script:made.Add($p); return $p }
    # Writes a store into the redirected config home. Until Set-PsadtVerifiedSwitch.ps1 existed there was
    # no way to produce one, which is why the hit branches below had never been exercised.
    function Write-Store {
        param([object[]]$Entries)
        ([pscustomobject]@{ schemaVersion = 1; entries = $Entries } | ConvertTo-Json -Depth 12) |
            Set-Content -LiteralPath (Join-Path $script:tempHome 'verified-switches.json') -Encoding UTF8
    }


    # A throwaway copy of a file Windows ships, for the fixtures that need a real ProductName:
    # New-TestPe writes no version resource, and the same-product fallback matches on exactly that
    # field, so a synthetic PE can never reach it. A test that can only ever skip is not a test.
    function New-NamedTestBinary {
        $dest = Join-Path ([System.IO.Path]::GetTempPath()) ('named_' + [guid]::NewGuid().ToString('N') + '.exe')
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\notepad.exe') -Destination $dest -Force
        return $dest
    }

    # Source guards match against the CODE with comments blanked out. Matching raw source would flag the
    # comment in which the script explains the very trap it avoids - the guard would fail on a correct
    # file purely because the file documents the rule. Same idiom as Get-PsadtMsiFacts.Tests.ps1.
    $raw = Get-Content -LiteralPath $script:src -Raw
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$tokens, [ref]$null) | Out-Null
    $builder = [System.Text.StringBuilder]::new($raw)
    foreach ($t in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $len = $t.Extent.EndOffset - $t.Extent.StartOffset
        [void]$builder.Remove($t.Extent.StartOffset, $len)
        [void]$builder.Insert($t.Extent.StartOffset, (' ' * $len))
    }
    $script:code = $builder.ToString()
}

AfterAll {
    foreach ($p in $script:made) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-PsadtSwitchCandidates' {

    # Pester rejects a per-test setup at the container root, so the config-home redirect lives here.
    BeforeEach {
        $script:oldHome = $env:PSADT_DEPLOY_HOME
        $script:tempHome = Join-Path ([System.IO.Path]::GetTempPath()) ('cand_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tempHome -Force | Out-Null
        $env:PSADT_DEPLOY_HOME = $script:tempHome
    }

    AfterEach {
        $env:PSADT_DEPLOY_HOME = $script:oldHome
        if ($script:tempHome -and (Test-Path $script:tempHome)) {
            Remove-Item $script:tempHome -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'guards' {
        It 'throws when the installer does not exist' {
            { & $script:src -Path 'C:\nope\missing.exe' } | Should -Throw -ExpectedMessage '*not found*'
        }
    }

    Context 'engine defaults (the offline stage that always runs)' {
        It 'serves an Inno installer its documented switches' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data (6.2.0)'))
            $r = & $script:src -Path $p
            $r.Engine | Should -Be 'inno'
            $c = @($r.Candidates)[0]
            $c.Source | Should -Be 'engine-default'
            $c.Stage | Should -Be 1
            $c.Confidence | Should -Be 'low'
            $c.Install | Should -Be '/VERYSILENT /SUPPRESSMSGBOXES /SP- /NORESTART'
            $c.Uninstall | Should -Be '/VERYSILENT /NORESTART'
        }

        It 'serves an MSI its switches and marks it as MSI' {
            $p = Track (New-TestCfb)
            $r = & $script:src -Path $p
            $r.Engine | Should -Be 'msi'
            $r.IsMsi | Should -BeTrue
            @($r.Candidates)[0].Install | Should -Be '/qn'
        }

        It 'carries the engine notes through, because that is where the traps live' {
            # install4j is the case the whole catalog exists for: its default is -q, and the note says
            # why /S is wrong. A candidate without the note is a switch without its warning.
            $p = Track (New-TestPe -Overlay (New-Blob 'i4jparams.conf'))
            $c = @((& $script:src -Path $p).Candidates)[0]
            $c.Install | Should -Be '-q'
            ($c.Notes -join ' ') | Should -Match 'NOT /S'
        }

        It 'produces no candidate at all for an unrecognised binary' {
            $p = Track (New-TestPe -Overlay (New-Blob 'nothing interesting here at all'))
            $r = & $script:src -Path $p
            $r.Engine | Should -Be 'unknown'
            @($r.Candidates).Count | Should -Be 0
            $miss = @($r.Misses | Where-Object { $_.Stage -eq 1 })
            $miss.Count | Should -Be 1
            $miss[0].Reason | Should -Not -BeNullOrEmpty
        }
    }

    Context 'the verified-switch cache (stage 0)' {
        It 'reports a miss naming both layers when neither exists yet' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            # Since 0.40.0 a shipped layer travels with the skill, so this case has to point the
            # shipped path somewhere empty - otherwise the test reads the real file and stops being
            # about an empty store at all.
            $r = & $script:src -Path $p -ShippedStorePath (Join-Path $script:tempHome 'absent.json')
            $miss = @($r.Misses | Where-Object { $_.Stage -eq 0 })
            $miss.Count | Should -Be 1
            $miss[0].Reason | Should -Match 'no verified-switch entries anywhere'
        }

        It 'resolves the store through the config home, never through LOCALAPPDATA directly' {
            # rule:config-home. Reading $env:LOCALAPPDATA here would ignore PSADT_DEPLOY_HOME and write
            # into the user's real profile during a test run.
            $script:code | Should -Not -Match '\$env:LOCALAPPDATA'
            $script:code | Should -Match 'Get-PsadtConfig\.ps1'
        }

        # Everything below was unreachable until Set-PsadtVerifiedSwitch.ps1 existed: the store had no
        # producer, so the hit branches had never run against anything but a hand-written JSON file.

        It 'says out loud when the stored switch is not self-contained' {
            # The store keeps the SWITCH and not the file it names. Firefox and Thunderbird are both
            # recorded as '/S /INI=<SupportFiles>\...ini', which is a true record of what a GREEN gate
            # proved and still not something a caller can run: handed on unread it becomes a literal
            # path that does not resolve, and installers of this family accept that silently.
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $sha = (Get-FileHash $p -Algorithm SHA256).Hash.ToLower()
            Write-Store @(@{
                    sha256     = $sha; productName = 'Fixture App'; productVersion = '1.0'
                    install    = '/S /INI=<SupportFiles>\app.ini'; uninstall = '/S'
                    scenarios  = @('Install', 'Uninstall', 'Reinstall', 'Repair', 'FinalUninstall')
                    verifiedAt = '2026-09-20'; verifiedBy = 'tester on TESTBOX'
                })
            $top = @((& $script:src -Path $p).Candidates | Where-Object { $_.Stage -eq 0 })[0]
            ($top.Notes -join ' ') | Should -Match 'NOT self-contained'
            ($top.Notes -join ' ') | Should -Match 'app\.ini'
        }

        It 'stays quiet about SupportFiles when the switch does not name one' {
            # A note on every entry is a note nobody reads.
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $sha = (Get-FileHash $p -Algorithm SHA256).Hash.ToLower()
            Write-Store @(@{
                    sha256     = $sha; productName = 'Fixture App'; productVersion = '1.0'
                    install    = '/VERYSILENT'; uninstall = '/VERYSILENT'
                    scenarios  = @('Install', 'Uninstall')
                    verifiedAt = '2026-09-20'; verifiedBy = 'tester on TESTBOX'
                })
            $top = @((& $script:src -Path $p).Candidates | Where-Object { $_.Stage -eq 0 })[0]
            ($top.Notes -join ' ') | Should -Not -Match 'self-contained'
        }

        It 'carries the note onto a different build of the same product as well' {
            # The demoted candidate is the one a version bump actually serves, so it is the one most
            # likely to be handed straight to a generator.
            $p = Track (New-NamedTestBinary)
            $engine = & (Join-Path (Split-Path $script:src -Parent) 'Get-PsadtInstallerEngine.ps1') -Path $p
            $engine.ProductName | Should -Not -BeNullOrEmpty -Because 'the fallback matches on this field'
            Write-Store @(@{
                    sha256     = ('e' * 64); productName = $engine.ProductName; appVersion = '1.0'
                    install    = '/S /INI=<SupportFiles>\app.ini'; uninstall = '/S'
                    scenarios  = @('Install', 'Uninstall')
                    verifiedAt = '2026-09-20'; verifiedBy = 'tester on TESTBOX'
                })
            $top = @((& $script:src -Path $p).Candidates | Where-Object { $_.Stage -eq 0 -and $_.Source -eq 'cache' })[0]
            $top | Should -Not -BeNullOrEmpty -Because 'the same-product fallback must have matched'
            $top.HashMatch | Should -BeFalse
            ($top.Notes -join ' ') | Should -Match 'NOT self-contained'
            ($top.Notes -join ' ') | Should -Match 'app\.ini'
        }

        It 'serves a hash match as verified' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $sha = (Get-FileHash $p -Algorithm SHA256).Hash.ToLower()
            Write-Store @(@{
                    sha256     = $sha; productName = 'Fixture App'; productVersion = '1.0'
                    install    = '/VERYSILENT /PROVEN'; uninstall = '/VERYSILENT'
                    scenarios  = @('Install', 'Uninstall', 'Reinstall', 'Repair', 'FinalUninstall')
                    verifiedAt = '2026-09-20'; verifiedBy = 'tester on TESTBOX'
                })
            $r = & $script:src -Path $p
            $top = @($r.Candidates | Where-Object { $_.Stage -eq 0 })[0]
            $top | Should -Not -BeNullOrEmpty
            $top.Confidence | Should -Be 'verified'
            $top.HashMatch | Should -BeTrue
            $top.Install | Should -Be '/VERYSILENT /PROVEN'
            $top.Evidence | Should -Match 'FinalUninstall'
            $top.SourceRef | Should -Match '2026-09-20'
        }

        It 'ranks a verified entry above the engine default' {
            # The rank table (verified/high/medium/low) had no test at all. The fixture is an Inno PE, so
            # stage 1 also produces a candidate and the two have to be ordered.
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $sha = (Get-FileHash $p -Algorithm SHA256).Hash.ToLower()
            Write-Store @(@{
                    sha256    = $sha; productName = 'Fixture App'; productVersion = '1.0'
                    install   = '/PROVEN'; scenarios = @('Install')
                    verifiedAt = '2026-09-20'; verifiedBy = 't'
                })
            $r = & $script:src -Path $p
            @($r.Candidates).Count | Should -BeGreaterThan 1
            $r.Candidates[0].Stage | Should -Be 0
            $r.Candidates[0].Confidence | Should -Be 'verified'
        }

        It 'falls back to an earlier build of the same product at medium confidence' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $engine = & (Join-Path $PSScriptRoot '..\scripts\Get-PsadtInstallerEngine.ps1') -Path $p
            Write-Store @(@{
                    sha256    = ('a' * 64); productName = $engine.ProductName; productVersion = '0.9'
                    install   = '/OLDBUILD'; scenarios = @('Install')
                    verifiedAt = '2026-01-01'; verifiedBy = 't'
                })
            $r = & $script:src -Path $p
            $hit = @($r.Candidates | Where-Object { $_.Stage -eq 0 })[0]
            if ($engine.ProductName) {
                $hit.Confidence | Should -Be 'medium'
                $hit.HashMatch | Should -BeFalse
                ($hit.Notes -join ' ') | Should -Match 'DIFFERENT build'
            }
            else {
                # A synthetic PE carries no version resource, so there is no product name to match on.
                # That is the reader's productName guard doing its job, not a failure.
                $hit | Should -BeNullOrEmpty
            }
        }

        It 'names the application version of the earlier build, not the wrapper version' {
            # The PE header of a WRAPPED installer carries the wrapper's version: every Mozilla full
            # installer reports 18.05, the version of the 7-Zip SFX module around the real installer.
            # The store keeps both, and this reference string is not decoration - line 688 of
            # Get-PsadtLocalEvidence.ps1 feeds it into the KnownContext of a research sub-agent, so
            # "previous version 18.05" for Firefox hands an agent a version that never existed.
            # The synthetic PE used elsewhere in this file has no version resource at all, which is
            # why this one test needs a real binary: without a ProductName the branch cannot be hit.
            $p = (Get-Process -Id $PID).Path
            $engine = & (Join-Path $PSScriptRoot '..\scripts\Get-PsadtInstallerEngine.ps1') -Path $p
            $engine.ProductName | Should -Not -BeNullOrEmpty -Because 'this case needs a PE that carries version info'
            Write-Store @(@{
                    sha256     = ('b' * 64); productName = $engine.ProductName
                    productVersion = '18.05'; appVersion = '153.3.0'
                    install    = '/S'; scenarios = @('Install')
                    verifiedAt = '2026-01-01'; verifiedBy = 't'
                })
            $hit = @((& $script:src -Path $p).Candidates | Where-Object { $_.Stage -eq 0 })[0]
            $hit.SourceRef | Should -Match ([regex]::Escape('153.3.0'))
            $hit.SourceRef | Should -Not -Match ([regex]::Escape('18.05'))
        }

        It 'still names a version for an entry written before appVersion existed' {
            $p = (Get-Process -Id $PID).Path
            $engine = & (Join-Path $PSScriptRoot '..\scripts\Get-PsadtInstallerEngine.ps1') -Path $p
            Write-Store @(@{
                    sha256     = ('c' * 64); productName = $engine.ProductName
                    productVersion = '6.5.6'
                    install    = '/S'; scenarios = @('Install')
                    verifiedAt = '2026-01-01'; verifiedBy = 't'
                })
            $hit = @((& $script:src -Path $p).Candidates | Where-Object { $_.Stage -eq 0 })[0]
            $hit.SourceRef | Should -Match ([regex]::Escape('6.5.6'))
        }

        It 'does not invent a same-product hit when neither side has a product name' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            Write-Store @(@{
                    sha256    = ('b' * 64); productName = $null; productVersion = $null
                    install   = '/NOPE'; scenarios = @('Install')
                    verifiedAt = '2026-01-01'; verifiedBy = 't'
                })
            $r = & $script:src -Path $p
            @($r.Candidates | Where-Object { $_.Stage -eq 0 }).Count | Should -Be 0
        }

        It 'degrades a malformed store to a miss instead of throwing' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            Set-Content -LiteralPath (Join-Path $script:tempHome 'verified-switches.json') -Value '{ not json' -Encoding UTF8
            # The shipped layer is pointed at an empty path so the only miss reported is the malformed
            # LOCAL one - which is what this case is about.
            { $script:rr = & $script:src -Path $p -ShippedStorePath (Join-Path $script:tempHome 'absent.json') } | Should -Not -Throw
            $miss = @($script:rr.Misses | Where-Object { $_.Stage -eq 0 })
            $miss.Count | Should -Be 1
            $miss[0].Reason | Should -Match 'not readable JSON'
        }

        It 'round-trips with the writer' {
            # The one case that catches the writer and the reader disagreeing on field names. A source
            # grep cannot: both files would still contain the strings they are supposed to.
            $pkg = Join-Path ([System.IO.Path]::GetTempPath()) ('rt_' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $pkg 'Files') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $pkg 'Invoke-AppDeployToolkit.ps1') -Value '# fixture' -Encoding UTF8
            $pe = New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data')
            Move-Item -LiteralPath $pe -Destination (Join-Path $pkg 'Files\setup.exe') -Force

            ([ordered]@{
                    schema   = 1
                    app      = [ordered]@{ vendor = 'Contoso'; name = 'Widget'; version = '3.1.4'; arch = 'x64' }
                    package  = [ordered]@{ name = 'Contoso_Widget'; type = 'installer'; installerTech = 'exe'; installerFile = 'setup.exe' }
                    research = [ordered]@{ switches = @{ installArgs = '/VERYSILENT /ROUNDTRIP'; uninstallArgs = '/VERYSILENT' } }
                } | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath (Join-Path $pkg 'psadt-package.json') -Encoding UTF8

            try {
                & (Join-Path $PSScriptRoot '..\scripts\Set-PsadtVerifiedSwitch.ps1') -PackagePath $pkg -Verdict 'GREEN' `
                    -Scenarios @('Install', 'Uninstall', 'Reinstall', 'Repair', 'FinalUninstall') | Out-Null

                $r = & $script:src -Path (Join-Path $pkg 'Files\setup.exe')
                $top = @($r.Candidates | Where-Object { $_.Stage -eq 0 })[0]
                $top.Confidence | Should -Be 'verified'
                $top.Install | Should -Be '/VERYSILENT /ROUNDTRIP'
                $top.Uninstall | Should -Be '/VERYSILENT'
            }
            finally { Remove-Item $pkg -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'the shipped layer, and how it merges with the local one (0.40.0)' {
        BeforeAll {
            # Writes a SHIPPED store to a temp path and hands it back, so no test ever reads or writes
            # the file the skill really ships.
            function Write-Shipped {
                param([object[]]$Entries)
                $p = Join-Path $script:tempHome ('shipped-' + [guid]::NewGuid().ToString('N') + '.json')
                ([pscustomobject]@{ schemaVersion = 1; entries = $Entries } | ConvertTo-Json -Depth 12) |
                    Set-Content -LiteralPath $p -Encoding UTF8
                return $p
            }
        }

        It 'serves a hash that only the shipped layer knows, and says where the proof came from' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $sha = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower()
            $shipped = Write-Shipped @(@{
                    sha256 = $sha; install = '/FROM-SHIPPED'; scenarios = @('Install','Uninstall','Reinstall','Repair','FinalUninstall')
                    verifiedAt = '2026-09-20'; verifiedBy = 'psadt-deploy reference run'
                })
            $r = & $script:src -Path $p -ShippedStorePath $shipped
            $hit = @($r.Candidates | Where-Object { $_.Stage -eq 0 })[0]
            $hit.Confidence | Should -Be 'verified'
            $hit.HashMatch  | Should -BeTrue
            $hit.Origin     | Should -Be 'shipped'
            $hit.Install    | Should -Be '/FROM-SHIPPED'
            $hit.SourceRef  | Should -BeLike '*shipped with the skill*'
            ($hit.Notes -join ' ') | Should -BeLike '*not on this one*'
        }

        It 'lets the LOCAL entry win for a hash both layers hold' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $sha = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower()
            Write-Store @(@{
                    sha256 = $sha; install = '/FROM-LOCAL'; scenarios = @('Install','Uninstall','Reinstall','Repair','FinalUninstall')
                    verifiedAt = '2026-09-21'; verifiedBy = 'this machine'
                })
            $shipped = Write-Shipped @(@{
                    sha256 = $sha; install = '/FROM-SHIPPED'; scenarios = @('Install')
                    verifiedAt = '2026-09-20'; verifiedBy = 'psadt-deploy reference run'
                })
            $hit = @((& $script:src -Path $p -ShippedStorePath $shipped).Candidates | Where-Object { $_.Stage -eq 0 })[0]
            $hit.Origin  | Should -Be 'local'
            $hit.Install | Should -Be '/FROM-LOCAL'
        }

        It 'merges idempotently - a hash in both layers yields ONE candidate, never two' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $sha = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower()
            $e = @{ sha256 = $sha; install = '/SAME'; scenarios = @('Install','Uninstall','Reinstall','Repair','FinalUninstall')
                    verifiedAt = '2026-09-20'; verifiedBy = 'x' }
            Write-Store @($e)
            $shipped = Write-Shipped @($e)
            $hits = @((& $script:src -Path $p -ShippedStorePath $shipped).Candidates | Where-Object { $_.Stage -eq 0 })
            $hits.Count | Should -Be 1
            # and running it again reaches exactly the same answer
            $again = @((& $script:src -Path $p -ShippedStorePath $shipped).Candidates | Where-Object { $_.Stage -eq 0 })
            $again.Count | Should -Be 1
            $again[0].Install | Should -Be $hits[0].Install
        }

        It 'does not let a damaged shipped layer take the local one down' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $sha = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower()
            Write-Store @(@{
                    sha256 = $sha; install = '/FROM-LOCAL'; scenarios = @('Install','Uninstall','Reinstall','Repair','FinalUninstall')
                    verifiedAt = '2026-09-21'; verifiedBy = 'this machine'
                })
            $broken = Join-Path $script:tempHome 'broken-shipped.json'
            Set-Content -LiteralPath $broken -Value '{ not json' -Encoding UTF8
            $r = & $script:src -Path $p -ShippedStorePath $broken
            $hit = @($r.Candidates | Where-Object { $_.Stage -eq 0 })[0]
            $hit.Install | Should -Be '/FROM-LOCAL'
        }

        It 'reports a miss naming BOTH layers when neither holds anything' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $empty = Join-Path $script:tempHome 'no-such-shipped.json'
            $r = & $script:src -Path $p -ShippedStorePath $empty
            $miss = @($r.Misses | Where-Object { $_.Stage -eq 0 })[0]
            $miss.Reason | Should -BeLike '*shipped*'
            $miss.Reason | Should -BeLike '*this machine*'
        }
    }

    Context 'the store that actually ships' {
        It 'is valid JSON with entries, and carries no internal hostname' {
            $p = Join-Path $PSScriptRoot '..\references\switch-catalog\verified-switches.json'
            Test-Path -LiteralPath $p | Should -BeTrue
            $raw = Get-Content -LiteralPath $p -Raw
            $doc = $raw | ConvertFrom-Json
            @($doc.entries).Count | Should -BeGreaterThan 0
            foreach ($e in $doc.entries) {
                $e.sha256 | Should -Match '^[0-9a-f]{64}$'
                # every shipped entry must be backed by a FULL gate, or it has no business claiming
                # 'verified' on somebody else's machine
                @($e.scenarios) | Should -Contain 'Install'
                @($e.scenarios) | Should -Contain 'FinalUninstall'
            }
            # the repository is public: a machine name must never travel with it
            $raw | Should -Not -Match 'SN-[A-Z0-9]{6,}'
        }
    }

    Context 'winget stays opt-in (App. I: never recommended or auto-selected)' {
        It 'does not attempt the winget stage without -WithWinget' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $r = & $script:src -Path $p
            $miss = @($r.Misses | Where-Object { $_.Stage -eq 2 })
            $miss.Count | Should -Be 1
            $miss[0].Reason | Should -Match 'opt-in'
        }

        It 'makes no network call on any path in this release' {
            $script:code | Should -Not -Match 'Invoke-RestMethod'
            $script:code | Should -Not -Match 'Invoke-WebRequest'
        }
    }

    Context 'reporting, not deciding' {
        It 'never writes the package manifest' {
            # The agent writes research.switches after CHOOSING a candidate. A script that wrote it
            # would turn a catalog lookup into a silent decision.
            $script:code | Should -Not -Match 'Set-PsadtPackageManifest'
        }

        It 'reports every stage it checked, hit or miss' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $r = & $script:src -Path $p
            $seen = @(@($r.Candidates).Stage) + @(@($r.Misses).Stage)
            0, 1, 2 | ForEach-Object { $seen | Should -Contain $_ }
        }

        It 'restricts the run with -Stage' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $r = & $script:src -Path $p -Stage 1
            $all = @(@($r.Candidates).Stage) + @(@($r.Misses).Stage)
            $all | Should -Not -Contain 0
            $all | Should -Not -Contain 2
        }

        It 'emits valid JSON under -Json' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $json = & $script:src -Path $p -Json
            { $json | ConvertFrom-Json } | Should -Not -Throw
            ($json | ConvertFrom-Json).Engine | Should -Be 'inno'
        }

        It 'always reports the installer hash, so a later run can key on it' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            (& $script:src -Path $p).Sha256 | Should -Match '^[0-9a-f]{64}$'
        }
    }

    Context 'house conventions' {
        It 'is ASCII-clean' {
            $bytes = [System.IO.File]::ReadAllBytes($script:src)
            $body = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF) { $bytes[3..($bytes.Length - 1)] } else { $bytes }
            @($body | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }

        It 'parses without errors' {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($script:src, [ref]$null, [ref]$errors) | Out-Null
            @($errors).Count | Should -Be 0
        }

        It 'never calls exit' {
            (Get-Content -LiteralPath $script:src -Raw) | Should -Not -Match '(?m)^\s*exit\s'
        }
    }
}

Describe 'the same-product fallback survives a padded product name (0.49.0)' {
    BeforeAll { $script:cand = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Get-PsadtSwitchCandidates.ps1') -Raw }

    # Five of the 24 entries in a real store are written with PE-header padding - 'WinSCP' followed by
    # fifty spaces, and the same for GIMP, Git, Greenshot and Visual Studio Code. The fallback compared
    # productName for exact equality, so those five could never match their own successor: the next
    # build would have to pad to an identical length. Trimming both sides costs nothing and recovers
    # them. The binary's productName stays the match key - Set-PsadtVerifiedSwitch.ps1 is explicit that
    # storing a friendly name instead would leave this fallback permanently dead.
    It 'trims both sides before comparing the product name' {
        $script:cand | Should -Match '\$_\.productName\)?\.Trim\(\)|Trim\(\)\s*-eq'
    }
    It 'still compares productName, not a friendly name from the manifest' {
        $script:cand | Should -Match 'productName'
        $script:cand | Should -Not -Match '\$engineInfo\.ProductName\s*-eq\s*\$m\.app\.name'
    }
}

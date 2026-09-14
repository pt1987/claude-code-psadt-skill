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
        It 'reports a miss with a reason when the store does not exist yet' {
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $r = & $script:src -Path $p
            $miss = @($r.Misses | Where-Object { $_.Stage -eq 0 })
            $miss.Count | Should -Be 1
            $miss[0].Reason | Should -Match 'no verified-switch store'
        }

        It 'resolves the store through the config home, never through LOCALAPPDATA directly' {
            # rule:config-home. Reading $env:LOCALAPPDATA here would ignore PSADT_DEPLOY_HOME and write
            # into the user's real profile during a test run.
            $script:code | Should -Not -Match '\$env:LOCALAPPDATA'
            $script:code | Should -Match 'Get-PsadtConfig\.ps1'
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

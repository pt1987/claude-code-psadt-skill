BeforeAll { . "$PSScriptRoot/_helpers.ps1" }
Describe 'Update-PsadtSkill' {
    BeforeEach {
        $script:root = New-TempSkillRoot   # no .git -> archive method (commit-sha based)
        # The script resolves the config home when the skill tree has no config.json - pin it to an empty
        # temp dir so the machine's real %LOCALAPPDATA%\psadt-deploy can never leak into these tests.
        $script:envBak  = $env:PSADT_DEPLOY_HOME
        $script:cfgHome = Join-Path ([IO.Path]::GetTempPath()) ("psadthome_" + [guid]::NewGuid().ToString('N'))
        New-Item $script:cfgHome -ItemType Directory -Force | Out-Null
        $env:PSADT_DEPLOY_HOME = $script:cfgHome
        Set-Content (Join-Path $script:root 'CHANGELOG.md') "# Changelog`n`n## 0.5.0 - x`n- local"
        $script:run = { param($extra) . (Join-Path $script:root 'scripts/Update-PsadtSkill.ps1') -SkillRoot $script:root @extra }
        # Remote latest commit (commits API) + remote changelog (contents API, base64).
        Mock -CommandName Invoke-RestMethod -ParameterFilter { $Uri -like '*/commits/*' } -MockWith { @{ sha = 'newsha123' } }
        Mock -CommandName Invoke-RestMethod -ParameterFilter { $Uri -like '*/contents/*' } -MockWith {
            @{ content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("# Changelog`n## 0.5.1 - y`n- newer")) }
        }
    }
    AfterEach {
        $env:PSADT_DEPLOY_HOME = $script:envBak
        Remove-Item $script:cfgHome -Recurse -Force -ErrorAction SilentlyContinue
        Remove-TempSkillRoot $script:root
    }

    It 'reports UpToDate when the recorded commit equals the latest remote commit' {
        @{ version = 1; tooling = @{ skillCommit = 'newsha123' } } | ConvertTo-Json | Set-Content (Join-Path $script:root 'config.json')
        $r = & $script:run @{}
        $r.RemoteCommit    | Should -Be 'newsha123'
        $r.UpdateAvailable | Should -BeFalse
        $r.Action          | Should -Be 'UpToDate'
    }

    It 'flags UpdateAvailable when the recorded commit differs (no apply without -Apply)' {
        @{ version = 1; tooling = @{ skillCommit = 'oldsha000' } } | ConvertTo-Json | Set-Content (Join-Path $script:root 'config.json')
        Mock -CommandName Invoke-WebRequest -MockWith { }
        $r = & $script:run @{}
        $r.UpdateAvailable | Should -BeTrue
        $r.Applied         | Should -BeFalse
        Should -Invoke Invoke-WebRequest -Times 0
    }

    It 'offers an update on first run when no commit is recorded yet' {
        $r = & $script:run @{}   # no config.json -> no skillCommit
        $r.UpdateAvailable | Should -BeTrue
    }

    It 'reports CheckFailed when GitHub is unreachable' {
        Mock -CommandName Invoke-RestMethod -ParameterFilter { $Uri -like '*/commits/*' } -MockWith { throw 'no network' }
        $r = & $script:run @{}
        $r.UpdateAvailable | Should -BeFalse
        $r.Action          | Should -Be 'CheckFailed'
        $r.Error           | Should -Match 'GitHub'
    }

    It 'applies via the archive method and records the applied commit' {
        @{ version = 1; tooling = @{ skillCommit = 'oldsha000' } } | ConvertTo-Json | Set-Content (Join-Path $script:root 'config.json')
        Mock -CommandName Invoke-WebRequest -MockWith { }
        Mock -CommandName Expand-Archive -MockWith {
            $ex = Join-Path ([IO.Path]::GetTempPath()) 'psadt-skill-extract\claude-code-psadt-skill-main'
            New-Item $ex -ItemType Directory -Force | Out-Null
            Set-Content (Join-Path $ex 'CHANGELOG.md') "# Changelog`n## 0.5.1 - y`n- newer"
        }
        $r = & $script:run @{ Apply = $true }
        $r.Method      | Should -Be 'archive'
        $r.Applied     | Should -BeTrue
        $r.LocalCommit | Should -Be 'newsha123'
        # the applied commit is recorded for the next sha-to-sha check
        (Get-Content (Join-Path $script:root 'config.json') -Raw | ConvertFrom-Json).tooling.skillCommit | Should -Be 'newsha123'
        (Get-Content (Join-Path $script:root 'CHANGELOG.md') -Raw) | Should -Match '0\.5\.1'
    }
}

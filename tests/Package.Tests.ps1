#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for the npm package (package.json + bin/install.mjs). These are drift guards in the style of the
    stale-ref sweeps: the version in package.json and the top CHANGELOG entry MUST agree, because a
    published installer claiming 0.23.0 while the skill is at 0.24.0 is a support case nobody can
    reproduce. And the installer must not grow a dependency tree or a second config-home implementation.
#>

BeforeAll {
    $script:root    = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:pkgPath = Join-Path $script:root 'package.json'
    $script:binPath = Join-Path $script:root 'bin\install.mjs'
    $script:pkg     = Get-Content $script:pkgPath -Raw | ConvertFrom-Json
    $script:bin     = Get-Content $script:binPath -Raw
}

Describe 'package.json' {
    It 'exists and parses as JSON' {
        Test-Path $script:pkgPath | Should -BeTrue
        $script:pkg | Should -Not -BeNullOrEmpty
    }
    It 'is the package name reserved for this installer' {
        $script:pkg.name | Should -Be 'psadt-deploy-skill'
    }
    It 'declares NO dependencies - an installer must not be able to break for an unrelated reason' {
        $script:pkg.PSObject.Properties.Name | Should -Not -Contain 'dependencies'
        $script:pkg.PSObject.Properties.Name | Should -Not -Contain 'peerDependencies'
    }
    It 'ships ONLY bin/ - the skill itself comes from GitHub at install time' {
        @($script:pkg.files) | Should -Be @('bin')
    }
    It 'points bin at a file that exists' {
        $binRel = $script:pkg.bin.'psadt-deploy-skill'
        $binRel | Should -Be 'bin/install.mjs'
        Test-Path (Join-Path $script:root $binRel) | Should -BeTrue
    }
    It 'requires Node 18+ (global fetch) and is ESM' {
        $script:pkg.engines.node | Should -Be '>=18'
        $script:pkg.type         | Should -Be 'module'
    }
    It 'is marked Windows-only, like the skill it installs' {
        @($script:pkg.os) | Should -Be @('win32')
    }
    It 'has the version of the TOP CHANGELOG entry' {
        # The drift guard. Bump both or neither.
        $changelog = Get-Content (Join-Path $script:root 'CHANGELOG.md')
        $top = $null
        foreach ($line in $changelog) {
            if ($line -match '^\s*##\s+(\d+\.\d+\.\d+)') { $top = $Matches[1]; break }
        }
        $top | Should -Not -BeNullOrEmpty
        $script:pkg.version | Should -Be $top
    }
}

Describe 'bin/install.mjs' {
    It 'exists and is 7-bit ASCII (it is read on machines with any code page)' {
        Test-Path $script:binPath | Should -BeTrue
        $bytes = [System.IO.File]::ReadAllBytes($script:binPath)
        ($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
    It 'imports only node: builtins' {
        $imports = [regex]::Matches($script:bin, "(?m)^import .*?from '([^']+)'") | ForEach-Object { $_.Groups[1].Value }
        @($imports).Count | Should -BeGreaterThan 0
        foreach ($i in $imports) { $i | Should -BeLike 'node:*' }
    }
    It 'defaults to the user skills folder and offers --dir / --project / --ref / --no-setup' {
        $script:bin | Should -Match "'\.claude', 'skills', SKILL_FOLDER"
        foreach ($flag in '--dir', '--project', '--ref', '--no-setup', '--help') {
            $script:bin | Should -BeLike "*$flag*"
        }
    }
    It 'has all three acquisition routes: pull, clone, tarball' {
        $script:bin | Should -Match "'pull', '--ff-only'"
        $script:bin | Should -Match "'clone', '--depth', '1'"
        $script:bin | Should -Match '--strip-components=1'
    }
    It 'defaults to the newest release tag rather than main' {
        # This skill registers an Entra app with admin consent and writes to a tenant. Installing
        # whatever last landed on main is not a defensible default for that, so the default is resolved
        # from the tag list; main stays reachable through --ref.
        $script:bin | Should -Match "/tags\?per_page="
        $script:bin | Should -Not -Match "flagValue\('--ref'\) \|\| 'main'"
    }
    It 'builds the tarball URL from a bare ref, so a TAG resolves' {
        # refs/heads/<ref> only ever resolves branches: every --ref v0.x.y returned HTTP 404 on the
        # tarball route while working on both git routes - and the tarball route is exactly the one a
        # managed machine without git lands on, which is exactly the machine that should be pinning.
        $script:bin | Should -Not -Match 'tar\.gz/refs/heads/'
        $script:bin | Should -Match 'codeload\.github\.com/\$\{REPO\}/tar\.gz/\$\{ref\}'
    }
    It 'never calls process.exit after a fetch has run' {
        # process.exit() with a pooled undici socket open aborts with a libuv assertion and exit code
        # 127 instead of the requested code, so a mistyped --ref looked like an installer crash and any
        # wrapper reading the exit code got the wrong number. Everything after the first fetch unwinds
        # out of main() instead.
        # Assert on the CODE, not the words: the file explains the choice in comments, so "process.exit"
        # legitimately appears in prose both inside and after main(). Strip line comments first.
        $body = $script:bin.Substring($script:bin.IndexOf('async function main()'))
        $code = ($body -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
        $code | Should -Not -Match 'process\.exit\('
        $script:bin | Should -Match 'class InstallFailure extends Error'
    }
    It 'does NOT reimplement the config home - it spawns the scripts that own it' {
        $script:bin | Should -Match 'Set-PsadtConfig\.ps1'
        $script:bin | Should -Match 'Initialize-PsadtSkill\.ps1'
        # Assert on the CODE, not the words: the file explains what it deliberately does not do, so the
        # env var and the config file name legitimately appear in comments. Reading them would not.
        $script:bin | Should -Not -Match 'process\.env\.PSADT_DEPLOY_HOME'
        $script:bin | Should -Not -Match 'process\.env\.LOCALAPPDATA'
        $script:bin | Should -Not -Match "join\([^)]*'config\.json'"
        $script:bin | Should -Not -Match 'writeFileSync\([^)]*config'
    }
    It 'runs PowerShell without a shell and bypasses the execution policy on BOTH hosts' {
        $script:bin | Should -Match 'shell: false'
        $script:bin | Should -Match "'-ExecutionPolicy', 'Bypass'"
        $script:bin | Should -Match "has\('pwsh'\) \? 'pwsh' : 'powershell'"
    }
    It 'uses -JsonPath, not -Json, because stdout is inherited' {
        # Assert on the INVOCATION. The file explains the choice in a comment, so "-Json" appears in prose.
        $script:bin | Should -Match '\-Fix \-JsonPath'
        $script:bin | Should -Not -Match "'-Json'"      # a bare -Json argv element
    }
    It 'swallows the doctor result object so it is not dumped under its own table' {
        # The doctor prints a table via Write-Host AND returns an object; with inherited stdout the object
        # would appear again underneath. Out-Null drops the object and leaves the table.
        $script:bin | Should -Match 'Out-Null'
    }
    It 'tells the user how to finish an incomplete setup' {
        $script:bin | Should -Match 'psadt setup'
    }
    It 'refuses to install on a non-Windows host' {
        $script:bin | Should -Match "process\.platform !== 'win32'"
    }
}

Describe 'Update-PsadtSkill tracks everything an installation needs' {
    BeforeAll {
        $script:upd = Get-Content (Join-Path $script:root 'scripts\Update-PsadtSkill.ps1') -Raw
    }

    It 'includes package.json and bin in $TrackedItems' {
        # Without this the archive update route silently drops them, and the next update on a git-less
        # machine leaves a skill whose installer is from an older version.
        $script:upd | Should -Match "\`$TrackedItems = @\([^)]*'package\.json'"
        $script:upd | Should -Match "\`$TrackedItems = @\([^)]*'bin'"
    }

    It 'includes every top-level repo file a user is meant to receive' {
        # $TrackedItems is an allow-list, so a new root-level document does not ship unless someone
        # remembers to add it - and the failure is invisible: git installs stay correct while the
        # tarball route quietly keeps the old tree. SECURITY.md is the case that motivated this test;
        # it exists so a customer security review has something to read, which it cannot do if the
        # file never reaches the machine.
        foreach ($item in 'SKILL.md', 'README.md', 'CHANGELOG.md', 'LICENSE', 'SECURITY.md') {
            $script:upd | Should -Match "\`$TrackedItems = @\([^)]*'$([regex]::Escape($item))'" -Because "$item is delivered to users"
        }
    }

    It 'includes every top-level directory a user is meant to receive' {
        foreach ($item in 'references', 'scripts', 'tests', 'bin', 'evals') {
            $script:upd | Should -Match "\`$TrackedItems = @\([^)]*'$([regex]::Escape($item))'" -Because "$item is delivered to users"
        }
    }
}

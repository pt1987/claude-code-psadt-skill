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

Describe 'Update-PsadtSkill tracks the packaging files' {
    It 'includes package.json and bin in $TrackedItems' {
        # Without this the archive update route silently drops them, and the next update on a git-less
        # machine leaves a skill whose installer is from an older version.
        $upd = Get-Content (Join-Path $script:root 'scripts\Update-PsadtSkill.ps1') -Raw
        $upd | Should -Match "\`$TrackedItems = @\([^)]*'package\.json'"
        $upd | Should -Match "\`$TrackedItems = @\([^)]*'bin'"
    }
}

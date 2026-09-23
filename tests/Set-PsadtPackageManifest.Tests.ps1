#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/Set-PsadtPackageManifest.ps1 - the per-package manifest writer. Same contract as
    Set-PsadtConfig (dotted paths, deep merge, -Remove), plus -Append for the results arrays: a second
    SYSTEM test must not erase the first one.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:Set = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Set-PsadtPackageManifest.ps1')).Path

    function New-TempPackage {
        $p = Join-Path ([IO.Path]::GetTempPath()) ("pkg_" + [guid]::NewGuid().ToString('N'))
        New-Item $p -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $p 'Invoke-AppDeployToolkit.ps1') '# launcher' -NoNewline
        return $p
    }
    function Get-Manifest([string]$PackagePath) {
        Get-Content (Join-Path $PackagePath 'psadt-package.json') -Raw | ConvertFrom-Json
    }
}

Describe 'Set-PsadtPackageManifest' {
    BeforeEach { $script:pkg = New-TempPackage }
    AfterEach  { Remove-Item $script:pkg -Recurse -Force -ErrorAction SilentlyContinue }

    It 'creates the manifest with schema 1 and nested values' {
        & $script:Set -PackagePath $script:pkg -Updates @{ 'app.name' = 'MxMC'; 'app.vendor' = 'Mobotix'; 'package.type' = 'installer' }
        $m = Get-Manifest $script:pkg
        $m.schema       | Should -Be 1
        $m.app.name     | Should -Be 'MxMC'
        $m.app.vendor   | Should -Be 'Mobotix'
        $m.package.type | Should -Be 'installer'
    }

    It 'deep-merges without dropping prior keys' {
        & $script:Set -PackagePath $script:pkg -Updates @{ 'app.name' = 'MxMC' }
        & $script:Set -PackagePath $script:pkg -Updates @{ 'app.version' = '2.9.1' }
        & $script:Set -PackagePath $script:pkg -Updates @{ 'results.preflight' = 'GREEN' }
        $m = Get-Manifest $script:pkg
        $m.app.name          | Should -Be 'MxMC'
        $m.app.version       | Should -Be '2.9.1'
        $m.results.preflight | Should -Be 'GREEN'
    }

    It 'writes a whole sub-tree in one go' {
        & $script:Set -PackagePath $script:pkg -Updates @{ 'decisions.gate2' = @{ audience = 'required'; reboot = 'never' } }
        $m = Get-Manifest $script:pkg
        $m.decisions.gate2.audience | Should -Be 'required'
        $m.decisions.gate2.reboot   | Should -Be 'never'
    }

    It 'appends to a results array instead of replacing it' {
        & $script:Set -PackagePath $script:pkg -Append @{ 'results.systemTest' = @{ type = 'Install'; verdict = 'GREEN' } }
        & $script:Set -PackagePath $script:pkg -Append @{ 'results.systemTest' = @{ type = 'Uninstall'; verdict = 'GREEN' } }
        $m = Get-Manifest $script:pkg
        @($m.results.systemTest).Count      | Should -Be 2
        @($m.results.systemTest)[0].type    | Should -Be 'Install'
        @($m.results.systemTest)[1].type    | Should -Be 'Uninstall'
    }

    It 'appends into a fresh array when the key does not exist yet' {
        & $script:Set -PackagePath $script:pkg -Append @{ 'artifacts.logs' = 'C:\Windows\Logs\Software\a.log' }
        @((Get-Manifest $script:pkg).artifacts.logs).Count | Should -Be 1
    }

    It 'removes a leaf and keeps its siblings' {
        & $script:Set -PackagePath $script:pkg -Updates @{ 'app.name' = 'MxMC'; 'app.arch' = 'x64' }
        & $script:Set -PackagePath $script:pkg -Remove @('app.arch', 'app.doesNotExist', 'nope.deeper.x')
        $m = Get-Manifest $script:pkg
        $m.app.name | Should -Be 'MxMC'
        $m.app.PSObject.Properties.Name | Should -Not -Contain 'arch'
        $m.PSObject.Properties.Name     | Should -Not -Contain 'nope'
    }

    It 'refuses to silently overwrite a malformed manifest' {
        Set-Content (Join-Path $script:pkg 'psadt-package.json') '{ not json' -NoNewline
        { & $script:Set -PackagePath $script:pkg -Updates @{ 'app.name' = 'X' } -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*malformed*'
    }

    It 'throws for a path that is not a PSADT package' {
        $empty = Join-Path ([IO.Path]::GetTempPath()) ("nopkg_" + [guid]::NewGuid().ToString('N'))
        New-Item $empty -ItemType Directory -Force | Out-Null
        try { { & $script:Set -PackagePath $empty -Updates @{ 'app.name' = 'X' } -ErrorAction Stop } | Should -Throw -ExpectedMessage '*Invoke-AppDeployToolkit.ps1*' }
        finally { Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the stores survive an interrupted write (0.46.0)' {
    # 2026-09-21 audit B14: all three JSON stores were read-modify-write with a plain Set-Content, no
    # temp+rename and no lock - while SKILL.md Phase 6 tells the agent to run Phase 7 in the SAME turn, so
    # the sandbox harness and the packaging step write this very file concurrently. A crash between
    # truncate and flush leaves a file that Get-PsadtConfig reports as "malformed" and every script then
    # treats as unconfigured.
    It 'writes each store through a temporary file and renames it into place' {
        $root = Split-Path $PSScriptRoot -Parent
        foreach ($s in 'Set-PsadtPackageManifest.ps1', 'Set-PsadtConfig.ps1', 'Set-PsadtVerifiedSwitch.ps1') {
            $text = Get-Content -LiteralPath (Join-Path $root "scripts/$s") -Raw
            $text | Should -Match 'Write-JsonAtomic' -Because "$s replaces a file the next phase reads"
        }
        $helper = Get-Content -LiteralPath (Join-Path $root 'scripts/_JsonStore.ps1') -Raw
        $helper | Should -Match 'Move-Item' -Because 'the rename is what makes the replacement atomic'
    }
}

Describe 'the manifest writer refuses a path it cannot write back (0.46.0)' {
    # Found on 2026-09-23 by the benchmark re-run: a caller built the dotted path from a property that did
    # not exist, so the key was 'research.answers.' with an EMPTY leaf. The writer accepted it and produced
    # {"answers": {"": "..."}} - valid to write, and ConvertFrom-Json then refuses the whole file, so the
    # manifest that is the single source of truth per app became unreadable to every later phase. The
    # pre-flight caught it as "malformed", which is the right place to fail but the wrong place to notice.
    BeforeEach {
        $script:mwDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item $script:mwDir -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:mwDir 'Invoke-AppDeployToolkit.ps1') -Value '# fixture' -Encoding UTF8
        $script:mwScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Set-PsadtPackageManifest.ps1'
    }

    It 'refuses an empty leaf segment' {
        { & $script:mwScript -PackagePath $script:mwDir -Updates @{ 'research.answers.' = 'x' } -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*empty*'
    }

    It 'refuses an empty segment in the middle' {
        { & $script:mwScript -PackagePath $script:mwDir -Updates @{ 'research..answers' = 'x' } -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*empty*'
    }

    It 'still writes a normal dotted path, and the result parses' {
        & $script:mwScript -PackagePath $script:mwDir -Updates @{ 'research.answers.intune-pitfalls' = 'ok' } | Out-Null
        $raw = Get-Content -LiteralPath (Join-Path $script:mwDir 'psadt-package.json') -Raw
        { $raw | ConvertFrom-Json } | Should -Not -Throw
        ($raw | ConvertFrom-Json).research.answers.'intune-pitfalls' | Should -Be 'ok'
    }
}

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

#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/Get-PsadtPackageManifest.ps1 - the per-package manifest reader. The manifest is the
    single source of truth for one app, so "does it exist and is the identity complete" has to be one
    answer every phase script can act on.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:Get = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Get-PsadtPackageManifest.ps1')).Path

    function New-TempPackage {
        $p = Join-Path ([IO.Path]::GetTempPath()) ("pkg_" + [guid]::NewGuid().ToString('N'))
        New-Item $p -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $p 'Invoke-AppDeployToolkit.ps1') '# launcher' -NoNewline
        return $p
    }
    function Set-Manifest([string]$PackagePath, [hashtable]$Manifest) {
        $Manifest | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $PackagePath 'psadt-package.json') -Encoding UTF8
    }
    function New-CompleteManifest {
        @{
            schema = 1
            app     = @{ vendor = 'Mobotix'; name = 'MxManagementCenter'; version = '2.9.1'; arch = 'x64'; lang = 'EN'; revision = 1 }
            package = @{ name = 'Mobotix_MxManagementCenter_2.9.1_x64'; type = 'installer'; installerTech = 'install4j'; sourceStrategy = 'bundle' }
        }
    }
}

Describe 'Get-PsadtPackageManifest' {
    BeforeEach { $script:pkg = New-TempPackage }
    AfterEach  { Remove-Item $script:pkg -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reports Exists=$false and the required keys when there is no manifest' {
        $r = & $script:Get -PackagePath $script:pkg
        $r.Exists   | Should -BeFalse
        $r.Manifest | Should -BeNullOrEmpty
        $r.Path     | Should -Be (Join-Path $script:pkg 'psadt-package.json')
        foreach ($k in 'app.vendor', 'app.name', 'app.version', 'app.arch', 'package.type') {
            $r.Missing | Should -Contain $k
        }
    }

    It 'reads a complete manifest and reports no gaps' {
        Set-Manifest $script:pkg (New-CompleteManifest)
        $r = & $script:Get -PackagePath $script:pkg
        $r.Exists                | Should -BeTrue
        $r.Missing               | Should -BeNullOrEmpty
        $r.Manifest.app.name     | Should -Be 'MxManagementCenter'
        $r.Manifest.package.type | Should -Be 'installer'
    }

    It 'derives the artifact stem from the identity' {
        Set-Manifest $script:pkg (New-CompleteManifest)
        (& $script:Get -PackagePath $script:pkg).Stem | Should -Be 'Mobotix_MxManagementCenter_2.9.1_x64'
    }

    It 'sanitizes the stem: spaces, non-ASCII and illegal characters never reach a file name' {
        $m = New-CompleteManifest
        $m.app.vendor  = 'Muenchener Rueck AG'
        $m.app.name    = 'Tool: Pro/Max'
        $m.app.version = '1.0 (beta)'
        Set-Manifest $script:pkg $m
        $stem = (& $script:Get -PackagePath $script:pkg).Stem
        $stem | Should -Be 'Muenchener_Rueck_AG_Tool_Pro_Max_1.0_beta_x64'
        $stem | Should -Not -Match '[^A-Za-z0-9._-]'
    }

    It 'names the gaps of a partial manifest instead of throwing' {
        Set-Manifest $script:pkg @{ schema = 1; app = @{ name = 'X' } }
        $r = & $script:Get -PackagePath $script:pkg
        $r.Exists  | Should -BeTrue
        $r.Missing | Should -Contain 'app.vendor'
        $r.Missing | Should -Not -Contain 'app.name'
        $r.Stem    | Should -BeNullOrEmpty       # no stem without a complete identity
    }

    It 'reports a malformed manifest instead of pretending it is absent' {
        Set-Content (Join-Path $script:pkg 'psadt-package.json') '{ not json' -NoNewline
        $r = & $script:Get -PackagePath $script:pkg
        $r.Exists | Should -BeTrue
        $r.Error  | Should -Not -BeNullOrEmpty
    }

    It 'throws for a path that is not a PSADT package' {
        $empty = Join-Path ([IO.Path]::GetTempPath()) ("nopkg_" + [guid]::NewGuid().ToString('N'))
        New-Item $empty -ItemType Directory -Force | Out-Null
        try { { & $script:Get -PackagePath $empty -ErrorAction Stop } | Should -Throw -ExpectedMessage '*Invoke-AppDeployToolkit.ps1*' }
        finally { Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

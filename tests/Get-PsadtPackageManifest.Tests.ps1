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

Describe 'the artifact stem keeps products apart (0.46.0)' {
    # 2026-09-21 audit B22 / benchmark FINDINGS #1: ConvertTo-NameToken stripped every character outside
    # [A-Za-z0-9._-], so Notepad++ became Notepad and C# became C. The stem is the folder name, the file
    # name and the win32LobApp fileName - two products sharing one stem overwrite each other's artefacts.
    BeforeAll {
        $script:mfScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Get-PsadtPackageManifest.ps1'
    }
    It 'spells out ++ and # instead of dropping them' {
        $a = & $script:mfScript -Identity @{ vendor = 'Notepad Team'; name = 'Notepad++'; version = '8.9.8'; arch = 'x64' }
        $b = & $script:mfScript -Identity @{ vendor = 'Notepad Team'; name = 'Notepad';   version = '8.9.8'; arch = 'x64' }
        $a.Stem | Should -Not -Be $b.Stem
        $a.Stem | Should -Match 'Plus'
        (& $script:mfScript -Identity @{ vendor = 'MS'; name = 'C#'; version = '1'; arch = 'x64' }).Stem | Should -Match 'Sharp'
    }
}

Describe 'ConvertTo-PsadtAppKey - the identity that survives a version bump (0.49.0)' {
    BeforeAll {
        # Dot-source the script's functions without running it: the app key has to be testable on its
        # own, because it is the join between a package built today and one built next year.
        . (Join-Path $PSScriptRoot '..\scripts\_AppKey.ps1')
    }

    It 'joins vendor and name, lowercased' {
        ConvertTo-PsadtAppKey -Vendor 'AOMEI' -Name 'Partition Assistant' | Should -Be 'aomei partition assistant'
    }

    It 'gives both Chrome package folders the same key' {
        # Measured on the real machine: C:\PSADT\Packages holds GoogleChrome and
        # GoogleChrome_154.0.8037.58 - two folders, one application. The folder name is not an identity.
        $a = ConvertTo-PsadtAppKey -Vendor 'Google LLC' -Name 'Google Chrome'
        $b = ConvertTo-PsadtAppKey -Vendor 'Google LLC' -Name 'Google Chrome'
        $a | Should -Be $b
        $a | Should -Be 'google llc google chrome'
    }

    It 'trims and collapses whitespace' {
        # Five entries in the real switch store are stored with PE-header padding - 'WinSCP        '.
        # An identity that does not normalise whitespace would never match its own successor.
        ConvertTo-PsadtAppKey -Vendor '  WinSCP   ' -Name '  Client  ' | Should -Be 'winscp client'
    }

    It 'is stable when the vendor is missing' {
        ConvertTo-PsadtAppKey -Vendor '' -Name '7-Zip' | Should -Be '7-zip'
        ConvertTo-PsadtAppKey -Vendor $null -Name '7-Zip' | Should -Be '7-zip'
    }

    It 'returns empty when there is no name to key on, rather than a key that matches everything' {
        ConvertTo-PsadtAppKey -Vendor 'Acme' -Name '' | Should -BeNullOrEmpty
        ConvertTo-PsadtAppKey -Vendor '' -Name '' | Should -BeNullOrEmpty
    }

    It 'ignores case differences between runs' {
        ConvertTo-PsadtAppKey -Vendor 'MOZILLA' -Name 'firefox' |
            Should -Be (ConvertTo-PsadtAppKey -Vendor 'Mozilla' -Name 'Firefox')
    }

    It 'does NOT strip a version from the name - that is the caller''s identity, not ours to guess' {
        # The store's productName carries versions ('LibreOffice 26.2.6.3') and that is exactly why the
        # key is built from app.vendor + app.name instead. Silently stripping digits here would merge
        # 'Office 2019' and 'Office 2021', which are genuinely different packages.
        ConvertTo-PsadtAppKey -Vendor 'The Document Foundation' -Name 'LibreOffice 26.2' |
            Should -Be 'the document foundation libreoffice 26.2'
    }

    It 'derives the key from a manifest object too' {
        $mf = [pscustomobject]@{ app = [pscustomobject]@{ vendor = 'AOMEI'; name = 'Partition Assistant' } }
        Get-PsadtAppKeyFromManifest -Manifest $mf | Should -Be 'aomei partition assistant'
    }

    It 'returns empty for a manifest with no identity, instead of throwing' {
        Get-PsadtAppKeyFromManifest -Manifest ([pscustomobject]@{}) | Should -BeNullOrEmpty
    }
}

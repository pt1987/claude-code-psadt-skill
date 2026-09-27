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

Describe 'the launcher command lines come from the manifest, parsed once (0.49.2)' {
    # Measured 2026-09-27: Gate 2 chose "close the app with a prompt", and the command line that went to
    # Intune was a hard-coded default in the upload and another in the dossier - '-DeployMode Silent',
    # which never shows a prompt. The generators now record package.installCommand / uninstallCommand,
    # and this reader is the one place that parses them. The manifest is DATA and the command runs as
    # SYSTEM on every device, so only the launcher's own shape is accepted.
    BeforeEach {
        $script:cp = New-TempPackage
        $script:cmdOf = { param($Install, $Uninstall)
            $m = New-CompleteManifest
            if ($Install) { $m.package.installCommand = $Install }
            if ($Uninstall) { $m.package.uninstallCommand = $Uninstall }
            Set-Manifest $script:cp $m
            (& $script:Get -PackagePath $script:cp).Commands }
    }
    AfterEach { Remove-Item $script:cp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'falls back to Silent, and says it did, when nothing is recorded' {
        $c = & $script:cmdOf $null $null
        $c.Install.Command    | Should -Be 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent'
        $c.Install.DeployMode | Should -Be 'Silent'
        $c.Install.Recorded   | Should -BeFalse
        $c.Install.Valid      | Should -BeTrue
        $c.Uninstall.Command  | Should -Be 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent'
    }

    It 'reads a recorded Auto command and its DeployMode' {
        $c = & $script:cmdOf 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Auto' 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode auto'
        $c.Install.DeployMode   | Should -Be 'Auto'
        $c.Install.Recorded     | Should -BeTrue
        $c.Uninstall.DeployMode | Should -Be 'Auto' -Because 'the mode is normalised to the launcher''s own spelling'
        $c.Uninstall.Command    | Should -Be 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Auto'
    }

    It 'refuses anything that is not the launcher''s own command line' {
        $c = & $script:cmdOf 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent & calc.exe' 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent'
        $c.Install.Valid        | Should -BeFalse -Because 'a second command must never ride along to every device'
        $c.Install.DeployMode   | Should -BeNullOrEmpty
        $c.Uninstall.Valid      | Should -BeFalse -Because 'an uninstall command that installs is not an uninstall command'
    }

    It 'refuses a DeployMode the launcher does not have' {
        (& $script:cmdOf 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Loud' $null).Install.Valid | Should -BeFalse
    }
}

Describe 'Resolve-PsadtDisplayName - one derivation of the Intune name (0.49.2)' {
    # The upload named an app "<vendor> <name>" while phases-7-12.md and the dossier said app.name, and
    # Get-IntuneAppVersions.ps1 copied the upload. Measured 2026-09-27: a real upload whose vendor name
    # already contained the app name came out with the name twice, and was renamed by hand. One helper,
    # one order.
    BeforeAll { . (Join-Path $PSScriptRoot '..\scripts\_AppKey.ps1') }

    It 'uses app.name, not vendor plus name' {
        $m = [pscustomobject]@{ app = [pscustomobject]@{ vendor = 'ACME'; name = 'Widget' } }
        $r = Resolve-PsadtDisplayName -Manifest $m
        $r.Name       | Should -Be 'Widget'
        $r.Source     | Should -Be 'app.name'
        $r.LegacyName | Should -Be 'ACME Widget' -Because 'what older uploads were named, for the tenant check'
    }

    It 'lets an explicit name win over everything' {
        $m = [pscustomobject]@{ app = [pscustomobject]@{ vendor = 'ACME'; name = 'Widget'; displayName = 'Widget Pro' } }
        (Resolve-PsadtDisplayName -Manifest $m -Explicit 'Chosen').Source | Should -Be 'explicit'
        (Resolve-PsadtDisplayName -Manifest $m -Explicit 'Chosen').Name   | Should -Be 'Chosen'
    }

    It 'prefers a recorded app.displayName over the name' {
        $m = [pscustomobject]@{ app = [pscustomobject]@{ vendor = 'ACME'; name = 'Widget'; displayName = 'Widget Pro' } }
        (Resolve-PsadtDisplayName -Manifest $m).Name | Should -Be 'Widget Pro'
    }

    It 'keeps the name this package was already uploaded under' {
        $m = [pscustomobject]@{ app = [pscustomobject]@{ vendor = 'ACME'; name = 'Widget' }
                                results = [pscustomobject]@{ upload = [pscustomobject]@{ displayName = 'ACME Widget' } } }
        $r = Resolve-PsadtDisplayName -Manifest $m -PriorUploadName 'Something Else'
        $r.Name   | Should -Be 'ACME Widget'
        $r.Source | Should -Be 'results.upload'
    }

    It 'takes the previous version''s uploaded name before falling back to app.name' {
        $m = [pscustomobject]@{ app = [pscustomobject]@{ vendor = 'ACME'; name = 'Widget' } }
        $r = Resolve-PsadtDisplayName -Manifest $m -PriorUploadName 'Widget (ACME)'
        $r.Name   | Should -Be 'Widget (ACME)'
        $r.Source | Should -Be 'predecessor'
    }

    It 'returns no name for a manifest without one, instead of inventing one' {
        (Resolve-PsadtDisplayName -Manifest ([pscustomobject]@{ app = [pscustomobject]@{ vendor = 'ACME' } })).Name | Should -BeNullOrEmpty
    }
}

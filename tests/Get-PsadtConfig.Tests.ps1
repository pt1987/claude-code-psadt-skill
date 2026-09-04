BeforeAll { . "$PSScriptRoot/_helpers.ps1" }
Describe 'Get-PsadtConfig' {
    BeforeEach {
        $script:root = New-TempSkillRoot
        $script:run  = { & (Join-Path $script:root 'scripts/Get-PsadtConfig.ps1') -SkillRoot $script:root }
    }
    AfterEach  { Remove-TempSkillRoot $script:root }

    It 'reports Exists=$false and all required fields missing when no config' {
        $r = & $script:run
        $r.Exists | Should -BeFalse
        $r.Missing | Should -Contain 'paths.packageRoot'
        $r.Missing | Should -Contain 'author.person'
    }

    It 'returns Exists=$true and empty Missing for a complete config' {
        @{
            version=1
            paths=@{ packageRoot='c:\p'; outputRoot='c:\o'; intuneWinAppUtil='c:\t\x.exe' }
            language=@{ script='EN'; dossier='DE' }
            author=@{ person='Pat'; company='PHAT' }
        } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:root 'config.json')
        $r = & $script:run
        $r.Exists | Should -BeTrue
        $r.Missing | Should -BeNullOrEmpty
    }

    It 'requires intune fields only when uploadEnabled is true' {
        @{
            version=1
            paths=@{ packageRoot='c:\p'; outputRoot='c:\o'; intuneWinAppUtil='c:\t\x.exe' }
            language=@{ script='EN'; dossier='DE' }
            author=@{ person='Pat'; company='PHAT' }
            intune=@{ uploadEnabled=$true; secretRef='secret.dpapi' }
        } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:root 'config.json')
        $r = & $script:run
        $r.Missing | Should -Contain 'intune.tenantId'
        $r.Missing | Should -Contain 'intune.secret'
    }

    Context 'config home resolution' {
        BeforeEach {
            $script:envBak = $env:PSADT_DEPLOY_HOME
            $script:cfgHome = Join-Path ([IO.Path]::GetTempPath()) ("psadthome_" + [guid]::NewGuid().ToString('N'))
            New-Item $script:cfgHome -ItemType Directory -Force | Out-Null
            $env:PSADT_DEPLOY_HOME = $script:cfgHome
            $script:get = Join-Path $script:root 'scripts/Get-PsadtConfig.ps1'
        }
        AfterEach {
            $env:PSADT_DEPLOY_HOME = $script:envBak
            Remove-Item $script:cfgHome -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'resolves to $env:PSADT_DEPLOY_HOME when -SkillRoot is not given' {
            $r = & $script:get
            $r.Home        | Should -Be $script:cfgHome
            $r.DefaultHome | Should -Be $script:cfgHome
            $r.Path        | Should -Be (Join-Path $script:cfgHome 'config.json')
            $r.LegacyInUse | Should -BeFalse
            $r.Exists      | Should -BeFalse
        }

        It 'an explicit -SkillRoot wins over the environment' {
            $r = & $script:get -SkillRoot $script:root
            $r.Home | Should -Be $script:root
            $r.Path | Should -Be (Join-Path $script:root 'config.json')
        }

        It 'falls back read-only to a legacy config beside scripts/ when the home has none' {
            @{ version=1; author=@{ person='Legacy' } } | ConvertTo-Json | Set-Content (Join-Path $script:root 'config.json')
            $r = & $script:get
            $r.LegacyInUse          | Should -BeTrue
            $r.Path                 | Should -Be (Join-Path $script:root 'config.json')
            $r.Home                 | Should -Be $script:root
            $r.DefaultHome          | Should -Be $script:cfgHome
            $r.Config.author.person | Should -Be 'Legacy'
        }

        It 'prefers the home config once it exists even if a legacy file remains' {
            @{ version=1; author=@{ person='Legacy' } } | ConvertTo-Json | Set-Content (Join-Path $script:root 'config.json')
            @{ version=1; author=@{ person='Home' } }   | ConvertTo-Json | Set-Content (Join-Path $script:cfgHome 'config.json')
            $r = & $script:get
            $r.LegacyInUse          | Should -BeFalse
            $r.Config.author.person | Should -Be 'Home'
        }
    }

    Context 'IntuneState' {
        BeforeEach {
            $script:writeCfg = {
                param($Intune)
                $cfg = @{
                    version  = 1
                    paths    = @{ packageRoot = 'c:\p'; outputRoot = 'c:\o'; intuneWinAppUtil = 'c:\t\x.exe' }
                    language = @{ script = 'EN'; dossier = 'DE' }
                    author   = @{ person = 'Pat'; company = 'PHAT' }
                }
                if ($Intune) { $cfg.intune = $Intune }
                $cfg | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:root 'config.json')
            }
            $script:credible = @{ tenantId = 't'; clientId = 'c'; secretRef = 'secret.dpapi'; uploadEnabled = $true }
        }

        It 'is NotConfigured without an intune block' {
            & $script:writeCfg $null
            (& $script:run).IntuneState | Should -Be 'NotConfigured'
        }

        It 'is NotConfigured while uploadEnabled is false' {
            & $script:writeCfg @{ tenantId = 't'; clientId = 'c'; uploadEnabled = $false }
            (& $script:run).IntuneState | Should -Be 'NotConfigured'
        }

        It 'is Configured when identity and credential are all present' {
            & $script:writeCfg $script:credible
            Set-Content (Join-Path $script:root 'secret.dpapi') 'blob' -NoNewline
            (& $script:run).IntuneState | Should -Be 'Configured'
        }

        It 'is Incomplete when upload is enabled but a key is missing' {
            & $script:writeCfg @{ clientId = 'c'; secretRef = 'secret.dpapi'; uploadEnabled = $true }
            Set-Content (Join-Path $script:root 'secret.dpapi') 'blob' -NoNewline
            (& $script:run).IntuneState | Should -Be 'Incomplete'
        }

        It 'is Incomplete when the credential file is gone' {
            & $script:writeCfg $script:credible
            (& $script:run).IntuneState | Should -Be 'Incomplete'
        }

        It 'stays Configured when only the group naming is missing - that is not an access gap' {
            $withGroups = $script:credible.Clone()
            $withGroups.groups = @{ enabled = $true }
            & $script:writeCfg $withGroups
            Set-Content (Join-Path $script:root 'secret.dpapi') 'blob' -NoNewline
            $r = & $script:run
            $r.Missing     | Should -Contain 'intune.groups.naming'
            $r.IntuneState | Should -Be 'Configured'
        }
    }
}

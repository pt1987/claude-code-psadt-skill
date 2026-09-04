BeforeAll { . "$PSScriptRoot/_helpers.ps1" }
Describe 'Set-PsadtConfig' {
    BeforeEach {
        $script:root = New-TempSkillRoot
        $script:set  = { param($h) & (Join-Path $script:root 'scripts/Set-PsadtConfig.ps1') -SkillRoot $script:root @h }
    }
    AfterEach { Remove-TempSkillRoot $script:root }

    It 'creates config.json with nested values' {
        & $script:set @{ Updates = @{ 'paths.packageRoot'='c:\p'; 'author.person'='Pat' } }
        $cfg = Get-Content (Join-Path $script:root 'config.json') -Raw | ConvertFrom-Json
        $cfg.paths.packageRoot | Should -Be 'c:\p'
        $cfg.author.person     | Should -Be 'Pat'
        $cfg.version           | Should -Be 1
    }

    It 'merges into an existing config without dropping prior keys' {
        & $script:set @{ Updates = @{ 'paths.packageRoot'='c:\p' } }
        & $script:set @{ Updates = @{ 'author.company'='PHAT' } }
        $cfg = Get-Content (Join-Path $script:root 'config.json') -Raw | ConvertFrom-Json
        $cfg.paths.packageRoot | Should -Be 'c:\p'
        $cfg.author.company    | Should -Be 'PHAT'
    }

    It 'DPAPI-encrypts the secret to secret.dpapi and never to config.json' {
        $sec = ConvertTo-SecureString 'p@ss-w0rd!' -AsPlainText -Force
        & $script:set @{ Secret = $sec }
        $blob = Get-Content (Join-Path $script:root 'secret.dpapi') -Raw
        $blob | Should -Not -BeNullOrEmpty
        $blob | Should -Not -Match 'p@ss-w0rd'
        (Get-Content (Join-Path $script:root 'config.json') -Raw) | Should -Not -Match 'p@ss-w0rd'
        $back = ConvertTo-SecureString $blob
        [System.Net.NetworkCredential]::new('', $back).Password | Should -Be 'p@ss-w0rd!'
    }

    It 'removes dotted keys with -Remove and keeps siblings; unknown keys are a no-op' {
        & $script:set @{ Updates = @{ 'intune.certThumbprint'='ABC'; 'intune.clientId'='cid' } }
        & $script:set @{ Remove = @('intune.certThumbprint', 'intune.doesNotExist', 'nope.deeper.x') }
        $cfg = Get-Content (Join-Path $script:root 'config.json') -Raw | ConvertFrom-Json
        $cfg.intune.PSObject.Properties.Name | Should -Not -Contain 'certThumbprint'
        $cfg.intune.clientId | Should -Be 'cid'
        $cfg.PSObject.Properties.Name | Should -Not -Contain 'nope'
    }

    Context 'config home' {
        BeforeEach {
            $script:envBak = $env:PSADT_DEPLOY_HOME
            $script:cfgHome = Join-Path ([IO.Path]::GetTempPath()) ("psadthome_" + [guid]::NewGuid().ToString('N'))
            $env:PSADT_DEPLOY_HOME = $script:cfgHome     # deliberately NOT created yet
            $script:setNoRoot = Join-Path $script:root 'scripts/Set-PsadtConfig.ps1'
        }
        AfterEach {
            $env:PSADT_DEPLOY_HOME = $script:envBak
            Remove-Item $script:cfgHome -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'writes into $env:PSADT_DEPLOY_HOME (creating it) when -SkillRoot is not given' {
            & $script:setNoRoot -Updates @{ 'author.person' = 'Pat' }
            (Test-Path (Join-Path $script:cfgHome 'config.json')) | Should -BeTrue
            (Test-Path (Join-Path $script:root 'config.json')) | Should -BeFalse
        }

        It 'stores the secret beside the resolved config' {
            & $script:setNoRoot -Secret (ConvertTo-SecureString 'x' -AsPlainText -Force)
            (Test-Path (Join-Path $script:cfgHome 'secret.dpapi')) | Should -BeTrue
        }

        It 'keeps writing to a legacy config beside scripts/ until it is migrated' {
            @{ version=1; author=@{ person='Legacy' } } | ConvertTo-Json | Set-Content (Join-Path $script:root 'config.json')
            & $script:setNoRoot -Updates @{ 'author.company' = 'PHAT' }
            $cfg = Get-Content (Join-Path $script:root 'config.json') -Raw | ConvertFrom-Json
            $cfg.author.company | Should -Be 'PHAT'
            (Test-Path (Join-Path $script:cfgHome 'config.json')) | Should -BeFalse
        }
    }
}

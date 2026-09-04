<#
.SYNOPSIS
    Tests for scripts/Initialize-PsadtSkill.ps1 (the setup doctor). Everything that would touch the machine
    is mocked - installed modules, PSGallery, the GitHub API and the IntuneWinAppUtil download - so the
    verdict is the same on any box. $env:PSADT_DEPLOY_HOME is pinned to an empty temp dir throughout, so
    the real config home can never leak in.
#>
BeforeAll {
    . "$PSScriptRoot/_helpers.ps1"
    # Load PowerShellGet up front: the Get-Module -ListAvailable mock below would otherwise break the
    # module auto-discovery that Mock needs to resolve Find-Module / Install-Module.
    Import-Module PowerShellGet -ErrorAction SilentlyContinue
}

Describe 'Initialize-PsadtSkill' {
    BeforeEach {
        $script:root    = New-TempSkillRoot
        $script:envBak  = $env:PSADT_DEPLOY_HOME
        $script:cfgHome = Join-Path ([IO.Path]::GetTempPath()) ("psadthome_" + [guid]::NewGuid().ToString('N'))
        New-Item $script:cfgHome -ItemType Directory -Force | Out-Null
        $env:PSADT_DEPLOY_HOME = $script:cfgHome
        $script:doctor = Join-Path $script:root 'scripts/Initialize-PsadtSkill.ps1'

        # Never reach PSGallery or GitHub.
        Mock -CommandName Find-Module      -MockWith { [pscustomobject]@{ Version = [version]'4.1.8' } }
        Mock -CommandName Install-Module   -MockWith { }
        Mock -CommandName Invoke-RestMethod -MockWith { @{ tag_name = 'v1.8.7' } }
        Mock -CommandName Invoke-WebRequest -MockWith {
            New-Item (Split-Path $OutFile -Parent) -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath $OutFile -Value 'MZ' -NoNewline
        }
        # Pretend every module is present at a known version. Registered LAST: this one shadows module
        # auto-discovery, so any command Mock still has to resolve must be mocked before it.
        Mock -CommandName Get-Module -ParameterFilter { $ListAvailable } -MockWith {
            switch ($Name) {
                'PSAppDeployToolkit' { [pscustomobject]@{ Name = $Name; Version = [version]'4.1.8' } }
                'Invoke-CommandAs'   { [pscustomobject]@{ Name = $Name; Version = [version]'3.1.7' } }
                'Pester'             { [pscustomobject]@{ Name = $Name; Version = [version]'5.7.1' } }
                default              { $null }
            }
        }
    }
    AfterEach {
        $env:PSADT_DEPLOY_HOME = $script:envBak
        Remove-Item $script:cfgHome -Recurse -Force -ErrorAction SilentlyContinue
        Remove-TempSkillRoot $script:root
    }

    It 'returns the documented shape' {
        $r = & $script:doctor -SkillRoot $script:root -SkipUpdateCheck

        foreach ($p in 'Overall', 'Checks', 'Missing', 'Home', 'ConfigPath', 'Migrated') {
            $r.PSObject.Properties.Name | Should -Contain $p
        }
        $r.Overall    | Should -BeIn 'GREEN', 'YELLOW', 'RED'
        $r.Home       | Should -Be $script:root
        $r.ConfigPath | Should -Be (Join-Path $script:root 'config.json')
        $r.Migrated   | Should -BeFalse

        $names = @($r.Checks | ForEach-Object Name)
        foreach ($c in 'PowerShell7', 'PsadtModule', 'IntuneWinAppUtil', 'Config', 'LegacyConfig', 'SkillUpdate', 'IntuneAccess') {
            $names | Should -Contain $c
        }
        foreach ($p in 'Name', 'Status', 'Detail', 'Fix') {
            $r.Checks[0].PSObject.Properties.Name | Should -Contain $p
        }
        @($r.Checks | Where-Object { $_.Status -notin 'PASS', 'WARN', 'FAIL', 'SKIP' }) | Should -BeNullOrEmpty
        ($r.Checks | Where-Object { $_.Name -eq 'SkillUpdate' }).Status | Should -Be 'SKIP'
    }

    It 'lists only the keys a human has to supply in .Missing' {
        $r = & $script:doctor -SkillRoot $script:root -SkipUpdateCheck

        $r.Missing | Should -HaveCount 4
        foreach ($k in 'paths.packageRoot', 'paths.outputRoot', 'author.person', 'author.company') {
            $r.Missing | Should -Contain $k
        }
        # These the doctor fills itself, so they are never handed back to the user.
        $r.Missing | Should -Not -Contain 'language.script'
        $r.Missing | Should -Not -Contain 'language.dossier'
        $r.Missing | Should -Not -Contain 'paths.intuneWinAppUtil'
        ($r.Checks | Where-Object { $_.Name -eq 'Config' }).Status | Should -Be 'FAIL'
    }

    It 'persists -Set values before judging the config' {
        $r = & $script:doctor -SkillRoot $script:root -SkipUpdateCheck -Set @{ 'paths.packageRoot' = 'c:\p'; 'author.person' = 'Pat' }

        $cfg = Get-Content (Join-Path $script:root 'config.json') -Raw | ConvertFrom-Json
        $cfg.paths.packageRoot | Should -Be 'c:\p'
        $cfg.author.person     | Should -Be 'Pat'
        $r.Missing | Should -Not -Contain 'paths.packageRoot'
        $r.Missing | Should -Contain 'author.company'
    }

    It 'fills the language defaults with -Fix instead of asking' {
        & $script:doctor -SkillRoot $script:root -SkipUpdateCheck -Fix | Out-Null

        $cfg = Get-Content (Join-Path $script:root 'config.json') -Raw | ConvertFrom-Json
        $cfg.language.script  | Should -Be 'EN'
        $cfg.language.dossier | Should -Be 'DE'
        $cfg.paths.intuneWinAppUtil | Should -Not -BeNullOrEmpty
    }

    It 'migrates a legacy config home with -Fix and keeps the old files as .migrated' {
        @{
            version = 1
            paths   = @{ packageRoot = 'c:\p'; outputRoot = 'c:\o'; intuneWinAppUtil = (Join-Path $script:root 'tools\IntuneWinAppUtil.exe') }
            author  = @{ person = 'Pat'; company = 'PHAT' }
        } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:root 'config.json')
        Set-Content (Join-Path $script:root 'tools/IntuneWinAppUtil.exe') 'MZ' -NoNewline
        Set-Content (Join-Path $script:root 'secret.dpapi') 'dpapi-blob' -NoNewline

        # No -SkillRoot: the resolver finds the legacy config beside scripts/ and the doctor migrates it.
        $r = & $script:doctor -SkipUpdateCheck -Fix

        $r.Migrated | Should -BeTrue
        $r.Home     | Should -Be $script:cfgHome
        (Test-Path (Join-Path $script:cfgHome 'config.json'))                | Should -BeTrue
        (Test-Path (Join-Path $script:cfgHome 'secret.dpapi'))               | Should -BeTrue
        (Test-Path (Join-Path $script:cfgHome 'tools/IntuneWinAppUtil.exe')) | Should -BeTrue
        # Nothing is deleted - the legacy files stay behind, renamed.
        (Test-Path (Join-Path $script:root 'config.json.migrated'))  | Should -BeTrue
        (Test-Path (Join-Path $script:root 'secret.dpapi.migrated')) | Should -BeTrue
        (Test-Path (Join-Path $script:root 'config.json'))           | Should -BeFalse

        $cfg = Get-Content (Join-Path $script:cfgHome 'config.json') -Raw | ConvertFrom-Json
        $cfg.paths.intuneWinAppUtil | Should -BeLike "$($script:cfgHome)*"
        $cfg.author.person          | Should -Be 'Pat'
        ($r.Checks | Where-Object { $_.Name -eq 'LegacyConfig' }).Status | Should -Be 'PASS'
    }

    It 'is idempotent: a second -Fix run migrates nothing' {
        @{ version = 1; author = @{ person = 'Pat' } } | ConvertTo-Json | Set-Content (Join-Path $script:root 'config.json')

        (& $script:doctor -SkipUpdateCheck -Fix).Migrated | Should -BeTrue
        (& $script:doctor -SkipUpdateCheck -Fix).Migrated | Should -BeFalse
    }

    It 'is RED while IntuneWinAppUtil is missing and no longer RED once it is there' {
        $tool = Join-Path $script:root 'tools/IntuneWinAppUtil.exe'
        @{
            version  = 1
            paths    = @{ packageRoot = 'c:\p'; outputRoot = 'c:\o'; intuneWinAppUtil = $tool }
            language = @{ script = 'EN'; dossier = 'DE' }
            author   = @{ person = 'Pat'; company = 'PHAT' }
        } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:root 'config.json')

        $r1 = & $script:doctor -SkillRoot $script:root -SkipUpdateCheck
        ($r1.Checks | Where-Object { $_.Name -eq 'IntuneWinAppUtil' }).Status | Should -Be 'FAIL'
        ($r1.Checks | Where-Object { $_.Name -eq 'Config' }).Status           | Should -Be 'PASS'
        $r1.Overall | Should -Be 'RED'

        Set-Content $tool 'MZ' -NoNewline
        $r2 = & $script:doctor -SkillRoot $script:root -SkipUpdateCheck
        ($r2.Checks | Where-Object { $_.Name -eq 'IntuneWinAppUtil' }).Status | Should -Be 'PASS'
        $r2.Overall | Should -Not -Be 'RED'
    }

    It 'writes the result to -JsonPath' {
        $out = Join-Path $script:cfgHome 'report/doctor.json'
        $r = & $script:doctor -SkillRoot $script:root -SkipUpdateCheck -JsonPath $out

        (Test-Path $out) | Should -BeTrue
        $fromDisk = Get-Content $out -Raw | ConvertFrom-Json
        $fromDisk.Overall | Should -Be $r.Overall
        $fromDisk.Checks.Count | Should -Be $r.Checks.Count
    }
}

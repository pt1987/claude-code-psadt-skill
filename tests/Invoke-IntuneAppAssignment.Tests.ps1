#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/Invoke-IntuneAppAssignment.ps1 - group-name resolution (the rules that bit us:
    no %intent% token, space-stripping) and the fail-fast when intune.groups is not configured.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:AssignScript = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Invoke-IntuneAppAssignment.ps1')).Path

    # Pull Resolve-GroupName out of the script and define it here (without running the script body).
    . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:AssignScript -Name 'Resolve-GroupName')))
}

Describe 'Resolve-GroupName' {
    BeforeAll {
        $script:AppName = 'Norton Neo'   # tokens read these from the enclosing scope
        $script:AppVendor = 'Norton'
        $script:AppArch = 'x64'
        $script:AppVersion = '148.0.3893.97'
    }

    It 'substitutes %appname% and strips spaces' {
        Resolve-GroupName 'intune-win-app-required-%appname%' | Should -Be 'intune-win-app-required-NortonNeo'
    }
    It 'supports %appvendor%, %apparch% and %version% tokens' {
        Resolve-GroupName 'App-%appvendor%-%apparch%-%version%' | Should -Be 'App-Norton-x64-148.0.3893.97'
    }
    It 'is case-insensitive and supports the {Token} alias' {
        Resolve-GroupName 'g-{AppName}-%APPARCH%' | Should -Be 'g-NortonNeo-x64'
    }
    It 'leaves an unknown %intent% placeholder untouched (there is NO intent token)' {
        # The intent is the naming-template KEY, never a token - a %intent% would survive verbatim.
        Resolve-GroupName 'app-%intent%-%appname%' | Should -Be 'app-%intent%-NortonNeo'
    }
    It 'produces a name with no whitespace even from spacey input' {
        (Resolve-GroupName '  pre %appname% post ') -match '\s' | Should -BeFalse
    }
}

Describe 'intune.groups not configured' {
    It 'throws a clear error when the resolved config has no intune.groups' {
        $tmp = New-TempSkillRoot
        try {
            # Minimal config WITHOUT intune.groups -> the script must fail fast before any Graph call.
            @{ version = 1; intune = @{ uploadEnabled = $false } } | ConvertTo-Json |
                Set-Content -Path (Join-Path $tmp 'config.json') -Encoding UTF8
            { & $script:AssignScript -AppId '00000000-0000-0000-0000-000000000000' -AppName 'X' -SkillRoot $tmp -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*not enabled*'
        }
        finally { Remove-TempSkillRoot $tmp }
    }
}

Describe 'Intents parameter binding' {
    # Regression guard for 2026-09-06: `pwsh script.ps1 -Intents required,available,uninstall` uses the
    # -File binder, which passes the whole string as ONE array element. With a [ValidateSet] on the
    # parameter that fails at BIND time with "the argument 'required,available,uninstall' does not belong
    # to the set" - an error naming a value the caller never typed and cannot fix without knowing why.
    BeforeAll {
        $raw = Get-Content -LiteralPath $script:AssignScript -Raw
        $tokens = $null
        [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$tokens, [ref]$null) | Out-Null
        $b = [System.Text.StringBuilder]::new($raw)
        foreach ($t in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
            $len = $t.Extent.EndOffset - $t.Extent.StartOffset
            [void]$b.Remove($t.Extent.StartOffset, $len); [void]$b.Insert($t.Extent.StartOffset, (' ' * $len))
        }
        $script:AssignCode = $b.ToString()
    }

    It 'does not put a ValidateSet on -Intents' {
        $script:AssignCode | Should -Not -Match '\[ValidateSet\([^)]*\)\]\[string\[\]\]\$Intents'
    }

    It 'splits a comma-separated value instead of treating it as one intent' {
        $script:AssignCode | Should -Match '\$Intents \| ForEach-Object \{ \$_ -split '','' \}'
    }

    It 'still rejects a genuinely unknown intent, by name' {
        $script:AssignCode | Should -Match 'Unknown intent'
        $script:AssignCode | Should -Match '\$validIntents -notcontains \$_'
    }

    It 'normalises case and surrounding spaces' {
        # "-Intents required, available" (with a space) was what the documentation used to show.
        $script:AssignCode | Should -Match '\.Trim\(\)\.ToLowerInvariant\(\)'
    }
}

Describe 'the assignment dry-runs unless -Execute (0.46.0)' {
    # 2026-09-21 audit B13, same gap as the upload: claimed in SECURITY.md, asserted nowhere.
    It 'names -Execute and reports what it would do' {
        $src = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Invoke-IntuneAppAssignment.ps1') -Raw
        $src | Should -Match '\[switch\]\$Execute'
        $src | Should -Match 'if \(-not \$Execute\)'
        $src | Should -Match 'Executed\s*='
    }
}

Describe 'the assignment takes its identity from the manifest and records what Intune holds (0.49.3)' {
    # Measured 2026-09-27: after a real three-group assignment the manifest recorded nothing, and the
    # dossier - which reads assignments only from -Metadata - still called the section a suggestion. Run
    # against a fake tenant (tests/_helpers.ps1), so what is recorded is what the tenant ends up holding.
    BeforeAll {
        function Invoke-Graph { param([string]$Method, [string]$Uri, $Body, [hashtable]$Headers, [int]$Depth = 20) }
        $script:appId = '11111111-2222-3333-4444-555555555555'
    }
    BeforeEach {
        $script:oldHome = $env:PSADT_DEPLOY_HOME
        $env:PSADT_DEPLOY_HOME = Join-Path $TestDrive ('ahome_' + [guid]::NewGuid().ToString('N'))
        New-Item $env:PSADT_DEPLOY_HOME -ItemType Directory -Force | Out-Null
        @{ version = 1; intune = @{ groups = @{ enabled = $true; create = $true; membershipType = 'assigned'; naming = @{
                        available = 'grp-available-%appname%'; required = 'grp-required-%appname%'; uninstall = 'grp-uninstall-%appname%' } } } } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $env:PSADT_DEPLOY_HOME 'config.json') -Encoding UTF8
        $global:PsadtFakeTenant = New-FakeIntuneTenant
        Add-FakeApp -Id $script:appId -Name 'Widget' -Version '2.0'
        $script:pkg = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item $script:pkg -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $script:pkg 'Invoke-AppDeployToolkit.ps1') '# launcher'
        $script:mf = Join-Path $script:pkg 'psadt-package.json'
        @{ schema = 1; app = @{ vendor = 'ACME'; name = 'Widget'; version = '2.0'; arch = 'x64' }; package = @{ type = 'installer' }
           results = @{ upload = @{ appId = $script:appId; displayName = 'Widget' } } } | ConvertTo-Json -Depth 6 | Set-Content $script:mf -Encoding UTF8
        Mock Invoke-Graph { Invoke-FakeGraph -Method $Method -Uri $Uri -Body $Body }
    }
    AfterEach { $env:PSADT_DEPLOY_HOME = $script:oldHome; Remove-Variable -Name PsadtFakeTenant -Scope Global -ErrorAction SilentlyContinue }

    It 'binds with -ManifestPath alone and takes the app id from results.upload' {
        $r = & $script:AssignScript -ManifestPath $script:mf -Intents available,required,uninstall -GraphToken 'opaque' 6>$null
        $r.AppId | Should -Be $script:appId
        @($r.Groups.Name) | Should -Contain 'grp-required-Widget'
        $r.Executed | Should -BeFalse
    }

    It 'records the assignments it read back from the tenant after -Execute' {
        & $script:AssignScript -ManifestPath $script:mf -Intents available,required,uninstall -GraphToken 'opaque' -Execute 6>$null | Out-Null
        $global:PsadtFakeTenant.Assignments[$script:appId].Count | Should -Be 3   # .Count, never @(): @() around a Generic.List throws "Argument types do not match"
        $m = Get-Content $script:mf -Raw | ConvertFrom-Json
        $m.results.assignment.verified | Should -Be 'read back from Intune'
        @($m.results.assignment.groups).Count | Should -Be 3
        @($m.results.assignment.groups | ForEach-Object { $_.Type }) | Should -Be @('Available', 'Required', 'Uninstall')
        @($m.results.assignment.groups | Where-Object Type -eq 'Required')[0].Group | Should -Be 'grp-required-Widget'
    }

    It 'records nothing on a dry run' {
        & $script:AssignScript -ManifestPath $script:mf -Intents available,required,uninstall -GraphToken 'opaque' 6>$null | Out-Null
        (Get-Content $script:mf -Raw | ConvertFrom-Json).results.assignment | Should -BeNullOrEmpty
        @($global:PsadtFakeTenant.Calls | Where-Object { $_ -match '^(POST|PATCH|DELETE)' }).Count | Should -Be 0
    }

    It 'refuses a manifest whose package was never uploaded' {
        @{ schema = 1; app = @{ vendor = 'ACME'; name = 'Widget'; version = '2.0'; arch = 'x64' }; package = @{ type = 'installer' } } |
            ConvertTo-Json -Depth 6 | Set-Content $script:mf -Encoding UTF8
        { & $script:AssignScript -ManifestPath $script:mf -Intents required -GraphToken 'opaque' -ErrorAction Stop 6>$null } |
            Should -Throw -ExpectedMessage '*results.upload.appId*'
    }
}

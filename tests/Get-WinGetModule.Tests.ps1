# 2026-09-21 audit (B01): the module that gets packed into the .intunewin and runs as SYSTEM on every
# assigned device was accepted on a 2-byte PK header, with Authenticode as a warning. Upstream ships it
# UNSIGNED (checked 2026-09-21: psm1, psd1 and both DLLs are NotSigned), so the signature can never be
# the gate - a SHA256 pin per release is. The upstream tag is '1.0.5', not 'v1.0.5'.
BeforeAll {
    . "$PSScriptRoot/_helpers.ps1"

    function New-FakeModuleZip {
        param([string]$Tag = '1.0.5')
        $ver      = $Tag -replace '^v', ''
        $fakeRoot = Join-Path $env:TEMP "PSADTfake-$([guid]::NewGuid().ToString('N'))"
        $fakeSrc  = Join-Path $fakeRoot 'PSAppDeployToolkit.WinGet'
        New-Item $fakeSrc -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $fakeSrc 'PSAppDeployToolkit.WinGet.psd1') "@{ ModuleVersion = '$ver' }"
        $zipPath = Join-Path $env:TEMP "PSADTWinGet-$Tag.zip"
        Compress-Archive -Path $fakeSrc -DestinationPath $zipPath -Force
        Remove-Item $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue
        return $zipPath
    }

    function New-ExistingModule {
        param([string]$Root, [string]$Tag = '1.0.5')
        $ver     = $Tag -replace '^v', ''
        $modPath = Join-Path $Root 'tools/PSAppDeployToolkit.WinGet'
        New-Item $modPath -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $modPath 'PSAppDeployToolkit.WinGet.psd1') "@{ ModuleVersion = '$ver' }"
        @{ version = 1; tooling = @{ winGetModuleVersion = $Tag } } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Root 'config.json')
    }

    function New-ReleaseMock([string]$Tag) {
        @{ tag_name = $Tag; assets = @(@{ name = 'PSAppDeployToolkit.WinGet.zip'; browser_download_url = 'https://example.com/fake.zip' }) }
    }
}

Describe 'Get-WinGetModule' {
    BeforeEach {
        $script:root = New-TempSkillRoot
        $script:run  = { param([hashtable]$extra = @{}) . (Join-Path $script:root 'scripts/Get-WinGetModule.ps1') -SkillRoot $script:root @extra }
    }
    AfterEach {
        Remove-TempSkillRoot $script:root
        Remove-Item "$env:TEMP\PSADTWinGet-*.zip"  -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\PSADTWinGet-extract" -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'downloads the module when missing and records version in config' {
        $zip = New-FakeModuleZip -Tag '1.0.5'  # pre-builds the zip the mock won't write
        Mock -CommandName Invoke-RestMethod -MockWith { New-ReleaseMock '1.0.5' }
        Mock -CommandName Invoke-WebRequest -MockWith { }  # zip already at $tmpZip path

        $r = & $script:run @{ ExpectedSha256 = (Get-FileHash $zip).Hash }

        Should -Invoke Invoke-WebRequest -Times 1
        $r.Action  | Should -Be 'Downloaded'
        $r.Version | Should -Be '1.0.5'
        (Test-Path (Join-Path $script:root 'tools/PSAppDeployToolkit.WinGet/PSAppDeployToolkit.WinGet.psd1')) | Should -BeTrue
        $cfg = Get-Content (Join-Path $script:root 'config.json') -Raw | ConvertFrom-Json
        $cfg.tooling.winGetModuleVersion | Should -Be '1.0.5'
    }

    It 'is a no-op when present and version matches config' {
        New-ExistingModule -Root $script:root -Tag '1.0.5'
        Mock -CommandName Invoke-RestMethod -MockWith { New-ReleaseMock '1.0.5' }
        Mock -CommandName Invoke-WebRequest -MockWith { }

        $r = & $script:run

        Should -Invoke Invoke-WebRequest -Times 0
        $r.Action | Should -Be 'AlreadyCurrent'
    }

    It 'copies the module into PackagePath and returns its path' {
        New-ExistingModule -Root $script:root -Tag '1.0.5'
        $pkgPath = Join-Path $env:TEMP "psadt-pkg-$([guid]::NewGuid().ToString('N'))"
        New-Item $pkgPath -ItemType Directory -Force | Out-Null
        Mock -CommandName Invoke-RestMethod -MockWith { New-ReleaseMock '1.0.5' }

        $r = & $script:run @{ PackagePath = $pkgPath }

        (Test-Path (Join-Path $pkgPath 'PSAppDeployToolkit.WinGet/PSAppDeployToolkit.WinGet.psd1')) | Should -BeTrue
        $r.Path | Should -Be (Join-Path $pkgPath 'PSAppDeployToolkit.WinGet')
        Remove-Item $pkgPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'falls back gracefully when GitHub is unreachable but module already exists' {
        New-ExistingModule -Root $script:root -Tag '1.0.5'
        Mock -CommandName Invoke-RestMethod -MockWith { throw 'no network' }
        Mock -CommandName Invoke-WebRequest -MockWith { }

        $r = & $script:run

        Should -Invoke Invoke-WebRequest -Times 0
        $r.Action | Should -Be 'AlreadyCurrent'
    }

    It 'falls back to the hardcoded URL when offline and module is missing - with the upstream tag format' {
        # The fallback tag was 'v1.0.5'; upstream tags are unprefixed, and that URL answered 404.
        $zip = New-FakeModuleZip -Tag '1.0.5'
        Mock -CommandName Invoke-RestMethod -MockWith { throw 'no network' }
        Mock -CommandName Invoke-WebRequest -MockWith { }

        $r = & $script:run @{ ExpectedSha256 = (Get-FileHash $zip).Hash }

        Should -Invoke Invoke-WebRequest -Times 1
        $r.Action  | Should -Be 'Downloaded'
        $r.Version | Should -Be '1.0.5'
    }

    It 'returns UpdateFailed when download fails and no module exists' {
        Mock -CommandName Invoke-RestMethod -MockWith { New-ReleaseMock '1.0.5' }
        Mock -CommandName Invoke-WebRequest -MockWith { throw 'download failed' }

        $r = & $script:run

        $r.Action | Should -Be 'UpdateFailed'
    }

    It 'returns an object with Action, Version, and Path properties' {
        New-ExistingModule -Root $script:root -Tag '1.0.5'
        Mock -CommandName Invoke-RestMethod -MockWith { New-ReleaseMock '1.0.5' }

        $r = & $script:run

        $r.PSObject.Properties.Name | Should -Contain 'Action'
        $r.PSObject.Properties.Name | Should -Contain 'Version'
        $r.PSObject.Properties.Name | Should -Contain 'Path'
    }

    Context 'integrity: the asset is pinned by SHA256 because upstream ships it unsigned' {
        It 'refuses a pinned release whose SHA256 does not match, and installs nothing' {
            $null = New-FakeModuleZip -Tag '1.0.5'   # a fake zip can never carry the real 1.0.5 hash
            Mock -CommandName Invoke-RestMethod -MockWith { New-ReleaseMock '1.0.5' }
            Mock -CommandName Invoke-WebRequest -MockWith { }

            $r = & $script:run

            $r.Action | Should -Be 'UpdateFailed'
            $r.Error  | Should -Match 'SHA256'
            (Test-Path (Join-Path $script:root 'tools/PSAppDeployToolkit.WinGet')) | Should -BeFalse
        }

        It 'refuses a release that is not pinned unless -AllowUnpinned is passed' {
            $null = New-FakeModuleZip -Tag '9.9.9'
            Mock -CommandName Invoke-RestMethod -MockWith { New-ReleaseMock '9.9.9' }
            Mock -CommandName Invoke-WebRequest -MockWith { }

            $r = & $script:run

            $r.Action | Should -Be 'UpdateFailed'
            $r.Error  | Should -Match 'not pinned'
        }

        It 'accepts an unpinned release with -AllowUnpinned' {
            $null = New-FakeModuleZip -Tag '9.9.9'
            Mock -CommandName Invoke-RestMethod -MockWith { New-ReleaseMock '9.9.9' }
            Mock -CommandName Invoke-WebRequest -MockWith { }

            $r = & $script:run @{ AllowUnpinned = $true }

            $r.Action | Should -Be 'Downloaded'
        }

        It 'accepts any release whose SHA256 matches -ExpectedSha256, case-insensitively' {
            $zip = New-FakeModuleZip -Tag '9.9.9'
            Mock -CommandName Invoke-RestMethod -MockWith { New-ReleaseMock '9.9.9' }
            Mock -CommandName Invoke-WebRequest -MockWith { }

            $r = & $script:run @{ ExpectedSha256 = (Get-FileHash $zip).Hash.ToLower() }

            $r.Action | Should -Be 'Downloaded'
        }

        It 'refuses when -ExpectedSha256 is given and does not match, even for a pinned tag' {
            $null = New-FakeModuleZip -Tag '1.0.5'
            Mock -CommandName Invoke-RestMethod -MockWith { New-ReleaseMock '1.0.5' }
            Mock -CommandName Invoke-WebRequest -MockWith { }

            $r = & $script:run @{ ExpectedSha256 = ('0' * 64) }

            $r.Action | Should -Be 'UpdateFailed'
            $r.Error  | Should -Match 'SHA256'
        }
    }
}

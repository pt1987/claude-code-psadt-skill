BeforeAll { . "$PSScriptRoot/_helpers.ps1" }
Describe 'Get-IntuneWinAppUtil' {
    BeforeEach {
        $script:root = New-TempSkillRoot
        $script:run  = { . (Join-Path $script:root 'scripts/Get-IntuneWinAppUtil.ps1') -SkillRoot $script:root }
        # Since 0.46.0 the script also checks WHO signed the download, because the binary is executed on
        # the packaging host. The fixture writes a two-byte "MZ" file, so the verdict is stated here.
        Mock -CommandName Get-AuthenticodeSignature -MockWith {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' } }
        }
    }
    AfterEach { Remove-TempSkillRoot $script:root }

    It 'downloads the exe when missing and records version' {
        Mock -CommandName Invoke-RestMethod -MockWith { @{ tag_name = 'v1.8.7' } }
        Mock -CommandName Invoke-WebRequest -MockWith { Set-Content (Join-Path $script:root 'tools/IntuneWinAppUtil.exe') 'MZ' }
        $r = & $script:run
        Should -Invoke Invoke-WebRequest -Times 1
        $r.Action  | Should -Be 'Downloaded'
        $r.Version | Should -Be 'v1.8.7'
        (Test-Path (Join-Path $script:root 'tools/IntuneWinAppUtil.exe')) | Should -BeTrue
    }

    It 'is a no-op when present and version matches config' {
        Set-Content (Join-Path $script:root 'tools/IntuneWinAppUtil.exe') 'MZ'
        @{ version=1; tooling=@{ intuneWinAppUtilVersion='v1.8.7' } } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:root 'config.json')
        Mock -CommandName Invoke-RestMethod -MockWith { @{ tag_name = 'v1.8.7' } }
        Mock -CommandName Invoke-WebRequest -MockWith { }
        $r = & $script:run
        Should -Invoke Invoke-WebRequest -Times 0
        $r.Action | Should -Be 'AlreadyCurrent'
    }

    It 'falls back to a known tag when the release API is unreachable (offline)' {
        Mock -CommandName Invoke-RestMethod -MockWith { throw 'no network' }
        Mock -CommandName Invoke-WebRequest -MockWith { Set-Content (Join-Path $script:root 'tools/IntuneWinAppUtil.exe') 'MZ' }
        $r = & $script:run
        $r.Action  | Should -Be 'Downloaded'
        $r.Version | Should -Be 'v1.8.7'
    }

    It 'returns UpdateFailed when the download fails and no exe exists' {
        Mock -CommandName Invoke-RestMethod -MockWith { @{ tag_name = 'v1.8.7' } }
        Mock -CommandName Invoke-WebRequest -MockWith { throw 'download failed' }
        $r = & $script:run
        $r.Action | Should -Be 'UpdateFailed'
    }

    It 'refuses a download that is not Microsoft-signed and keeps nothing' {
        # 2026-09-21 audit B15: an MZ header proves the file is a PE, not that it is the tool - and the
        # tool is then EXECUTED on the packaging host by Invoke-PsadtPackage.ps1.
        Mock -CommandName Invoke-RestMethod -MockWith { @{ tag_name = 'v1.8.7' } }
        Mock -CommandName Invoke-WebRequest -MockWith { Set-Content (Join-Path $script:root 'tools/IntuneWinAppUtil.exe') 'MZ' }
        Mock -CommandName Get-AuthenticodeSignature -MockWith {
            [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null }
        }
        $r = & $script:run
        $r.Action | Should -Be 'UpdateFailed'
        $r.Error  | Should -Match 'signature'
        (Test-Path (Join-Path $script:root 'tools/IntuneWinAppUtil.exe')) | Should -BeFalse
    }

    It 'refuses a valid signature from someone other than Microsoft' {
        Mock -CommandName Invoke-RestMethod -MockWith { @{ tag_name = 'v1.8.7' } }
        Mock -CommandName Invoke-WebRequest -MockWith { Set-Content (Join-Path $script:root 'tools/IntuneWinAppUtil.exe') 'MZ' }
        Mock -CommandName Get-AuthenticodeSignature -MockWith {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Contoso Ltd, O=Contoso Ltd' } }
        }
        $r = & $script:run
        $r.Action | Should -Be 'UpdateFailed'
        (Test-Path (Join-Path $script:root 'tools/IntuneWinAppUtil.exe')) | Should -BeFalse
    }
}

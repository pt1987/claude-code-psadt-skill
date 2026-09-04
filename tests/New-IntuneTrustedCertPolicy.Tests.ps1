#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/New-IntuneTrustedCertPolicy.ps1 - the OMA-URI builder, single-line base64 (the rule that
    bites: NO line breaks -> 0x87d1fde8), the Graph custom-profile body shape, signer-cert extraction, and the
    read-only dry run (no token / no Graph call).
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:CertScript = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\New-IntuneTrustedCertPolicy.ps1')).Path

    foreach ($fn in 'Get-CertStoreOmaUri', 'ConvertTo-CertBase64', 'New-CustomOmaProfileBody', 'Get-CertFromSource', 'Get-CertPolicyManualSteps') {
        . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:CertScript -Name $fn)))
    }

    # A throwaway code-signing cert exported to a .cer for the file-based tests.
    $script:testCert = New-SelfSignedCertificate -Subject 'CN=PSADT Test Cert' -Type CodeSigningCert -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddDays(1)
    $script:cerPath = Join-Path $TestDrive 'psadt-test.cer'
    Export-Certificate -Cert $script:testCert -FilePath $script:cerPath | Out-Null
}

AfterAll {
    if ($script:testCert) { Remove-Item "Cert:\CurrentUser\My\$($script:testCert.Thumbprint)" -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-CertStoreOmaUri' {
    It 'builds the RootCATrustedCertificates path for TrustedPublisher' {
        Get-CertStoreOmaUri -Store 'TrustedPublisher' -Thumbprint '60b9cd30986049b937762ae56a657e66b02e8be1' |
            Should -Be './Device/Vendor/MSFT/RootCATrustedCertificates/TrustedPublisher/60B9CD30986049B937762AE56A657E66B02E8BE1/EncodedCertificate'
    }
    It 'uppercases and strips non-hex (spaces) from the thumbprint' {
        Get-CertStoreOmaUri -Store 'Root' -Thumbprint '60 b9 cd 30' | Should -Match '/Root/60B9CD30/EncodedCertificate$'
    }
    It 'supports all four stores' {
        foreach ($s in 'Root', 'CA', 'TrustedPublisher', 'TrustedPeople') {
            Get-CertStoreOmaUri -Store $s -Thumbprint 'AABB' | Should -Match "/$s/AABB/"
        }
    }
}

Describe 'ConvertTo-CertBase64' {
    It 'returns single-line base64 (no whitespace/newlines) that round-trips to the DER bytes' {
        $b64 = ConvertTo-CertBase64 -Cert $script:testCert
        ($b64 -match '\s') | Should -BeFalse
        [System.Convert]::FromBase64String($b64) | Should -Be $script:testCert.RawData
    }
}

Describe 'New-CustomOmaProfileBody' {
    It 'produces a windows10CustomConfiguration with one omaSettingString carrying the value' {
        $body = New-CustomOmaProfileBody -DisplayName 'P' -Description 'D' -OmaUri './x' -Base64Value 'QUJD'
        $body.'@odata.type' | Should -Be '#microsoft.graph.windows10CustomConfiguration'
        $body.omaSettings.Count | Should -Be 1
        $body.omaSettings[0].'@odata.type' | Should -Be '#microsoft.graph.omaSettingString'
        $body.omaSettings[0].omaUri | Should -Be './x'
        $body.omaSettings[0].value  | Should -Be 'QUJD'
    }
}

Describe 'Get-CertFromSource' {
    It 'loads a raw .cer file' {
        (Get-CertFromSource -Path $script:cerPath).Thumbprint | Should -Be $script:testCert.Thumbprint
    }
    It 'throws on a missing path' {
        { Get-CertFromSource -Path (Join-Path $TestDrive 'nope.cer') } | Should -Throw
    }
}

Describe 'Get-CertPolicyManualSteps' {
    It 'includes the OMA-URI and points at the Custom template route' {
        $m = Get-CertPolicyManualSteps -ProfileName 'P' -OmaUri './abc' -Base64Length 100 -Subject 'CN=X'
        $m | Should -Match 'OMA-URI\s*=\s*\./abc'
        $m | Should -Match 'Custom'
    }
}

Describe 'Dry run (read-only, no Graph)' {
    It 'returns DryRun=true / Executed=false with the right OMA-URI and no profile id - without a token' {
        $r = & $script:CertScript -CertPath $script:cerPath -Store TrustedPublisher
        $r.DryRun | Should -BeTrue
        $r.Executed | Should -BeFalse
        $r.ProfileId | Should -BeNullOrEmpty
        $r.Thumbprint | Should -Be $script:testCert.Thumbprint
        $r.OmaUri | Should -Match '/TrustedPublisher/.+/EncodedCertificate$'
        $r.Base64Length | Should -BeGreaterThan 0
    }
}

Describe 'Assert-ConfigRole is embedded in BOTH policy scripts and must not drift' {
    It 'is byte-identical to the copy in New-IntuneFirewallPolicy.ps1' {
        # Both policy scripts carry their own copy on purpose (they must stay self-contained), which is
        # exactly the setup that let a retry-guard bug live in one copy only before _GraphCommon existed.
        $fw   = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\New-IntuneFirewallPolicy.ps1')).Path
        $here = Get-ScriptFunctionText -Path $script:CertScript -Name 'Assert-ConfigRole'
        $there = Get-ScriptFunctionText -Path $fw -Name 'Assert-ConfigRole'
        $here | Should -Be $there
    }
}

Describe 'New-IntuneTrustedCertPolicy is self-contained (0.22.0)' {
    BeforeAll { $script:certRaw = Get-Content -LiteralPath $script:CertScript -Raw }

    It 'dot-sources nothing - it runs on clients that have no skill installed' {
        $script:certRaw | Should -Not -Match '_GraphCommon'
        $script:certRaw | Should -Not -Match '_GraphInteractive'
        $script:certRaw | Should -Not -Match '(?m)^\s*\.\s+\(Join-Path'
    }
    It 'reads no skill config and calls no sibling script' {
        # A deliverable copied to a test client has no config.json and no sibling scripts. The comment
        # showing the -GraphToken call site is fine; an actual invocation is not.
        $script:certRaw | Should -Not -Match '&\s*\(Join-Path \$PSScriptRoot'
        $script:certRaw | Should -Not -Match 'Get-PsadtConfig'
    }
    It 'brings its own console helpers and WAM sign-in' {
        foreach ($fn in 'Write-Info', 'Write-Warn2', 'Write-Step', 'Write-Ok', 'Initialize-MsalBroker', 'Get-InteractiveGraphToken') {
            $script:certRaw | Should -Match "function $fn"
        }
    }
    It 'brings its own Graph error extraction instead of Get-GraphErr' {
        $script:certRaw | Should -Match 'function Get-GraphErrText'
        $script:certRaw | Should -Not -Match 'Invoke-Graph POST'
    }
    It 'takes the credential from outside: -Interactive or -GraphToken' {
        $script:certRaw | Should -Match '\[switch\]\$Interactive'
        $script:certRaw | Should -Match '\[string\]\$GraphToken'
        $script:certRaw | Should -Match 'this self-contained script reads no config'
    }
    It 'keeps its WAM sign-in signature identical to the firewall copy' {
        $fw = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\New-IntuneFirewallPolicy.ps1')).Path
        $here  = Get-ScriptFunctionText -Path $script:CertScript -Name 'Get-InteractiveGraphToken'
        $there = Get-ScriptFunctionText -Path $fw -Name 'Get-InteractiveGraphToken'
        $here | Should -Be $there
    }
    It 'is 7-bit ASCII only (encoding cleanliness)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:CertScript)
        ($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

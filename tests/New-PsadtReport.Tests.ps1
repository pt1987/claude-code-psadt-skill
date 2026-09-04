BeforeAll {
    $script:gen = Join-Path $PSScriptRoot '..\scripts\New-PsadtReport.ps1'
    $script:out = Join-Path ([System.IO.Path]::GetTempPath()) ("psadtreport_" + [guid]::NewGuid().ToString('N') + '.html')
}

Describe 'New-PsadtReport' {

    AfterEach {
        if (Test-Path $script:out) { Remove-Item $script:out -Force -ErrorAction SilentlyContinue }
    }

    It 'generates a complete report from minimal metadata with no leftover tokens' {
        & $script:gen -Metadata @{ AppName = 'Contoso Tool'; AppVersion = '1.2.3' } -OutputPath $script:out
        Test-Path $script:out | Should -BeTrue
        $html = Get-Content $script:out -Raw
        $html | Should -Match 'Contoso Tool'
        $html | Should -Match '1\.2\.3'
        $html | Should -Not -Match '\{\{[A-Z0-9_]+\}\}'   # every token filled
    }

    It 'embeds a fallback initials logo (base64 SVG) when no LogoPath is given' {
        & $script:gen -Metadata @{ AppName = 'Foo Bar' } -OutputPath $script:out
        $html = Get-Content $script:out -Raw
        $m = [regex]::Match($html, 'data:image/svg\+xml;base64,([A-Za-z0-9+/=]+)')
        $m.Success | Should -BeTrue
        $svg = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($m.Groups[1].Value))
        $svg | Should -Match '>FB<'   # initials of "Foo Bar"
    }

    It 'XML-escapes special characters in the fallback SVG initials (no markup injection)' {
        & $script:gen -Metadata @{ AppName = '<x Y' } -OutputPath $script:out   # initials -> '<' + 'Y'
        $html = Get-Content $script:out -Raw
        $m = [regex]::Match($html, 'data:image/svg\+xml;base64,([A-Za-z0-9+/=]+)')
        $m.Success | Should -BeTrue
        $svg = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($m.Groups[1].Value))
        $svg | Should -Match '&lt;Y'              # the '<' initial is XML-escaped...
        $svg | Should -Not -Match '>\<Y'          # ...never a raw '<' opening inside the text node
    }

    It 'embeds a real logo file as a base64 data URI' {
        $png = Join-Path ([System.IO.Path]::GetTempPath()) ("logo_" + [guid]::NewGuid().ToString('N') + '.png')
        [System.IO.File]::WriteAllBytes($png, [byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A))
        try {
            & $script:gen -Metadata @{ AppName = 'X' } -LogoPath $png -OutputPath $script:out
            $html = Get-Content $script:out -Raw
            $html | Should -Match 'data:image/png;base64,iVBORw0K'
        } finally { Remove-Item $png -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps the document bilingual (data-de + data-en + toggle)' {
        & $script:gen -Metadata @{ AppName = 'X' } -OutputPath $script:out
        $html = Get-Content $script:out -Raw
        $html | Should -Match 'data-de='
        $html | Should -Match 'data-en='
        $html | Should -Match "onclick=`"setLang\('en'\)`""
    }

    It 'sets the document language from -Metadata Lang' {
        & $script:gen -Metadata @{ AppName = 'X'; Lang = 'en' } -OutputPath $script:out
        (Get-Content $script:out -Raw) | Should -Match '<html lang="en">'
    }

    It 'escapes HTML-significant characters in free text (no injection)' {
        & $script:gen -Metadata @{ AppName = 'A <b> & "C"' } -OutputPath $script:out
        $html = Get-Content $script:out -Raw
        $html | Should -Match 'A &lt;b&gt; &amp; &quot;C&quot;'
    }

    It 'renders custom return codes' {
        & $script:gen -Metadata @{
            AppName     = 'X'
            ReturnCodes = @(
                @{ Code = '0';    Cls = 'b-ok';   Label = 'Success'; De = 'OK'; En = 'OK' }
                @{ Code = '9999'; Cls = 'b-fail'; Label = 'Failed';  De = 'Spezialfehler'; En = 'Special error' }
            )
        } -OutputPath $script:out
        $html = Get-Content $script:out -Raw
        $html | Should -Match '9999'
        $html | Should -Match 'Special error'
    }

    It 'renders bilingual deployment-hook bullets' {
        & $script:gen -Metadata @{
            AppName    = 'X'
            HookInstall = @( 'Start-ADTMsiProcess', @{ De = 'Deutsch-Eintrag'; En = 'English entry' } )
        } -OutputPath $script:out
        $html = Get-Content $script:out -Raw
        $html | Should -Match 'Deutsch-Eintrag'
        $html | Should -Match 'data-en="English entry"'
    }

    It 'preserves real umlauts from the description Markdown' {
        # the literal umlaut characters survive a UTF-8 round trip
        & $script:gen -Metadata @{ AppName = 'X'; DescMdDe = "Gr" + [char]0xF6 + [char]0xDF + "e" } -OutputPath $script:out
        $txt = [System.IO.File]::ReadAllText($script:out, [System.Text.Encoding]::UTF8)
        $txt | Should -Match ([char]0xF6)
    }

    It 'shows "none" for the driver certificate row by default' {
        & $script:gen -Metadata @{ AppName = 'X' } -OutputPath $script:out
        $html = Get-Content $script:out -Raw
        $html | Should -Match 'Driver certificate'
        $html | Should -Match 'no certificate required'
    }

    It 'renders the cert policy (store, owner, thumbprint, OMA-URI) when supplied' {
        & $script:gen -Metadata @{
            AppName    = 'X'
            CertPolicy = @{
                Store      = 'TrustedPublisher'
                Owner      = 'Policy'
                Thumbprint = '60B9CD30986049B937762AE56A657E66B02E8BE1'
                OmaUri     = './Device/Vendor/MSFT/RootCATrustedCertificates/TrustedPublisher/60B9CD30986049B937762AE56A657E66B02E8BE1/EncodedCertificate'
            }
        } -OutputPath $script:out
        $html = Get-Content $script:out -Raw
        $html | Should -Match 'TrustedPublisher'
        $html | Should -Match 'Intune policy'
        $html | Should -Match '60B9CD30986049B937762AE56A657E66B02E8BE1'
        $html | Should -Match 'RootCATrustedCertificates'
    }
}

Describe 'New-PsadtReport -ManifestPath (0.21.0)' {
    BeforeEach {
        $script:pkgDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item $script:pkgDir -ItemType Directory -Force | Out-Null
        $script:mfPath = Join-Path $script:pkgDir 'psadt-package.json'
        $script:outHtml = Join-Path $script:pkgDir 'Intune-Dossier.html'
        $script:writeMf = {
            param([hashtable]$M)
            $M | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:mfPath -Encoding UTF8
        }
        $script:fullIdentity = @{
            schema  = 1
            app     = @{ vendor = 'Mobotix'; name = 'MxManagementCenter'; version = '2.9.1'; arch = 'x64' }
            package = @{ type = 'installer' }
        }
    }

    It 'takes the identity from the manifest' {
        & $script:writeMf $script:fullIdentity
        & $script:gen -ManifestPath $script:mfPath -OutputPath $script:outHtml
        $html = Get-Content $script:outHtml -Raw
        $html | Should -Match 'MxManagementCenter'
        $html | Should -Match '2\.9\.1'
        $html | Should -Match 'Mobotix'
    }

    It 'still renders a package that was never packed or tested' {
        # "Report ALWAYS" has to hold before Phase 7 - the unknown parts render neutral, not as a failure.
        & $script:writeMf $script:fullIdentity
        { & $script:gen -ManifestPath $script:mfPath -OutputPath $script:outHtml } | Should -Not -Throw
        (Test-Path $script:outHtml) | Should -BeTrue
    }

    It 'refuses an incomplete identity instead of shipping a placeholder' {
        & $script:writeMf @{ schema = 1; app = @{ name = 'OnlyAName' }; package = @{ type = 'installer' } }
        { & $script:gen -ManifestPath $script:mfPath -OutputPath $script:outHtml -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*identity is incomplete*'
    }

    It 'lets -Metadata override the manifest' {
        & $script:writeMf $script:fullIdentity
        & $script:gen -ManifestPath $script:mfPath -Metadata @{ AppVersion = '3.0.0-rc1' } -OutputPath $script:outHtml
        (Get-Content $script:outHtml -Raw) | Should -Match '3\.0\.0-rc1'
    }

    It 'picks up the artifact names recorded by the packaging step' {
        $m = $script:fullIdentity.Clone()
        $m.artifacts = @{
            outputFolder = 'D:\Intune\Mobotix_MxManagementCenter_2.9.1_x64'
            intunewin    = 'D:\Intune\Mobotix_MxManagementCenter_2.9.1_x64\Mobotix_MxManagementCenter_2.9.1_x64.intunewin'
            detection    = 'D:\Intune\Mobotix_MxManagementCenter_2.9.1_x64\Detect-MxMC.ps1'
        }
        & $script:writeMf $m
        & $script:gen -ManifestPath $script:mfPath -OutputPath $script:outHtml
        $html = Get-Content $script:outHtml -Raw
        $html | Should -Match 'Mobotix_MxManagementCenter_2\.9\.1_x64\.intunewin'
        $html | Should -Match 'Detect-MxMC\.ps1'
    }

    It 'enforces the SYSTEM-test gate only when the package is meant to be uploaded' {
        $m = $script:fullIdentity.Clone()
        $m.decisions = @{ upload = $true }
        & $script:writeMf $m
        { & $script:gen -ManifestPath $script:mfPath -OutputPath $script:outHtml -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*SYSTEM-test result*'

        # Same manifest, upload not planned -> the dossier is produced without a SYSTEM test.
        $m.decisions = @{ upload = $false }
        & $script:writeMf $m
        { & $script:gen -ManifestPath $script:mfPath -OutputPath $script:outHtml } | Should -Not -Throw
    }

    It 'accepts the upload gate once SYSTEM-test results are supplied' {
        $m = $script:fullIdentity.Clone()
        $m.decisions = @{ upload = $true }
        & $script:writeMf $m
        $st = @(@{ StepDe = 'Install'; StepEn = 'Install'; Exit = '0'; Detection = 'installed'; Cls = 'b-ok'; Result = 'OK' })
        { & $script:gen -ManifestPath $script:mfPath -Metadata @{ SystemTest = $st } -OutputPath $script:outHtml } | Should -Not -Throw
    }

    It 'throws for a manifest path that does not exist' {
        { & $script:gen -ManifestPath (Join-Path $TestDrive 'nope.json') -OutputPath $script:outHtml -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*ManifestPath not found*'
    }
}

Describe 'New-PsadtReport: the driver-trust row (0.22.0)' {
    BeforeEach {
        $script:dpkg = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item $script:dpkg -ItemType Directory -Force | Out-Null
        $script:dmf  = Join-Path $script:dpkg 'psadt-package.json'
        $script:dout = Join-Path $script:dpkg 'Intune-Dossier.html'
        $script:baseMf = @{
            schema  = 1
            app     = @{ vendor = 'Mobotix'; name = 'Printer Driver'; version = '3.1.4'; arch = 'x64' }
            package = @{ type = 'driver' }
        }
    }

    It 'states "no drivers" for an ordinary package instead of leaving the cell empty' {
        $script:baseMf | ConvertTo-Json -Depth 12 | Set-Content $script:dmf -Encoding UTF8
        & $script:gen -ManifestPath $script:dmf -OutputPath $script:dout
        $html = Get-Content $script:dout -Raw
        $html | Should -Match 'no drivers'
        $html | Should -Not -Match '\{\{V_DRIVERS\}\}'
    }

    It 'renders the classification, the certificate owner and the per-INF rows' {
        $m = $script:baseMf.Clone()
        $m.driverTrust = @{
            classification = 'YELLOW'; owner = 'policy'; thumbprint = 'AABBCC'
            assumeSecureBootOff = $false
            drivers = @(@{ inf = 'mxdriver.inf'; classification = 'VendorSigned'; kernelMode = $false; provider = 'Mobotix AG'; version = '3.1.4.0' })
        }
        $m | ConvertTo-Json -Depth 12 | Set-Content $script:dmf -Encoding UTF8
        & $script:gen -ManifestPath $script:dmf -OutputPath $script:dout
        $html = Get-Content $script:dout -Raw
        $html | Should -Match 'vendor-signed'
        $html | Should -Match 'Intune policy'
        $html | Should -Match 'AABBCC'
        $html | Should -Match 'mxdriver\.inf'
        $html | Should -Match 'VendorSigned'
    }

    It 'says a Microsoft-signed package needs no certificate at all' {
        $m = $script:baseMf.Clone()
        $m.driverTrust = @{ classification = 'GREEN'; owner = 'none'; drivers = @(@{ inf = 'usb.inf'; classification = 'MicrosoftSigned'; kernelMode = $true }) }
        $m | ConvertTo-Json -Depth 12 | Set-Content $script:dmf -Encoding UTF8
        & $script:gen -ManifestPath $script:dmf -OutputPath $script:dout
        $html = Get-Content $script:dout -Raw
        $html | Should -Match 'Microsoft-signed'
        $html | Should -Match 'no certificate needed'
        $html | Should -Match 'kernel'
    }

    It 'documents an assumed-off Secure Boot as the fleet decision it is' {
        $m = $script:baseMf.Clone()
        $m.driverTrust = @{ classification = 'YELLOW'; owner = 'policy'; assumeSecureBootOff = $true; drivers = @() }
        $m | ConvertTo-Json -Depth 12 | Set-Content $script:dmf -Encoding UTF8
        & $script:gen -ManifestPath $script:dmf -OutputPath $script:dout
        (Get-Content $script:dout -Raw) | Should -Match 'Secure Boot assumed off'
    }
}

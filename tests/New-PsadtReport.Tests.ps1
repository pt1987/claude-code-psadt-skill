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

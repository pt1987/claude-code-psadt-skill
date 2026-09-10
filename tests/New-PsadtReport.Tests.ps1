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
        # A description is supplied too, because an upload has to clear BOTH gates since 0.27.1. This
        # test is about the SYSTEM-test gate; the description gate has its own tests further down.
        { & $script:gen -ManifestPath $script:mfPath -Metadata @{ SystemTest = $st; DescMdDe = '**Test**'; DescMdEn = '**Test**' } -OutputPath $script:outHtml } | Should -Not -Throw
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

Describe 'Return codes in the rendered dossier' {
    BeforeEach {
        $script:rcOut = Join-Path ([System.IO.Path]::GetTempPath()) ("psadtrc_" + [guid]::NewGuid().ToString('N') + '.html')
    }
    AfterEach { if (Test-Path $script:rcOut) { Remove-Item $script:rcOut -Force -ErrorAction SilentlyContinue } }

    It 'renders the mandatory table in Appendix F.4 order when none is supplied' {
        & $script:gen -Metadata @{ AppName = 'X'; AppVersion = '1' } -OutputPath $script:rcOut
        $tbody = [regex]::Match((Get-Content $script:rcOut -Raw), '(?s)id="returncodes".*?<tbody>(.*?)</tbody>').Groups[1].Value
        $codes = [regex]::Matches($tbody, '<code>(\d+)</code>') | ForEach-Object { [int]$_.Groups[1].Value }
        $codes | Should -Be @(0, 1707, 3010, 1641, 1618, 60001, 60008)
    }

    It 'refuses an invalid Intune return-code type and writes no file' {
        # The throw must precede the write: half a dossier on disk is worse than none, because it looks
        # finished. "Ignored" is the concrete value that reached a real dossier before 0.26.0.
        { & $script:gen -Metadata @{
                AppName = 'X'; AppVersion = '1'
                ReturnCodes = @(@{ Code = 5; Type = 'Ignored'; De = 'x'; En = 'x' })
            } -OutputPath $script:rcOut } | Should -Throw
        Test-Path $script:rcOut | Should -BeFalse
    }

    It 'cannot have a badge class injected through metadata' {
        & $script:gen -Metadata @{
            AppName = 'X'; AppVersion = '1'
            ReturnCodes = @(@{ Code = 3010; Type = 'softReboot'; Cls = '" onmouseover="alert(1)'; De = 'x'; En = 'x' })
        } -OutputPath $script:rcOut -WarningAction SilentlyContinue
        (Get-Content $script:rcOut -Raw) | Should -Not -Match 'onmouseover'
    }

    It 'keeps data-de off the return-code cell so an injected copy button survives setLang' {
        # setLang() assigns el.textContent to every [data-de] element, deleting its children. With the
        # attributes on the <td> the copy button would vanish on the first DE/EN toggle - a failure that
        # only shows on click. The bilingual span therefore lives INSIDE the cell.
        & $script:gen -Metadata @{ AppName = 'X'; AppVersion = '1' } -OutputPath $script:rcOut
        $tbody = [regex]::Match((Get-Content $script:rcOut -Raw), '(?s)id="returncodes".*?<tbody>(.*?)</tbody>').Groups[1].Value
        $tbody | Should -Match '<td><span data-de='
        $tbody | Should -Not -Match '<td data-de='
    }

    It 'merges custom codes over the mandatory table instead of replacing it' {
        & $script:gen -Metadata @{
            AppName = 'X'; AppVersion = '1'
            ReturnCodes = @(@{ Code = 1603; Type = 'failed'; De = 'MSI-Fehler'; En = 'MSI error' })
        } -OutputPath $script:rcOut
        $html = Get-Content $script:rcOut -Raw
        $html | Should -Match '1603'
        $html | Should -Match '60008'      # the mandatory rows are still there
    }

    It 'carries the Graph token as a row attribute rather than printing it' {
        # Printed next to the portal label it reads as a duplicated word ("Soft reboot softReboot"), but
        # "copy table" still needs the API spelling - so it is carried, not displayed.
        & $script:gen -Metadata @{ AppName = 'X'; AppVersion = '1' } -OutputPath $script:rcOut
        $html = Get-Content $script:rcOut -Raw
        $html | Should -Match '<tr data-rc-type="softReboot">'
        $html | Should -Not -Match 'rc-token'
    }
}


Describe 'The dossier never invents a fact about the package (0.27.1)' {
    # SCOPE NOTE: the failure this guards against shipped. A dossier generated without -Metadata
    # described a generic MSI package: the Company-Portal text read "_Beschreibung folgt._", the hook
    # lists claimed Start-ADTMsiProcess and "user data is preserved", and the cmdlet list named four
    # cmdlets nobody had checked. For a WinMerge package driven by Start-ADTProcess with Inno
    # switches, that was four printed occurrences of a cmdlet the package never calls.
    #
    # None of it was marked as a guess. The document exists so an approver can decide whether to
    # ship; a plausible invention there is worse than a blank, because a blank gets filled.

    BeforeEach {
        $script:pkg = Join-Path ([System.IO.Path]::GetTempPath()) ("psadtpkg_" + [guid]::NewGuid().ToString('N'))
        New-Item $script:pkg -ItemType Directory -Force | Out-Null
        $script:manifest = Join-Path $script:pkg 'psadt-package.json'
        @{
            schema = 1
            app = @{ vendor = 'ACME'; name = 'Widget'; version = '1.0'; arch = 'x64'; lang = 'EN'; revision = 1 }
            decisions = @{ upload = $false }
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:manifest -Encoding UTF8
    }

    AfterEach {
        if (Test-Path $script:pkg) { Remove-Item $script:pkg -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'the app description' {
        It 'never renders invented prose in place of a missing description' {
            & $script:gen -ManifestPath $script:manifest -OutputPath $script:out -WarningAction SilentlyContinue
            $html = Get-Content $script:out -Raw
            $html | Should -Not -Match 'Beschreibung folgt'
            $html | Should -Not -Match 'Description to follow'
        }

        It 'says plainly that no description was supplied' {
            & $script:gen -ManifestPath $script:manifest -OutputPath $script:out -WarningAction SilentlyContinue
            $html = Get-Content $script:out -Raw
            $html | Should -Match 'KEINE BESCHREIBUNG HINTERLEGT'
        }

        It 'warns when the description is missing' {
            $warnings = @()
            & $script:gen -ManifestPath $script:manifest -OutputPath $script:out -WarningVariable warnings -WarningAction SilentlyContinue
            ($warnings -join ' ') | Should -Match 'description'
        }

        It 'REFUSES outright when an upload is planned and writes no file' {
            # An earlier It in this Context wrote to the same path; the assertion below is about THIS
            # run producing nothing, so start from a known-absent file.
            if (Test-Path $script:out) { Remove-Item $script:out -Force }
            @{
                schema = 1
                app = @{ vendor = 'ACME'; name = 'Widget'; version = '1.0'; arch = 'x64'; lang = 'EN'; revision = 1 }
                decisions = @{ upload = $true }
            } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:manifest -Encoding UTF8
            { & $script:gen -ManifestPath $script:manifest -OutputPath $script:out -Metadata @{
                SystemTest = @(@{ StepDe = 'Install'; StepEn = 'Install'; Exit = '0'; Detection = 'ok'; Cls = 'b-ok'; Result = 'pass' })
            } } | Should -Throw -ExpectedMessage '*description*'
            Test-Path $script:out | Should -BeFalse
        }

        It 'accepts -AllowMissingDescription as a deliberate, visible choice' {
            { & $script:gen -ManifestPath $script:manifest -OutputPath $script:out -AllowMissingDescription } | Should -Not -Throw
            (Get-Content $script:out -Raw) | Should -Match 'KEINE BESCHREIBUNG HINTERLEGT'
        }
    }

    Context 'the hooks and the cmdlet list' {
        BeforeEach {
            # A launcher that calls Start-ADTProcess and NOT Start-ADTMsiProcess - the exact shape the
            # old defaults got wrong.
            @'
$adtSession = @{ AppName = 'Widget' }
function Install-ADTDeployment {
    Show-ADTInstallationWelcome -CloseProcesses 'widget'
    Start-ADTProcess -FilePath 'setup.exe' -ArgumentList '/VERYSILENT'
}
function Uninstall-ADTDeployment {
    Start-ADTProcess -FilePath 'unins000.exe' -ArgumentList '/VERYSILENT'
}
function Repair-ADTDeployment {
    Start-ADTProcess -FilePath 'setup.exe' -ArgumentList '/VERYSILENT'
}
'@ | Set-Content -LiteralPath (Join-Path $script:pkg 'Invoke-AppDeployToolkit.ps1') -Encoding UTF8
        }

        It 'reports the cmdlets the launcher actually calls, not a generic MSI list' {
            & $script:gen -ManifestPath $script:manifest -OutputPath $script:out -WarningAction SilentlyContinue
            $html = Get-Content $script:out -Raw
            $html | Should -Match 'Start-ADTProcess'
            $html | Should -Not -Match 'Start-ADTMsiProcess'
        }

        It 'does not assert uninstall behaviour nobody stated' {
            & $script:gen -ManifestPath $script:manifest -OutputPath $script:out -WarningAction SilentlyContinue
            $html = Get-Content $script:out -Raw
            $html | Should -Not -Match 'Nutzerdaten bleiben erhalten'
            $html | Should -Not -Match 'User data is preserved'
        }

        It 'says "not derivable" when there is no launcher to read' {
            Remove-Item (Join-Path $script:pkg 'Invoke-AppDeployToolkit.ps1') -Force
            & $script:gen -ManifestPath $script:manifest -OutputPath $script:out -WarningAction SilentlyContinue
            (Get-Content $script:out -Raw) | Should -Match 'nicht ermittelbar'
        }

        It 'still lets an explicit -Metadata value win' {
            & $script:gen -ManifestPath $script:manifest -OutputPath $script:out -WarningAction SilentlyContinue -Metadata @{
                Cmdlets = @('Get-ADTApplication')
            }
            (Get-Content $script:out -Raw) | Should -Match 'Get-ADTApplication'
        }
    }

    Context 'the header status' {
        It 'is derived from the evidence rather than claiming "tested" by default' {
            # The literal default used to say "Upload-bereit - getestet" while the same document said
            # "no SYSTEM-test results supplied (no evidence)" three sections lower. The template does
            # not currently render this token, which is why nobody saw it - a landmine, not a bug yet.
            $src = Get-Content (Join-Path $PSScriptRoot '..\scripts\New-PsadtReport.ps1') -Raw
            $src | Should -Not -Match "Get-Val 'StatusDe' 'Upload-bereit"
            $src | Should -Match '\$statusDefaultDe'
        }
    }
}

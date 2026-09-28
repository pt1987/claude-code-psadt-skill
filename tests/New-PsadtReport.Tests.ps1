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

    It 'states "no drivers, no certificate" in a single row by default (0.49.4)' {
        # Two rows ("driver certificate: none", "driver trust: no drivers") said one fact twice.
        & $script:gen -Metadata @{ AppName = 'X' } -OutputPath $script:out
        $html = Get-Content $script:out -Raw
        $html | Should -Not -Match 'Driver certificate'
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

    # 0.49.3: the dossier no longer ENFORCES the SYSTEM-test gate - it SHOWS it. It used to be the only
    # place that did, and SKILL.md has it rendered while the sandbox is still running, so it refused at
    # exactly the moment it is documented to run. The upload enforces the gate now (Get-PsadtPackageManifest
    # .TestGate, checked before any token), and the dossier states it, from the same derivation.
    It 'renders an upload package that is not tested yet, and says it is not ready to upload' {
        $m = $script:fullIdentity.Clone()
        $m.decisions = @{ upload = $true }
        & $script:writeMf $m
        { & $script:gen -ManifestPath $script:mfPath -Metadata @{ DescMdDe = '**T**'; DescMdEn = '**T**' } -OutputPath $script:outHtml -ErrorAction Stop } |
            Should -Not -Throw
        $html = Get-Content $script:outHtml -Raw
        $html | Should -Match 'Upload gesperrt'
        $html | Should -Match 'Invoke-PsadtSandboxTest\.ps1'
    }

    It 'marks a PARTIAL sandbox verdict as not ready, with the re-run command' {
        # Since Invoke-PsadtSandboxTest.ps1 once defaulted to the Install+Uninstall pair, a GREEN_PARTIAL
        # renders a plausible table while Reinstall, Repair and the final Uninstall never ran. Only a
        # full-gate GREEN may ship - the upload refuses the rest, and the dossier says why.
        $m = $script:fullIdentity.Clone()
        $m.decisions = @{ upload = $true }
        $m.results = @{ sandboxTest = @{ verdict = 'GREEN_PARTIAL'; scenarios = @('Install', 'Uninstall') } }
        & $script:writeMf $m
        $st = @(@{ StepDe = 'Install'; StepEn = 'Install'; Exit = '0'; Detection = 'installed'; Cls = 'b-ok'; Result = 'OK' })
        & $script:gen -ManifestPath $script:mfPath -Metadata @{ SystemTest = $st; DescMdDe = '**T**'; DescMdEn = '**T**' } -OutputPath $script:outHtml
        $html = Get-Content $script:outHtml -Raw
        $html | Should -Match 'Upload blocked'
        $html | Should -Match 'GREEN_PARTIAL'
        $html | Should -Match 'the full gate is the default'
    }

    It 'no longer calls a full-gate GREEN package not ready' {
        $m = $script:fullIdentity.Clone()
        $m.decisions = @{ upload = $true }
        $m.results = @{ sandboxTest = @{ verdict = 'GREEN'; scenarios = @('Install', 'Uninstall', 'Reinstall', 'Repair', 'FinalUninstall') } }
        & $script:writeMf $m
        $st = @(@{ StepDe = 'Install'; StepEn = 'Install'; Exit = '0'; Detection = 'installed'; Cls = 'b-ok'; Result = 'OK' })
        & $script:gen -ManifestPath $script:mfPath -Metadata @{ SystemTest = $st; DescMdDe = '**T**'; DescMdEn = '**T**' } -OutputPath $script:outHtml
        (Get-Content $script:outHtml -Raw) | Should -Not -Match 'Upload gesperrt'
    }

    It 'reads the DEV-VM route from what Invoke-PsadtSystemTest.ps1 recorded' {
        $m = $script:fullIdentity.Clone()
        $m.decisions = @{ upload = $true }
        $m.results = @{ systemTest = @(
                @{ type = 'Install'; success = $true; exitCode = 0 },
                @{ type = 'Uninstall'; success = $true; exitCode = 0 }) }
        & $script:writeMf $m
        $st = @(@{ StepDe = 'Install'; StepEn = 'Install'; Exit = '0'; Detection = 'installed'; Cls = 'b-ok'; Result = 'OK' })
        & $script:gen -ManifestPath $script:mfPath -Metadata @{ SystemTest = $st; DescMdDe = '**T**'; DescMdEn = '**T**' } -OutputPath $script:outHtml
        (Get-Content $script:outHtml -Raw) | Should -Not -Match 'Upload gesperrt'
    }

    It 'takes the gate from the one derivation the upload uses' {
        $src = Get-Content -LiteralPath $script:gen -Raw
        $src | Should -Match '\.TestGate'
        $src | Should -Not -Match 'throw "decisions\.upload is true but no SYSTEM-test'
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

Describe 'The dossier reads the sandbox verdict instead of asking for it (0.32.0)' {
    # SCOPE NOTE: this shipped wrong. Invoke-PsadtSandboxTest.ps1 measures every action, writes
    # result.json and records its path in the manifest - and the dossier ignored all of it. Without a
    # hand-built -Metadata SystemTest it printed "the SYSTEM test was not run (no evidence)" on a package
    # whose gate was GREEN, and the only remedy was to retype numbers the harness had already produced.
    # Measured on JetBrains PyCharm 2026.2.2, 2026-09-15.
    #
    # The rows must also be JUDGED, not just copied: an action that exits 0 while the detection rule
    # disagrees with it is a FAIL, because that combination is the signature of a per-user install
    # (App. L.7) and it is the one thing this table exists to surface.

    BeforeAll {
        # Defined here, not at Describe scope: Pester evaluates the Describe body during discovery, so a
        # function declared there does not exist when an It actually runs.
        function Set-SandboxResult {
            param([string]$Verdict, [array]$Steps, [array]$Failed = @())
            @{ verdict = $Verdict; failedAssertions = $Failed; steps = $Steps } |
                ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:res2 -Encoding UTF8
        }
    }

    BeforeEach {
        $script:pkg2 = Join-Path ([System.IO.Path]::GetTempPath()) ("psadtsbx_" + [guid]::NewGuid().ToString('N'))
        New-Item $script:pkg2 -ItemType Directory -Force | Out-Null
        $script:res2 = Join-Path $script:pkg2 'result.json'
        $script:mf2 = Join-Path $script:pkg2 'psadt-package.json'
        $script:out2 = Join-Path $script:pkg2 'Dossier.html'

        @{
            schema = 1
            app = @{ vendor = 'ACME'; name = 'Widget'; version = '1.0'; arch = 'x64'; lang = 'EN'; revision = 1 }
            decisions = @{ upload = $false }
            results = @{ sandboxTest = @{ verdict = 'GREEN'; resultPath = $script:res2 } }
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:mf2 -Encoding UTF8
    }

    AfterEach {
        if (Test-Path $script:pkg2) { Remove-Item $script:pkg2 -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'renders a row per deployment action, with its exit code and duration' {
        Set-SandboxResult -Verdict 'GREEN' -Steps @(
            @{ step = 'Install'; exitCode = 0; seconds = 185; success = $true }
            @{ step = 'DetectionAfterInstall'; detected = $true }
            @{ step = 'Uninstall'; exitCode = 0; seconds = 32; success = $true }
            @{ step = 'DetectionAfterUninstall'; detected = $false }
        )
        & $script:gen -ManifestPath $script:mf2 -OutputPath $script:out2 -WarningAction SilentlyContinue
        $html = Get-Content $script:out2 -Raw

        $html | Should -Not -Match 'SYSTEM test was not run'
        $html | Should -Match '185 s'
        $html | Should -Match '32 s'
        # One value per language (0.49.4): the German view printed "pass" under the heading "Ergebnis".
        ([regex]::Matches($html, 'data-de="bestanden" data-en="passed"')).Count | Should -Be 2
        $html | Should -Not -Match '>pass<'
    }

    It 'gives the detection column one value per language, not both languages in one cell (0.49.1)' {
        # The English view of a real 7-Zip dossier still read "erkannt / detected": the value was one
        # hard-coded bilingual string, so no language switch could reach it.
        Set-SandboxResult -Verdict 'GREEN' -Steps @(
            @{ step = 'Install'; exitCode = 0; seconds = 18; success = $true }
            @{ step = 'DetectionAfterInstall'; detected = $true }
            @{ step = 'Uninstall'; exitCode = 0; seconds = 18; success = $true }
            @{ step = 'DetectionAfterUninstall'; detected = $false }
        )
        & $script:gen -ManifestPath $script:mf2 -OutputPath $script:out2 -WarningAction SilentlyContinue
        $html = Get-Content $script:out2 -Raw

        $html | Should -Match 'data-de="erkannt" data-en="detected"'
        $html | Should -Match 'data-de="nicht erkannt" data-en="absent"'
        $html | Should -Not -Match 'erkannt / detected'
        $html | Should -Not -Match 'nicht erkannt / absent'
    }

    It 'labels the SYSTEM test with the phase the skill gives it (0.49.1)' {
        # The section said "Phase 5.5" - a number from an older phase plan. In SKILL.md the SYSTEM test is
        # Phase 6, and 5.5 is the leftover-v3-cmdlets step of the pre-flight.
        Set-SandboxResult -Verdict 'GREEN' -Steps @(
            @{ step = 'Install'; exitCode = 0; seconds = 18; success = $true }
            @{ step = 'DetectionAfterInstall'; detected = $true }
        )
        & $script:gen -ManifestPath $script:mf2 -OutputPath $script:out2 -WarningAction SilentlyContinue
        $html = Get-Content $script:out2 -Raw

        $html | Should -Not -Match 'Phase 5\.5'
        $html | Should -Match 'data-en="Phase 6 &middot; mandatory before upload"'
    }

    It 'gives the browser tab title an English form too (0.49.1)' {
        # The <title> was fixed to "Paket-Report" and carried no data-en, so the language switch - which
        # walks every [data-de] element - never reached it.
        Set-SandboxResult -Verdict 'GREEN' -Steps @(@{ step = 'Install'; exitCode = 0; seconds = 18; success = $true })
        & $script:gen -ManifestPath $script:mf2 -OutputPath $script:out2 -WarningAction SilentlyContinue
        $html = Get-Content $script:out2 -Raw

        $html | Should -Match '<title data-de="Paket-Report &middot; [^"]+" data-en="Package report &middot; [^"]+">'
    }

    It 'fails a row whose detection contradicts the action that succeeded' {
        # exit 0 plus "absent" right after an install is the per-user-install signature, not a pass.
        Set-SandboxResult -Verdict 'RED' -Steps @(
            @{ step = 'Install'; exitCode = 0; seconds = 14; success = $true }
            @{ step = 'DetectionAfterInstall'; detected = $false }
        ) -Failed @('detection after install')
        & $script:gen -ManifestPath $script:mf2 -OutputPath $script:out2 -WarningAction SilentlyContinue
        $html = Get-Content $script:out2 -Raw

        # 'b-fail' is the class the stylesheet defines; the row used to carry 'b-bad', which styles nothing
        # and which the header status - looking for 'b-fail' - never counted as a failure (0.49.4).
        $html | Should -Match 'class="badge b-fail" data-de="fehlgeschlagen" data-en="failed"'
        $html | Should -Not -Match 'b-bad'
        ([regex]::Matches($html, 'data-de="bestanden"')).Count | Should -Be 0
    }

    It 'lets a caller-supplied SystemTest win, for the DEV-VM route that has no result.json' {
        Set-SandboxResult -Verdict 'GREEN' -Steps @(
            @{ step = 'Install'; exitCode = 0; seconds = 185; success = $true }
            @{ step = 'DetectionAfterInstall'; detected = $true }
        )
        & $script:gen -ManifestPath $script:mf2 -OutputPath $script:out2 -WarningAction SilentlyContinue -Metadata @{
            SystemTest = @(@{ StepDe = 'Handgebaut'; StepEn = 'Hand built'; Exit = '1618'; Detection = '&ndash;'; Cls = 'b-neut'; Result = 'manual' })
        }
        $html = Get-Content $script:out2 -Raw

        $html | Should -Match 'Hand built'
        $html | Should -Match '1618'
        $html | Should -Not -Match '185 s'
    }

    It 'keeps the neutral default when the recorded result.json is gone' {
        # Unreadable evidence is not evidence. The honest state is "not run", never an invented pass.
        Remove-Item -LiteralPath $script:res2 -Force -ErrorAction SilentlyContinue
        & $script:gen -ManifestPath $script:mf2 -OutputPath $script:out2 -WarningAction SilentlyContinue
        $html = Get-Content $script:out2 -Raw

        $html | Should -Match 'SYSTEM test was not run'
        $html | Should -Not -Match 'data-de="bestanden"'
    }
}

Describe 'the re-run hint names parameters that exist' {
    # 2026-09-21 audit (B17): the refusal told the operator to re-run the gate with -FullGate, which
    # Invoke-PsadtSandboxTest.ps1 has never had. A message that cannot be obeyed is worse than none: it
    # sends someone to a binder error at the moment their upload is already blocked.
    It 'passes only real Invoke-PsadtSandboxTest parameters' {
        $src  = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/New-PsadtReport.ps1') -Raw
        $real = (Get-Command (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Invoke-PsadtSandboxTest.ps1')).Parameters.Keys
        foreach ($m in [regex]::Matches($src, 'Invoke-PsadtSandboxTest\.ps1[^
"]*')) {
            foreach ($p in [regex]::Matches($m.Value, '\s-([A-Za-z][A-Za-z0-9]*)')) {
                $real | Should -Contain $p.Groups[1].Value -Because "the hint tells an operator to run it with -$($p.Groups[1].Value)"
            }
        }
    }
}

Describe 'the dossier records itself in the manifest (0.46.0)' {
    # 2026-09-21 audit B09, re-measured live on 0.45.0: a full run produced Intune-Dossier.html on disk
    # while the manifest's artifacts.dossier and results.report stayed empty. The manifest is the single
    # source of truth per app, so a deliverable nothing records cannot be asserted by anything downstream -
    # which is why rule:dossier-always has never been enforceable.
    BeforeEach {
        $script:d09Dir  = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item $script:d09Dir -ItemType Directory -Force | Out-Null
        # A manifest only ever lives inside a real package folder, and Set-PsadtPackageManifest.ps1
        # refuses anything else - so the fixture has to look like one.
        Set-Content -LiteralPath (Join-Path $script:d09Dir 'Invoke-AppDeployToolkit.ps1') -Value '# fixture' -Encoding UTF8
        $script:d09Mf   = Join-Path $script:d09Dir 'psadt-package.json'
        $script:d09Html = Join-Path $script:d09Dir 'Intune-Dossier.html'
        @{ schema = 1
           app = @{ vendor = 'Mobotix'; name = 'MxManagementCenter'; version = '2.9.1'; arch = 'x64' }
           package = @{ type = 'installer' } } |
            ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:d09Mf -Encoding UTF8
    }

    It 'writes artifacts.dossier and results.report back' {
        $st = @(@{ StepDe = 'Install'; StepEn = 'Install'; Exit = '0'; Detection = 'installed'; Cls = 'b-ok'; Result = 'OK' })
        & $script:gen -ManifestPath $script:d09Mf -OutputPath $script:d09Html `
            -Metadata @{ SystemTest = $st; DescMdDe = '**T**'; DescMdEn = '**T**' } | Out-Null
        $after = Get-Content -LiteralPath $script:d09Mf -Raw | ConvertFrom-Json
        $after.artifacts.dossier      | Should -Be $script:d09Html
        $after.results.report.verdict | Should -Be 'OK'
        $after.results.report.at      | Should -Not -BeNullOrEmpty
    }

    It 'leaves the manifest alone when the caller asked for no manifest' {
        # -ManifestPath is optional; the explicit-metadata route has nothing to record into.
        $out2 = Join-Path $script:d09Dir 'explicit.html'
        { & $script:gen -OutputPath $out2 -Metadata @{ AppName = 'X'; AppVersion = '1'; Publisher = 'Y'; DescMdDe = 'd'; DescMdEn = 'e' } } |
            Should -Not -Throw
    }
}

Describe 'language.dossier decides the dossier language (0.46.0)' {
    # 2026-09-21 audit B23: the key was required by Get-PsadtConfig and defaulted by the doctor, and the
    # dossier - the one artefact named after it - never read it. 0.44.0 gave it a consumer in the upload;
    # this gives it the one SKILL.md actually promises.
    It 'falls back to the configured dossier language' {
        $src = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/New-PsadtReport.ps1') -Raw
        $src | Should -Match 'language\.dossier'
    }
}

Describe 'the dossier reports the supersedence that was actually wired (0.47.0)' {
    BeforeAll {
        $script:pkgDir = Join-Path ([System.IO.Path]::GetTempPath()) ('supsedmf_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:pkgDir -Force | Out-Null
        function New-SupManifest {
            param([string]$Mode)
            $mf = Join-Path $script:pkgDir 'psadt-package.json'
            @{
                schema  = 1
                app     = @{ vendor = 'Google LLC'; name = 'Google Chrome'; version = '153.0.8010.37'; arch = 'x64' }
                package = @{ type = 'installer' }
                results = @{ upload = @{ appId = 'aaaaaaaa-0000-0000-0000-00000000000a'
                        supersedes = 'bbbbbbbb-0000-0000-0000-00000000000b'; supersedenceType = $Mode } }
            } | ConvertTo-Json -Depth 8 | Set-Content $mf -Encoding UTF8
            return $mf
        }
    }
    AfterAll { if (Test-Path $script:pkgDir) { Remove-Item $script:pkgDir -Recurse -Force -ErrorAction SilentlyContinue } }
    AfterEach { if (Test-Path $script:out) { Remove-Item $script:out -Force -ErrorAction SilentlyContinue } }

    It 'names the superseded app instead of claiming this is the first version' {
        & $script:gen -ManifestPath (New-SupManifest 'update') -OutputPath $script:out -Metadata @{ DescMdDe = 'x'; DescMdEn = 'x' } *> $null
        $html = Get-Content $script:out -Raw
        $html | Should -Match 'bbbbbbbb-0000-0000-0000-00000000000b'
        $html | Should -Not -Match 'erste Version'
    }

    # The defect this catches: the template rendered the explanatory note ONLY when the field was empty,
    # so a populated supersedence printed a bare GUID and the note set beside it was dead code. A reader
    # could not tell whether the previous version gets uninstalled - which is the whole decision.
    It 'explains the update mode, which decides whether the old version is uninstalled' {
        & $script:gen -ManifestPath (New-SupManifest 'update') -OutputPath $script:out -Metadata @{ DescMdDe = 'x'; DescMdEn = 'x' } *> $null
        Get-Content $script:out -Raw | Should -Match 'aktualisiert die Vorversion selbst'
    }

    It 'explains the replace mode, and says the previous version is uninstalled' {
        & $script:gen -ManifestPath (New-SupManifest 'replace') -OutputPath $script:out -Metadata @{ DescMdDe = 'x'; DescMdEn = 'x' } *> $null
        Get-Content $script:out -Raw | Should -Match 'DEINSTALLIERT'
    }
}

Describe 'New-PsadtReport documents the command line the package recorded (0.49.2)' {
    # The dossier printed its own default ('-DeployMode Silent') while the package could ship Auto.
    BeforeEach {
        $script:pd3 = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item $script:pd3 -ItemType Directory -Force | Out-Null
        $script:mf3 = Join-Path $script:pd3 'psadt-package.json'
        $script:out3 = Join-Path $script:pd3 'Intune-Dossier.html'
        $script:m3 = @{ schema = 1; app = @{ vendor = 'ACME'; name = 'Widget'; version = '2.0'; arch = 'x64' }; package = @{ type = 'installer' } }
        Set-Content (Join-Path $script:pd3 'Invoke-AppDeployToolkit.ps1') '# launcher'
    }
    It 'shows the recorded install and uninstall command lines' {
        $script:m3.package.installCommand = 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode silent'
        $script:m3.package.uninstallCommand = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode silent'
        $script:m3 | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:mf3 -Encoding UTF8
        & $script:gen -ManifestPath $script:mf3 -OutputPath $script:out3
        $html = Get-Content $script:out3 -Raw
        # the recorded line, normalised by the parser - proof it came from the manifest, not the default
        $html | Should -Match 'Invoke-AppDeployToolkit\.exe -DeploymentType Install -DeployMode Silent'
        $html | Should -Match 'Invoke-AppDeployToolkit\.exe -DeploymentType Uninstall -DeployMode Silent'
    }
    It 'names a recorded -DeployMode Auto as refused instead of printing it (0.49.3)' {
        $script:m3.package.installCommand = 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Auto'
        $script:m3 | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:mf3 -Encoding UTF8
        $w = & $script:gen -ManifestPath $script:mf3 -OutputPath $script:out3 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        ($w -join ' ') | Should -Match 'Silent'
        (Get-Content $script:out3 -Raw) | Should -Not -Match 'DeployMode Auto'
    }
    It 'shows the Silent default when nothing is recorded' {
        $script:m3 | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:mf3 -Encoding UTF8
        & $script:gen -ManifestPath $script:mf3 -OutputPath $script:out3
        (Get-Content $script:out3 -Raw) | Should -Match 'Invoke-AppDeployToolkit\.exe -DeploymentType Install -DeployMode Silent'
    }
    It 'lets an explicit -Metadata InstallCmd win' {
        $script:m3.package.installCommand = 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent'
        $script:m3 | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:mf3 -Encoding UTF8
        & $script:gen -ManifestPath $script:mf3 -Metadata @{ InstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent /explicit' } -OutputPath $script:out3
        (Get-Content $script:out3 -Raw) | Should -Match 'DeployMode Silent /explicit'
    }
}

Describe 'the dossier and the upload describe the same app (0.49.3)' {
    # The class of defect, not one instance. Measured 2026-09-27: the dossier showed Developer = vendor, a
    # branded "PSADT v4.1.8 - pkg rev 01" note and "Windows 10 22H2"; the upload sent an empty developer,
    # empty notes and 1607. Each script was tested on its own and each test was green. This runs BOTH on
    # the same manifest - the upload up to its artifact step, before any token - and compares what the
    # approver reads with what Intune would get.
    BeforeAll {
        $script:up = Join-Path $PSScriptRoot '..\scripts\Invoke-IntuneWin32Upload.ps1'
        $script:pair = { param([hashtable]$App)
            $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item $d -ItemType Directory -Force | Out-Null
            Set-Content (Join-Path $d 'Invoke-AppDeployToolkit.ps1') '# launcher'
            $mf = Join-Path $d 'psadt-package.json'
            @{ schema = 1; app = $App; package = @{ type = 'installer' } } | ConvertTo-Json -Depth 6 | Set-Content $mf -Encoding UTF8
            $lines = New-Object System.Collections.Generic.List[string]
            try { & $script:up -ManifestPath $mf -IntuneWinPath 'C:\__nonexistent__\nope.intunewin' -ErrorAction Stop 6>&1 | ForEach-Object { $lines.Add([string]$_) } } catch { }
            $txt = $lines -join "`n"
            $out = Join-Path $d 'Intune-Dossier.html'
            & $script:gen -ManifestPath $mf -OutputPath $out -AllowMissingDescription 3>$null | Out-Null
            $html = Get-Content $out -Raw
            $cell = { param($label) [regex]::Match($html, "data-de=`"$label`"[^>]*>$label</td><td>(.*?)</td>").Groups[1].Value }
            [pscustomobject]@{
                UpDeveloper = [regex]::Match($txt, 'developer : ([^\r\n]*)').Groups[1].Value.Trim()
                UpNotes     = [regex]::Match($txt, 'notes     : ([^\r\n]*)').Groups[1].Value.Trim()
                UpMinOs     = [regex]::Match($txt, 'min OS    : ([^\r\n]*)').Groups[1].Value.Trim()
                # The German portal labels (0.49.4) - the English ones showed in the German view.
                DoDeveloper = & $cell 'Entwickler'
                DoNotes     = & $cell 'Notizen'
                DoMinOs     = & $cell 'Minimales Betriebssystem'
            }
        }
        $script:agree = { param($p)
            $p.UpDeveloper | Should -Not -BeNullOrEmpty -Because 'the upload names the developer it will send'
            $p.DoDeveloper | Should -BeExactly $p.UpDeveloper
            $p.DoMinOs | Should -BeExactly $p.UpMinOs
            if ($p.UpNotes -eq '(empty)') { $p.DoNotes | Should -Match 'nicht gesetzt' }
            else { $p.DoNotes | Should -BeExactly $p.UpNotes }
        }
    }
    BeforeEach {
        $script:oldHome = $env:PSADT_DEPLOY_HOME
        $env:PSADT_DEPLOY_HOME = Join-Path $TestDrive ('home_' + [guid]::NewGuid().ToString('N'))
        New-Item $env:PSADT_DEPLOY_HOME -ItemType Directory -Force | Out-Null
    }
    AfterEach { $env:PSADT_DEPLOY_HOME = $script:oldHome }

    It 'agrees on a manifest that records nothing beyond the identity' {
        $p = & $script:pair @{ vendor = 'ACME'; name = 'Widget'; version = '2.0'; arch = 'x64' }
        & $script:agree $p
        $p.UpDeveloper | Should -BeExactly 'ACME'
        $p.UpMinOs | Should -BeExactly 'Windows 10 1607'
        $p.UpNotes | Should -BeExactly '(empty)' -Because 'no branded note is imposed'
    }

    It 'agrees on recorded developer, notes and minimum release' {
        $p = & $script:pair @{ vendor = 'ACME'; name = 'Widget'; version = '2.0'; arch = 'x64'; developer = 'ACME Labs'; notes = 'Pilot only'; minWindowsRelease = '1809' }
        & $script:agree $p
        $p.UpMinOs | Should -BeExactly 'Windows 10 1809'
    }

    It 'agrees when the organisation opted into a default note' {
        @{ version = 1; intune = @{ notes = 'Desktop team' } } | ConvertTo-Json -Depth 4 |
            Set-Content (Join-Path $env:PSADT_DEPLOY_HOME 'config.json') -Encoding UTF8
        $p = & $script:pair @{ vendor = 'ACME'; name = 'Widget'; version = '2.0'; arch = 'x64' }
        & $script:agree $p
        $p.UpNotes | Should -BeExactly 'Desktop team'
    }
}

Describe 'the dossier shows what Intune holds, not a suggestion (0.49.3)' {
    BeforeEach {
        $script:pd = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item $script:pd -ItemType Directory -Force | Out-Null
        $script:pm = Join-Path $script:pd 'psadt-package.json'
        $script:po = Join-Path $script:pd 'Intune-Dossier.html'
        $script:base = @{ schema = 1; app = @{ vendor = 'ACME'; name = 'Widget'; version = '2.0'; arch = 'x64' }; package = @{ type = 'installer' } }
        $script:render = { param([hashtable]$Results)
            $m = $script:base.Clone(); if ($Results) { $m['results'] = $Results }
            $m | ConvertTo-Json -Depth 8 | Set-Content $script:pm -Encoding UTF8
            & $script:gen -ManifestPath $script:pm -OutputPath $script:po -AllowMissingDescription 3>$null | Out-Null
            Get-Content $script:po -Raw }
    }

    It 'renders the assignments Phase 10 recorded, and says they were read back' {
        $html = & $script:render @{ assignment = @{ at = '2026-09-27T14:00:00Z'; verified = 'read back from Intune'; groups = @(
                    @{ Group = 'grp-available-Widget'; Type = 'Available'; Availability = 'As soon as possible' },
                    @{ Group = 'grp-required-Widget'; Type = 'Required'; Availability = 'As soon as possible' }) } }
        $html | Should -Match 'grp-available-Widget'
        $html | Should -Match 'grp-required-Widget'
        # The date as the ISO day. ConvertFrom-Json turns an ISO timestamp into [datetime], and [string] of that
        # is culture-formatted - measured 2026-09-27: the tag read '09/27/2026'.
        $html | Should -Match 'aus Intune zur&uuml;ckgelesen 2026-09-27'
        $html | Should -Not -Match 'Vorschlag &middot; Anwender entscheidet'
    }

    It 'still calls it a suggestion while nothing is assigned' {
        (& $script:render $null) | Should -Match 'Vorschlag &middot; Anwender entscheidet'
    }

    It 'names the superseded version, not its bare id' {
        $html = & $script:render @{ supersedence = @{ supersedes = @('11111111-2222-3333-4444-555555555555'); supersedenceType = 'update'
                supersedesApps = @(@{ id = '11111111-2222-3333-4444-555555555555'; displayName = 'Widget'; displayVersion = '1.0' }) } }
        $html | Should -Match 'Widget 1\.0'
    }

    It 'says on a superseded version what superseded it' {
        $html = & $script:render @{ supersededBy = @{ appId = '99999999-2222-3333-4444-555555555555'; displayName = 'Widget'; displayVersion = '3.0'; supersedenceType = 'update'; at = '2026-09-27T14:00:00Z' } }
        $html | Should -Match 'Abgel&ouml;st durch Widget 3\.0'
        $html | Should -Match 'Superseded by Widget 3\.0'
        $html | Should -Match 'Modus update, 2026-09-27'
    }
}

Describe 'the dossier speaks one language at a time, and says only what it knows (0.49.4)' {
    # Measured 2026-09-28 on a real dossier (Windows App 2.0.1375.0), read the way setLang() renders it:
    # the German view showed "Success", "Soft reboot", "pass", "As soon as possible", "Determine behavior
    # based on return codes", "Publisher" and the tab names in English; the groups by GUID; a logo row that
    # repeated the logo section; an empty author and an empty disk-space cell; script version 0.1 for a 0.2
    # launcher; "not run" for a package whose DEV-VM test was recorded; PSADT template comments and a
    # "<Perform Post-Repair tasks here>" placeholder as if they described the package. Each test names the
    # defect it guards. The views are built the way the page builds them, so a string the language switch
    # cannot reach fails here and not in front of an approver.
    BeforeAll {
        function Get-DossierView {
            param([string]$Html, [string]$Lang)
            $b = [regex]::Match($Html, '(?s)<body[^>]*>(.*)</body>').Groups[1].Value
            $b = $b -replace '(?s)<script.*?</script>', '' -replace '(?s)<svg.*?</svg>', ''
            $other = if ($Lang -eq 'de') { 'en' } else { 'de' }
            # What setLang() does: every [data-de] element's text becomes data-<lang>; element children stay.
            $b = [regex]::Replace($b, '(?s)<(\w+)((?:\s[^>]*?)?)\sdata-de="([^"]*)"\s+data-en="([^"]*)"([^>]*)>(.*?)</\1>', {
                    param($m)
                    $kids = @([regex]::Matches($m.Groups[6].Value, '(?s)<(\w+)[^>]*>.*?</\1>') | ForEach-Object { $_.Value }) -join ''
                    $txt = if ($Lang -eq 'de') { $m.Groups[3].Value } else { $m.Groups[4].Value }
                    "<$($m.Groups[1].Value)>$txt$kids</$($m.Groups[1].Value)>"
                })
            $b = $b -replace "(?s)<(\w+)[^>]*class=`"[^`"]*only-$other[^`"]*`"[^>]*>.*?</\1>", ''
            $b = $b -replace '(?i)</?(tr|h1|h2|h3|h4|p|li|div|section|pre|header|footer|nav|ul|ol|table|summary|details)[^>]*>', "`n" -replace '(?i)</t[dh]>', ' | ' -replace '<[^>]+>', ''
            $b = [System.Net.WebUtility]::HtmlDecode($b)
            @($b -split "`n" | ForEach-Object { ($_ -replace '\s+', ' ').Trim(' ', '|') } | Where-Object { $_ })
        }
        function Get-Section {
            param([string]$Html, [string]$Id)
            [regex]::Match($Html, "(?s)<section[^>]*id=`"$Id`".*?</section>").Value
        }

        $script:oldHomeL = $env:PSADT_DEPLOY_HOME
        $env:PSADT_DEPLOY_HOME = Join-Path $TestDrive 'lang_home'
        New-Item $env:PSADT_DEPLOY_HOME -ItemType Directory -Force | Out-Null
        @{ version = 1; language = @{ dossier = 'DE'; script = 'EN' }; author = @{ person = 'Pat Example'; company = 'Example GmbH' } } |
            ConvertTo-Json -Depth 4 | Set-Content (Join-Path $env:PSADT_DEPLOY_HOME 'config.json') -Encoding UTF8

        $script:lpkg = Join-Path $TestDrive 'lang_pkg'
        New-Item (Join-Path $script:lpkg 'PSAppDeployToolkit.Extensions') -ItemType Directory -Force | Out-Null
        $script:launcherText = @'
$adtSession = @{
    AppVendor = 'ACME'
    AppName = 'Widget'
    AppVersion = '2.0'
    AppRevision = '03'
    AppScriptVersion = '0.7'
    AppScriptAuthor = 'Jane Doe, ACME Ltd'
}
function Install-ADTDeployment {
    ## Show Progress Message (with the default message).
    Show-ADTInstallationProgress
    ## Remove the legacy client first, so the two never run side by side.
    Uninstall-ADTApplication -Name 'Legacy'
    Install-WidgetThing -Path 'x'
}
function Uninstall-ADTDeployment {
    ## <Perform Uninstallation tasks here>
    Uninstall-WidgetThing
}
function Repair-ADTDeployment {
    Install-WidgetThing -Path 'x'
    ## <Perform Post-Repair tasks here>
}
'@
        Set-Content (Join-Path $script:lpkg 'Invoke-AppDeployToolkit.ps1') $script:launcherText -Encoding UTF8
        Set-Content (Join-Path $script:lpkg 'PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1') "function Install-WidgetThing { param(`$Path) }`nfunction Uninstall-WidgetThing { }" -Encoding UTF8
        # A real PNG header: 600 x 600, 8 bit, colour type 6 (RGBA).
        $script:llogo = Join-Path $script:lpkg 'Widget.png'
        [System.IO.File]::WriteAllBytes($script:llogo, [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
                0, 0, 2, 0x58, 0, 0, 2, 0x58, 8, 6, 0, 0, 0, 0, 0, 0, 0))
        $script:lmf = Join-Path $script:lpkg 'psadt-package.json'
        $script:lout = Join-Path $script:lpkg 'Intune-Dossier.html'
        $script:lManifest = @{
            schema    = 1
            app       = @{ vendor = 'ACME'; name = 'Widget'; version = '2.0'; arch = 'x64'
                description = @{ de = '**Widget** ist ein Werkzeug.'; en = '**Widget** is a tool.' } }
            package   = @{ type = 'installer' }
            decisions = @{ upload = $true }
            artifacts = @{ intunewin = 'C:\out\Widget.intunewin'; detection = 'C:\out\Detect-Widget.ps1'; outputFolder = 'C:\out' }
            results   = @{
                preflight  = @{ verdict = 'GREEN'; at = '2026-09-28T07:00:00Z'; checks = @(
                        @{ Name = 'Encoding'; Status = 'PASS'; Detail = 'ASCII-clean'; File = 'Invoke-AppDeployToolkit.ps1' },
                        @{ Name = 'Parse'; Status = 'PASS'; Detail = 'PARSE_OK'; File = 'Invoke-AppDeployToolkit.ps1' },
                        @{ Name = 'LogName'; Status = 'PASS'; Detail = 'launcher sets a per-run log name'; File = 'Invoke-AppDeployToolkit.ps1' },
                        @{ Name = 'Structure'; Status = 'WARN'; Detail = 'extension helper Foo is defined but nothing reaches it'; File = 'PSAppDeployToolkit.Extensions.psm1' }) }
                systemTest = @(
                    @{ type = 'Install'; exitCode = 0; success = $true; detection = 'installed'; at = '2026-09-21T15:32:51Z' },
                    @{ type = 'Uninstall'; exitCode = 0; success = $true; detection = 'unknown'; at = '2026-09-21T17:49:38Z' })
                assignment = @{ at = '2026-09-28T07:23:44Z'; verified = 'read back from Intune'; groups = @(
                        @{ Group = 'grp-available-Widget'; GroupId = 'aaaaaaaa-1111-2222-3333-444444444444'; Type = 'Available'; Availability = 'As soon as possible' },
                        @{ Group = 'grp-required-Widget'; GroupId = 'bbbbbbbb-1111-2222-3333-444444444444'; Type = 'Required'; Availability = 'As soon as possible' },
                        @{ Group = 'grp-uninstall-Widget'; GroupId = 'cccccccc-1111-2222-3333-444444444444'; Type = 'Uninstall'; Availability = 'As soon as possible' }) }
                upload     = @{ appId = '215550e2-1475-425d-84ba-03f9b5ac7adc'; at = '2026-09-28T07:23:12Z'; portalUrl = 'https://intune.microsoft.com/#view/x' }
                package    = @{ sha256 = 'A5D94D96D7368ECBE3904E7933C0DD04BA80754309623D16F027862D3C7A4205'; setupFile = 'Invoke-AppDeployToolkit.exe' }
            }
        }
        $script:lManifest | ConvertTo-Json -Depth 12 | Set-Content $script:lmf -Encoding UTF8
        & $script:gen -ManifestPath $script:lmf -LogoPath $script:llogo -OutputPath $script:lout 3>$null | Out-Null
        $script:lhtml = Get-Content $script:lout -Raw -Encoding UTF8
        $script:de = Get-DossierView -Html $script:lhtml -Lang 'de'
        $script:en = Get-DossierView -Html $script:lhtml -Lang 'en'
    }
    AfterAll { $env:PSADT_DEPLOY_HOME = $script:oldHomeL }

    It 'shows no English interface text in the German view' {
        $contains = 'As soon as possible', 'Determine behavior based on return codes', 'Custom Detection Script', 'App information tab',
        'Program tab', 'Soft reboot', 'Publisher', 'Developer', 'Owner', 'Privacy URL', 'Information URL', 'Allow uninstall',
        'Default icon guard', 'SetupFile', 'Show detection script', 'not set', 'passed', 'Return Codes'
        $exact = 'pass', 'fail', 'Available', 'Required', 'Detection', 'Success', 'Failed', 'Retry'
        $hits = @(foreach ($line in $script:de) {
                foreach ($c in $contains) { if ($line -match "\b$([regex]::Escape($c))\b") { "[$c] $line" } }
                foreach ($cell in ($line -split ' \| ')) { if ($exact -ccontains $cell.Trim()) { "[$($cell.Trim())] $line" } }
            })
        $hits | Should -BeNullOrEmpty
    }

    It 'shows no German interface text in the English view' {
        $words = 'bestanden', 'Erforderlich', 'Verf.gbar', 'So bald wie', 'Verhalten basierend', 'Benutzerdefiniert', 'nicht gesetzt',
        'nicht festgelegt', 'Kommentar im Skript', 'Paket-Helfer', 'Deinstallieren', 'R.ckgabecodes', 'Zeichenkodierung', 'Herausgeber',
        'Entwickler', 'getestet', 'Hochgeladen', 'nicht protokolliert'
        $hits = @(foreach ($line in $script:en) { foreach ($w in $words) { if ($line -match $w) { "[$w] $line" } } })
        $hits | Should -BeNullOrEmpty
    }

    It 'has no logo row in the app-information table - the logo section already says it' {
        (Get-Section $script:lhtml 'appinfo') | Should -Not -Match 'data-de="Logo"'
    }

    It 'names the assigned groups and keeps the id as a detail' {
        @($script:de | Where-Object { $_ -match '^grp-required-Widget\b.*\| Erforderlich \| So bald wie m' }).Count | Should -Be 1
        (Get-Section $script:lhtml 'assign') | Should -Match 'bbbbbbbb-1111-2222-3333-444444444444'
        (Get-Section $script:lhtml 'assign') | Should -Not -Match '<td>bbbbbbbb-'
    }

    It 'takes the script version, the package revision and the author from the launcher' {
        $script:de | Should -Contain 'Skript-Version 0.7'
        $script:de | Should -Contain 'Paket-Rev 03'
        $script:de | Should -Contain 'Autor Jane Doe, ACME Ltd'
    }

    It 'falls back to the configured author when the launcher names none' {
        $d = Join-Path $TestDrive 'lang_noauthor'
        New-Item $d -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $d 'Invoke-AppDeployToolkit.ps1') ($script:launcherText -replace "(?m)^\s*AppScriptAuthor.*$", '') -Encoding UTF8
        $mf = Join-Path $d 'psadt-package.json'
        $script:lManifest | ConvertTo-Json -Depth 12 | Set-Content $mf -Encoding UTF8
        & $script:gen -ManifestPath $mf -OutputPath (Join-Path $d 'd.html') 3>$null | Out-Null
        Get-DossierView -Html (Get-Content (Join-Path $d 'd.html') -Raw -Encoding UTF8) -Lang 'de' | Should -Contain 'Autor Pat Example, Example GmbH'
    }

    It 'builds the SYSTEM-test rows from what the DEV-VM route recorded, without hand-built metadata' {
        @($script:de | Where-Object { $_ -match '^Installation \(.+\) \| 0 \| erkannt \| bestanden$' }).Count | Should -Be 1
        @($script:de | Where-Object { $_ -match '^Deinstallation \(.+\) \| 0 \| nicht protokolliert \| bestanden$' }).Count | Should -Be 1
        $script:lhtml | Should -Not -Match 'SYSTEM-Test wurde nicht ausgef'
    }

    It 'reads the logo size from the PNG header instead of printing "not checked"' {
        $script:lhtml | Should -Match '600 &times; 600 px'
        (Get-Section $script:lhtml 'logo') | Should -Not -Match 'nicht gepr&uuml;ft'
    }

    It 'leaves no value cell empty' {
        $empty = @([regex]::Matches($script:lhtml, '(?s)<tr><td class="k"[^>]*>([^<]*)</td><td>(.*?)</td></tr>') |
                Where-Object { [string]::IsNullOrWhiteSpace(($_.Groups[2].Value -replace '<[^>]+>', '')) } | ForEach-Object { $_.Groups[1].Value })
        $empty | Should -BeNullOrEmpty
    }

    It 'states the absence of drivers in one row, not two' {
        $req = Get-Section $script:lhtml 'requirements'
        $req | Should -Not -Match 'data-de="Treiber-Zertifikat"'
        $req | Should -Match 'keine Treiber'
        $req | Should -Match 'kein Zertifikat erforderlich'
    }

    It 'prints the app version once in the header area and once in the table' {
        ([regex]::Matches($script:lhtml, 'data-de="App-Version"')).Count | Should -Be 2
    }

    It 'shows the Intune app id and the package hash once uploaded' {
        $logo = Get-Section $script:lhtml 'logo'
        $logo | Should -Match '215550e2-1475-425d-84ba-03f9b5ac7adc'
        $logo | Should -Match 'A5D94D96D7368ECBE3904E7933C0DD04BA80754309623D16F027862D3C7A4205'
        $logo | Should -Match '2026-09-28'
    }

    It 'drops the PSADT template comments and placeholders from the hooks' {
        $hooks = Get-Section $script:lhtml 'hooks'
        $hooks | Should -Not -Match 'Show Progress Message'
        $hooks | Should -Not -Match 'Perform Post-Repair tasks here'
        $hooks | Should -Not -Match 'Perform Uninstallation tasks here'
    }

    It 'marks a package comment as a quote from the English script' {
        $hooks = Get-Section $script:lhtml 'hooks'
        $hooks | Should -Match 'Remove the legacy client first'
        @($script:de | Where-Object { $_ -match '^Kommentar im Skript \(EN\).*Remove the legacy client first' }).Count | Should -Be 1
    }

    It 'lists the package helpers a hook calls, apart from the verified PSADT cmdlets' {
        $hooks = Get-Section $script:lhtml 'hooks'
        $hooks | Should -Match 'Install-WidgetThing'
        $hooks | Should -Match 'Uninstall-WidgetThing'
        $hooks | Should -Match 'Paket-Helfer'
        (Get-Section $script:lhtml 'cmdlets') | Should -Not -Match 'WidgetThing'
    }

    It 'summarises the passed pre-flight checks and keeps the warning in view' {
        $pf = Get-Section $script:lhtml 'preflight'
        $pf | Should -Match '3 von 4'
        $cut = $pf.IndexOf('<details')
        $cut | Should -BeGreaterThan 0
        $pf.IndexOf('nothing reaches it') | Should -BeLessThan $cut -Because 'a warning is never folded away'
        $pf.IndexOf('PARSE_OK') | Should -BeGreaterThan $cut -Because 'passed checks are folded'
    }

    It 'says a hook was tested only when its action passed the SYSTEM test' {
        $hooks = Get-Section $script:lhtml 'hooks'
        [regex]::Match($hooks, '(?s)<div class="hook install">.*?hook-foot">(.*?)</div>').Groups[1].Value | Should -Match 'data-de="getestet"'
        [regex]::Match($hooks, '(?s)<div class="hook repair">.*?hook-foot">(.*?)</div>').Groups[1].Value | Should -Match 'data-de="nicht getestet"'
    }

    It 'writes German with real umlauts, never ASCII stand-ins' {
        $src = Get-Content $script:gen -Raw
        $src | Should -Not -Match 'vertrauenswuerdig|kein Zertifikat noetig|Abschliessende|SYSTEM ueber|geprueft|unveraendert|uebernommen|gefuellt'
    }
}

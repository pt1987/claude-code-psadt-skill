BeforeAll {
    $script:src = Join-Path $PSScriptRoot '..\scripts\New-MsiPackage.ps1'
    # Parse the file WITHOUT executing it (the script Imports PSAppDeployToolkit and writes files on run).
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:src, [ref]$null, [ref]([System.Management.Automation.Language.ParseError[]]$errs))
    $script:errs = $errs
    $pb = $script:ast.ParamBlock
    $script:params = @($pb.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $script:mandatory = @($pb.Parameters | Where-Object {
        $_.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' } |
            ForEach-Object { $_.NamedArguments } | Where-Object { $_.ArgumentName -eq 'Mandatory' }
    } | ForEach-Object { $_.Name.VariablePath.UserPath })
}

Describe 'New-MsiPackage.ps1' {
    It 'exists' {
        Test-Path $script:src | Should -BeTrue
    }

    It 'parses without syntax errors' {
        $script:errs | Should -BeNullOrEmpty
    }

    It 'declares the expected mandatory parameters' {
        foreach ($p in 'Name','AppVendor','AppName','AppVersion','AppArch','ProductCode','InstallerFile','InstallerPath') {
            $script:mandatory | Should -Contain $p
        }
    }

    It 'resolves Get-PsadtConfig as a sibling (no hard-coded skills path)' {
        $raw = Get-Content $script:src -Raw
        $raw | Should -Not -Match '\.claude\\skills'
        $raw | Should -Match "Join-Path \`$PSScriptRoot 'Get-PsadtConfig.ps1'"
    }

    It 'is 7-bit ASCII only (encoding cleanliness)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:src)
        ($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe 'New-MsiPackage: one log per run + manifest (0.21.0)' {
    BeforeAll { $script:raw = Get-Content $script:src -Raw }

    It 'emits a LogName carrying the identity, the deployment type and a timestamp' {
        $script:raw | Should -Match "LogName = \('__LOGSTEM__'"
        $script:raw | Should -Match "Get-Date -Format 'yyyyMMdd-HHmmss'"
    }
    It 'guards the deployment type inline - the launcher declares no default for it' {
        $script:raw | Should -Match '\$\(if \(\$DeploymentType\) \{ \$DeploymentType \} else \{ .Install. \}\)'
    }
    It 'takes the log stem from the ONE sanitizing rule instead of copying it' {
        $script:raw | Should -Match "Replace\('__LOGSTEM__', "
        $script:raw | Should -Match "Get-PsadtPackageManifest\.ps1'\) -Identity"
    }
    It 'writes the package manifest with package.type = installer' {
        $script:raw | Should -Match 'Set-PsadtPackageManifest\.ps1'
        $script:raw | Should -Match "'package\.type'\s+= 'installer'"
    }
}

Describe 'New-MsiPackage: the template Replace chain is unbroken' {
    BeforeAll { $script:chainRaw = Get-Content $script:src -Raw }

    It 'has no statement wedged into the $out = $tpl.Replace(...) chain' {
        # This is NOT caught by a parse check: '$tpl.' followed by a comment and then '$logStem = ...'
        # parses fine as '$tpl.$logStem = ...' and fails only at RUN time with
        # "The property '' cannot be found on this object". A sed insert put exactly that into two
        # generators in 0.21.0. So: from '$out = $tpl.' until the chain ends, every non-empty line must be
        # a .Replace(...) continuation.
        $lines = $script:chainRaw -split "`r?`n"
        $start = ($lines | Select-String -SimpleMatch '$out = $tpl.' | Select-Object -First 1).LineNumber
        $start | Should -Not -BeNullOrEmpty
        for ($i = $start; $i -lt $lines.Count; $i++) {
            $line = $lines[$i].Trim()
            if ($line -eq '') { continue }
            $line | Should -Match '^Replace\('
            if ($line -notmatch '\.$') { break }      # last link in the chain
        }
    }
    It 'computes the log stem BEFORE the chain uses it' {
        $stemAt  = $script:chainRaw.IndexOf('$logStem = (&')
        $chainAt = $script:chainRaw.IndexOf('$out = $tpl.')
        $stemAt  | Should -BeGreaterThan 0
        $chainAt | Should -BeGreaterThan $stemAt
    }
}

Describe 'New-MsiPackage array parameters (0.26.2)' {
    # The 2026-09-06 binder trap, third occurrence - and the generator was missed when 0.25.1 fixed the
    # other five scripts. With "-ProcessesToClose 'a','b'" the -File binder hands over ONE element, so the
    # scaffold ends up with AppProcessesToClose = @('''a'',''b''') - a single nonsense process name.
    # Show-ADTInstallationWelcome -CloseProcesses then closes NOTHING and reports success: the install
    # proceeds against a running application. Observed while packaging BootForge on 2026-09-08.
    BeforeAll {
        $raw = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\New-MsiPackage.ps1') -Raw
        $tokens = $null
        [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$tokens, [ref]$null) | Out-Null
        $b = [System.Text.StringBuilder]::new($raw)
        foreach ($t in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
            $len = $t.Extent.EndOffset - $t.Extent.StartOffset
            [void]$b.Remove($t.Extent.StartOffset, $len); [void]$b.Insert($t.Extent.StartOffset, (' ' * $len))
        }
        $script:MsiCode = $b.ToString()
    }

    It 'defines the expansion helper' {
        $script:MsiCode | Should -Match 'function Expand-CommaSeparated'
    }

    It 'expands comma-separated values for -ProcessesToClose' {
        $script:MsiCode | Should -Match '\$ProcessesToClose = Expand-CommaSeparated \$ProcessesToClose'
    }

    It 'expands BEFORE the literal is built - otherwise the split is pointless' {
        $expandAt = $script:MsiCode.IndexOf('$ProcessesToClose = Expand-CommaSeparated')
        $literalAt = $script:MsiCode.IndexOf('$procLiteral =')
        $expandAt  | Should -BeGreaterThan 0
        $literalAt | Should -BeGreaterThan $expandAt
    }

    It 'records the installer file and the ProductCode for the verified-switch store' {
        $raw = Get-Content $script:src -Raw
        $raw | Should -Match "'package\.installerFile'\s*=\s*\`$InstallerFile"
        $raw | Should -Match "'package\.productCode'\s*=\s*\`$ProductCode"
    }

    It 'keeps the manifest ProductCode switches for the default mode' {
        $raw = Get-Content $script:src -Raw
        $raw | Should -Match 'uninstall\s*=\s*"msiexec /x \$ProductCode'
    }

    It 'records machine-readable switches including the researched properties' {
        # An MSI's silent switch is deterministic; its PROPERTIES are not. ADDLOCAL selections and the
        # update-check properties are researched per application and are the expensive half of the
        # package, so they belong in the store.
        $raw = Get-Content $script:src -Raw
        $raw | Should -Match 'installArgs\s*=\s*"/qn /norestart'
        $raw | Should -Match 'uninstallArgs\s*=\s*''/qn /norestart'''
    }
}

Describe 'New-MsiPackage.ps1 keeps operator values out of the code path (0.43.0)' {
    # 2026-09-21 audit (B03): three placeholders were substituted raw into a launcher that runs as SYSTEM.
    # A ProductCode with an apostrophe broke a single-quoted literal in launcher AND detection script; an
    # AppName with a $ interpolated inside the double-quoted desktop-shortcut path; a Changelog with #>
    # terminated the comment-based help and turned what followed into top-level code.
    BeforeAll { . "$PSScriptRoot/_helpers.ps1"; $script:text = Get-Content -LiteralPath $script:src -Raw }

    It 'validates -ProductCode as a GUID at binding' {
        $p = $script:ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ProductCode' }
        @($p.Attributes | ForEach-Object { $_.TypeName.Name }) | Should -Contain 'ValidatePattern'
    }

    It 'embeds the desktop-shortcut name as a single-quoted, escaped literal, never inside a double-quoted string' {
        $script:text | Should -Not -Match '"[^"\r\n]*__APPNAME_FILE__[^"\r\n]*"'
        $script:text | Should -Match "'__APPNAME_FILE__\.lnk'"
        $script:text | Should -Match 'Replace\(''__APPNAME_FILE__'', \(Get-SqEscaped \$AppName\)\)'
    }

    It 'rejects an Author or Changelog carrying the comment terminator' {
        . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:src -Name 'Assert-NoCommentTerminator')))
        { Assert-NoCommentTerminator '- 0.1 (2026-09-21, Pat): initial' 'Changelog' } | Should -Not -Throw
        { Assert-NoCommentTerminator 'x #> Write-Host injected' 'Changelog' } | Should -Throw -ExpectedMessage '*Changelog*'
    }

    It 'runs the terminator guard over Author and Changelog' {
        $script:text | Should -Match 'Assert-NoCommentTerminator[^\r\n]*\$Author'
        $script:text | Should -Match 'Assert-NoCommentTerminator[^\r\n]*\$Changelog'
    }
}

BeforeDiscovery {
    $script:hasPsadt = [bool](Get-Module -ListAvailable PSAppDeployToolkit)
}

Describe 'New-MsiPackage: self-updating mode (0.44.0)' -Skip:(-not $script:hasPsadt) {
    # Google Chrome 154, 2026-09-23: every build ships a new ProductCode and GoogleUpdater updates in place,
    # so a ProductCode-keyed package detects nothing one update later (Intune reinstall loop), installs an
    # older MSI over a newer build (1603) and uninstalls a GUID the device no longer has. The generator is
    # RUN here, in both modes, because the templating is where this would silently regress.
    BeforeAll {
        $script:gen = Join-Path $PSScriptRoot '..\scripts\New-MsiPackage.ps1'
        $script:root = Join-Path $TestDrive 'pk'
        $msi = Join-Path $TestDrive 'dummy.msi'
        Set-Content -LiteralPath $msi -Value 'x'
        $script:common = @{
            AppVendor = 'Contoso'; AppName = 'Contoso Browser'; AppVersion = '12.3.45.6'; AppArch = 'x64'
            ProductCode = '{11111111-2222-3333-4444-555555555555}'; InstallerFile = 'contoso.msi'; InstallerPath = $msi
            AdditionalArgs = 'NOPING=1'; ProcessesToClose = @('contoso'); Author = 'Test'; Changelog = 'c'; PackageRoot = $script:root
        }
        & $script:gen -Name 'Plain' @script:common | Out-Null
        & $script:gen -Name 'Self' -SelfUpdatingBinary 'Contoso\Browser\contoso.exe' @script:common | Out-Null
        $script:plainL = Get-Content (Join-Path $script:root 'Plain\Invoke-AppDeployToolkit.ps1') -Raw
        $script:selfL = Get-Content (Join-Path $script:root 'Self\Invoke-AppDeployToolkit.ps1') -Raw
        $script:selfD = Get-Content (Join-Path $script:root 'Self\Detect-Self.ps1') -Raw
        $script:selfX = Get-Content (Join-Path $script:root 'Self\PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1') -Raw
        $script:plainX = Get-Content (Join-Path $script:root 'Plain\PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1') -Raw
        $script:selfM = Get-Content (Join-Path $script:root 'Self\psadt-package.json') -Raw | ConvertFrom-Json
    }

    It 'leaves the default mode keyed on the ProductCode' {
        $script:plainL | Should -Match "Start-ADTMsiProcess -Action Uninstall -ProductCode '\{11111111-2222-3333-4444-555555555555\}'"
        $script:plainL | Should -Match "Start-ADTMsiProcess -Action Repair -ProductCode '\{11111111-2222-3333-4444-555555555555\}' -RepairMode Reinstall"
        $script:plainL | Should -Not -Match 'Get-InstalledBinaryVersion'
        $script:plainX | Should -Not -Match 'Get-InstalledBinaryVersion'
    }

    It 'keys no hook and not the detection on the build ProductCode' {
        $script:selfL | Should -Not -Match '11111111-2222'
        $script:selfD | Should -Not -Match '11111111-2222'
    }

    It 'detects by a version FLOOR on the binary, resolving 64-bit Program Files' {
        $script:selfD | Should -Match "\[System\.Version\]'12\.3\.45\.6'"
        $script:selfD | Should -Match '-ge \$minVersion'
        $script:selfD | Should -Match 'ProgramW6432'
        $script:selfD | Should -Match "'Contoso\\Browser\\contoso\.exe'"
    }

    It 'skips the install on an equal or newer build, before closing anything' {
        $guard = $script:selfL.IndexOf('Get-InstalledBinaryVersion')
        $guard | Should -BeGreaterThan 0
        $guard | Should -BeLessThan $script:selfL.IndexOf('Show-ADTInstallationWelcome @saiwParams')
        $script:selfL | Should -Match '-ge \[System\.Version\]\$adtSession\.AppVersion'
    }

    It 'uninstalls and repairs whichever MSI is registered under the exact ARP name' {
        $script:selfL | Should -Match "Uninstall-ADTApplication -Name 'Contoso Browser' -NameMatch Exact -ApplicationType MSI"
        $script:selfL | Should -Match "Get-ADTApplication -Name 'Contoso Browser' -NameMatch Exact -ApplicationType MSI"
        $script:selfL | Should -Match 'Start-ADTMsiProcess -Action Repair -ProductCode \$registeredMsi\.ProductCode'
    }

    It 'puts the helper in the Extensions module, not the launcher' {
        $script:selfX | Should -Match 'function Get-InstalledBinaryVersion'
        $script:selfL | Should -Not -Match 'function Get-InstalledBinaryVersion'
    }

    It 'writes generated scripts that parse and are 7-bit ASCII' {
        foreach ($p in 'Self\Invoke-AppDeployToolkit.ps1', 'Self\Detect-Self.ps1', 'Self\PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1') {
            $full = Join-Path $script:root $p
            $errs = $null
            [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$null, [ref]$errs) | Out-Null
            $errs | Should -BeNullOrEmpty -Because $p
            ([System.IO.File]::ReadAllBytes($full) | Where-Object { $_ -gt 127 -and $_ -notin 0xEF, 0xBB, 0xBF }).Count | Should -Be 0 -Because $p
        }
    }

    It 'records the mode in the manifest' {
        $script:selfM.package.detection | Should -Be 'versionFloor'
        $script:selfM.package.selfUpdating.binary | Should -Be 'Contoso\Browser\contoso.exe'
        $script:selfM.package.selfUpdating.arpDisplayName | Should -Be 'Contoso Browser'
    }

    It 'keeps an AppName with a quote and a $ inert in the generated detection and hooks (B03 class)' {
        $weird = $script:common.Clone(); $weird.AppName = "Con'toso `$env:COMPUTERNAME Browser"
        & $script:gen -Name 'Weird' -SelfUpdatingBinary 'Contoso\Browser\contoso.exe' @weird | Out-Null
        $d = Get-Content (Join-Path $script:root 'Weird\Detect-Weird.ps1') -Raw
        $l = Get-Content (Join-Path $script:root 'Weird\Invoke-AppDeployToolkit.ps1') -Raw
        $d | Should -Match ([regex]::Escape("('Detected: Con''toso `$env:COMPUTERNAME Browser ' + `$version)"))
        $l | Should -Match ([regex]::Escape("Uninstall-ADTApplication -Name 'Con''toso `$env:COMPUTERNAME Browser' -NameMatch Exact"))
        foreach ($p in 'Weird\Detect-Weird.ps1', 'Weird\Invoke-AppDeployToolkit.ps1') {
            $errs = $null
            [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:root $p), [ref]$null, [ref]$errs) | Out-Null
            $errs | Should -BeNullOrEmpty -Because $p
        }
    }

    It 'rejects a rooted binary path' {
        { & $script:gen -Name 'Bad' -SelfUpdatingBinary 'C:\Program Files\x.exe' @script:common } | Should -Throw '*RELATIVE*'
    }
}

Describe 'a generator run does not silently discard an existing package (0.46.0)' {
    # 2026-09-21 audit B06: every generator opened with Remove-Item $pkg -Recurse -Force. Phase 4 is where
    # the operator fills the three hooks by hand, so a re-run with the same -Name threw that work away,
    # along with the Extensions module, Assets\ and the manifest's recorded results - no prompt, no warning.
    It 'requires -Force before replacing a package folder that already exists' {
        $pb = $script:ast.ParamBlock
        @($pb.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Contain 'Force'
        $script:text = Get-Content -LiteralPath $script:src -Raw
        $script:text | Should -Match 'if \(Test-Path \$pkg\)'
        $script:text | Should -Match 'already exists'
    }
    It 'refuses a PackageRoot that is a drive root' {
        $script:text | Should -Match 'GetPathRoot'
    }
}

Describe 'the installer hash is recorded, so the manifest can be joined to the stores (0.49.0)' {
    BeforeAll { $script:genSrc = Get-Content -LiteralPath $script:src -Raw }

    # Both hash-keyed stores - verified-switches.json and evidence\<sha>.json - are indexed by the
    # SHA256 of the vendor installer. The manifest never recorded it, so a package could not be joined
    # to what was learned about its own installer. Invoke-PsadtPreflight.ps1:388 already computes this
    # value from the same staged file; recording it at scaffold time costs one Get-FileHash.
    It 'records package.installerSha256' {
        $script:genSrc | Should -Match "'package\.installerSha256'"
    }
    It 'hashes the staged installer rather than inventing the value' {
        $script:genSrc | Should -Match 'Get-FileHash'
    }
    It 'records the processes to close, so the next version can inherit them' {
        # -ProcessesToClose was a generator parameter and nothing else: not in the manifest, not in the
        # switch store. It had to be retyped for every new version from memory.
        $script:genSrc | Should -Match "'package\.processesToClose'"
    }
}

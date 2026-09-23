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

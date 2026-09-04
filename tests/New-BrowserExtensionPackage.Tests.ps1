<#
    Tests for scripts/New-BrowserExtensionPackage.ps1. Like the MSI generator's tests these inspect the
    SOURCE via the AST and raw text: running the generator imports PSAppDeployToolkit and writes a package
    tree, which is a DEV-VM concern, not a unit test.
#>
BeforeAll {
    $script:src = Join-Path $PSScriptRoot '..\scripts\New-BrowserExtensionPackage.ps1'
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:src, [ref]$null, [ref]([System.Management.Automation.Language.ParseError[]]$errs))
    $script:errs = $errs
    $pb = $script:ast.ParamBlock
    $script:params = @($pb.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $script:mandatory = @($pb.Parameters | Where-Object {
        $_.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' } |
            ForEach-Object { $_.NamedArguments } | Where-Object { $_.ArgumentName -eq 'Mandatory' }
    } | ForEach-Object { $_.Name.VariablePath.UserPath })
}

Describe 'New-BrowserExtensionPackage.ps1' {
    It 'exists' { Test-Path $script:src | Should -BeTrue }
    It 'parses without syntax errors' { $script:errs | Should -BeNullOrEmpty }
    It 'declares the identity parameters the manifest needs' {
        foreach ($p in 'Name', 'AppVendor', 'AppName', 'AppVersion') { $script:params | Should -Contain $p }
    }
    It 'resolves sibling scripts as siblings (no hard-coded skills path)' {
        $raw = Get-Content $script:src -Raw
        $raw | Should -Not -Match '\.claude\\skills'
        $raw | Should -Match "Join-Path \`$PSScriptRoot 'Get-PsadtConfig.ps1'"
    }
    It 'is 7-bit ASCII only (encoding cleanliness)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:src)
        ($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe 'New-BrowserExtensionPackage: one log per run + manifest (0.21.0)' {
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
    It 'writes the package manifest with package.type = browser-extension' {
        $script:raw | Should -Match 'Set-PsadtPackageManifest\.ps1'
        $script:raw | Should -Match "'package\.type'\s+= 'browser-extension'"
    }
}

Describe 'New-BrowserExtensionPackage: the template Replace chain is unbroken' {
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

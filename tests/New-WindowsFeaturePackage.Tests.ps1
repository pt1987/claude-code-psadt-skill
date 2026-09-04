<#
    Tests for scripts/New-WindowsFeaturePackage.ps1. Like the MSI generator's tests these inspect the
    SOURCE via the AST and raw text: running the generator imports PSAppDeployToolkit and writes a package
    tree, which is a DEV-VM concern, not a unit test.
#>
BeforeAll {
    $script:src = Join-Path $PSScriptRoot '..\scripts\New-WindowsFeaturePackage.ps1'
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:src, [ref]$null, [ref]([System.Management.Automation.Language.ParseError[]]$errs))
    $script:errs = $errs
    $pb = $script:ast.ParamBlock
    $script:params = @($pb.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

Describe 'New-WindowsFeaturePackage.ps1' {
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

Describe 'New-WindowsFeaturePackage: one log per run + manifest (0.21.0)' {
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
    It 'writes the package manifest with package.type = windows-feature' {
        $script:raw | Should -Match 'Set-PsadtPackageManifest\.ps1'
        $script:raw | Should -Match "'package\.type'\s+= 'windows-feature'"
    }
}

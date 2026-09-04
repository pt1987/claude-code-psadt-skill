<#
    Tests for scripts/New-DriverPackage.ps1. Like the other generator tests these inspect the SOURCE via
    the AST and raw text - running the generator imports PSAppDeployToolkit and writes a package tree,
    which belongs on a DEV VM. What matters here is that the generated content cannot be wrong in the ways
    that actually hurt: a collective pnputil call whose exit code lies, a guessed oemNN.inf, or an unsigned
    driver reaching a package at all.
#>
BeforeAll {
    $script:src = Join-Path $PSScriptRoot '..\scripts\New-DriverPackage.ps1'
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:src, [ref]$null, [ref]([System.Management.Automation.Language.ParseError[]]$errs))
    $script:errs = $errs
    $script:raw = Get-Content $script:src -Raw
    $pb = $script:ast.ParamBlock
    $script:params = @($pb.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $script:mandatory = @($pb.Parameters | Where-Object {
        $_.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' } |
            ForEach-Object { $_.NamedArguments } | Where-Object { $_.ArgumentName -eq 'Mandatory' }
    } | ForEach-Object { $_.Name.VariablePath.UserPath })
}

Describe 'New-DriverPackage.ps1' {
    It 'exists' { Test-Path $script:src | Should -BeTrue }
    It 'parses without syntax errors' { $script:errs | Should -BeNullOrEmpty }
    It 'declares the expected mandatory parameters' {
        foreach ($p in 'Name', 'AppName', 'AppVendor', 'AppVersion', 'DriverSource') { $script:mandatory | Should -Contain $p }
    }
    It 'offers exactly the three certificate owners' {
        $script:raw | Should -Match "ValidateSet\('policy', 'package', 'none'\)"
    }
    It 'resolves sibling scripts as siblings (no hard-coded skills path)' {
        $script:raw | Should -Not -Match '\.claude\\skills'
        $script:raw | Should -Match "Join-Path \`$PSScriptRoot 'Get-PsadtConfig.ps1'"
    }
    It 'is 7-bit ASCII only (encoding cleanliness)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:src)
        ($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe 'New-DriverPackage: it refuses what cannot work' {
    It 'classifies BEFORE it scaffolds anything' {
        # The classifier call has to come before New-ADTTemplate, or an unsigned driver leaves a package
        # tree behind on every failed attempt.
        $classifyAt = $script:raw.IndexOf('Get-DriverSignatureInfo.ps1')
        $scaffoldAt = $script:raw.IndexOf('New-ADTTemplate')
        $classifyAt | Should -BeGreaterThan 0
        $scaffoldAt | Should -BeGreaterThan $classifyAt
    }
    It 'aborts on an unsigned driver and quotes the options' {
        $script:raw | Should -Match 'Cannot build a driver package from unsigned drivers'
        $script:raw | Should -Match '\$trust\.Options'
    }
    It 'aborts on a vendor-signed kernel driver and names the escape hatch' {
        $script:raw | Should -Match 'Refusing to build this package'
        $script:raw | Should -Match '-AssumeSecureBootOff'
    }
    It 'never enables testsigning or disables integrity checks' {
        $script:raw | Should -Not -Match '(?i)bcdedit'
        $script:raw | Should -Not -Match '(?i)nointegritychecks'
        $script:raw | Should -Not -Match '(?i)/set\s+testsigning'
    }
    It 'defaults the certificate owner from the classification instead of asking' {
        $script:raw | Should -Match "PSBoundParameters\.ContainsKey\('CertOwner'\)"
        $script:raw | Should -Match '\$trust\.SuggestedCertOwner'
    }
}

Describe 'New-DriverPackage: the generated install hooks' {
    It 'stages every INF individually, never the collective *.inf form' {
        $script:raw | Should -Match '/add-driver'
        # The collective call is the anti-pattern (Microsoft documents its aggregate exit code as
        # unreliable). Assert on the actual INVOCATION, not the word: the script explains why it avoids
        # /subdirs, so the string legitimately appears in a comment.
        $script:raw | Should -Not -Match '(?m)ArgumentList.*subdirs'
        $script:raw | Should -Match 'foreach \(\$d in \$DriverPackages\)'
    }
    It 'treats 0, 259 and 3010 as success and raises 3010 to Intune' {
        $script:raw | Should -Match 'SuccessExitCodes @\(0, 259, 3010\)'
        $script:raw | Should -Match 'SetExitCode\(3010\)'
        $script:raw | Should -Match 'AppSuccessExitCodes = @\(0, 259\)'
    }
    It 'documents what 259 actually means (staged, no matching device)' {
        $script:raw | Should -Match 'ERROR_NO_MORE_ITEMS'
    }
    It 'names the two pnputil failures that actually happen' {
        $script:raw | Should -Match '0xE000022F'
        $script:raw | Should -Match '0xE0000247'
    }
    It 'resolves oemNN.inf by Original Name instead of guessing an index' {
        $script:raw | Should -Match '/enum-drivers'
        $script:raw | Should -Match 'Original Name'
        $script:raw | Should -Match '/delete-driver'
        $script:raw | Should -Match '/uninstall /force'
    }
    It 'imports the signer certificate ONLY when the package owns it' {
        $script:raw | Should -Match "if \(\`$CertOwner -eq 'package'\)"
        $script:raw | Should -Match 'Import-ADTTrustedPublisherCert'
        $script:raw | Should -Match 'TrustedPublisher'
    }
    It 'ships the four extension helpers' {
        foreach ($fn in 'Add-ADTDriverPackage', 'Remove-ADTDriverPackage', 'Get-ADTStagedDriver', 'Import-ADTTrustedPublisherCert') {
            $script:raw | Should -Match "function $fn"
        }
    }
    It 'requires admin (pnputil needs it) and repairs idempotently' {
        $script:raw | Should -Match 'RequireAdmin = \$true'
        $script:raw | Should -Match 'Re-adding is idempotent'
    }
}

Describe 'New-DriverPackage: detection + manifest' {
    It 'detects via Get-WindowsDriver and compares on the LEAF of OriginalFileName' {
        $script:raw | Should -Match 'Get-WindowsDriver -Online'
        $script:raw | Should -Match 'Split-Path -Leaf \(\[string\]\$_\.OriginalFileName\)'
    }
    It 'honours the Intune detection contract (stdout + exit 0, never a non-zero exit)' {
        $script:raw | Should -Match 'non-zero exit reads as a'
        $script:raw | Should -Not -Match '(?m)^exit [1-9]'
    }
    It 'writes package.type = driver plus the driverTrust decision' {
        $script:raw | Should -Match "'package\.type'\s+= 'driver'"
        $script:raw | Should -Match "'driverTrust'"
        $script:raw | Should -Match 'assumeSecureBootOff'
    }
    It 'sets a per-run LogName from the ONE sanitizing rule (WS3)' {
        $script:raw | Should -Match "LogName = \('__LOGSTEM__'"
        $script:raw | Should -Match "Get-PsadtPackageManifest\.ps1'\) -Identity"
    }
    It 'points at the cert policy when the policy owns the certificate' {
        $script:raw | Should -Match 'New-IntuneTrustedCertPolicy\.ps1'
        $script:raw | Should -Match 'SAME scope'
    }
}

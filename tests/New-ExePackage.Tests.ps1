# The EXE generator had no test file at all until the verified-switch store needed its manifest output
# to be machine-readable. Parsed, never executed: the script imports PSAppDeployToolkit and writes a
# package on run.

BeforeAll {
    $script:src = Join-Path $PSScriptRoot '..\scripts\New-ExePackage.ps1'
    $errs = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:src, [ref]$null, [ref]([System.Management.Automation.Language.ParseError[]]$errs))
    $script:errs = $errs
    $script:raw = Get-Content $script:src -Raw
    $pb = $script:ast.ParamBlock
    $script:mandatory = @($pb.Parameters | Where-Object {
            $_.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' } |
                ForEach-Object { $_.NamedArguments } | Where-Object { $_.ArgumentName -eq 'Mandatory' }
        } | ForEach-Object { $_.Name.VariablePath.UserPath })
}

Describe 'New-ExePackage.ps1' {
    It 'parses without syntax errors' {
        $script:errs | Should -BeNullOrEmpty
    }

    It 'declares the expected mandatory parameters' {
        foreach ($p in 'Name', 'AppVendor', 'AppName', 'AppVersion', 'AppArch', 'InstallerFile',
            'InstallerPath', 'InstallArgs', 'DisplayNameLike', 'VerifyRelativePath') {
            $script:mandatory | Should -Contain $p
        }
    }

    Context 'the manifest it writes' {
        It 'names the installer file' {
            # Files\ may hold several files. Without this key the only record of which one was installed
            # is the first token of the prose install string, which breaks on "Setup 1.2.exe".
            $script:raw | Should -Match "'package\.installerFile'\s*=\s*\`$InstallerFile"
        }

        It 'records machine-readable install and uninstall arguments' {
            # The verified-switch store consumes these. Its reader treats them as arguments only.
            $script:raw | Should -Match 'installArgs\s*=\s*\$InstallArgs'
            $script:raw | Should -Match 'uninstallArgs\s*=\s*\$UninstallArgs'
        }

        It 'keeps the prose fields too, because the dossier prints them' {
            $script:raw | Should -Match 'install\s*=\s*"\$InstallerFile \$InstallArgs"'
            $script:raw | Should -Match 'resolved from ARP at run time'
        }
    }

    It 'sets a per-run log name' {
        $script:raw | Should -Match 'LogName'
    }
}

Describe 'New-ExePackage.ps1 refuses the comment terminator in Author and Changelog (0.43.0)' {
    # 2026-09-21 audit (B03): __CHANGELOG__ and __AUTHOR__ land inside the launcher's <# #> block; a value
    # containing #> ends the block and what follows becomes top-level code in a script that runs as SYSTEM.
    BeforeAll { . "$PSScriptRoot/_helpers.ps1"; $script:genSrc = Join-Path $PSScriptRoot '..\scripts\New-ExePackage.ps1'; $script:genText = Get-Content -LiteralPath $script:genSrc -Raw }

    It 'rejects a value carrying the comment terminator' {
        . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:genSrc -Name 'Assert-NoCommentTerminator')))
        { Assert-NoCommentTerminator '- 0.1: initial' 'Changelog' } | Should -Not -Throw
        { Assert-NoCommentTerminator 'x #> Write-Host injected' 'Author' } | Should -Throw -ExpectedMessage '*Author*'
    }

    It 'runs the guard over Author and Changelog' {
        $script:genText | Should -Match 'Assert-NoCommentTerminator[^\r\n]*\$Author'
        $script:genText | Should -Match 'Assert-NoCommentTerminator[^\r\n]*\$Changelog'
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

Describe 'New-ExePackage: the running app and the command line (0.49.2)' {
    BeforeAll { $script:s3 = Get-Content -LiteralPath $script:src -Raw }
    It 'has no DeployMode switch - every package runs Silent (0.49.3)' {
        @($script:ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Not -Contain 'DeployMode'
    }
    It 'records the install and uninstall command lines in the manifest, Silent' {
        $script:s3 | Should -Match "'package\.installCommand'\s*=\s*'Invoke-AppDeployToolkit\.exe -DeploymentType Install -DeployMode Silent'"
        $script:s3 | Should -Match "'package\.uninstallCommand'\s*=\s*'Invoke-AppDeployToolkit\.exe -DeploymentType Uninstall -DeployMode Silent'"
    }
    It 'gives the Install close prompt a countdown - inside the if, because the countdown needs -CloseProcesses' {
        $script:s3 | Should -Match "(?s)if \(\`$adtSession\.AppProcessesToClose\.Count -gt 0\)\s*\{\s*\`$saiwParams\.Add\('CloseProcesses', \`$adtSession\.AppProcessesToClose\)\s*\`$saiwParams\.Add\('CloseProcessesCountdown', 60\)\s*\}"
    }
}

BeforeDiscovery { $script:hasPsadtExe = [bool](Get-Module -ListAvailable PSAppDeployToolkit) }

Describe 'New-ExePackage: a generated package with processes to close (0.49.2)' -Skip:(-not $script:hasPsadtExe) {
    BeforeAll {
        $g = Join-Path $PSScriptRoot '..\scripts\New-ExePackage.ps1'
        $r = Join-Path $TestDrive 'pk3'
        $exe = Join-Path $TestDrive 'setup.exe'
        Set-Content -LiteralPath $exe -Value 'x'
        & $g -Name 'Auto' -AppVendor 'ACME' -AppName 'Widget' -AppVersion '2.0' -AppArch 'x64' -InstallerFile 'setup.exe' `
            -InstallerPath $exe -InstallArgs '/S' -DisplayNameLike 'Widget' -VerifyRelativePath 'widget.exe' `
            -ProcessesToClose @('widget') -Author 'Test' -Changelog 'c' -PackageRoot $r | Out-Null
        $script:exeM = Get-Content (Join-Path $r 'Auto\psadt-package.json') -Raw | ConvertFrom-Json
        $script:exeL = Get-Content (Join-Path $r 'Auto\Invoke-AppDeployToolkit.ps1') -Raw
    }
    It 'records the Silent command lines' {
        $script:exeM.package.installCommand   | Should -Be 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent'
        $script:exeM.package.uninstallCommand | Should -Be 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent'
    }
    It 'writes the Install countdown into the launcher, and the launcher parses' {
        $script:exeL | Should -Match "\`$saiwParams\.Add\('CloseProcessesCountdown', 60\)"
        $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($script:exeL, [ref]$null, [ref]$e)
        @($e).Count | Should -Be 0
    }
}

Describe 'New-ExePackage: the detection script reports the version the way it is written (0.49.3)' {
    # Measured 2026-09-27: ARP said 3.01, and the detection script printed "3.1 detected (baseline 3.1)".
    # [System.Version] reads '3.01' as major 3, minor 1. The ORDERING is right - a vendor that writes the
    # minor with two digits compares 01 < 09 < 10 < 21 correctly - but the one line an operator reads in
    # the IME log names a version that does not exist. The comparison stays numeric; the text is the
    # string the source reported. Built from the template in the generator, then run.
    BeforeAll {
        $assign = $script:ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -eq '$detect' -and $n.Right.Extent.Text.StartsWith("@'") }, $true) | Select-Object -First 1
        $tmpl = $assign.Right.Expression.Value
        $script:detectText = $tmpl.Replace('__NAME__', 'Widget_3.01').Replace('__APPNAME__', 'Widget').
            Replace('__APPVERSION__', '3.01').Replace('__BASELINE__', '3.01').
            Replace('__VERIFYRELATIVEPATH__', 'widget.exe').Replace('__DISPLAYNAMELIKE__', 'ACME Widget')
        $dast = [System.Management.Automation.Language.Parser]::ParseInput($script:detectText, [ref]$null, [ref]$null)
        $fn = $dast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Add-Candidate' }, $true) | Select-Object -First 1
        $base = $dast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$baseline' }, $true) | Select-Object -First 1
        $verdict = $dast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Extent.Text -match '^if \(\$candidates\.Count' } | Select-Object -First 1
        $script:detectParts = @($base.Extent.Text, $fn.Extent.Text, $verdict.Extent.Text)
        $script:detectFor = {
            param([string]$Raw)
            $sb = [scriptblock]::Create(($script:detectParts[0], '$candidates = New-Object System.Collections.ArrayList', $script:detectParts[1],
                    "Add-Candidate '$Raw' 'ARP DisplayVersion'", $script:detectParts[2]) -join "`n")
            & $sb
        }
    }

    It 'prints the version the ARP entry wrote, not the normalised one' {
        & $script:detectFor '3.01' | Should -BeExactly 'Widget 3.01 detected via ARP DisplayVersion (baseline 3.01)'
    }

    It 'still compares numerically: a newer build satisfies the floor, an older one does not' {
        & $script:detectFor '3.10' | Should -BeExactly 'Widget 3.10 detected via ARP DisplayVersion (baseline 3.01)'
        & $script:detectFor '2.21' | Should -BeNullOrEmpty
    }
}

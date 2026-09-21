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

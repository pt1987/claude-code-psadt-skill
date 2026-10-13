# New-PortablePackage.ps1 (0.50.0) - the generator for payloads with no installer (a vendor ZIP or one
# binary). Built for Terraform 1.16.5 on 2026-10-13 and proved there by a full sandbox gate. The static
# half runs anywhere; the generated-package half needs PSAppDeployToolkit installed.

BeforeAll {
    $script:src = Join-Path $PSScriptRoot '..\scripts\New-PortablePackage.ps1'
    $errs = $null
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

Describe 'New-PortablePackage.ps1 - static' {
    It 'parses without syntax errors' { $script:errs | Should -BeNullOrEmpty }

    It 'is ASCII-only, like every script it generates' {
        $script:raw | Should -Not -Match '[^\x00-\x7F]'
    }

    It 'declares the expected mandatory parameters' {
        foreach ($p in 'Name', 'AppVendor', 'AppName', 'AppVersion', 'AppArch', 'SourcePath', 'VerifyRelativePath') {
            $script:mandatory | Should -Contain $p
        }
    }

    It 'has no DeployMode switch - every package runs Silent' {
        $script:params | Should -Not -Contain 'DeployMode'
    }

    It 'edits the machine PATH in the registry and keeps the value kind' {
        # [Environment]::SetEnvironmentVariable - and Set-ADTEnvironmentVariable, which calls it - writes
        # REG_SZ and breaks every %SystemRoot% segment of a REG_EXPAND_SZ Path.
        $script:raw | Should -Match 'DoNotExpandEnvironmentNames'
        $script:raw | Should -Match "GetValueKind\('Path'\)"
        $script:raw | Should -Match "SetValue\('Path', \`$new, \`$kind\)"
        # Calls only - the comments name both on purpose, to say why they are not used.
        $script:raw | Should -Not -Match 'Environment\]::SetEnvironmentVariable\('
        $script:raw | Should -Not -Match 'Set-ADTEnvironmentVariable\s+-'
    }

    It 'broadcasts the PATH change into the user session' {
        $script:raw | Should -Match 'Update-ADTDesktop'
    }

    It 'defers a running process with 1618 instead of killing it' {
        $script:raw | Should -Match 'Close-ADTSession -ExitCode 1618'
    }

    It 'reads the 64-bit registry view in the detection script' {
        $script:raw | Should -Match 'RegistryView\]::Registry64'
    }

    It 'never records a null element for an empty process list' {
        # A function that returns @() returns $null to its caller, and @($null) has one element: the
        # manifest carried processesToClose = [null] (found on this very run, in all three generators).
        $script:raw | Should -Match "'package\.processesToClose' = @\(\`$ProcessesToClose \| Where-Object \{ \`$_ \}\)"
    }

    It 'records the portable facts and a version-floor detection in the manifest' {
        $script:raw | Should -Match "'package\.type'\s*= 'portable'"
        $script:raw | Should -Match "'package\.detection'\s*= 'versionFloor'"
        $script:raw | Should -Match "'package\.installerSha256'"
        $script:raw | Should -Match "'package\.portable'"
    }
}

BeforeDiscovery { $script:hasPsadt = [bool](Get-Module -ListAvailable PSAppDeployToolkit) }

Describe 'New-PortablePackage.ps1 - a generated package' -Skip:(-not $script:hasPsadt) {
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $script:gen = Join-Path $PSScriptRoot '..\scripts\New-PortablePackage.ps1'
        $script:root = Join-Path $TestDrive 'pkgs'
        $srcDir = Join-Path $TestDrive 'zipsrc'
        New-Item -ItemType Directory -Path (Join-Path $srcDir 'tool-1.2') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $srcDir 'tool-1.2\tool.exe') -Value 'x'
        $script:zip = Join-Path $TestDrive 'tool_1.2_windows_amd64.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($srcDir, $script:zip)
        $script:sha = (Get-FileHash -LiteralPath $script:zip -Algorithm SHA256).Hash.ToLowerInvariant()

        & $script:gen -Name 'ACME_Tool_1.2' -AppVendor 'ACME' -AppName 'Tool' -AppVersion '1.2' -AppArch 'x64' `
            -SourcePath $script:zip -ExpectedSha256 $script:sha.ToUpperInvariant() -ArchiveSubfolder 'tool-1.2' `
            -VerifyRelativePath 'tool.exe' -AddToPath -DeferIfRunning 'tool,tool-agent.exe' `
            -SmokeTestArgs 'version' -SmokeTestPattern '^Tool 1\.2' -SmokeTestEnvironment @{ NO_TELEMETRY = '1' } `
            -Author 'Test' -Changelog 'c' -PackageRoot $script:root | Out-Null
        $script:pkg = Join-Path $script:root 'ACME_Tool_1.2'
        $script:launcher = Get-Content (Join-Path $script:pkg 'Invoke-AppDeployToolkit.ps1') -Raw
        $script:extText = Get-Content (Join-Path $script:pkg 'PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1') -Raw
        $script:detectText = Get-Content (Join-Path $script:pkg 'Detect-ACME_Tool_1.2.ps1') -Raw
        $script:m = Get-Content (Join-Path $script:pkg 'psadt-package.json') -Raw | ConvertFrom-Json
    }

    It 'writes three files that parse, are ASCII-only and carry no placeholder' {
        foreach ($t in $script:launcher, $script:extText, $script:detectText) {
            $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$e)
            @($e).Count | Should -Be 0
            $t | Should -Not -Match '[^\x00-\x7F]'
            $t | Should -Not -Match '__[A-Z0-9_]+__'
        }
    }

    It 'bundles the ZIP unchanged, so its hash stays the vendor checksum' {
        (Get-FileHash -LiteralPath (Join-Path $script:pkg 'Files\tool_1.2_windows_amd64.zip') -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $script:sha
        $script:m.package.installerSha256 | Should -Be $script:sha
        $script:m.package.installerFile | Should -Be 'tool_1.2_windows_amd64.zip'
    }

    It 'records the manifest the rest of the pipeline reads' {
        $script:m.package.type | Should -Be 'portable'
        $script:m.package.installerTech | Should -Be 'zip'
        $script:m.package.detection | Should -Be 'versionFloor'
        $script:m.package.installCommand | Should -Be 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent'
        $script:m.package.portable.arpKey | Should -Be 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PSADT_ACME_Tool'
        $script:m.package.portable.addToPath | Should -BeTrue
        @($script:m.package.portable.deferIfRunning) | Should -Be @('tool', 'tool-agent')
    }

    It 'never records a null process name' {
        @($script:m.package.processesToClose | Where-Object { $null -eq $_ }).Count | Should -Be 0
    }

    It 'uses a version-independent ARP key, so the next version replaces the row in place' {
        $script:extText | Should -Match "ArpKey\s+= 'PSADT_ACME_Tool'"
        $script:detectText | Should -Match 'Uninstall\\PSADT_ACME_Tool'
        $script:detectText | Should -Not -Match 'PSADT_ACME_Tool_1'
    }

    It 'splits the -File style comma list and strips .exe from defer names' {
        $script:extText | Should -Match "DeferIfRunning\s+= @\('tool', 'tool-agent'\)"
    }

    It 'calls install, smoke test and uninstall from the launcher - Repair reuses Install' {
        $script:launcher | Should -Match 'Install-ADTACMETool12Payload'
        $script:launcher | Should -Match 'Test-ADTACMETool12Payload'
        $script:launcher | Should -Match 'Uninstall-ADTACMETool12Payload'
        ([regex]::Matches($script:launcher, 'Exit-ADTACMETool12IfBusy')).Count | Should -Be 3
    }

    It 'asks PSADT for the session inside the module - $adtSession is not visible there' {
        $script:extText | Should -Match 'Get-ADTSession'
        $script:extText | Should -Not -Match '\$adtSession\.'
    }

    It 'refuses a SHA256 mismatch before writing anything' {
        { & $script:gen -Name 'Bad' -AppVendor 'A' -AppName 'B' -AppVersion '1.0' -AppArch 'x64' -SourcePath $script:zip `
                -ExpectedSha256 ('0' * 64) -VerifyRelativePath 'tool.exe' -ArchiveSubfolder 'tool-1.2' -Author 'T' -PackageRoot $script:root } |
            Should -Throw -ExpectedMessage '*SHA256 mismatch*'
        Test-Path (Join-Path $script:root 'Bad') | Should -BeFalse
    }

    It 'refuses an archive that lacks the promised binary' {
        { & $script:gen -Name 'NoBin' -AppVendor 'A' -AppName 'B' -AppVersion '1.0' -AppArch 'x64' -SourcePath $script:zip `
                -VerifyRelativePath 'other.exe' -Author 'T' -PackageRoot $script:root } |
            Should -Throw -ExpectedMessage "*has no entry*"
    }

    It 'refuses an install path that climbs out of Program Files' {
        { & $script:gen -Name 'Climb' -AppVendor 'A' -AppName 'B' -AppVersion '1.0' -AppArch 'x64' -SourcePath $script:zip `
                -ArchiveSubfolder 'tool-1.2' -VerifyRelativePath 'tool.exe' -InstallSubPath '..\Windows' -Author 'T' -PackageRoot $script:root } |
            Should -Throw -ExpectedMessage "*InstallSubPath*"
    }

    It 'refuses an MSI - that is the MSI generator''s job' {
        $msi = Join-Path $TestDrive 'x.msi'; Set-Content -LiteralPath $msi -Value 'x'
        { & $script:gen -Name 'Msi' -AppVendor 'A' -AppName 'B' -AppVersion '1.0' -AppArch 'x64' -SourcePath $msi `
                -VerifyRelativePath 'x.msi' -Author 'T' -PackageRoot $script:root } |
            Should -Throw -ExpectedMessage '*installer package*'
    }
}

Describe 'New-PortablePackage.ps1 - the defer guard, run' -Skip:(-not $script:hasPsadt) {
    # The sandbox gate never has the app running, so this branch would ship unexercised. Generated with
    # the name of a process that IS running (this test host), imported, and called.
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $gen = Join-Path $PSScriptRoot '..\scripts\New-PortablePackage.ps1'
        $root = Join-Path $TestDrive 'defer'
        $srcDir = Join-Path $TestDrive 'dsrc'
        New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $srcDir 'tool.exe') -Value 'x'
        $zip = Join-Path $TestDrive 'dtool.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($srcDir, $zip)
        $self = (Get-Process -Id $PID).ProcessName
        & $gen -Name 'Busy' -AppVendor 'ACME' -AppName 'Busy' -AppVersion '1.0' -AppArch 'x64' -SourcePath $zip `
            -VerifyRelativePath 'tool.exe' -DeferIfRunning $self -Author 'T' -Changelog 'c' -PackageRoot $root | Out-Null
        & $gen -Name 'Idle' -AppVendor 'ACME' -AppName 'Idle' -AppVersion '1.0' -AppArch 'x64' -SourcePath $zip `
            -VerifyRelativePath 'tool.exe' -DeferIfRunning 'no-such-process-4711' -Author 'T' -Changelog 'c' -PackageRoot $root | Out-Null
        Import-Module PSAppDeployToolkit -Force
        $script:busyMod = Import-Module (Join-Path $root 'Busy\PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1') -Force -PassThru -DisableNameChecking 3>$null
        $script:busyMod | Should -Not -BeNullOrEmpty
    }
    AfterAll { Get-Module PSAppDeployToolkit.Extensions | Remove-Module -Force -ErrorAction SilentlyContinue }

    It 'exits 1618 when the process is running' {
        Mock -ModuleName PSAppDeployToolkit.Extensions Close-ADTSession { }
        Mock -ModuleName PSAppDeployToolkit.Extensions Write-ADTLogEntry { }
        Exit-ADTBusyIfBusy
        Should -Invoke -ModuleName PSAppDeployToolkit.Extensions Close-ADTSession -Times 1 -Exactly -ParameterFilter { $ExitCode -eq 1618 }
    }

    It 'does nothing when it is not running' {
        $root = Join-Path $TestDrive 'defer'
        Get-Module PSAppDeployToolkit.Extensions | Remove-Module -Force
        Import-Module (Join-Path $root 'Idle\PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1') -Force -DisableNameChecking 3>$null
        Mock -ModuleName PSAppDeployToolkit.Extensions Close-ADTSession { }
        Mock -ModuleName PSAppDeployToolkit.Extensions Write-ADTLogEntry { }
        Exit-ADTIdleIfBusy
        Should -Invoke -ModuleName PSAppDeployToolkit.Extensions Close-ADTSession -Times 0 -Exactly
    }
}
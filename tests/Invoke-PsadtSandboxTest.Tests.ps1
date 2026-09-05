# SCOPE NOTE: these tests exercise the guards and the GENERATED artefacts (runner script + .wsb). Actually
# booting a Windows Sandbox is out of scope for a unit-test run - it needs the optional feature, takes
# minutes, and installs software. The end-to-end coverage is the real run documented in CHANGELOG 0.24.0.
#
# The three "generated runner" tests are REGRESSION GUARDS, not style checks. Each one corresponds to a bug
# that silently burned a full sandbox run before this script existed; all three fail as a timeout or a
# NullReferenceException minutes after launch, where the cause is nowhere near the symptom.
BeforeAll {
    . "$PSScriptRoot/_helpers.ps1"
}

Describe 'Invoke-PsadtSandboxTest' {
    BeforeEach {
        $script:root = New-TempSkillRoot
        $script:pkg = Join-Path $script:root 'MyPackage'
        New-Item $script:pkg -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $script:pkg 'Invoke-AppDeployToolkit.ps1') '# stub launcher'
        Set-Content (Join-Path $script:pkg 'Invoke-AppDeployToolkit.exe') 'stub'
        Set-Content (Join-Path $script:pkg 'Detect-MyPackage.ps1') 'exit 0'
        $script:script = Join-Path $script:root 'scripts/Invoke-PsadtSandboxTest.ps1'

        # Pretend Windows Sandbox is enabled and idle, so the guards pass and generation is reached.
        Mock -CommandName Get-CimInstance -MockWith { [pscustomobject]@{ Name = 'Containers-DisposableClientVM'; InstallState = 1 } }
        Mock -CommandName Get-Process -MockWith { @() }
    }
    AfterEach { Remove-TempSkillRoot $script:root }

    Context 'guards' {
        It 'throws when the folder is not a PSADT package' {
            $empty = Join-Path $script:root 'empty'; New-Item $empty -ItemType Directory -Force | Out-Null
            { & $script:script -PackagePath $empty -GenerateOnly } | Should -Throw -ExpectedMessage '*Not a PSADT package*'
        }

        It 'throws when the package has no Invoke-AppDeployToolkit.exe' {
            Remove-Item (Join-Path $script:pkg 'Invoke-AppDeployToolkit.exe') -Force
            { & $script:script -PackagePath $script:pkg -GenerateOnly } | Should -Throw -ExpectedMessage '*Invoke-AppDeployToolkit.exe*'
        }

        It 'throws when no detection script is present' {
            Remove-Item (Join-Path $script:pkg 'Detect-MyPackage.ps1') -Force
            { & $script:script -PackagePath $script:pkg -GenerateOnly } | Should -Throw -ExpectedMessage '*No Detect*'
        }

        It 'refuses to guess when several detection scripts are present' {
            Set-Content (Join-Path $script:pkg 'Detect-Other.ps1') 'exit 0'
            { & $script:script -PackagePath $script:pkg -GenerateOnly } | Should -Throw -ExpectedMessage '*Pass -DetectionScript*'
        }

        It 'throws with the enable command when the optional feature is disabled' {
            Mock -CommandName Get-CimInstance -MockWith { [pscustomobject]@{ Name = 'Containers-DisposableClientVM'; InstallState = 2 } }
            { & $script:script -PackagePath $script:pkg -GenerateOnly } | Should -Throw -ExpectedMessage '*Enable-WindowsOptionalFeature*'
        }

        It 'refuses to start when another sandbox instance is already running' {
            # Windows permits exactly one instance; a second launch attaches to the first, so the test would
            # run against the previous run's dirty machine instead of a clean one.
            Mock -CommandName Get-Process -MockWith { @([pscustomobject]@{ Name = 'WindowsSandboxServer' }) }
            { & $script:script -PackagePath $script:pkg -GenerateOnly } | Should -Throw -ExpectedMessage '*already running*'
        }
    }

    Context 'generated runner - regression guards' {
        BeforeEach {
            $script:gen = & $script:script -PackagePath $script:pkg -GenerateOnly
            $script:runner = Get-Content -LiteralPath $script:gen.RunnerPath -Raw
        }

        It 'writes the exit code with a space before the redirection operator' {
            # "echo %ERRORLEVEL%>file" makes cmd read a single-digit code as the stdin redirection operator
            # 0>, which creates an EMPTY file. The caller then waits for a number that never arrives and the
            # action is reported as a timeout although it succeeded.
            $script:runner | Should -Match 'echo %ERRORLEVEL% > '
            $script:runner | Should -Not -Match 'echo %ERRORLEVEL%>'
        }

        It 'waits for the exit-code file to hold a number, not merely to exist' {
            # The redirection creates the file before the value is written, so existence is not completion.
            $script:runner | Should -Match "-match '\^-\?\\d\+\`$'"
        }

        It 'builds the captured output by concatenation so an empty file stays a string' {
            # Get-Content -Raw returns $null for an empty file, which is the NORMAL result of a detection
            # script when the app is absent. In Windows PowerShell 5.1 "$x = [string]$null" is STILL $null,
            # so only concatenation (or a typed variable) yields a real empty string and keeps .Trim() safe.
            $script:runner | Should -Match "'' \+ \(Get-Content"
            $script:runner | Should -Not -Match '\[string\]\(Get-Content'
        }

        It 'never treats a timed-out detection as a valid absent result' {
            $script:runner | Should -Match '\(-not \$r\.TimedOut\) -and \(-not \[string\]::IsNullOrWhiteSpace'
        }

        It 'runs every deployment action as SYSTEM' {
            $script:runner | Should -Match "/RU 'SYSTEM'"
            $script:runner | Should -Match '/RL HIGHEST'
        }

        It 'covers the full Phase 6 loop and leaves the machine uninstalled' {
            foreach ($label in 'Install', 'DetectionAfterInstall', 'Uninstall', 'DetectionAfterUninstall',
                               'Reinstall', 'Repair', 'FinalUninstall') {
                $script:runner | Should -Match ([regex]::Escape($label))
            }
        }

        It 'writes DONE.txt in a finally block so the host never waits forever' {
            $script:runner | Should -Match 'finally'
            $script:runner | Should -Match 'DONE\.txt'
        }

        It 'is ASCII-clean like every other script this skill generates' {
            $bytes = [System.IO.File]::ReadAllBytes($script:gen.RunnerPath)
            # UTF-8 BOM is allowed (the file is written with one); no other byte may exceed 7-bit ASCII.
            $body = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF) { $bytes[3..($bytes.Length - 1)] } else { $bytes }
            @($body | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }
    }

    Context 'generated .wsb' {
        BeforeEach { $script:gen = & $script:script -PackagePath $script:pkg -GenerateOnly }

        It 'is well-formed XML' {
            { [xml](Get-Content -LiteralPath $script:gen.WsbPath -Raw) } | Should -Not -Throw
        }

        It 'maps the package read-only and the work folder read-write' {
            $xml = [xml](Get-Content -LiteralPath $script:gen.WsbPath -Raw)
            $folders = @($xml.Configuration.MappedFolders.MappedFolder)
            $folders.Count | Should -Be 2
            ($folders | Where-Object { $_.HostFolder -eq $script:pkg }).ReadOnly | Should -Be 'true'
            ($folders | Where-Object { $_.HostFolder -like '*_PsadtSandboxTest' }).ReadOnly | Should -Be 'false'
        }

        It 'starts the runner from the mapped work folder' {
            $xml = [xml](Get-Content -LiteralPath $script:gen.WsbPath -Raw)
            $xml.Configuration.LogonCommand.Command | Should -Match 'Run-PsadtSandboxTest\.ps1'
        }
    }

    Context 'package-specific assertions' {
        It 'embeds the -Paths* expectations in the runner' {
            $gen = & $script:script -PackagePath $script:pkg -GenerateOnly `
                -PathsPresentAfterInstall 'C:\Program Files\App\app.exe' `
                -PathsAbsentAfterInstall 'C:\Program Files\App\updater\GUP.exe'
            $runner = Get-Content -LiteralPath $gen.RunnerPath -Raw
            $runner | Should -Match ([regex]::Escape('C:\Program Files\App\app.exe'))
            $runner | Should -Match ([regex]::Escape('C:\Program Files\App\updater\GUP.exe'))
        }

        It 'escapes a single quote in a path instead of breaking the literal' {
            $gen = & $script:script -PackagePath $script:pkg -GenerateOnly -PathsPresentAfterInstall "C:\Dev's\app.exe"
            $runner = Get-Content -LiteralPath $gen.RunnerPath -Raw
            $runner | Should -Match ([regex]::Escape("'C:\Dev''s\app.exe'"))
            { [System.Management.Automation.Language.Parser]::ParseInput($runner, [ref]$null, [ref]$null) } | Should -Not -Throw
        }
    }

    Context 'the generated runner is valid PowerShell' {
        It 'parses without errors' {
            $gen = & $script:script -PackagePath $script:pkg -GenerateOnly
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($gen.RunnerPath, [ref]$null, [ref]$errors) | Out-Null
            @($errors).Count | Should -Be 0
        }
    }
}

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
        # The script derives its work folder from the resolved config home. Without this override the test
        # suite would create - and leave behind - a folder under the REAL %LOCALAPPDATA%\psadt-deploy on
        # whatever machine runs the tests.
        $script:prevHome = $env:PSADT_DEPLOY_HOME
        $env:PSADT_DEPLOY_HOME = Join-Path $script:root 'confighome'
        New-Item -ItemType Directory -Path $env:PSADT_DEPLOY_HOME -Force | Out-Null

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
    AfterEach {
        if ($null -eq $script:prevHome) { Remove-Item Env:\PSADT_DEPLOY_HOME -ErrorAction SilentlyContinue }
        else { $env:PSADT_DEPLOY_HOME = $script:prevHome }
        Remove-TempSkillRoot $script:root
    }

    It 'writes its work folder under the resolved config home, never under a hard-coded path' {
        # Guarantees the PSADT_DEPLOY_HOME override above actually takes effect, so a test run cannot
        # litter the real config home.
        $gen = & $script:script -PackagePath $script:pkg -GenerateOnly
        $gen.SandboxWorkFolder | Should -BeLike "$($env:PSADT_DEPLOY_HOME)*"
    }

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

    Context 'evidence handling and cleanup' {
        BeforeAll {
            $script:sbxSrc = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Invoke-PsadtSandboxTest.ps1')).ProviderPath
            $raw = Get-Content -LiteralPath $script:sbxSrc -Raw
            $tokens = $null
            [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$tokens, [ref]$null) | Out-Null
            $b = [System.Text.StringBuilder]::new($raw)
            foreach ($t in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
                $len = $t.Extent.EndOffset - $t.Extent.StartOffset
                [void]$b.Remove($t.Extent.StartOffset, $len); [void]$b.Insert($t.Extent.StartOffset, (' ' * $len))
            }
            $script:sbxCode = $b.ToString()
        }

        It 'copies the evidence into the Output folder, not into the package' {
            # The package folder is what IntuneWinAppUtil packs - test logs must never ship to devices.
            $script:sbxCode | Should -Match "Join-Path \`$outputFolder 'SandboxTest'"
            $script:sbxCode | Should -Not -Match "Join-Path \`$PackagePath 'SandboxTest'"
        }

        It 'removes the scratch work folder only after the evidence is copied out' {
            # The guard on $evidenceFolder is what keeps a failed run investigable.
            $script:sbxCode | Should -Match '-not \$KeepWorkFolder -and \$evidenceFolder'
            $script:sbxCode | Should -Match 'Remove-Item -LiteralPath \$workRoot -Recurse -Force'
        }

        It 'offers -KeepWorkFolder for the investigate-by-hand case' {
            (Get-Command $script:sbxSrc).Parameters.Keys | Should -Contain 'KeepWorkFolder'
        }

        It 'records the copied logs in the manifest' {
            $script:sbxCode | Should -Match "'artifacts.logs'"
        }

        It 'has the guest shut ITSELF down' {
            # Not interchangeable with a host-side kill: only a guest-initiated shutdown tears the VM down
            # cleanly, so vmmemWindowsSandbox exits and releases the mapped folder. Killing the VM from the
            # host orphans that worker and the work folder stays locked for minutes (measured 2026-09-06).
            $gen = & $script:script -PackagePath $script:pkg -GenerateOnly
            $raw = Get-Content -LiteralPath $gen.RunnerPath -Raw
            $tk = $null
            [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$tk, [ref]$null) | Out-Null
            $sb = [System.Text.StringBuilder]::new($raw)
            foreach ($t in @($tk | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
                $len = $t.Extent.EndOffset - $t.Extent.StartOffset
                [void]$sb.Remove($t.Extent.StartOffset, $len); [void]$sb.Insert($t.Extent.StartOffset, (' ' * $len))
            }
            $sb.ToString() | Should -Match 'shutdown\.exe /s /t 0'
        }

        It 'kills the viewer from the host so no connection-lost dialog is left behind' {
            $script:sbxCode | Should -Match 'function Stop-SandboxInstance'
            $script:sbxCode | Should -Match "'WindowsSandboxRemoteSession', 'WindowsSandboxClient', 'WindowsSandbox'"
        }

        It 'never kills WindowsSandboxServer, which supervises the VM teardown' {
            $script:sbxCode | Should -Not -Match "foreach \(\$name in 'WindowsSandboxRemoteSession', 'WindowsSandboxClient', 'WindowsSandbox', 'WindowsSandboxServer'\)"
        }

        It 'waits for the VM worker, not for the viewer' {
            # vmmemWindowsSandbox does not match 'WindowsSandbox*' and is the process holding the mapped folder.
            $script:sbxCode | Should -Match "'vmmemWindowsSandbox', 'WindowsSandboxServer'"
        }

        It 'does not wait on vmwp, which is shared with every other Hyper-V guest' {
            $script:sbxCode | Should -Not -Match "Get-Process -Name 'vmwp'"
        }

        It 'terminates the viewer instead of asking it to close politely' {
            # WM_CLOSE makes Windows Sandbox prompt "are you sure - all contents will be discarded", which an
            # unattended run must never produce. Discarding is the point, and the evidence is already copied.
            $script:sbxCode | Should -Match 'Stop-Process -Force'
            $script:sbxCode | Should -Not -Match 'CloseMainWindow'
        }

        It 'retries the cleanup, because the mapped-folder handle outlives the guest' {
            # The files delete while the directory itself stays locked for a few seconds after shutdown.
            $script:sbxCode | Should -Match 'foreach \(\$attempt in 1\.\.10\)'
        }

        It 'tells a host timeout apart from a guest that finished on its own' {
            # Three terminal states, and they are NOT interchangeable: DONE.txt written (the guest shut
            # itself down), the VM gone without DONE.txt, and the HOST giving up while the guest is still
            # working. Only the third one must keep its hands off the VM.
            $script:sbxCode | Should -Match '\$hostTimedOut'
        }

        It 'leaves the VM alone on a host timeout instead of orphaning the worker' {
            # The script's own reasoning: a host-side kill orphans vmmemWindowsSandbox, which then holds the
            # work folder open until a reboot. Killing the viewer on the timeout path ALSO removes the only
            # way the user could still shut the guest down cleanly - the window is gone.
            $script:sbxCode | Should -Match 'if \(\$hostTimedOut\)'
            $script:sbxCode | Should -Match 'elseif \(-not \(Stop-SandboxInstance'
        }

        It 'never states a timeout the code does not actually wait' {
            # The warning claimed "60 seconds" while Stop-SandboxInstance waited 180 - a literal in a
            # message duplicating a default. One source, interpolated into both.
            $script:sbxCode | Should -Not -Match 'within 60 seconds'
            $script:sbxCode | Should -Match '\$sandboxStopTimeoutSeconds'
        }

        It 'does not advise closing a window it has already killed' {
            # The old timeout warning said "close the window by hand" AFTER force-killing every viewer
            # process - advice the user cannot act on. The replacement must say why the VM is still there.
            $script:sbxCode | Should -Not -Match 'close the window by hand'
            $script:sbxCode | Should -Match 'orphan'
        }
        It 'reports the work folder from what is on disk, not from what was intended' {
            # A single Remove-Item -ErrorAction SilentlyContinue leaves an empty directory behind AND
            # reports success. The returned value must be a Test-Path result, not a flag.
            $script:sbxCode | Should -Match '\$workFolderRemaining = if \(Test-Path -LiteralPath \$workRoot\)'
            $script:sbxCode | Should -Match 'SandboxWorkFolder = \$workFolderRemaining'
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

Describe 'Invoke-PsadtSandboxTest array parameters' {
    # Same 2026-09-06 binder trap as Invoke-IntuneAppAssignment, but with a nastier failure mode: with
    # "-PathsAbsentAfterInstall a,b" the -File binder passes ONE element, so the second path is never
    # asserted and the run still reports GREEN. A silent loss of coverage beats an error every time.
    BeforeAll {
        $src = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Invoke-PsadtSandboxTest.ps1')).ProviderPath
        $raw = Get-Content -LiteralPath $src -Raw
        $tokens = $null
        [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$tokens, [ref]$null) | Out-Null
        $b = [System.Text.StringBuilder]::new($raw)
        foreach ($t in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
            $len = $t.Extent.EndOffset - $t.Extent.StartOffset
            [void]$b.Remove($t.Extent.StartOffset, $len); [void]$b.Insert($t.Extent.StartOffset, (' ' * $len))
        }
        $script:SbxCode2 = $b.ToString()
    }

    It 'expands comma-separated values for every -Paths* parameter' {
        foreach ($p in 'PathsPresentAfterInstall', 'PathsAbsentAfterInstall', 'PathsAbsentAfterUninstall') {
            $script:SbxCode2 | Should -Match "\`$$p = Expand-CommaSeparated \`$$p"
        }
    }

    It 'defines the expansion helper' {
        $script:SbxCode2 | Should -Match 'function Expand-CommaSeparated'
    }
}

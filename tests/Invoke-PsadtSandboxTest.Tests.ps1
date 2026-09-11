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

    Context 'runner: running an action as SYSTEM' {
        BeforeEach { $script:sysRunner = Get-Content -LiteralPath (& $script:script -PackagePath $script:pkg -GenerateOnly).RunnerPath -Raw }

        It 'keeps the ONCE trigger in the past so it can never fire on its own' {
            # /Run starts the task; the trigger only exists because /Create demands one. A near-future
            # /ST silences the stderr notice by ARMING a real trigger, which can re-launch the same
            # deployment .cmd as SYSTEM while the action is still running.
            $script:sysRunner | Should -Match '/SC ONCE /ST 00:00'
        }

        It 'never formats the start time through the current culture' {
            # 'HH:mm' takes ':' as the culture's TimeSeparator: under fi-FI it renders 15.02, and
            # schtasks rejects that with "Invalid start time value" and creates no task at all.
            $script:sysRunner | Should -Not -Match "ToString\('HH:mm'\)"
        }

        It 'checks the exit code of both schtasks calls' {
            # Unchecked, any failure to create or start the task presents as the action timing out
            # $actionTimeout seconds later - the one symptom that says nothing about the cause.
            $script:sysRunner | Should -Match "Get-SchtasksFailure -Operation 'Create'"
            $script:sysRunner | Should -Match "Get-SchtasksFailure -Operation 'Run'"
        }

        It 'lowers ErrorActionPreference around the schtasks calls so their stderr cannot abort the run' {
            # The ONCE trigger is deliberately in the past, so schtasks writes "/ST is earlier than
            # current time" to STDERR on EVERY step. In WinPS 5.1 a native command's stderr raises a
            # terminating NativeCommandError whenever $ErrorActionPreference is 'Stop', and a '2>file'
            # redirect does NOT prevent that - it only chooses where the ErrorRecord is written. With
            # the redirect alone the runner died on its very first step: measured on a de-DE host
            # 2026-09-11, verdict ERROR after 0.7 minutes with no action executed.
            # The exit-code checks above remain the real failure signal, so nothing is hidden.
            $createBlock = [regex]::Match($script:sysRunner, "(?s)\&\s*\{[^}]*?schtasks\.exe\s+/Create.*?\}").Value
            $createBlock | Should -Match "ErrorActionPreference\s*=\s*'Continue'"

            $runBlock = [regex]::Match($script:sysRunner, "(?s)\&\s*\{[^}]*?schtasks\.exe\s+/Run.*?\}").Value
            $runBlock | Should -Match "ErrorActionPreference\s*=\s*'Continue'"

            $deleteBlock = [regex]::Match($script:sysRunner, "(?s)\&\s*\{[^}]*?schtasks\.exe\s+/Delete.*?\}").Value
            $deleteBlock | Should -Match "ErrorActionPreference\s*=\s*'Continue'"
        }

        It 'guards the guest shutdown against the same stderr trap' {
            # shutdown.exe is the LAST statement of the run and the one that tears the VM down. If its
            # stderr raised a terminating error, the guest would never shut itself down, the
            # vmmemWindowsSandbox worker would keep the mapped folder open, and the NEXT run would be
            # refused - Windows permits exactly one sandbox instance. Observed as an orphaned VM on
            # 2026-09-11, which blocked the re-run until it was cleaned up by hand.
            $shutdownBlock = [regex]::Match($script:sysRunner, "(?s)\&\s*\{[^}]*?shutdown\.exe.*?\}").Value
            $shutdownBlock | Should -Match "ErrorActionPreference\s*=\s*'Continue'"
        }

        It 'fails fast when the runner was handed a filtered token' {
            # schtasks /RU SYSTEM /RL HIGHEST needs the full administrator token.
            $script:sysRunner | Should -Match 'WindowsBuiltInRole\]::Administrator'
            $script:sysRunner | Should -Match 'not elevated'
        }

        It 'proves a SYSTEM task actually RUNS before spending the full loop on it' {
            # Elevation is necessary but not sufficient, and that gap cost a whole afternoon on
            # 2026-09-11: a Startup-folder-launched runner passed the IsInRole check yet could not make
            # the Task Scheduler run anything - schtasks returned exit 0 and the task never executed, so
            # all seven actions timed out identically and the evidence pointed at the package.
            # The canary answers the only question that matters, in seconds rather than hours.
            $script:sysRunner | Should -Match "Label 'SystemTaskCanary'"
            $script:sysRunner | Should -Match 'whoami\.exe'
            $script:sysRunner | Should -Match "notmatch '\(\?i\)system'"
            # and it must name the harness, not the package, as the culprit
            $script:sysRunner | Should -Match 'HARNESS/environment fault'
        }

        It 'lays down missing PowerShell module resources in the guest before the first PSADT import' {
            # Measured 2026-09-11: the sandbox image lacked de-DE\ArchiveResources.psd1 for
            # Microsoft.PowerShell.Archive, which PSADT imports at load. WinPS 5.1 throws instead of
            # falling back, so every launcher exited 60008 with no log - on every package, not just one.
            $script:sysRunner | Should -Match 'ps-module-resources'
            $script:sysRunner | Should -Match "Add-Step 'GuestPrepare'"
            # the shim must run BEFORE the package is copied and any toolkit import happens
            $script:sysRunner.IndexOf("Add-Step 'GuestPrepare'") | Should -BeLessThan $script:sysRunner.IndexOf('Copy-Item -LiteralPath $pkgSrc')
        }

        It 'repairs WMI for SYSTEM before the first PSADT session is opened' {
            # Measured 2026-09-11: Initialize-ADTModule queries Win32_ComputerSystem and the guest
            # answered 0x80070005 for SYSTEM, so Open-ADTSession threw - 60008 on every action, even
            # after the module import itself had been fixed. The repository holds the namespace ACLs.
            $script:sysRunner | Should -Match 'Win32_ComputerSystem'
            $script:sysRunner | Should -Match 'Winmgmt'
            $script:sysRunner | Should -Match 'salvage'
            $script:sysRunner | Should -Match 'resetrepository|/\$\{attempt\}repository'
            $script:sysRunner | Should -Match 'wmi = \$wmiState'
        }

        It 'imports the package toolkit AND opens a session once as SYSTEM, stopping with the real error text' {
            # Invoke-AppDeployToolkit.exe swallows the .ps1 stderr, so an import or session failure is
            # otherwise a bare 60008 on every action. Two stages, because they failed for two different
            # reasons on the same day (missing localized resource, then WMI access denied).
            $script:sysRunner | Should -Match "Label 'PsadtModuleCanary'"
            $script:sysRunner | Should -Match 'PSADT_MODULE_OK'
            $script:sysRunner | Should -Match 'Open-ADTSession'
            $script:sysRunner | Should -Match 'PSADT_SESSION_OK'
            $script:sysRunner | Should -Match 'Real error'
            # the canary's own log must not end up in the package evidence
            $script:sysRunner | Should -Match 'PsadtSandboxCanary\.log'
            $script:sysRunner | Should -Match 'Remove-Item -LiteralPath \(Join-Path \$env:WinDir .Logs\\Software\\PsadtSandboxCanary\.log'
            # and it runs after the copy (it imports from the copied package) but before the first action
            $script:sysRunner.IndexOf("Label 'PsadtModuleCanary'") | Should -BeGreaterThan $script:sysRunner.IndexOf('Copy-Item -LiteralPath $pkgSrc')
            $script:sysRunner.IndexOf("Label 'PsadtModuleCanary'") | Should -BeLessThan $script:sysRunner.IndexOf("Invoke-Deployment -Label 'Install'")
        }

        It 'ships the host''s module culture resources in the work folder' {
            $hostArchive = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\Modules\Microsoft.PowerShell.Archive'
            $hostCultures = @(Get-ChildItem -LiteralPath $hostArchive -Directory -ErrorAction SilentlyContinue | Where-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.psd1' -File -ErrorAction SilentlyContinue })
            if ($hostCultures.Count -eq 0) { Set-ItResult -Skipped -Because 'this host has no culture resource folder for Microsoft.PowerShell.Archive'; return }
            $gen = & $script:script -PackagePath $script:pkg -GenerateOnly
            foreach ($c in $hostCultures) {
                (Join-Path $gen.SandboxWorkFolder "ps-module-resources\Microsoft.PowerShell.Archive\$($c.Name)\ArchiveResources.psd1") | Should -Exist
            }
        }

        It 're-runs a 60008 action once through powershell.exe to capture the stderr the .exe discards' {
            # 60008 = the launcher's Initialization block threw: nothing was deployed, no PSADT log exists,
            # and Invoke-AppDeployToolkit.exe swallowed the .ps1's stderr. Re-running via -File is
            # side-effect-free in that case and is the ONLY way the real error text reaches result.json.
            $script:sysRunner | Should -Match '\$r\.ExitCode -eq 60008'
            $script:sysRunner | Should -Match 'Invoke-AppDeployToolkit\.ps1'
            $script:sysRunner | Should -Match '\.Diagnostic'
            $script:sysRunner | Should -Match 'step\.diagnostic'
            # 60001 must NOT trigger it - the hook already ran and a re-run would deploy twice
            $script:sysRunner | Should -Not -Match '-eq 60001'
        }

        It 'shows a heartbeat while a SYSTEM action runs' {
            # A SYSTEM scheduled task draws nothing on the guest desktop, so without this the VM looks
            # frozen for minutes during a healthy install - indistinguishable from a hang to anyone
            # watching the sandbox window.
            $script:sysRunner | Should -Match 'still running'
            $script:sysRunner | Should -Match 'WindowTitle'
        }

        It 'retries a captured output that reads back empty' {
            # A transiently unreadable .out file (Defender scanning it) is otherwise indistinguishable
            # from a detection script reporting "absent".
            $script:sysRunner | Should -Match 'for \(\$i = 0; \$i -lt 3; \$i\+\+\)'
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

        It 'starts the runner through LogonCommand' {
            # 0.28.0 swapped LogonCommand for a Startup-folder trigger to dodge
            # microsoft/Windows-Sandbox#125 (LogonCommand never spawns on some Sandbox app versions).
            # Measured on 2026-09-11, that trade is a bad one wherever LogonCommand works: a
            # Startup-launched runner inherits Explorer's token, and with it schtasks /Create and /Run
            # both return exit 0 while the task NEVER executes (and the ScheduledTasks cmdlets are
            # refused with "Cannot connect to CIM server. Access denied"). Every action then times out
            # blaming the package. #125 is caught by the host's DONE.txt timeout instead.
            $xml = [xml](Get-Content -LiteralPath $script:gen.WsbPath -Raw)
            $xml.Configuration.LogonCommand.Command | Should -Match 'Run-PsadtSandboxTest\.ps1'
        }

        It 'does not hide the guest console window' {
            # The console is the only visible sign of life in the VM: every deployment action runs as
            # SYSTEM via a scheduled task and draws nothing on the desktop.
            $xml = [xml](Get-Content -LiteralPath $script:gen.WsbPath -Raw)
            $xml.Configuration.LogonCommand.Command | Should -Not -Match '(?i)-WindowStyle\s+Hidden'
        }

        It 'leaves the work folder at its default desktop mapping' {
            # No SandboxFolder override: the guest sees it as C:\Users\WDAGUtilityAccount\Desktop\<leaf>,
            # which is where the runner template and the LogonCommand both expect it.
            $xml = [xml](Get-Content -LiteralPath $script:gen.WsbPath -Raw)
            $folders = @($xml.Configuration.MappedFolders.MappedFolder)
            $work = $folders | Where-Object { $_.HostFolder -like '*_PsadtSandboxTest' }
            $work.SandboxFolder | Should -BeNullOrEmpty
            $script:gen.RunnerPath | Should -Match '_PsadtSandboxTest.Run-PsadtSandboxTest\.ps1$'
        }

        It 'waits before starting the runner only when a settle delay was asked for' {
            $xml = [xml](Get-Content -LiteralPath $script:gen.WsbPath -Raw)
            $xml.Configuration.LogonCommand.Command | Should -Not -Match 'ping\.exe'

            $delayed = & $script:script -PackagePath $script:pkg -GenerateOnly -GuestSettleDelaySeconds 20
            $dx = [xml](Get-Content -LiteralPath $delayed.WsbPath -Raw)
            # ping, not timeout: timeout aborts without a console it owns.
            $dx.Configuration.LogonCommand.Command | Should -Match 'ping\.exe -n 21 127\.0\.0\.1'
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

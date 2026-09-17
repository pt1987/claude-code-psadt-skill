# SCOPE NOTE: the guest progress window, and the JSON it lives on.
#
# This window is the only thing an operator can see while the sandbox works, and it runs where nothing
# reports back: inside a VM, started by <LogonCommand>, under Windows PowerShell 5.1. A fault here does
# not throw anywhere a human is looking - it shows an empty window, or no window, and the run looks
# hung. So the cheap, mechanical faults are caught here instead.
#
# The two that actually happened, both on 2026-09-14, in the drafts this window was ported from:
#   * the .ps1 carried non-ASCII bytes with no BOM. Windows PowerShell 5.1 reads such a file as
#     Windows-1252, an em-dash inside a double-quoted string terminated it early, and the script had
#     FOUR parse errors - it could never have run in the guest at all (App. B.1/B.2);
#   * the .xaml set Style twice on one element, as an attribute AND as a <TextBlock.Style> child, so
#     XamlReader threw before the window existed.
# Neither is visible by reading the file, and both are one line to fix once named.

BeforeAll {
    $script:scriptDir = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts')).ProviderPath
    $script:uiPs1 = Join-Path $script:scriptDir '_SandboxProgressUi.ps1'
    $script:uiXaml = Join-Path $script:scriptDir '_SandboxProgressUi.xaml'
    $script:harness = Join-Path $script:scriptDir 'Invoke-PsadtSandboxTest.ps1'

    # WPF needs an STA thread and pwsh 7 is MTA by default, so the XAML is loaded in a child
    # powershell.exe -STA rather than skipped - the guest runs it under exactly that host anyway.
    function Invoke-Sta {
        param([string]$Command)
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $ps -NoProfile -STA -ExecutionPolicy Bypass -Command $Command 2>&1 | Out-String
    }
}

Describe 'the guest window can actually start in the guest' {

    It 'ships both halves' {
        Test-Path -LiteralPath $script:uiPs1 | Should -BeTrue
        Test-Path -LiteralPath $script:uiXaml | Should -BeTrue
    }

    It 'is 7-bit ASCII on both halves' -ForEach @(
        @{ Which = 'ps1' }
        @{ Which = 'xaml' }
    ) {
        $path = if ($Which -eq 'ps1') { $script:uiPs1 } else { $script:uiXaml }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $high = @($bytes | Where-Object { $_ -gt 127 })
        $high.Count | Should -Be 0 -Because 'WinPS 5.1 reads a BOM-less file as Windows-1252 and an em-dash in a double-quoted string ends it early'
    }

    It 'parses under Windows PowerShell' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:uiPs1, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }

    It 'loads its XAML and finds every element the script asks for' {
        # Anti-vacuity is built in: the script's own FindName list is the source of the names, so a
        # renamed element fails here rather than producing a window with dead controls.
        $text = Get-Content -LiteralPath $script:uiPs1 -Raw
        $block = [regex]::Match($text, "(?s)foreach \(\`$n in ('.*?')\) \{\s*\`$ui\[\`$n\] = \`$win\.FindName").Groups[1].Value
        $names = @([regex]::Matches($block, "'([A-Za-z_][A-Za-z0-9_]*)'") | ForEach-Object { $_.Groups[1].Value })
        $names.Count | Should -BeGreaterOrEqual 15 -Because 'the FindName list is what this test reads; an empty match would pass vacuously'

        $cmd = @"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
`$x = [System.IO.File]::ReadAllText('$($script:uiXaml)', (New-Object System.Text.UTF8Encoding(`$false)))
`$w = [System.Windows.Markup.XamlReader]::Parse(`$x)
$(($names | ForEach-Object { "if (-not `$w.FindName('$_')) { Write-Output 'MISSING $_' }" }) -join "`n")
Write-Output 'PARSED'
"@
        $out = Invoke-Sta $cmd
        $out | Should -Match 'PARSED' -Because "XamlReader must not throw. Output was: $out"
        $out | Should -Not -Match 'MISSING' -Because "every name the script looks up must exist. Output was: $out"
    }

    It 'never sets Style twice on one element' {
        # The exact defect that made the imported draft throw: Style="{StaticResource X}" as an
        # attribute on an element that also carries a <Tag.Style> child.
        $xaml = Get-Content -LiteralPath $script:uiXaml -Raw
        # A self-closing element has no children, so a <Tag.Style> further down belongs to a SIBLING.
        # Matching that would fail on perfectly legal markup - which is what the first draft of this test
        # did. Only an element that stays open can carry both forms, and only inside its own scope.
        $bad = foreach ($m in [regex]::Matches($xaml, '<(\w+)(?![^>]*/>)([^>]*?\sStyle="\{[^"]*\}"[^>]*?)>')) {
            $tag = $m.Groups[1].Value
            $tail = $xaml.Substring($m.Index + $m.Length, [Math]::Min(400, $xaml.Length - $m.Index - $m.Length))
            $ownEnd = $tail.IndexOf("</$tag>")
            $scope = if ($ownEnd -ge 0) { $tail.Substring(0, $ownEnd) } else { $tail }
            if ($scope -match "<$tag\.Style>") { $tag }
        }
        @($bad) -join ', ' | Should -BeNullOrEmpty
    }

    It 'never writes a property as an attribute that its own triggers are meant to change' {
        # WPF precedence: a LOCAL value beats a style trigger. An element with Background="..." written as
        # an attribute, plus a <Tag.Style> whose DataTriggers set Background, renders the attribute and
        # ignores every trigger - silently, with no error anywhere.
        # Measured 2026-09-14 on the imported XAML: the phase marker rendered #FF0A2F29 for Pending,
        # Running, Done AND Failed alike, so a failed phase was indistinguishable from a passed one. The
        # defaults belong in the Style as Setters, where a trigger can override them.
        $xaml = Get-Content -LiteralPath $script:uiXaml -Raw
        $props = 'Background', 'BorderBrush', 'Foreground', 'Text', 'Opacity'
        $bad = foreach ($m in [regex]::Matches($xaml, '<(\w+)(?![^>]*/>)([^>]*)>')) {
            $tag = $m.Groups[1].Value
            $attrs = $m.Groups[2].Value
            $tail = $xaml.Substring($m.Index + $m.Length)
            $close = $tail.IndexOf("</$tag>")
            $scope = if ($close -ge 0) { $tail.Substring(0, $close) } else { $tail.Substring(0, [Math]::Min(1200, $tail.Length)) }
            $sm = [regex]::Match($scope, "(?s)<$tag\.Style>(.*?)</$tag\.Style>")
            if (-not $sm.Success -or $sm.Groups[1].Value -notmatch '<Style\.Triggers>') { continue }
            foreach ($prop in $props) {
                if ($attrs -match "\s$prop=`"" -and $sm.Groups[1].Value -match "<Setter Property=`"$prop`"") {
                    "$tag.$prop"
                }
            }
        }
        @($bad) -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'the window stays passive' {

    It 'never writes anything and never touches the package' {
        # It is a read-only observer of a run happening in another process. A window that deletes, writes
        # or launches deployment work could turn a diagnostic into the cause of a failure.
        $text = Get-Content -LiteralPath $script:uiPs1 -Raw
        $text | Should -Not -Match '\bRemove-Item\b'
        $text | Should -Not -Match '\bSet-Content\b'
        $text | Should -Not -Match '\bNew-Item\b'
        # The single permitted launch: the operator opening the transcript in notepad.
        $starts = @([regex]::Matches($text, 'Start-Process\s+(\S+)') | ForEach-Object { $_.Groups[1].Value })
        ($starts | Where-Object { $_ -ne 'notepad.exe' }) -join ', ' | Should -BeNullOrEmpty
    }

    It 'takes its phase list from the JSON rather than a hardcoded one' {
        # A list baked into the window goes stale the moment -Scenarios changes the run, and then it
        # shows phases that will never execute. The runner derives the plan; this only renders it.
        $text = Get-Content -LiteralPath $script:uiPs1 -Raw
        $text | Should -Match '\$phases = @\(\$p\.phases\)'
        $text | Should -Not -Match "'DetectionAfterInstall'"
        $text | Should -Not -Match "'FinalUninstall'"
    }
}

Describe 'the runner publishes the phase plan the window renders' {

    BeforeAll {
        # The runner is a here-string template inside the harness, so it is extracted and exercised
        # rather than trusted. Only the progress block is taken - enough to produce a real progress.json.
        $src = Get-Content -LiteralPath $script:harness -Raw
        $tpl = [regex]::Match($src, "(?s)\`$runnerTemplate = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
        # Pulled out by NAME through the AST, not by a byte range between two anchors. A range picks up
        # whatever happens to sit in between - here that included a `continue` outside any loop, and
        # Pester aborts an entire block on that instead of reporting it (pester#2669).
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($tpl, [ref]$null, [ref]$null)
        $wanted = 'Initialize-PhasePlan', 'Add-PhaseLine', 'Set-Progress', 'Add-Step', 'Get-PhaseLabel'
        $funcs = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name
            }, $true)
        $script:progressBlock = (@('$script:phaseOrder = @()', '$script:phaseData = @{}') +
            @($funcs | ForEach-Object { $_.Extent.Text })) -join [Environment]::NewLine

        $script:out = Join-Path $TestDrive 'progress.json'
        $scenarios = @('Install', 'Uninstall', 'Repair')
        $progressFile = $script:out
        $script:progressPackage = 'Demo_App_1.0_x64'
        $script:report = [ordered]@{ steps = @() }

        . ([scriptblock]::Create($script:progressBlock))
        Initialize-PhasePlan -Scenarios $scenarios

        Set-Progress -Step 'Install' -State 'running as SYSTEM' -Elapsed 12 -Timeout 600
        Add-Step 'Install' @{ exitCode = 0; timedOut = $false; success = $true; seconds = 157 }
        Add-Step 'DetectionAfterInstall' @{ stdout = 'found it'; exitCode = 0; detected = $true; timedOut = $false }
        Add-Step 'Repair' @{ exitCode = 1603; timedOut = $false; success = $false; seconds = 30 }
        # A pre-check reports no seconds of its own. It still has to show a duration.
        Add-Step 'Elevation' @{ elevated = $true; identity = 'WDAGUtilityAccount' }
        Set-Progress -Step 'Uninstall' -State 'running as SYSTEM' -Timeout 600

        $script:json = Get-Content -LiteralPath $script:out -Raw | ConvertFrom-Json
        $script:phases = @($script:json.phases)
    }

    It 'still finds the progress block in the runner template' {
        # Guards the extraction above: if it stops matching, every assertion below would pass on nothing.
        $script:progressBlock | Should -Not -BeNullOrEmpty
        $script:progressBlock | Should -Match 'function Set-Progress'
        $script:progressBlock | Should -Match 'function Add-Step'
    }

    It 'sizes the plan from the scenarios instead of a fixed number' {
        # Five pre-checks + Install/Detection + one pair per chosen scenario. The count this file used to
        # publish was a hardcoded 14, which was wrong for every partial run AND for the full gate (15).
        $script:phases.Count | Should -Be 11
        $script:json.total | Should -Be 11
        @($script:phases | Where-Object { $_.name -like 'DetectionAfterReinstall' }).Count |
            Should -Be 0 -Because 'Reinstall was not among the scenarios'
    }

    It 'gives every phase the fields the detail panel binds' {
        foreach ($ph in $script:phases) {
            foreach ($key in 'name', 'status', 'exitCode', 'seconds', 'started', 'ended', 'timeout', 'detection', 'logTail') {
                $ph.PSObject.Properties.Name | Should -Contain $key -Because "phase $($ph.name) must carry $key"
            }
        }
    }

    It 'records how each phase ended' {
        $by = @{}
        foreach ($ph in $script:phases) { $by[$ph.name] = $ph }

        $by['Install'].status | Should -Be 'done'
        $by['Install'].exitCode | Should -Be 0
        $by['Install'].seconds | Should -Be 157
        $by['Install'].timeout | Should -Be 600
        $by['Install'].started | Should -Not -BeNullOrEmpty
        $by['Install'].ended | Should -Not -BeNullOrEmpty

        $by['Repair'].status | Should -Be 'failed' -Because 'success=$false must not be rendered as a pass'
        $by['Repair'].exitCode | Should -Be 1603

        # A pre-check supplies no seconds of its own; it is timed from the end of the phase before, so the
        # window shows a duration for every row rather than a dash on the five that start the run.
        $by['Elevation'].PSObject.Properties.Name | Should -Contain 'seconds'
        $by['Elevation'].seconds | Should -Not -BeNullOrEmpty
        [int]$by['Elevation'].seconds | Should -BeGreaterOrEqual 0

        $by['DetectionAfterInstall'].detection | Should -Be 'found'
        $by['Uninstall'].status | Should -Be 'running'
        $by['DetectionAfterUninstall'].status | Should -Be 'pending'
    }

    It 'keeps a transcript per phase' {
        $install = @($script:phases | Where-Object { $_.name -eq 'Install' })[0]
        @($install.logTail).Count | Should -BeGreaterThan 0
        (@($install.logTail) -join ' ') | Should -Match 'exitCode=0'
    }

    It 'keeps the older top-level fields so an older window still works' {
        $script:json.package | Should -Be 'Demo_App_1.0_x64'
        $script:json.PSObject.Properties.Name | Should -Contain 'completed'
        $script:json.PSObject.Properties.Name | Should -Contain 'updated'
        $script:json.PSObject.Properties.Name | Should -Contain 'verdict'
    }
}

Describe 'the harness delivers both halves into the guest' {

    It 'copies the XAML next to the script' {
        # The window is one file plus its markup since 0.31.0. Copying only the script leaves the guest
        # throwing on its first read and the operator back at a blank desktop.
        $src = Get-Content -LiteralPath $script:harness -Raw
        $src | Should -Match "_SandboxProgressUi\.xaml"
        $src | Should -Match "Copy-Item -LiteralPath \`$progressUiXaml"
    }
}

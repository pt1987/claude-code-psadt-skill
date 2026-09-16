# SCOPE NOTE: this script is the gate on the Phase 2 research fan-out, so the tests that matter are
# about the NUMBER it reports and about what it refuses to do on its own.
#
# Three rules are enforced here as behaviour, not as prose:
#   - AgentBudget IS the dispatch cap. OpenQuestions must contain only questions that are Open AND
#     worth an agent; anything answerable by dropping the binary in Files\, or by the Phase 6 probe
#     run, belongs in Deferred. A question that leaked into OpenQuestions authorises an agent, and
#     authorising agents nobody needed is the 400k-token failure this script exists to stop.
#   - It COMPOSES the existing probes, it does not reimplement them. Source guards assert that it
#     calls Get-PsadtSwitchCandidates.ps1 and Get-PsadtMsiFacts.ps1, that it does NOT call
#     Get-PsadtInstallerEngine.ps1 a second time (switch-candidates already ran it, and a second
#     whole-file scan of a vendor bootstrapper is the bug), and that no engine marker or MSI COM call
#     appears in its own source.
#   - The gate itself is deterministic. No network call on any path, ever - carried over verbatim from
#     Get-PsadtSwitchCandidates.Tests.ps1. A vendor doc URL is NAMED and handed back; fetching it is
#     the orchestrator's job, so that a proxy or an air-gapped packaging VM cannot make the gate look
#     broken.
#
# Rung 1 reads the Uninstall registry, which nothing else in this suite touches. It is pointed at
# Pester's TestRegistry: drive through -UninstallRoots - that parameter exists for this seam. Without
# it the tests would read (and their assertions would depend on) whatever happens to be installed on
# the machine running them.

BeforeAll {
    . "$PSScriptRoot/_helpers.ps1"
    $script:src = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Get-PsadtLocalEvidence.ps1')).ProviderPath
    $script:made = New-Object System.Collections.Generic.List[string]
    function Track([string]$p) { $script:made.Add($p); return $p }

    # Source guards match against the CODE with comments blanked out. Matching raw source would flag
    # the comment in which the script explains the very trap it avoids. Same idiom as the sibling.
    $raw = Get-Content -LiteralPath $script:src -Raw
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$tokens, [ref]$null) | Out-Null
    $builder = [System.Text.StringBuilder]::new($raw)
    foreach ($t in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $len = $t.Extent.EndOffset - $t.Extent.StartOffset
        [void]$builder.Remove($t.Extent.StartOffset, $len)
        [void]$builder.Insert($t.Extent.StartOffset, (' ' * $len))
    }
    $script:code = $builder.ToString()

    # Builds one Add/Remove-Programs row under whatever root is passed in.
    function New-ArpKey {
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Name, [hashtable]$Values = @{})
        $p = Join-Path $Root $Name
        if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }
        foreach ($k in $Values.Keys) { New-ItemProperty -Path $p -Name $k -Value $Values[$k] -Force | Out-Null }
        return $p
    }
}

AfterAll {
    foreach ($p in $script:made) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-PsadtLocalEvidence' {

    BeforeEach {
        # The ladder calls Get-PsadtSwitchCandidates.ps1, which resolves the verified-switch store
        # through the config home. Without the redirect the suite would create one under the real
        # %LOCALAPPDATA%\psadt-deploy (rule:config-home).
        $script:oldHome = $env:PSADT_DEPLOY_HOME
        $script:tempHome = Join-Path ([System.IO.Path]::GetTempPath()) ('ev_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tempHome -Force | Out-Null
        $env:PSADT_DEPLOY_HOME = $script:tempHome
        $script:reg = 'TestRegistry:\Uninstall'
        New-Item -Path $script:reg -Force | Out-Null
    }

    AfterEach {
        $env:PSADT_DEPLOY_HOME = $script:oldHome
        if ($script:tempHome -and (Test-Path $script:tempHome)) {
            Remove-Item $script:tempHome -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'guards' {
        It 'throws when given nothing to go on' {
            # A run with no inputs would return every question Open and authorise an agent for each -
            # eight agents from an empty prompt, which is worse than the fan-out being replaced.
            { & $script:src -UninstallRoots $script:reg } | Should -Throw -ExpectedMessage '*Nothing to go on*'
        }

        It 'does NOT throw when the installer does not exist yet' {
            # Deliberately unlike the sibling probes. Phase 1 routinely runs before the binary is in
            # Files\, and a ladder that cannot run then is a ladder nobody runs.
            { & $script:src -Path 'C:\nope\missing.exe' -ProductName 'X' -UninstallRoots $script:reg } |
                Should -Not -Throw
        }

        It 'reports InstallerPresent false and a rung-2 miss naming the path' {
            $r = & $script:src -Path 'C:\nope\missing.exe' -ProductName 'X' -UninstallRoots $script:reg
            $r.InstallerPresent | Should -BeFalse
            $miss = @($r.Rungs | Where-Object { $_.Rung -eq 2 }).Misses
            ($miss.Reason -join ' ') | Should -Match 'missing\.exe'
        }
    }

    Context 'rung 1 - is it already installed here' {
        It 'matches on DisplayName plus DisplayVersion and calls that verified' {
            New-ArpKey -Root $script:reg -Name 'Acme_is1' -Values @{
                DisplayName = 'Acme Reader'; DisplayVersion = '3.1.0'; Publisher = 'Acme'
            } | Out-Null
            $r = & $script:src -ProductName 'Acme Reader' -ProductVersion '3.1.0' -UninstallRoots $script:reg
            @($r.Installed).Count | Should -Be 1
            $r.Installed[0].MatchKind | Should -Be 'name-version'
            $r.Installed[0].MatchConfidence | Should -Be 'verified'
        }

        It 'matches on the ProductCode in the key name' {
            New-ArpKey -Root $script:reg -Name '{11112222-3333-4444-5555-666677778888}' -Values @{
                DisplayName = 'Whatever It Calls Itself'; DisplayVersion = '9.9'
            } | Out-Null
            $r = & $script:src -ProductCode '{11112222-3333-4444-5555-666677778888}' -UninstallRoots $script:reg
            $r.Installed[0].MatchKind | Should -Be 'product-code'
            $r.Installed[0].ProductCodeGuid | Should -Be '{11112222-3333-4444-5555-666677778888}'
        }

        It 'reports the full key path, so a human can re-check the finding' {
            New-ArpKey -Root $script:reg -Name 'Acme_is1' -Values @{ DisplayName = 'Acme Reader'; DisplayVersion = '3.1.0' } | Out-Null
            $r = & $script:src -ProductName 'Acme Reader' -ProductVersion '3.1.0' -UninstallRoots $script:reg
            $r.Installed[0].KeyPath | Should -Match 'Acme_is1$'
        }

        It 'carries QuietUninstallString verbatim, quotes and spaces intact' {
            # Re-quoting a path with spaces is how a wrong uninstall command ships. The caller gets the
            # original and does its own splitting.
            $q = '"C:\Program Files\Acme Reader\unins000.exe" /SILENT /NORESTART'
            New-ArpKey -Root $script:reg -Name 'Acme_is1' -Values @{
                DisplayName = 'Acme Reader'; DisplayVersion = '3.1.0'; QuietUninstallString = $q
            } | Out-Null
            $r = & $script:src -ProductName 'Acme Reader' -ProductVersion '3.1.0' -UninstallRoots $script:reg
            $r.Installed[0].QuietUninstallString | Should -BeExactly $q
        }

        It 'ranks an older build as medium, never verified' {
            New-ArpKey -Root $script:reg -Name 'Acme_is1' -Values @{ DisplayName = 'Acme Reader'; DisplayVersion = '2.0.0' } | Out-Null
            $r = & $script:src -ProductName 'Acme Reader' -ProductVersion '3.1.0' -UninstallRoots $script:reg
            $r.Installed[0].MatchConfidence | Should -Be 'medium'
            $r.Installed[0].MatchDetail | Should -Match 'different build'
        }

        It 'reports both rows and refuses to pick when two match exactly' {
            New-ArpKey -Root $script:reg -Name 'Acme_x64' -Values @{ DisplayName = 'Acme Reader'; DisplayVersion = '3.1.0' } | Out-Null
            New-ArpKey -Root $script:reg -Name 'Acme_x86' -Values @{ DisplayName = 'Acme Reader'; DisplayVersion = '3.1.0' } | Out-Null
            $r = & $script:src -ProductName 'Acme Reader' -ProductVersion '3.1.0' -UninstallRoots $script:reg
            @($r.Installed).Count | Should -Be 2
            $q = @($r.Questions | Where-Object Id -eq 'silent-uninstall')[0]
            ($q.Evidence.Detail -join ' ') | Should -Match 'ambiguous'
        }

        It 'caps the reported rows and says how many it suppressed' {
            1..5 | ForEach-Object {
                New-ArpKey -Root $script:reg -Name "Acme_$_" -Values @{ DisplayName = 'Acme Reader'; DisplayVersion = '3.1.0' } | Out-Null
            }
            $r = & $script:src -ProductName 'Acme Reader' -ProductVersion '3.1.0' -UninstallRoots $script:reg -MaxArpMatches 2
            @($r.Installed).Count | Should -Be 2
            $r.ArpMatchesSuppressed | Should -Be 3
        }

        It 'records a miss with a reason for a root that is not there, and keeps going' {
            New-ArpKey -Root $script:reg -Name 'Acme_is1' -Values @{ DisplayName = 'Acme Reader'; DisplayVersion = '3.1.0' } | Out-Null
            $r = & $script:src -ProductName 'Acme Reader' -ProductVersion '3.1.0' `
                -UninstallRoots @('TestRegistry:\DoesNotExist', $script:reg)
            @($r.Installed).Count | Should -Be 1
            $miss = @($r.Rungs | Where-Object { $_.Rung -eq 1 }).Misses
            ($miss.Reason -join ' ') | Should -Match 'root not present'
        }

        It 'reports a miss with a reason when nothing matches at all' {
            New-ArpKey -Root $script:reg -Name 'Other' -Values @{ DisplayName = 'Something Else'; DisplayVersion = '1.0' } | Out-Null
            $r = & $script:src -ProductName 'Acme Reader' -UninstallRoots $script:reg
            @($r.Installed).Count | Should -Be 0
            $miss = @($r.Rungs | Where-Object { $_.Rung -eq 1 }).Misses
            ($miss.Reason -join ' ') | Should -Match 'no Uninstall row matched'
        }
    }

    Context 'rung 2 - composition, not reimplementation' {
        It 'calls the switch-candidate and MSI probes' {
            $script:code | Should -Match 'Get-PsadtSwitchCandidates\.ps1'
            $script:code | Should -Match 'Get-PsadtMsiFacts\.ps1'
        }

        It 'does NOT call the engine probe a second time' {
            # Get-PsadtSwitchCandidates.ps1 already runs it and republishes Engine/Sha256/IsMsi on its
            # own result. A second call re-scans the whole file - and vendor bootstrappers are large.
            $script:code | Should -Not -Match 'Get-PsadtInstallerEngine\.ps1'
        }

        It 'does not reimplement engine detection' {
            'NullsoftInst', 'i4jparams', 'ISSetupStream', 'WixBundle' | ForEach-Object {
                $script:code | Should -Not -Match ([regex]::Escape($_))
            }
        }

        It 'does not reimplement MSI probing' {
            $script:code | Should -Not -Match 'WindowsInstaller\.Installer'
            $script:code | Should -Not -Match 'OpenDatabase'
        }

        It 'leaves a known engine default Provisional, never Closed' {
            # An engine default is the documented default FOR THAT ENGINE, not a fact about this file.
            # Only the probe run promotes it, so the ladder must not spend an agent on it either.
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data (6.2.0)'))
            $r = & $script:src -Path $p -ProductName 'Acme Reader' -UninstallRoots $script:reg
            $q = @($r.Questions | Where-Object Id -eq 'silent-install')[0]
            $q.Status | Should -Be 'Provisional'
            $q.Resolution | Should -Be 'probe-run'
            $r.OpenQuestions.Id | Should -Not -Contain 'silent-install'
        }

        It 'closes the install question for an MSI even when the database probe fails' {
            # The compound-file header is enough to know msiexec owns the command line. A locked or
            # malformed database becomes a recorded miss, not a dead ladder.
            $p = Track (New-TestCfb)
            $r = & $script:src -Path $p -ProductName 'Acme Reader' -UninstallRoots $script:reg
            $q = @($r.Questions | Where-Object Id -eq 'silent-install')[0]
            $q.Status | Should -Be 'Closed'
            $q.Answer | Should -Match 'msiexec'
            @($r.ToolsRun | Where-Object { $_.Script -eq 'Get-PsadtMsiFacts.ps1' }).Ok | Should -BeFalse
        }

        It 'reports the help-output probe as not attempted, and says the sandbox is why' {
            # Running the vendor binary to read its /? output would put vendor code on the packaging
            # host, three phases before the throwaway sandbox that exists for exactly that.
            $p = Track (New-TestPe -Overlay (New-Blob 'Inno Setup Setup Data'))
            $r = & $script:src -Path $p -ProductName 'Acme Reader' -UninstallRoots $script:reg
            $miss = @($r.Rungs | Where-Object { $_.Rung -eq 2 }).Misses
            ($miss | Where-Object { $_.Source -eq 'help-output' }).Reason | Should -Match 'sandbox'
        }
    }

    Context 'the 400k-token case' {
        It 'closes the uninstall question from QuietUninstallString alone, with no installer file at all' {
            # This is the run that started it: three agents dispatched to find a command Windows had
            # been storing in the registry the whole time.
            $q = '"C:\Program Files\Acme Reader\unins000.exe" /SILENT'
            New-ArpKey -Root $script:reg -Name 'Acme_is1' -Values @{
                DisplayName = 'Acme Reader'; DisplayVersion = '3.1.0'; QuietUninstallString = $q
            } | Out-Null
            $r = & $script:src -ProductName 'Acme Reader' -ProductVersion '3.1.0' -UninstallRoots $script:reg
            $u = @($r.Questions | Where-Object Id -eq 'silent-uninstall')[0]
            $u.Status | Should -Be 'Closed'
            $u.Confidence | Should -Be 'verified'
            $u.Answer | Should -BeExactly $q
            $u.ClosedBy | Should -Be 1
            $r.OpenQuestions.Id | Should -Not -Contain 'silent-uninstall'
        }
    }

    Context 'honest closure' {
        It 'never claims the runtime prerequisite or Intune pitfalls can be closed locally' {
            # A statement about other people's fleets does not follow from this machine. Saying so is
            # the difference between a gate and a pretence.
            $r = & $script:src -ProductName 'Acme Reader' -UninstallRoots $script:reg
            foreach ($id in 'runtime-prerequisite', 'intune-pitfalls') {
                $q = @($r.Questions | Where-Object Id -eq $id)[0]
                $q.CanCloseLocally | Should -BeFalse
                $q.Resolution | Should -Be 'dispatch-agent'
            }
        }

        It 'never marks a question Closed on medium or low confidence' {
            $r = & $script:src -ProductName 'Acme Reader' -UninstallRoots $script:reg
            @($r.Questions | Where-Object { $_.Status -eq 'Closed' -and $_.Confidence -in @('medium', 'low', 'none') }).Count |
                Should -Be 0
        }

        It 'gives every closed question at least one evidence entry with a re-checkable SourceRef' {
            New-ArpKey -Root $script:reg -Name 'Acme_is1' -Values @{
                DisplayName = 'Acme Reader'; DisplayVersion = '3.1.0'
                QuietUninstallString = '"C:\x\unins000.exe" /SILENT'
            } | Out-Null
            $r = & $script:src -ProductName 'Acme Reader' -ProductVersion '3.1.0' -UninstallRoots $script:reg
            foreach ($q in @($r.Questions | Where-Object { $_.Status -eq 'Closed' })) {
                @($q.Evidence).Count | Should -BeGreaterThan 0 -Because "$($q.Id) claims to be closed"
                [string]@($q.Evidence)[0].SourceRef | Should -Not -BeNullOrEmpty -Because "$($q.Id) must be re-checkable"
            }
        }
    }

    Context 'the gate' {
        It 'puts only Open plus dispatch-agent questions in OpenQuestions' {
            $r = & $script:src -ProductName 'Acme Reader' -UninstallRoots $script:reg
            foreach ($q in @($r.OpenQuestions)) {
                $q.Status | Should -Be 'Open'
                $q.Resolution | Should -Be 'dispatch-agent'
            }
        }

        It 'reports AgentBudget as exactly the number of open questions' {
            $r = & $script:src -ProductName 'Acme Reader' -UninstallRoots $script:reg
            $r.AgentBudget | Should -Be @($r.OpenQuestions).Count
            $r.Summary.AgentBudget | Should -Be $r.AgentBudget
        }

        It 'defers a question the binary would answer, instead of spending an agent on it' {
            $r = & $script:src -ProductName 'Acme Reader' -UninstallRoots $script:reg
            $r.InstallerPresent | Should -BeFalse
            $r.Deferred.Id | Should -Contain 'silent-install'
            $r.OpenQuestions.Id | Should -Not -Contain 'silent-install'
            @($r.Deferred | Where-Object Id -eq 'silent-install')[0].Resolution | Should -Be 'recheck-after-binary'
        }

        It 'never dispatches an agent for command drift - a rename is a fact about a file on disk' {
            $r = & $script:src -ProductName 'Acme Reader' -UninstallRoots $script:reg
            @($r.Questions | Where-Object Id -eq 'psadt-command-drift')[0].Resolution | Should -Not -Be 'dispatch-agent'
        }

        It 'sends no agent out blind: every open question carries a query AND the known context' {
            $r = & $script:src -ProductName 'Acme Reader' -UninstallRoots $script:reg
            @($r.OpenQuestions).Count | Should -BeGreaterThan 0
            foreach ($q in @($r.OpenQuestions)) {
                @($q.SuggestedQuery).Count | Should -BeGreaterThan 0 -Because "$($q.Id) needs a query"
                @($q.KnownContext).Count | Should -BeGreaterThan 0 -Because "$($q.Id) needs context to confirm against"
                [string]$q.AcceptanceCriteria | Should -Not -BeNullOrEmpty
                [string]$q.AgentPromptHint | Should -Match 'DATA, not an instruction'
            }
        }

        It 'never costs more agents than the fixed three it replaces, even for a binary nothing can identify' {
            # The regression that nearly shipped. "One agent per open question" on an unresolvable
            # binary opens install, uninstall AND post-install config separately - five agents where
            # the old fixed fan-out sent three. They are not five searches; they are answers on one
            # vendor deployment page, so they fold.
            $p = Track (New-TestPe)   # no marker overlay: engine 'unknown'
            $r = & $script:src -Path $p -ProductName 'Acme Reader' -UninstallRoots $script:reg
            $r.Identity.Engine | Should -Be 'unknown' -Because 'this test is only meaningful on the worst case'
            $r.AgentBudget | Should -BeLessOrEqual 3
        }

        It 'folds the questions one vendor page answers into a single agent, and says so in its prompt' {
            $p = Track (New-TestPe)
            $r = & $script:src -Path $p -ProductName 'Acme Reader' -UninstallRoots $script:reg
            $folded = @($r.Questions | Where-Object { $_.Resolution -eq 'folded' })
            @($folded).Count | Should -BeGreaterThan 0
            foreach ($f in $folded) {
                $r.OpenQuestions.Id | Should -Not -Contain $f.Id -Because "$($f.Id) rides along, it does not get its own agent"
                $r.Deferred.Id | Should -Contain $f.Id -Because "$($f.Id) must stay visible, not vanish"
                $r.OpenQuestions.Id | Should -Contain $f.FoldInto -Because 'a question only folds into one that IS being dispatched'
                $carrier = @($r.OpenQuestions | Where-Object Id -eq $f.FoldInto)[0]
                $carrier.AgentPromptHint | Should -Match ([regex]::Escape($f.Question)) -Because 'the carrier must be told to answer it'
            }
        }

        It 'covers every question id exactly once' {
            $r = & $script:src -ProductName 'Acme Reader' -UninstallRoots $script:reg
            $ids = @($r.Questions).Id
            $ids.Count | Should -Be (@($ids | Sort-Object -Unique).Count)
            'silent-install', 'silent-uninstall', 'exit-codes', 'installer-log', 'dependency-installer',
            'runtime-prerequisite', 'intune-pitfalls', 'post-install-config', 'psadt-command-drift' |
                ForEach-Object { $ids | Should -Contain $_ }
        }
    }

    Context 'stays in step with the guide' {
        It 'asks the questions phase 1.3 says to document, word for word' {
            # If the guide table is reworded and the script is not, the dossier and the ladder start
            # describing different things. Comparing the strings is what keeps them one table.
            $guide = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\references\phases-0-6.md')
            $start = (1..$guide.Count | Where-Object { $guide[$_ - 1] -like '*Document the minimal result*' })[0]
            $start | Should -Not -BeNullOrEmpty -Because 'the results table must still exist in 1.3'

            $rows = New-Object System.Collections.Generic.List[string]
            for ($i = $start; $i -lt $guide.Count; $i++) {
                $line = $guide[$i]
                if ($line -notmatch '^\|') { if ($rows.Count -gt 0) { break } else { continue } }
                if ($line -match '^\|\s*-+') { continue }
                $first = ($line -split '\|')[1].Trim()
                if ($first -eq 'Question') { continue }
                $rows.Add($first)
            }
            # Anti-vacuity: a regex that stopped matching would make this test pass on an empty list.
            $rows.Count | Should -BeGreaterOrEqual 8

            $r = & $script:src -ProductName 'Acme Reader' -UninstallRoots $script:reg
            $asked = @($r.Questions).Question
            foreach ($row in $rows) { $asked | Should -Contain $row }
        }
    }

    Context 'reporting, not deciding' {
        It 'never writes the package manifest' {
            $script:code | Should -Not -Match 'Set-PsadtPackageManifest'
        }

        It 'makes no network call on any path' {
            # Carried over from Get-PsadtSwitchCandidates.Tests.ps1. A vendor doc URL is NAMED and
            # handed back; the orchestrator fetches it, so a proxy cannot make the gate look broken.
            $script:code | Should -Not -Match 'Invoke-RestMethod'
            $script:code | Should -Not -Match 'Invoke-WebRequest'
        }

        It 'never writes to the registry' {
            $script:code | Should -Not -Match 'Set-ItemProperty'
            $script:code | Should -Not -Match 'New-ItemProperty'
            $script:code | Should -Not -Match 'Remove-ItemProperty'
        }

        It 'never imports the PSADT module - it reads the manifest, which has no side effects' {
            $script:code | Should -Not -Match 'Import-Module'
            $script:code | Should -Match 'Import-PowerShellDataFile'
        }

        It 'resolves the config home through the sibling scripts, never LOCALAPPDATA directly' {
            $script:code | Should -Not -Match '\$env:LOCALAPPDATA'
        }

        It 'never constructs a vendor URL it was not given' {
            # A URL nobody named is a guess wearing a field name.
            $r = & $script:src -ProductName 'Acme Reader' -Publisher 'Acme' -UninstallRoots $script:reg
            @($r.DocCandidates).Count | Should -Be 0
            $miss = @($r.Rungs | Where-Object { $_.Rung -eq 3 }).Misses
            ($miss.Reason -join ' ') | Should -Match 'guessed URL is not evidence'
        }

        It 'reports every rung it ran, hit or miss' {
            $r = & $script:src -ProductName 'Acme Reader' -UninstallRoots $script:reg
            0, 1, 2, 3 | ForEach-Object { @($r.Rungs).Rung | Should -Contain $_ }
        }

        It 'emits valid JSON under -Json and writes the file under -JsonPath' {
            $out = Track (Join-Path ([System.IO.Path]::GetTempPath()) ('ev_' + [guid]::NewGuid().ToString('N') + '.json'))
            $json = & $script:src -ProductName 'Acme Reader' -UninstallRoots $script:reg -Json -JsonPath $out
            { $json | ConvertFrom-Json } | Should -Not -Throw
            ($json | ConvertFrom-Json).SchemaVersion | Should -Be 1
            Test-Path $out | Should -BeTrue
        }
    }

    Context 'house conventions' {
        It 'is ASCII-clean' {
            $bytes = [System.IO.File]::ReadAllBytes($script:src)
            $body = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF) { $bytes[3..($bytes.Length - 1)] } else { $bytes }
            @($body | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }

        It 'parses without errors' {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($script:src, [ref]$null, [ref]$errors) | Out-Null
            @($errors).Count | Should -Be 0
        }

        It 'never calls exit' {
            (Get-Content -LiteralPath $script:src -Raw) | Should -Not -Match '(?m)^\s*exit\s'
        }
    }
}

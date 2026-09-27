#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SCOPE NOTE: Write-JsonAtomic writes the package manifest, config.json and the verified-switch store,
# and until 0.49.1 it had no tests of its own. Two defects lived in it, both measured, both silent:
#
#   * The commit step was `Move-Item -Force`. When the target is held open by another process, Move-Item
#     raises a NON-terminating error: no exception reached the caller, the finally block deleted the temp
#     file, and the update was gone while every caller believed it had been written. Measured
#     2026-09-26 by holding the file open; the same day a Windows Sandbox run whose VM still had the
#     package folder mapped reported "being used by another process" and the package's
#     psadt-package.json was missing afterwards.
#   * The mutex name was derived with [SHA256]::HashData, which exists only from .NET 5 on. Under Windows
#     PowerShell 5.1 every write threw - including config.json from New-PsadtEntraApp.ps1, a script that
#     promises 5.1 and writes the config only AFTER it has created the app and a secret that is never
#     displayed.

BeforeAll {
    $script:store = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\_JsonStore.ps1')).Path
    . $script:store
}

Describe 'Write-JsonAtomic' {
    BeforeEach {
        $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) ("jsonstore_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        $script:file = Join-Path $script:dir 'psadt-package.json'
    }
    AfterEach {
        if (Test-Path $script:dir) { Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'creates the file when it does not exist yet' {
        Write-JsonAtomic -Path $script:file -Object @{ app = @{ name = 'new' } }
        (Get-Content $script:file -Raw | ConvertFrom-Json).app.name | Should -Be 'new'
    }

    It 'replaces an existing file and leaves no temp file behind' {
        '{"app":{"name":"old"}}' | Set-Content $script:file -Encoding UTF8
        Write-JsonAtomic -Path $script:file -Object @{ app = @{ name = 'new' } }
        (Get-Content $script:file -Raw | ConvertFrom-Json).app.name | Should -Be 'new'
        @(Get-ChildItem $script:dir -Filter '*.tmp').Count | Should -Be 0
    }

    It 'throws, and keeps the original, when another process holds the file open' {
        '{"app":{"name":"original"}}' | Set-Content $script:file -Encoding UTF8
        $h = [System.IO.File]::Open($script:file, 'Open', 'Read', [System.IO.FileShare]::ReadWrite)
        try {
            { Write-JsonAtomic -Path $script:file -Object @{ app = @{ name = 'lost' } } } | Should -Throw
        } finally { $h.Dispose() }
        (Get-Content $script:file -Raw | ConvertFrom-Json).app.name | Should -Be 'original' -Because 'a failed write must not touch what was there'
        @(Get-ChildItem $script:dir -Filter '*.tmp').Count | Should -Be 0
    }

    It 'still replaces the file when the other handle allows deletion' {
        '{"app":{"name":"original"}}' | Set-Content $script:file -Encoding UTF8
        $h = [System.IO.File]::Open($script:file, 'Open', 'Read', ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            Write-JsonAtomic -Path $script:file -Object @{ app = @{ name = 'updated' } }
        } finally { $h.Dispose() }
        (Get-Content $script:file -Raw | ConvertFrom-Json).app.name | Should -Be 'updated'
    }

    It 'writes config.json under Windows PowerShell 5.1, called the way New-PsadtEntraApp.ps1 calls it' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        # 'Stop' is inherited from the bootstrap. Without it the HashData failure only ends one statement,
        # the function limps on with an empty mutex name, and a probe of the bare function passes - which
        # is exactly how this stayed hidden.
        $setter = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Set-PsadtConfig.ps1')).Path
        $cmd = "`$ErrorActionPreference = 'Stop'; & '$setter' -SkillRoot '$script:dir' -Updates @{ 'author.person' = 'ps51' } | Out-Null; 'ok'"
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1
        ($out | Out-String) | Should -Match '(?m)^ok\s*$' -Because "Windows PowerShell 5.1 said: $($out | Out-String)"
        (Get-Content (Join-Path $script:dir 'config.json') -Raw | ConvertFrom-Json).author.person | Should -Be 'ps51'
    }
}

Describe 'Update-JsonAtomic: the read happens inside the lock (0.49.2)' {
    # Write-JsonAtomic serialised the WRITES, but every caller read the file before it asked for the lock.
    # Two writers therefore read the same old text, and the second replace threw away the first one's
    # change - atomically, so nothing ever looked broken. SKILL.md Phase 6 has the sandbox gate and
    # Phase 7 write the same manifest in the same turn, which is exactly that pair. Update-JsonAtomic moves
    # the read into the lock: read, change, replace, all under one mutex.
    BeforeEach {
        $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) ("jsonupd_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        $script:file = Join-Path $script:dir 'store.json'
        # A second process that holds the lock by being a slow mutator: it signals once it is INSIDE the
        # block, then sleeps. Public API only - the test never reimplements the mutex name.
        $script:slowMutator = {
            param($storeScript, $file, $marker, $sleepSeconds, $key)
            . $storeScript
            Update-JsonAtomic -Path $file -Mutate {
                param($rawText)
                $o = if ($rawText) { $rawText | ConvertFrom-Json } else { [pscustomobject]@{} }
                Set-Content -LiteralPath $marker -Value 'inside'
                Start-Sleep -Seconds $sleepSeconds
                $o | Add-Member -NotePropertyName $key -NotePropertyValue 1 -Force
                $o
            } | Out-Null
        }
        $script:waitMarker = {
            param([string]$Path)
            $deadline = (Get-Date).AddSeconds(60)
            while (-not (Test-Path -LiteralPath $Path)) {
                if ((Get-Date) -gt $deadline) { throw "the helper process never reached its mutator ($Path)" }
                Start-Sleep -Milliseconds 100
            }
        }
    }
    AfterEach {
        Get-Job | Where-Object { $_.Name -like 'jsonupd*' } | Remove-Job -Force -ErrorAction SilentlyContinue
        if (Test-Path $script:dir) { Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'hands the mutator $null when the store does not exist yet, and writes what it returns' {
        $script:seen = 'unset'
        Update-JsonAtomic -Path $script:file -Mutate { param($rawText) $script:seen = $rawText; @{ a = 1 } } | Out-Null
        $null -eq $script:seen | Should -BeTrue
        (Get-Content $script:file -Raw | ConvertFrom-Json).a | Should -Be 1
    }

    It 'hands the mutator the current text and returns the object it wrote' {
        '{"a":1}' | Set-Content $script:file -Encoding UTF8
        $r = Update-JsonAtomic -Path $script:file -Mutate {
            param($rawText)
            $o = $rawText | ConvertFrom-Json
            $o | Add-Member -NotePropertyName b -NotePropertyValue 2
            $o
        }
        $r.b | Should -Be 2
        $disk = Get-Content $script:file -Raw | ConvertFrom-Json
        $disk.a | Should -Be 1
        $disk.b | Should -Be 2
        @(Get-ChildItem $script:dir -Filter '*.tmp').Count | Should -Be 0
    }

    It 'leaves the file untouched when the mutator throws, and the caller hears the mutator''s own error' {
        '{"a":1}' | Set-Content $script:file -Encoding UTF8
        { Update-JsonAtomic -Path $script:file -Mutate { param($rawText) throw 'store is malformed' } } |
            Should -Throw -ExpectedMessage '*malformed*'
        (Get-Content $script:file -Raw | ConvertFrom-Json).a | Should -Be 1
        @(Get-ChildItem $script:dir -Filter '*.tmp').Count | Should -Be 0
    }

    It 'refuses a mutator that returns nothing, instead of writing "null" over the store' {
        '{"a":1}' | Set-Content $script:file -Encoding UTF8
        { Update-JsonAtomic -Path $script:file -Mutate { param($rawText) } } | Should -Throw -ExpectedMessage '*exactly one*'
        (Get-Content $script:file -Raw | ConvertFrom-Json).a | Should -Be 1
    }

    It 'THROWS when the lock is not free in time, rather than writing without it' {
        # The old writer logged "replacing anyway" to Verbose and wrote - which is precisely how the
        # other writer's update gets lost.
        '{"a":1}' | Set-Content $script:file -Encoding UTF8
        $marker = Join-Path $script:dir 'inside.txt'
        $job = Start-Job -Name 'jsonupd-holder' -ScriptBlock $script:slowMutator -ArgumentList $script:store, $script:file, $marker, 6, 'holder'
        & $script:waitMarker $marker
        { Update-JsonAtomic -Path $script:file -LockTimeoutSeconds 1 -Mutate { param($rawText) @{ lost = 1 } } } |
            Should -Throw -ExpectedMessage '*lock*'
        $job | Wait-Job -Timeout 60 | Receive-Job -ErrorAction Stop | Out-Null
        $disk = Get-Content $script:file -Raw | ConvertFrom-Json
        $disk.holder | Should -Be 1
        $disk.PSObject.Properties.Name | Should -Not -Contain 'lost'
    }

    It 'serialises two read-modify-writes: a change made while another writer is inside the lock is not lost' {
        '{"a":1}' | Set-Content $script:file -Encoding UTF8
        $marker = Join-Path $script:dir 'inside.txt'
        $job = Start-Job -Name 'jsonupd-first' -ScriptBlock $script:slowMutator -ArgumentList $script:store, $script:file, $marker, 2, 'first'
        & $script:waitMarker $marker
        # The first writer has READ the store and is still inside its block. A read outside the lock would
        # see {"a":1} here and its replace would throw "first" away.
        Update-JsonAtomic -Path $script:file -Mutate {
            param($rawText)
            $o = $rawText | ConvertFrom-Json
            $o | Add-Member -NotePropertyName second -NotePropertyValue 1 -Force
            $o
        } | Out-Null
        $job | Wait-Job -Timeout 60 | Receive-Job -ErrorAction Stop | Out-Null
        $disk = Get-Content $script:file -Raw | ConvertFrom-Json
        $disk.first  | Should -Be 1 -Because 'the writer that held the lock finished first'
        $disk.second | Should -Be 1 -Because 'the waiting writer read the store only after the first had replaced it'
    }
}

Describe 'the readers wait out a replace instead of calling the store malformed (0.49.2)' {
    # Readers take no lock. While a writer's File.Replace holds the file, a read fails with a sharing
    # violation - and both readers reported that as "malformed". Measured 2026-09-27 by the two-process
    # append test below, whose first run on the old code died on exactly that message. Phase 7 reads the
    # manifest while the sandbox harness writes it a dozen times, by design.
    BeforeEach {
        $script:rDir = Join-Path ([System.IO.Path]::GetTempPath()) ("jsonread_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:rDir -Force | Out-Null
        $script:holdExclusive = {
            param($file, $marker, $holdMs)
            $h = [System.IO.File]::Open($file, 'Open', 'ReadWrite', [System.IO.FileShare]::None)
            try { Set-Content -LiteralPath $marker -Value 'held'; Start-Sleep -Milliseconds $holdMs }
            finally { $h.Dispose() }
        }
        $script:waitFor = {
            param([string]$Path)
            $deadline = (Get-Date).AddSeconds(60)
            while (-not (Test-Path -LiteralPath $Path)) {
                if ((Get-Date) -gt $deadline) { throw "the helper process never took the file ($Path)" }
                Start-Sleep -Milliseconds 50
            }
        }
    }
    AfterEach {
        Get-Job | Where-Object { $_.Name -like 'jsonread*' } | Remove-Job -Force -ErrorAction SilentlyContinue
        if (Test-Path $script:rDir) { Remove-Item $script:rDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Get-PsadtPackageManifest reads the manifest once the writer lets go' {
        Set-Content (Join-Path $script:rDir 'Invoke-AppDeployToolkit.ps1') '# stub launcher'
        $file = Join-Path $script:rDir 'psadt-package.json'
        '{"schema":1,"app":{"name":"Widget"}}' | Set-Content $file -Encoding UTF8
        $marker = Join-Path $script:rDir 'held.txt'
        $job = Start-Job -Name 'jsonread-mf' -ScriptBlock $script:holdExclusive -ArgumentList $file, $marker, 400
        & $script:waitFor $marker
        $r = & (Join-Path $PSScriptRoot '..\scripts\Get-PsadtPackageManifest.ps1') -PackagePath $script:rDir
        $job | Wait-Job -Timeout 60 | Receive-Job -ErrorAction Stop | Out-Null
        $r.PSObject.Properties.Name | Should -Not -Contain 'Error' -Because "a busy file is not a malformed one: $($r.Error)"
        $r.Manifest.app.name | Should -Be 'Widget'
    }

    It 'Get-PsadtConfig reads config.json once the writer lets go' {
        $file = Join-Path $script:rDir 'config.json'
        '{"version":1,"author":{"person":"ACME"}}' | Set-Content $file -Encoding UTF8
        $marker = Join-Path $script:rDir 'held.txt'
        $job = Start-Job -Name 'jsonread-cfg' -ScriptBlock $script:holdExclusive -ArgumentList $file, $marker, 400
        & $script:waitFor $marker
        $r = & (Join-Path $PSScriptRoot '..\scripts\Get-PsadtConfig.ps1') -SkillRoot $script:rDir
        $job | Wait-Job -Timeout 60 | Receive-Job -ErrorAction Stop | Out-Null
        $r.PSObject.Properties.Name | Should -Not -Contain 'Error' -Because "a busy file is not a malformed one: $($r.Error)"
        $r.Config.author.person | Should -Be 'ACME'
    }

    It 'still calls a file that does not parse malformed' {
        Set-Content (Join-Path $script:rDir 'Invoke-AppDeployToolkit.ps1') '# stub launcher'
        Set-Content (Join-Path $script:rDir 'psadt-package.json') '{ not json' -NoNewline
        $r = & (Join-Path $PSScriptRoot '..\scripts\Get-PsadtPackageManifest.ps1') -PackagePath $script:rDir
        $r.Error | Should -Match 'malformed'
    }
}

Describe 'Set-PsadtPackageManifest loses nothing when two processes append at once (0.49.2)' {
    # The measured case: the sandbox harness appends results.systemTest and artifacts.logs while the
    # packaging step records artifacts.intunewin - two processes, one manifest.
    BeforeAll {
        $script:setter = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Set-PsadtPackageManifest.ps1')).Path
    }
    BeforeEach {
        $script:pkg = Join-Path ([System.IO.Path]::GetTempPath()) ("jsonrace_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:pkg -Force | Out-Null
        Set-Content (Join-Path $script:pkg 'Invoke-AppDeployToolkit.ps1') '# stub launcher'
        & $script:setter -PackagePath $script:pkg -Updates @{ 'app.name' = 'Widget' } | Out-Null
    }
    AfterEach {
        Get-Job | Where-Object { $_.Name -like 'jsonrace*' } | Remove-Job -Force -ErrorAction SilentlyContinue
        if (Test-Path $script:pkg) { Remove-Item $script:pkg -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps every one of 2 x 15 appends' {
        $go = Join-Path $script:pkg 'go.txt'
        $appender = {
            param($setter, $pkg, $go, $tag, $n)
            while (-not (Test-Path -LiteralPath $go)) { Start-Sleep -Milliseconds 20 }
            for ($i = 1; $i -le $n; $i++) {
                & $setter -PackagePath $pkg -Append @{ 'artifacts.logs' = "$tag-$i" } | Out-Null
            }
        }
        $jobs = @(
            Start-Job -Name 'jsonrace-a' -ScriptBlock $appender -ArgumentList $script:setter, $script:pkg, $go, 'a', 15
            Start-Job -Name 'jsonrace-b' -ScriptBlock $appender -ArgumentList $script:setter, $script:pkg, $go, 'b', 15
        )
        Start-Sleep -Seconds 2   # both processes up and polling before the start signal
        Set-Content -LiteralPath $go -Value 'go'
        $jobs | Wait-Job -Timeout 120 | Out-Null
        foreach ($j in $jobs) { $j | Receive-Job -ErrorAction Stop | Out-Null }
        $m = Get-Content (Join-Path $script:pkg 'psadt-package.json') -Raw | ConvertFrom-Json
        $logs = @($m.artifacts.logs)
        $logs.Count | Should -Be 30 -Because "each append must survive the other process's; kept: $($logs -join ', ')"
        $m.app.name | Should -Be 'Widget'
    }

    It 'still runs under Windows PowerShell 5.1, which the per-action SYSTEM test uses' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $cmd = "`$ErrorActionPreference = 'Stop'; & '$script:setter' -PackagePath '$script:pkg' -Append @{ 'artifacts.logs' = 'ps51' } | Out-Null; 'ok'"
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1
        ($out | Out-String) | Should -Match '(?m)^ok\s*$' -Because "Windows PowerShell 5.1 said: $($out | Out-String)"
        @((Get-Content (Join-Path $script:pkg 'psadt-package.json') -Raw | ConvertFrom-Json).artifacts.logs) | Should -Contain 'ps51'
    }
}

<#
.SYNOPSIS  Runs the COMPLETE Install/Detect/Uninstall/Reinstall/Repair loop inside a throwaway Windows Sandbox, every action as SYSTEM.
.DESCRIPTION
  The complement to Invoke-PsadtSystemTest.ps1, which performs ONE action on the machine it runs on and
  needs an elevated session. This script needs NO elevation on the host: it hands the package to a
  disposable Windows Sandbox VM and, inside that VM, drives the whole Phase 6 loop through scheduled tasks
  running as NT AUTHORITY\SYSTEM - the same account the Intune Management Extension uses.

  Two consequences follow, and both are the point:
    * the host is never modified, so a packaging session can prove Install AND Uninstall without a DEV VM
      and without administrative rights;
    * every action runs on a machine that has never seen the app, so "it worked because the last run left
      something behind" cannot happen.

  The verdict is keyed on the DETECTION SCRIPT, not on file paths, because the detection script is what
  Intune actually evaluates. Package-specific facts (an updater directory that must be absent, a shortcut
  that must exist) are asserted through the -Paths* parameters.

  Where the evidence ends up: result.json, the PSADT logs and the .wsb are copied into
  <outputRoot>\<Stem>\SandboxTest\, beside the dossier and the detection script, and the log paths are
  appended to artifacts.logs[]. The scratch work folder under the config home is then removed - it holds
  only the generated runner and raw output, all of which the next run regenerates. Deliberately NOT the
  package folder: that is what IntuneWinAppUtil packs, and test logs have no business shipping to devices.
  A run that fails before producing a result keeps its work folder so it can be investigated.

  What it does NOT do: it decides nothing about fixes. Like Invoke-PsadtSystemTest it reports facts, and the
  caller drives the loop.
.OUTPUTS
  PSCustomObject: Verdict ('GREEN'|'RED'|'ERROR'), Steps, FailedAssertions, Assertions, ResultPath,
  LogFolder, EvidenceFolder, SandboxWorkFolder (null once the scratch is cleaned up), DurationMinutes
.EXAMPLE
  Invoke-PsadtSandboxTest.ps1 -PackagePath C:\PSADT\Packages\NotepadPlusPlus

  Runs the full loop and returns the verdict.
.EXAMPLE
  Invoke-PsadtSandboxTest.ps1 -PackagePath C:\PSADT\Packages\NotepadPlusPlus `
      -PathsPresentAfterInstall 'C:\Program Files\Notepad++\notepad++.exe' `
      -PathsAbsentAfterInstall  'C:\Program Files\Notepad++\updater\GUP.exe'

  Adds package-specific assertions: the binary must be there, the auto-updater must not.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath,

    # Defaults to the single Detect*.ps1 in the package root. Give it explicitly when a package ships more
    # than one - the verdict depends on which script Intune will actually use.
    [string]$DetectionScript,

    [int[]]$SuccessExitCodes = @(0, 1707, 3010, 1641),

    # Package-specific facts to assert on the freshly installed / freshly removed machine.
    [string[]]$PathsPresentAfterInstall = @(),
    [string[]]$PathsAbsentAfterInstall = @(),
    [string[]]$PathsAbsentAfterUninstall = @(),

    # Per-action ceiling inside the VM. A sandbox has no warm file cache and Defender scans every file it
    # sees, so an install that takes 20 seconds on real hardware can take two minutes here.
    [ValidateRange(60, 3600)][int]$ActionTimeoutSeconds = 900,

    # Ceiling for the whole run, measured on the host. Protects against a VM that never boots.
    [ValidateRange(5, 180)][int]$TotalTimeoutMinutes = 45,

    [ValidateRange(2048, 32768)][int]$MemoryInMB = 6144,

    # Leave the VM running at the end instead of shutting it down. For looking at a failure by hand.
    [switch]$KeepSandboxOpen,

    # Keep the scratch work folder (generated runner, .wsb, raw sandbox output). Off by default: the
    # evidence is copied into the package's Output folder, and what is left behind is regenerated on every
    # run, so keeping it only grows one stale directory per app under the config home forever.
    [switch]$KeepWorkFolder,

    # Write the runner and the .wsb, then stop without starting the VM. Returns the generated paths.
    # A human uses it to inspect or hand-tune the configuration; the test suite uses it to assert on the
    # generated runner without needing Windows Sandbox on the machine running the tests.
    [switch]$GenerateOnly,

    # Unused downstream; accepted so callers can pass it through. Empty = Get-PsadtConfig resolves the home.
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'
$startedAt = Get-Date

# --- 1. Package guards -----------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $PackagePath)) { throw "PackagePath not found: $PackagePath" }
$PackagePath = (Resolve-Path -LiteralPath $PackagePath).ProviderPath.TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $PackagePath 'Invoke-AppDeployToolkit.ps1'))) {
    throw "Not a PSADT package (no Invoke-AppDeployToolkit.ps1): $PackagePath"
}
if (-not (Test-Path -LiteralPath (Join-Path $PackagePath 'Invoke-AppDeployToolkit.exe'))) {
    throw "The package has no Invoke-AppDeployToolkit.exe. The sandbox test drives the same entry point Intune uses; re-scaffold the package."
}

if (-not $DetectionScript) {
    $found = @(Get-ChildItem -LiteralPath $PackagePath -Filter 'Detect*.ps1' -File -ErrorAction SilentlyContinue)
    if ($found.Count -eq 1) { $DetectionScript = $found[0].Name }
    elseif ($found.Count -eq 0) { throw "No Detect*.ps1 found in $PackagePath. Pass -DetectionScript, or add the detection script - the verdict is keyed on it." }
    else { throw "$($found.Count) Detect*.ps1 scripts found in $PackagePath. Pass -DetectionScript to say which one Intune will use." }
} elseif (-not (Test-Path -LiteralPath (Join-Path $PackagePath $DetectionScript))) {
    throw "DetectionScript '$DetectionScript' not found in $PackagePath."
}

# --- 2. Sandbox guards -----------------------------------------------------------------------------
# Deliberately read through Win32_OptionalFeature and not Get-WindowsOptionalFeature: the DISM cmdlet
# requires elevation, and needing no elevation is this script's whole reason to exist.
$feature = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='Containers-DisposableClientVM'" -ErrorAction SilentlyContinue
if (-not $feature) {
    throw "Windows Sandbox is not available on this machine (optional feature 'Containers-DisposableClientVM' is unknown). Use Invoke-PsadtSystemTest.ps1 on a DEV VM instead."
}
if ([int]$feature.InstallState -ne 1) {
    throw "Windows Sandbox is present but not enabled (InstallState=$($feature.InstallState)). Enable it ONCE from an elevated session: Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All (a restart is required), then re-run this script unelevated."
}
# Windows allows exactly one sandbox instance. Starting a second one silently attaches to the first, which
# would run this test against the previous run's dirty machine.
$running = @(Get-Process -Name 'WindowsSandboxServer' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    throw "A Windows Sandbox instance is already running. Close it first - Windows permits only one, and reusing it would test against a machine that is no longer clean."
}

# --- 3. Work folder --------------------------------------------------------------------------------
$cfg = & (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1')
$mf = & (Join-Path $PSScriptRoot 'Get-PsadtPackageManifest.ps1') -PackagePath $PackagePath
$stem = if ($mf.Stem) { $mf.Stem } else { Split-Path $PackagePath -Leaf }

# The mapped folder appears inside the VM as C:\Users\WDAGUtilityAccount\Desktop\<leaf>, so the two leaf
# names must differ or the second mapping shadows the first.
$packageLeaf = Split-Path $PackagePath -Leaf
$workLeaf = '_PsadtSandboxTest'
if ($packageLeaf -eq $workLeaf) { throw "The package folder must not be named '$workLeaf' - that name is reserved for the sandbox work folder." }

$workRoot = Join-Path $cfg.Home "sandbox\$stem"
if (Test-Path -LiteralPath $workRoot) {
    # A previous run's folder must go: it was mapped into a VM, and reusing it would map stale content.
    # The realistic failure here is an ORPHANED vmmemWindowsSandbox worker still holding the mapped folder
    # open - it survives the client processes, cannot be killed (the Hyper-V compute service owns it), and
    # usually clears on a reboot. Say that, instead of surfacing a bare "used by another process".
    try {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop
    } catch {
        $orphan = @(Get-Process -Name 'vmmemWindowsSandbox' -ErrorAction SilentlyContinue).Count -gt 0
        $why = if ($orphan) {
            "A Windows Sandbox VM worker (vmmemWindowsSandbox) is still running and holding it open. It cannot be terminated directly - the Hyper-V compute service owns it - so either wait for it to exit or reboot."
        } else {
            "Something still holds a handle on it."
        }
        throw "The work folder from a previous run cannot be removed: $workRoot`n$why`nOriginal error: $($_.Exception.Message)"
    }
}
$workFolder = Join-Path $workRoot $workLeaf
$resultsFolder = Join-Path $workFolder 'results'
New-Item -ItemType Directory -Path $resultsFolder -Force | Out-Null

# --- 4. Generate the in-sandbox runner --------------------------------------------------------------
function ConvertTo-PsArrayLiteral([string[]]$Values) {
    if (-not $Values -or $Values.Count -eq 0) { return '@()' }
    return '@(' + (($Values | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', ') + ')'
}

function Expand-CommaSeparated([string[]]$Values) {
    # `pwsh script.ps1 -PathsAbsentAfterInstall a,b` (the -File binder, which a bare `pwsh scripts/...ps1`
    # invocation uses) passes "a,b" as ONE element. Without this the second path is silently never asserted -
    # the run still reports GREEN, which is worse than an error.
    # A Windows path cannot contain a comma-less-ambiguity problem here: commas are legal in file names but
    # vanishingly rare, and a caller who needs one can pass a real array via -Command.
    if (-not $Values) { return @() }
    return @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$PathsPresentAfterInstall = Expand-CommaSeparated $PathsPresentAfterInstall
$PathsAbsentAfterInstall = Expand-CommaSeparated $PathsAbsentAfterInstall
$PathsAbsentAfterUninstall = Expand-CommaSeparated $PathsAbsentAfterUninstall

$runnerTemplate = @'
# Generated by Invoke-PsadtSandboxTest.ps1 - runs inside Windows Sandbox, started by the .wsb LogonCommand.
# Drives the full Phase 6 loop with every deployment action executed as NT AUTHORITY\SYSTEM.
$ErrorActionPreference = 'Stop'

$mapped   = 'C:\Users\WDAGUtilityAccount\Desktop\__WORKLEAF__'
$pkgSrc   = 'C:\Users\WDAGUtilityAccount\Desktop\__PACKAGELEAF__'
$results  = Join-Path $mapped 'results'
$work     = 'C:\PsadtSandboxWork'
$pkg      = 'C:\PsadtSandboxPackage'

$detectionScript   = '__DETECTIONSCRIPT__'
$successExitCodes  = __SUCCESSCODES__
$actionTimeout     = __ACTIONTIMEOUT__
$pathsPresentAfterInstall  = __PATHSPRESENTINSTALL__
$pathsAbsentAfterInstall   = __PATHSABSENTINSTALL__
$pathsAbsentAfterUninstall = __PATHSABSENTUNINSTALL__

$report = [ordered]@{ startedUtc = (Get-Date).ToUniversalTime().ToString('o'); steps = @(); verdict = 'UNKNOWN'; failedAssertions = @() }
$assertions = @()

function Add-Step {
    param([string]$Name, $Data)
    $entry = [ordered]@{ step = $Name }
    foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }
    $script:report.steps += [pscustomobject]$entry
    Write-Host ("== " + $Name + " : " + (($Data.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '  '))
}

function Add-Assertion {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:assertions += [pscustomobject]@{ name = $Name; ok = $Ok; detail = $Detail }
    if (-not $Ok) { $script:report.failedAssertions += $Name }
}

function Invoke-AsSystem {
    <#
      Runs one command line as SYSTEM through a scheduled task and returns { ExitCode, Output, TimedOut }.
      Three details here are load-bearing; each one cost a full sandbox run to find:
        1. "echo %ERRORLEVEL% > file" needs the space. Without it, a single-digit code makes cmd read
           "echo 0>file", where 0> is the STDIN redirection operator - the file is created EMPTY and the
           caller waits for a number that never arrives.
        2. The file merely existing is therefore not the completion signal; wait until it holds a number.
        3. Get-Content -Raw returns $null for an empty file, and an empty file is the NORMAL result of a
           detection script on a machine where the app is absent. In Windows PowerShell 5.1
           "$x = [string]$null" is still $null, so the value has to be built by concatenation to make
           .Trim() safe for callers.
    #>
    param([string]$Label, [string]$CommandLine, [int]$TimeoutSeconds)

    $taskName = "PsadtSbx_$Label"
    $codeFile = Join-Path $work "$Label.exitcode"
    $cmdFile  = Join-Path $work "$Label.cmd"
    $outFile  = Join-Path $work "$Label.out"
    Remove-Item $codeFile, $outFile -Force -ErrorAction SilentlyContinue

    @(
        '@echo off'
        "$CommandLine > `"$outFile`" 2>&1"
        "echo %ERRORLEVEL% > `"$codeFile`""
    ) | Set-Content -LiteralPath $cmdFile -Encoding ASCII

    & schtasks.exe /Create /TN $taskName /TR "`"$cmdFile`"" /SC ONCE /ST 00:00 /RU 'SYSTEM' /RL HIGHEST /F | Out-Null
    & schtasks.exe /Run /TN $taskName | Out-Null

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $raw = $null
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $codeFile) {
            $raw = Get-Content -LiteralPath $codeFile -Raw -ErrorAction SilentlyContinue
            if ($raw -and ($raw.Trim() -match '^-?\d+$')) { break }
        }
        Start-Sleep -Seconds 2
        $raw = $null
    }
    & schtasks.exe /Delete /TN $taskName /F | Out-Null

    if (-not $raw) { return [pscustomobject]@{ ExitCode = $null; Output = ''; TimedOut = $true } }

    [string]$out = ''
    if (Test-Path -LiteralPath $outFile) { $out = '' + (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) }
    return [pscustomobject]@{ ExitCode = [int]$raw.Trim(); Output = $out; TimedOut = $false }
}

function Invoke-Deployment {
    param([string]$Label, [string]$DeploymentType)
    $exe = Join-Path $pkg 'Invoke-AppDeployToolkit.exe'
    $r = Invoke-AsSystem -Label $Label -CommandLine "`"$exe`" -DeploymentType $DeploymentType -DeployMode Silent" -TimeoutSeconds $actionTimeout
    $ok = (-not $r.TimedOut) -and ($successExitCodes -contains $r.ExitCode)
    Add-Step $Label @{ exitCode = $r.ExitCode; timedOut = $r.TimedOut; success = $ok }
    Add-Assertion "$Label exit code" $ok "exit=$($r.ExitCode) timedOut=$($r.TimedOut)"
    return $r
}

function Invoke-Detection {
    param([string]$Label, [bool]$ExpectDetected)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = Join-Path $pkg $detectionScript
    $r = Invoke-AsSystem -Label $Label -CommandLine "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$script`"" -TimeoutSeconds 300

    # A timeout puts no text on stdout, but it must never be read as "absent" either - assert on TimedOut
    # separately so a hung detection cannot masquerade as a correct negative result.
    $detected = (-not $r.TimedOut) -and (-not [string]::IsNullOrWhiteSpace($r.Output))
    Add-Step $Label @{ exitCode = $r.ExitCode; timedOut = $r.TimedOut; detected = $detected; stdout = $r.Output.Trim() }
    Add-Assertion "$Label not timed out" (-not $r.TimedOut)
    Add-Assertion "$Label exit code 0" ($r.ExitCode -eq 0) "exit=$($r.ExitCode) - Intune reads any non-zero exit as a detection ERROR, not as absent"
    Add-Assertion "$Label detected=$ExpectDetected" ($detected -eq $ExpectDetected) "stdout='$($r.Output.Trim())'"
    return $r
}

function Test-Paths {
    param([string]$Label, [string[]]$Paths, [bool]$ShouldExist)
    foreach ($p in $Paths) {
        $exists = Test-Path -LiteralPath $p
        Add-Assertion "$Label : $p" ($exists -eq $ShouldExist) "exists=$exists expected=$ShouldExist"
    }
}

try {
    New-Item -ItemType Directory -Path $results, $work -Force | Out-Null
    Start-Transcript -LiteralPath (Join-Path $results 'sandbox-transcript.txt') -Force | Out-Null

    # The mapped package folder is read-only and PSADT unblocks files under its own root, so work on a copy.
    Copy-Item -LiteralPath $pkgSrc -Destination $pkg -Recurse -Force
    Get-ChildItem -LiteralPath $pkg -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    Invoke-Deployment -Label 'Install'   -DeploymentType 'Install'   | Out-Null
    Test-Paths -Label 'present after install' -Paths $pathsPresentAfterInstall -ShouldExist $true
    Test-Paths -Label 'absent after install'  -Paths $pathsAbsentAfterInstall  -ShouldExist $false
    Invoke-Detection -Label 'DetectionAfterInstall' -ExpectDetected $true | Out-Null

    Invoke-Deployment -Label 'Uninstall' -DeploymentType 'Uninstall' | Out-Null
    Test-Paths -Label 'absent after uninstall' -Paths $pathsAbsentAfterUninstall -ShouldExist $false
    Invoke-Detection -Label 'DetectionAfterUninstall' -ExpectDetected $false | Out-Null

    Invoke-Deployment -Label 'Reinstall' -DeploymentType 'Install'   | Out-Null
    Invoke-Detection -Label 'DetectionAfterReinstall' -ExpectDetected $true | Out-Null

    Invoke-Deployment -Label 'Repair'    -DeploymentType 'Repair'    | Out-Null
    Test-Paths -Label 'absent after repair' -Paths $pathsAbsentAfterInstall -ShouldExist $false
    Invoke-Detection -Label 'DetectionAfterRepair' -ExpectDetected $true | Out-Null

    # Phase 6 requires the machine to be left uninstalled.
    Invoke-Deployment -Label 'FinalUninstall' -DeploymentType 'Uninstall' | Out-Null
    Invoke-Detection -Label 'DetectionAfterFinalUninstall' -ExpectDetected $false | Out-Null

    $report.verdict = if ($report.failedAssertions.Count -eq 0) { 'GREEN' } else { 'RED' }
}
catch {
    $report.verdict = 'ERROR'
    $report.error = ($_ | Out-String)
    Write-Host ("ERROR: " + $_.Exception.Message)
}
finally {
    try { Stop-Transcript | Out-Null } catch { }

    # PSADT logs are the primary evidence for anything that went wrong, so copy them out unconditionally.
    $logDest = Join-Path $results 'psadt-logs'
    New-Item -ItemType Directory -Path $logDest -Force -ErrorAction SilentlyContinue | Out-Null
    Copy-Item 'C:\Windows\Logs\Software\*' -Destination $logDest -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item "$work\*.out" -Destination $logDest -Force -ErrorAction SilentlyContinue

    $report.assertions = $assertions
    $report.finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $results 'result.json') -Encoding UTF8

    # Written last: the host treats this file as "results are complete on disk", and it is the host that
    # tears the VM down from there.
    #
    Set-Content -LiteralPath (Join-Path $mapped 'DONE.txt') -Value $report.verdict -Encoding ASCII

    # The guest shuts ITSELF down, and that is not interchangeable with the host killing the VM: only a
    # guest-initiated shutdown tears the virtual machine down cleanly, so the vmmemWindowsSandbox worker
    # exits and releases the mapped folder. Force-killing the client from the host instead orphans that
    # worker, which then holds the host's work folder open indefinitely.
    # The cost of shutting down here is that the RDP-style client is left showing a connection-lost dialog -
    # which the host disposes of separately (Stop-SandboxInstance), so the user never sees it.
    Start-Sleep -Seconds 5   # let the mapped-folder writes above reach the host
    & shutdown.exe /s /t 0
}
'@

$runner = $runnerTemplate.
    Replace('__WORKLEAF__', $workLeaf).
    Replace('__PACKAGELEAF__', $packageLeaf).
    Replace('__DETECTIONSCRIPT__', ($DetectionScript -replace "'", "''")).
    Replace('__SUCCESSCODES__', ('@(' + ($SuccessExitCodes -join ', ') + ')')).
    Replace('__ACTIONTIMEOUT__', [string]$ActionTimeoutSeconds).
    Replace('__PATHSPRESENTINSTALL__', (ConvertTo-PsArrayLiteral $PathsPresentAfterInstall)).
    Replace('__PATHSABSENTINSTALL__', (ConvertTo-PsArrayLiteral $PathsAbsentAfterInstall)).
    Replace('__PATHSABSENTUNINSTALL__', (ConvertTo-PsArrayLiteral $PathsAbsentAfterUninstall))

$runnerPath = Join-Path $workFolder 'Run-PsadtSandboxTest.ps1'
[System.IO.File]::WriteAllText($runnerPath, $runner, [System.Text.UTF8Encoding]::new($true))

# --- 5. Generate the .wsb configuration -------------------------------------------------------------
$wsbPath = Join-Path $workRoot "$stem.wsb"
$wsb = @"
<Configuration>
  <MemoryInMB>$MemoryInMB</MemoryInMB>
  <vGPU>Disable</vGPU>
  <Networking>Default</Networking>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$PackagePath</HostFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$workFolder</HostFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Users\WDAGUtilityAccount\Desktop\$workLeaf\Run-PsadtSandboxTest.ps1</Command>
  </LogonCommand>
</Configuration>
"@
[System.IO.File]::WriteAllText($wsbPath, $wsb, [System.Text.UTF8Encoding]::new($false))

# --- 6. Run ------------------------------------------------------------------------------------------
$donePath = Join-Path $workFolder 'DONE.txt'
$resultPath = Join-Path $resultsFolder 'result.json'

if ($GenerateOnly) {
    return [pscustomobject]@{
        Verdict = 'NOT_RUN'; RunnerPath = $runnerPath; WsbPath = $wsbPath
        SandboxWorkFolder = $workFolder; ResultPath = $resultPath
    }
}

$sandboxExe = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'
if (-not (Test-Path -LiteralPath $sandboxExe)) { throw "WindowsSandbox.exe not found at '$sandboxExe'." }

Write-Verbose "Starting Windows Sandbox with $wsbPath"
Start-Process -FilePath $sandboxExe -ArgumentList $wsbPath | Out-Null

$hostDeadline = (Get-Date).AddMinutes($TotalTimeoutMinutes)
$sawSandbox = $false
while ((Get-Date) -lt $hostDeadline) {
    if (Test-Path -LiteralPath $donePath) { break }
    $alive = @(Get-Process -Name 'WindowsSandboxServer' -ErrorAction SilentlyContinue).Count -gt 0
    if ($alive) { $sawSandbox = $true }
    elseif ($sawSandbox) { break }   # the VM went away without writing DONE.txt
    Start-Sleep -Seconds 10
}

function Stop-SandboxInstance {
    <#
      Disposes of the Windows Sandbox client window and waits until the VM is really gone.

      The division of labour matters and is not interchangeable:
        * The GUEST shuts itself down (see the generated runner). Only a guest-initiated shutdown tears the
          virtual machine down cleanly, so vmmemWindowsSandbox exits and releases the host's mapped folder.
          Force-killing the VM from the host instead ORPHANS that worker: the client processes disappear,
          the work folder stays locked, and the cleanup then reports a failure it could not have avoided.
          That was measured on 2026-09-06 - the orphan outlived the run by minutes.
        * The HOST kills only the CLIENT window. The client is an RDP-style viewer; when the guest shuts
          down the session drops out from under it and it leaves a connection-lost dialog on the user's
          desktop. Killing it is what makes the run silent.
        * The client is terminated rather than sent WM_CLOSE, because closing the window politely makes
          Windows Sandbox ask "are you sure - all contents will be discarded". An unattended run must not
          produce a prompt. Discarding is the entire point, and the evidence reached the host before
          DONE.txt was written.
    #>
    param([int]$TimeoutSeconds = 180)

    # The viewer only - never WindowsSandboxServer, which is what supervises the VM teardown.
    foreach ($name in 'WindowsSandboxRemoteSession', 'WindowsSandboxClient', 'WindowsSandbox') {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # Wait for the VM worker, not for the client: vmmemWindowsSandbox does not match 'WindowsSandbox*' and
    # it is the process that holds the mapped folder. vmwp is deliberately NOT waited on - it is shared with
    # every other Hyper-V guest on the machine (WSL, a dev VM) and may legitimately never exit.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $alive = @(Get-Process -Name 'vmmemWindowsSandbox', 'WindowsSandboxServer' -ErrorAction SilentlyContinue)
        if ($alive.Count -eq 0) { return $true }
        Start-Sleep -Seconds 3
    }
    return @(Get-Process -Name 'vmmemWindowsSandbox', 'WindowsSandboxServer' -ErrorAction SilentlyContinue).Count -eq 0
}

$verdictFile = if (Test-Path -LiteralPath $donePath) { (Get-Content -LiteralPath $donePath -Raw).Trim() } else { $null }

# Tear the VM down before touching the work folder: while the sandbox lives it holds the mapped-folder
# handle, which is what made the cleanup below need a retry loop in the first place.
if (-not $KeepSandboxOpen) {
    if (-not (Stop-SandboxInstance)) {
        Write-Warning 'The Windows Sandbox process did not exit within 60 seconds; close the window by hand.'
    }
}
$result = $null
if (Test-Path -LiteralPath $resultPath) {
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
}

if (-not $result) {
    $reason = if (-not $sawSandbox) { "Windows Sandbox never started - check that no policy blocks it." }
              elseif (-not $verdictFile) { "The sandbox stopped before the test finished (host timeout after $TotalTimeoutMinutes minutes, or the VM was closed)." }
              else { "The sandbox reported '$verdictFile' but wrote no result.json." }
    return [pscustomobject]@{
        Verdict = 'ERROR'; Steps = @(); FailedAssertions = @(); Error = $reason
        ResultPath = $null; LogFolder = (Join-Path $resultsFolder 'psadt-logs')
        SandboxWorkFolder = $workFolder; DurationMinutes = [math]::Round(((Get-Date) - $startedAt).TotalMinutes, 1)
    }
}

# --- 7a. Move the evidence next to the package's other artefacts ------------------------------------
# The work folder lives under the config home and is wiped at the start of the next run for this stem, so
# anything left there is not evidence, it is scratch. result.json and the PSADT logs ARE the proof that
# Phase 6 passed, so they belong beside the dossier and the detection script - the same place the rest of
# the package's deliverables live, and a place that is NOT inside the folder IntuneWinAppUtil packs.
$evidenceFolder = $null
try {
    $outputFolder = $null
    if ($mf.Exists -and -not $mf.Error -and $mf.Manifest.artifacts -and $mf.Manifest.artifacts.outputFolder) {
        $outputFolder = [string]$mf.Manifest.artifacts.outputFolder
    }
    if (-not $outputFolder) { $outputFolder = Join-Path $cfg.Config.paths.outputRoot $stem }
    $evidenceFolder = Join-Path $outputFolder 'SandboxTest'

    if (Test-Path -LiteralPath $evidenceFolder) { Remove-Item -LiteralPath $evidenceFolder -Recurse -Force }
    New-Item -ItemType Directory -Path $evidenceFolder -Force | Out-Null
    Copy-Item -Path (Join-Path $resultsFolder '*') -Destination $evidenceFolder -Recurse -Force
    Copy-Item -LiteralPath $wsbPath -Destination $evidenceFolder -Force
    $resultPath = Join-Path $evidenceFolder 'result.json'
} catch {
    Write-Warning "Could not copy the sandbox evidence to the Output folder: $($_.Exception.Message)"
    $evidenceFolder = $null
}

# --- 7. Record in the manifest (best effort, exactly like Invoke-PsadtSystemTest) --------------------
try {
    if ($mf.Exists -and -not $mf.Error) {
        $append = @{}
        foreach ($step in $result.steps) {
            if ($step.PSObject.Properties.Name -contains 'success') {
                $append['results.systemTest'] = @{
                    type      = $step.step
                    exitCode  = $step.exitCode
                    success   = $step.success
                    detection = 'see result.json'
                    log       = $resultPath
                    context   = 'windows-sandbox'
                    at        = $result.finishedUtc
                }
                & (Join-Path $PSScriptRoot 'Set-PsadtPackageManifest.ps1') -PackagePath $PackagePath -Append $append | Out-Null
            }
        }
        & (Join-Path $PSScriptRoot 'Set-PsadtPackageManifest.ps1') -PackagePath $PackagePath -Updates @{
            'results.sandboxTest' = @{
                verdict          = $result.verdict
                failedAssertions = @($result.failedAssertions)
                resultPath       = $resultPath
                evidenceFolder   = $evidenceFolder
                at               = $result.finishedUtc
            }
        } | Out-Null

        if ($evidenceFolder) {
            $logs = @(Get-ChildItem -LiteralPath (Join-Path $evidenceFolder 'psadt-logs') -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
            foreach ($log in $logs) {
                & (Join-Path $PSScriptRoot 'Set-PsadtPackageManifest.ps1') -PackagePath $PackagePath -Append @{ 'artifacts.logs' = $log } | Out-Null
            }
        }
    }
} catch {
    Write-Warning "Could not record the sandbox-test result in the manifest: $($_.Exception.Message)"
}

$logFolder = if ($evidenceFolder) { Join-Path $evidenceFolder 'psadt-logs' } else { Join-Path $resultsFolder 'psadt-logs' }

# --- 8. Clean up the scratch ------------------------------------------------------------------------
# Only reached once the evidence is safely copied out; on the failure paths above the function has already
# returned, so a run worth investigating still has its work folder.
#
# The retry is not defensive padding: the host keeps the mapped-folder handle for a few seconds after the
# guest has shut down, so the FILES delete while the directory itself stays locked. A single
# Remove-Item -ErrorAction SilentlyContinue therefore leaves an empty directory behind AND reports success,
# which is why this is verified below instead of assumed.
if (-not $KeepWorkFolder -and $evidenceFolder) {
    foreach ($attempt in 1..10) {
        if (-not (Test-Path -LiteralPath $workRoot)) { break }
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $workRoot) { Start-Sleep -Seconds 2 }
    }
    if (Test-Path -LiteralPath $workRoot) {
        Write-Warning "The scratch work folder is still locked and could not be removed: $workRoot. The evidence is safe in $evidenceFolder; delete the work folder by hand or leave it for the next run of this package, which wipes it before starting."
    }
}

# Report what is actually on disk, never what was intended.
$workFolderRemaining = if (Test-Path -LiteralPath $workRoot) { $workFolder } else { $null }

return [pscustomobject]@{
    Verdict           = $result.verdict
    Steps             = $result.steps
    FailedAssertions  = @($result.failedAssertions)
    Assertions        = $result.assertions
    Error             = $result.error
    ResultPath        = $resultPath
    LogFolder         = $logFolder
    EvidenceFolder    = $evidenceFolder
    SandboxWorkFolder = $workFolderRemaining
    DurationMinutes   = [math]::Round(((Get-Date) - $startedAt).TotalMinutes, 1)
}

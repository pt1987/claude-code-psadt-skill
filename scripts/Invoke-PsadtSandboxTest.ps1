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

    # Guest-side wait, inside the Startup trigger, before the runner starts reading the mapped folder.
    # Some hosts see the mapped-folder mount land empty when the guest uses it too soon after logon; this
    # pause happens after the guest has logged on, giving the mount extra time to settle. 0 disables it.
    # Host-specific rather than a fixed cost - tune it down once a working value is known.
    [ValidateRange(0, 900)][int]$GuestSettleDelaySeconds = 0,

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

$mapped   = '__MAPPEDROOT__'
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

function Get-SchtasksFailure {
    <#
      Both schtasks calls used to be piped to Out-Null with no exit-code check, so ANY failure to
      create or start the task presented as the action timing out $actionTimeout seconds later - the
      one symptom that says nothing about the cause. The likeliest real cause is a token problem:
      /RU SYSTEM /RL HIGHEST needs the full administrator token, and a Startup-folder item does not
      always carry one.
    #>
    param([string]$Operation, [string]$TaskName, [int]$Code, [string]$ErrFile)

    $detail = ''
    if (Test-Path -LiteralPath $ErrFile) {
        $detail = (('' + (Get-Content -LiteralPath $ErrFile -Raw -ErrorAction SilentlyContinue)) -replace '\s+', ' ').Trim()
    }
    "schtasks /$Operation failed for '$TaskName' (exit $Code). $detail"
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

    # /Run starts the task immediately, so the ONCE trigger exists only because /Create demands one.
    # 00:00 is in the past ON PURPOSE: a trigger that can never fire by itself cannot re-launch this
    # deployment .cmd as SYSTEM behind the loop's back while the action is still running. schtasks says
    # so on STDERR ("Task may not run because /ST is earlier than current time") on every single step -
    # that notice is the design working, so it is suppressed rather than designed away with a
    # near-future /ST. A formatted time would be culture-dependent on top: 'HH:mm' renders as 15.02
    # under fi-FI, which schtasks rejects with "Invalid start time value", creating no task at all.
    # $ErrorActionPreference is 'Stop' here, and in WinPS 5.1 a native command writing to stderr raises
    # a terminating NativeCommandError REGARDLESS of a '2>file' redirect - the redirect chooses where the
    # ErrorRecord is written, not whether one is raised. Suppressing the notice therefore needs the
    # preference lowered around the call itself; with 2>file alone the very first step dies on schtasks'
    # own "/ST is earlier than current time" warning, which this design provokes deliberately on EVERY
    # step. Measured on de-DE 2026-09-11: verdict ERROR after 0.7 min, before a single action ran.
    # The exit-code checks below are what actually decide success, and they are unaffected.
    $schtasksErr = Join-Path $work "$Label.schtasks.err"
    & {
        $ErrorActionPreference = 'Continue'
        & schtasks.exe /Create /TN $taskName /TR "`"$cmdFile`"" /SC ONCE /ST 00:00 /RU 'SYSTEM' /RL HIGHEST /F 2>$schtasksErr | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw (Get-SchtasksFailure -Operation 'Create' -TaskName $taskName -Code $LASTEXITCODE -ErrFile $schtasksErr) }
    & {
        $ErrorActionPreference = 'Continue'
        & schtasks.exe /Run /TN $taskName 2>$schtasksErr | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw (Get-SchtasksFailure -Operation 'Run' -TaskName $taskName -Code $LASTEXITCODE -ErrFile $schtasksErr) }

    # Everything below runs as SYSTEM through the scheduled task, which draws nothing on the guest
    # desktop. A heartbeat is therefore the only way an operator watching the VM can tell a working
    # install from a hung one - and telling those two apart by staring at an idle screen is exactly
    # what cost hours on 2026-09-11.
    try { $Host.UI.RawUI.WindowTitle = "PSADT Sandbox - $Label (running as SYSTEM)" } catch { }
    Write-Host ("-> {0}: started as SYSTEM at {1}" -f $Label, (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Cyan

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $startedAt = Get-Date
    $raw = $null
    $tick = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $codeFile) {
            $raw = Get-Content -LiteralPath $codeFile -Raw -ErrorAction SilentlyContinue
            if ($raw -and ($raw.Trim() -match '^-?\d+$')) { break }
        }
        Start-Sleep -Seconds 2
        $raw = $null
        $tick++
        if (($tick % 5) -eq 0) {
            $secs = [int]((Get-Date) - $startedAt).TotalSeconds
            Write-Host ("   {0}: still running - {1}s of max {2}s" -f $Label, $secs, $TimeoutSeconds) -ForegroundColor DarkGray
        }
    }
    # Same stderr trap as /Create and /Run: a task that is already gone makes schtasks write to stderr,
    # which would end the whole run here - during CLEANUP, after the action itself already succeeded.
    # Nothing about this call's outcome changes the verdict, so it neither throws nor is checked.
    & {
        $ErrorActionPreference = 'Continue'
        & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
    }

    if (-not $raw) { return [pscustomobject]@{ ExitCode = $null; Output = ''; TimedOut = $true } }

    # The .cmd writes the output file and the exit-code file on two consecutive lines, but that does not
    # guarantee the output file's bytes are visible to THIS process the moment the exit-code file is:
    # Defender briefly locking a freshly-written file for a scan is enough to turn the -ErrorAction
    # SilentlyContinue read into a silently EMPTY result, which a detection step then reads as "not
    # detected". Observed exactly that - a step captured stdout as '' while the same file, re-read when
    # the evidence was copied out at the end of the run, held the real result all along. The retry
    # separates a genuinely empty result (stays empty across every attempt - the normal case for an
    # absent app) from a transiently unreadable one (fills in within an attempt or two).
    [string]$out = ''
    if (Test-Path -LiteralPath $outFile) {
        for ($i = 0; $i -lt 3; $i++) {
            $out = '' + (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
            if ($out) { break }
            Start-Sleep -Milliseconds 300
        }
    }
    return [pscustomobject]@{ ExitCode = [int]$raw.Trim(); Output = $out; TimedOut = $false }
}

function Invoke-Deployment {
    param([string]$Label, [string]$DeploymentType)
    $exe = Join-Path $pkg 'Invoke-AppDeployToolkit.exe'
    $r = Invoke-AsSystem -Label $Label -CommandLine "`"$exe`" -DeploymentType $DeploymentType -DeployMode Silent" -TimeoutSeconds $actionTimeout
    $ok = (-not $r.TimedOut) -and ($successExitCodes -contains $r.ExitCode)
    $step = @{ exitCode = $r.ExitCode; timedOut = $r.TimedOut; success = $ok }

    # 60008 is the launcher's own "Initialization failed" code: the toolkit could not be imported or
    # the session could not be opened, so nothing was deployed and no PSADT log was written. The .exe
    # runs the .ps1 hidden and discards its stderr, so all that ever reaches this loop is the number -
    # on 2026-09-11 it took two separate probe VMs to read the one line behind it. Because nothing ran,
    # re-running the action ONCE through powershell.exe -File is side-effect-free, and it captures the
    # error text the .exe threw away. 60001 is deliberately excluded: there the hook already executed
    # and the PSADT log holds the cause.
    if (-not $r.TimedOut -and $r.ExitCode -eq 60008) {
        $ps1 = Join-Path $pkg 'Invoke-AppDeployToolkit.ps1'
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $d = Invoke-AsSystem -Label "$Label.Diagnostic" -CommandLine "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File `"$ps1`" -DeploymentType $DeploymentType -DeployMode Silent" -TimeoutSeconds $actionTimeout
        $diag = (('' + $d.Output) -replace '\s+', ' ').Trim()
        if ($diag.Length -gt 1200) { $diag = $diag.Substring(0, 1200) + ' ...' }
        $step.diagnostic = "$Label exited 60008 (initialization failed, nothing deployed). Re-run via powershell.exe -File said: $diag"
        Write-Host "   !! $($step.diagnostic)" -ForegroundColor Yellow
    }

    Add-Step $Label $step
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

    # Every deployment action below goes through schtasks /RU SYSTEM /RL HIGHEST, which needs the full
    # administrator token that <LogonCommand> supplies.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isElevated = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Add-Step 'Elevation' @{ elevated = $isElevated; identity = $identity.Name }
    if (-not $isElevated) {
        throw "The sandbox runner is not elevated, so schtasks /RU SYSTEM /RL HIGHEST cannot work."
    }

    # Elevation is NECESSARY BUT NOT SUFFICIENT, and believing otherwise is what made 2026-09-11
    # expensive. A runner started from the guest's Startup folder passed the check above and still could
    # not make the Task Scheduler run ANYTHING: schtasks /Create and /Run both returned exit 0 while the
    # task never executed, and the cmdlet route was refused outright ("Cannot connect to CIM server.
    # Access denied"). All seven deployment actions then died on identical timeouts that named no cause,
    # and the evidence pointed at the package instead of at the harness.
    #
    # So prove the mechanism ONCE, in seconds, before spending twenty minutes per action on it. whoami
    # is the smallest command that answers the only question that matters: did something actually run,
    # and did it run as SYSTEM?
    $canary = Invoke-AsSystem -Label 'SystemTaskCanary' -CommandLine 'whoami.exe' -TimeoutSeconds 90
    $canaryWho = ('' + $canary.Output).Trim()
    Add-Step 'SystemTaskCanary' @{ exitCode = $canary.ExitCode; timedOut = $canary.TimedOut; ranAs = $canaryWho }
    if ($canary.TimedOut -or $canaryWho -notmatch '(?i)system') {
        throw ("The sandbox cannot run a scheduled task as SYSTEM, so no deployment action could " +
            "succeed here. A canary task that only runs whoami.exe " +
            $(if ($canary.TimedOut) { 'never produced any output' } else { "reported '$canaryWho' instead of SYSTEM" }) +
            ". This is a HARNESS/environment fault, not a fault in the package under test. The usual " +
            "cause is the runner being started with a token that cannot drive the Task Scheduler - " +
            "check that the .wsb still uses <LogonCommand> rather than a Startup-folder trigger.")
    }

    # --- Guest preparation: PowerShell module resources the sandbox image is missing -----------------
    # PSADT imports Microsoft.PowerShell.Archive when it loads. That module localises its messages via
    # Import-LocalizedData, and Windows PowerShell 5.1 does NOT fall back to another culture when the
    # resource folder for the current UI culture is absent - the import throws, and every
    # Invoke-AppDeployToolkit.ps1 dies in its Initialization block with 60008 before writing one log
    # line. The sandbox base image on a de-DE host had exactly that hole on 2026-09-11: module present,
    # de-DE\ArchiveResources.psd1 absent, while the host itself carried the file. A real device has its
    # language pack, so this is a guest artefact - and the guest is patched to look like a real device.
    # The host's culture folders for the modules PSADT imports were copied into the work folder at
    # generation time; they are laid down here wherever the guest lacks them. Administrators hold Modify
    # on these folders. Should a copy still fail, the PSADT module canary below reports the real error.
    $resSrc = Join-Path $mapped 'ps-module-resources'
    $modRoot = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\Modules'
    $shimmed = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $resSrc) {
        foreach ($mod in (Get-ChildItem -LiteralPath $resSrc -Directory)) {
            $dstMod = Join-Path $modRoot $mod.Name
            if (-not (Test-Path -LiteralPath $dstMod)) { continue }   # module not in the image - nothing to localise
            foreach ($culture in (Get-ChildItem -LiteralPath $mod.FullName -Directory)) {
                $dst = Join-Path $dstMod $culture.Name
                if (Test-Path -LiteralPath $dst) { continue }
                try {
                    Copy-Item -LiteralPath $culture.FullName -Destination $dst -Recurse -Force -ErrorAction Stop
                    $shimmed.Add("$($mod.Name)\$($culture.Name)")
                } catch {
                    Write-Host "   !! could not lay down $($mod.Name)\$($culture.Name): $($_.Exception.Message)"
                }
            }
            # Culture-neutral fallback at the module root: Import-LocalizedData ends its search in the base
            # directory, so this resolves even a guest UI culture the host does not carry.
            $anyRes = Get-ChildItem -LiteralPath $mod.FullName -Recurse -File -Filter '*.psd1' | Select-Object -First 1
            if ($anyRes -and -not (Test-Path -LiteralPath (Join-Path $dstMod $anyRes.Name))) {
                try {
                    Copy-Item -LiteralPath $anyRes.FullName -Destination $dstMod -Force -ErrorAction Stop
                    $shimmed.Add("$($mod.Name)\$($anyRes.Name) (root fallback)")
                } catch { }
            }
        }
    }
    # WMI/CIM must answer SYSTEM: Initialize-ADTModule queries root\cimv2:Win32_ComputerSystem for the
    # hardware platform, and on 2026-09-11 that query came back 0x80070005 (Access denied) inside the
    # guest - for SYSTEM and for the elevated runner alike - so Open-ADTSession threw and every action
    # exited 60008 even after the module import had been repaired. The same guest image had passed on
    # 2026-09-08; the host's cumulative updates of 2026-09-11 are the only change in between. The WMI
    # repository carries the namespace security descriptors, so it is salvaged and, failing that, reset.
    # Both are safe here: the VM is discarded when the run ends. The outcome is recorded either way and
    # the session canary below turns a still-broken WMI into a named failure instead of 7 x 60008.
    $wmiState = 'unknown'
    try {
        $svc = Get-Service -Name 'Winmgmt' -ErrorAction Stop
        if ($svc.StartType -eq 'Disabled') { Set-Service -Name 'Winmgmt' -StartupType Automatic }
        if ($svc.Status -ne 'Running') { Start-Service -Name 'Winmgmt' -ErrorAction Stop }
        $null = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $wmiState = 'OK'
    } catch {
        $firstError = $_.Exception.Message
        $wmiState = "denied ($firstError)"
        foreach ($attempt in @('salvage', 'reset')) {
            try {
                Write-Host "   !! WMI refused Win32_ComputerSystem ($firstError) - trying winmgmt /${attempt}repository" -ForegroundColor Yellow
                & { $ErrorActionPreference = 'Continue'; & winmgmt.exe "/${attempt}repository" 2>&1 | Out-Null }
                Restart-Service -Name 'Winmgmt' -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 5
                $null = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
                $wmiState = "OK after winmgmt /${attempt}repository (was: $firstError)"
                break
            } catch {
                $wmiState = "STILL denied after winmgmt /${attempt}repository ($($_.Exception.Message))"
            }
        }
    }
    Add-Step 'GuestPrepare' @{ uiCulture = (Get-UICulture).Name; wmi = $wmiState; resourcesShimmed = $(if ($shimmed.Count) { $shimmed -join ', ' } else { 'none needed' }) }

    # The mapped package folder is read-only and PSADT unblocks files under its own root, so work on a copy.
    Copy-Item -LiteralPath $pkgSrc -Destination $pkg -Recurse -Force
    Get-ChildItem -LiteralPath $pkg -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    # --- PSADT module canary: can the package's toolkit be IMPORTED as SYSTEM in this guest? ---------
    # Invoke-AppDeployToolkit.exe swallows the .ps1's stderr, so a failing toolkit import shows up only
    # as a bare 60008 on every action and no log anywhere - exactly how 2026-09-11 presented, and it took
    # a separate probe VM to read the one line that explained it. Import the toolkit once, as SYSTEM,
    # with stderr captured, and stop with the REAL error text before the loop starts.
    # Two stages, because they failed for two different reasons on the same day: the IMPORT (missing
    # localized resource, fixed by GuestPrepare) and then OPEN-ADTSESSION (WMI refused to SYSTEM). The
    # canary session is Silent, named so it cannot be mistaken for the package, and its log is removed
    # again on success so it never lands in the package's evidence.
    $modCanaryScript = Join-Path $work 'PsadtModuleCanary.ps1'
    @(
        "`$ErrorActionPreference = 'Stop'"
        "try { Import-Module -Name '$pkg\PSAppDeployToolkit\PSAppDeployToolkit.psd1' -Force; Write-Output 'PSADT_MODULE_OK' }"
        "catch { Write-Output ('PSADT_MODULE_FAILED: ' + `$_.Exception.Message); exit 1 }"
        "try { `$null = Open-ADTSession -AppVendor 'PSADT' -AppName 'SandboxCanary' -AppVersion '1.0' -DeploymentType Install -DeployMode Silent -LogName 'PsadtSandboxCanary.log' -PassThru; Write-Output 'PSADT_SESSION_OK'; Close-ADTSession -ExitCode 0 -NoShellExit }"
        "catch { Write-Output ('PSADT_SESSION_FAILED: ' + `$_.Exception.Message); exit 2 }"
    ) | Set-Content -LiteralPath $modCanaryScript -Encoding ASCII
    $psExeCanary = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $mc = Invoke-AsSystem -Label 'PsadtModuleCanary' -CommandLine "`"$psExeCanary`" -NoProfile -ExecutionPolicy Bypass -File `"$modCanaryScript`"" -TimeoutSeconds 300
    $mcOut = (('' + $mc.Output) -replace '\s+', ' ').Trim()
    Add-Step 'PsadtModuleCanary' @{ exitCode = $mc.ExitCode; timedOut = $mc.TimedOut; result = $(if ($mcOut.Length -gt 600) { $mcOut.Substring(0, 600) } else { $mcOut }) }
    if ($mc.TimedOut -or $mcOut -notmatch 'PSADT_SESSION_OK') {
        $stage = if ($mcOut -notmatch 'PSADT_MODULE_OK') { 'imported' } else { 'opened as a session' }
        throw ("The package's PSAppDeployToolkit cannot be $stage as SYSTEM inside this guest, so every " +
            "deployment action would exit 60008 without writing a log. Real error: " +
            $(if ($mc.TimedOut) { 'the canary never returned' } else { $mcOut }) +
            ". A missing localized resource (e.g. ArchiveResources.psd1) means the sandbox image lacks a " +
            "language-pack file a real device has; 'Win32_ComputerSystem ... 0x80070005' means WMI refuses SYSTEM " +
            "in this guest - see the GuestPrepare step for what was attempted. Both are HARNESS/environment " +
            "faults, not faults in the package under test.")
    }
    Remove-Item -LiteralPath (Join-Path $env:WinDir 'Logs\Software\PsadtSandboxCanary.log') -Force -ErrorAction SilentlyContinue

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

    # Same stderr trap as the schtasks calls: $ErrorActionPreference is 'Stop', and in WinPS 5.1 a
    # native command writing to stderr raises a terminating NativeCommandError. This is the LAST
    # statement of the run and the one that tears the VM down - if it throws, the guest never shuts
    # itself down, the vmmemWindowsSandbox worker keeps holding the mapped folder, and the next run
    # is refused because Windows permits only one sandbox instance. Exactly that orphan blocked a
    # re-run on 2026-09-11.
    & {
        $ErrorActionPreference = 'Continue'
        & shutdown.exe /s /t 0 2>&1 | Out-Null
    }
}
'@

# The work folder keeps its default mapping - the guest desktop - and the runner is started by the
# .wsb LogonCommand.
#
# 0.28.0 replaced LogonCommand with a Startup-folder trigger to work around
# microsoft/Windows-Sandbox#125 (LogonCommand never spawns a process on some Sandbox app versions).
# Wherever LogonCommand DOES work, that workaround is worse than the bug it avoids, and it fails
# silently: a Startup item is launched by Explorer, and although the resulting process still passes an
# IsInRole(Administrator) check, its token cannot drive the Task Scheduler. Measured inside the guest
# on 2026-09-11 (Sandbox app 0.8.107.0, guest 10.0.26100), with a standalone probe:
#   * schtasks.exe /Create AND /Run both return exit 0 while the task NEVER executes - no marker file
#     is ever written, so every deployment action reports a bare timeout that names no cause;
#   * Register-ScheduledTask / Get-ScheduledTaskInfo fail with "Cannot connect to CIM server. Access
#     denied", so the cmdlet route is not an alternative on that token either.
# Under LogonCommand the very same schtasks calls work: five GREEN runs on this host, 2026-09-07 to
# 2026-09-10, against the same Sandbox app version. LogonCommand therefore stays. #125 belongs where
# it is already handled - the host times out waiting for DONE.txt and says the runner never started -
# rather than being traded for a failure mode that looks like a broken package.
$guestDesktop = 'C:\Users\WDAGUtilityAccount\Desktop'
$guestRunner  = "$guestDesktop\$workLeaf\Run-PsadtSandboxTest.ps1"

$runner = $runnerTemplate.
    Replace('__MAPPEDROOT__', "$guestDesktop\$workLeaf").
    Replace('__PACKAGELEAF__', $packageLeaf).
    Replace('__DETECTIONSCRIPT__', ($DetectionScript -replace "'", "''")).
    Replace('__SUCCESSCODES__', ('@(' + ($SuccessExitCodes -join ', ') + ')')).
    Replace('__ACTIONTIMEOUT__', [string]$ActionTimeoutSeconds).
    Replace('__PATHSPRESENTINSTALL__', (ConvertTo-PsArrayLiteral $PathsPresentAfterInstall)).
    Replace('__PATHSABSENTINSTALL__', (ConvertTo-PsArrayLiteral $PathsAbsentAfterInstall)).
    Replace('__PATHSABSENTUNINSTALL__', (ConvertTo-PsArrayLiteral $PathsAbsentAfterUninstall))

$runnerPath = Join-Path $workFolder 'Run-PsadtSandboxTest.ps1'
[System.IO.File]::WriteAllText($runnerPath, $runner, [System.Text.UTF8Encoding]::new($true))

# --- 4a. PowerShell module resources for the guest --------------------------------------------------
# The sandbox base image can lack the localized resource folders (<culture>\*.psd1) of modules that
# PSADT imports at load - measured 2026-09-11: Microsoft.PowerShell.Archive without de-DE\ on a de-DE
# host that has it. Windows PowerShell 5.1 then throws on import instead of falling back, and every
# launcher exits 60008 before its first log line. The host has whatever its language pack installed, so
# its culture folders are shipped along and the runner lays them down inside the guest (GuestPrepare).
# Only the modules PSADT's own import list names are considered; the psd1 filter keeps this to resource
# files, never module code.
$modRootHost = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\Modules'
$resDest = Join-Path $workFolder 'ps-module-resources'
foreach ($modName in 'Microsoft.PowerShell.Archive', 'Dism', 'International', 'NetAdapter', 'ScheduledTasks') {
    $modDir = Join-Path $modRootHost $modName
    if (-not (Test-Path -LiteralPath $modDir)) { continue }
    foreach ($cultureDir in (Get-ChildItem -LiteralPath $modDir -Directory | Where-Object { $_.Name -match '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$' })) {
        if (-not (Get-ChildItem -LiteralPath $cultureDir.FullName -File -Filter '*.psd1' -ErrorAction SilentlyContinue)) { continue }
        $target = Join-Path (Join-Path $resDest $modName) $cultureDir.Name
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Copy-Item -Path (Join-Path $cultureDir.FullName '*.psd1') -Destination $target -Force
    }
}

# --- 4b. LogonCommand line -------------------------------------------------------------------------
# Deliberately NOT -WindowStyle Hidden: the console this opens inside the VM is the only thing an
# operator watching the sandbox can see, and every deployment action below runs as SYSTEM through a
# scheduled task, which by design draws nothing on the desktop. Without a visible window the VM looks
# idle for minutes during a perfectly healthy install, which is indistinguishable from a hang.
$logonCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$guestRunner`""
if ($GuestSettleDelaySeconds -gt 0) {
    # ping, not timeout: timeout needs a console it owns and aborts with "input redirection is not
    # supported" when it does not have one.
    # The delay has to happen BEFORE the runner is launched, not inside it: the runner .ps1 itself lives
    # in the mapped folder, so a mount that has not settled yet breaks the launch, not just the first read.
    # Note the '&' - the value is XML-escaped on the way into the .wsb below, without which the whole
    # configuration fails to parse and Windows Sandbox starts with no mapped folders at all.
    $logonCommand = "cmd.exe /c `"ping.exe -n $($GuestSettleDelaySeconds + 1) 127.0.0.1 > nul & $logonCommand`""
}

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
    <Command>$([System.Security.SecurityElement]::Escape($logonCommand))</Command>
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
# Start-Process does not quote -ArgumentList elements itself. A path containing a space - routine as
# soon as the Windows username has one, which also puts one in %LOCALAPPDATA% - is split into several
# argv entries, so WindowsSandbox.exe receives a garbled config path and boots with NO custom
# MappedFolders at all. It reports no error while doing it, which reads exactly like an upstream bug.
Start-Process -FilePath $sandboxExe -ArgumentList "`"$wsbPath`"" | Out-Null

$hostDeadline = (Get-Date).AddMinutes($TotalTimeoutMinutes)
$sawSandbox = $false
while ((Get-Date) -lt $hostDeadline) {
    if (Test-Path -LiteralPath $donePath) { break }
    $alive = @(Get-Process -Name 'WindowsSandboxServer' -ErrorAction SilentlyContinue).Count -gt 0
    if ($alive) { $sawSandbox = $true }
    elseif ($sawSandbox) { break }   # the VM went away without writing DONE.txt
    Start-Sleep -Seconds 10
}

# How long to wait for the VM worker to disappear after the guest has shut itself down. Named once:
# this value is quoted back to the user in the warning below, and a literal in that message used to
# drift from the actual wait (it claimed 60 seconds while the code waited 180).
$sandboxStopTimeoutSeconds = 180

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
    param([int]$TimeoutSeconds = $sandboxStopTimeoutSeconds)

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

# Which of the three terminal states did the wait loop above end in? They are NOT interchangeable:
#   * DONE.txt written        -> the guest shut itself down. Only the leftover viewer needs disposing of.
#   * the VM went away        -> nothing left to do; Stop-SandboxInstance returns immediately.
#   * the HOST gave up first  -> the guest is STILL RUNNING and was never told to stop.
# The third case must not be handled like the other two. Killing the viewer there is worse than doing
# nothing: it orphans the vmmemWindowsSandbox worker (the Hyper-V compute service owns it, so the host
# cannot terminate it) which keeps holding the mapped folder, AND it destroys the window that was the
# user's only way to shut the guest down cleanly. The old code did exactly that and then advised closing
# a window it had just killed.
$hostTimedOut = (-not $verdictFile) -and
    @(Get-Process -Name 'WindowsSandboxServer' -ErrorAction SilentlyContinue).Count -gt 0

# Tear the VM down before touching the work folder: while the sandbox lives it holds the mapped-folder
# handle, which is what made the cleanup below need a retry loop in the first place.
if (-not $KeepSandboxOpen) {
    if ($hostTimedOut) {
        Write-Warning "The host stopped waiting after $TotalTimeoutMinutes minutes, but the sandbox is still running. It is deliberately left alone: killing it from here would orphan the vmmemWindowsSandbox worker, which then holds '$workRoot' open until a reboot. Close the Windows Sandbox window yourself and confirm the discard prompt - that shuts the guest down cleanly and releases the folder. Raise -TotalTimeoutMinutes if the package simply needs longer."
    }
    elseif (-not (Stop-SandboxInstance)) {
        Write-Warning "The Windows Sandbox VM worker did not exit within $sandboxStopTimeoutSeconds seconds. It holds '$workRoot' open until it does; the folder is wiped at the start of the next run for this package."
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

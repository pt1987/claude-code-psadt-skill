<#
.SYNOPSIS  Runs ONE PSADT deployment action as the SYSTEM account (via Invoke-CommandAs) and reports structured facts.
.DESCRIPTION
  Executes Invoke-AppDeployToolkit.exe -DeploymentType <X> -DeployMode Silent as SYSTEM, optionally runs a
  detection script in the same SYSTEM context, reads the fresh PSADT session log, and returns a structured
  result. Performs ONE action and decides nothing about fixes - the caller (skill/agent) drives the loop.
.OUTPUTS PSCustomObject: DeploymentType, ExitCode, Success, DetectionState, LogPath, LogTail, ErrorLines, Elevated
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][ValidateSet('Install','Uninstall','Repair')][string]$DeploymentType,
    [string]$DetectionScript,
    [int[]]$SuccessExitCodes = @(0, 1707, 3010, 1641),
    [string]$LogDirectory = 'C:\Windows\Logs\Software',
    [bool]$IsElevated = (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)),
    # Unused downstream; accepted so callers can pass it through. Empty = Get-PsadtConfig resolves the home.
    [string]$SkillRoot,
    # Internal: when set, write the result object as JSON here instead of emitting it. Used by the
    # WinPS 5.1 re-exec child below to hand its result back to a PowerShell 7 (Core) parent.
    [string]$ResultJsonPath,
    # Internal: SuccessExitCodes forwarded as CSV by the re-exec parent. [int[]] params do NOT bind
    # through `powershell.exe -File` (only the first value binds), so we marshal them as a string.
    [string]$SuccessExitCodesCsv
)
$ErrorActionPreference = 'Stop'
if ($SuccessExitCodesCsv) { $SuccessExitCodes = [int[]]($SuccessExitCodesCsv -split ',' | ForEach-Object { [int]$_ }) }

# 1. Elevation guard - creating a SYSTEM scheduled task needs admin
if (-not $IsElevated) {
    throw "Invoke-PsadtSystemTest must run in an ELEVATED PowerShell session (SYSTEM scheduled task creation requires admin). Re-run as Administrator."
}

# 1b. PowerShell edition guard - Invoke-CommandAs -AsSystem relies on the PSScheduledJob module
#     (New-ScheduledJobOption / Register-ScheduledJob). PSScheduledJob is a Windows PowerShell 5.1-only
#     module and is BLOCKED from loading under PowerShell 7 (Core) by the WindowsPowerShellCompatibility
#     deny list. So when launched from pwsh, transparently re-run this script under Windows PowerShell 5.1
#     and marshal the structured result back via a temp JSON file.
#     ($env:PSADT_SYSTEMTEST_NOREEXEC=1 is a unit-test seam: it exercises the in-process logic under pwsh 7
#     without spawning the 5.1 child - never set it for a real SYSTEM run.)
if ($PSVersionTable.PSEdition -eq 'Core' -and $env:PSADT_SYSTEMTEST_NOREEXEC -ne '1') {
    $winPs = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $winPs)) { throw "Windows PowerShell 5.1 not found at '$winPs' - required because PSScheduledJob cannot load under PowerShell 7." }
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PSCommandPath,
                     '-PackagePath', $PackagePath, '-DeploymentType', $DeploymentType)
        if ($DetectionScript) { $argList += @('-DetectionScript', $DetectionScript) }
        if ($PSBoundParameters.ContainsKey('LogDirectory')) { $argList += @('-LogDirectory', $LogDirectory) }
        if ($PSBoundParameters.ContainsKey('SuccessExitCodes')) { $argList += @('-SuccessExitCodesCsv', ($SuccessExitCodes -join ',')) }
        $argList += @('-ResultJsonPath', $tmp)
        $childOut = & $winPs @argList *>&1 | Out-String
        $json = if (Test-Path $tmp) { Get-Content $tmp -Raw } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($json)) { return ($json | ConvertFrom-Json) }
        throw "SYSTEM test child (Windows PowerShell 5.1) produced no result.`nChild output:`n$childOut"
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Get-FreshSessionLog {
    # Which log belongs to THIS run? Since 0.21.0 the generated launchers set a per-run LogName
    # (<Vendor>_<App>_<Version>_<Arch>_<Type>_<timestamp>.log), while packages scaffolded before that - and
    # anything built from the raw PSADT template - still write <...>PSAppDeployToolkit_<Type>.log and APPEND
    # to it. So both shapes are accepted, and the deciding filter is time: a file that was not written
    # during this run cannot be this run's log, no matter how well its name matches. Without that, a stale
    # legacy log from last week wins the "newest" contest and the verdict is read from the wrong file.
    param(
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][string]$DeploymentType,
        [Parameter(Mandatory)][datetime]$Since
    )
    if (-not (Test-Path $LogDirectory)) { return $null }
    $perRun = "*_$($DeploymentType)_*.log"                       # 0.21.0+
    $legacy = "*PSAppDeployToolkit_$($DeploymentType).log"       # pre-0.21 and raw template
    $candidates = @(
        Get-ChildItem -Path $LogDirectory -Filter $perRun -File -ErrorAction SilentlyContinue
        Get-ChildItem -Path $LogDirectory -Filter $legacy -File -ErrorAction SilentlyContinue
    ) | Sort-Object FullName -Unique | Where-Object { $_.LastWriteTime -ge $Since }
    return ($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

# 2. Ensure the Invoke-CommandAs module is present (self-heal from PSGallery)
if (-not (Get-Module -ListAvailable -Name Invoke-CommandAs)) {
    Install-Module -Name Invoke-CommandAs -Scope CurrentUser -Force -AllowClobber
}
Import-Module Invoke-CommandAs -ErrorAction SilentlyContinue

$exe = Join-Path $PackagePath 'Invoke-AppDeployToolkit.exe'

# 3. Run the launcher (and optional detection) as SYSTEM in one context
$sb = {
    param($Exe, $Dt, $Detect)
    $deployOut  = & $Exe -DeploymentType $Dt -DeployMode Silent 2>&1 | Out-String
    $deployExit = $LASTEXITCODE
    $detExit = $null; $detOut = $null
    if ($Detect) {
        $detOut  = & $Detect 2>&1 | Out-String
        $detExit = $LASTEXITCODE
    }
    [pscustomobject]@{ DeployExitCode = $deployExit; DeployOutput = $deployOut; DetectExitCode = $detExit; DetectOutput = $detOut }
}
# A second of slack: the log's LastWriteTime is written by the SYSTEM process, whose clock resolution and
# our own are not the same thing, and a log created in the same tick must not be excluded.
$runStart = (Get-Date).AddSeconds(-1)
$run = Invoke-CommandAs -AsSystem -ScriptBlock $sb -ArgumentList $exe, $DeploymentType, $DetectionScript

# 4. Locate + read the fresh PSADT session log
$log = Get-FreshSessionLog -LogDirectory $LogDirectory -DeploymentType $DeploymentType -Since $runStart
$logPath = if ($log) { $log.FullName } else { $null }
$logTail = if ($logPath) { (Get-Content $logPath -Tail 40) -join "`n" } else { '' }
$errorLines = @()
if ($logTail) { $errorLines = @($logTail -split "`n" | Where-Object { $_ -match '\[Error\]|ERROR|Exception' }) }

# 5. Interpret detection (installed = exit 0 AND non-empty stdout, per Intune custom-detection contract)
$state = 'unknown'
if ($DetectionScript) {
    $installed = ($run.DetectExitCode -eq 0) -and (-not [string]::IsNullOrWhiteSpace([string]$run.DetectOutput))
    $state = if ($installed) { 'installed' } else { 'not-installed' }
}

# 6. Success per action
$exitOk  = $SuccessExitCodes -contains [int]$run.DeployExitCode
$success = switch ($DeploymentType) {
    'Uninstall' { $exitOk -and ( -not $DetectionScript -or $state -eq 'not-installed' ) }
    default     { $exitOk -and ( -not $DetectionScript -or $state -eq 'installed' ) }
}

$result = [pscustomobject]@{
    DeploymentType = $DeploymentType
    ExitCode       = [int]$run.DeployExitCode
    Success        = [bool]$success
    DetectionState = $state
    LogPath        = $logPath
    LogTail        = $logTail
    ErrorLines     = $errorLines
    Elevated       = $true
}

# When invoked as the WinPS 5.1 re-exec child, hand the result back via JSON (UTF-8, no BOM, so the
# Core parent's ConvertFrom-Json reads it cleanly). Otherwise emit the object to the pipeline as usual.
if ($ResultJsonPath) {
    [System.IO.File]::WriteAllText($ResultJsonPath, ($result | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
} else {
    $result
}

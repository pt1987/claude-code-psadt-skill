<#
.SYNOPSIS
    Is the package's recorded pre-flight verdict GREEN and newer than every file it judged?

.DESCRIPTION
    The hard handoff "Builder may not package until Reviewer returns GREEN on pre-flight" was, until 0.44.0,
    a sentence in SKILL.md and nothing else: Invoke-PsadtPackage.ps1 and Invoke-PsadtSandboxTest.ps1 never
    looked. On Google Chrome 154 a package went into the sandbox with its researchers still out; with the
    Research check (Invoke-PsadtPreflight.ps1, check 11) that pre-flight would have been RED - but only if
    something reads the verdict. This is that something.

    Current = results.preflight.verdict is GREEN AND results.preflight.at is not older than the newest
    launcher, Extensions module, detection script or file under Files\ / SupportFiles\. An edit after the
    pre-flight makes the verdict stale, which is the same as having none.

    Read-only. Invoke-PsadtPackage.ps1 and Invoke-PsadtSandboxTest.ps1 call it and refuse unless it is
    current, or unless their -SkipPreflightGate is passed deliberately.

.PARAMETER PackagePath
    The package folder (the one containing Invoke-AppDeployToolkit.ps1).

.OUTPUTS
    PSCustomObject: Current (bool), Reason (string), Verdict, At, NewestFile, NewestAt
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath
)
$ErrorActionPreference = 'Stop'

$PackagePath = (Resolve-Path -LiteralPath $PackagePath).ProviderPath.TrimEnd('\')
$mf = & (Join-Path $PSScriptRoot 'Get-PsadtPackageManifest.ps1') -PackagePath $PackagePath
$pf = if ($mf.Exists -and -not $mf.Error) { $mf.Manifest.results.preflight } else { $null }

$judged = @()
$judged += @(Get-Item -LiteralPath (Join-Path $PackagePath 'Invoke-AppDeployToolkit.ps1') -ErrorAction SilentlyContinue)
$judged += @(Get-ChildItem -LiteralPath (Join-Path $PackagePath 'PSAppDeployToolkit.Extensions') -Filter '*.psm1' -File -ErrorAction SilentlyContinue)
$judged += @(Get-ChildItem -LiteralPath $PackagePath -Filter 'Detect*.ps1' -File -ErrorAction SilentlyContinue)
foreach ($d in 'Files', 'SupportFiles') {
    $judged += @(Get-ChildItem -LiteralPath (Join-Path $PackagePath $d) -File -Recurse -ErrorAction SilentlyContinue)
}
$newest = @($judged | Where-Object { $_ } | Sort-Object LastWriteTimeUtc -Descending)[0]

$at = $null
if ($pf -and $pf.at) {
    # ConvertFrom-Json in PowerShell 7 already turns an ISO string into a DateTime; 5.1 leaves a string.
    $at = if ($pf.at -is [datetime]) { ([datetime]$pf.at).ToUniversalTime() } else { [datetime]::Parse([string]$pf.at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
}

$reason = $null
if (-not $pf) {
    $reason = 'no pre-flight verdict recorded - run Invoke-PsadtPreflight.ps1 first'
} elseif ([string]$pf.verdict -ne 'GREEN') {
    $reason = "the recorded pre-flight verdict is $($pf.verdict) - fix the FAIL checks and re-run Invoke-PsadtPreflight.ps1"
} elseif ($newest -and $at -and $newest.LastWriteTimeUtc -gt $at) {
    $reason = "the pre-flight is stale: $($newest.Name) changed at $($newest.LastWriteTimeUtc.ToString('o')), after the GREEN verdict of $($at.ToString('o')) - re-run Invoke-PsadtPreflight.ps1"
}

[pscustomobject]@{
    Current    = -not $reason
    Reason     = $(if ($reason) { $reason } else { 'GREEN and newer than every file it judged' })
    Verdict    = $(if ($pf) { [string]$pf.verdict } else { $null })
    At         = $at
    NewestFile = $(if ($newest) { $newest.FullName } else { $null })
    NewestAt   = $(if ($newest) { $newest.LastWriteTimeUtc } else { $null })
}

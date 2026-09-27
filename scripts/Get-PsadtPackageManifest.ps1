<#
.SYNOPSIS
    Reads a package's psadt-package.json (the per-app single source of truth) and reports what is missing.

.DESCRIPTION
    Read-only, and it never throws on an incomplete manifest - gaps are listed in .Missing for the caller to
    act on, exactly like Get-PsadtConfig.ps1 does for the machine config. One app, one file, one truth:
    identity, the decisions taken at the gates, the research findings, the results of every phase and the
    artifacts produced. Before 0.21 this lived in the operator's head and in $meta arguments, which is why
    two packages of the same app could disagree about their own version.

    Schema 1 sections:
      app        vendor, name, version, arch, lang, revision, displayName (optional Intune name),
                 description{de,en}; optional App-information fields developer, owner, notes,
                 informationUrl, privacyUrl, minWindowsRelease (Resolve-PsadtIntuneAppInfo, _AppKey.ps1)
      package    name, type (installer|winget|script|browser-extension|windows-feature|driver),
                 installerTech, sourceStrategy, installerFile, installerSha256, productCode,
                 processesToClose[], installCommand, uninstallCommand, detection, selfUpdating
      decisions  gate1, gate2{audience,uninstallScope,repair,reboot,runningApp,deployMode}, systemTest,
                 upload
      research   switches, exitCodes, logPaths, leftovers, returnCodes[] ({ code, type, de, en } -
                 installer-specific Intune return codes; type is one of success/softReboot/hardReboot/
                 retry/failed and is validated by Get-PsadtReturnCodes.ps1)
      driverTrust classification, owner, thumbprint
      results    preflight, sandboxTest, systemTest[], package, report, upload, assignment (read back
                 from Intune), supersedence{supersedes[], supersedesApps[]}, supersededBy
      artifacts  outputFolder, intunewin, detection, dossier, logo, logs[]

    .Stem is the BINDING artifact name, ALWAYS derived from the identity: <Vendor>_<App>_<Version>_<Arch>,
    spaces to underscores, reduced to [A-Za-z0-9._-], ASCII. It is $null while the identity is incomplete -
    a partial identity must never produce a half-named file. package.name is where that stem gets recorded
    for other tools to read; it is never read back as the source, or a stale cache would win over a version
    bump.

.PARAMETER PackagePath
    The package folder (the one containing Invoke-AppDeployToolkit.ps1).

.PARAMETER Identity
    Derive a stem WITHOUT a package on disk: @{ vendor=..; name=..; version=..; arch=.. }. The generators
    need the stem while they are still writing the launcher, and the sanitizing rule must exist exactly
    once - a second copy would drift and rename an app behind everyone's back.

.PARAMETER Manifest
    An already-parsed manifest object: returns only what is derived from it (Commands, TestGate), with no
    package on disk. For the dossier, whose fixtures and callers need not have a launcher beside the file.

.OUTPUTS
    PSCustomObject: Exists(bool), Manifest(object|null), Missing(string[]), Path(string), Stem(string|null),
    Commands({ Install, Uninstall } each { Command, DeployMode, Recorded, Valid } - the Silent default when
    nothing is recorded, Valid = $false - with Reason - for anything but the launcher's own command line
    with -DeployMode Silent),
    TestGate({ Passed, Route (sandbox|dev-vm|$null), Code, Reason } - rule:test-before-upload, derived
    once: the upload enforces it before any token, the dossier shows it),
    Error(string, only when the file is malformed)

.EXAMPLE
    $m = & Get-PsadtPackageManifest.ps1 -PackagePath D:\Pakete\MxMC
    if ($m.Missing) { ... Set-PsadtPackageManifest.ps1 ... }
#>
[CmdletBinding(DefaultParameterSetName = 'Package')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Package')][string]$PackagePath,
    [Parameter(Mandatory, ParameterSetName = 'Identity')][hashtable]$Identity,
    [Parameter(Mandatory, ParameterSetName = 'Object')][object]$Manifest
)
$ErrorActionPreference = 'Stop'

function ConvertTo-NameToken([string]$value) {
    # File-name safety is not cosmetic here: the stem becomes a folder name, a file name and the
    # win32LobApp fileName, and IntuneWinAppUtil is unforgiving about the last one.
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    # Characters that carry meaning in a product name are SPELLED OUT before the sanitiser drops them.
    # Stripping them collapsed Notepad++ onto Notepad and C# onto C - and the stem is the folder name, the
    # file name and the win32LobApp fileName, so two products sharing one stem overwrite each other.
    $t = $value.Trim()
    $t = $t -replace '\+\+', 'Plus' -replace '\+', 'Plus' -replace '#', 'Sharp' -replace '&', 'And'
    $t = $t -replace '\s+', '_'
    $t = $t -replace '[^A-Za-z0-9._-]', '_'
    $t = $t -replace '_{2,}', '_'
    return $t.Trim('_', '.')
}

if ($PSCmdlet.ParameterSetName -eq 'Identity') {
    $parts = @('vendor', 'name', 'version', 'arch') |
        ForEach-Object { ConvertTo-NameToken ([string]$Identity[$_]) } |
        Where-Object { $_ }
    return [pscustomobject]@{ Stem = ($parts -join '_') }
}

$manifestPath = $null
if ($PSCmdlet.ParameterSetName -eq 'Package') {
    if (-not (Test-Path -LiteralPath $PackagePath)) { throw "PackagePath not found: $PackagePath" }
    $launcher = Join-Path $PackagePath 'Invoke-AppDeployToolkit.ps1'
    if (-not (Test-Path -LiteralPath $launcher)) { throw "Not a PSADT package (no Invoke-AppDeployToolkit.ps1): $PackagePath" }
    $manifestPath = Join-Path $PackagePath 'psadt-package.json'
}

# The identity floor: everything the artifact name and the dossier header are built from.
$required = @('app.vendor', 'app.name', 'app.version', 'app.arch', 'package.type')

function Get-ByPath($obj, [string]$path) {
    $cur = $obj
    foreach ($seg in ($path -split '\.')) {
        if ($null -eq $cur) { return $null }
        $cur = $cur.$seg
    }
    return $cur
}
# The launcher command lines Intune runs (0.49.2). The generators record them as package.installCommand /
# package.uninstallCommand, and this is the ONE place that parses them - before, the upload and the dossier
# each carried their own default and the sandbox a third. The manifest is data and the command runs as
# SYSTEM on every device, so only the launcher's own shape is accepted: the right deployment type, nothing
# chained after it - and -DeployMode Silent, without exception (rule:deploymode-silent, 0.49.3). 0.49.2
# briefly offered Auto at Gate 2; a manifest that still records it is refused with the reason, not run.
function Get-LauncherCommand($Raw, [string]$Type) {
    $silent = "Invoke-AppDeployToolkit.exe -DeploymentType $Type -DeployMode Silent"
    if ([string]::IsNullOrWhiteSpace([string]$Raw)) {
        return [pscustomobject]@{ Command = $silent; DeployMode = 'Silent'; Recorded = $false; Valid = $true; Reason = $null }
    }
    $text = ([string]$Raw).Trim()
    $hit = [regex]::Match($text, "^Invoke-AppDeployToolkit\.exe\s+-DeploymentType\s+$Type\s+-DeployMode\s+(\w+)$", 'IgnoreCase')
    if ($hit.Success -and $hit.Groups[1].Value -eq 'Silent') {
        return [pscustomobject]@{ Command = $silent; DeployMode = 'Silent'; Recorded = $true; Valid = $true; Reason = $null }
    }
    $why = if ($hit.Success) {
        "it runs -DeployMode $($hit.Groups[1].Value); every package runs -DeployMode Silent, without exception"
    } else {
        "it is not the launcher's own command line (expected: $silent) and would run as SYSTEM on every device"
    }
    return [pscustomobject]@{ Command = $text; DeployMode = $null; Recorded = $true; Valid = $false; Reason = $why }
}
function Get-LauncherCommands($manifest) {
    [pscustomobject]@{
        Install   = Get-LauncherCommand (Get-ByPath $manifest 'package.installCommand') 'Install'
        Uninstall = Get-LauncherCommand (Get-ByPath $manifest 'package.uninstallCommand') 'Uninstall'
    }
}
# rule:test-before-upload, derived ONCE (0.49.3). Until then the dossier was the only place that enforced
# it - by refusing to render - while SKILL.md has the dossier rendered while the sandbox is still running,
# and the upload never looked at all. Now the upload enforces this verdict before any token, and the
# dossier shows it. Two routes count:
#   sandbox - results.sandboxTest: a GREEN full gate (all five scenarios) on a package that did not
#             change while the VM ran. GREEN_PARTIAL is not a pass.
#   dev-vm  - results.systemTest[] from Invoke-PsadtSystemTest.ps1: the LATEST Install and the LATEST
#             Uninstall both succeeded. Rows the sandbox appends (context = windows-sandbox) do not count
#             here, or a partial sandbox run would pass through this door on its own rows.
# A recorded timestamp as a point in time. ConvertFrom-Json turns an ISO string into [datetime], and [string]
# of that is '12/30/2026 ...', which sorts after '01/02/2027 ...' - so timestamps are compared as instants,
# never as text (0.49.3). Unreadable or missing is the earliest possible time.
function ConvertTo-Instant($Value) {
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d }
    return [datetime]::MinValue
}
function Get-TestGate($manifest) {
    $rerun = 'pwsh scripts/Invoke-PsadtSandboxTest.ps1 -PackagePath <pkg> (the full gate is the default)'
    $five = @('Install', 'Uninstall', 'Reinstall', 'Repair', 'FinalUninstall')
    $sbx = Get-ByPath $manifest 'results.sandboxTest'
    $dev = @(Get-ByPath $manifest 'results.systemTest') | Where-Object { $_ -and [string]$_.context -ne 'windows-sandbox' }

    $sandboxPassed = $false; $sandboxReason = $null; $sandboxCode = $null
    if ($sbx) {
        $ran = @($sbx.scenarios | ForEach-Object { [string]$_ })
        $missing = @($five | Where-Object { $ran -notcontains $_ })
        if ([string]$sbx.verdict -ne 'GREEN' -or $missing.Count) {
            $sandboxCode = 'not-green'
            $sandboxReason = "the sandbox verdict is '$([string]$sbx.verdict)' (scenarios that ran: $(if ($ran.Count) { $ran -join ', ' } else { 'unknown' })), not a full-gate GREEN - re-run: $rerun"
        } elseif ($sbx.packageChangedDuringRun -eq $true) {
            $sandboxCode = 'changed-during-run'
            $sandboxReason = "the package changed while the sandbox ran, so its GREEN describes files that are no longer there - re-run: $rerun"
        } else { $sandboxPassed = $true }
    }
    if ($sandboxPassed) { return [pscustomobject]@{ Passed = $true; Route = 'sandbox'; Code = 'passed'; Reason = $null } }

    $latest = @{}
    foreach ($row in $dev) {
        $t = [string]$row.type
        if ($t -notin 'Install', 'Uninstall') { continue }
        if (-not $latest.ContainsKey($t) -or ((ConvertTo-Instant $row.at) -ge (ConvertTo-Instant $latest[$t].at))) { $latest[$t] = $row }
    }
    if ($latest.Count) {
        $state = foreach ($t in 'Install', 'Uninstall') {
            if (-not $latest.ContainsKey($t)) { "$t not run" }
            elseif ($latest[$t].success -ne $true) { "$t failed (exit $($latest[$t].exitCode))" }
        }
        if (-not @($state).Count) {
            # A newer DEV-VM pass settles it; a sandbox failure recorded AFTER it does not get overruled.
            $devAt = @($latest.Values | ForEach-Object { ConvertTo-Instant $_.at } | Sort-Object)[-1]
            if (-not $sbx -or -not $sbx.at -or $devAt -gt (ConvertTo-Instant $sbx.at)) {
                return [pscustomobject]@{ Passed = $true; Route = 'dev-vm'; Code = 'passed'; Reason = $null }
            }
        } elseif (-not $sbx) {
            return [pscustomobject]@{ Passed = $false; Route = 'dev-vm'; Code = 'dev-vm-incomplete'
                Reason = "the DEV-VM route needs both Install and Uninstall to pass as SYSTEM: $(@($state) -join '; ') - Invoke-PsadtSystemTest.ps1 (phase 6.2)" }
        }
    }
    if ($sandboxReason) { return [pscustomobject]@{ Passed = $false; Route = 'sandbox'; Code = $sandboxCode; Reason = $sandboxReason } }
    [pscustomobject]@{ Passed = $false; Route = $null; Code = 'not-run'
        Reason = "no SYSTEM test is recorded in the manifest - run: $rerun" }
}
function New-Result([bool]$exists, $manifest, $missing, [string]$stem, [string]$err) {
    $o = [ordered]@{
        Exists = $exists; Manifest = $manifest; Missing = $missing; Path = $manifestPath; Stem = $stem
        Commands = (Get-LauncherCommands $manifest)
        TestGate = (Get-TestGate $manifest)
    }
    if ($err) { $o['Error'] = $err }
    [pscustomobject]$o
}

if ($PSCmdlet.ParameterSetName -eq 'Object') {
    return [pscustomobject]@{ Commands = (Get-LauncherCommands $Manifest); TestGate = (Get-TestGate $Manifest) }
}

if (-not (Test-Path -LiteralPath $manifestPath)) { return (New-Result $false $null $required $null $null) }

# Read and parse apart. A writer's File.Replace holds the file for milliseconds, and a read that lands in
# that window used to be reported as "malformed" - measured 2026-09-27 with two processes on one manifest.
# A busy file is retried briefly (_JsonStore.ps1) and, if it stays busy, named as busy.
. (Join-Path $PSScriptRoot '_JsonStore.ps1')
$fullManifestPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($manifestPath)
try { $rawManifest = Invoke-JsonStoreRetry { [System.IO.File]::ReadAllText($fullManifestPath, [System.Text.Encoding]::UTF8) } }
catch { return (New-Result $true $null $required $null "psadt-package.json could not be read: $($_.Exception.Message)") }
try { $m = $rawManifest | ConvertFrom-Json -ErrorAction Stop }
catch { return (New-Result $true $null $required $null "psadt-package.json is malformed: $($_.Exception.Message)") }

$missing = [System.Collections.Generic.List[string]]::new()
foreach ($key in $required) {
    if ([string]::IsNullOrWhiteSpace([string](Get-ByPath $m $key))) { $missing.Add($key) }
}

$stem = $null
if ($missing.Count -eq 0) {
    # ALWAYS derived from the identity, never read back from package.name. package.name is where the
    # derived stem gets recorded for other tools; if the two ever disagree, the identity is the truth and
    # the cached name is stale. Letting the cache win would silently rename an app after a version bump.
    $parts = @('app.vendor', 'app.name', 'app.version', 'app.arch') |
        ForEach-Object { ConvertTo-NameToken ([string](Get-ByPath $m $_)) } |
        Where-Object { $_ }
    $stem = ($parts -join '_')
}

New-Result $true $m $missing.ToArray() $stem $null

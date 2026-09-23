<#
.SYNOPSIS
    Records what a GREEN full sandbox gate proved, into the machine-local verified-switch store.

.DESCRIPTION
    The write side of %LOCALAPPDATA%\psadt-deploy\verified-switches.json. The read side is stage 0 of
    Get-PsadtSwitchCandidates.ps1, which serves an entry as confidence 'verified' on a SHA256 match and
    as 'medium' when only the product name matches. 'verified' outranks every other stage, which is why
    this script is deliberately hard to talk into writing.

    Until this script existed the store had a reader, a confidence tier, a documentation row and no
    producer: every packaging run reported "nothing has been proven on this machine" and the verified
    branch of the evidence ladder was unreachable. Ten applications were packaged in one measured run
    without the file ever being created.

    WHAT IT WRITES, AND WHAT IT REFUSES

    An entry is only written for a full gate that came back GREEN. The verdict alone is not enough: the
    scenario list must cover Install, Uninstall, Reinstall, Repair and FinalUninstall, because -Quick
    reports GREEN_PARTIAL from two scenarios and a package whose uninstall never ran has not been proven.
    Both halves are checked HERE rather than at the call site, so a second caller - a DEV-VM harness, a
    manual re-record - cannot skip them. There is no -Force.

    MSI packages ARE recorded, and the first version of this script was wrong to skip them. That skip
    confused two different things: an MSI's silent SWITCH is deterministic (/qn, readable from the file
    header), but its PROPERTIES are not. ADDLOCAL feature selections, update-check and shortcut
    properties are researched per application and are the expensive half of an MSI package. VLC needed
    its feature hierarchy read out of the MSI database, Temurin's ADDLOCAL silently drops the PATH entry
    unless the default set is repeated, and LibreOffice took a failed gate run to establish.

    What genuinely must not be stored is a SECRET. A property carrying a licence key or a token is site
    configuration, and replaying one tenant's key as a "verified switch" for the next package would be
    worse than no entry at all. Those are refused by name, with a reason, instead of throwing away the
    whole class.

    IDENTITY COMES FROM THE BINARY

    sha256, productName and productVersion are taken verbatim from Get-PsadtInstallerEngine.ps1, never
    from the manifest's app.* fields. The reader compares productName against the probed file's PE
    metadata, so storing a friendly name ("Visual Studio Code" where the binary says "Microsoft Visual
    Studio Code") leaves the same-product fallback permanently dead.

    Switches come from research.switches.installArgs / .uninstallArgs, which are arguments only. The
    sibling install/uninstall fields are prose written for the dossier - one of them literally reads
    "<resolved from ARP at run time> ..., then WAIT until ... is gone" - and parsing either into a
    command line is how an English sentence ends up being executed.

.PARAMETER PackagePath
    The package folder, the one holding Invoke-AppDeployToolkit.ps1 and psadt-package.json.

.PARAMETER InstallerFile
    File name inside Files\, for a hand-scaffolded package whose manifest has no package.installerFile.

.PARAMETER Verdict
    The sandbox verdict. Anything other than GREEN is refused with a reason.

.PARAMETER Scenarios
    The scenarios the guest actually ran. Must cover all five, or the write is refused.

.PARAMETER InstalledApp
    The Install step's Add/Remove Programs row, as Invoke-PsadtSandboxTest.ps1 surfaces it. Its
    DisplayName becomes the detection hint.

.PARAMETER EvidenceRef
    Path of the run's result.json, recorded in notes so an entry can be traced back to its proof.

.PARAMETER Remove
    SHA256 of an entry to delete. The invalidation path for an entry that turned out wrong.

.PARAMETER SkillRoot
    Forwarded to Get-PsadtConfig.ps1. Test seam; the store path is resolved through that script and
    never from $env:LOCALAPPDATA, or PSADT_DEPLOY_HOME would be ignored (rule:config-home).

.OUTPUTS
    PSCustomObject: Written, Action (added|updated|removed|skipped), Reason, Sha256, StorePath, EntryCount.
    A policy refusal is Written = $false plus a Reason, never an exception - the same way the reader
    reports a miss. It throws only on a genuine fault: a malformed store, or an installer it cannot read.

.EXAMPLE
    Set-PsadtVerifiedSwitch.ps1 -PackagePath C:\PSADT\Packages\GIMP -Verdict GREEN -Scenarios Install,Uninstall,Reinstall,Repair,FinalUninstall

.EXAMPLE
    Set-PsadtVerifiedSwitch.ps1 -Remove 9337cccbc01d4098ee7a3dab215b3afbe6ece99c5287c92441d6f12cf541ebca

.NOTES
    Author: psadt-deploy
    Changelog:
      - 0.1 (2026-09-20, Patrick Taubert): first version. The store had a reader since 0.30.0 and no
        writer; this is the missing half.
#>
[CmdletBinding()]
param(
    [string]$PackagePath,
    [string]$InstallerFile,
    [string]$Verdict,
    [string[]]$Scenarios,
    $InstalledApp,
    [string]$EvidenceRef,
    [string]$Remove,
    [string]$SkillRoot
)

$ErrorActionPreference = 'Stop'

# The five scenarios that together prove a package. Anything less is not a gate, whatever the verdict
# string says.
$RequiredScenarios = @('Install', 'Uninstall', 'Reinstall', 'Repair', 'FinalUninstall')

function New-Result {
    param([bool]$Written, [string]$Action, [string]$Reason, [string]$Sha256, [string]$StorePath, [int]$EntryCount)
    [pscustomobject]@{
        Written    = $Written
        Action     = $Action
        Reason     = $Reason
        Sha256     = $Sha256
        StorePath  = $StorePath
        EntryCount = $EntryCount
    }
}

# rule:config-home - Get-PsadtConfig.ps1 is the only resolver. Building the path from $env:LOCALAPPDATA
# would ignore $env:PSADT_DEPLOY_HOME and write into the real profile during a test run.
$cfgArgs = @{}
if ($SkillRoot) { $cfgArgs['SkillRoot'] = $SkillRoot }
$cfg = & (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1') @cfgArgs
$storePath = Join-Path $cfg.Home 'verified-switches.json'

# ---------------------------------------------------------------------------------------------------
# Load the store. A malformed store is a hard stop, never a silent overwrite - it is a record of things
# that were proven, and quietly replacing it would destroy that record to fix a typo.
# ---------------------------------------------------------------------------------------------------
$store = $null
if (Test-Path -LiteralPath $storePath) {
    try { $store = Get-Content -LiteralPath $storePath -Raw | ConvertFrom-Json }
    catch {
        throw "The verified-switch store at $storePath is not readable JSON and will not be overwritten: $($_.Exception.Message)"
    }
}
if (-not $store) { $store = [pscustomobject]@{ schemaVersion = 1; entries = @() } }

$entries = [System.Collections.Generic.List[object]]::new()
foreach ($e in @($store.entries)) { if ($e) { $entries.Add($e) } }

function Save-Store {
    param([System.Collections.Generic.List[object]]$Entries)
    $out = [pscustomobject]@{ schemaVersion = 1; entries = $Entries.ToArray() }
    $dir = Split-Path -Parent $storePath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    . (Join-Path $PSScriptRoot '_JsonStore.ps1')
    Write-JsonAtomic -Path $storePath -Object $out -Depth 12
}

# ---------------------------------------------------------------------------------------------------
# -Remove: the invalidation path. Idempotent, because "make sure this is gone" should not fail when it
# already is.
# ---------------------------------------------------------------------------------------------------
if ($Remove) {
    $needle = $Remove.ToLowerInvariant()
    $kept = [System.Collections.Generic.List[object]]::new()
    $dropped = 0
    foreach ($e in $entries) {
        if ([string]$e.sha256 -eq $needle) { $dropped++ } else { $kept.Add($e) }
    }
    if ($dropped -gt 0) { Save-Store -Entries $kept }
    return New-Result -Written ($dropped -gt 0) -Action 'removed' `
        -Reason $(if ($dropped -gt 0) { "removed $dropped entr(y/ies)" } else { 'no entry with that hash' }) `
        -Sha256 $needle -StorePath $storePath -EntryCount $kept.Count
}

# ---------------------------------------------------------------------------------------------------
# The gate. Both halves, here rather than at the call site.
# ---------------------------------------------------------------------------------------------------
if ($Verdict -ne 'GREEN') {
    return New-Result -Written $false -Action 'skipped' `
        -Reason "verdict is '$Verdict', not GREEN - only a passing gate proves a switch" `
        -Sha256 '' -StorePath $storePath -EntryCount $entries.Count
}

$ran = @($Scenarios | ForEach-Object { [string]$_ })
$missing = @($RequiredScenarios | Where-Object { $ran -notcontains $_ })
if ($missing.Count -gt 0) {
    return New-Result -Written $false -Action 'skipped' `
        -Reason ("GREEN but not a full gate - missing " + ($missing -join ', ') + "; a package whose uninstall never ran is not proven") `
        -Sha256 '' -StorePath $storePath -EntryCount $entries.Count
}

if (-not $PackagePath) { throw 'PackagePath is required unless -Remove is used.' }
$pkg = (Resolve-Path -LiteralPath $PackagePath).ProviderPath

# ---------------------------------------------------------------------------------------------------
# The manifest decides whether this package has anything worth storing.
# ---------------------------------------------------------------------------------------------------
$mf = & (Join-Path $PSScriptRoot 'Get-PsadtPackageManifest.ps1') -PackagePath $pkg
if (-not $mf.Exists) {
    return New-Result -Written $false -Action 'skipped' -Reason 'no psadt-package.json in the package' `
        -Sha256 '' -StorePath $storePath -EntryCount $entries.Count
}
$m = $mf.Manifest

$pkgType = [string]$m.package.type
if ($pkgType -and $pkgType -ne 'installer') {
    return New-Result -Written $false -Action 'skipped' `
        -Reason "package.type is '$pkgType' - the store keys on one installer binary, which this package type does not have" `
        -Sha256 '' -StorePath $storePath -EntryCount $entries.Count
}

$tech = [string]$m.package.installerTech
$installArgs = [string]$m.research.switches.installArgs
if (-not $installArgs) {
    return New-Result -Written $false -Action 'skipped' `
        -Reason 'no research.switches.installArgs in the manifest - the prose install field is not parsed on purpose' `
        -Sha256 '' -StorePath $storePath -EntryCount $entries.Count
}

# A property carrying a secret is site configuration, not a fact about the installer, and the store is a
# plain file in the profile. Refused by name rather than redacted: a half-recorded argument string is a
# command line that does not work.
$secretish = 'LICEN[SC]E|SERIAL|PIDKEY|PRODUCTKEY|\bKEY\b|TOKEN|PASSWORD|\bPWD\b|SECRET|CREDENTIAL'
if ($installArgs -match $secretish) {
    return New-Result -Written $false -Action 'skipped' `
        -Reason "the install arguments look like they carry a secret (matched '$($Matches[0])') - that is site configuration, not a property of the file" `
        -Sha256 '' -StorePath $storePath -EntryCount $entries.Count
}

# ---------------------------------------------------------------------------------------------------
# Which file was installed. Never guessed: a wrong hash writes an entry that a later package adopts for
# a different binary, and it would carry the word 'verified' while doing it.
# ---------------------------------------------------------------------------------------------------
$filesDir = Join-Path $pkg 'Files'
$name = if ($InstallerFile) { $InstallerFile } else { [string]$m.package.installerFile }

if (-not $name) {
    $inFiles = @(Get-ChildItem -LiteralPath $filesDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'Add Setup Files Here.txt' })
    if ($inFiles.Count -eq 1) { $name = $inFiles[0].Name }
    else {
        return New-Result -Written $false -Action 'skipped' `
            -Reason ("cannot tell which file was installed - manifest names none and Files\ holds " +
                $inFiles.Count + " candidate(s): " + (($inFiles | ForEach-Object { $_.Name }) -join ', ')) `
            -Sha256 '' -StorePath $storePath -EntryCount $entries.Count
    }
}

$installerPath = Join-Path $filesDir $name
if (-not (Test-Path -LiteralPath $installerPath)) {
    throw "The manifest names '$name' but $installerPath does not exist - refusing to record a hash for a file that is not there."
}

$engine = & (Join-Path $PSScriptRoot 'Get-PsadtInstallerEngine.ps1') -Path $installerPath

# ---------------------------------------------------------------------------------------------------
# Build the entry. Field names are the reader's, verbatim.
# ---------------------------------------------------------------------------------------------------
$detectHint = $null
if ($InstalledApp) {
    $dn = [string]$InstalledApp.DisplayName
    if ($dn) {
        $detectHint = @{
            kind = 'registry-uninstall'
            note = "the Install step registered DisplayName '$dn'"
        }
    }
}

$notes = [System.Collections.Generic.List[string]]::new()
$notes.Add("proven by the full sandbox gate on package '$($mf.Stem)'")
if ($EvidenceRef) { $notes.Add("evidence: $EvidenceRef") }

$who = [string]$cfg.Config.author.person
if (-not $who) { $who = $env:USERNAME }

$entry = [ordered]@{
    sha256         = [string]$engine.Sha256
    productName    = $engine.ProductName
    productVersion = $engine.ProductVersion
    # The version the PACKAGE declares, which is not always the version the binary reports: a synthetic
    # or resource-less installer has no ProductVersion at all, and some vendors ship a marketing version
    # in the file and a build number in the package. Both are kept, because the reason to look an entry
    # up months later is usually "did the switches change between versions".
    appVersion     = [string]$m.app.version
    # How to read the install field: for an MSI it is msiexec arguments plus the researched properties,
    # for an EXE it is the installer's own switches.
    installerTech  = $(if ($tech) { $tech } else { $null })
    productCode    = $(if ($m.package.productCode) { [string]$m.package.productCode } else { $null })
    install        = $installArgs
    uninstall      = [string]$m.research.switches.uninstallArgs
    installLog     = $null
    noReboot       = $null
    detectHint     = $detectHint
    returnCodes    = @($m.research.returnCodes)
    notes          = $notes.ToArray()
    scenarios      = $ran
    verifiedAt     = (Get-Date -Format 'yyyy-MM-dd')
    verifiedBy     = "$who on $env:COMPUTERNAME"
}

# Upsert, newest first. Two decisions here, and the second one matters more than it looks.
#
# Upsert rather than append, because the reader takes [0] of a match: a duplicate for one hash would
# make the winner depend on insertion order. A re-run after a fix has to be able to correct the record,
# so it is not a skip either.
#
# NEWEST FIRST, because a new version of the same product gets a new hash and therefore its own entry -
# that is how version history accumulates here, and it is the point of keeping the store. But the
# reader's same-product fallback also takes [0], so appending would hand a future package the OLDEST
# known version's switches. Prepending makes [0] the most recently proven one, which is the only answer
# worth offering at 'medium' confidence.
$action = 'added'
$kept = [System.Collections.Generic.List[object]]::new()
foreach ($e in $entries) {
    if ([string]$e.sha256 -eq $entry.sha256) { $action = 'updated' } else { $kept.Add($e) }
}
$entries = [System.Collections.Generic.List[object]]::new()
$entries.Add([pscustomobject]$entry)
foreach ($e in $kept) { $entries.Add($e) }

Save-Store -Entries $entries

New-Result -Written $true -Action $action -Reason "full gate GREEN on $($ran.Count) scenarios" `
    -Sha256 $entry.sha256 -StorePath $storePath -EntryCount $entries.Count

<#
.SYNOPSIS  Runs the local-evidence ladder before Phase 2 opens a browser, and reports the questions that are STILL OPEN.
.DESCRIPTION
  Phase 2 used to dispatch three Researcher sub-agents unconditionally, on every job. On an app that was
  already installed on the packaging machine that cost 400k tokens to rediscover a QuietUninstallString
  Windows had been storing all along. The fan-out was not too slow - it was not GATED.

  This is the gate. Four rungs, deterministic, offline, in order:
    0  tooling?     the installed PSADT module's manifest, read with Import-PowerShellDataFile (never
                    Import-Module - that has side effects). Retires "did a cmdlet get renamed" as a
                    research topic entirely.
    1  installed?   the Uninstall registry (HKLM 64-bit + 32-bit views, HKCU). DisplayName, DisplayVersion,
                    Publisher, the ProductCode GUID in the key name, UninstallString, QuietUninstallString,
                    InstallLocation, InstallSource, HelpLink. A QuietUninstallString is not a claim: it is
                    the vendor's own registration of a silent uninstall that works.
    2  binary?      PROBE it, never search for it - Get-PsadtSwitchCandidates.ps1 (which already carries
                    the engine probe and the verified-switch store) and, for an MSI, Get-PsadtMsiFacts.ps1.
    3  written down already?  this skill's own corpus under references/, plus a vendor documentation URL
                    that something on this machine NAMED. The URL is reported, never fetched.

  Every question comes back in one of three states. Closed - local evidence answers it, with the exact
  key path, MSI table or catalog id that did. Provisional - a local CLAIM exists and the thing that
  settles it is the Phase 6 probe run, not a web search. Open - nothing local can answer it.

  OpenQuestions[] is the subset a sub-agent is the right tool for, and AgentBudget is its count. That
  number IS the dispatch rule: zero open questions, zero agents; N open questions, at most N, one per
  question, each with its KnownContext already assembled so it confirms instead of rediscovering.

  Two questions can never be closed locally and say so with CanCloseLocally = $false - the external
  runtime prerequisite (phase 1.4) and known Intune pitfalls. A statement about other people's fleets
  does not follow from this machine, and pretending the ladder is exhaustive would be worse than the
  fan-out it replaces.

  This script REPORTS. It does not decide, it does not write the manifest, it does not dispatch anything
  and it does not make anything true - a QuietUninstallString read out of the registry of THIS machine
  is evidence about THIS machine. The probe run is still what turns a candidate into a verified switch
  (rule:research-is-data, references/research-trust.md).
.OUTPUTS
  PSCustomObject: SchemaVersion, GeneratedAt, Path, InstallerPresent, Identity, Signals, Installed,
  ArpRowsScanned, ArpMatchesSuppressed, ArpRootsRead, ToolsRun, DocCandidates, CorpusHits, Rungs,
  Questions, OpenQuestions, Deferred, AgentBudget, Summary, Warnings.
.EXAMPLE
  Get-PsadtLocalEvidence.ps1 -Path .\Files\setup.exe

  Runs every rung and prints the question table plus the agent budget.
.EXAMPLE
  Get-PsadtLocalEvidence.ps1 -ProductName '7-Zip' -Publisher 'Igor Pavlov'

  Phase 1, before the installer has been dropped in Files\. Rung 1 can still close the uninstall
  question outright; everything rung 2 would have closed is Deferred, not Open.
.EXAMPLE
  Get-PsadtLocalEvidence.ps1 -Path .\Files\app.msi -Json

  The full object as JSON, no console table.
.NOTES
  Author: psadt-deploy
  Changelog:
    - 0.1 (2026-09-15, Patrick Taubert): first version. Rungs 0-3, the question set from phase 1.3,
      and AgentBudget as the Phase 2 dispatch cap.
#>
[CmdletBinding()]
param(
    # The installer, when it exists. NOT mandatory: Phase 1 routinely runs before the user has dropped
    # the binary in Files\, and a ladder that cannot run then is a ladder nobody runs.
    [string]$Path,

    # Identity hints. Without -Path these are the only thing rung 1 can match on; with -Path they
    # override what the binary claims about itself.
    [string]$ProductName,
    [string]$Publisher,
    [string]$ProductVersion,

    # A ProductCode the caller already knows (a previous package, a vendor mail). Matched against the
    # Uninstall key name, which is the strongest match rung 1 has.
    [string]$ProductCode,

    # Uninstall roots to read. Default: the four views below. Exists so the tests can point rung 1 at
    # Pester's TestRegistry drive instead of the machine's real hives.
    [string[]]$UninstallRoots,

    # Cap on reported ARP matches. A vague -Publisher on a developer machine matches hundreds of rows;
    # the number suppressed is reported, so a truncated list is never a silent one.
    [ValidateRange(1, 200)][int]$MaxArpMatches = 10,

    # Emit JSON instead of the object, and skip the console table.
    [switch]$Json,

    # Additionally write the JSON to this file.
    [string]$JsonPath,

    # Unused downstream; accepted so callers can pass it through.
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------------
# Collections and small helpers
# ---------------------------------------------------------------------------------------------------
$misses    = New-Object System.Collections.Generic.List[object]
$warnings  = New-Object System.Collections.Generic.List[string]
$toolsRun  = New-Object System.Collections.Generic.List[object]
$rungInfo  = New-Object System.Collections.Generic.List[object]
$installed = New-Object System.Collections.Generic.List[object]
$docCands  = New-Object System.Collections.Generic.List[object]
$corpusHit = New-Object System.Collections.Generic.List[object]
$corpusTotal = 0

function Add-Miss([int]$Rung, [string]$Source, [string]$Reason) {
    $misses.Add([pscustomobject]@{ Rung = $Rung; Source = $Source; Reason = $Reason })
}
function Add-Tool([string]$ScriptName, [bool]$Ok, [string]$ErrorText) {
    $toolsRun.Add([pscustomobject]@{ Script = $ScriptName; Ok = $Ok; Error = $ErrorText })
}
function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}
function Resolve-Field([object[]]$Values) {
    foreach ($v in $Values) { if ($v -and [string]$v -ne '') { return $v } }
    return $null
}

if (-not $Path -and -not $ProductName -and -not $Publisher -and -not $ProductCode) {
    # The only throw in the script, and it earns its place: a run with nothing to go on would return
    # every question Open and authorise an agent for each - precisely the failure this script exists
    # to stop.
    throw 'Nothing to go on: pass -Path, or at least -ProductName / -Publisher / -ProductCode.'
}

$installerPresent = $false
if ($Path) {
    if (Test-Path -LiteralPath $Path) {
        $Path = (Resolve-Path -LiteralPath $Path).ProviderPath
        $installerPresent = $true
    } else {
        # Deliberately NOT a throw, unlike the sibling probes: they probe a file, this probes a
        # situation, and "the binary is not here yet" is the normal Phase 1 state.
        Add-Miss 2 'installer' "installer not present at $Path - rung 2 did not run"
    }
}

if (-not $UninstallRoots) {
    $UninstallRoots = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'Registry::HKEY_CURRENT_USER\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
}

# ---------------------------------------------------------------------------------------------------
# Rung 0 - the toolchain. Reads the module MANIFEST; importing PSADT has side effects.
# ---------------------------------------------------------------------------------------------------
# The command list is the set this skill's generated launchers and its guide actually call, so a
# rename in any of them breaks a package. Extensions-module helpers are deliberately absent: they are
# authored here, not exported by PSAppDeployToolkit.
$skillCommands = @(
    'Open-ADTSession', 'Close-ADTSession', 'Start-ADTMsiProcess', 'Start-ADTProcess', 'Write-ADTLogEntry',
    'Show-ADTInstallationWelcome', 'Show-ADTInstallationProgress', 'Close-ADTInstallationProgress',
    'New-ADTTemplate', 'Initialize-ADTModule', 'Get-ADTApplication', 'Show-ADTInstallationPrompt',
    'Show-ADTInstallationRestartPrompt', 'Update-ADTDesktop', 'Resolve-ADTErrorRecord'
)
$psadtVersion = $null
$psadtMissing = @()
$psadtManifest = $null
try {
    $mod = Get-Module -ListAvailable -Name PSAppDeployToolkit |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($mod) {
        $psadtVersion = [string]$mod.Version
        $psadtManifest = $mod.Path
        $data = Import-PowerShellDataFile -LiteralPath $mod.Path
        $exported = @($data.FunctionsToExport)
        if ($exported.Count -eq 1 -and $exported[0] -eq '*') {
            Add-Miss 0 'psadt-module' 'the manifest exports * - a rename cannot be detected from it'
        } else {
            $psadtMissing = @($skillCommands | Where-Object { $_ -notin $exported })
        }
    } else {
        Add-Miss 0 'psadt-module' 'PSAppDeployToolkit is not installed for this user or machine'
    }
} catch {
    Add-Miss 0 'psadt-module' $_.Exception.Message
}
$rungInfo.Add([pscustomobject]@{
    Rung     = 0
    Name     = 'tooling'
    Ran      = $true
    Context  = $(if ($psadtVersion) { "PSAppDeployToolkit $psadtVersion" } else { 'no module' })
    Findings = @($psadtMissing).Count
})

# ---------------------------------------------------------------------------------------------------
# Rung 1 - is it already installed on THIS machine?
# ---------------------------------------------------------------------------------------------------
$whoami = [Security.Principal.WindowsIdentity]::GetCurrent().Name
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $warnings.Add('running 32-bit on a 64-bit OS: HKLM\SOFTWARE is redirected to WOW6432Node and the 64-bit view is invisible. Re-run under a 64-bit host before trusting a "not installed".')
}

function Get-ArpScope([string]$Root) {
    if ($Root -match 'WOW6432Node') { return 'machine-32' }
    if ($Root -match 'HKEY_LOCAL_MACHINE|HKLM:') { return 'machine-64' }
    return 'user'
}

$rowsScanned = 0
$arpRows = New-Object System.Collections.Generic.List[object]
$rootsRead = New-Object System.Collections.Generic.List[string]

foreach ($root in $UninstallRoots) {
    try {
        if (-not (Test-Path -LiteralPath $root)) {
            Add-Miss 1 'uninstall-registry' "root not present: $root"
            continue
        }
        $rootsRead.Add($root)
        $scope = Get-ArpScope $root
        foreach ($key in (Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
            $rowsScanned++
            $v = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not $v) { continue }
            $display = [string](Get-Prop $v 'DisplayName')
            if (-not $display) { continue }

            $keyName = [string]$key.PSChildName
            $guid = $null
            $parsed = [guid]::Empty
            if ([guid]::TryParse(($keyName -replace '^\{|\}$', ''), [ref]$parsed)) { $guid = $keyName }

            $arpRows.Add([pscustomobject]@{
                Scope                = $scope
                Key                  = $keyName
                KeyPath              = ([string]$key.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')
                ProductCodeGuid      = $guid
                DisplayName          = $display
                DisplayVersion       = [string](Get-Prop $v 'DisplayVersion')
                Publisher            = [string](Get-Prop $v 'Publisher')
                InstallDate          = [string](Get-Prop $v 'InstallDate')
                InstallLocation      = [string](Get-Prop $v 'InstallLocation')
                InstallSource        = [string](Get-Prop $v 'InstallSource')
                UninstallString      = [string](Get-Prop $v 'UninstallString')
                QuietUninstallString = [string](Get-Prop $v 'QuietUninstallString')
                ModifyPath           = [string](Get-Prop $v 'ModifyPath')
                EstimatedSize        = Get-Prop $v 'EstimatedSize'
                SystemComponent      = Get-Prop $v 'SystemComponent'
                WindowsInstaller     = Get-Prop $v 'WindowsInstaller'
                ParentDisplayName    = [string](Get-Prop $v 'ParentDisplayName')
                ParentKeyName        = [string](Get-Prop $v 'ParentKeyName')
                HelpLink             = [string](Get-Prop $v 'HelpLink')
                URLInfoAbout         = [string](Get-Prop $v 'URLInfoAbout')
                URLUpdateInfo        = [string](Get-Prop $v 'URLUpdateInfo')
                MatchKind            = $null
                MatchConfidence      = $null
                MatchDetail          = $null
            })
        }
    } catch {
        Add-Miss 1 'uninstall-registry' ("{0}: {1}" -f $root, $_.Exception.Message)
    }
}

# Matchers, ranked; the first one that fires wins for a row. Nothing matches on Publisher alone - on a
# developer machine that is a vendor's whole catalogue, not this app.
# InstallSource is the FOLDER the installer ran from, not the file. Comparing it to the installer's
# file name never matches, which quietly made this whole matcher dead code.
$srcDir = $(if ($installerPresent) { (Split-Path -Parent $Path).TrimEnd('\') } else { $null })
foreach ($row in $arpRows) {
    if ($ProductCode -and $row.ProductCodeGuid -and $row.ProductCodeGuid -eq $ProductCode) {
        $row.MatchKind = 'product-code'; $row.MatchConfidence = 'verified'
        $row.MatchDetail = 'the Uninstall key IS the ProductCode'
    } elseif ($ProductName -and $ProductVersion -and $row.DisplayName -eq $ProductName -and $row.DisplayVersion -eq $ProductVersion) {
        $row.MatchKind = 'name-version'; $row.MatchConfidence = 'verified'
        $row.MatchDetail = 'DisplayName and DisplayVersion both match exactly'
    } elseif ($srcDir -and $row.InstallSource -and $row.InstallSource.TrimEnd('\') -eq $srcDir) {
        $row.MatchKind = 'install-source'; $row.MatchConfidence = 'high'
        $row.MatchDetail = 'InstallSource is the folder the installer in front of us lives in'
    } elseif ($ProductName -and $row.DisplayName -eq $ProductName) {
        $row.MatchKind = 'name-only'; $row.MatchConfidence = 'medium'
        $row.MatchDetail = 'same product, different build - vendors change switches between versions'
    } elseif ($ProductName -and $Publisher -and $row.DisplayName -like "*$ProductName*" -and $row.Publisher -like "*$Publisher*") {
        $row.MatchKind = 'name-like'; $row.MatchConfidence = 'medium'
        $row.MatchDetail = 'name and publisher both match loosely'
    }
}

$rank = @{ verified = 0; high = 1; medium = 2 }
$hits = @($arpRows | Where-Object { $_.MatchKind } |
    Sort-Object @{ Expression = { $rank[[string]$_.MatchConfidence] } }, DisplayName)
$suppressed = 0
if ($hits.Count -gt $MaxArpMatches) {
    $suppressed = $hits.Count - $MaxArpMatches
    $hits = @($hits[0..($MaxArpMatches - 1)])
}
foreach ($h in $hits) { $installed.Add($h) }
if ($installed.Count -eq 0) {
    Add-Miss 1 'uninstall-registry' "no Uninstall row matched (scanned $rowsScanned rows as $whoami)"
}
$rungInfo.Add([pscustomobject]@{
    Rung     = 1
    Name     = 'installed-here'
    Ran      = $true
    Context  = "as $whoami, $rowsScanned rows over $($rootsRead.Count) root(s)"
    Findings = $installed.Count
})

# The strongest row is the one that gets to close a question.
$best = $(if ($installed.Count -gt 0) { $installed[0] } else { $null })
$verifiedCount = @($installed | Where-Object { $_.MatchConfidence -eq 'verified' }).Count
$ambiguous = $verifiedCount -gt 1

# ---------------------------------------------------------------------------------------------------
# Rung 2 - probe the binary. Composition only: both facts already have an owner.
# ---------------------------------------------------------------------------------------------------
# ONE call. Get-PsadtSwitchCandidates.ps1 runs the engine probe itself and republishes Sha256, Engine,
# EngineConfidence, IsMsi, ProductName/Version/Publisher on its own result. Calling the engine probe
# again here would re-scan the whole file for data already in hand, and vendor bootstrappers are big.
# -Json is how that script returns the object without printing its console table.
$sc = $null
$msi = $null
if ($installerPresent) {
    try {
        $scJson = & (Join-Path $PSScriptRoot 'Get-PsadtSwitchCandidates.ps1') -Path $Path `
            -ProductName $ProductName -Publisher $Publisher -Json
        $sc = $scJson | ConvertFrom-Json
        Add-Tool 'Get-PsadtSwitchCandidates.ps1' $true $null
    } catch {
        Add-Miss 2 'switch-candidates' $_.Exception.Message
        Add-Tool 'Get-PsadtSwitchCandidates.ps1' $false $_.Exception.Message
    }
    if ($sc -and $sc.IsMsi) {
        try {
            $msi = & (Join-Path $PSScriptRoot 'Get-PsadtMsiFacts.ps1') -Path $Path
            Add-Tool 'Get-PsadtMsiFacts.ps1' $true $null
        } catch {
            Add-Miss 2 'msi-facts' $_.Exception.Message
            Add-Tool 'Get-PsadtMsiFacts.ps1' $false $_.Exception.Message
        }
    }
    # Reported, not attempted, and the reason is the point: running the vendor binary to read its help
    # output puts vendor code on the packaging HOST, three phases before the throwaway sandbox that
    # exists for exactly that. Several engines answer /? with a modal dialog, or by installing anyway.
    Add-Miss 2 'help-output' 'not attempted: vendor code runs in the Phase 6 sandbox, never on the packaging host (SECURITY.md)'
}
$rungInfo.Add([pscustomobject]@{
    Rung     = 2
    Name     = 'binary-here'
    Ran      = $installerPresent
    Context  = $(if ($installerPresent) { "engine " + [string](Get-Prop $sc 'Engine') } else { 'no installer supplied' })
    Findings = @(Get-Prop $sc 'Candidates').Count
})

# Resolved identity: the parameter wins, then the MSI database, then what the binary says about itself.
$resolvedName    = Resolve-Field @($ProductName, (Get-Prop $msi 'ProductName'), (Get-Prop $sc 'ProductName'), (Get-Prop $best 'DisplayName'))
$resolvedVersion = Resolve-Field @($ProductVersion, (Get-Prop $msi 'ProductVersion'), (Get-Prop $sc 'ProductVersion'), (Get-Prop $best 'DisplayVersion'))
$resolvedPub     = Resolve-Field @($Publisher, (Get-Prop $msi 'Manufacturer'), (Get-Prop $sc 'Publisher'), (Get-Prop $best 'Publisher'))
$resolvedCode    = Resolve-Field @($ProductCode, (Get-Prop $msi 'ProductCode'), (Get-Prop $best 'ProductCodeGuid'))
$engine          = [string](Get-Prop $sc 'Engine')
$isMsi           = [bool](Get-Prop $sc 'IsMsi')
$topCand         = @(Get-Prop $sc 'Candidates') | Select-Object -First 1

# ---------------------------------------------------------------------------------------------------
# Rung 3 - is it written down already? Corpus first, then a doc URL that something NAMED.
# ---------------------------------------------------------------------------------------------------
$refDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'references'
if ($resolvedName -and (Test-Path -LiteralPath $refDir)) {
    try {
        # Bounded, not a substring match. A short product name ("Git", "R", "Go") otherwise hits every
        # "GitHub" and "Registry" in the corpus, and a corpus hit is not cosmetic: it is handed to the
        # pitfalls agent as established context, so a false one actively misleads it - and so does a
        # false MISS, which is stated outright in KnownContext.
        # \b is wrong for the job: it asserts a word/non-word TRANSITION, so a name ending in a non-word
        # character can never satisfy it. "Notepad++" found 0 of its 5 real mentions, ".NET" 5 of 11.
        # The lookarounds say what was actually meant - not glued to more name.
        $needle = '(?<!\w)' + [regex]::Escape($resolvedName) + '(?!\w)'
        $found = @(Select-String -Path (Join-Path $refDir '*.md') -Pattern $needle -ErrorAction SilentlyContinue)
        $corpusTotal = $found.Count
        foreach ($f in ($found | Select-Object -First 20)) {
            $corpusHit.Add([pscustomobject]@{ File = $f.Filename; Line = $f.LineNumber; Text = $f.Line.Trim() })
        }
        if ($corpusHit.Count -eq 0) {
            Add-Miss 3 'local-corpus' "this skill's pitfall corpus (App. A/B/G/L) does not mention '$resolvedName'"
        }
    } catch {
        Add-Miss 3 'local-corpus' $_.Exception.Message
    }
} else {
    Add-Miss 3 'local-corpus' 'no product name resolved, nothing to search the corpus for'
}

# Candidates are DERIVED, never constructed. There is deliberately no https://<publisher>.com/docs
# guess here: a URL nobody named is a guess wearing a field name.
function Add-Doc([string]$Url, [string]$Kind, [string]$Source, [string]$SourceRef, [string]$Why) {
    if (-not $Url) { return }
    if ($Url -notmatch '^https?://') { return }
    if (@($docCands | Where-Object { $_.Url -eq $Url }).Count -gt 0) { return }
    $docCands.Add([pscustomobject]@{ Url = $Url; Kind = $Kind; Source = $Source; SourceRef = $SourceRef; Why = $Why })
}
if ($best) {
    Add-Doc (Get-Prop $best 'HelpLink')      'vendor-kb'   'arp-registry' $best.KeyPath 'the installed product registered it as its help link'
    Add-Doc (Get-Prop $best 'URLInfoAbout')  'vendor-doc'  'arp-registry' $best.KeyPath 'the installed product registered it as its product page'
    Add-Doc (Get-Prop $best 'URLUpdateInfo') 'update-feed' 'arp-registry' $best.KeyPath 'the installed product registered it as its update feed'
}
if ($msi) {
    $props = Get-Prop $msi 'Properties'
    if ($props) {
        Add-Doc ([string]$props['ARPHELPLINK'])     'vendor-kb'  'msi-database' 'Property table ARPHELPLINK'     'the MSI names it as its help link'
        Add-Doc ([string]$props['ARPURLINFOABOUT']) 'vendor-doc' 'msi-database' 'Property table ARPURLINFOABOUT' 'the MSI names it as its product page'
    }
}
if ($docCands.Count -eq 0) {
    Add-Miss 3 'vendor-doc' 'nothing on this machine named a vendor URL - and none is constructed, because a guessed URL is not evidence'
}
$rungInfo.Add([pscustomobject]@{
    Rung     = 3
    Name     = 'written-down'
    Ran      = $true
    Context  = "corpus hits $corpusTotal, named URLs $($docCands.Count)"
    Findings = $corpusHit.Count + $docCands.Count
})

# ---------------------------------------------------------------------------------------------------
# The question set (phase 1.3), each in exactly one state
# ---------------------------------------------------------------------------------------------------
$questions = New-Object System.Collections.Generic.List[object]

function New-Question {
    param(
        [string]$Id, [string]$Topic, [string]$Question, [string]$Severity,
        # Questions in the same family are answered by the same vendor page. At most ONE agent is ever
        # dispatched per family, which is what caps the fan-out structurally rather than by hoping the
        # arithmetic works out - see the folding pass below.
        [string]$Family,
        [bool]$CanCloseLocally = $true
    )
    $q = [pscustomobject]@{
        Id = $Id; Topic = $Topic; Question = $Question; Status = 'Open'; Answer = $null
        Confidence = 'none'; Evidence = @(); ClosedBy = $null; CanCloseLocally = $CanCloseLocally
        Severity = $Severity; Family = $Family; Resolution = 'dispatch-agent'; WhyOpen = $null
        SuggestedQuery = @(); Sources = @(); KnownContext = @(); AcceptanceCriteria = $null
        FoldInto = $null; AgentPromptHint = $null
    }
    $questions.Add($q)
    return $q
}
function Set-Answer {
    param($Q, [string]$Value, [string]$Confidence, [int]$Rung, [string]$Source, [string]$SourceRef, [string]$Detail)
    $Q.Answer = $Value
    $Q.Confidence = $Confidence
    $Q.ClosedBy = $Rung
    $Q.Evidence = @($Q.Evidence) + @([pscustomobject]@{
        Rung = $Rung; Source = $Source; SourceRef = $SourceRef; Value = $Value
        Confidence = $Confidence; Detail = $Detail
    })
}
function Set-Open {
    param($Q, [string]$Why, [string]$Resolution)
    $Q.WhyOpen = $Why
    $Q.Resolution = $Resolution
}

# Families, not topics, are what bound the fan-out: everything in 'vendor-doc' is answered by the same
# enterprise-deployment page, so it costs one agent no matter how many of its questions are open.
$qInstall   = New-Question 'silent-install'       'install'      'Silent install CMD' 'blocking' 'vendor-doc'
$qUninstall = New-Question 'silent-uninstall'     'uninstall'    'Silent uninstall CMD' 'blocking' 'vendor-doc'
$qRepair    = New-Question 'repair-strategy'      'repair'       'Repair strategy (native verb, or uninstall + install)' 'important' 'vendor-doc'
$qCodes     = New-Question 'exit-codes'           'exit-codes'   'Known exit codes (success, reboot, error)' 'important' 'vendor-doc'
$qLog       = New-Question 'installer-log'        'logging'      'Installer log file path' 'optional' 'vendor-doc'
$qDep       = New-Question 'dependency-installer' 'dependencies' 'Dependency installer (if separate)' 'important' 'vendor-doc'
$qConfig    = New-Question 'post-install-config'  'config'       'Known post-install config (registry / XML)' 'important' 'vendor-doc'
$qRuntime   = New-Question 'runtime-prerequisite' 'runtime'      'External runtime prerequisite (1.4)' 'blocking' 'runtime' $false
$qPitfalls  = New-Question 'intune-pitfalls'      'intune'       'Known Intune pitfalls' 'important' 'intune' $false
$qDrift     = New-Question 'psadt-command-drift'  'tooling'      'PSADT command drift (renamed or removed cmdlets)' 'blocking' 'tooling'

# --- silent install --------------------------------------------------------------------------------
if ($topCand -and [string](Get-Prop $topCand 'Confidence') -eq 'verified') {
    Set-Answer $qInstall ([string](Get-Prop $topCand 'Install')) 'verified' 2 'verified-switch-store' `
        ([string](Get-Prop $topCand 'SourceRef')) 'a run on THIS machine already proved this switch for this file hash'
} elseif ($isMsi) {
    Set-Answer $qInstall 'msiexec /i "{file}" /qn /norestart /l*v "{log}"' 'high' 2 'engine-catalog' `
        'engine-defaults.json engine msi' 'the compound-file header proves it is an MSI, and the msiexec command line is Microsoft''s'
} elseif ($topCand) {
    Set-Answer $qInstall ([string](Get-Prop $topCand 'Install')) ([string](Get-Prop $topCand 'Confidence')) 2 'engine-catalog' `
        ([string](Get-Prop $topCand 'SourceRef')) "the documented default for engine '$engine' - a claim until the probe run"
    Set-Open $qInstall "engine '$engine' has a documented default, but nothing has run it here" 'probe-run'
} elseif (-not $installerPresent) {
    Set-Open $qInstall 'no installer supplied yet - dropping the binary in Files\ answers this for free' 'recheck-after-binary'
} else {
    Set-Open $qInstall "the engine probe could not resolve this binary (engine '$engine'), so there is no documented default to start from" 'dispatch-agent'
}

# --- silent uninstall ------------------------------------------------------------------------------
# This is the one the 400k-token run went looking for on the web.
$quiet = $(if ($best) { [string](Get-Prop $best 'QuietUninstallString') } else { '' })
$strongRow = ($best -and $best.MatchConfidence -in @('verified', 'high'))
$parented = ($best -and (Get-Prop $best 'ParentKeyName'))
# A ProductCode is only a ProductCode if it came from somewhere that knows. The MSI database and the
# caller do. A braced ARP key name does NOT, unless that row is both a strong match AND registered by
# Windows Installer - plenty of non-MSI installers use a GUID-shaped key, and a weak row's key belongs
# to a DIFFERENT BUILD whose ProductCode is different by definition. Getting this wrong ships a
# confident `msiexec /x` line for a product msiexec has never heard of.
$trustedCode = Resolve-Field @($ProductCode, (Get-Prop $msi 'ProductCode'))
if (-not $trustedCode -and $strongRow -and (Get-Prop $best 'ProductCodeGuid') -and (Get-Prop $best 'WindowsInstaller')) {
    $trustedCode = [string](Get-Prop $best 'ProductCodeGuid')
}

if ($quiet -and $strongRow -and -not $parented) {
    Set-Answer $qUninstall $quiet 'verified' 1 'arp-registry' $best.KeyPath `
        'the vendor registered this as the silent uninstall - it is not a claim, it is a registration'
} elseif ($trustedCode) {
    Set-Answer $qUninstall ("msiexec /x {0} /qn /norestart" -f $trustedCode) 'high' `
        $(if ($msi) { 2 } else { 1 }) 'engine-catalog' 'engine-defaults.json engine msi' `
        'a ProductCode is all msiexec needs; pass it to -ProductCode, never to -FilePath'
} elseif ($quiet) {
    # Right shape, wrong build. Worth far more than a fabricated command line, but only a run settles it.
    Set-Answer $qUninstall $quiet 'medium' 1 'arp-registry' $best.KeyPath `
        'registered by a row that is not an exact match for this build - vendors change switches between versions'
    Set-Open $qUninstall 'the QuietUninstallString comes from a near-match row, not this exact build' 'probe-run'
} elseif ($best -and (Get-Prop $best 'UninstallString')) {
    Set-Answer $qUninstall ([string](Get-Prop $best 'UninstallString')) 'medium' 1 'arp-registry' $best.KeyPath `
        'an UninstallString with no Quiet twin - the engine''s silent argument still has to be appended, and run'
    Set-Open $qUninstall 'the registered UninstallString is not the silent one; the probe run settles what to append' 'probe-run'
} elseif (-not $installerPresent -and $installed.Count -eq 0) {
    Set-Open $qUninstall 'nothing installed here and no binary supplied' 'recheck-after-binary'
} else {
    Set-Open $qUninstall 'no ARP row, no trustworthy ProductCode, and the engine default did not cover uninstall' 'dispatch-agent'
}
if ($ambiguous) {
    # Two rows claim to be this exact product. Downgrading the confidence is not enough on its own: the
    # answer was reached through a branch that never called Set-Open, so without this the question would
    # be Provisional AND still carrying the initial 'dispatch-agent' - a combination that belongs to
    # neither output list. The probe run is what disambiguates, so say so.
    $qUninstall.Confidence = 'medium'
    Set-Open $qUninstall "$verifiedCount rows match this build exactly and nothing is picked for you; the probe run decides" 'probe-run'
    $qUninstall.Evidence = @($qUninstall.Evidence) + @([pscustomobject]@{
        Rung = 1; Source = 'arp-registry'; SourceRef = 'multiple roots'; Value = $null; Confidence = 'medium'
        Detail = "ambiguous: $verifiedCount rows match exactly, and nothing is picked for you"
    })
}

# --- repair ------------------------------------------------------------------------------------------
# Its own question because rule:all-three-deployment-types makes Repair a deliverable, and App. L.7
# records an engine whose "just re-run the installer" repair never returned.
if ($isMsi -or $trustedCode) {
    Set-Answer $qRepair 'msiexec /f{omus} <ProductCode> /qn /norestart' 'high' 2 'engine-catalog' `
        'engine-defaults.json engine msi' 'Windows Installer has a real repair verb; nothing else has to be inferred'
} elseif ($best -and (Get-Prop $best 'ModifyPath')) {
    Set-Answer $qRepair ([string](Get-Prop $best 'ModifyPath')) 'medium' 1 'arp-registry' $best.KeyPath `
        'the product registered a ModifyPath, which is a maintenance entry point - whether it repairs SILENTLY is a claim'
    Set-Open $qRepair 'a registered ModifyPath is not proof of a silent repair' 'probe-run'
} elseif (-not $installerPresent) {
    Set-Open $qRepair 'no binary to inspect yet' 'recheck-after-binary'
} else {
    Set-Open $qRepair 'no repair verb is documented for this engine, and re-running the installer over an existing install is not a safe substitute (App. L.7)' 'dispatch-agent'
}

# --- exit codes ------------------------------------------------------------------------------------
if ($isMsi) {
    Set-Answer $qCodes '0, 1641, 3010, 1618, 1603 (msiexec)' 'high' 2 'return-code-table' `
        'scripts/Get-PsadtReturnCodes.ps1' 'msiexec''s exit codes ARE the space for an MSI'
} else {
    Set-Answer $qCodes '0, 1641, 3010 and the mandatory seven' 'medium' 2 'return-code-table' `
        'scripts/Get-PsadtReturnCodes.ps1' 'the mandatory base table always renders; vendor extras are a bonus'
    Set-Open $qCodes 'vendor-specific exit codes are unknown, but the base table already covers the required ones' 'accept-unanswered'
    $qCodes.FoldInto = 'silent-install'
}

# --- installer log ---------------------------------------------------------------------------------
if ($topCand -and (Get-Prop $topCand 'InstallLog')) {
    Set-Answer $qLog ([string](Get-Prop $topCand 'InstallLog')) 'high' 2 'engine-catalog' `
        ([string](Get-Prop $topCand 'SourceRef')) 'an engine property, and we choose the value we pass'
} else {
    Set-Open $qLog 'no engine resolved, so no documented log argument' 'accept-unanswered'
    $qLog.FoldInto = 'silent-install'
}

# --- dependency installer ---------------------------------------------------------------------------
if ($engine -eq 'wix-burn') {
    Set-Answer $qDep 'chained inside the bundle' 'high' 2 'engine-catalog' 'engine-defaults.json engine wix-burn' `
        'a Burn bundle carries its chain; there is no separate dependency installer to find'
} elseif (-not $installerPresent) {
    Set-Open $qDep 'no binary to inspect yet' 'recheck-after-binary'
} else {
    Set-Open $qDep 'a missing dependency makes the install fail in a clean Phase 6 sandbox, which is a better test than any forum post' 'probe-run'
}

# --- runtime prerequisite / intune pitfalls: never closable here --------------------------------------
Set-Open $qRuntime 'no local source can answer whether the vendor expects a separate runtime, and phase 1.4 says no later phase asks it either' 'dispatch-agent'
Set-Open $qPitfalls 'a statement about other people''s fleets does not follow from this machine' 'dispatch-agent'
if ($corpusHit.Count -gt 0) {
    $qPitfalls.Evidence = @([pscustomobject]@{
        Rung = 3; Source = 'local-corpus'; SourceRef = ($corpusHit[0].File + ':' + $corpusHit[0].Line)
        Value = $null; Confidence = 'low'
        Detail = "this skill's corpus already mentions this app in $corpusTotal place(s) - read them before searching"
    })
}

# --- post-install config -----------------------------------------------------------------------------
if ($msi) {
    $regRows = @(Get-Prop $msi 'Registry').Count
    $scRows = @(Get-Prop $msi 'Shortcuts').Count
    Set-Answer $qConfig "MSI Property / Registry ($regRows rows) / Shortcut ($scRows rows) tables" 'high' 2 'msi-database' `
        'Property, Registry, Shortcut tables' 'for an MSI those tables ARE the supported configuration surface'
} elseif (-not $installerPresent) {
    Set-Open $qConfig 'no binary to inspect yet' 'recheck-after-binary'
} else {
    Set-Open $qConfig 'a non-MSI installer does not publish its configuration surface' 'dispatch-agent'
    $qConfig.FoldInto = 'silent-install'
}

# --- PSADT command drift ------------------------------------------------------------------------------
if ($psadtVersion -and @($psadtMissing).Count -eq 0) {
    Set-Answer $qDrift "no drift against PSAppDeployToolkit $psadtVersion" 'verified' 0 'psadt-module' $psadtManifest `
        'every command this skill uses is in the installed module''s FunctionsToExport'
} elseif ($psadtVersion) {
    Set-Answer $qDrift ("missing from the installed module: " + (@($psadtMissing) -join ', ')) 'verified' 0 'psadt-module' $psadtManifest `
        'the manifest is authoritative about what the module exports - fix the package or the module before building'
} else {
    # Never an agent either way: a rename is a fact about a file on disk, not about the internet.
    Set-Open $qDrift 'PSAppDeployToolkit is not installed, so there is nothing to compare against' 'accept-unanswered'
    $qDrift.Confidence = 'low'
}

# ---------------------------------------------------------------------------------------------------
# Derive Status from Confidence - it is never assigned directly
# ---------------------------------------------------------------------------------------------------
foreach ($q in $questions) {
    $q.Status = switch ($q.Confidence) {
        'verified' { 'Closed' }
        'high'     { 'Closed' }
        'medium'   { 'Provisional' }
        'low'      { 'Provisional' }
        default    { 'Open' }
    }
    if ($q.Status -eq 'Closed') { $q.Resolution = 'none' }
}

# ---------------------------------------------------------------------------------------------------
# Normalise, then fold - in that order, because both feed the count
# ---------------------------------------------------------------------------------------------------
# A question that ended up Provisional still carries the 'dispatch-agent' it was born with unless some
# branch changed it. That combination belongs to neither output list, so the question would vanish from
# a contract whose whole promise is that nothing is dropped silently. Provisional means a local claim
# exists; the thing that settles a local claim is the probe run, never a search.
foreach ($q in $questions) {
    if ($q.Status -eq 'Provisional' -and $q.Resolution -eq 'dispatch-agent') {
        Set-Open $q $(if ($q.WhyOpen) { $q.WhyOpen } else { 'a local claim exists; only a run settles it' }) 'probe-run'
    }
}

# One agent answers everything one vendor page answers. Without this the ladder is WORSE than the
# fan-out it replaces: an app whose engine IS identified still opens uninstall, repair and
# post-install config separately, so "one agent per open question" dispatched FOUR where the old fixed
# fan-out sent three. They are not four searches. They are four answers on one deployment page.
#
# Folding by FAMILY rather than by a FoldInto chain is what makes the cap structural: there are three
# families that can ever dispatch (vendor-doc, runtime, intune), so AgentBudget cannot exceed three no
# matter how the question set grows. A chain could also leave a rider attached to a carrier that was
# itself folded, and then reach no prompt at all.
$riders = @{}
foreach ($family in @($questions | Where-Object { $_.Status -eq 'Open' -and $_.Resolution -eq 'dispatch-agent' } |
                      ForEach-Object { $_.Family } | Sort-Object -Unique)) {
    $members = @($questions | Where-Object { $_.Family -eq $family -and $_.Status -eq 'Open' -and $_.Resolution -eq 'dispatch-agent' })
    if ($members.Count -le 1) { continue }
    # The carrier is the most severe member, ties broken by the order the questions were declared, so
    # the choice is stable across runs and does not depend on hashtable ordering.
    $sev = @{ blocking = 0; important = 1; optional = 2 }
    $carrier = @($members | Sort-Object @{ Expression = { $sev[[string]$_.Severity] } },
                                        @{ Expression = { $questions.IndexOf($_) } })[0]
    $riders[$carrier.Id] = New-Object System.Collections.Generic.List[string]
    foreach ($q in @($members | Where-Object { $_.Id -ne $carrier.Id })) {
        $q.FoldInto = $carrier.Id
        Set-Open $q ("{0} (folded into '{1}': one vendor page answers both)" -f $q.WhyOpen, $carrier.Id) 'folded'
        $riders[$carrier.Id].Add($q.Question)
    }
}

# ---------------------------------------------------------------------------------------------------
# KnownContext, queries and the paste-ready prompt - only for what is actually being dispatched
# ---------------------------------------------------------------------------------------------------
$baseContext = New-Object System.Collections.Generic.List[string]
if ($resolvedName) { $baseContext.Add("Product: $resolvedName $resolvedVersion ($resolvedPub)") }
if ($engine)       { $baseContext.Add("Installer engine: $engine (confidence $([string](Get-Prop $sc 'EngineConfidence')))") }
if ($resolvedCode) { $baseContext.Add("ProductCode: $resolvedCode") }
if ($best)         { $baseContext.Add("Installed on the packaging machine: $($best.DisplayName) $($best.DisplayVersion), key $($best.KeyPath)") }
if ($topCand)      { $baseContext.Add("Provisional install switch: $([string](Get-Prop $topCand 'Install')) (confidence $([string](Get-Prop $topCand 'Confidence')), $([string](Get-Prop $topCand 'SourceRef')))") }
if ($corpusHit.Count -eq 0 -and $resolvedName) {
    $baseContext.Add("This skill's own pitfall corpus (App. A/B/G/L) does NOT mention $resolvedName - do not re-derive its generic entries.")
}
foreach ($d in $docCands) { $baseContext.Add("Vendor URL named on this machine ($($d.Source)): $($d.Url)") }

$communitySources = @(
    [pscustomobject]@{ Kind = 'community'; Url = 'https://silentinstallhq.com'; Why = 'silent switches for many apps' }
    [pscustomobject]@{ Kind = 'community'; Url = 'https://discourse.psappdeploytoolkit.com/search'; Why = 'the PSADT forum' }
)
$acceptance = @{
    'silent-install'       = 'a command line from the vendor''s own documentation, with the URL it came from'
    'silent-uninstall'     = 'a command line or ProductCode from the vendor''s documentation, with the URL'
    'runtime-prerequisite' = 'the vendor system-requirements or enterprise-deployment page stating whether a separate runtime must already be present, with the URL - not a forum post (phase 1.4)'
    'intune-pitfalls'      = 'a concrete, reproduced failure with its source, not a general warning'
    'post-install-config'  = 'the registry keys or config files the vendor documents for enterprise defaults, with the URL'
}
foreach ($q in $questions) {
    if ($q.Resolution -ne 'dispatch-agent') { continue }
    $q.KnownContext = $baseContext.ToArray()
    $q.AcceptanceCriteria = $(if ($acceptance.ContainsKey($q.Id)) { $acceptance[$q.Id] } else { 'a vendor-sourced answer with the URL it came from' })
    $n = $(if ($resolvedName) { $resolvedName } else { 'the app' })
    $v = $(if ($resolvedVersion) { $resolvedVersion } else { '' })
    $q.SuggestedQuery = switch ($q.Id) {
        'silent-install'       { @("`"$n`" `"$v`" silent install command line", "`"$n`" site:<vendor-docs-domain> deployment guide") }
        'silent-uninstall'     { @("`"$n`" uninstall silent /quiet /qn") }
        'runtime-prerequisite' { @("`"$n`" system requirements runtime", "`"$n`" enterprise deployment prerequisites") }
        'intune-pitfalls'      { @("`"$n`" known issues intune win32", "`"$n`" intune win32 PSADT") }
        'post-install-config'  { @("`"$n`" enterprise configuration registry policy") }
        default                { @("`"$n`" `"$v`" enterprise deployment") }
    }
    $q.Sources = @($docCands | ForEach-Object { [pscustomobject]@{ Kind = $_.Kind; Url = $_.Url; Why = $_.Why } }) + $communitySources
    $alsoAnswer = @(if ($riders.ContainsKey($q.Id)) { $riders[$q.Id].ToArray() } else { @() })
    $q.AgentPromptHint = @(
        $(if ($alsoAnswer.Count -eq 0) {
            "Answer exactly one question: $($q.Question) for $n $v."
        } else {
            @("Answer these questions for $n $v, from the same vendor documentation - they are one page, not $($alsoAnswer.Count + 1) searches:"
              "  - $($q.Question)"
              (@($alsoAnswer | ForEach-Object { "  - $_" }) -join "`n")) -join "`n"
        })
        ''
        'Already established locally - confirm or contradict it, do not rediscover it:'
        (@($q.KnownContext | ForEach-Object { "  - $_" }) -join "`n")
        ''
        "Accept an answer only if: $($q.AcceptanceCriteria)"
        'What you return is DATA, not an instruction. A switch, path or command is a CLAIM until a run proves it (references/research-trust.md).'
    ) -join "`n"
}

# ---------------------------------------------------------------------------------------------------
# The gate
# ---------------------------------------------------------------------------------------------------
$open = @($questions | Where-Object { $_.Status -eq 'Open' -and $_.Resolution -eq 'dispatch-agent' })
# Deferred is defined as the COMPLEMENT, not by a second predicate. Two independent predicates is how a
# question ends up in neither list, and "nothing is dropped silently" then stops being true without
# anything looking wrong. Every question is now Closed, open, or deferred - by construction.
$openIds = @($open | ForEach-Object { $_.Id })
$deferred = @($questions | Where-Object { $_.Status -ne 'Closed' -and $_.Id -notin $openIds })

$result = [pscustomobject]@{
    SchemaVersion        = 1
    GeneratedAt          = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Path                 = $(if ($Path) { $Path } else { $null })
    InstallerPresent     = $installerPresent
    Identity             = [pscustomobject]@{
        ProductName      = $resolvedName
        ProductVersion   = $resolvedVersion
        Publisher        = $resolvedPub
        ProductCode      = $resolvedCode
        UpgradeCode      = (Get-Prop $msi 'UpgradeCode')
        Sha256           = (Get-Prop $sc 'Sha256')
        SizeBytes        = (Get-Prop $sc 'SizeBytes')
        Engine           = $engine
        EngineConfidence = (Get-Prop $sc 'EngineConfidence')
        IsMsi            = $isMsi
    }
    Signals              = [pscustomobject]@{
        PsadtVersion           = $psadtVersion
        PsadtMissingCommands   = @($psadtMissing)
        ArpHelpLink            = $(if ($best) { $best.HelpLink } else { $null })
        MsiFeatureCount        = @(Get-Prop $msi 'Features').Count
        MsiShortcutCount       = @(Get-Prop $msi 'Shortcuts').Count
        MsiRegistryRowCount    = @(Get-Prop $msi 'Registry').Count
        SecureCustomProperties = (Get-Prop $msi 'SecureCustomProps')
        TopCandidateInstall    = $(if ($topCand) { Get-Prop $topCand 'Install' } else { $null })
        TopCandidateUninstall  = $(if ($topCand) { Get-Prop $topCand 'Uninstall' } else { $null })
        TopCandidateConfidence = $(if ($topCand) { Get-Prop $topCand 'Confidence' } else { $null })
        SwitchCandidateMisses  = @(Get-Prop $sc 'Misses')
    }
    Installed            = $installed.ToArray()
    ArpRowsScanned       = $rowsScanned
    ArpMatchesSuppressed = $suppressed
    ArpRootsRead         = $rootsRead.ToArray()
    ToolsRun             = $toolsRun.ToArray()
    DocCandidates        = $docCands.ToArray()
    CorpusHits           = $corpusHit.ToArray()
    CorpusHitsTotal      = $corpusTotal
    Rungs                = @($rungInfo.ToArray() | ForEach-Object {
        $r = $_
        [pscustomobject]@{
            Rung   = $r.Rung
            Name   = $r.Name
            Ran    = $r.Ran
            Context = $r.Context
            Findings = $r.Findings
            Misses = @($misses | Where-Object { $_.Rung -eq $r.Rung } | Select-Object Source, Reason)
        }
    })
    Questions            = $questions.ToArray()
    OpenQuestions        = $open
    Deferred             = $deferred
    AgentBudget          = $open.Count
    Summary              = [pscustomobject]@{
        Closed      = @($questions | Where-Object { $_.Status -eq 'Closed' }).Count
        Provisional = @($questions | Where-Object { $_.Status -eq 'Provisional' }).Count
        Open        = @($questions | Where-Object { $_.Status -eq 'Open' }).Count
        Deferred    = $deferred.Count
        AgentBudget = $open.Count
    }
    Warnings             = $warnings.ToArray()
}

if ($JsonPath) { $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $JsonPath -Encoding UTF8 }
if ($Json) { return ($result | ConvertTo-Json -Depth 10) }

# --- Human view -------------------------------------------------------------------------------------
Write-Host ""
Write-Host ("Product : {0} {1}" -f $result.Identity.ProductName, $result.Identity.ProductVersion) -ForegroundColor Cyan
Write-Host ("Engine  : {0}   Installed here: {1} row(s)   Corpus: {2} hit(s)" -f `
    $(if ($engine) { $engine } else { '-' }), $installed.Count, $corpusTotal) -ForegroundColor DarkGray
# A -Path that does not resolve produces the same table as no -Path at all: every rung-2 question
# deferred to 'recheck-after-binary'. That reads as "the binary is not here yet" when what actually
# happened is a wrong path, and the run looks healthy while answering nothing. Say it out loud.
if ($Path -and -not $installerPresent) {
    Write-Host ("Rung 2 DID NOT RUN - no file at: {0}" -f $Path) -ForegroundColor Red
    Write-Host "  Everything below is deferred because the binary was not read, not because it cannot be read." -ForegroundColor Red
}
Write-Host ""
$result.Questions |
    Select-Object Question, Status, Confidence,
                  @{ n = 'Next'; e = { $_.Resolution } },
                  @{ n = 'Answer'; e = { if ($_.Answer -and $_.Answer.Length -gt 46) { $_.Answer.Substring(0, 43) + '...' } else { $_.Answer } } } |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host

foreach ($w in $result.Warnings) { Write-Host ("WARN: {0}" -f $w) -ForegroundColor Yellow }

$colour = $(if ($result.AgentBudget -eq 0) { 'Green' } else { 'Yellow' })
Write-Host ("AGENT BUDGET: {0}" -f $result.AgentBudget) -ForegroundColor $colour
if ($result.AgentBudget -eq 0) {
    Write-Host "  Nothing is open. Dispatch no research sub-agent." -ForegroundColor Green
} else {
    Write-Host "  At most one sub-agent per line below, each given its KnownContext. Never more." -ForegroundColor DarkGray
    foreach ($q in $result.OpenQuestions) {
        Write-Host ("  - [{0}] {1}" -f $q.Severity, $q.Question) -ForegroundColor Yellow
        Write-Host ("      why open: {0}" -f $q.WhyOpen) -ForegroundColor DarkGray
    }
}
if ($result.Deferred.Count -gt 0) {
    Write-Host ""
    Write-Host "Deferred - still open, but not worth an agent of its own:" -ForegroundColor DarkGray
    foreach ($q in $result.Deferred) {
        Write-Host ("  - {0} -> {1}" -f $q.Question, $q.Resolution) -ForegroundColor DarkGray
    }
}
Write-Host ""
return $result

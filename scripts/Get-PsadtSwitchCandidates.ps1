<#
.SYNOPSIS  Returns prioritised silent-switch candidates for an installer, from local sources first, so Phase 2 stops guessing before it starts searching.
.DESCRIPTION
  Phase 2 used to reach for the web as soon as an installer was not an MSI. That is slow, it is
  non-deterministic, and it is how a wrong switch gets adopted: a forum post is a CLAIM, and a claim that
  arrives first tends to win. This script puts the deterministic sources in front of the search.

  Stages, in order. The DEFAULT PATH IS ENTIRELY OFFLINE:
    0  verified-switch store  - what a run on THIS machine already proved, keyed by file hash
    1  engine default         - read the engine out of the binary, look its documented switches up
    2  winget-pkgs            - OPT-IN (-WithWinget). WinGet is never auto-selected in this skill
                                (SKILL.md gate 1, App. I), and that holds for research too
    3  Researcher             - the existing web fan-out, when the stages above found nothing

  Every stage reports, hit or miss, and a miss carries a reason. The dossier can then show what was
  checked rather than only what was found, which is the difference between "no catalog entry" and
  "nobody looked".

  This script REPORTS. It does not choose, it does not write the manifest, and it does not make anything
  true: an engine default is the documented default FOR THAT ENGINE, not a fact about the file in front
  of you. The probe run is still what turns a candidate into a verified switch.
.OUTPUTS
  PSCustomObject: Path, Sha256, SizeBytes, Engine, EngineConfidence, EngineEvidence, IsMsi, ProductName,
  ProductVersion, Publisher, Candidates (Stage, Source, SourceRef, Confidence, HashMatch, Install,
  Uninstall, InstallLog, NoReboot, DetectHint, ReturnCodes, Notes, Evidence)[], Misses (Stage, Source,
  Reason)[]
.EXAMPLE
  Get-PsadtSwitchCandidates.ps1 -Path .\Files\setup.exe

  Prints the candidate table and returns the object.
.EXAMPLE
  Get-PsadtSwitchCandidates.ps1 -Path .\Files\setup.exe -Stage 1 -Json

  Engine default only, as JSON.
.NOTES
  Author: psadt-deploy
  Changelog:
    - 0.1 (2026-09-14, Patrick Taubert): first version. Stages 0 and 1; stage 2 reports as opt-in.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,

    # Hints for the stages that match on identity rather than on bytes. Unused by stage 1.
    [string]$ProductName,
    [string]$Publisher,

    # Restrict the run to these stages. Default: every stage this release implements.
    [ValidateRange(0, 3)][int[]]$Stage,

    # Opt in to the winget-pkgs lookup. WinGet is never the default in this skill, and a research
    # lookup that reached for it automatically would make it the default by the back door.
    [switch]$WithWinget,

    # Emit JSON instead of the object, and skip the console table.
    [switch]$Json,

    # Additionally write the JSON to this file.
    [string]$JsonPath,

    # Unused downstream; accepted so callers can pass it through.
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) { throw "Installer not found: $Path" }
$Path = (Resolve-Path -LiteralPath $Path).ProviderPath

$stagesRequested = if ($PSBoundParameters.ContainsKey('Stage')) { @($Stage) } else { @(0, 1, 2) }

$candidates = New-Object System.Collections.Generic.List[object]
$misses = New-Object System.Collections.Generic.List[object]
function Add-Miss([int]$StageNo, [string]$Source, [string]$Reason) {
    $misses.Add([pscustomobject]@{ Stage = $StageNo; Source = $Source; Reason = $Reason })
}

# ---------------------------------------------------------------------------------------------------
# The engine probe runs first and unconditionally: stage 0 keys on its hash, stage 1 on its verdict,
# and even a stage-2-only run wants the engine in the report.
# ---------------------------------------------------------------------------------------------------
$engineInfo = & (Join-Path $PSScriptRoot 'Get-PsadtInstallerEngine.ps1') -Path $Path

# ---------------------------------------------------------------------------------------------------
# Stage 0: what a run on this machine already proved. Keyed by SHA256, because a product name is a
# label and a hash is the file.
# ---------------------------------------------------------------------------------------------------
if ($stagesRequested -contains 0) {
    # rule:config-home - Get-PsadtConfig.ps1 is the only resolver. Building the path from
    # $env:LOCALAPPDATA would ignore $env:PSADT_DEPLOY_HOME and write into the real profile.
    $cfg = & (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1')
    $storePath = Join-Path $cfg.Home 'verified-switches.json'

    if (-not (Test-Path -LiteralPath $storePath)) {
        Add-Miss 0 'cache' "no verified-switch store yet at $storePath - nothing has been proven on this machine"
    }
    else {
        $store = $null
        try { $store = Get-Content -LiteralPath $storePath -Raw | ConvertFrom-Json }
        catch { Add-Miss 0 'cache' "verified-switch store is not readable JSON: $($_.Exception.Message)" }

        if ($store) {
            $hit = @($store.entries | Where-Object { $_.sha256 -eq $engineInfo.Sha256 })[0]
            if ($hit) {
                $candidates.Add([pscustomobject]@{
                        Stage      = 0
                        Source     = 'cache'
                        SourceRef  = "verified $($hit.verifiedAt) by $($hit.verifiedBy)"
                        Confidence = 'verified'
                        HashMatch  = $true
                        Install    = $hit.install
                        Uninstall  = $hit.uninstall
                        InstallLog = $hit.installLog
                        NoReboot   = $hit.noReboot
                        DetectHint = $hit.detectHint
                        ReturnCodes = @($hit.returnCodes)
                        Notes      = @($hit.notes)
                        Evidence   = "SHA256 matches an entry proven on this machine ($($hit.scenarios -join ', '))"
                    })
            }
            else {
                $sameProduct = @($store.entries | Where-Object {
                        $_.productName -and $engineInfo.ProductName -and $_.productName -eq $engineInfo.ProductName
                    })[0]
                if ($sameProduct) {
                    # productVersion comes from the PE header, which for a WRAPPED installer is the
                    # wrapper's version, not the application's: every Mozilla full installer reports
                    # 18.05, the version of the 7-Zip SFX module around it. appVersion is the version
                    # the package declared, so it is the one a reader can act on. This string is not
                    # cosmetic - Get-PsadtLocalEvidence.ps1 puts it into the KnownContext handed to a
                    # research sub-agent, and "previous version 18.05" for Firefox is a false claim.
                    $prevVersion = if ($sameProduct.appVersion) { $sameProduct.appVersion } else { $sameProduct.productVersion }
                    $candidates.Add([pscustomobject]@{
                            Stage      = 0
                            Source     = 'cache'
                            SourceRef  = "previous version $prevVersion, verified $($sameProduct.verifiedAt)"
                            Confidence = 'medium'
                            HashMatch  = $false
                            Install    = $sameProduct.install
                            Uninstall  = $sameProduct.uninstall
                            InstallLog = $sameProduct.installLog
                            NoReboot   = $sameProduct.noReboot
                            DetectHint = $sameProduct.detectHint
                            ReturnCodes = @($sameProduct.returnCodes)
                            Notes      = @("Proven on a DIFFERENT build of this product - vendors change switches between versions.")
                            Evidence   = "same productName, different hash"
                        })
                }
                else {
                    Add-Miss 0 'cache' 'no entry for this hash and no earlier version of this product'
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------------------------------
# Stage 1: the engine default. Deterministic, offline, and the reason the catalog is in the skill at
# all - engines are a short, stable list, applications are a long tail that rots.
# ---------------------------------------------------------------------------------------------------
if ($stagesRequested -contains 1) {
    $catalogPath = Join-Path $PSScriptRoot '..\references\switch-catalog\engine-defaults.json'
    if (-not (Test-Path -LiteralPath $catalogPath)) {
        Add-Miss 1 'engine-default' "engine catalog not found at $catalogPath"
    }
    elseif ($engineInfo.Engine -eq 'unknown') {
        Add-Miss 1 'engine-default' 'engine could not be identified from the binary, so there is no default to offer'
    }
    else {
        $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
        $entry = @($catalog.engines | Where-Object { $_.engine -eq $engineInfo.Engine })[0]
        if (-not $entry) {
            Add-Miss 1 'engine-default' "engine '$($engineInfo.Engine)' has no entry in the catalog"
        }
        else {
            $firstMarker = if (@($engineInfo.Evidence).Count) { @($engineInfo.Evidence)[0].Marker } else { 'none' }
            $candidates.Add([pscustomobject]@{
                    Stage      = 1
                    Source     = 'engine-default'
                    SourceRef  = $entry.sourceRef
                    Confidence = 'low'
                    HashMatch  = $false
                    Install    = $entry.install
                    Uninstall  = $entry.uninstall
                    InstallLog = $entry.installLog
                    NoReboot   = $entry.noReboot
                    DetectHint = $entry.detectHint
                    ReturnCodes = @($entry.returnCodes)
                    Notes      = @($entry.notes)
                    Evidence   = "engine '$($entry.engine)' identified with confidence $($engineInfo.Confidence) from marker '$firstMarker'"
                })
        }
    }
}

# ---------------------------------------------------------------------------------------------------
# Stage 2: winget-pkgs. Opt-in by design, and not implemented in this release - the miss says which,
# so the caller is never left wondering whether the lookup ran and found nothing.
# ---------------------------------------------------------------------------------------------------
if ($stagesRequested -contains 2) {
    if (-not $WithWinget) {
        Add-Miss 2 'winget' 'not attempted: the winget-pkgs lookup is opt-in (-WithWinget), because WinGet is never auto-selected in this skill'
    }
    else {
        Add-Miss 2 'winget' 'requested, but the winget-pkgs lookup is not implemented in this release'
    }
}

if ($stagesRequested -contains 3) {
    Add-Miss 3 'research' 'the Researcher is a Phase 2 sub-agent, not a stage this script runs'
}

# ---------------------------------------------------------------------------------------------------
# Order: confidence first, then stage. A verified switch outranks a hash-matched manifest entry, which
# outranks a generic engine default, whatever order the stages happened to run in.
# ---------------------------------------------------------------------------------------------------
$rank = @{ verified = 0; high = 1; medium = 2; low = 3 }
$ordered = @($candidates | Sort-Object @{ Expression = { $rank[[string]$_.Confidence] } }, @{ Expression = { $_.Stage } })

$result = [pscustomobject]@{
    Path             = $Path
    Sha256           = $engineInfo.Sha256
    SizeBytes        = $engineInfo.SizeBytes
    Engine           = $engineInfo.Engine
    EngineConfidence = $engineInfo.Confidence
    EngineEvidence   = $engineInfo.Evidence
    IsMsi            = $engineInfo.IsMsi
    ProductName      = if ($ProductName) { $ProductName } else { $engineInfo.ProductName }
    ProductVersion   = $engineInfo.ProductVersion
    Publisher        = if ($Publisher) { $Publisher } else { $engineInfo.Publisher }
    Candidates       = $ordered
    Misses           = $misses.ToArray()
}

if ($JsonPath) { $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $JsonPath -Encoding UTF8 }
if ($Json) { return ($result | ConvertTo-Json -Depth 8) }

# --- Human view -------------------------------------------------------------------------------------
Write-Host ""
Write-Host ("Engine : {0} ({1})" -f $result.Engine, $result.EngineConfidence) -ForegroundColor Cyan
Write-Host ("SHA256 : {0}" -f $result.Sha256) -ForegroundColor DarkGray
if (@($ordered).Count -gt 0) {
    Write-Host ""
    @($ordered | Select-Object Stage, Source, Confidence,
        @{ n = 'Install'; e = { $_.Install } },
        @{ n = 'Uninstall'; e = { $_.Uninstall } }) | Format-Table -AutoSize | Out-String | Write-Host
    foreach ($c in $ordered) {
        foreach ($n in @($c.Notes)) { if ($n) { Write-Host ("  note [{0}] {1}" -f $c.Source, $n) -ForegroundColor Yellow } }
    }
}
else {
    Write-Host ""
    Write-Host ("No catalog hit. Engine '{0}' was identified with confidence '{1}'." -f $result.Engine, $result.EngineConfidence) -ForegroundColor Yellow
    Write-Host "  The probe run decides from here; the Researcher follows on RED." -ForegroundColor Yellow
}
Write-Host ""
foreach ($m in $misses) {
    Write-Host ("  stage {0} [{1}] {2}" -f $m.Stage, $m.Source, $m.Reason) -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "Every candidate above is a CLAIM until a run proves it (App. L.1)." -ForegroundColor DarkGray
Write-Host ""

return $result

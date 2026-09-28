#Requires -Version 5.1
<#
.SYNOPSIS
    Generate the combined PSADT package report (Intune dossier + technical package report)
    as a single self-contained HTML file from references/Report-Template.html.

.DESCRIPTION
    Fills the tokenized report template with package metadata and writes Intune-Dossier.html.
    The report is ALWAYS produced for a finished package - regardless of whether the package is
    uploaded to Intune (Phase 9) or not. The output is self-contained: the logo is embedded as
    a base64 data URI, the description preview is rendered client-side from its Markdown source,
    and the whole document switches between DE/EN in the browser (data-de/data-en).

    The script is data-driven: pass a -Metadata hashtable (or -MetadataPath to a JSON file). Every
    field has a sensible default so a minimal call still yields a complete, valid report. Variable
    length sections (return codes, cmdlets, deployment-hook bullets, pre-flight checks, SYSTEM-test
    rows, assignments) are built from arrays.

    Language note: this script is ASCII-clean. German default strings use HTML entities (e.g.
    &ouml;, &middot;); real umlauts only ever come in through runtime metadata (the description
    Markdown), and the output file is written as UTF-8.

.PARAMETER Metadata
    Hashtable with the package metadata. See references/appendix-f-dossier-template.md (F.0) for the full key list.

.PARAMETER MetadataPath
    Path to a JSON file with the same shape as -Metadata (alternative to -Metadata).

.PARAMETER OutputPath
    Target HTML file. Default: '<current dir>\Intune-Dossier.html'.

.PARAMETER TemplatePath
    Path to the report template. Default: references/Report-Template.html next to this script.

.PARAMETER LogoPath
    Path to the real app logo (PNG/SVG/JPG). Embedded as a base64 data URI. If omitted, a neutral
    initials tile is generated so the header is never empty.

.PARAMETER PassThru
    Return the generated file as a System.IO.FileInfo object.

.NOTES
    Author : PSADT v4.x Deployment Skill
    Part of the psadt-deploy skill. See SKILL.md Phase 7.
#>
[CmdletBinding(DefaultParameterSetName = 'Hash')]
param(
    [Parameter(ParameterSetName = 'Hash')]
    [hashtable]$Metadata = @{},

    [Parameter(ParameterSetName = 'Json', Mandatory)]
    [string]$MetadataPath,

    # A package manifest (psadt-package.json) to take the identity and the artifacts from. -Metadata still
    # wins for every key it sets, so a one-off override needs no manifest edit.
    [string]$ManifestPath,

    [string]$OutputPath,

    [string]$TemplatePath,

    [string]$LogoPath,

    # Render an explicit "not supplied" marker in place of the app description instead of refusing.
    # Deliberate and visible, the way -AllowDefaultLogo is on the upload script - never the default.
    [switch]$AllowMissingDescription,

    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------- resolve inputs
if ($PSCmdlet.ParameterSetName -eq 'Json') {
    if (-not (Test-Path $MetadataPath)) { throw "MetadataPath not found: $MetadataPath" }
    $json = Get-Content -LiteralPath $MetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # convert PSCustomObject -> hashtable
    $Metadata = @{}
    foreach ($p in $json.PSObject.Properties) { $Metadata[$p.Name] = $p.Value }
}

# A recorded timestamp as its ISO day (0.49.3). ConvertFrom-Json turns an ISO string into [datetime], and
# [string] of that is culture-formatted - the assignment tag read '09/27/2026' (measured 2026-09-27).
function Format-IsoDay($Value) {
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-dd') }
    $s = [string]$Value
    if ($s.Length -ge 10) { return $s.Substring(0, 10) }
    return $s
}

# ----------------------------------------------------------------------------- manifest (0.21.0)
$launcherAst = $null; $launcherTokens = $null; $launcherFile = $null
if ($ManifestPath) {
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "ManifestPath not found: $ManifestPath" }
    try { $mf = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "psadt-package.json is malformed: $($_.Exception.Message)" }

    # Only fill what -Metadata did not set: an explicit argument always wins.
    function Set-FromManifest([string]$Key, $Value) {
        if ($null -eq $Value -or '' -eq $Value) { return }
        if (-not $Metadata.ContainsKey($Key) -or $null -eq $Metadata[$Key]) { $Metadata[$Key] = $Value }
    }
    Set-FromManifest 'AppName'      $mf.app.name
    Set-FromManifest 'AppVersion'   $mf.app.version
    Set-FromManifest 'Publisher'    $mf.app.vendor
    Set-FromManifest 'Location'     $mf.artifacts.outputFolder
    if ($mf.artifacts.intunewin) { Set-FromManifest 'IntuneWin' ([IO.Path]::GetFileName([string]$mf.artifacts.intunewin)) }
    if ($mf.artifacts.detection) { Set-FromManifest 'DetectScript' ([IO.Path]::GetFileName([string]$mf.artifacts.detection)) }
    Set-FromManifest 'SetupFile'    $mf.results.package.setupFile
    Set-FromManifest 'DriverTrust'  $mf.driverTrust
    # The App-information fields, ONE derivation with the upload (Resolve-PsadtIntuneAppInfo, 0.49.3). This
    # document used to print Developer = vendor, a branded "PSADT vX - pkg rev NN" note and "Windows 10
    # 22H2" while the upload sent an empty developer, empty notes and 1607.
    . (Join-Path $PSScriptRoot '_AppKey.ps1')
    $cfgNotes = ''
    try {
        $cfgR = (& (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1')).Config
        if ($cfgR.intune -and $cfgR.intune.notes) { $cfgNotes = [string]$cfgR.intune.notes }
    } catch {}
    $appInfo = Resolve-PsadtIntuneAppInfo -Manifest $mf -ConfigNotes $cfgNotes
    Set-FromManifest 'Developer'  $appInfo.Developer
    Set-FromManifest 'Owner'      $appInfo.Owner
    Set-FromManifest 'Notes'      $appInfo.Notes
    Set-FromManifest 'InfoUrl'    $appInfo.InformationUrl
    Set-FromManifest 'PrivacyUrl' $appInfo.PrivacyUrl
    Set-FromManifest 'MinOs'      "Windows 10 $($appInfo.MinWindowsRelease)"
    # The assignments Phase 10 set and read back (Invoke-IntuneAppAssignment.ps1 -ManifestPath, 0.49.3).
    # Until then they reached this document only through -Metadata, so a real three-group assignment was
    # shown as "not yet assigned - a suggestion".
    $asgRecorded = $null
    if ($mf.results.assignment -and $mf.results.assignment.groups) {
        $asgRecorded = $mf.results.assignment
        Set-FromManifest 'Assignments' @($asgRecorded.groups | ForEach-Object { @{ Group = [string]$_.Group; GroupId = [string]$_.GroupId; Type = [string]$_.Type; Availability = [string]$_.Availability } })
    }
    # The command lines the package ships (0.49.2), parsed once, by Get-PsadtPackageManifest.ps1 - the
    # upload reads the same value. Before, the dossier printed its own '-DeployMode Silent' default
    # whatever Gate 2 had chosen. A line the upload would refuse is named, not rendered as if it were fine.
    $mfDir = Split-Path -Parent (Resolve-Path -LiteralPath $ManifestPath).ProviderPath
    if (Test-Path -LiteralPath (Join-Path $mfDir 'Invoke-AppDeployToolkit.ps1')) {
        $mfCmds = (& (Join-Path $PSScriptRoot 'Get-PsadtPackageManifest.ps1') -PackagePath $mfDir).Commands
        foreach ($c in @(@('InstallCmd', $mfCmds.Install, 'installCommand'), @('UninstallCmd', $mfCmds.Uninstall, 'uninstallCommand'))) {
            if (-not $c[1].Valid) { Write-Warning "package.$($c[2]) is refused by the upload and the sandbox: $($c[1].Reason). Recorded: '$($c[1].Command)'" }
            elseif ($c[1].Recorded) { Set-FromManifest $c[0] $c[1].Command }
        }
    }
    # Installer-specific return codes researched in Phase 1.3. Recorded once in the manifest so the
    # dossier and Invoke-IntuneWin32Upload.ps1 cannot document different mappings.
    Set-FromManifest 'ReturnCodes'  $mf.research.returnCodes
    # The Company-Portal description, recorded once (app.description.de/en) so the dossier and the upload
    # cannot carry different texts. Chrome 154 (0.44.0): the same Markdown was typed twice, into -Metadata
    # and into -Description, and nothing kept the two in step.
    if ($mf.app.description) {
        Set-FromManifest 'DescMdDe' $mf.app.description.de
        Set-FromManifest 'DescMdEn' $mf.app.description.en
    }

    # What the upload left behind (0.49.4): the app id, when, and the hash of the file that went up. The
    # dossier of an uploaded package said nothing about the upload at all.
    Set-FromManifest 'UploadAppId'   $mf.results.upload.appId
    Set-FromManifest 'UploadPortal'  $mf.results.upload.portalUrl
    if ($mf.results.upload.at) { Set-FromManifest 'UploadAt' (Format-IsoDay $mf.results.upload.at) }
    Set-FromManifest 'PackageSha256' $mf.results.package.sha256

    # The launcher, parsed once: the hooks further down read it, and so do the header fields (0.49.4) -
    # the header printed script version 0.1, revision 01 and no author for a launcher that declared 0.2,
    # 01 and its author, because it only knew -Metadata and literals.
    $launcherFile = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $ManifestPath).Path) 'Invoke-AppDeployToolkit.ps1'
    if (Test-Path -LiteralPath $launcherFile) {
        $launcherTokens = $null
        $launcherAst = [System.Management.Automation.Language.Parser]::ParseFile($launcherFile, [ref]$launcherTokens, [ref]$null)
        $sessionHt = $launcherAst.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$adtSession' -and
                $n.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and
                $n.Right.Expression -is [System.Management.Automation.Language.HashtableAst] }, $true) |
            Select-Object -First 1
        if ($sessionHt) {
            foreach ($kv in $sessionHt.Right.Expression.KeyValuePairs) {
                $key = [string]$kv.Item1.Extent.Text.Trim("'", '"')
                $expr = if ($kv.Item2 -is [System.Management.Automation.Language.PipelineAst]) { $kv.Item2.GetPureExpression() } elseif ($kv.Item2 -is [System.Management.Automation.Language.CommandExpressionAst]) { $kv.Item2.Expression } else { $null }
                if ($expr -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
                switch ($key) {
                    'AppScriptVersion' { Set-FromManifest 'ScriptVersion' $expr.Value }
                    'AppRevision'      { Set-FromManifest 'PkgRev' $expr.Value }
                    'AppScriptAuthor'  { Set-FromManifest 'Author' $expr.Value }
                }
            }
        }
    }

    # Supersedence, from what was actually wired rather than from what was typed. The field existed only
    # as a -Metadata value, so App. F.8 asked the dossier to document a relationship the dossier had no
    # way to see - and the upload recorded it nowhere either until 0.47.0. results.supersedence (written
    # by Set-IntuneAppSupersedence.ps1) wins over results.upload: it is the later and more deliberate act.
    $supRec = if ($mf.results.supersedence -and $mf.results.supersedence.supersedes) { $mf.results.supersedence }
    elseif ($mf.results.upload -and $mf.results.upload.supersedes) { $mf.results.upload }
    else { $null }
    # The superseded apps by NAME AND VERSION when the supersedence recorded them (0.49.3) - a bare GUID
    # told the reader nothing about which version this one replaces.
    $supNoteDe = $null; $supNoteEn = $null
    if ($supRec) {
        $supNamed = @($supRec.supersedesApps | Where-Object { $_ -and $_.displayName })
        $supIds  = if ($supNamed.Count) { @($supNamed | ForEach-Object { ("$($_.displayName) $($_.displayVersion)").Trim() }) -join ', ' }
                   else { @($supRec.supersedes) -join ', ' }
        $supMode = if ($supRec.supersedenceType) { [string]$supRec.supersedenceType } else { 'update' }
        Set-FromManifest 'Supersedence' $supIds
        if ($supMode -eq 'replace') {
            $supNoteDe = 'Modus "replace": die Vorversion wird vor der Installation DEINSTALLIERT. Sie bleibt in Intune erhalten (Rollback-Ziel), wird aber nicht mehr angeboten.'
            $supNoteEn = 'Mode "replace": the previous version is UNINSTALLED before the new one installs. It stays in Intune as a rollback target but is no longer offered.'
        } else {
            $supNoteDe = 'Modus "update": das Installationsprogramm aktualisiert die Vorversion selbst; es wird kein Deinstallationsbefehl gesendet. Die Vorversion bleibt in Intune erhalten (Rollback-Ziel).'
            $supNoteEn = 'Mode "update": the installer upgrades the previous version itself; no uninstall command is sent. The previous version stays in Intune as a rollback target.'
        }
    }
    # ...and, on a superseded version, what superseded it. Set-IntuneAppSupersedence.ps1 records that on the
    # OLD package since 0.49.3; before, the old package's dossier never learned it had been replaced.
    $by = $mf.results.supersededBy
    if ($by -and $by.appId) {
        $byName = ("$($by.displayName) $($by.displayVersion)").Trim()
        # Esc is defined further down; the same four replacements, here.
        $byHtml = $byName.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
        $byMode = if ($by.supersedenceType) { [string]$by.supersedenceType } else { 'update' }
        $byDate = if ($by.at) { Format-IsoDay $by.at } else { '' }
        $byDe = "Abgel&ouml;st durch $byHtml (Modus $byMode$(if ($byDate) { ", $byDate" })). Diese Version bleibt in Intune als Rollback-Ziel."
        $byEn = "Superseded by $byHtml (mode $byMode$(if ($byDate) { ", $byDate" })). This version stays in Intune as a rollback target."
        if (-not $supRec) { Set-FromManifest 'Supersedence' $byName }
        $supNoteDe = if ($supNoteDe) { "$supNoteDe $byDe" } else { $byDe }
        $supNoteEn = if ($supNoteEn) { "$supNoteEn $byEn" } else { $byEn }
    }
    Set-FromManifest 'SupersedenceNoteDe' $supNoteDe
    Set-FromManifest 'SupersedenceNoteEn' $supNoteEn

    # The sandbox harness already measures every action and writes its verdict, exit codes, durations and
    # detection results into result.json, recording the path in the manifest. Until 0.32.0 this document
    # ignored all of it: without a hand-built -Metadata SystemTest it printed "the SYSTEM test was not run
    # (no evidence)" - on a package whose gate was GREEN. The only way to correct that was to retype, by
    # hand, numbers the harness had already produced, which is exactly the kind of transcription this
    # skill refuses everywhere else. It is read here instead.
    #
    # A caller-supplied SystemTest still wins: Set-FromManifest never overwrites a key that is already
    # present, and the DEV-VM route (Invoke-PsadtSystemTest.ps1) has no result.json to read. Whether the
    # upload gate is met is NOT read from these rows - a GREEN_PARTIAL run produces rows like any other -
    # but from the manifest's verdict, below (.TestGate).
    if (-not $Metadata.ContainsKey('SystemTest')) {
        $sbxResultPath = [string]$mf.results.sandboxTest.resultPath
        if ($sbxResultPath -and (Test-Path -LiteralPath $sbxResultPath)) {
            try {
                $sbx = Get-Content -LiteralPath $sbxResultPath -Raw | ConvertFrom-Json

                # Whether the rule was expected to find the app after each action. This is what makes a
                # row a PASS or a FAIL - an action that exits 0 while detection disagrees is not a pass.
                $expectDetected = @{
                    Install = $true; Reinstall = $true; Repair = $true
                    Uninstall = $false; FinalUninstall = $false
                }
                $labelDe = @{
                    Install = 'Installation'; Uninstall = 'Deinstallation'; Reinstall = 'Neuinstallation'
                    Repair = 'Reparatur'; FinalUninstall = 'Abschlie&szlig;ende Deinstallation'
                }
                $labelEn = @{
                    Install = 'Install'; Uninstall = 'Uninstall'; Reinstall = 'Reinstall'
                    Repair = 'Repair'; FinalUninstall = 'Final uninstall'
                }

                $detected = @{}
                foreach ($s in $sbx.steps) {
                    if ([string]$s.step -like 'DetectionAfter*') { $detected[[string]$s.step] = [bool]$s.detected }
                }

                $sbxRows = @(foreach ($name in 'Install', 'Uninstall', 'Reinstall', 'Repair', 'FinalUninstall') {
                        $step = $sbx.steps | Where-Object { [string]$_.step -eq $name } | Select-Object -First 1
                        if (-not $step) { continue }
                        $key = "DetectionAfter$name"
                        $det = if ($detected.ContainsKey($key)) { $detected[$key] } else { $null }
                        $ok = [bool]$step.success -and ($null -eq $det -or $det -eq $expectDetected[$name])
                        $secs = if ($null -ne $step.seconds) { " ($($step.seconds) s)" } else { '' }
                        @{
                            StepDe    = $labelDe[$name] + $secs
                            StepEn    = $labelEn[$name] + $secs
                            Exit      = "$($step.exitCode)"
                            # One value per language: a single bilingual string ("erkannt / detected") could not
                            # follow the dossier's language switch and showed German in the English view.
                            DetectionDe = $(if ($null -eq $det) { '&ndash;' } elseif ($det) { 'erkannt' } else { 'nicht erkannt' })
                            DetectionEn = $(if ($null -eq $det) { '&ndash;' } elseif ($det) { 'detected' } else { 'absent' })
                            # 'b-fail' is the class the stylesheet defines. 'b-bad' styled nothing, and the
                            # header status - which looks for 'b-fail' - never saw the failure (0.49.4).
                            Cls       = $(if ($ok) { 'b-ok' } else { 'b-fail' })
                            Result    = $(if ($ok) { 'pass' } else { 'fail' })
                            ResultDe  = $(if ($ok) { 'bestanden' } else { 'fehlgeschlagen' })
                            ResultEn  = $(if ($ok) { 'passed' } else { 'failed' })
                            Action    = $name
                        }
                    })

                if ($sbxRows.Count) {
                    $Metadata['SystemTest'] = $sbxRows
                    $verdict = [string]$sbx.verdict
                    $failed = @($sbx.failedAssertions)
                    $failedText = if ($failed.Count) { ($failed -join ', ') } else { $null }
                    if (-not $Metadata.ContainsKey('SystemTestNoteDe')) {
                        $Metadata['SystemTestNoteDe'] = 'Windows Sandbox, jede Aktion als NT AUTHORITY\SYSTEM &uuml;ber eine geplante Aufgabe. Verdikt: ' +
                        $verdict + '. ' + $(if ($failedText) { 'Fehlgeschlagene Zusicherungen: ' + $failedText + '. ' } else { 'Keine fehlgeschlagene Zusicherung. ' }) +
                        'Die Erkennung wurde nach jeder Aktion gegen dieselbe Regel gepr&uuml;ft, die Intune auswertet. Beleg: ' + $sbxResultPath
                    }
                    if (-not $Metadata.ContainsKey('SystemTestNoteEn')) {
                        $Metadata['SystemTestNoteEn'] = 'Windows Sandbox, every action as NT AUTHORITY\SYSTEM through a scheduled task. Verdict: ' +
                        $verdict + '. ' + $(if ($failedText) { 'Failed assertions: ' + $failedText + '. ' } else { 'No failed assertion. ' }) +
                        'Detection was evaluated after every action against the same rule Intune runs. Evidence: ' + $sbxResultPath
                    }
                }
            }
            catch {
                # A result.json that cannot be read must not cost the caller the whole dossier. The
                # neutral "not run" default then stands, which is the honest state for unreadable evidence.
                Write-Verbose "sandbox result.json not usable: $($_.Exception.Message)"
            }
        }
    }

    # The DEV-VM route (0.49.4). Invoke-PsadtSystemTest.ps1 appends every action to results.systemTest, and
    # the upload gate (.TestGate) already reads it - but this document did not, so a package whose gate was
    # met printed "the SYSTEM test was not run" unless someone retyped the rows into -Metadata by hand.
    if (-not $Metadata.ContainsKey('SystemTest') -and @($mf.results.systemTest).Count) {
        $devLabelDe = @{ Install = 'Installation'; Uninstall = 'Deinstallation'; Repair = 'Reparatur' }
        $expectDev = @{ Install = $true; Repair = $true; Uninstall = $false }
        $devRows = @(foreach ($t in @($mf.results.systemTest)) {
                $type = [string]$t.type
                if (-not $devLabelDe.ContainsKey($type)) { continue }
                $when = ''
                if ($t.at) {
                    $d = if ($t.at -is [datetime]) { $t.at } else { [datetime]::Parse([string]$t.at, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) }
                    $d = $d.ToLocalTime()
                    $when = " ($($d.ToString('dd.MM. HH:mm', [cultureinfo]::InvariantCulture)))"
                    $whenEn = " ($($d.ToString('MM-dd HH:mm', [cultureinfo]::InvariantCulture)))"
                } else { $whenEn = '' }
                $det = switch ([string]$t.detection) { 'installed' { $true } 'not-installed' { $false } default { $null } }
                $ok = [bool]$t.success -and ($null -eq $det -or $det -eq $expectDev[$type])
                @{
                    StepDe = $devLabelDe[$type] + $when; StepEn = $type + $whenEn; Exit = "$($t.exitCode)"
                    DetectionDe = $(if ($null -eq $det) { 'nicht protokolliert' } elseif ($det) { 'erkannt' } else { 'nicht erkannt' })
                    DetectionEn = $(if ($null -eq $det) { 'not recorded' } elseif ($det) { 'detected' } else { 'absent' })
                    Cls = $(if ($ok) { 'b-ok' } else { 'b-fail' }); Result = $(if ($ok) { 'pass' } else { 'fail' })
                    ResultDe = $(if ($ok) { 'bestanden' } else { 'fehlgeschlagen' }); ResultEn = $(if ($ok) { 'passed' } else { 'failed' })
                    Action = $type
                }
            })
        if ($devRows.Count) {
            $Metadata['SystemTest'] = $devRows
            $nOk = @($devRows | Where-Object { $_.Cls -eq 'b-ok' }).Count
            if (-not $Metadata.ContainsKey('SystemTestNoteDe')) {
                $Metadata['SystemTestNoteDe'] = "DEV-VM-Route: jede Aktion einzeln als NT AUTHORITY\SYSTEM (Invoke-PsadtSystemTest.ps1). $($devRows.Count) L&auml;ufe, $nOk bestanden." +
                $(if ($mf.results.gate.verdict) { " Gate-Verdikt: $([string]$mf.results.gate.verdict)$(if ($mf.results.gate.at) { ' (' + (Format-IsoDay $mf.results.gate.at) + ')' })." })
            }
            if (-not $Metadata.ContainsKey('SystemTestNoteEn')) {
                $Metadata['SystemTestNoteEn'] = "DEV-VM route: every action on its own as NT AUTHORITY\SYSTEM (Invoke-PsadtSystemTest.ps1). $($devRows.Count) runs, $nOk passed." +
                $(if ($mf.results.gate.verdict) { " Gate verdict: $([string]$mf.results.gate.verdict)$(if ($mf.results.gate.at) { ' (' + (Format-IsoDay $mf.results.gate.at) + ')' })." })
            }
        }
    }

    # The identity floor. Everything else - IntuneWin, Preflight, SystemTest - renders neutrally, because
    # "report ALWAYS" has to hold for a package that is not packed or tested yet. But a dossier that says
    # "App 0.0.0" is not an honest deliverable, it is a placeholder with a letterhead.
    $identityGaps = @('AppName', 'AppVersion', 'Publisher') |
        Where-Object { [string]::IsNullOrWhiteSpace([string]$Metadata[$_]) }
    if ($identityGaps.Count) {
        throw "The manifest identity is incomplete ($($identityGaps -join ', ')) - fill it with Set-PsadtPackageManifest.ps1, or pass the values via -Metadata. A dossier without a real app identity is a placeholder, not a deliverable."
    }

    # The SYSTEM test is BINDING for a package that is going to be uploaded (rule:test-before-upload). Until
    # 0.49.3 this dossier ENFORCED it by refusing to render - the only place that did, while SKILL.md has the
    # dossier rendered before the sandbox verdict exists. The upload enforces it now, from the verdict
    # Get-PsadtPackageManifest.ps1 derives (.TestGate); this dossier SHOWS the same verdict, so the two can
    # never disagree. A partial run (GREEN_PARTIAL) is still not a pass - the upload refuses it, and the
    # status line and the SYSTEM-test note below say why.
    $uploadGate = $null
    if ($mf.decisions.upload -eq $true) {
        $uploadGate = (& (Join-Path $PSScriptRoot 'Get-PsadtPackageManifest.ps1') -Manifest $mf).TestGate
    }

    # The Company-Portal description is the one field in this document an end user reads, and it is
    # copied out of here by hand. A default of "_Beschreibung folgt._" is not a neutral empty state:
    # it renders as a finished sentence, survives review, and ships to every device in the assignment.
    # Same rule as the identity floor above - do not invent a value that looks supplied.
    $hasDesc = ($Metadata.ContainsKey('DescMdDe') -and -not [string]::IsNullOrWhiteSpace([string]$Metadata['DescMdDe'])) -or
               ($Metadata.ContainsKey('DescMdEn') -and -not [string]::IsNullOrWhiteSpace([string]$Metadata['DescMdEn']))
    if (-not $hasDesc -and -not $AllowMissingDescription) {
        if ($mf.decisions.upload -eq $true) {
            throw "No app description was supplied (DescMdDe / DescMdEn) and decisions.upload is true. That text goes to Company Portal verbatim - write it, or pass -AllowMissingDescription to render an explicit 'not supplied' marker instead."
        }
        Write-Warning "No app description supplied (DescMdDe / DescMdEn). The dossier will show an explicit 'not supplied' marker rather than placeholder prose. Fill it before any upload."
    }
}

if (-not $TemplatePath) {
    $TemplatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'references\Report-Template.html'
}
if (-not (Test-Path $TemplatePath)) { throw "Template not found: $TemplatePath" }

if (-not $OutputPath) { $OutputPath = Join-Path (Get-Location) 'Intune-Dossier.html' }

# ----------------------------------------------------------------------------- helpers
function Get-Val {
    param($Key, $Default)
    if ($Metadata.ContainsKey($Key) -and $null -ne $Metadata[$Key]) { return $Metadata[$Key] }
    return $Default
}
function Esc {
    param($s)
    if ($null -eq $s) { return '' }
    return ([string]$s).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}
# Attribute-escape an ALREADY-HTML string (entities preserved, only quotes escaped).
function AttrHtml { param($s) if ($null -eq $s) { return '' } return ([string]$s).Replace('"', '&quot;') }
function Codei { param($s) return "<code>$(Esc $s)</code>" }
# bilingual <span> from HTML-ready strings (entities allowed)
function Bspan { param($de, $en) return "<span data-de=`"$(AttrHtml $de)`" data-en=`"$(AttrHtml $en)`">$de</span>" }
function Badge {
    param($cls, $de, $en)
    if ($PSBoundParameters.ContainsKey('en') -and $en) {
        return "<span class=`"badge $cls`" data-de=`"$(AttrHtml $de)`" data-en=`"$(AttrHtml $en)`">$de</span>"
    }
    return "<span class=`"badge $cls`">$de</span>"
}
function NoteHtml {
    param($de, $en)
    if ($PSBoundParameters.ContainsKey('en') -and $en) {
        return "<span class=`"note`" data-de=`"$(AttrHtml $de)`" data-en=`"$(AttrHtml $en)`">$de</span>"
    }
    return "<span class=`"note`">$de</span>"
}

# ----------------------------------------------------------------------------- logo data URI
function Get-LogoDataUri {
    param($Path, $AppName)
    if ($Path -and (Test-Path $Path)) {
        $ext = ([System.IO.Path]::GetExtension($Path)).TrimStart('.').ToLowerInvariant()
        $mime = switch ($ext) {
            'png'  { 'image/png' }
            'jpg'  { 'image/jpeg' }
            'jpeg' { 'image/jpeg' }
            'gif'  { 'image/gif' }
            'svg'  { 'image/svg+xml' }
            default { 'image/png' }
        }
        $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $Path).Path)
        return "data:$mime;base64,$([System.Convert]::ToBase64String($bytes))"
    }
    # fallback: neutral initials tile (so the header is never empty)
    $initials = -join (($AppName -split '\s+' | Where-Object { $_ } | Select-Object -First 2) |
        ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() })
    if (-not $initials) { $initials = 'AP' }
    # XML-escape the initials (AppName-derived) and base64-encode the data URI so a special character
    # in AppName can neither break the SVG nor inject markup.
    $initialsSafe = [System.Security.SecurityElement]::Escape($initials)
    $svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 120 120'>" +
           "<text x='60' y='78' font-family='Segoe UI,Arial,sans-serif' font-size='56' font-weight='700' " +
           "fill='#0F6CBD' text-anchor='middle'>$initialsSafe</text></svg>"
    return "data:image/svg+xml;base64,$([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($svg)))"
}

# Width, height and alpha from a PNG's IHDR chunk (bytes 16-25) - deterministic, no image library. $null
# for anything that is not a complete PNG header, so the caller says "not checked" instead of guessing.
function Get-PngFacts {
    param($Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $buf = New-Object byte[] 26
    $fs = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try { $n = $fs.Read($buf, 0, 26) } finally { $fs.Dispose() }
    if ($n -lt 26) { return $null }
    $sig = @(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    for ($i = 0; $i -lt 8; $i++) { if ($buf[$i] -ne $sig[$i]) { return $null } }
    if ([System.Text.Encoding]::ASCII.GetString($buf, 12, 4) -ne 'IHDR') { return $null }
    $be = { param($o) ([uint32]$buf[$o] -shl 24) -bor ([uint32]$buf[$o + 1] -shl 16) -bor ([uint32]$buf[$o + 2] -shl 8) -bor [uint32]$buf[$o + 3] }
    # Colour type 4 (grey + alpha) and 6 (RGBA) carry an alpha channel.
    [pscustomobject]@{ Width = [int](& $be 16); Height = [int](& $be 20); Alpha = ($buf[25] -eq 4 -or $buf[25] -eq 6) }
}

# ----------------------------------------------------------------------------- scalar values
# language.dossier is what SKILL.md promises decides this, and until 0.46.0 nothing read it: the template
# is bilingual, so the key only chooses which language the file OPENS in. -Metadata Lang still wins.
$cfgLang = $null
try {
    $cfgProbe = & (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1')
    if ($cfgProbe.Config -and $cfgProbe.Config.language -and $cfgProbe.Config.language.dossier) {
        $cfgLang = ([string]$cfgProbe.Config.language.dossier).ToLowerInvariant()
    }
} catch { }
$lang          = Get-Val 'Lang' $(if ($cfgLang) { $cfgLang } else { 'de' })
$appName       = Get-Val 'AppName' 'App'
$appVersion    = Get-Val 'AppVersion' '0.0.0'
$publisher     = Get-Val 'Publisher' ''
$developer     = Get-Val 'Developer' $publisher
$owner         = Get-Val 'Owner' ''
# No invented header facts (0.49.4): script version, revision and author come from the launcher (read in
# the manifest block), the author otherwise from config.author; a value nobody supplied renders as a dash
# instead of the literals '0.1' and '01', which read like facts about the package.
$cfgAuthor = ''
if ($cfgProbe -and $cfgProbe.Config -and $cfgProbe.Config.author) {
    $cfgAuthor = (@([string]$cfgProbe.Config.author.person, [string]$cfgProbe.Config.author.company) | Where-Object { $_ }) -join ', '
}
$pkgRev        = Get-Val 'PkgRev' ''
$scriptVersion = Get-Val 'ScriptVersion' ''
$created       = Get-Val 'Created' (Get-Date -Format 'yyyy-MM-dd')
$author        = Get-Val 'Author' $cfgAuthor
# Default the PSADT version from the ACTUALLY INSTALLED module, not a literal that silently goes stale
# on the next PSADT update; '4.1.8' is only the last-resort fallback when the module isn't present.
$psadtModuleInfo = try {
    Get-Module -ListAvailable PSAppDeployToolkit -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
} catch { $null }
$psadtInstalled = if ($psadtModuleInfo) { $psadtModuleInfo.Version.ToString() } else { $null }
$psadtVersion  = Get-Val 'PsadtVersion' $(if ($psadtInstalled) { $psadtInstalled } else { '4.1.8' })
$moduleVersion = Get-Val 'ModuleVersion' $psadtVersion

$subDe   = Get-Val 'SubDe' "Intune Win32 &middot; PSADT v$psadtVersion Paket-Report"
$subEn   = Get-Val 'SubEn' "Intune Win32 &middot; PSADT v$psadtVersion package report"
# $statusDe / $statusEn are DERIVED further down, once the pre-flight and SYSTEM-test evidence has
# actually been read. They used to default to "Upload-bereit / Ready to upload - tested", which this
# document then contradicted three sections later with "no SYSTEM-test results supplied (no evidence)".
# The header is the line people read; a claim there has to come from the evidence, not from a literal.

# ----------------------------------------------------------------------------- app-info cells
$cat = Get-Val 'Category' $null
if ([string]::IsNullOrWhiteSpace([string]$cat)) {
    $vCategory = (Badge 'b-neut' 'nicht vorbelegt' 'not preset') +
                 (NoteHtml 'Wird vom Anwender/Org gesetzt &ndash; nie automatisch.' 'Set by the user/org &ndash; never automatically.')
} else {
    $vCategory = Badge 'b-info' (Esc $cat) (Esc $cat)
}

$featured = [bool](Get-Val 'Featured' $false)
$vFeatured = if ($featured) { Badge 'b-info' 'Ja' 'Yes' } else { Badge 'b-neut' 'Nein' 'No' }

$infoUrl    = Get-Val 'InfoUrl' ''
$privacyUrl = Get-Val 'PrivacyUrl' ''
$vInfoUrl    = if ($infoUrl) { Codei $infoUrl } else { Bspan 'nicht gesetzt' 'not set' }
$vPrivacyUrl = if ($privacyUrl) { Codei $privacyUrl } else { Bspan 'nicht gesetzt' 'not set' }
# No branded default (0.49.3): the upload sends none, and a note that is not in Intune is not a fact.
$notesVal = Get-Val 'Notes' ''
$vNotes = if ($notesVal) { Esc $notesVal } else { Bspan 'nicht gesetzt' 'not set' }

$vOwner = if ($owner) { Esc $owner } else { Bspan 'nicht gesetzt' 'not set' }

# The logo is described once, in the logo section (0.49.4). An app-information row said the same thing
# again - "real app logo, <file>" - and told the reader nothing the logo section does not.
$logoLeaf = ''
if ($LogoPath) { $logoLeaf = Split-Path $LogoPath -Leaf }
$logoSource = Get-Val 'LogoSource' $logoLeaf
$logoGuardOk = [bool](Get-Val 'LogoGuardOk' $true)

# ----------------------------------------------------------------------------- program cells
$vInstallCmd   = Codei (Get-Val 'InstallCmd' 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent')
$vUninstallCmd = Codei (Get-Val 'UninstallCmd' 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent')
$vInstallBehavior = Badge 'b-ok' (Esc (Get-Val 'InstallBehavior' 'System')) (Esc (Get-Val 'InstallBehavior' 'System'))
$restartDe = Get-Val 'RestartBehaviorDe' 'Verhalten basierend auf R&uuml;ckgabecodes bestimmen'
$restartEn = Get-Val 'RestartBehaviorEn' 'Determine behavior based on return codes'
$restartNoteDe = Get-Val 'RestartNoteDe' ''
$restartNoteEn = Get-Val 'RestartNoteEn' ''
$vRestart = (Bspan $restartDe $restartEn)
if ($restartNoteDe) { $vRestart += ' ' + (NoteHtml $restartNoteDe $restartNoteEn) }
$installTime = Get-Val 'InstallTimeMin' 60
$vInstallTime = Bspan "$installTime Minuten" "$installTime minutes"
$allowUninstall = [bool](Get-Val 'AllowUninstall' $true)
$vAllowUninstall = if ($allowUninstall) { Badge 'b-ok' 'Ja' 'Yes' } else { Badge 'b-neut' 'Nein' 'No' }

# ----------------------------------------------------------------------------- requirements / detection
$vOsArch = Esc (Get-Val 'OsArch' 'x64')
# 1607 is what the upload sends by default (0.49.3); '22H2' was printed here while Intune got 1607.
$vMinOs  = Esc (Get-Val 'MinOs' 'Windows 10 1607')
# An unset requirement says so (0.49.4); the disk-space cell used to be empty.
$vDisk   = $dsk = Get-Val 'DiskMb' ''
$vDisk   = if ($dsk) { Esc $dsk } else { (Bspan 'nicht festgelegt' 'not set') }
$vMemory = $m = Get-Val 'MemoryMb' ''
$vMemory = if ($m) { Esc $m } else { (Bspan 'nicht festgelegt' 'not set') }

# Certificate / driver-trust policy (guide Appendix N). CertPolicy = @{ Store; Thumbprint; OmaUri; Owner }
# Owner = 'Policy' (Intune Custom OMA-URI) | 'Package' (in-script import). Default: none required.
$cp = Get-Val 'CertPolicy' $null
if (-not $cp) {
    $vCertPolicy = (Badge 'b-neut' 'keine' 'none') + (NoteHtml 'kein Zertifikat erforderlich' 'no certificate required')
} else {
    $cpGet = { param($k) if ($cp -is [hashtable]) { $cp[$k] } elseif ($cp.PSObject -and $cp.PSObject.Properties[$k]) { $cp.$k } else { $null } }
    $cpStore = [string](& $cpGet 'Store'); if (-not $cpStore) { $cpStore = 'TrustedPublisher' }
    $cpOwner = [string](& $cpGet 'Owner'); if (-not $cpOwner) { $cpOwner = 'Policy' }
    $cpThumb = [string](& $cpGet 'Thumbprint')
    $cpOma   = [string](& $cpGet 'OmaUri')
    $ownerBadge = if ($cpOwner -match 'Package') { Badge 'b-warn' 'Paket-Import' 'package import' } else { Badge 'b-ok' 'Intune-Policy' 'Intune policy' }
    $vCertPolicy = (Badge 'b-info' (Esc $cpStore) (Esc $cpStore)) + ' ' + $ownerBadge
    if ($cpThumb) { $vCertPolicy += (NoteHtml "Thumbprint $(Esc $cpThumb)" "thumbprint $(Esc $cpThumb)") }
    if ($cpOma)   { $vCertPolicy += '<br>' + (Codei $cpOma) }
}

# Driver trust (guide Appendix Q). Fed from the manifest's driverTrust when -ManifestPath was used, or via
# -Metadata DriverTrust. A package without drivers renders a neutral row rather than an empty cell - "no
# drivers" is a fact worth stating in a dossier that a reviewer reads.
$dt = Get-Val 'DriverTrust' $null
if (-not $dt) {
    $vDrivers = (Badge 'b-neut' 'keine Treiber' 'no drivers') + (NoteHtml 'das Paket liefert keine Treiber aus' 'this package ships no drivers')
} else {
    $dtGet = { param($k) if ($dt -is [hashtable]) { $dt[$k] } elseif ($dt.PSObject -and $dt.PSObject.Properties[$k]) { $dt.$k } else { $null } }
    $dtClass = [string](& $dtGet 'classification')
    $dtOwner = [string](& $dtGet 'owner')
    $dtThumb = [string](& $dtGet 'thumbprint')
    $dtSbOff = [bool](& $dtGet 'assumeSecureBootOff')
    $dtList  = @(& $dtGet 'drivers')

    $classBadge = switch ($dtClass) {
        'GREEN'  { Badge 'b-ok'   'Microsoft-signiert' 'Microsoft-signed' }
        'YELLOW' { Badge 'b-warn' 'herstellersigniert' 'vendor-signed' }
        'RED'    { Badge 'b-fail' 'nicht vertrauensw&uuml;rdig' 'not trusted' }
        default  { Badge 'b-neut' (Esc $dtClass) (Esc $dtClass) }
    }
    $ownerBadge2 = switch ($dtOwner) {
        'policy'  { Badge 'b-ok'   'Zertifikat: Intune-Policy' 'certificate: Intune policy' }
        'package' { Badge 'b-warn' 'Zertifikat: Paket-Import'  'certificate: package import' }
        'none'    { Badge 'b-neut' 'kein Zertifikat n&ouml;tig' 'no certificate needed' }
        default   { '' }
    }
    $vDrivers = $classBadge + ' ' + $ownerBadge2
    if ($dtThumb) { $vDrivers += (NoteHtml "Signer-Thumbprint $(Esc $dtThumb)" "signer thumbprint $(Esc $dtThumb)") }
    if ($dtSbOff) {
        $vDrivers += (NoteHtml 'Secure Boot als deaktiviert angenommen - Flottenentscheidung, im Manifest dokumentiert' 'Secure Boot assumed off - a fleet decision, recorded in the manifest')
    }
    if ($dtList.Count) {
        $rows = foreach ($d in $dtList) {
            $dGet = { param($k) if ($d -is [hashtable]) { $d[$k] } elseif ($d.PSObject -and $d.PSObject.Properties[$k]) { $d.$k } else { $null } }
            $mode = if ([bool](& $dGet 'kernelMode')) { 'kernel' } else { 'user' }
            '<br>' + (Codei ([string](& $dGet 'inf'))) + ' &middot; ' + (Esc ([string](& $dGet 'classification'))) +
                ' &middot; ' + $mode + ' &middot; ' + (Esc ([string](& $dGet 'version')))
        }
        $vDrivers += ($rows -join '')
    }
}

# One row when there is nothing to say twice (0.49.4): "driver certificate: none" and "driver trust: no
# drivers" were two rows stating one fact. A package with drivers or a certificate policy keeps both.
if (-not $cp -and -not $dt) {
    $driverRows = "          <tr><td class=`"k`" data-de=`"Treiber`" data-en=`"Drivers`">Treiber</td><td>" +
        (Badge 'b-neut' 'keine Treiber' 'no drivers') +
        (NoteHtml 'das Paket liefert keine Treiber aus, kein Zertifikat erforderlich' 'this package ships no drivers, no certificate required') + '</td></tr>'
} else {
    $driverRows = "          <tr><td class=`"k`" data-de=`"Treiber-Zertifikat`" data-en=`"Driver certificate`">Treiber-Zertifikat</td><td>$vCertPolicy</td></tr>`r`n" +
        "          <tr><td class=`"k`" data-de=`"Treiber-Vertrauen`" data-en=`"Driver trust`">Treiber-Vertrauen</td><td>$vDrivers</td></tr>"
}

# The portal's own wording, per language (0.49.4) - "Custom Detection Script" showed in the German view.
$ruleFormat = Get-Val 'RuleFormat' $null
$vRuleFormat = if ($ruleFormat) { Esc $ruleFormat } else { Bspan 'Benutzerdefiniertes Erkennungsskript' 'Custom detection script' }
$detectScript  = Get-Val 'DetectScript' ''
$vDetectScript = if ($detectScript) { Codei $detectScript } else { Bspan 'n. z.' 'n/a' }
$runAs32 = [bool](Get-Val 'RunAs32' $false)
$vRun32 = if ($runAs32) { Bspan 'Ja' 'Yes' } else { Bspan 'Nein' 'No' }
$sigCheck = [bool](Get-Val 'SignatureCheck' $false)
$vSigCheck = if ($sigCheck) { Bspan 'Ja' 'Yes' } else { Bspan 'Nein' 'No' }

# ----------------------------------------------------------------------------- deps / supersedence
$deps = Get-Val 'Dependencies' $null
$vDeps = if ([string]::IsNullOrWhiteSpace([string]$deps)) {
    (Badge 'b-neut' 'keine' 'none') + (NoteHtml (Get-Val 'DependenciesNoteDe' '') (Get-Val 'DependenciesNoteEn' ''))
} else { Esc $deps }
$sup = Get-Val 'Supersedence' $null
$vSup = if ([string]::IsNullOrWhiteSpace([string]$sup)) {
    (Badge 'b-neut' 'keine' 'none') +
    (NoteHtml (Get-Val 'SupersedenceNoteDe' 'erste Version &ndash; neue Versionen koexistieren sp&auml;ter (kein L&ouml;schen)') (Get-Val 'SupersedenceNoteEn' 'first version &ndash; new versions coexist later (no deletion)'))
} else {
    # The note travels with the VALUE, not only with its absence. Rendering it only in the empty branch
    # meant a populated supersedence printed a bare GUID: the reader could not tell whether the previous
    # version gets uninstalled, which is the entire decision the field exists to record.
    (Esc $sup) + (NoteHtml (Get-Val 'SupersedenceNoteDe' '') (Get-Val 'SupersedenceNoteEn' ''))
}

# ----------------------------------------------------------------------------- logo / intunewin
$vLogoSource     = Bspan (Esc $logoSource) (Esc $logoSource)
$vLogoResolution = Get-Val 'LogoResolution' ''
# Measured, not asked for (0.49.4): a PNG states its size and whether it carries an alpha channel in its
# IHDR chunk, so "not checked" was never necessary. The guideline is App. J: >= 512 px, transparent.
$png = Get-PngFacts $LogoPath
$vLogoResolution = if ($vLogoResolution) { (Esc $vLogoResolution) + ' ' + (Badge 'b-ok' 'verifiziert' 'verified') }
elseif ($png) {
    $alphaDe = if ($png.Alpha) { 'mit Alphakanal' } else { 'ohne Alphakanal' }
    $alphaEn = if ($png.Alpha) { 'with alpha channel' } else { 'no alpha channel' }
    $meets = $png.Width -ge 512 -and $png.Height -ge 512 -and $png.Alpha
    (Bspan "$($png.Width) &times; $($png.Height) px, $alphaDe" "$($png.Width) &times; $($png.Height) px, $alphaEn") + ' ' +
    $(if ($meets) { Badge 'b-ok' 'erf&uuml;llt die Vorgabe' 'meets the guideline' } else { Badge 'b-warn' 'unter der Vorgabe (&ge; 512 px, transparent)' 'below the guideline (&ge; 512 px, transparent)' })
}
else { (Bspan 'nicht gepr&uuml;ft' 'not checked') }
$vLogoGuard = if ($logoGuardOk) {
    (Badge 'b-ok' 'kein PSADT-AppIcon.png' 'no PSADT AppIcon.png') + (NoteHtml 'SHA256-Blocklist bestanden' 'SHA256 blocklist passed')
} else { Badge 'b-fail' 'PSADT-Default!' 'PSADT default!' }
$vIntunewin = $iw = Get-Val 'IntuneWin' ''
$vIntunewin = if ($iw) { Codei $iw } else { Bspan 'noch nicht gepackt' 'not packed yet' }
$vSetupFile = (Codei (Get-Val 'SetupFile' 'Invoke-AppDeployToolkit.exe')) + ' ' + (Badge 'b-ok' 'korrekt' 'correct')
$vLocation = $loc = Get-Val 'Location' ''
$vLocation = if ($loc) { Codei $loc } else { Bspan 'Output-Ordner der App' 'app output folder' }

# The upload, once there was one (0.49.4): which Intune app this file became, and the hash of what went up.
$uploadRows = @()
$pkgSha = Get-Val 'PackageSha256' ''
if ($pkgSha) { $uploadRows += "          <tr><td class=`"k`">SHA256</td><td>$(Codei $pkgSha)</td></tr>" }
$upId = Get-Val 'UploadAppId' ''
if ($upId) {
    $upCell = Codei $upId
    $upPortal = Get-Val 'UploadPortal' ''
    if ($upPortal -match '^https://') {
        $upCell += " <a href=`"$(Esc $upPortal)`" target=`"_blank`" rel=`"noopener`" data-de=`"im Intune Admin Center &ouml;ffnen`" data-en=`"open in the Intune admin center`">im Intune Admin Center &ouml;ffnen</a>"
    }
    $upAt = Get-Val 'UploadAt' ''
    if ($upAt) { $upCell += NoteHtml "hochgeladen am $(Esc $upAt)" "uploaded on $(Esc $upAt)" }
    $uploadRows += "          <tr><td class=`"k`" data-de=`"Intune-App-ID`" data-en=`"Intune app ID`">Intune-App-ID</td><td>$upCell</td></tr>"
}
$uploadRowsHtml = $uploadRows -join "`r`n"

# ----------------------------------------------------------------------------- description markdown
# No invented prose. "_Beschreibung folgt._" read like a finished field, survived review and shipped
# to Company Portal; this marker cannot be mistaken for content. The guard above refuses outright when
# an upload is planned.
# Real umlauts via [char] - the Markdown source is escaped text, so an HTML entity would print literally,
# and this file stays 7-bit ASCII.
$ae = [char]0xE4; $ue = [char]0xFC
$descMdDe = Esc (Get-Val 'DescMdDe' "**$appName $appVersion**`n`n> **KEINE BESCHREIBUNG HINTERLEGT.** Dieses Feld wird unver$($ae)ndert ins Company Portal $($ue)bernommen und muss vor dem Upload gef$($ue)llt werden (New-PsadtReport.ps1 -Metadata @{ DescMdDe = '...' }).")
$descMdEn = Esc (Get-Val 'DescMdEn' "**$appName $appVersion**`n`n> **NO DESCRIPTION SUPPLIED.** This field is copied to Company Portal verbatim and must be filled before upload (New-PsadtReport.ps1 -Metadata @{ DescMdEn = '...' }).")

# ----------------------------------------------------------------------------- return codes
# One source of truth, shared with Invoke-IntuneWin32Upload.ps1 - see Get-PsadtReturnCodes.ps1. Two
# hand-maintained literals that happen to agree are drift waiting to happen, and a dossier promising a
# mapping the uploaded app does not carry is worse than no dossier at all.
#
# NOTE the semantics: -Metadata ReturnCodes MERGES OVER the mandatory Appendix F.4 table, it does not
# replace it. A package that fails to map 60001/60008 to Failed reports its own crashes as success, so
# dropping those rows is not an option a caller gets to take. An invalid type throws there, by design.
$rcCustom = @(Get-Val 'ReturnCodes' @())
$rc = @(& (Join-Path $PSScriptRoot 'Get-PsadtReturnCodes.ps1') -Custom $rcCustom)
$rcRows = @(foreach ($r in $rc) {
    # $r.Cls is interpolated raw and that is SAFE here, but only because Get-PsadtReturnCodes derives it
    # from a closed switch. Do NOT "restore" it to a metadata field - it lands inside a class attribute.
    #
    # data-de/data-en sit on an inner <span>, never on the <td>: setLang() in the template assigns
    # el.textContent to every [data-de] element, which deletes that element's children. With the
    # attributes on the cell, the injected copy button would vanish on the first DE/EN toggle - a failure
    # that shows up on click, not on load, and therefore survives a screenshot review.
    # The Graph token (softReboot) rides along as a data attribute instead of being printed next to the
    # portal label (Soft reboot). Shown side by side it reads as a duplicated word rather than as two
    # audiences, but "copy table" still needs the API spelling - so it is carried, not displayed.
    "            <tr data-rc-type=`"$(Esc $r.Type)`"><td><code>$(Esc $r.Code)</code></td>" +
    "<td><span class=`"badge $($r.Cls)`" data-de=`"$(Esc $r.LabelDe)`" data-en=`"$(Esc $r.LabelEn)`">$(Esc $r.LabelDe)</span></td>" +
    "<td><span data-de=`"$(AttrHtml $r.De)`" data-en=`"$(AttrHtml $r.En)`">$($r.De)</span></td></tr>"
}) -join "`n"

# ----------------------------------------------------------------------------- assignments
$asg = Get-Val 'Assignments' @()
# What the section says it is (0.49.3): assignments Phase 10 set and read back are facts, not a suggestion.
if ($asgRecorded) {
    $asgAt = Format-IsoDay $asgRecorded.at
    $asgTagDe = "Gesetzt &middot; aus Intune zur&uuml;ckgelesen $asgAt"
    $asgTagEn = "Set &middot; read back from Intune $asgAt"
    $asgNoteDe = "Diese Zuweisungen sind der Stand in Intune am $asgAt, kein Vorschlag. Kategorie und Hervorhebung im Company Portal legt die Organisation bewusst selbst fest."
    $asgNoteEn = "These assignments are what Intune held on $asgAt, not a suggestion. Category and the Company Portal highlight are left to the organisation on purpose."
} else {
    $asgTagDe = 'Vorschlag &middot; Anwender entscheidet'
    $asgTagEn = 'Suggestion &middot; user decides'
    $asgNoteDe = 'Zuweisung, Kategorie und Featured-Flag sind bewusste menschliche Entscheidungen &ndash; der Report schl&auml;gt nur vor, setzt nichts automatisch.'
    $asgNoteEn = 'Assignment, category and the featured flag are deliberate human decisions &ndash; the report only suggests, it sets nothing automatically.'
}
if ($asg.Count -eq 0) {
    $asgRows = "            <tr><td colspan=`"3`"><span data-de=`"noch nicht zugewiesen &ndash; bewusste Entscheidung im Admin Center`" data-en=`"not yet assigned &ndash; a deliberate decision in the Admin Center`">noch nicht zugewiesen</span></td></tr>"
} else {
    # The recorded values stay the portal's English tokens; the reader gets them in the page language
    # (0.49.4), and the group by name with its id as a detail - three GUIDs told an approver nothing.
    $asgTypeDe = @{ Available = 'Verf&uuml;gbar'; Required = 'Erforderlich'; Uninstall = 'Deinstallieren' }
    $asgAvailDe = @{ 'As soon as possible' = 'So bald wie m&ouml;glich' }
    $asgRows = @(foreach ($a in $asg) {
        $tcls = switch ($a.Type) { 'Required' { 'b-info' } 'Uninstall' { 'b-fail' } default { 'b-neut' } }
        $grpCell = Esc $a.Group
        if ($a.GroupId -and [string]$a.GroupId -ne [string]$a.Group) { $grpCell += ' ' + (NoteHtml (Codei $a.GroupId)) }
        $tDe = if ($asgTypeDe.ContainsKey([string]$a.Type)) { $asgTypeDe[[string]$a.Type] } else { Esc $a.Type }
        $avDe = if ($asgAvailDe.ContainsKey([string]$a.Availability)) { $asgAvailDe[[string]$a.Availability] } else { Esc $a.Availability }
        "            <tr><td>$grpCell</td><td>$(Badge $tcls $tDe (Esc $a.Type))</td><td>$(Bspan $avDe (Esc $a.Availability))</td></tr>"
    }) -join "`n"
}

# ----------------------------------------------------------------------------- hooks
function Format-HookItems {
    param($Items)
    if (-not $Items -or $Items.Count -eq 0) { return '' }
    @(foreach ($it in $Items) {
        $kind = $null
        if ($it -isnot [string] -and $it -isnot [hashtable] -and $it.PSObject -and $it.PSObject.Properties['Kind']) { $kind = [string]$it.Kind }
        if ($kind -eq 'comment') {
            # A '##' comment from the launcher, which is English by convention (0.49.4): quoted and labelled
            # as one, so the German view does not read as if it had slipped into English mid-sentence.
            "              <li class=`"cmt`"><span class=`"qlabel`" data-de=`"Kommentar im Skript (EN)`" data-en=`"Script comment`">Kommentar im Skript (EN)</span> <q>$(Esc $it.Text)</q></li>"
            continue
        }
        if ($kind -eq 'helper') {
            "              <li><code>$(Esc $it.Text)</code><span class=`"htag`" data-de=`"Paket-Helfer`" data-en=`"package helper`">Paket-Helfer</span></li>"
            continue
        }
        if ($kind -eq 'cmd') { "              <li><code>$(Esc $it.Text)</code></li>"; continue }
        $de = $null; $en = $null
        if ($it -is [hashtable] -and $it.ContainsKey('De')) { $de = $it['De']; $en = $it['En'] }
        elseif ($it -isnot [string] -and $it.PSObject -and $it.PSObject.Properties['De']) { $de = $it.De; $en = $it.En }
        if ($de) { "              <li data-de=`"$(AttrHtml $de)`" data-en=`"$(AttrHtml $en)`">$de</li>" }
        else { "              <li>$(Esc ([string]$it))</li>" }
    }) -join "`n"
}
# The hooks and the cmdlet list describe THIS package, so they are read out of THIS package. The
# defaults here used to be a generic MSI package's contents - "Start-ADTMsiProcess", "user data is
# preserved" - printed as fact for whatever was being reported on. A WinMerge package driven by
# Start-ADTProcess with Inno switches was described as calling Start-ADTMsiProcess four times.
# Nothing in the document said the list was a guess. The launcher is parsed once, in the manifest block.

# PSADT's own template comments describe the template, not this package, and "<Perform ... here>" is a
# placeholder (0.49.4): both were printed as if they were the package's rationale - "allow up to 3
# deferrals" on a package that runs Silent. The list comes from the installed module's v4 template when
# there is one, so a new PSADT release needs no new skill release; the built-in lines are the floor.
$stockHookComments = New-Object System.Collections.Generic.HashSet[string]
foreach ($c in @(
        'Show Welcome Message, close processes if specified, allow up to 3 deferrals, verify there is enough disk space to complete the install, and persist the prompt.'
        'Show Progress Message (with the default message).'
        'If there are processes to close, show Welcome Message with a 60 second countdown before automatically closing.'
        'Handle Zero-Config MSI installations.'
        'Handle Zero-Config MSI uninstallations.'
        'Handle Zero-Config MSI repairs.'
        'Display a message at the end of the install.')) { [void]$stockHookComments.Add($c) }
try {
    $tplFile = if ($psadtModuleInfo) { Join-Path $psadtModuleInfo.ModuleBase 'Frontend\v4\Invoke-AppDeployToolkit.ps1' } else { $null }
    if ($tplFile -and (Test-Path -LiteralPath $tplFile)) {
        $tplTokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($tplFile, [ref]$tplTokens, [ref]$null)
        foreach ($tk in @($tplTokens | Where-Object { $_.Kind -eq 'Comment' -and $_.Text -match '^##\s' })) {
            [void]$stockHookComments.Add(($tk.Text -replace '^##\s*', '').Trim())
        }
    }
} catch { Write-Verbose "PSADT template comments not readable: $($_.Exception.Message)" }

# The package's own helpers (0.49.4). The core step of a hook is often one - Install-WindowsAppProvisioning
# provisions the whole app - and a filter that knew only *-ADT* names left that step out of the hook.
$extHelpers = @{}
if ($launcherFile) {
    foreach ($psm in @(Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $launcherFile) 'PSAppDeployToolkit.Extensions') -Filter '*.psm1' -File -ErrorAction SilentlyContinue)) {
        $extAst = [System.Management.Automation.Language.Parser]::ParseFile($psm.FullName, [ref]$null, [ref]$null)
        foreach ($fd in $extAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $extHelpers[$fd.Name] = $true }
    }
}

function Get-HookItems {
    # The hook as a reader needs it: the '##' rationale comments the launcher carries AND the commands it
    # runs, in source order. Commands alone said "Uninstall-ADTApplication" on Chrome 154 and nothing about
    # WHY it replaced a ProductCode call - that had to be retyped into -Metadata by hand (0.44.0).
    # MARK banners, separator lines, PSADT's template comments and placeholders are skipped.
    param($Ast, $Tokens, [string]$FunctionName)
    if (-not $Ast) { return $null }
    $fn = $Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName }, $true) |
        Select-Object -First 1
    if (-not $fn) { return $null }
    $items = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($c in $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        if (-not $name -or $seen.ContainsKey($name)) { continue }
        $kind = if ($name -match '^[A-Za-z]+-(ADT|Psadt)') { 'cmd' } elseif ($extHelpers.ContainsKey($name)) { 'helper' } else { $null }
        if (-not $kind) { continue }
        $seen[$name] = $true
        $items.Add([pscustomobject]@{ Offset = $c.Extent.StartOffset; Line = $c.Extent.StartLineNumber; Text = $name; Kind = $kind })
    }
    $last = $null
    foreach ($t in @($Tokens | Where-Object {
                $_.Kind -eq 'Comment' -and $_.Extent.StartOffset -gt $fn.Extent.StartOffset -and $_.Extent.EndOffset -lt $fn.Extent.EndOffset })) {
        $txt = $t.Text.Trim()
        if ($txt -notmatch '^##\s' -or $txt -match '^##\s*(=|MARK:)') { $last = $null; continue }
        $txt = ($txt -replace '^##\s*', '').Trim()
        if ($stockHookComments.Contains($txt) -or $txt -match '^<Perform .+ here>$') { $last = $null; continue }
        # Consecutive '##' lines are one sentence wrapped at the column limit.
        if ($last -and $t.Extent.StartLineNumber -eq $last.Line + 1) { $last.Text = "$($last.Text) $txt"; $last.Line = $t.Extent.StartLineNumber; continue }
        $last = [pscustomobject]@{ Offset = $t.Extent.StartOffset; Line = $t.Extent.StartLineNumber; Text = $txt; Kind = 'comment' }
        $items.Add($last)
    }
    return @($items | Sort-Object Offset)
}

function Get-HookCommands {
    # ADT commands actually invoked inside one *-ADTDeployment function, in source order, deduplicated.
    param($Ast, [string]$FunctionName)
    if (-not $Ast) { return $null }
    $fn = $Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName }, $true) |
        Select-Object -First 1
    if (-not $fn) { return $null }
    $names = $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } |
        Where-Object { $_ -and $_ -match '^[A-Za-z]+-(ADT|Psadt)' }
    return @($names | Select-Object -Unique)
}

$hookInstallCmds   = Get-HookCommands $launcherAst 'Install-ADTDeployment'
$hookUninstallCmds = Get-HookCommands $launcherAst 'Uninstall-ADTDeployment'
$hookRepairCmds    = Get-HookCommands $launcherAst 'Repair-ADTDeployment'

$notDerived = @(@{ De = '&ndash; nicht ermittelbar (kein Launcher gefunden), nicht &uuml;bergeben'; En = '&ndash; not derivable (no launcher found), not supplied' })

$hookInstallItems   = Get-HookItems $launcherAst $launcherTokens 'Install-ADTDeployment'
$hookUninstallItems = Get-HookItems $launcherAst $launcherTokens 'Uninstall-ADTDeployment'
$hookRepairItems    = Get-HookItems $launcherAst $launcherTokens 'Repair-ADTDeployment'

$hookInstall   = Format-HookItems (Get-Val 'HookInstall'   $(if ($hookInstallItems)   { $hookInstallItems }   else { $notDerived }))
$hookUninstall = Format-HookItems (Get-Val 'HookUninstall' $(if ($hookUninstallItems) { $hookUninstallItems } else { $notDerived }))
$hookRepair    = Format-HookItems (Get-Val 'HookRepair'    $(if ($hookRepairItems)    { $hookRepairItems }    else { $notDerived }))

# ----------------------------------------------------------------------------- cmdlets
$derivedCmds = @($hookInstallCmds + $hookUninstallCmds + $hookRepairCmds | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
$cmds = Get-Val 'Cmdlets' $(if ($derivedCmds) { $derivedCmds } else { @('nicht ermittelbar / not derivable') })
$cmdChips = @(foreach ($c in $cmds) { "          <span class=`"chip`">$(Esc $c)</span>" }) -join "`n"

# ----------------------------------------------------------------------------- pre-flight
# Default = NOT RUN (neutral). Real results arrive via -Metadata Preflight; without them the report must
# NOT show a synthetic PASS (honest reporting - green-by-default would hide checks that never ran).
$defaultPf = @(
    @{ Title = 'Pre-flight'; Cls = 'neutral'; De = 'keine Ergebnisse &uuml;bergeben &middot; nicht ausgef&uuml;hrt'; En = 'no results supplied &middot; not run'; BDe = 'nicht ausgef&uuml;hrt'; BEn = 'not run' }
)
# The recorded verdict (Invoke-PsadtPreflight.ps1 writes results.preflight.checks since 0.44.0). Before
# that, a package whose pre-flight was GREEN in the manifest still rendered "not run" here - Chrome 154.
# Check names in the reader's language (0.49.4); the finding itself is the tool's output and is shown as
# that - as code, the same in both views - instead of an English sentence in the German view.
$pfNames = @{
    'Encoding'       = @('Zeichenkodierung', 'Encoding')
    'Parse'          = @('Syntax', 'Syntax')
    'v3-cmdlets'     = @('Keine v3-Cmdlets', 'No v3 cmdlets')
    'Structure'      = @('Struktur', 'Structure')
    'ProductCode'    = @('ProductCode-&Uuml;bergabe', 'ProductCode usage')
    'AsyncUninstall' = @('Deinstallation gepr&uuml;ft', 'Uninstall verified')
    'TopLevel'       = @('Kein Code au&szlig;erhalb von try/catch', 'No top-level code')
    'Detection'      = @('Erkennungsskript', 'Detection script')
    'Manifest'       = @('Paket-Manifest', 'Package manifest')
    'LogName'        = @('Log je Lauf', 'Per-run log')
    'DriverTrust'    = @('Treiber-Vertrauen', 'Driver trust')
    'Research'       = @('Recherche', 'Research')
    'SupportFiles'   = @('SupportFiles', 'SupportFiles')
    'SwitchSync'     = @('Schalter-Abgleich', 'Switch sync')
}
if ($ManifestPath -and $mf -and $mf.results.preflight -and $mf.results.preflight.checks) {
    $defaultPf = @(foreach ($pc in @($mf.results.preflight.checks)) {
        $cls = switch ([string]$pc.Status) { 'PASS' { 'ok' } 'WARN' { 'warn' } default { 'fail' } }
        $bde = switch ($cls) { 'ok' { 'bestanden' } 'warn' { 'Hinweis' } default { 'fehlgeschlagen' } }
        $ben = switch ($cls) { 'ok' { 'passed' } 'warn' { 'warning' } default { 'failed' } }
        $nm = [string]$pc.Name
        $pair = if ($pfNames.ContainsKey($nm)) { $pfNames[$nm] } else { @((Esc $nm), (Esc $nm)) }
        $file = if ($pc.File) { ' &middot; ' + (Esc ([string]$pc.File)) } else { '' }
        @{ Title = $nm; TitleDe = $pair[0] + $file; TitleEn = $pair[1] + $file; Cls = $cls; Raw = [string]$pc.Detail; BDe = $bde; BEn = $ben }
    })
}
$pf = Get-Val 'Preflight' $defaultPf
function Format-PfCheck {
    param($c)
    $sym = switch ($c.Cls) { 'ok' { '&#10003;' } 'warn' { '!' } 'neutral' { '&ndash;' } default { '&times;' } }
    $bcls = switch ($c.Cls) { 'ok' { 'b-ok' } 'warn' { 'b-warn' } 'neutral' { 'b-neut' } default { 'b-fail' } }
    $title = if ($c.TitleDe) { "<div class=`"ct`" data-de=`"$(AttrHtml $c.TitleDe)`" data-en=`"$(AttrHtml $c.TitleEn)`">$($c.TitleDe)</div>" } else { "<div class=`"ct`">$(Esc $c.Title)</div>" }
    $detail = if ($null -ne $c.Raw) { "<div class=`"cd`"><code>$(Esc $c.Raw)</code></div>" } else { "<div class=`"cd`" data-de=`"$(AttrHtml $c.De)`" data-en=`"$(AttrHtml $c.En)`">$($c.De)</div>" }
    "          <div class=`"check`"><span class=`"ci $($c.Cls)`">$sym</span><div>$title$detail</div><span class=`"badge $bcls`" data-de=`"$(AttrHtml $c.BDe)`" data-en=`"$(AttrHtml $c.BEn)`">$($c.BDe)</span></div>"
}
# Eighteen near-identical "passed" rows buried the one that mattered (0.49.4): the roll-up says how many
# passed, warnings and failures stay open, and the passed checks fold away.
$pfPass = @($pf | Where-Object { $_.Cls -eq 'ok' })
$pfOpen = @($pf | Where-Object { $_.Cls -ne 'ok' })
if ($pfPass.Count -and @($pf).Count -gt 1) {
    $nAll = @($pf).Count
    $nWarn = @($pf | Where-Object { $_.Cls -eq 'warn' }).Count
    $nFail = @($pf | Where-Object { $_.Cls -notin @('ok', 'warn', 'neutral') }).Count
    $sumDe = "$($pfPass.Count) von $nAll Pr&uuml;fungen bestanden" + $(if ($nWarn) { " &middot; $nWarn $(if ($nWarn -eq 1) { 'Hinweis' } else { 'Hinweise' })" }) + $(if ($nFail) { " &middot; $nFail fehlgeschlagen" })
    $sumEn = "$($pfPass.Count) of $nAll checks passed" + $(if ($nWarn) { " &middot; $nWarn $(if ($nWarn -eq 1) { 'warning' } else { 'warnings' })" }) + $(if ($nFail) { " &middot; $nFail failed" })
    $pfParts = @("          <div class=`"pf-sum`" data-de=`"$(AttrHtml $sumDe)`" data-en=`"$(AttrHtml $sumEn)`">$sumDe</div>")
    $pfParts += @($pfOpen | ForEach-Object { Format-PfCheck $_ })
    $pfParts += "          <details class=`"pf-fold`"><summary data-de=`"Bestandene Pr&uuml;fungen anzeigen ($($pfPass.Count))`" data-en=`"Show passed checks ($($pfPass.Count))`">Bestandene Pr&uuml;fungen anzeigen ($($pfPass.Count))</summary>"
    $pfParts += @($pfPass | ForEach-Object { Format-PfCheck $_ })
    $pfParts += '          </details>'
    $pfChecks = $pfParts -join "`n"
} else {
    $pfChecks = @(foreach ($c in $pf) { Format-PfCheck $c }) -join "`n"
}
# KPI band status: a compact roll-up of the pre-flight result for the header KPI band.
# fail (any non-ok/warn/neutral Cls) -> ROT; all neutral -> not run; any warn -> GELB; else GRUEN.
$pfClsList = @($pf | ForEach-Object { $_.Cls })
$pfHasFail = @($pfClsList | Where-Object { $_ -notin @('ok', 'warn', 'neutral') }).Count -gt 0
$pfAllNeut = ($pfClsList.Count -gt 0) -and (@($pfClsList | Where-Object { $_ -ne 'neutral' }).Count -eq 0)
if     ($pfHasFail) { $kpiStatusDe = 'ROT';               $kpiStatusEn = 'RED';     $kpiStatusCls = 'fail' }
elseif ($pfAllNeut) { $kpiStatusDe = 'nicht ausgef&uuml;hrt'; $kpiStatusEn = 'not run'; $kpiStatusCls = 'neutral' }
elseif ($pfClsList -contains 'warn') { $kpiStatusDe = 'GELB'; $kpiStatusEn = 'AMBER'; $kpiStatusCls = 'warn' }
else                { $kpiStatusDe = 'GR&Uuml;N';          $kpiStatusEn = 'GREEN';   $kpiStatusCls = 'ok' }

# ----------------------------------------------------------------------------- system test
# Default = NOT RUN (neutral) - same honesty rule as pre-flight: no synthetic "Success" rows.
$defaultSt = @(
    @{ StepDe = 'SYSTEM-Test'; StepEn = 'SYSTEM test'; Exit = '-'; Detection = '&ndash;'; Cls = 'b-neut'; Result = 'not run'; ResultDe = 'nicht ausgef&uuml;hrt'; ResultEn = 'not run' }
)
$st = Get-Val 'SystemTest' $defaultSt
$legacyResult = @{ 'pass' = @('bestanden', 'passed'); 'fail' = @('fehlgeschlagen', 'failed'); 'not run' = @('nicht ausgef&uuml;hrt', 'not run') }
$stRows = @(foreach ($s in $st) {
    # Rows built from result.json carry DetectionDe/DetectionEn; a caller-supplied row keeps its single cell.
    $detCell = if ($s.DetectionDe) { "<td data-de=`"$(AttrHtml $s.DetectionDe)`" data-en=`"$(AttrHtml $s.DetectionEn)`">$($s.DetectionDe)</td>" } else { "<td>$($s.Detection)</td>" }
    # One result per language (0.49.4) - the German view printed "pass" under "Ergebnis". A caller row that
    # still says pass / fail / not run gets the same two words; anything else is shown as given.
    $resDe = $s.ResultDe; $resEn = $s.ResultEn
    if (-not $resDe -and $legacyResult.ContainsKey([string]$s.Result)) { $resDe = $legacyResult[[string]$s.Result][0]; $resEn = $legacyResult[[string]$s.Result][1] }
    $resCell = if ($resDe) { "<span class=`"badge $($s.Cls)`" data-de=`"$(AttrHtml $resDe)`" data-en=`"$(AttrHtml $resEn)`">$resDe</span>" } else { "<span class=`"badge $($s.Cls)`">$(Esc $s.Result)</span>" }
    "            <tr><td data-de=`"$(AttrHtml $s.StepDe)`" data-en=`"$(AttrHtml $s.StepEn)`">$($s.StepDe)</td><td><code>$(Esc $s.Exit)</code></td>$detCell<td>$resCell</td></tr>"
}) -join "`n"
$stNoteDe = Get-Val 'SystemTestNoteDe' 'Keine SYSTEM-Test-Ergebnisse &uuml;bergeben &ndash; der SYSTEM-Test wurde nicht ausgef&uuml;hrt (kein Beleg).'
$stNoteEn = Get-Val 'SystemTestNoteEn' 'No SYSTEM-test results supplied &ndash; the SYSTEM test was not run (no evidence).'

# The upload gate, as the upload itself will judge it (0.49.3) - only for a package meant to be uploaded.
# Plain text with entities, no tags: the language switch sets textContent, so a tag would show as text.
$gateOpen = $false
if ($uploadGate -and -not $uploadGate.Passed) {
    $gateOpen = $true
    $rerunDe = 'pwsh scripts/Invoke-PsadtSandboxTest.ps1 -PackagePath &lt;pkg&gt;'
    $gateDe = switch ([string]$uploadGate.Code) {
        'not-green'          { "Das Sandbox-Verdikt ist $(Esc ([string]$mf.results.sandboxTest.verdict)), kein voller GREEN-Lauf aller f&uuml;nf Szenarien. Neu starten: $rerunDe (der volle Test ist der Standard)." }
        'changed-during-run' { "Das Paket wurde w&auml;hrend des Sandbox-Laufs ge&auml;ndert; das Verdikt beschreibt Dateien, die es so nicht mehr gibt. Neu starten: $rerunDe." }
        'dev-vm-incomplete'  { 'DEV-VM-Route: Install und Uninstall m&uuml;ssen beide als SYSTEM bestanden haben (Invoke-PsadtSystemTest.ps1).' }
        default              { "Noch kein SYSTEM-Test im Manifest. Starten: $rerunDe." }
    }
    $stNoteDe = "Upload gesperrt &ndash; der Upload verweigert -Execute, bis das Gate erf&uuml;llt ist. $gateDe $stNoteDe"
    $stNoteEn = "Upload blocked &ndash; the upload refuses -Execute until the gate is met: $(Esc ([string]$uploadGate.Reason)). $stNoteEn"
}

# Whether each hook's action was exercised, from the rows above (0.49.4). The template printed "tested"
# under every hook of every package, whether a SYSTEM test had run or not.
function Get-RowAction {
    param($Row)
    $a = if ($Row.Action) { [string]$Row.Action } else { ([string]$Row.StepEn -split '[\s(]')[0] }
    switch ($a) { 'Install' { 'Install' } 'Reinstall' { 'Install' } 'Uninstall' { 'Uninstall' } 'FinalUninstall' { 'Uninstall' } 'Repair' { 'Repair' } default { $null } }
}
$hookBadge = @{}
foreach ($h in 'Install', 'Uninstall', 'Repair') {
    $hr = @($st | Where-Object { (Get-RowAction $_) -eq $h })
    $hookBadge[$h] = if (@($hr | Where-Object { $_.Cls -eq 'b-fail' }).Count) { Badge 'b-fail' 'fehlgeschlagen' 'failed' }
    elseif (@($hr | Where-Object { $_.Cls -eq 'b-ok' }).Count) { Badge 'b-ok' 'getestet' 'tested' }
    else { Badge 'b-neut' 'nicht getestet' 'not tested' }
}
# ----------------------------------------------------------------------------- header status
# Derived, never asserted. The rule the SYSTEM-test table and the pre-flight KPI already follow -
# "no synthetic Success rows" - applies with most force to the badge at the top of the page, because
# that is the line an approver reads before deciding to ship. An explicit StatusDe/StatusEn in
# -Metadata still wins; what is gone is the default that claimed "tested" with nothing behind it.
$stWasRun = @($st | Where-Object { [string]$_.Result -ne 'not run' }).Count -gt 0
$stFailed = @($st | Where-Object { $_.Cls -eq 'b-fail' }).Count -gt 0
if ($pfHasFail) {
    $statusDefaultDe = 'Nicht upload-bereit &middot; Pre-flight ROT'
    $statusDefaultEn = 'Not ready to upload &middot; pre-flight RED'
}
elseif ($stFailed) {
    $statusDefaultDe = 'Nicht upload-bereit &middot; SYSTEM-Test fehlgeschlagen'
    $statusDefaultEn = 'Not ready to upload &middot; SYSTEM test failed'
}
elseif (-not $stWasRun) {
    $statusDefaultDe = 'Nicht getestet &middot; kein SYSTEM-Test'
    $statusDefaultEn = 'Not tested &middot; no SYSTEM test'
}
elseif ($pfAllNeut) {
    $statusDefaultDe = 'Getestet &middot; Pre-flight nicht ausgef&uuml;hrt'
    $statusDefaultEn = 'Tested &middot; pre-flight not run'
}
else {
    $statusDefaultDe = 'Upload-bereit &middot; getestet'
    $statusDefaultEn = 'Ready to upload &middot; tested'
}
$statusDe = Get-Val 'StatusDe' $statusDefaultDe
$statusEn = Get-Val 'StatusEn' $statusDefaultEn

# ----------------------------------------------------------------------------- token map
$logoSrc = Get-LogoDataUri -Path $LogoPath -AppName $appName

$tokens = [ordered]@{
    'LANG'              = $lang
    'APP_NAME'          = (Esc $appName)
    'APP_VERSION'       = (Esc $appVersion)
    'PUBLISHER'         = (Esc $publisher)
    'PKG_REV'           = $(if ($pkgRev) { Esc $pkgRev } else { '&ndash;' })
    'SCRIPT_VERSION'    = $(if ($scriptVersion) { Esc $scriptVersion } else { '&ndash;' })
    'CREATED'           = (Esc $created)
    'AUTHOR'            = $(if ($author) { Esc $author } else { '&ndash;' })
    'MODULE_VERSION'    = (Esc $moduleVersion)
    'SUB_DE'            = (AttrHtml $subDe)
    'SUB_EN'            = (AttrHtml $subEn)
    'STATUS_DE'         = (AttrHtml $statusDe)
    'STATUS_EN'         = (AttrHtml $statusEn)
    'KPI_STATUS_DE'     = $kpiStatusDe
    'KPI_STATUS_EN'     = $kpiStatusEn
    'KPI_STATUS_CLS'    = $kpiStatusCls
    'LOGO_IMG_SRC'      = $logoSrc
    'V_DEVELOPER'       = (Esc $developer)
    'V_OWNER'           = $vOwner
    'V_CATEGORY'        = $vCategory
    'V_FEATURED'        = $vFeatured
    'V_INFO_URL'        = $vInfoUrl
    'V_PRIVACY_URL'     = $vPrivacyUrl
    'V_NOTES'           = $vNotes
    'DESC_MD_DE'        = $descMdDe
    'DESC_MD_EN'        = $descMdEn
    'V_INSTALL_CMD'     = $vInstallCmd
    'V_UNINSTALL_CMD'   = $vUninstallCmd
    'V_INSTALL_BEHAVIOR' = $vInstallBehavior
    'V_RESTART_BEHAVIOR' = $vRestart
    'V_INSTALL_TIME'    = $vInstallTime
    'V_ALLOW_UNINSTALL' = $vAllowUninstall
    'RETURN_CODE_ROWS'  = $rcRows
    'V_OS_ARCH'         = $vOsArch
    'V_MIN_OS'          = $vMinOs
    'V_DISK'            = $vDisk
    'V_MEMORY'          = $vMemory
    'DRIVER_ROWS'       = $driverRows
    'V_RULE_FORMAT'     = $vRuleFormat
    'V_DETECT_SCRIPT'   = $vDetectScript
    'V_RUN_32'          = $vRun32
    'V_SIG_CHECK'       = $vSigCheck
    'V_DEPENDENCIES'    = $vDeps
    'V_SUPERSEDENCE'    = $vSup
    'ASSIGNMENT_ROWS'   = $asgRows
    'ASSIGN_TAG_DE'     = (AttrHtml $asgTagDe)
    'ASSIGN_TAG_EN'     = (AttrHtml $asgTagEn)
    'ASSIGN_NOTE_DE'    = (AttrHtml $asgNoteDe)
    'ASSIGN_NOTE_EN'    = (AttrHtml $asgNoteEn)
    'HOOK_INSTALL_ITEMS' = $hookInstall
    'HOOK_UNINSTALL_ITEMS' = $hookUninstall
    'HOOK_REPAIR_ITEMS' = $hookRepair
    'HOOK_INSTALL_BADGE'   = $hookBadge['Install']
    'HOOK_UNINSTALL_BADGE' = $hookBadge['Uninstall']
    'HOOK_REPAIR_BADGE'    = $hookBadge['Repair']
    'CMDLET_CHIPS'      = $cmdChips
    'PREFLIGHT_CHECKS'  = $pfChecks
    'SYSTEMTEST_ROWS'   = $stRows
    'SYSTEMTEST_NOTE_DE' = (AttrHtml $stNoteDe)
    'SYSTEMTEST_NOTE_EN' = (AttrHtml $stNoteEn)
    'V_LOGO_SOURCE'     = $vLogoSource
    'V_LOGO_RESOLUTION' = $vLogoResolution
    'V_LOGO_GUARD'      = $vLogoGuard
    'V_INTUNEWIN'       = $vIntunewin
    'V_SETUPFILE'       = $vSetupFile
    'V_LOCATION'        = $vLocation
    'UPLOAD_ROWS'       = $uploadRowsHtml
}

# ----------------------------------------------------------------------------- render
$html = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
foreach ($k in $tokens.Keys) {
    $html = $html.Replace("{{$k}}", [string]$tokens[$k])
}

# any leftover tokens -> warn + blank (keeps the report clean if the template gains a token)
$leftover = [regex]::Matches($html, '\{\{[A-Z0-9_]+\}\}') | ForEach-Object { $_.Value } | Select-Object -Unique
if ($leftover) {
    Write-Warning "Unfilled template tokens blanked: $($leftover -join ', ')"
    $html = [regex]::Replace($html, '\{\{[A-Z0-9_]+\}\}', '')
}

$dir = Split-Path $OutputPath -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.UTF8Encoding]::new($false))

# The dossier is a deliverable, so the manifest has to carry it like every other artefact. Without this
# the file existed on disk and nothing downstream could assert it - which is why rule:dossier-always was
# a sentence rather than a check. Only when the caller came in through -ManifestPath: the explicit
# -Metadata route has no manifest to record into.
if ($ManifestPath) {
    try {
        & (Join-Path $PSScriptRoot 'Set-PsadtPackageManifest.ps1') -PackagePath (Split-Path -Parent (Resolve-Path -LiteralPath $ManifestPath).Path) -Updates @{
            'artifacts.dossier' = (Resolve-Path -LiteralPath $OutputPath).Path
            'results.report'    = @{
                verdict  = 'OK'
                at       = (Get-Date).ToString('o')
                template = (Split-Path -Leaf $TemplatePath)
                language = $lang
            }
        } | Out-Null
    }
    catch {
        # The dossier itself is written and valid; failing to record it must not fail the phase.
        Write-Warning "Dossier written, but recording it in the manifest failed: $($_.Exception.Message)"
    }
}

Write-Verbose "Report written: $OutputPath"
if ($PassThru) { Get-Item -LiteralPath $OutputPath }

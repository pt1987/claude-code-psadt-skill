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

# ----------------------------------------------------------------------------- manifest (0.21.0)
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
    # Installer-specific return codes researched in Phase 1.3. Recorded once in the manifest so the
    # dossier and Invoke-IntuneWin32Upload.ps1 cannot document different mappings.
    Set-FromManifest 'ReturnCodes'  $mf.research.returnCodes

    # The identity floor. Everything else - IntuneWin, Preflight, SystemTest - renders neutrally, because
    # "report ALWAYS" has to hold for a package that is not packed or tested yet. But a dossier that says
    # "App 0.0.0" is not an honest deliverable, it is a placeholder with a letterhead.
    $identityGaps = @('AppName', 'AppVersion', 'Publisher') |
        Where-Object { [string]::IsNullOrWhiteSpace([string]$Metadata[$_]) }
    if ($identityGaps.Count) {
        throw "The manifest identity is incomplete ($($identityGaps -join ', ')) - fill it with Set-PsadtPackageManifest.ps1, or pass the values via -Metadata. A dossier without a real app identity is a placeholder, not a deliverable."
    }

    # The SYSTEM test is BINDING only for a package that is going to be uploaded. That decision lives in
    # the manifest, so the gate can be enforced here instead of relying on the operator remembering it.
    if ($mf.decisions.upload -eq $true -and -not $Metadata.ContainsKey('SystemTest')) {
        throw "decisions.upload is true but no SYSTEM-test result was supplied. Run Invoke-PsadtSystemTest.ps1 (Install + Uninstall) first - Phase 6 is the binding gate for upload - or set decisions.upload to false."
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

# ----------------------------------------------------------------------------- scalar values
$lang          = Get-Val 'Lang' 'de'
$appName       = Get-Val 'AppName' 'App'
$appVersion    = Get-Val 'AppVersion' '0.0.0'
$publisher     = Get-Val 'Publisher' ''
$developer     = Get-Val 'Developer' $publisher
$owner         = Get-Val 'Owner' ''
$pkgRev        = Get-Val 'PkgRev' '01'
$scriptVersion = Get-Val 'ScriptVersion' '0.1'
$created       = Get-Val 'Created' (Get-Date -Format 'yyyy-MM-dd')
$author        = Get-Val 'Author' ''
# Default the PSADT version from the ACTUALLY INSTALLED module, not a literal that silently goes stale
# on the next PSADT update; '4.1.8' is only the last-resort fallback when the module isn't present.
$psadtInstalled = try {
    (Get-Module -ListAvailable PSAppDeployToolkit -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()
} catch { $null }
$psadtVersion  = Get-Val 'PsadtVersion' $(if ($psadtInstalled) { $psadtInstalled } else { '4.1.8' })
$moduleVersion = Get-Val 'ModuleVersion' $psadtVersion

$subDe   = Get-Val 'SubDe' "Intune Win32 &middot; PSADT v$psadtVersion Paket-Report"
$subEn   = Get-Val 'SubEn' "Intune Win32 &middot; PSADT v$psadtVersion package report"
$statusDe = Get-Val 'StatusDe' 'Upload-bereit &middot; getestet'
$statusEn = Get-Val 'StatusEn' 'Ready to upload &middot; tested'

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
$vNotes = Esc (Get-Val 'Notes' "PSADT v$psadtVersion - pkg rev $pkgRev - $created")

$logoLeaf = ''
if ($LogoPath) { $logoLeaf = Split-Path $LogoPath -Leaf }
$logoSource = Get-Val 'LogoSource' $logoLeaf
$logoGuardOk = [bool](Get-Val 'LogoGuardOk' $true)
$vLogo = (Badge 'b-ok' 'echtes App-Logo' 'real app logo') +
         (NoteHtml (Esc $logoSource) (Esc $logoSource))

# ----------------------------------------------------------------------------- program cells
$vInstallCmd   = Codei (Get-Val 'InstallCmd' 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent')
$vUninstallCmd = Codei (Get-Val 'UninstallCmd' 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent')
$vInstallBehavior = Badge 'b-ok' (Esc (Get-Val 'InstallBehavior' 'System')) (Esc (Get-Val 'InstallBehavior' 'System'))
$restartDe = Get-Val 'RestartBehaviorDe' 'Determine behavior based on return codes'
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
$vMinOs  = Esc (Get-Val 'MinOs' 'Windows 10 22H2')
$vDisk   = Esc (Get-Val 'DiskMb' '')
$vMemory = $m = Get-Val 'MemoryMb' ''
$vMemory = if ($m) { Esc $m } else { (Bspan 'nicht relevant' 'not relevant') }

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
        'RED'    { Badge 'b-fail' 'nicht vertrauenswuerdig' 'not trusted' }
        default  { Badge 'b-neut' (Esc $dtClass) (Esc $dtClass) }
    }
    $ownerBadge2 = switch ($dtOwner) {
        'policy'  { Badge 'b-ok'   'Zertifikat: Intune-Policy' 'certificate: Intune policy' }
        'package' { Badge 'b-warn' 'Zertifikat: Paket-Import'  'certificate: package import' }
        'none'    { Badge 'b-neut' 'kein Zertifikat noetig'    'no certificate needed' }
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

$vRuleFormat   = Esc (Get-Val 'RuleFormat' 'Custom Detection Script')
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
} else { Esc $sup }

# ----------------------------------------------------------------------------- logo / intunewin
$vLogoSource     = Bspan (Esc $logoSource) (Esc $logoSource)
$vLogoResolution = Get-Val 'LogoResolution' ''
$vLogoResolution = if ($vLogoResolution) { (Esc $vLogoResolution) + ' ' + (Badge 'b-ok' 'verifiziert' 'verified') } else { (Bspan 'nicht gepr&uuml;ft' 'not checked') }
$vLogoGuard = if ($logoGuardOk) {
    (Badge 'b-ok' 'kein PSADT-AppIcon.png' 'no PSADT AppIcon.png') + (NoteHtml 'SHA256-Blocklist bestanden' 'SHA256 blocklist passed')
} else { Badge 'b-fail' 'PSADT-Default!' 'PSADT default!' }
$vIntunewin = $iw = Get-Val 'IntuneWin' ''
$vIntunewin = if ($iw) { Codei $iw } else { Bspan 'noch nicht gepackt' 'not packed yet' }
$vSetupFile = (Codei (Get-Val 'SetupFile' 'Invoke-AppDeployToolkit.exe')) + ' ' + (Badge 'b-ok' 'korrekt' 'correct')
$vLocation = $loc = Get-Val 'Location' ''
$vLocation = if ($loc) { Codei $loc } else { Bspan 'Output-Ordner der App' 'app output folder' }

# ----------------------------------------------------------------------------- description markdown
$descMdDe = Esc (Get-Val 'DescMdDe' "**$appName $appVersion**`n`n_Beschreibung folgt._")
$descMdEn = Esc (Get-Val 'DescMdEn' "**$appName $appVersion**`n`n_Description to follow._")

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
    "<td><span class=`"badge $($r.Cls)`">$(Esc $r.Label)</span></td>" +
    "<td><span data-de=`"$(AttrHtml $r.De)`" data-en=`"$(AttrHtml $r.En)`">$($r.De)</span></td></tr>"
}) -join "`n"

# ----------------------------------------------------------------------------- assignments
$asg = Get-Val 'Assignments' @()
if ($asg.Count -eq 0) {
    $asgRows = "            <tr><td colspan=`"3`"><span data-de=`"noch nicht zugewiesen &ndash; bewusste Entscheidung im Admin Center`" data-en=`"not yet assigned &ndash; a deliberate decision in the Admin Center`">noch nicht zugewiesen</span></td></tr>"
} else {
    $asgRows = @(foreach ($a in $asg) {
        $tcls = switch ($a.Type) { 'Required' { 'b-info' } 'Uninstall' { 'b-fail' } default { 'b-neut' } }
        "            <tr><td>$(Esc $a.Group)</td><td><span class=`"badge $tcls`">$(Esc $a.Type)</span></td><td>$(Esc $a.Availability)</td></tr>"
    }) -join "`n"
}

# ----------------------------------------------------------------------------- hooks
function Format-HookItems {
    param($Items)
    if (-not $Items -or $Items.Count -eq 0) { return '' }
    @(foreach ($it in $Items) {
        $de = $null; $en = $null
        if ($it -is [hashtable] -and $it.ContainsKey('De')) { $de = $it['De']; $en = $it['En'] }
        elseif ($it -isnot [string] -and $it.PSObject -and $it.PSObject.Properties['De']) { $de = $it.De; $en = $it.En }
        if ($de) { "              <li data-de=`"$(AttrHtml $de)`" data-en=`"$(AttrHtml $en)`">$de</li>" }
        else { "              <li>$(Esc ([string]$it))</li>" }
    }) -join "`n"
}
$hookInstall = Format-HookItems (Get-Val 'HookInstall' @(
    'Show-ADTInstallationWelcome (CloseProcesses, CheckDiskSpace)',
    'Start-ADTMsiProcess / Start-ADTProcess (silent)',
    @{ De = 'Startmen&uuml;-Verkn&uuml;pfung (kein Desktop)'; En = 'Start-menu shortcut (no desktop)' }
))
$hookUninstall = Format-HookItems (Get-Val 'HookUninstall' @(
    'Start-ADTMsiProcess -Action Uninstall / Remove-ADTApplication',
    @{ De = 'App-spezifische Leftovers entfernen'; En = 'Remove app-specific leftovers' },
    @{ De = 'Nutzerdaten bleiben erhalten'; En = 'User data is preserved' }
))
$hookRepair = Format-HookItems (Get-Val 'HookRepair' @(
    'Start-ADTMsiProcess -Action Repair (/fa) oder Reinstall',
    @{ De = 'Dateien + Verkn&uuml;pfungen werden neu gesetzt'; En = 'Files + shortcuts are re-applied' }
))

# ----------------------------------------------------------------------------- cmdlets
$cmds = Get-Val 'Cmdlets' @('Show-ADTInstallationWelcome', 'Start-ADTMsiProcess', 'Write-ADTLogEntry', 'Close-ADTSession')
$cmdChips = @(foreach ($c in $cmds) { "          <span class=`"chip`">$(Esc $c)</span>" }) -join "`n"

# ----------------------------------------------------------------------------- pre-flight
# Default = NOT RUN (neutral). Real results arrive via -Metadata Preflight; without them the report must
# NOT show a synthetic PASS (honest reporting - green-by-default would hide checks that never ran).
$defaultPf = @(
    @{ Title = 'Pre-flight'; Cls = 'neutral'; De = 'keine Ergebnisse &uuml;bergeben &middot; nicht ausgef&uuml;hrt'; En = 'no results supplied &middot; not run'; BDe = 'nicht ausgef&uuml;hrt'; BEn = 'not run' }
)
$pf = Get-Val 'Preflight' $defaultPf
$pfChecks = @(foreach ($c in $pf) {
    $sym = switch ($c.Cls) { 'ok' { '&#10003;' } 'warn' { '!' } 'neutral' { '&ndash;' } default { '&times;' } }
    $bcls = switch ($c.Cls) { 'ok' { 'b-ok' } 'warn' { 'b-warn' } 'neutral' { 'b-neut' } default { 'b-fail' } }
    "          <div class=`"check`"><span class=`"ci $($c.Cls)`">$sym</span><div><div class=`"ct`">$(Esc $c.Title)</div><div class=`"cd`" data-de=`"$(AttrHtml $c.De)`" data-en=`"$(AttrHtml $c.En)`">$($c.De)</div></div><span class=`"badge $bcls`" data-de=`"$(AttrHtml $c.BDe)`" data-en=`"$(AttrHtml $c.BEn)`">$($c.BDe)</span></div>"
}) -join "`n"

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
    @{ StepDe = 'SYSTEM-Test'; StepEn = 'SYSTEM test'; Exit = '-'; Detection = '&ndash;'; Cls = 'b-neut'; Result = 'not run' }
)
$st = Get-Val 'SystemTest' $defaultSt
$stRows = @(foreach ($s in $st) {
    "            <tr><td data-de=`"$(AttrHtml $s.StepDe)`" data-en=`"$(AttrHtml $s.StepEn)`">$($s.StepDe)</td><td><code>$(Esc $s.Exit)</code></td><td>$($s.Detection)</td><td><span class=`"badge $($s.Cls)`">$(Esc $s.Result)</span></td></tr>"
}) -join "`n"
$stNoteDe = Get-Val 'SystemTestNoteDe' 'Keine SYSTEM-Test-Ergebnisse &uuml;bergeben &ndash; der SYSTEM-Test wurde nicht ausgef&uuml;hrt (kein Beleg).'
$stNoteEn = Get-Val 'SystemTestNoteEn' 'No SYSTEM-test results supplied &ndash; the SYSTEM test was not run (no evidence).'

# ----------------------------------------------------------------------------- token map
$logoSrc = Get-LogoDataUri -Path $LogoPath -AppName $appName

$tokens = [ordered]@{
    'LANG'              = $lang
    'APP_NAME'          = (Esc $appName)
    'APP_VERSION'       = (Esc $appVersion)
    'PUBLISHER'         = (Esc $publisher)
    'PKG_REV'           = (Esc $pkgRev)
    'SCRIPT_VERSION'    = (Esc $scriptVersion)
    'CREATED'           = (Esc $created)
    'AUTHOR'            = (Esc $author)
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
    'V_OWNER'           = (Esc $owner)
    'V_CATEGORY'        = $vCategory
    'V_FEATURED'        = $vFeatured
    'V_INFO_URL'        = $vInfoUrl
    'V_PRIVACY_URL'     = $vPrivacyUrl
    'V_NOTES'           = $vNotes
    'V_LOGO'            = $vLogo
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
    'V_CERT_POLICY'     = $vCertPolicy
    'V_DRIVERS'         = $vDrivers
    'V_RULE_FORMAT'     = $vRuleFormat
    'V_DETECT_SCRIPT'   = $vDetectScript
    'V_RUN_32'          = $vRun32
    'V_SIG_CHECK'       = $vSigCheck
    'V_DEPENDENCIES'    = $vDeps
    'V_SUPERSEDENCE'    = $vSup
    'ASSIGNMENT_ROWS'   = $asgRows
    'HOOK_INSTALL_ITEMS' = $hookInstall
    'HOOK_UNINSTALL_ITEMS' = $hookUninstall
    'HOOK_REPAIR_ITEMS' = $hookRepair
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

Write-Verbose "Report written: $OutputPath"
if ($PassThru) { Get-Item -LiteralPath $OutputPath }

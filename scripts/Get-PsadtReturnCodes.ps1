<#
.SYNOPSIS  The canonical Intune return-code table - ONE source of truth for the dossier and the upload.
.DESCRIPTION
  Microsoft Graph's win32LobAppReturnCode.type accepts exactly five values: success, softReboot,
  hardReboot, retry, failed. There is no 'ignored'. Anything else is rejected by the Intune backend, and a
  dossier that names an invalid type instructs the operator to configure something the portal will not
  accept - a wrong document is worse than a missing one.

  Before this script the canonical table existed TWICE as independent literals, in New-PsadtReport.ps1 and
  in Invoke-IntuneWin32Upload.ps1, and the report accepted a caller-supplied table without validating a
  single field. That is how the invalid type 'Ignored' reached a real dossier. Both callers now read from
  here, so the document and the app can no longer disagree.

  The design decision that makes an invalid type structurally impossible: Label and Cls are DERIVED from
  Type through a closed switch and are NEVER taken from the caller. A caller can therefore state what a
  code MEANS but not how it is labelled, which also removes the attribute-injection hazard that the old
  raw-interpolated Cls carried.

  Ordering follows guide Appendix F.4: by type (success, softReboot, hardReboot, retry, failed), then
  numerically within a type. Not plain numeric ordering - the dossier is verified line by line against that
  mandatory table and is transcribed into the portal grid in the same sequence, so matching it beats
  sorting the digits.
.PARAMETER Custom
  Installer-specific return codes researched in Phase 1.3, MERGED OVER the canonical table. Each entry is
  a hashtable or a PSCustomObject with Code, Type and optionally De/En - PascalCase (@{ Code = 3 }) and the
  camelCase shape that comes out of the package manifest JSON (@{ code = 3 }) are both accepted.
  An entry whose Code already exists OVERRIDES that row; an installer for which 1618 genuinely means
  success must be expressible.

  There is deliberately NO switch to replace the canonical table wholesale. Appendix F.4 calls it
  mandatory, and a package that does not map 60001/60008 to Failed reports its own crashes as success.
.PARAMETER AsGraphBody
  Project to the Microsoft Graph win32LobApp shape: @(@{ returnCode = <int>; type = '<token>' }).
.OUTPUTS
  PSCustomObject[] with Code(int), Type(string), Label(string), Cls(string), De(string), En(string),
  or the Graph shape when -AsGraphBody is given. Always sorted, never empty.
.EXAMPLE
  Get-PsadtReturnCodes.ps1

  The seven mandatory codes, ready for the dossier.
.EXAMPLE
  Get-PsadtReturnCodes.ps1 -Custom @(@{ Code = 1603; Type = 'failed'; De = 'MSI-Fehler'; En = 'MSI error' })

  The mandatory table plus one researched installer code, in Appendix F.4 order.
.EXAMPLE
  Get-PsadtReturnCodes.ps1 -AsGraphBody

  The same table as the returnCodes collection of a win32LobApp.
#>
[CmdletBinding()]
param(
    [object[]]$Custom = @(),
    [switch]$AsGraphBody,

    # Unused downstream; accepted so callers can pass it through.
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'

# The only types Intune accepts. Written out here rather than derived from anything, because this list IS
# the contract - see https://learn.microsoft.com/graph/api/resources/intune-apps-win32lobappreturncode
$ValidTypes = @('success', 'softReboot', 'hardReboot', 'retry', 'failed')

# Appendix F.4 order. Used as the primary sort key so the dossier reads in the same sequence as the table
# it is checked against and as the portal grid it is typed into.
$TypeRank = @{ success = 1; softReboot = 2; hardReboot = 3; retry = 4; failed = 5 }

function Get-Field {
    <#
      Reads one field from either a hashtable (@{ Code = 3 }) or a PSCustomObject (manifest JSON, @{ code = 3 }).
      Both are case-insensitive in PowerShell, so one accessor covers PascalCase metadata and camelCase JSON
      without the caller having to normalise first. This looks like a missing branch; it is not.
    #>
    param($Entry, [string]$Name)

    if ($null -eq $Entry) { return $null }
    if ($Entry -is [System.Collections.IDictionary]) {
        foreach ($key in $Entry.Keys) { if ([string]$key -ieq $Name) { return $Entry[$key] } }
        return $null
    }
    $prop = $Entry.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($prop) { return $prop.Value }
    return $null
}

function ConvertTo-ReturnCodeType {
    <#
      Liberal in, strict out. 'Soft reboot', 'SOFTREBOOT' and 'softReboot' all resolve, because the guide's
      own mandatory table writes the portal's display wording rather than the Graph token. Anything that
      does not resolve is a caller bug and throws - silently rendering it is what produced 'Ignored'.
    #>
    param([string]$Value, $Code)

    $normalised = ($Value -replace '[^A-Za-z]', '').ToLowerInvariant()
    switch ($normalised) {
        'success' { return 'success' }
        'successful' { return 'success' }
        'softreboot' { return 'softReboot' }
        'hardreboot' { return 'hardReboot' }
        'retry' { return 'retry' }
        'failed' { return 'failed' }
        'fail' { return 'failed' }
        'failure' { return 'failed' }
    }

    # Called out separately because it is the mistake that actually happened, and a generic "unknown type"
    # message would leave the reader looking for a typo instead of a wrong concept.
    if ($normalised -in @('ignored', 'ignore')) {
        throw "Return code $Code was given the type '$Value', but Intune has no 'ignored' return-code type. The Win32 app return-code dropdown offers exactly: Success, Soft reboot, Hard reboot, Retry, Failed. A code that should not fail the install is 'Success'; one that should is 'Failed'."
    }

    throw "Return code $Code was given the unknown type '$Value'. Valid types are: $($ValidTypes -join ', ') (the portal shows them as Success, Soft reboot, Hard reboot, Retry, Failed)."
}

function Get-ReturnCodePresentation {
    <#
      Type -> badge class + label. A closed switch, and the ONLY place either value can come from.
      Label stays English on purpose even in a German dossier: it is the literal wording of the Intune
      portal's Type dropdown, which the operator has to find there in either language.
    #>
    param([string]$Type)

    switch ($Type) {
        'success' { return @{ Label = 'Success'; Cls = 'b-ok' } }
        'softReboot' { return @{ Label = 'Soft reboot'; Cls = 'b-warn' } }
        'hardReboot' { return @{ Label = 'Hard reboot'; Cls = 'b-warn' } }
        'retry' { return @{ Label = 'Retry'; Cls = 'b-neut' } }
        'failed' { return @{ Label = 'Failed'; Cls = 'b-fail' } }
    }
    throw "No presentation defined for return-code type '$Type'."
}

function Get-DefaultMeaning {
    # Fallback wording for a researched code entered as just number + type, so its row is never blank.
    param([string]$Type)

    switch ($Type) {
        'success' { return @{ De = 'Erfolgreich'; En = 'Successful' } }
        'softReboot' { return @{ De = 'Neustart empfohlen'; En = 'Restart recommended' } }
        'hardReboot' { return @{ De = 'Neustart wird ausgel&ouml;st'; En = 'Restart is triggered' } }
        'retry' { return @{ De = 'Sp&auml;ter erneut versuchen'; En = 'Retry later' } }
        'failed' { return @{ De = 'Installation fehlgeschlagen'; En = 'Installation failed' } }
    }
    return @{ De = ''; En = '' }
}

# --- The canonical table (guide Appendix F.4) --------------------------------------------------------
$canonical = @(
    @{ Code = 0; Type = 'success'; De = 'Erfolgreich'; En = 'Successful' }
    @{ Code = 1707; Type = 'success'; De = 'Erfolgreich'; En = 'Successful' }
    @{ Code = 3010; Type = 'softReboot'; De = 'Neustart empfohlen'; En = 'Restart recommended' }
    @{ Code = 1641; Type = 'hardReboot'; De = 'Neustart wird ausgel&ouml;st'; En = 'Restart is triggered' }
    @{ Code = 1618; Type = 'retry'; De = 'Anderer Installer l&auml;uft, erneut versuchen'; En = 'Another installer running, retry' }
    @{ Code = 60001; Type = 'failed'; De = 'Laufzeitfehler in Install-ADTDeployment'; En = 'Runtime error in Install-ADTDeployment' }
    @{ Code = 60008; Type = 'failed'; De = 'Init/Import-Module fehlgeschlagen'; En = 'Init/Import-Module failed' }
)

# --- Normalise the caller's entries ------------------------------------------------------------------
$resolved = [ordered]@{}
foreach ($entry in $canonical) { $resolved[[string]$entry.Code] = $entry }

$seenCustom = @{}
foreach ($entry in @($Custom | Where-Object { $null -ne $_ })) {
    $rawCode = Get-Field $entry 'Code'
    $parsedCode = 0
    if (-not [int]::TryParse([string]$rawCode, [ref]$parsedCode)) {
        throw "Return code '$rawCode' is not an integer. Each entry needs a numeric Code, e.g. @{ Code = 1603; Type = 'failed' }."
    }

    if ($seenCustom.ContainsKey($parsedCode)) {
        throw "Return code $parsedCode is listed twice in -Custom. Which entry wins would be ambiguous; supply it once."
    }
    $seenCustom[$parsedCode] = $true

    $rawType = Get-Field $entry 'Type'
    if ([string]::IsNullOrWhiteSpace([string]$rawType)) {
        # Backwards compatibility: the pre-0.26 shape carried Label (free text) and Cls (a badge class).
        # Label is usable - it held the portal wording - so fall back to it.
        $rawType = Get-Field $entry 'Label'
    }
    if ([string]::IsNullOrWhiteSpace([string]$rawType)) {
        # Cls alone is NOT enough: b-warn is ambiguous between softReboot and hardReboot, and guessing is
        # exactly the silent wrongness this script exists to prevent.
        $legacyCls = Get-Field $entry 'Cls'
        if (-not [string]::IsNullOrWhiteSpace([string]$legacyCls)) {
            throw "Return code $parsedCode supplies only Cls ('$legacyCls') and no Type. A badge class cannot identify the Intune type - 'b-warn' is both Soft reboot and Hard reboot. Supply Type = '$($ValidTypes -join "' / '")'."
        }
        throw "Return code $parsedCode has no Type. Supply one of: $($ValidTypes -join ', ')."
    }

    if (-not [string]::IsNullOrWhiteSpace([string](Get-Field $entry 'Cls'))) {
        Write-Warning "Return code ${parsedCode}: the 'Cls' field is ignored - the badge class is derived from Type so an invalid combination cannot be rendered. Drop it from the metadata."
    }

    $type = ConvertTo-ReturnCodeType -Value ([string]$rawType) -Code $parsedCode
    $fallback = Get-DefaultMeaning $type
    $de = Get-Field $entry 'De'; if ([string]::IsNullOrWhiteSpace([string]$de)) { $de = $fallback.De }
    $en = Get-Field $entry 'En'; if ([string]::IsNullOrWhiteSpace([string]$en)) { $en = $fallback.En }

    $resolved[[string]$parsedCode] = @{ Code = $parsedCode; Type = $type; De = $de; En = $en }
}

# --- Project + sort ----------------------------------------------------------------------------------
# Duplicate codes throw above, so (TypeRank, Code) is a TOTAL order: the result is deterministic on
# Windows PowerShell 5.1 as well, where Sort-Object is not stable.
$records = foreach ($entry in $resolved.Values) {
    $type = ConvertTo-ReturnCodeType -Value ([string]$entry.Type) -Code $entry.Code
    $presentation = Get-ReturnCodePresentation $type
    [pscustomobject]@{
        Code  = [int]$entry.Code
        Type  = $type
        Label = $presentation.Label
        Cls   = $presentation.Cls
        De    = [string]$entry.De
        En    = [string]$entry.En
    }
}
$sorted = @($records | Sort-Object -Property @{ Expression = { $TypeRank[$_.Type] } }, @{ Expression = { $_.Code } })

if ($AsGraphBody) {
    return @($sorted | ForEach-Object { @{ returnCode = $_.Code; type = $_.Type } })
}
return $sorted

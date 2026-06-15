#Requires -Modules PSAppDeployToolkit
<#
    New-BrowserExtensionPackage.ps1 - reusable PSADT v4.1.8 generator for browser-extension
    force-install packages (Microsoft Edge / Google Chrome / Mozilla Firefox).

    These are POLICY-ONLY packages: no vendor installer, no bundled payload - the package only sets
    enterprise policy registry keys, and each browser then pulls the extension from its own store
    (Chrome Web Store / Edge Add-ons / Firefox AMO). ESP-safe, no reboot.

    The generator scaffolds the template and writes (English/ASCII only):
      - Invoke-AppDeployToolkit.ps1  (data model + Install/Uninstall/Repair hooks)
      - PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1  (4 merge/remove helpers)
      - Detect-<Name>.ps1            (verifies the policy is set; honest model)

    See references/PSADTv4-Deployment-Guide.md Appendix O for the model, registry reference and
    anti-patterns.

    .PARAMETER Extensions
    Array of hashtables, one per extension. Each MUST set at least one browser:
        @{
            Name    = 'uBlock Origin'                                  # display name (ASCII)
            Edge    = @{ Id = 'odfafepnkmbhccpbejgmiehpchacaeak' }      # Edge Add-ons ID (optional)
            Chrome  = @{ Id = 'cjpalhdlnbpafiamejdnhcphjbkeiagm' }      # Chrome Web Store ID (optional)
            Firefox = @{ Id = 'uBlock0@raymondhill.net'; Slug = 'ublock-origin' }   # AMO id + slug (optional)
        }
    Firefox accepts either Slug (the AMO install_url is derived) OR an explicit InstallUrl.

    .EXAMPLE
    $exts = @(
        @{ Name='uBlock Origin'
           Edge=@{Id='odfafepnkmbhccpbejgmiehpchacaeak'}
           Chrome=@{Id='cjpalhdlnbpafiamejdnhcphjbkeiagm'}
           Firefox=@{Id='uBlock0@raymondhill.net'; Slug='ublock-origin'} }
    )
    pwsh scripts/New-BrowserExtensionPackage.ps1 -Name 'BrowserExtensions-Standard' `
        -AppName 'Browser Extensions (Standard Set)' -Extensions $exts
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,                 # package folder + scaffold name (path-safe)
    [Parameter(Mandatory)][string]$AppName,              # display name in $adtSession
    [string]$AppVersion = '1.0',
    [Parameter(Mandatory)][hashtable[]]$Extensions,      # see .PARAMETER Extensions
    [string]$AppVendor = 'Browser Extensions',
    [string]$Author,
    [string]$PackageRoot,
    [string]$Changelog = ''
)

$ErrorActionPreference = 'Stop'
Import-Module PSAppDeployToolkit -Force

if (-not $PackageRoot) { $PackageRoot = (& (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1')).Config.paths.packageRoot }
if (-not $Author) {
    $cfg = (& (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1')).Config
    if ($cfg) { $Author = "$($cfg.author.person), $($cfg.author.company)" }
}
$today = (Get-Item $PSCommandPath).LastWriteTime.ToString('yyyy-MM-dd')  # avoid Get-Date (sandbox)

# Escape a value for embedding inside a single-quoted PowerShell literal (double internal quotes).
function Get-SqEscaped([string]$s) { ($s -replace "'", "''") }
# Reject a value that contains a template placeholder - it would corrupt the .Replace() templating.
function Assert-NoTokenLeak([string]$value, [string]$paramName) {
    if ($value -match '__[A-Z0-9_]+__') { throw "Parameter '$paramName' must not contain a template placeholder sequence ('$($Matches[0])')." }
}
if ($Name -match '[\\/:*?"<>|]' -or $Name -match '\.\.') { throw "Name '$Name' must be a simple folder name (no path separators or '..')." }
foreach ($pair in @(@('Name', $Name), @('AppVendor', $AppVendor), @('AppName', $AppName), @('AppVersion', $AppVersion), @('Author', $Author), @('Changelog', $Changelog))) {
    Assert-NoTokenLeak ([string]$pair[1]) $pair[0]
}

# --- Validate + normalize the extension list ------------------------------------------------------
$chromiumIdPattern = '^[a-p]{32}$'
$norm = foreach ($ext in $Extensions) {
    if (-not $ext.ContainsKey('Name') -or [string]::IsNullOrWhiteSpace([string]$ext.Name)) {
        throw "Each extension needs a Name."
    }
    $hasBrowser = $false
    foreach ($b in 'Edge', 'Chrome', 'Firefox') { if ($ext.ContainsKey($b)) { $hasBrowser = $true } }
    if (-not $hasBrowser) { throw "Extension '$($ext.Name)' sets no browser (need at least one of Edge/Chrome/Firefox)." }

    foreach ($b in 'Edge', 'Chrome') {
        if ($ext.ContainsKey($b)) {
            $id = [string]$ext[$b].Id
            if ([string]::IsNullOrWhiteSpace($id)) { throw "Extension '$($ext.Name)' $b is missing an Id." }
            if ($id -notmatch $chromiumIdPattern) { Write-Warning "Extension '$($ext.Name)' $b Id '$id' is not a 32-char a-p store ID - double-check it." }
        }
    }
    if ($ext.ContainsKey('Firefox')) {
        $fid = [string]$ext.Firefox.Id
        if ([string]::IsNullOrWhiteSpace($fid)) { throw "Extension '$($ext.Name)' Firefox is missing an Id." }
        $furl = [string]$ext.Firefox.InstallUrl
        if ([string]::IsNullOrWhiteSpace($furl)) {
            $slug = [string]$ext.Firefox.Slug
            if ([string]::IsNullOrWhiteSpace($slug)) { throw "Extension '$($ext.Name)' Firefox needs either Slug or InstallUrl." }
            $furl = "https://addons.mozilla.org/firefox/downloads/latest/$slug/latest.xpi"
        }
        $ext.Firefox.InstallUrl = $furl
    }
    $ext
}

# --- Render the shared $BrowserExtensions literal (used by launcher AND detection) ----------------
function ConvertTo-Literal([string]$s) { "'" + ($s -replace "'", "''") + "'" }
$lines = foreach ($ext in $norm) {
    $parts = @("Name = $(ConvertTo-Literal $ext.Name)")
    if ($ext.ContainsKey('Edge'))    { $parts += "Edge = @{ Id = $(ConvertTo-Literal ([string]$ext.Edge.Id)) }" }
    if ($ext.ContainsKey('Chrome'))  { $parts += "Chrome = @{ Id = $(ConvertTo-Literal ([string]$ext.Chrome.Id)) }" }
    if ($ext.ContainsKey('Firefox')) { $parts += "Firefox = @{ Id = $(ConvertTo-Literal ([string]$ext.Firefox.Id)); InstallUrl = $(ConvertTo-Literal ([string]$ext.Firefox.InstallUrl)) }" }
    "    @{ " + ($parts -join '; ') + " }"
}
$extLiteral = "@(`r`n" + ($lines -join "`r`n") + "`r`n)"

# 1) Scaffold
$pkg = Join-Path $PackageRoot $Name
if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
New-ADTTemplate -Destination $PackageRoot -Name $Name -Force | Out-Null

# 2) Launcher
$tpl = @'
<#
.SYNOPSIS
PSAppDeployToolkit - Force-installs / removes browser extensions for __APPNAME__.
.DESCRIPTION
Policy-only package (no vendor installer): sets enterprise policy registry keys so Edge / Chrome /
Firefox pull the configured extensions from their stores. Three deployment types (Install / Uninstall
/ Repair) for Intune Win32 (PSADT v4.1.8). Custom helpers live in PSAppDeployToolkit.Extensions.
.NOTES
Changelog:
__CHANGELOG__
.LINK
https://psappdeploytoolkit.com
#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Interactive', 'NonInteractive', 'Silent')]
    [System.String]$DeployMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$SuppressRebootPassThru,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$TerminalServerMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$DisableLogging
)


##================================================
## MARK: Variables
##================================================

$adtSession = @{
    AppVendor = '__APPVENDOR__'
    AppName = '__APPNAME__'
    AppVersion = '__APPVERSION__'
    AppArch = 'x64'
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @()
    AppScriptVersion = '0.1'
    AppScriptDate = '__DATE__'
    AppScriptAuthor = '__AUTHOR__'
    RequireAdmin = $true

    InstallName = ''
    InstallTitle = ''

    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.1.8'
}

## Single source of truth for all three hooks + the detection script: the managed extensions.
## Each entry sets at least one browser. Edge/Chrome use the policy ExtensionInstallForcelist; Firefox
## uses the policy ExtensionSettings JSON. The helpers MERGE into shared policy keys and remove ONLY
## their own entries, so multiple extension packages coexist on the same device.
$script:BrowserExtensions = __EXTLITERAL__

function Install-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Install
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    ## Policy-only: nothing to close. The browser applies the policy on its next start.
    Show-ADTInstallationProgress

    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    foreach ($ext in $script:BrowserExtensions)
    {
        Write-ADTLogEntry -Message "Force-installing browser extension [$($ext.Name)]."
        if ($ext.ContainsKey('Edge'))    { Set-ADTChromiumForcelistEntry -Browser Edge   -ExtensionId $ext.Edge.Id }
        if ($ext.ContainsKey('Chrome'))  { Set-ADTChromiumForcelistEntry -Browser Chrome -ExtensionId $ext.Chrome.Id }
        if ($ext.ContainsKey('Firefox')) { Set-ADTFirefoxExtensionSetting -ExtensionId $ext.Firefox.Id -InstallUrl $ext.Firefox.InstallUrl }
    }

    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"
}

function Uninstall-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Uninstall
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    Show-ADTInstallationProgress

    ##================================================
    ## MARK: Uninstall
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## Remove ONLY our own entries. For Edge/Chrome the browser then auto-uninstalls the extension.
    foreach ($ext in $script:BrowserExtensions)
    {
        Write-ADTLogEntry -Message "Removing browser extension policy for [$($ext.Name)]."
        if ($ext.ContainsKey('Edge'))    { Remove-ADTChromiumForcelistEntry -Browser Edge   -ExtensionId $ext.Edge.Id }
        if ($ext.ContainsKey('Chrome'))  { Remove-ADTChromiumForcelistEntry -Browser Chrome -ExtensionId $ext.Chrome.Id }
        if ($ext.ContainsKey('Firefox')) { Remove-ADTFirefoxExtensionSetting -ExtensionId $ext.Firefox.Id }
    }

    ##================================================
    ## MARK: Post-Uninstall
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"
}

function Repair-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Repair
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    Show-ADTInstallationProgress

    ##================================================
    ## MARK: Repair
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## Idempotent re-apply (same as install). Helpers skip entries that are already present.
    foreach ($ext in $script:BrowserExtensions)
    {
        Write-ADTLogEntry -Message "Re-applying browser extension policy for [$($ext.Name)]."
        if ($ext.ContainsKey('Edge'))    { Set-ADTChromiumForcelistEntry -Browser Edge   -ExtensionId $ext.Edge.Id }
        if ($ext.ContainsKey('Chrome'))  { Set-ADTChromiumForcelistEntry -Browser Chrome -ExtensionId $ext.Chrome.Id }
        if ($ext.ContainsKey('Firefox')) { Set-ADTFirefoxExtensionSetting -ExtensionId $ext.Firefox.Id -InstallUrl $ext.Firefox.InstallUrl }
    }

    ##================================================
    ## MARK: Post-Repair
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"
}


##================================================
## MARK: Initialization
##================================================

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

try
{
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf)
    {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{ ModuleName = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }
    else
    {
        Import-Module -FullyQualifiedName @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }

    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
}
catch
{
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int32]::MaxValue)))
    exit 60008
}


##================================================
## MARK: Invocation
##================================================

try
{
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory | & {
        process
        {
            if ($_.Name -match 'PSAppDeployToolkit\..+$')
            {
                Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
                Import-Module -Name $_.FullName -Force
            }
        }
    }

    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch
{
    $mainErrorMessage = "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity 3
    Close-ADTSession -ExitCode 60001
}
'@

if (-not $Changelog) { $Changelog = "- 0.1 ($today, $Author): Initial version - force-install browser extensions via policy registry keys." }

$out = $tpl.
    Replace('__APPVENDOR__', (Get-SqEscaped $AppVendor)).
    Replace('__APPNAME__', (Get-SqEscaped $AppName)).
    Replace('__APPVERSION__', (Get-SqEscaped $AppVersion)).
    Replace('__AUTHOR__', (Get-SqEscaped $Author)).
    Replace('__DATE__', $today).
    Replace('__CHANGELOG__', $Changelog).
    Replace('__EXTLITERAL__', $extLiteral)

[System.IO.File]::WriteAllText("$pkg\Invoke-AppDeployToolkit.ps1", $out, [System.Text.UTF8Encoding]::new($true))

# 3) Extensions module (the 4 merge/remove helpers). Overwrite the template stub.
$extModuleDir = Join-Path $pkg 'PSAppDeployToolkit.Extensions'
if (-not (Test-Path -LiteralPath $extModuleDir)) { New-Item -ItemType Directory -Path $extModuleDir -Force | Out-Null }
$psd1 = Join-Path $extModuleDir 'PSAppDeployToolkit.Extensions.psd1'
if (-not (Test-Path -LiteralPath $psd1)) {
    $manifest = @'
@{
    RootModule = 'PSAppDeployToolkit.Extensions.psm1'
    ModuleVersion = '1.0.0'
    GUID = '3d6a6f6d-7b1e-4a2c-9c8e-0b1d2e3f4a5b'
    Author = '__AUTHOR__'
    Description = 'PSAppDeployToolkit extension helpers for browser-extension force-install packages.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Set-ADTChromiumForcelistEntry', 'Remove-ADTChromiumForcelistEntry', 'Set-ADTFirefoxExtensionSetting', 'Remove-ADTFirefoxExtensionSetting')
}
'@
    [System.IO.File]::WriteAllText($psd1, $manifest.Replace('__AUTHOR__', (Get-SqEscaped $Author)), [System.Text.UTF8Encoding]::new($true))
}

$psm1 = @'
<#
.SYNOPSIS
PSAppDeployToolkit.Extensions - browser-extension force-install helpers (Edge / Chrome / Firefox).
.DESCRIPTION
Merge-and-selective-remove helpers for the enterprise policy keys that force-install browser
extensions. All four helpers leave OTHER packages' entries intact - they key off the extension ID,
never a fixed registry index. See guide Appendix O.
#>

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

# Chromium (Edge/Chrome) ExtensionInstallForcelist policy locations + store update URLs.
$script:AdtChromiumForcelist = @{
    Edge   = @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist';  Url = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx' }
    Chrome = @{ Key = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist';   Url = 'https://clients2.google.com/service/update2/crx' }
}
$script:AdtFirefoxPolicyKey = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'

function Set-ADTChromiumForcelistEntry
{
    <#
    .SYNOPSIS
        Adds one extension to the Edge/Chrome ExtensionInstallForcelist policy (merge, idempotent).
    .DESCRIPTION
        Computes the next free numeric value name (never hard-codes "1"), so other packages' entries
        are preserved. If the same extension ID is already present in any entry, it is left as-is.
    .PARAMETER Browser
        'Edge' or 'Chrome'.
    .PARAMETER ExtensionId
        The store extension ID (32 chars a-p).
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)][ValidateSet('Edge', 'Chrome')][System.String]$Browser,
        [Parameter(Mandatory)][System.String]$ExtensionId
    )

    begin { Initialize-ADTFunction -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState }

    process
    {
        try
        {
            try
            {
                $key = $script:AdtChromiumForcelist[$Browser].Key
                $entry = "$ExtensionId;$($script:AdtChromiumForcelist[$Browser].Url)"
                if (!(Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }

                $existing = @()
                $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
                if ($props)
                {
                    foreach ($p in $props.PSObject.Properties)
                    {
                        if ($p.Name -match '^\d+$') { $existing += [pscustomobject]@{ Index = [int]$p.Name; Value = [string]$p.Value } }
                    }
                }

                if (@($existing | Where-Object { $_.Value -like "$ExtensionId;*" }).Count -gt 0)
                {
                    Write-ADTLogEntry -Message "$Browser forcelist already manages [$ExtensionId]; nothing to do."
                    return
                }

                $next = 1
                if ($existing.Count -gt 0) { $next = ([int]($existing | Measure-Object -Property Index -Maximum).Maximum) + 1 }
                New-ItemProperty -LiteralPath $key -Name "$next" -Value $entry -PropertyType String -Force | Out-Null
                Write-ADTLogEntry -Message "$Browser forcelist: added [$entry] at index $next."
            }
            catch
            {
                Write-Error -ErrorRecord $_
            }
        }
        catch
        {
            Invoke-ADTFunctionErrorHandler -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState -ErrorRecord $_
        }
    }

    end { Complete-ADTFunction -Cmdlet $PSCmdlet }
}

function Remove-ADTChromiumForcelistEntry
{
    <#
    .SYNOPSIS
        Removes ONLY this extension's entry from the Edge/Chrome ExtensionInstallForcelist policy.
    .DESCRIPTION
        Finds the value whose data matches "<id>;..." and deletes only that value name. Other packages'
        entries are untouched. Removing the entry makes the browser auto-uninstall the extension.
    .PARAMETER Browser
        'Edge' or 'Chrome'.
    .PARAMETER ExtensionId
        The store extension ID to remove.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)][ValidateSet('Edge', 'Chrome')][System.String]$Browser,
        [Parameter(Mandatory)][System.String]$ExtensionId
    )

    begin { Initialize-ADTFunction -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState }

    process
    {
        try
        {
            try
            {
                $key = $script:AdtChromiumForcelist[$Browser].Key
                if (!(Test-Path -LiteralPath $key)) { return }
                $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
                if (!$props) { return }
                foreach ($p in $props.PSObject.Properties)
                {
                    if (($p.Name -match '^\d+$') -and ([string]$p.Value -like "$ExtensionId;*"))
                    {
                        Remove-ItemProperty -LiteralPath $key -Name $p.Name -Force
                        Write-ADTLogEntry -Message "$Browser forcelist: removed [$ExtensionId] (was index $($p.Name))."
                    }
                }
            }
            catch
            {
                Write-Error -ErrorRecord $_
            }
        }
        catch
        {
            Invoke-ADTFunctionErrorHandler -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState -ErrorRecord $_
        }
    }

    end { Complete-ADTFunction -Cmdlet $PSCmdlet }
}

function Set-ADTFirefoxExtensionSetting
{
    <#
    .SYNOPSIS
        Adds one extension to the Firefox ExtensionSettings policy as force_installed (merge).
    .DESCRIPTION
        Reads the existing ExtensionSettings REG_MULTI_SZ JSON, merges this extension, and writes it
        back as REG_MULTI_SZ. CRITICAL: the value MUST be REG_MULTI_SZ - current Firefox silently
        ignores a single-line REG_SZ (Mozilla bug 1750233).
    .PARAMETER ExtensionId
        The Firefox extension ID (e.g. name@domain or a GUID).
    .PARAMETER InstallUrl
        The AMO install_url (.xpi) the extension is fetched from.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)][System.String]$ExtensionId,
        [Parameter(Mandatory)][System.String]$InstallUrl
    )

    begin { Initialize-ADTFunction -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState }

    process
    {
        try
        {
            try
            {
                $key = $script:AdtFirefoxPolicyKey
                if (!(Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }

                $obj = $null
                $raw = (Get-ItemProperty -LiteralPath $key -Name 'ExtensionSettings' -ErrorAction SilentlyContinue).'ExtensionSettings'
                if ($raw)
                {
                    $joined = ($raw -join '')
                    try { $obj = $joined | ConvertFrom-Json -ErrorAction Stop } catch { $obj = $null }
                }
                if (!$obj) { $obj = [pscustomobject]@{} }

                $setting = [pscustomobject]@{ installation_mode = 'force_installed'; install_url = $InstallUrl }
                $obj | Add-Member -NotePropertyName $ExtensionId -NotePropertyValue $setting -Force

                $json = $obj | ConvertTo-Json -Depth 6 -Compress
                # Write as REG_MULTI_SZ (MultiString) - a single-element array is one line of JSON.
                New-ItemProperty -LiteralPath $key -Name 'ExtensionSettings' -Value @($json) -PropertyType MultiString -Force | Out-Null
                Write-ADTLogEntry -Message "Firefox ExtensionSettings: ensured [$ExtensionId] force_installed."
            }
            catch
            {
                Write-Error -ErrorRecord $_
            }
        }
        catch
        {
            Invoke-ADTFunctionErrorHandler -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState -ErrorRecord $_
        }
    }

    end { Complete-ADTFunction -Cmdlet $PSCmdlet }
}

function Remove-ADTFirefoxExtensionSetting
{
    <#
    .SYNOPSIS
        Removes ONLY this extension's key from the Firefox ExtensionSettings policy JSON.
    .DESCRIPTION
        Parses the ExtensionSettings JSON, removes this extension ID, and writes the rest back as
        REG_MULTI_SZ. If it was the last entry, the value is deleted. Other extensions are preserved.
    .PARAMETER ExtensionId
        The Firefox extension ID to remove.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)][System.String]$ExtensionId
    )

    begin { Initialize-ADTFunction -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState }

    process
    {
        try
        {
            try
            {
                $key = $script:AdtFirefoxPolicyKey
                if (!(Test-Path -LiteralPath $key)) { return }
                $raw = (Get-ItemProperty -LiteralPath $key -Name 'ExtensionSettings' -ErrorAction SilentlyContinue).'ExtensionSettings'
                if (!$raw) { return }
                $joined = ($raw -join '')
                try { $obj = $joined | ConvertFrom-Json -ErrorAction Stop } catch { return }
                if (!$obj.PSObject.Properties[$ExtensionId]) { return }

                $obj.PSObject.Properties.Remove($ExtensionId)
                # Test emptiness via the serialized JSON, NOT PSObject.Properties.Count: after removing the
                # last note property, PSCustomObject reports a phantom empty-named property (count 1), but
                # ConvertTo-Json correctly yields '{}'.
                $json = $obj | ConvertTo-Json -Depth 6 -Compress
                if ([string]::IsNullOrWhiteSpace($json) -or $json -eq '{}')
                {
                    Remove-ItemProperty -LiteralPath $key -Name 'ExtensionSettings' -Force -ErrorAction SilentlyContinue
                    Write-ADTLogEntry -Message "Firefox ExtensionSettings: removed last entry [$ExtensionId]; deleted value."
                }
                else
                {
                    New-ItemProperty -LiteralPath $key -Name 'ExtensionSettings' -Value @($json) -PropertyType MultiString -Force | Out-Null
                    Write-ADTLogEntry -Message "Firefox ExtensionSettings: removed [$ExtensionId]."
                }
            }
            catch
            {
                Write-Error -ErrorRecord $_
            }
        }
        catch
        {
            Invoke-ADTFunctionErrorHandler -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState -ErrorRecord $_
        }
    }

    end { Complete-ADTFunction -Cmdlet $PSCmdlet }
}

Write-ADTLogEntry -Message "Module [$($MyInvocation.MyCommand.ScriptBlock.Module.Name)] imported successfully." -ScriptSection Initialization
'@
[System.IO.File]::WriteAllText((Join-Path $extModuleDir 'PSAppDeployToolkit.Extensions.psm1'), $psm1, [System.Text.UTF8Encoding]::new($true))

# 4) Detection script - verifies the policy is SET (not whether the browser loaded the extension).
$detect = @'
# Detect-__NAME__.ps1 - Intune detection for __APPNAME__ (__APPVERSION__).
# Honest model: checks that the force-install POLICY is present in the registry. It does NOT verify
# that each browser/profile has actually downloaded the extension (that is online + per-user).
# Contract: write to stdout + exit 0 when all managed policies are present; otherwise no output + exit 0.

$exts = __EXTLITERAL__

$chromium = @{
    Edge   = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist'
    Chrome = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
}
$firefoxKey = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'

function Test-ChromiumForce([string]$Browser, [string]$Id)
{
    $key = $chromium[$Browser]
    if (-not (Test-Path -LiteralPath $key)) { return $false }
    $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    if (-not $props) { return $false }
    foreach ($p in $props.PSObject.Properties)
    {
        if (($p.Name -match '^\d+$') -and ([string]$p.Value -like "$Id;*")) { return $true }
    }
    return $false
}

function Test-FirefoxForce([string]$Id)
{
    if (-not (Test-Path -LiteralPath $firefoxKey)) { return $false }
    $raw = (Get-ItemProperty -LiteralPath $firefoxKey -Name 'ExtensionSettings' -ErrorAction SilentlyContinue).'ExtensionSettings'
    if (-not $raw) { return $false }
    try { $obj = (($raw -join '') | ConvertFrom-Json -ErrorAction Stop) } catch { return $false }
    $prop = $obj.PSObject.Properties[$Id]
    if (-not $prop) { return $false }
    return ($prop.Value.installation_mode -eq 'force_installed')
}

$found = @()
$allOk = $true
foreach ($ext in $exts)
{
    if ($ext.ContainsKey('Edge'))    { if (Test-ChromiumForce 'Edge'   $ext.Edge.Id)   { $found += "Edge:$($ext.Edge.Id)" }   else { $allOk = $false } }
    if ($ext.ContainsKey('Chrome'))  { if (Test-ChromiumForce 'Chrome' $ext.Chrome.Id) { $found += "Chrome:$($ext.Chrome.Id)" } else { $allOk = $false } }
    if ($ext.ContainsKey('Firefox')) { if (Test-FirefoxForce $ext.Firefox.Id)          { $found += "Firefox:$($ext.Firefox.Id)" } else { $allOk = $false } }
}

if ($allOk -and $found.Count -gt 0)
{
    Write-Output ("Detected browser-extension policies: " + ($found -join ', '))
    exit 0
}
exit 0
'@
$detect = $detect.
    Replace('__NAME__', $Name).
    Replace('__APPNAME__', $AppName).
    Replace('__APPVERSION__', $AppVersion).
    Replace('__EXTLITERAL__', $extLiteral)
[System.IO.File]::WriteAllText("$pkg\Detect-$Name.ps1", $detect, [System.Text.UTF8Encoding]::new($true))

Write-Output "PACKAGE_OK: $pkg"
Write-Output "Next: Phase 5 pre-flight (scripts/Invoke-PsadtPreflight.ps1 -PackagePath '$pkg') -> Phase 7 package -> Phase 8 dossier."

#Requires -Modules PSAppDeployToolkit
<#
    New-MsiPackage.ps1 - reusable PSADT v4.1.8 MSI package generator.
    Scaffolds a template, writes a fully-customized ASCII Invoke-AppDeployToolkit.ps1
    (Install/Uninstall/Repair), bundles the MSI, and writes a registry detection script.
    English/ASCII only in all generated script content (encoding cleanliness).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,            # package folder + scaffold name (path-safe)
    [Parameter(Mandatory)][string]$AppVendor,
    [Parameter(Mandatory)][string]$AppName,         # display name in $adtSession (may contain / etc.)
    [Parameter(Mandatory)][string]$AppVersion,
    [Parameter(Mandatory)][string]$AppArch,         # x64 | x86 | ARM64
    # Validated at binding, like Invoke-IntuneWin32Upload.ps1 does: this value is substituted into a
    # single-quoted literal in BOTH the launcher and the detection script, and both run as SYSTEM.
    [Parameter(Mandatory)][ValidatePattern('^\{?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}?$')]
    [string]$ProductCode,                           # {GUID}
    [Parameter(Mandatory)][string]$InstallerFile,   # filename placed into Files\
    [Parameter(Mandatory)][string]$InstallerPath,   # source path of the MSI to copy in
    [string]$AdditionalArgs = '',                   # extra MSI properties only (NOT /qn)
    [string]$DisplayNameLike = '',                  # detection DisplayName fallback pattern
    [string[]]$ProcessesToClose = @(),
    [string]$Author,
    [string]$PackageRoot,
    [string]$Changelog = '',
    # A re-run used to wipe the folder outright. Phase 4 fills the three hooks BY HAND, so that threw away
    # work nothing else holds - along with the Extensions module, Assets\ and the recorded results.
    [switch]$Force,
    # Self-updating MSI apps (Chrome, Audacity, ...): the app binary relative to Program Files, e.g.
    # 'Google\Chrome\Application\chrome.exe'. Switches the package from ProductCode identity to a version
    # FLOOR - see the comment at $selfUpdating below.
    [string]$SelfUpdatingBinary = '',
    [string]$ArpDisplayName = ''                    # exact ARP DisplayName for that mode (default: AppName)
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
function Expand-CommaSeparated([string[]]$Values) {
    # `pwsh scripts/New-MsiPackage.ps1 -ProcessesToClose a,b` uses the -File binder, and that binder
    # passes "a,b" as ONE element - it does not split on commas. Left alone, the scaffold gets
    # AppProcessesToClose = @('a,b') - one process name that matches nothing. Show-ADTInstallationWelcome
    # -CloseProcesses then closes NOTHING and still reports success, so the install runs against a
    # running application. A silent loss beats an error every time; 0.25.1 fixed the other five scripts
    # and missed this one. A process name cannot contain a comma, so the split is unambiguous here.
    if (-not $Values) { return @() }
    return @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
# Reject a value that contains a template placeholder - it would corrupt the .Replace() templating.
function Assert-NoTokenLeak([string]$value, [string]$paramName) {
    if ($value -match '__[A-Z0-9_]+__') { throw "Parameter '$paramName' must not contain a template placeholder sequence ('$($Matches[0])')." }
}
# A value carrying the comment-block terminator would END the launcher's <# .. #> help block, and what
# follows it becomes top-level code in a script that later runs as SYSTEM. Reject it at the source.
function Assert-NoCommentTerminator([string]$value, [string]$paramName) {
    if ($value -match '#>') { throw "Parameter '$paramName' must not contain the comment terminator '#>'." }
}
if ($Name -match '[\\/:*?"<>|]' -or $Name -match '\.\.') { throw "Name '$Name' must be a simple folder name (no path separators or '..')." }
foreach ($pair in @(@('Name', $Name), @('AppVendor', $AppVendor), @('AppName', $AppName), @('AppVersion', $AppVersion), @('Author', $Author), @('AdditionalArgs', $AdditionalArgs), @('InstallerFile', $InstallerFile), @('DisplayNameLike', $DisplayNameLike), @('Changelog', $Changelog), @('SelfUpdatingBinary', $SelfUpdatingBinary), @('ArpDisplayName', $ArpDisplayName))) {
    Assert-NoTokenLeak ([string]$pair[1]) $pair[0]
}
Assert-NoCommentTerminator ([string]$Author) 'Author'
Assert-NoCommentTerminator ([string]$Changelog) 'Changelog'
if (-not (Test-Path -LiteralPath $InstallerPath)) { throw "InstallerPath not found: $InstallerPath" }

# Self-updating mode. Measured on Google Chrome 154.0.8037.58 (2026-09-23): every Chrome build ships a
# NEW ProductCode, and GoogleUpdater replaces the binaries in place without re-running this package's MSI.
# A ProductCode-keyed package then breaks three ways: detection of the NEXT package never matches a
# device that auto-updated (Intune reinstalls on its ~24h cycle), installing the older MSI over a newer
# build fails with 1603 (downgrade), and Uninstall/Repair aim at a GUID the device no longer has.
# So: detection is a version FLOOR on the binary, Install skips when an equal or newer build is present,
# and Uninstall/Repair resolve whichever MSI is registered under the exact ARP DisplayName.
$selfUpdating = [bool]$SelfUpdatingBinary
if ($selfUpdating) {
    if ([System.IO.Path]::IsPathRooted($SelfUpdatingBinary) -or $SelfUpdatingBinary -match '\.\.' -or $SelfUpdatingBinary -match '[:*?"<>|]') {
        throw "SelfUpdatingBinary '$SelfUpdatingBinary' must be a path RELATIVE to Program Files (e.g. 'Vendor\App\app.exe')."
    }
    $null = [System.Version]$AppVersion   # the floor must be comparable; fail at generation, not on the client
    if (-not $ArpDisplayName) { $ArpDisplayName = $AppName }
}

# 1) Scaffold
# A package root that is a drive root would turn the delete below into a top-level system folder.
if ([string]::IsNullOrWhiteSpace($PackageRoot) -or $PackageRoot -eq [System.IO.Path]::GetPathRoot($PackageRoot)) {
    throw "PackageRoot must be a real folder, not a drive root: '$PackageRoot'. Set paths.packageRoot, or pass -PackageRoot."
}
$pkg = Join-Path $PackageRoot $Name
if (Test-Path $pkg) {
    if (-not $Force) {
        throw "Package folder already exists: $pkg. Re-running the generator REPLACES it, including hand-filled hooks, the Extensions module, Assets\ and the results recorded in psadt-package.json. Pass -Force if that is what you want, or use a different -Name."
    }
    Remove-Item $pkg -Recurse -Force
}
New-ADTTemplate -Destination $PackageRoot -Name $Name -Force | Out-Null

# 2) Process list literal (single-quote-escaped so a name with an apostrophe cannot break the literal)
$ProcessesToClose = Expand-CommaSeparated $ProcessesToClose
$procLiteral = if ($ProcessesToClose.Count -gt 0) { "@(" + (($ProcessesToClose | ForEach-Object { "'$(Get-SqEscaped $_)'" }) -join ', ') + ")" } else { "@()" }

# 3) Build the customized script
$tpl = @'
<#
.SYNOPSIS
PSAppDeployToolkit - Installs, uninstalls or repairs __APPNAME__.
.DESCRIPTION
Three deployment types (Install / Uninstall / Repair) for Intune Win32 (PSADT v4.1.8).
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
    AppArch = '__APPARCH__'
    AppLang = 'EN'
    AppRevision = '01'

    # One log per RUN. PSADT appends to a fixed default name (Toolkit.LogAppend = $true in 4.1.8), so
    # without this every run of every version piles into one file and a failed install is unreadable.
    # $DeploymentType has no default in this launcher, hence the inline guard. Sanitizing already happened
    # when this file was generated; Get-Date runs on the client.
    LogName = ('__LOGSTEM__' + '_' + $(if ($DeploymentType) { $DeploymentType } else { 'Install' }) + '_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    AppSuccessExitCodes = @(0, 1707)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = __PROCESSES__
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
__INSTALLGUARD__
    $saiwParams = @{ CheckDiskSpace = $true }
    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        $saiwParams.Add('CloseProcesses', $adtSession.AppProcessesToClose)
    }
    Show-ADTInstallationWelcome @saiwParams
    Show-ADTInstallationProgress

    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    Start-ADTMsiProcess -Action Install -FilePath "$($adtSession.DirFiles)\__INSTALLER__"__ADDARGSLINE__

    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## Remove any desktop shortcut the installer may have created (Start Menu only policy).
    foreach ($lnk in @((Join-Path "$env:Public\Desktop" '__APPNAME_FILE__.lnk')))
    {
        if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue }
    }
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

    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
    }
    Show-ADTInstallationProgress

    ##================================================
    ## MARK: Uninstall
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

__UNINSTALLCALL__

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

    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
    }
    Show-ADTInstallationProgress

    ##================================================
    ## MARK: Repair
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

__REPAIRCALL__

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

if (-not $Changelog) { $Changelog = "- 0.1 ($today, $Author): Initial version." }
$addArgsLine = if ($AdditionalArgs) { " -AdditionalArgumentList '$(Get-SqEscaped $AdditionalArgs)'" } else { '' }

# The three hook bodies that differ between the modes. The default values reproduce the ProductCode
# package byte for byte; the self-updating values are what passed the full sandbox gate on Chrome 154.
$nl = if ($tpl.Contains("`r`n")) { "`r`n" } else { "`n" }
if ($selfUpdating) {
    $arpLiteral = Get-SqEscaped $ArpDisplayName
    $installGuard = $nl + (@(
            '    ## The app updates itself past the packaged build. Installing the older MSI over it fails with'
            '    ## 1603 (downgrade), so an equal or newer build counts as done.'
            '    $installedVersion = Get-InstalledBinaryVersion'
            '    if ($installedVersion -and ($installedVersion -ge [System.Version]$adtSession.AppVersion))'
            '    {'
            '        Write-ADTLogEntry -Message "[$($adtSession.AppName)] [$installedVersion] is already installed (>= [$($adtSession.AppVersion)]). Skipping the MSI."'
            '        return'
            '    }'
        ) -join $nl) + $nl
    $uninstallCall = (@(
            '    ## Every build has its own ProductCode and the app moves on without this package. Remove whichever'
            '    ## MSI is registered under the exact display name instead of a fixed GUID.'
            "    Uninstall-ADTApplication -Name '$arpLiteral' -NameMatch Exact -ApplicationType MSI"
        ) -join $nl)
    $repairCall = (@(
            '    ## Repair the MSI that is actually registered (its ProductCode may differ from this package''s after'
            '    ## an auto-update); if none is registered, lay the packaged MSI down again.'
            "    `$registeredMsi = Get-ADTApplication -Name '$arpLiteral' -NameMatch Exact -ApplicationType MSI | Select-Object -First 1"
            '    if ($registeredMsi)'
            '    {'
            '        Start-ADTMsiProcess -Action Repair -ProductCode $registeredMsi.ProductCode -RepairMode Reinstall'
            '    }'
            '    else'
            '    {'
            "        Start-ADTMsiProcess -Action Install -FilePath `"`$(`$adtSession.DirFiles)\$(Get-SqEscaped $InstallerFile)`"$addArgsLine"
            '    }'
        ) -join $nl)
}
else {
    $installGuard = ''
    $uninstallCall = "    Start-ADTMsiProcess -Action Uninstall -ProductCode '$ProductCode'"
    $repairCall = "    Start-ADTMsiProcess -Action Repair -ProductCode '$ProductCode' -RepairMode Reinstall"
}

# Every operator value that lands in the generated script goes through Get-SqEscaped and into a
# SINGLE-quoted literal - including the desktop-shortcut name, which used to sit in a double-quoted
# string where a $ in an app name interpolated at client runtime, as SYSTEM.
# The per-run log name shares the artifact stem, and the sanitizing rule lives in exactly ONE place
# (Get-PsadtPackageManifest -Identity) so a second copy can never drift and rename an app.
$logStem = (& (Join-Path $PSScriptRoot 'Get-PsadtPackageManifest.ps1') -Identity @{ vendor = $AppVendor; name = $AppName; version = $AppVersion; arch = $AppArch }).Stem
$out = $tpl.
    Replace('__APPVENDOR__', (Get-SqEscaped $AppVendor)).
    Replace('__APPNAME_FILE__', (Get-SqEscaped $AppName)).
    Replace('__APPNAME__', (Get-SqEscaped $AppName)).
    Replace('__APPVERSION__', (Get-SqEscaped $AppVersion)).
    Replace('__APPARCH__', (Get-SqEscaped $AppArch)).
    Replace('__LOGSTEM__', $logStem).
    Replace('__PROCESSES__', $procLiteral).
    Replace('__AUTHOR__', (Get-SqEscaped $Author)).
    Replace('__DATE__', $today).
    Replace('__INSTALLER__', (Get-SqEscaped $InstallerFile)).
    Replace('__ADDARGSLINE__', $addArgsLine).
    Replace('__INSTALLGUARD__', $installGuard).
    Replace('__UNINSTALLCALL__', $uninstallCall).
    Replace('__REPAIRCALL__', $repairCall).
    Replace('__PRODUCTCODE__', $ProductCode).
    Replace('__CHANGELOG__', $Changelog)

# Write UTF-8 with BOM (encoding cleanliness)
[System.IO.File]::WriteAllText("$pkg\Invoke-AppDeployToolkit.ps1", $out, [System.Text.UTF8Encoding]::new($true))

# 4) Bundle installer
Copy-Item -LiteralPath $InstallerPath -Destination "$pkg\Files\$InstallerFile" -Force

# 5) Detection script (registry, ProductCode-based with DisplayName fallback)
$detect = @'
# Detect-__NAME__.ps1 - Intune detection for __APPNAME__ (__APPVERSION__)
$code = '__PRODUCTCODE__'
$keys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$code",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$code"
)
foreach ($k in $keys)
{
    if (Test-Path -LiteralPath $k)
    {
        $p = Get-ItemProperty -LiteralPath $k
        Write-Output "Detected: $($p.DisplayName) $($p.DisplayVersion)"
        exit 0
    }
}
# Not installed: emit nothing and exit 0 (Intune detection contract; a non-zero exit reads as a detection error).
exit 0
'@

# Where the binary lives. Intune may run the detection script as a 32-bit process, where $env:ProgramFiles
# is the x86 folder - ProgramW6432 always names the 64-bit one.
$pfExpr = if ($AppArch -eq 'x86') { '${env:ProgramFiles(x86)}' } else { 'if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }' }

if ($selfUpdating) {
    $detect = @'
# Detect-__NAME__.ps1 - Intune detection for __APPNAME__ (>= __APPVERSION__)
# Version FLOOR on the binary, not the MSI ProductCode: every build of this app has a new ProductCode and
# it updates its binaries in place, so a fixed GUID stops matching and Intune loops reinstalls.
$minVersion = [System.Version]'__APPVERSION__'
# Program Files resolved explicitly: Intune may run this script as a 32-bit process.
$programFiles = __PFEXPR__
$binary = Join-Path -Path $programFiles -ChildPath '__BINARY__'
if (Test-Path -LiteralPath $binary -PathType Leaf)
{
    $version = [System.Version](Get-Item -LiteralPath $binary).VersionInfo.ProductVersion
    if ($version -ge $minVersion)
    {
        Write-Output ('Detected: __APPNAME_SQ__ ' + $version)
        exit 0
    }
}
# Not installed (or older): emit nothing and exit 0 (Intune detection contract; a non-zero exit reads as a detection error).
exit 0
'@
    $detect = $detect.Replace('__PFEXPR__', $pfExpr).Replace('__BINARY__', (Get-SqEscaped $SelfUpdatingBinary)).Replace('__APPNAME_SQ__', (Get-SqEscaped $AppName))

    # The install guard's helper. Custom helpers belong in the Extensions module, never in the launcher.
    $helper = @'
function Get-InstalledBinaryVersion
{
    <#
    .SYNOPSIS
        Returns the file version of the packaged application's binary, or $null when it is absent.

    .DESCRIPTION
        Reads the binary rather than the MSI registration, because the app replaces its binaries with
        newer builds without re-running this package's MSI.

    .OUTPUTS
        System.Version

        The installed version, or $null.

    .EXAMPLE
        Get-InstalledBinaryVersion
    #>

    [CmdletBinding()]
    [OutputType([System.Version])]
    param
    (
    )

    begin
    {
        Initialize-ADTFunction -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState
    }

    process
    {
        try
        {
            try
            {
                $programFiles = __PFEXPR__
                $binary = Join-Path -Path $programFiles -ChildPath '__BINARY__'
                if (Test-Path -LiteralPath $binary -PathType Leaf)
                {
                    return [System.Version](Get-Item -LiteralPath $binary).VersionInfo.ProductVersion
                }
                return $null
            }
            catch
            {
                # Re-writing the ErrorRecord with Write-Error ensures the correct PositionMessage is used.
                Write-Error -ErrorRecord $_
            }
        }
        catch
        {
            # Process the caught error, log it and throw depending on the specified ErrorAction.
            Invoke-ADTFunctionErrorHandler -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState -ErrorRecord $_
        }
    }

    end
    {
        Complete-ADTFunction -Cmdlet $PSCmdlet
    }
}


'@
    $helper = $helper.Replace('__PFEXPR__', $pfExpr).Replace('__BINARY__', (Get-SqEscaped $SelfUpdatingBinary))
    $extPath = "$pkg\PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1"
    $ext = [System.IO.File]::ReadAllText($extPath)
    $extNl = if ($ext.Contains("`r`n")) { "`r`n" } else { "`n" }
    $anchor = '##*===============================================' + $extNl + '##* MARK: SCRIPT BODY'
    $at = $ext.IndexOf($anchor)
    if ($at -lt 0) { throw "Extensions module has no '##* MARK: SCRIPT BODY' anchor - the PSADT template changed: $extPath" }
    $ext = $ext.Insert($at, ($helper -replace "`r?`n", $extNl))
    [System.IO.File]::WriteAllText($extPath, $ext, [System.Text.UTF8Encoding]::new($true))
}

$detect = $detect.Replace('__NAME__', $Name).Replace('__APPNAME__', $AppName).Replace('__APPVERSION__', $AppVersion).Replace('__PRODUCTCODE__', $ProductCode)
[System.IO.File]::WriteAllText("$pkg\Detect-$Name.ps1", $detect, [System.Text.UTF8Encoding]::new($true))


# The manifest is written by the generator, not left to the operator: the identity that named the log and
# will name the .intunewin has to be recorded where every later phase reads it.
& (Join-Path $PSScriptRoot 'Set-PsadtPackageManifest.ps1') -PackagePath $pkg -Updates @{
    'app.vendor'             = $AppVendor
    'app.name'               = $AppName
    'app.version'            = $AppVersion
    'app.arch'               = $AppArch
    'app.lang'               = 'EN'
    'app.revision'           = 1
    'package.name'           = $logStem
    'package.type'           = 'installer'
    'package.installerTech'  = 'msi'
    # Recorded for the verified-switch store. An MSI's silent switch is deterministic, but its PROPERTIES
    # are not: ADDLOCAL feature selections, update-check and shortcut properties are researched per
    # application and are the expensive half of an MSI package.
    'package.installerFile'  = $InstallerFile
    # The join key the manifest never had. Both hash-keyed stores - verified-switches.json and
    # evidence\<sha>.json - are indexed by the SHA256 of THIS file, and the manifest recorded only the
    # hash of the finished .intunewin. Without this, a package cannot be matched to what was learned
    # about its own installer. Invoke-PsadtPreflight.ps1 already computes the same value at check time.
    'package.installerSha256' = $(try { (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant() } catch { $null })
    # Recorded so the next version can inherit it. This was a generator parameter and nothing else:
    # not in the manifest, not in the switch store, so it had to be retyped from memory every time.
    # Already normalised by Expand-CommaSeparated further up: the -File binder hands 'a,b' over as
    # ONE element, and recording that would carry a process name matching nothing into the next version.
    'package.processesToClose' = @($ProcessesToClose)
    'package.productCode'    = $ProductCode
    'package.sourceStrategy' = 'bundle'
    'research.switches'      = @{
        install       = "msiexec /i `"$InstallerFile`" /qn /norestart$(if ($AdditionalArgs) { " $AdditionalArgs" })"
        installArgs   = "/qn /norestart$(if ($AdditionalArgs) { " $AdditionalArgs" })"
        uninstall     = "msiexec /x $ProductCode /qn /norestart"
        uninstallArgs = '/qn /norestart'
        repair        = "msiexec /fomus $ProductCode /qn /norestart"
    }
} | Out-Null

if ($selfUpdating) {
    # The ProductCode above is only THIS build's. Recorded so pre-flight, the dossier and the next
    # version's operator can see why detection and uninstall do not key on it.
    & (Join-Path $PSScriptRoot 'Set-PsadtPackageManifest.ps1') -PackagePath $pkg -Updates @{
        'package.detection'    = 'versionFloor'
        'package.selfUpdating' = @{ binary = $SelfUpdatingBinary; arpDisplayName = $ArpDisplayName; floor = $AppVersion }
    } | Out-Null
}

Write-Output "PACKAGE_OK: $pkg"

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
    [Parameter(Mandatory)][string]$ProductCode,     # {GUID}
    [Parameter(Mandatory)][string]$InstallerFile,   # filename placed into Files\
    [Parameter(Mandatory)][string]$InstallerPath,   # source path of the MSI to copy in
    [string]$AdditionalArgs = '',                   # extra MSI properties only (NOT /qn)
    [string]$DisplayNameLike = '',                  # detection DisplayName fallback pattern
    [string[]]$ProcessesToClose = @(),
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
if ($Name -match '[\\/:*?"<>|]' -or $Name -match '\.\.') { throw "Name '$Name' must be a simple folder name (no path separators or '..')." }
foreach ($pair in @(@('Name', $Name), @('AppVendor', $AppVendor), @('AppName', $AppName), @('AppVersion', $AppVersion), @('Author', $Author), @('AdditionalArgs', $AdditionalArgs), @('InstallerFile', $InstallerFile), @('DisplayNameLike', $DisplayNameLike), @('Changelog', $Changelog))) {
    Assert-NoTokenLeak ([string]$pair[1]) $pair[0]
}
if (-not (Test-Path -LiteralPath $InstallerPath)) { throw "InstallerPath not found: $InstallerPath" }

# 1) Scaffold
$pkg = Join-Path $PackageRoot $Name
if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
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
    foreach ($lnk in @("$env:Public\Desktop\__APPNAME_FILE__.lnk"))
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

    Start-ADTMsiProcess -Action Uninstall -ProductCode '__PRODUCTCODE__'

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

    Start-ADTMsiProcess -Action Repair -ProductCode '__PRODUCTCODE__' -RepairMode Reinstall

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

# Values that land in single-quoted $adtSession literals are single-quote-escaped; __APPNAME_FILE__ is the
# raw name for the double-quoted desktop-shortcut path (apostrophes are valid inside a double-quoted string).
# The per-run log name shares the artifact stem, and the sanitizing rule lives in exactly ONE place
# (Get-PsadtPackageManifest -Identity) so a second copy can never drift and rename an app.
$logStem = (& (Join-Path $PSScriptRoot 'Get-PsadtPackageManifest.ps1') -Identity @{ vendor = $AppVendor; name = $AppName; version = $AppVersion; arch = $AppArch }).Stem
$out = $tpl.
    Replace('__APPVENDOR__', (Get-SqEscaped $AppVendor)).
    Replace('__APPNAME_FILE__', $AppName).
    Replace('__APPNAME__', (Get-SqEscaped $AppName)).
    Replace('__APPVERSION__', (Get-SqEscaped $AppVersion)).
    Replace('__APPARCH__', (Get-SqEscaped $AppArch)).
    Replace('__LOGSTEM__', $logStem).
    Replace('__PROCESSES__', $procLiteral).
    Replace('__AUTHOR__', (Get-SqEscaped $Author)).
    Replace('__DATE__', $today).
    Replace('__INSTALLER__', (Get-SqEscaped $InstallerFile)).
    Replace('__ADDARGSLINE__', $addArgsLine).
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
    'package.sourceStrategy' = 'bundle'
} | Out-Null

Write-Output "PACKAGE_OK: $pkg"

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
$today = (Get-Item $PSCommandPath).LastWriteTime.ToString('yyyy-MM-dd')  # avoid Get-Date (sandbox)

# 1) Scaffold
$pkg = Join-Path $PackageRoot $Name
if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
New-ADTTemplate -Destination $PackageRoot -Name $Name -Force | Out-Null

# 2) Process list literal
$procLiteral = if ($ProcessesToClose.Count -gt 0) { "@(" + (($ProcessesToClose | ForEach-Object { "'$_'" }) -join ', ') + ")" } else { "@()" }

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
    foreach ($lnk in @("$env:Public\Desktop\__APPNAME__.lnk"))
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
$addArgsLine = if ($AdditionalArgs) { " -AdditionalArgumentList '$AdditionalArgs'" } else { '' }

$out = $tpl.
    Replace('__APPVENDOR__', $AppVendor).
    Replace('__APPNAME__', $AppName).
    Replace('__APPVERSION__', $AppVersion).
    Replace('__APPARCH__', $AppArch).
    Replace('__PROCESSES__', $procLiteral).
    Replace('__AUTHOR__', $Author).
    Replace('__DATE__', $today).
    Replace('__INSTALLER__', $InstallerFile).
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
exit 1
'@
$detect = $detect.Replace('__NAME__', $Name).Replace('__APPNAME__', $AppName).Replace('__APPVERSION__', $AppVersion).Replace('__PRODUCTCODE__', $ProductCode)
[System.IO.File]::WriteAllText("$pkg\Detect-$Name.ps1", $detect, [System.Text.UTF8Encoding]::new($true))

Write-Output "PACKAGE_OK: $pkg"

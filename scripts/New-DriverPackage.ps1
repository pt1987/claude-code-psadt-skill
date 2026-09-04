#Requires -Modules PSAppDeployToolkit
<#
    New-DriverPackage.ps1 - reusable PSADT v4.1.8 generator for third-party driver packages.

    Stages driver packages into the Windows DriverStore with pnputil, as an Intune Win32 app. The point of a
    driver package is to get rid of the "install device software?" prompt that no SYSTEM-silent install can
    click - so this generator REFUSES to build something that cannot work, instead of producing a package
    that fails on the first client.

    It classifies the driver source first (Get-DriverSignatureInfo.ps1):
      MicrosoftSigned  -> nothing to do, -CertOwner none
      VendorSigned     -> the signer certificate must land in TrustedPublisher; -CertOwner decides WHERE
      Unsigned         -> ABORT with the three honest options; no testsigning, ever

    -CertOwner owns the certificate in exactly ONE place (they fight on uninstall/sync otherwise):
      policy   the Intune Custom OMA-URI profile (recommended, transparent, survives re-imaging)
               -> build it with scripts/New-IntuneTrustedCertPolicy.ps1 and assign it to the SAME scope
      package  the package's pre-install hook imports it, uninstall removes it again
      none     nothing to import (Microsoft-signed drivers)

    Install stages EVERY INF individually (`pnputil /add-driver <inf> /install`). The collective
    `*.inf /subdirs` form exists, but Microsoft documents its aggregate exit code as unreliable - one
    failure inside a batch can still report success, which is the worst possible outcome for a driver.

    pnputil exit codes treated as success: 0 (added), 259 = ERROR_NO_MORE_ITEMS (no matching device present,
    or the device already uses a newer driver - the package is staged, which is what we want), 3010 (reboot
    required -> SetExitCode(3010)). NOTE: documented per Microsoft, still to be confirmed against
    setupapi.dev.log on a DEV VM.

    English/ASCII only in all generated content (encoding cleanliness). See guide Appendix Q.

    .EXAMPLE
    & scripts/New-DriverPackage.ps1 -Name 'Mobotix-PrinterDriver-3.1.4' -AppName 'Mobotix Printer Driver' `
        -AppVendor 'Mobotix AG' -AppVersion '3.1.4' -DriverSource 'D:\src\mobotix-printer'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,                  # package folder + scaffold name (path-safe)
    [Parameter(Mandatory)][string]$AppName,               # display name in $adtSession
    [Parameter(Mandatory)][string]$AppVendor,
    [Parameter(Mandatory)][string]$AppVersion,
    [Parameter(Mandatory)][string]$DriverSource,          # folder holding the INF/CAT/SYS set
    [ValidateSet('policy', 'package', 'none')][string]$CertOwner,
    [switch]$AssumeSecureBootOff,
    [string]$AppArch = 'x64',
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

function Get-SqEscaped([string]$s) { ($s -replace "'", "''") }
function Assert-NoTokenLeak([string]$value, [string]$paramName) {
    if ($value -match '__[A-Z0-9_]+__') { throw "Parameter '$paramName' must not contain a template placeholder sequence ('$($Matches[0])')." }
}
if ($Name -match '[\\/:*?"<>|]' -or $Name -match '\.\.') { throw "Name '$Name' must be a simple folder name (no path separators or '..')." }
foreach ($pair in @(@('Name', $Name), @('AppVendor', $AppVendor), @('AppName', $AppName), @('AppVersion', $AppVersion), @('Author', $Author), @('Changelog', $Changelog))) {
    Assert-NoTokenLeak ([string]$pair[1]) $pair[0]
}
if (-not (Test-Path -LiteralPath $DriverSource)) { throw "DriverSource not found: $DriverSource" }

# --- Classify BEFORE anything is scaffolded -------------------------------------------------------
$trust = & (Join-Path $PSScriptRoot 'Get-DriverSignatureInfo.ps1') -Path $DriverSource -AssumeSecureBootOff:$AssumeSecureBootOff
if ($trust.Overall -eq 'RED' -and @($trust.Drivers | Where-Object { $_.Classification -eq 'Unsigned' }).Count) {
    $msg = "Cannot build a driver package from unsigned drivers.`n`n" +
           (($trust.Hints) -join "`n") + "`n`nOptions:`n" +
           (($trust.Options | ForEach-Object -Begin { $i = 0 } -Process { $i++; "  $i) $_" }) -join "`n")
    throw $msg
}
if ($trust.Overall -eq 'RED') {
    $msg = "Refusing to build this package:`n" + (($trust.Hints) -join "`n") +
           "`n`nIf this fleet genuinely runs without Secure Boot, re-run with -AssumeSecureBootOff - the reason is then recorded in the manifest under driverTrust."
    throw $msg
}

# Default the certificate owner from the classification instead of asking.
if (-not $PSBoundParameters.ContainsKey('CertOwner')) { $CertOwner = [string]$trust.SuggestedCertOwner }
if ([string]::IsNullOrWhiteSpace($CertOwner)) { $CertOwner = 'none' }

$vendorSigner = @($trust.Drivers | Where-Object { $_.Classification -eq 'VendorSigned' } | Select-Object -First 1)
$signerThumb  = if ($vendorSigner) { [string]$vendorSigner[0].SignerThumbprint } else { '' }
$signerSubject = if ($vendorSigner) { [string]$vendorSigner[0].SignerSubject } else { '' }
if ($CertOwner -ne 'none' -and -not $vendorSigner) {
    Write-Warning "-CertOwner '$CertOwner' was requested but no vendor-signed driver was found - nothing to import. Falling back to 'none'."
    $CertOwner = 'none'
}

# --- The driver list the launcher and the detection script share ----------------------------------
# Relative to Files\Drivers so the generated scripts never carry an authoring-machine path.
$srcRoot = (Resolve-Path -LiteralPath $DriverSource).Path
$infRel = foreach ($d in $trust.Drivers) {
    $rel = $d.Path.Substring($srcRoot.Length).TrimStart('\', '/')
    [pscustomobject]@{ Rel = $rel; Inf = $d.Inf; Provider = $d.Provider; DriverVer = $d.DriverVer }
}
# The per-run log name shares the artifact stem, and the sanitizing rule lives in exactly ONE place
# (Get-PsadtPackageManifest -Identity) so a second copy can never drift and rename an app.
$logStem = (& (Join-Path $PSScriptRoot 'Get-PsadtPackageManifest.ps1') -Identity @{ vendor = $AppVendor; name = $AppName; version = $AppVersion; arch = $AppArch }).Stem

function ConvertTo-Literal([string]$s) { "'" + ($s -replace "'", "''") + "'" }
$driverLines = foreach ($d in $infRel) {
    "    @{ Inf = $(ConvertTo-Literal $d.Inf); Rel = $(ConvertTo-Literal $d.Rel); Provider = $(ConvertTo-Literal ([string]$d.Provider)); Version = $(ConvertTo-Literal ([string]$d.DriverVer)) }"
}
$driverLiteral = "@(`r`n" + ($driverLines -join "`r`n") + "`r`n)"

# 1) Scaffold
$pkg = Join-Path $PackageRoot $Name
if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
New-ADTTemplate -Destination $PackageRoot -Name $Name -Force | Out-Null

# 2) Driver payload
$driverDest = Join-Path $pkg 'Files\Drivers'
New-Item $driverDest -ItemType Directory -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $srcRoot '*') -Destination $driverDest -Recurse -Force

# 3) Launcher
$tpl = @'
<#
.SYNOPSIS
    PSADT v4 deployment script - driver package (pnputil staging).
.NOTES
    Author  : __AUTHOR__
    Version : 0.1
    Changelog:
__CHANGELOG__
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
    # 259 = ERROR_NO_MORE_ITEMS: no matching device present, or the device already runs a newer driver.
    # The package IS staged in the DriverStore in both cases, which is exactly the goal.
    AppSuccessExitCodes = @(0, 259)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @()
    AppScriptVersion = '0.1'
    AppScriptDate = '__DATE__'
    AppScriptAuthor = '__AUTHOR__'
    RequireAdmin = $true

    # One log per RUN. PSADT appends to a fixed default name (Toolkit.LogAppend = $true in 4.1.8), so
    # without this every run of every version piles into one file and a failed install is unreadable.
    # $DeploymentType has no default in this launcher, hence the inline guard. Sanitizing already happened
    # when this file was generated; Get-Date runs on the client.
    LogName = ('__LOGSTEM__' + '_' + $(if ($DeploymentType) { $DeploymentType } else { 'Install' }) + '_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

    InstallName = ''
    InstallTitle = ''

    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.1.8'
}

## Single source of truth for all three hooks AND the detection script: the driver packages to stage.
## Rel is relative to Files\Drivers; Provider + Version are what the uninstall matches on.
$DriverPackages = __DRIVERLITERAL__

## Where the signer certificate is owned: 'policy' (Intune profile), 'package' (this script), 'none'.
$CertOwner = '__CERTOWNER__'
$SignerThumbprint = '__SIGNERTHUMB__'

function Install-ADTDeployment
{
    ##================================================
    ## MARK: Pre-Install
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    if ($CertOwner -eq 'package')
    {
        Import-ADTTrustedPublisherCert -DriversRoot "$($adtSession.DirFiles)\Drivers" -Thumbprint $SignerThumbprint
    }

    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    $rebootNeeded = $false
    foreach ($d in $DriverPackages)
    {
        $result = Add-ADTDriverPackage -InfPath "$($adtSession.DirFiles)\Drivers\$($d.Rel)"
        if ($result.RebootRequired) { $rebootNeeded = $true }
    }
    if ($rebootNeeded) { $adtSession.SetExitCode(3010) }

    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    $staged = Get-ADTStagedDriver -DriverPackages $DriverPackages
    Write-ADTLogEntry -Message "Staged $($staged.Count) of $($DriverPackages.Count) driver package(s) in the DriverStore."
}

function Uninstall-ADTDeployment
{
    ##================================================
    ## MARK: Pre-Uninstall
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    ##================================================
    ## MARK: Uninstall
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    $rebootNeeded = $false
    foreach ($d in $DriverPackages)
    {
        $result = Remove-ADTDriverPackage -Inf $d.Inf -Provider $d.Provider -Version $d.Version
        if ($result.RebootRequired) { $rebootNeeded = $true }
    }
    if ($rebootNeeded) { $adtSession.SetExitCode(3010) }

    ##================================================
    ## MARK: Post-Uninstall
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## Only remove the certificate when THIS package owns it - an Intune policy owner keeps it.
    if ($CertOwner -eq 'package' -and $SignerThumbprint)
    {
        $certPath = "Cert:\LocalMachine\TrustedPublisher\$SignerThumbprint"
        if (Test-Path $certPath)
        {
            Remove-Item $certPath -Force -ErrorAction SilentlyContinue
            Write-ADTLogEntry -Message "Removed the signer certificate $SignerThumbprint from TrustedPublisher."
        }
    }
}

function Repair-ADTDeployment
{
    ##================================================
    ## MARK: Pre-Repair
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    if ($CertOwner -eq 'package')
    {
        Import-ADTTrustedPublisherCert -DriversRoot "$($adtSession.DirFiles)\Drivers" -Thumbprint $SignerThumbprint
    }

    ##================================================
    ## MARK: Repair
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## Re-adding is idempotent: pnputil replaces the staged package or reports 259.
    $rebootNeeded = $false
    foreach ($d in $DriverPackages)
    {
        $result = Add-ADTDriverPackage -InfPath "$($adtSession.DirFiles)\Drivers\$($d.Rel)"
        if ($result.RebootRequired) { $rebootNeeded = $true }
    }
    if ($rebootNeeded) { $adtSession.SetExitCode(3010) }

    ##================================================
    ## MARK: Post-Repair
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"
}

##================================================
## MARK: Initialization
##================================================

try
{
    $moduleName = if ([System.IO.File]::Exists("$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1")) { "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" } else { 'PSAppDeployToolkit' }
    Remove-Module -Name PSAppDeployToolkit* -Force
    Import-Module -FullyQualifiedName @{ ModuleName = $moduleName; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.0' } -Force
    try
    {
        $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
        $null = Get-Item -LiteralPath $moduleName -ErrorAction Ignore | Split-Path -Parent | Get-ChildItem -Filter PSAppDeployToolkit.Extensions -Directory -ErrorAction Ignore | Import-Module -Force -PassThru
        $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
    }
    catch
    {
        Remove-Module -Name PSAppDeployToolkit* -Force
        throw
    }
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
    Get-Item -Path $PSScriptRoot\PSAppDeployToolkit.* | & {
        process
        {
            Get-ChildItem -LiteralPath $_.FullName -File | Unblock-File -ErrorAction Ignore
            Import-Module -Name $_.FullName -Force
        }
    }
    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch
{
    Write-ADTLogEntry -Message ($mainErrorMessage = Resolve-ADTErrorRecord -ErrorRecord $_) -Severity 3
    Show-ADTDialogBox -Text $mainErrorMessage -Icon Stop | Out-Null
    Close-ADTSession -ExitCode 60001
}
'@

$out = $tpl.
    Replace('__APPVENDOR__', (Get-SqEscaped $AppVendor)).
    Replace('__APPNAME__', (Get-SqEscaped $AppName)).
    Replace('__APPVERSION__', (Get-SqEscaped $AppVersion)).
    Replace('__APPARCH__', (Get-SqEscaped $AppArch)).
    Replace('__LOGSTEM__', $logStem).
    Replace('__CERTOWNER__', $CertOwner).
    Replace('__SIGNERTHUMB__', (Get-SqEscaped $signerThumb)).
    Replace('__AUTHOR__', (Get-SqEscaped $Author)).
    Replace('__DATE__', $today).
    Replace('__CHANGELOG__', $Changelog).
    Replace('__DRIVERLITERAL__', $driverLiteral)

[System.IO.File]::WriteAllText("$pkg\Invoke-AppDeployToolkit.ps1", $out, [System.Text.UTF8Encoding]::new($true))

# 4) Extensions module - the pnputil mechanics live here, not in the launcher.
$ext = @'
<#
    PSAppDeployToolkit.Extensions - driver-package helpers.

    pnputil is the only supported way to stage a driver package into the DriverStore from a SYSTEM context.
    Everything here works per INF: `pnputil /add-driver *.inf /subdirs /install` exists, but Microsoft
    documents its aggregate exit code as unreliable, and "one INF of six failed but the batch returned 0"
    is the worst possible outcome for a driver deployment.
#>

function Add-ADTDriverPackage
{
    <#
    .SYNOPSIS
        Stages ONE driver package into the DriverStore and installs it on matching devices.
    .DESCRIPTION
        Exit codes treated as success:
          0    added (and installed on matching devices)
          259  ERROR_NO_MORE_ITEMS - no matching device present, OR the device already uses a newer
               driver. The package is staged either way, which is what a driver package is for.
          3010 staged, reboot required -> the caller raises 3010 to Intune.
        Anything else is a failure and is logged with the code, because the two that actually happen are
        0xE000022F (ERROR_NO_CATALOG_FOR_OEM_INF - unsigned or missing .cat) and 0xE0000247
        (ERROR_DRIVER_STORE_ADD_FAILED - generic, in practice an untrusted publisher).
    #>
    param
    (
        [Parameter(Mandatory = $true)][System.String]$InfPath
    )

    if (-not (Test-Path -LiteralPath $InfPath))
    {
        Write-ADTLogEntry -Message "Driver INF not found: $InfPath" -Severity 3
        throw "Driver INF not found: $InfPath"
    }

    $leaf = Split-Path -Leaf $InfPath
    Write-ADTLogEntry -Message "pnputil /add-driver '$leaf' /install"
    $p = Start-ADTProcess -FilePath "$env:SystemRoot\System32\pnputil.exe" `
        -ArgumentList "/add-driver `"$InfPath`" /install" `
        -SuccessExitCodes @(0, 259, 3010) -CreateNoWindow -PassThru

    $code = [int]$p.ExitCode
    switch ($code)
    {
        0    { Write-ADTLogEntry -Message "$leaf added and installed." }
        259  { Write-ADTLogEntry -Message "$leaf staged; no matching device present or the device already uses a newer driver (259)." }
        3010 { Write-ADTLogEntry -Message "$leaf staged; a reboot is required (3010)." }
        default { Write-ADTLogEntry -Message "$leaf FAILED with pnputil exit code $code (0x$('{0:X8}' -f $code))." -Severity 3 }
    }
    return [PSCustomObject]@{ Inf = $leaf; ExitCode = $code; RebootRequired = ($code -eq 3010) }
}

function Remove-ADTDriverPackage
{
    <#
    .SYNOPSIS
        Removes a staged driver package, resolved by its ORIGINAL name instead of a guessed oemNN.inf.
    .DESCRIPTION
        Windows renames every third-party INF to oemNN.inf in the DriverStore, and the number depends on
        the machine's history - deleting oem12.inf because it was oem12.inf on the build machine is how you
        remove someone else's driver. So: enumerate, match on Original Name (+ Provider and Version when
        they are known), then delete what was actually found.
    #>
    param
    (
        [Parameter(Mandatory = $true)][System.String]$Inf,
        [Parameter(Mandatory = $false)][System.String]$Provider,
        [Parameter(Mandatory = $false)][System.String]$Version
    )

    $enum = & "$env:SystemRoot\System32\pnputil.exe" /enum-drivers 2>&1 | Out-String
    $blocks = $enum -split '(?m)^\s*Published Name:\s*' | Where-Object { $_ -match '\S' }

    $published = $null
    $rebootRequired = $false
    foreach ($b in $blocks)
    {
        $lines = $b -split "`r?`n"
        $pub = ($lines[0]).Trim()
        $orig = ($lines | Where-Object { $_ -match '^\s*Original Name:\s*(.+)$' } | Select-Object -First 1)
        $prov = ($lines | Where-Object { $_ -match '^\s*Provider Name:\s*(.+)$' } | Select-Object -First 1)
        $ver  = ($lines | Where-Object { $_ -match '^\s*Driver Version:\s*(.+)$' } | Select-Object -First 1)

        $origName = if ($orig -match '^\s*Original Name:\s*(.+)$') { $Matches[1].Trim() } else { '' }
        $provName = if ($prov -match '^\s*Provider Name:\s*(.+)$') { $Matches[1].Trim() } else { '' }
        $verText  = if ($ver  -match '^\s*Driver Version:\s*(.+)$') { $Matches[1].Trim() } else { '' }

        if ($origName -ne $Inf) { continue }
        if ($Provider -and $provName -and $provName -ne $Provider) { continue }
        if ($Version  -and $verText -and $verText -notlike "*$Version*") { continue }
        $published = $pub
        break
    }

    if (-not $published)
    {
        Write-ADTLogEntry -Message "Driver '$Inf' is not staged (nothing to remove)."
        return [PSCustomObject]@{ Inf = $Inf; Published = $null; ExitCode = 0; RebootRequired = $false }
    }

    Write-ADTLogEntry -Message "pnputil /delete-driver '$published' (original '$Inf') /uninstall /force"
    $p = Start-ADTProcess -FilePath "$env:SystemRoot\System32\pnputil.exe" `
        -ArgumentList "/delete-driver `"$published`" /uninstall /force" `
        -SuccessExitCodes @(0, 259, 3010) -CreateNoWindow -PassThru

    $code = [int]$p.ExitCode
    if ($code -eq 3010) { $rebootRequired = $true }
    if ($code -notin @(0, 259, 3010))
    {
        Write-ADTLogEntry -Message "Removing '$published' FAILED with pnputil exit code $code (0x$('{0:X8}' -f $code))." -Severity 3
    }
    return [PSCustomObject]@{ Inf = $Inf; Published = $published; ExitCode = $code; RebootRequired = $rebootRequired }
}

function Get-ADTStagedDriver
{
    <#
    .SYNOPSIS
        Returns the driver packages from the list that are currently staged in the DriverStore.
    .DESCRIPTION
        Get-WindowsDriver -Online lists THIRD-PARTY drivers only (without -All), which is exactly the set a
        driver package cares about. Its OriginalFileName is the FULL DriverStore path, so the comparison
        has to be on the leaf - matching the full path never succeeds.
    #>
    param
    (
        [Parameter(Mandatory = $true)]$DriverPackages
    )

    $online = @()
    try { $online = @(Get-WindowsDriver -Online -ErrorAction Stop) }
    catch { Write-ADTLogEntry -Message "Get-WindowsDriver failed: $($_.Exception.Message)" -Severity 2; return @() }

    $found = @()
    foreach ($d in $DriverPackages)
    {
        $hit = $online | Where-Object { (Split-Path -Leaf ([string]$_.OriginalFileName)) -eq $d.Inf } | Select-Object -First 1
        if ($hit) { $found += $d.Inf }
    }
    return $found
}

function Import-ADTTrustedPublisherCert
{
    <#
    .SYNOPSIS
        Imports the driver signer certificate into LocalMachine\TrustedPublisher.
    .DESCRIPTION
        Only used when the PACKAGE owns the certificate (-CertOwner package). With -CertOwner policy an
        Intune Custom OMA-URI profile owns it and this is never called - two owners fight on uninstall.
        The certificate is taken from the driver's own catalog, so nothing extra has to be bundled.
    #>
    param
    (
        [Parameter(Mandatory = $true)][System.String]$DriversRoot,
        [Parameter(Mandatory = $false)][System.String]$Thumbprint
    )

    if ($Thumbprint -and (Test-Path "Cert:\LocalMachine\TrustedPublisher\$Thumbprint"))
    {
        Write-ADTLogEntry -Message "Signer certificate $Thumbprint is already in TrustedPublisher."
        return
    }

    $cat = Get-ChildItem -LiteralPath $DriversRoot -Filter '*.cat' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cat)
    {
        Write-ADTLogEntry -Message "No .cat found under $DriversRoot - cannot import a signer certificate." -Severity 3
        return
    }

    $sig = Get-AuthenticodeSignature -FilePath $cat.FullName
    if (-not $sig.SignerCertificate)
    {
        Write-ADTLogEntry -Message "The catalog $($cat.Name) carries no signer certificate." -Severity 3
        return
    }

    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'LocalMachine')
    try
    {
        $store.Open('ReadWrite')
        $store.Add($sig.SignerCertificate)
        Write-ADTLogEntry -Message "Imported signer certificate $($sig.SignerCertificate.Thumbprint) into TrustedPublisher."
    }
    finally { $store.Close() }
}
'@

$extDir = Join-Path $pkg 'PSAppDeployToolkit.Extensions'
New-Item $extDir -ItemType Directory -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $extDir 'PSAppDeployToolkit.Extensions.psm1'), $ext, [System.Text.UTF8Encoding]::new($true))
$psd1 = Join-Path $extDir 'PSAppDeployToolkit.Extensions.psd1'
if (Test-Path $psd1) {
    $manifestText = Get-Content -LiteralPath $psd1 -Raw
    [System.IO.File]::WriteAllText($psd1, $manifestText.Replace('__AUTHOR__', (Get-SqEscaped $Author)), [System.Text.UTF8Encoding]::new($true))
}

# 5) Detection script
$detect = @'
# Detect-__NAME__.ps1 - Intune detection for __APPNAME__ (__APPVERSION__)
# Installed = every driver package of this app is staged in the DriverStore.
# Contract: stdout + exit 0 when installed; NOTHING and exit 0 when not (a non-zero exit reads as a
# detection error, not as "absent").
$DriverPackages = __DRIVERLITERAL__

try {
    # Third-party drivers only (no -All), which is exactly the set this package installs. OriginalFileName
    # is the FULL DriverStore path, so compare on the leaf.
    $online = @(Get-WindowsDriver -Online -ErrorAction Stop)
} catch {
    # Cannot tell -> report "not installed" rather than a detection error.
    exit 0
}

$missing = @()
foreach ($d in $DriverPackages) {
    $hit = $online | Where-Object { (Split-Path -Leaf ([string]$_.OriginalFileName)) -eq $d.Inf } | Select-Object -First 1
    if (-not $hit) { $missing += $d.Inf }
}

if ($missing.Count -eq 0) {
    Write-Output ("Detected: " + $DriverPackages.Count + " driver package(s) staged (__APPVERSION__)")
    exit 0
}
exit 0
'@
$detect = $detect.
    Replace('__NAME__', $Name).
    Replace('__APPNAME__', $AppName).
    Replace('__APPVERSION__', $AppVersion).
    Replace('__DRIVERLITERAL__', $driverLiteral)
[System.IO.File]::WriteAllText("$pkg\Detect-$Name.ps1", $detect, [System.Text.UTF8Encoding]::new($true))

# 6) Manifest - identity, package type and the driver-trust decision
& (Join-Path $PSScriptRoot 'Set-PsadtPackageManifest.ps1') -PackagePath $pkg -Updates @{
    'app.vendor'             = $AppVendor
    'app.name'               = $AppName
    'app.version'            = $AppVersion
    'app.arch'               = $AppArch
    'app.lang'               = 'EN'
    'app.revision'           = 1
    'package.name'           = $logStem
    'package.type'           = 'driver'
    'package.installerTech'  = 'pnputil'
    'package.sourceStrategy' = 'bundle'
    'driverTrust'            = @{
        classification      = [string]$trust.Overall
        owner               = $CertOwner
        thumbprint          = $signerThumb
        signer              = $signerSubject
        assumeSecureBootOff = [bool]$AssumeSecureBootOff
        drivers             = @($trust.Drivers | ForEach-Object {
            @{ inf = $_.Inf; classification = $_.Classification; kernelMode = $_.KernelMode; provider = $_.Provider; version = $_.DriverVer }
        })
    }
} | Out-Null

Write-Output "PACKAGE_OK: $pkg"
Write-Output "Driver trust: $($trust.Overall); certificate owner: $CertOwner"
if ($CertOwner -eq 'policy' -and $signerThumb) {
    Write-Output "Next: create the TrustedPublisher policy and assign it to the SAME scope as the app:"
    Write-Output "  pwsh scripts/New-IntuneTrustedCertPolicy.ps1 -CertThumbprint $signerThumb -Store TrustedPublisher"
}
Write-Output "Then: Phase 5 pre-flight (scripts/Invoke-PsadtPreflight.ps1 -PackagePath '$pkg') -> Phase 6 SYSTEM test -> Phase 7 package."

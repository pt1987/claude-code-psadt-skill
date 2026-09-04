#Requires -Modules PSAppDeployToolkit
<#
    New-WindowsFeaturePackage.ps1 - reusable PSADT v4.1.8 generator for Windows-feature packages.

    Enables additional Windows features as an Intune Win32 app, covering BOTH mechanisms:
      - Optional Features (DISM): Enable-WindowsOptionalFeature  (e.g. NetFx3, Microsoft-Hyper-V-All,
        Microsoft-Windows-Subsystem-Linux, TelnetClient)
      - Capabilities / Features on Demand: Add-WindowsCapability  (e.g. Rsat.*~~~~0.0.1.0, OpenSSH.Client~~~~0.0.1.0)

    Feature-only package: no vendor installer. `Files\` is empty unless you bundle an offline source (e.g. the
    NetFx3 SxS cabs from a Windows ISO under Files\sxs). Install enables, Uninstall reverts (disable/remove),
    Repair re-applies. Content comes from a bundled -Source when present, otherwise from Windows Update with a
    temporary WSUS bypass that is restored afterwards.

    English/ASCII only in all generated script content (encoding cleanliness). See guide Appendix P.

    .PARAMETER Features
    Array of hashtables, one per feature:
        @{ Type='OptionalFeature'; Name='NetFx3'; Source='sxs' }   # Source optional: a relative path under Files\
        @{ Type='OptionalFeature'; Name='TelnetClient' }
        @{ Type='Capability';      Name='Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0' }
    Type must be 'OptionalFeature' or 'Capability'. Source is optional (offline content); without it the feature
    is pulled from Windows Update.

    .EXAMPLE
    $feats = @(
        @{ Type='OptionalFeature'; Name='NetFx3' }
        @{ Type='Capability';      Name='Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0' }
    )
    & scripts/New-WindowsFeaturePackage.ps1 -Name 'WinFeatures-NetFx3-RSATAD' `
        -AppName 'Windows Features: .NET 3.5 + RSAT AD' -Features $feats
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,                 # package folder + scaffold name (path-safe)
    [Parameter(Mandatory)][string]$AppName,              # display name in $adtSession
    [string]$AppVersion = '1.0',
    [Parameter(Mandatory)][hashtable[]]$Features,        # see .PARAMETER Features
    [string]$AppVendor = 'Windows Features',
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

# --- Validate + normalize the feature list --------------------------------------------------------
$norm = foreach ($f in $Features) {
    $type = [string]$f.Type
    if ($type -ne 'OptionalFeature' -and $type -ne 'Capability') {
        throw "Feature '$($f.Name)': Type must be 'OptionalFeature' or 'Capability' (got '$type')."
    }
    if ([string]::IsNullOrWhiteSpace([string]$f.Name)) { throw "Each feature needs a Name." }
    $f
}

# --- Render the shared $WindowsFeatures literal (used by launcher AND detection) ------------------
function ConvertTo-Literal([string]$s) { "'" + ($s -replace "'", "''") + "'" }
$lines = foreach ($f in $norm) {
    $parts = @("Type = $(ConvertTo-Literal ([string]$f.Type))", "Name = $(ConvertTo-Literal ([string]$f.Name))")
    if (-not [string]::IsNullOrWhiteSpace([string]$f.Source)) { $parts += "Source = $(ConvertTo-Literal ([string]$f.Source))" }
    "    @{ " + ($parts -join '; ') + " }"
}
$featLiteral = "@(`r`n" + ($lines -join "`r`n") + "`r`n)"

# 1) Scaffold
$pkg = Join-Path $PackageRoot $Name
if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
New-ADTTemplate -Destination $PackageRoot -Name $Name -Force | Out-Null

# 2) Launcher
$tpl = @'
<#
.SYNOPSIS
PSAppDeployToolkit - Enables / reverts Windows features for __APPNAME__.
.DESCRIPTION
Feature-only package (no vendor installer): enables Windows Optional Features (Enable-WindowsOptionalFeature)
and/or Capabilities/FoD (Add-WindowsCapability). Three deployment types (Install / Uninstall / Repair) for
Intune Win32 (PSADT v4.1.8). Custom helpers live in PSAppDeployToolkit.Extensions.
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

    # One log per RUN. PSADT appends to a fixed default name (Toolkit.LogAppend = $true in 4.1.8), so
    # without this every run of every version piles into one file and a failed install is unreadable.
    # $DeploymentType has no default in this launcher, hence the inline guard. Sanitizing already happened
    # when this file was generated; Get-Date runs on the client.
    LogName = ('__LOGSTEM__' + '_' + $(if ($DeploymentType) { $DeploymentType } else { 'Install' }) + '_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    AppSuccessExitCodes = @(0, 1707)
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

## Single source of truth for all three hooks + the detection script: the managed Windows features.
## Each entry: Type = 'OptionalFeature' (Enable/Disable-WindowsOptionalFeature) or 'Capability'
## (Add/Remove-WindowsCapability); Name = exact feature/capability name; optional Source = a relative path
## under Files\ holding offline content (e.g. NetFx3 SxS cabs). Without Source the feature is pulled from
## Windows Update (the install hook temporarily enables WU FoD access and restores it afterwards).
$script:WindowsFeatures = __FEATLITERAL__

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

    Show-ADTInstallationProgress

    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## If any feature has no bundled source, content must come from Windows Update - temporarily allow that on
    ## WSUS-managed devices, and always restore the prior state in the finally block.
    $restartNeeded = $false
    $wuNeeded = @($script:WindowsFeatures | Where-Object { [string]::IsNullOrWhiteSpace($_.Source) }).Count -gt 0
    try
    {
        ## Set inside the try so the finally always restores the WU/WSUS state, even if Set- itself throws.
        if ($wuNeeded) { Set-ADTWindowsUpdateFodAccess }
        foreach ($f in $script:WindowsFeatures)
        {
            $src = ''
            if (-not [string]::IsNullOrWhiteSpace($f.Source)) { $src = Join-Path -Path $adtSession.DirFiles -ChildPath $f.Source }
            if (Enable-ADTWindowsFeatureItem -Type $f.Type -Name $f.Name -SourcePath $src) { $restartNeeded = $true }
        }
    }
    finally
    {
        if ($wuNeeded) { Restore-ADTWindowsUpdateFodAccess }
    }

    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    if ($restartNeeded)
    {
        Write-ADTLogEntry -Message 'One or more features require a restart; returning 3010 (soft reboot).'
        $adtSession.SetExitCode(3010)
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

    Show-ADTInstallationProgress

    ##================================================
    ## MARK: Uninstall
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## Revert: disable optional features / remove capabilities. NOTE: a feature shared with other software is
    ## disabled here too - scope the assignment accordingly.
    $restartNeeded = $false
    foreach ($f in $script:WindowsFeatures)
    {
        if (Disable-ADTWindowsFeatureItem -Type $f.Type -Name $f.Name) { $restartNeeded = $true }
    }

    ##================================================
    ## MARK: Post-Uninstall
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    if ($restartNeeded)
    {
        Write-ADTLogEntry -Message 'One or more features require a restart to finish removal; returning 3010.'
        $adtSession.SetExitCode(3010)
    }
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

    ## Idempotent re-enable (same as install). Helpers skip features already in the target state.
    $restartNeeded = $false
    $wuNeeded = @($script:WindowsFeatures | Where-Object { [string]::IsNullOrWhiteSpace($_.Source) }).Count -gt 0
    try
    {
        ## Set inside the try so the finally always restores the WU/WSUS state, even if Set- itself throws.
        if ($wuNeeded) { Set-ADTWindowsUpdateFodAccess }
        foreach ($f in $script:WindowsFeatures)
        {
            $src = ''
            if (-not [string]::IsNullOrWhiteSpace($f.Source)) { $src = Join-Path -Path $adtSession.DirFiles -ChildPath $f.Source }
            if (Enable-ADTWindowsFeatureItem -Type $f.Type -Name $f.Name -SourcePath $src) { $restartNeeded = $true }
        }
    }
    finally
    {
        if ($wuNeeded) { Restore-ADTWindowsUpdateFodAccess }
    }

    ##================================================
    ## MARK: Post-Repair
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    if ($restartNeeded) { $adtSession.SetExitCode(3010) }
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

if (-not $Changelog) { $Changelog = "- 0.1 ($today, $Author): Initial version - enable Windows features (optional features + capabilities)." }

$out = $tpl.
    Replace('__APPVENDOR__', (Get-SqEscaped $AppVendor)).
    Replace('__APPNAME__', (Get-SqEscaped $AppName)).
# The per-run log name shares the artifact stem, and the sanitizing rule lives in exactly ONE place
# (Get-PsadtPackageManifest -Identity) so a second copy can never drift and rename an app.
$logStem = (& (Join-Path $PSScriptRoot 'Get-PsadtPackageManifest.ps1') -Identity @{ vendor = $AppVendor; name = $AppName; version = $AppVersion; arch = 'x64' }).Stem
    Replace('__APPVERSION__', (Get-SqEscaped $AppVersion)).
    Replace('__LOGSTEM__', $logStem).
    Replace('__AUTHOR__', (Get-SqEscaped $Author)).
    Replace('__DATE__', $today).
    Replace('__CHANGELOG__', $Changelog).
    Replace('__FEATLITERAL__', $featLiteral)

[System.IO.File]::WriteAllText("$pkg\Invoke-AppDeployToolkit.ps1", $out, [System.Text.UTF8Encoding]::new($true))

# 3) Extensions module (enable/disable dispatch + WU FoD access save/restore). Overwrite the template stub.
$extModuleDir = Join-Path $pkg 'PSAppDeployToolkit.Extensions'
if (-not (Test-Path -LiteralPath $extModuleDir)) { New-Item -ItemType Directory -Path $extModuleDir -Force | Out-Null }
$psd1 = Join-Path $extModuleDir 'PSAppDeployToolkit.Extensions.psd1'
if (-not (Test-Path -LiteralPath $psd1)) {
    $manifest = @'
@{
    RootModule = 'PSAppDeployToolkit.Extensions.psm1'
    ModuleVersion = '1.0.0'
    GUID = '7e2b1a4c-3d5f-4e6a-9b8c-1f0d2e3a4b5c'
    Author = '__AUTHOR__'
    Description = 'PSAppDeployToolkit extension helpers for Windows-feature packages.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Enable-ADTWindowsFeatureItem', 'Disable-ADTWindowsFeatureItem', 'Set-ADTWindowsUpdateFodAccess', 'Restore-ADTWindowsUpdateFodAccess')
}
'@
    [System.IO.File]::WriteAllText($psd1, $manifest.Replace('__AUTHOR__', (Get-SqEscaped $Author)), [System.Text.UTF8Encoding]::new($true))
}

$psm1 = @'
<#
.SYNOPSIS
PSAppDeployToolkit.Extensions - Windows-feature helpers (Optional Features + Capabilities/FoD).
.DESCRIPTION
Enable/disable dispatch for Enable-WindowsOptionalFeature / Add-WindowsCapability, plus a temporary
Windows-Update Features-on-Demand access toggle (WSUS bypass) that records and restores the prior state.
See guide Appendix P.
#>

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

# Saved prior state for the WU FoD access toggle (module-scoped, set by Set- and consumed by Restore-).
$script:AdtFodSaved = @()

function Enable-ADTWindowsFeatureItem
{
    <#
    .SYNOPSIS
        Enables one Windows optional feature or capability (idempotent). Returns $true if a restart is needed.
    .PARAMETER Type
        'OptionalFeature' or 'Capability'.
    .PARAMETER Name
        Exact feature name (e.g. NetFx3) or capability name (e.g. Rsat.Dns.Tools~~~~0.0.1.0).
    .PARAMETER SourcePath
        Optional path to offline content (e.g. SxS cabs). If it exists, -Source + -LimitAccess is used;
        otherwise the feature is pulled from Windows Update.
    #>
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [Parameter(Mandatory)][ValidateSet('OptionalFeature', 'Capability')][System.String]$Type,
        [Parameter(Mandatory)][System.String]$Name,
        [Parameter()][System.String]$SourcePath = ''
    )

    begin { Initialize-ADTFunction -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState }

    process
    {
        try
        {
            try
            {
                $useSource = (-not [string]::IsNullOrWhiteSpace($SourcePath)) -and (Test-Path -LiteralPath $SourcePath)
                if ($Type -eq 'OptionalFeature')
                {
                    $state = (Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction SilentlyContinue).State
                    if ($state -eq 'Enabled') { Write-ADTLogEntry -Message "Optional feature [$Name] already Enabled; skipping."; return $false }
                    $p = @{ Online = $true; FeatureName = $Name; All = $true; NoRestart = $true; ErrorAction = 'Stop' }
                    if ($useSource) { $p.Source = $SourcePath; $p.LimitAccess = $true; Write-ADTLogEntry -Message "Enabling optional feature [$Name] from bundled source [$SourcePath]." }
                    else { Write-ADTLogEntry -Message "Enabling optional feature [$Name] from Windows Update." }
                    $r = Enable-WindowsOptionalFeature @p
                }
                else
                {
                    $state = (Get-WindowsCapability -Online -Name $Name -ErrorAction SilentlyContinue).State
                    if ($state -eq 'Installed') { Write-ADTLogEntry -Message "Capability [$Name] already Installed; skipping."; return $false }
                    $p = @{ Online = $true; Name = $Name; ErrorAction = 'Stop' }
                    if ($useSource) { $p.Source = $SourcePath; $p.LimitAccess = $true; Write-ADTLogEntry -Message "Adding capability [$Name] from bundled source [$SourcePath]." }
                    else { Write-ADTLogEntry -Message "Adding capability [$Name] from Windows Update." }
                    $r = Add-WindowsCapability @p
                }
                $restart = [bool]($r -and $r.RestartNeeded)
                Write-ADTLogEntry -Message "[$Name] processed (RestartNeeded=$restart)."
                return $restart
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

function Disable-ADTWindowsFeatureItem
{
    <#
    .SYNOPSIS
        Disables one optional feature / removes one capability (idempotent). Returns $true if a restart is needed.
    .PARAMETER Type
        'OptionalFeature' or 'Capability'.
    .PARAMETER Name
        Exact feature/capability name.
    #>
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [Parameter(Mandatory)][ValidateSet('OptionalFeature', 'Capability')][System.String]$Type,
        [Parameter(Mandatory)][System.String]$Name
    )

    begin { Initialize-ADTFunction -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState }

    process
    {
        try
        {
            try
            {
                if ($Type -eq 'OptionalFeature')
                {
                    $state = (Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction SilentlyContinue).State
                    if ($state -ne 'Enabled' -and $state -ne 'EnablePending') { Write-ADTLogEntry -Message "Optional feature [$Name] not Enabled; nothing to disable."; return $false }
                    Write-ADTLogEntry -Message "Disabling optional feature [$Name]."
                    $r = Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction Stop
                }
                else
                {
                    $state = (Get-WindowsCapability -Online -Name $Name -ErrorAction SilentlyContinue).State
                    if ($state -ne 'Installed') { Write-ADTLogEntry -Message "Capability [$Name] not Installed; nothing to remove."; return $false }
                    Write-ADTLogEntry -Message "Removing capability [$Name]."
                    $r = Remove-WindowsCapability -Online -Name $Name -ErrorAction Stop
                }
                return [bool]($r -and $r.RestartNeeded)
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

function Set-ADTWindowsUpdateFodAccess
{
    <#
    .SYNOPSIS
        Temporarily allows Features-on-Demand / optional-feature content to come from Windows Update on
        WSUS-managed devices. Records the prior state so Restore-ADTWindowsUpdateFodAccess can undo it exactly.
    .DESCRIPTION
        Sets RepairContentServerSource=2 (Policies\Servicing) and UseWUServer=0 (WindowsUpdate\AU), then
        restarts wuauserv so the change takes effect. Without this, an Add-WindowsCapability / NetFx3 enable on
        a WSUS-bound device fails to fetch content (0x800f0950 / 0x800f081f).
    #>
    [CmdletBinding()]
    param
    (
    )

    begin { Initialize-ADTFunction -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState }

    process
    {
        try
        {
            try
            {
                $script:AdtFodSaved = @()
                $targets = @(
                    [pscustomobject]@{ Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing'; Name = 'RepairContentServerSource'; Value = 2 }
                    [pscustomobject]@{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU';          Name = 'UseWUServer';               Value = 0 }
                )
                # Phase 1: record the prior state of EVERY target before changing anything, so a partial write
                # (e.g. the 2nd New-ItemProperty throws on a locked key) is still fully reversible by Restore-.
                foreach ($t in $targets)
                {
                    $keyExisted = Test-Path -LiteralPath $t.Key
                    $existed = $false
                    $prior = $null
                    if ($keyExisted)
                    {
                        $cur = Get-ItemProperty -LiteralPath $t.Key -Name $t.Name -ErrorAction SilentlyContinue
                        if ($cur -and $cur.PSObject.Properties[$t.Name]) { $existed = $true; $prior = $cur.$($t.Name) }
                    }
                    $script:AdtFodSaved += [pscustomobject]@{ Key = $t.Key; Name = $t.Name; KeyExisted = $keyExisted; Existed = $existed; Prior = $prior }
                }
                # Phase 2: apply (create the key if needed, then set the value).
                foreach ($t in $targets)
                {
                    if (!(Test-Path -LiteralPath $t.Key)) { New-Item -Path $t.Key -Force | Out-Null }
                    New-ItemProperty -LiteralPath $t.Key -Name $t.Name -Value $t.Value -PropertyType DWord -Force | Out-Null
                    Write-ADTLogEntry -Message "WU FoD access: set [$($t.Key)\$($t.Name)] = $($t.Value)."
                }
                try { Restart-Service -Name wuauserv -Force -ErrorAction SilentlyContinue } catch { }
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

function Restore-ADTWindowsUpdateFodAccess
{
    <#
    .SYNOPSIS
        Restores the exact prior state changed by Set-ADTWindowsUpdateFodAccess (re-set prior value, or remove
        the value if it did not exist before). Keys created by Set- are left in place (harmless, empty policy).
    #>
    [CmdletBinding()]
    param
    (
    )

    begin { Initialize-ADTFunction -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState }

    process
    {
        try
        {
            try
            {
                if (-not $script:AdtFodSaved -or @($script:AdtFodSaved).Count -eq 0) { return }
                foreach ($s in $script:AdtFodSaved)
                {
                    if (-not (Test-Path -LiteralPath $s.Key)) { continue }
                    if ($s.Existed)
                    {
                        New-ItemProperty -LiteralPath $s.Key -Name $s.Name -Value $s.Prior -PropertyType DWord -Force | Out-Null
                        Write-ADTLogEntry -Message "WU FoD access: restored [$($s.Key)\$($s.Name)] = $($s.Prior)."
                    }
                    else
                    {
                        Remove-ItemProperty -LiteralPath $s.Key -Name $s.Name -Force -ErrorAction SilentlyContinue
                        Write-ADTLogEntry -Message "WU FoD access: removed temporary [$($s.Key)\$($s.Name)]."
                    }
                }
                $script:AdtFodSaved = @()
                try { Restart-Service -Name wuauserv -Force -ErrorAction SilentlyContinue } catch { }
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

# 4) Detection script - verifies each feature reached its target state (Enabled / Installed).
$detect = @'
# Detect-__NAME__.ps1 - Intune detection for __APPNAME__ (__APPVERSION__).
# Reports installed only when EVERY managed feature is in its target state (OptionalFeature -> Enabled,
# Capability -> Installed). A feature pending a reboot shows EnablePending and is treated as NOT yet done;
# Intune re-detects after the 3010 reboot. Run as System, 64-bit (Run as 32-bit = No).
# Contract: stdout + exit 0 when all present; otherwise no output + exit 0.

$feats = __FEATLITERAL__

$found = @()
$allOk = $true
foreach ($f in $feats)
{
    if ($f.Type -eq 'OptionalFeature')
    {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $f.Name -ErrorAction SilentlyContinue).State
        if ($state -eq 'Enabled') { $found += "OptionalFeature:$($f.Name)" } else { $allOk = $false }
    }
    else
    {
        $state = (Get-WindowsCapability -Online -Name $f.Name -ErrorAction SilentlyContinue).State
        if ($state -eq 'Installed') { $found += "Capability:$($f.Name)" } else { $allOk = $false }
    }
}

if ($allOk -and $found.Count -gt 0)
{
    Write-Output ("Detected Windows features: " + ($found -join ', '))
    exit 0
}
exit 0
'@
$detect = $detect.
    Replace('__NAME__', $Name).
    Replace('__APPNAME__', $AppName).
    Replace('__APPVERSION__', $AppVersion).
    Replace('__FEATLITERAL__', $featLiteral)
[System.IO.File]::WriteAllText("$pkg\Detect-$Name.ps1", $detect, [System.Text.UTF8Encoding]::new($true))


# The manifest is written by the generator, not left to the operator: the identity that named the log and
# will name the .intunewin has to be recorded where every later phase reads it.
& (Join-Path $PSScriptRoot 'Set-PsadtPackageManifest.ps1') -PackagePath $pkg -Updates @{
    'app.vendor'             = $AppVendor
    'app.name'               = $AppName
    'app.version'            = $AppVersion
    'app.arch'               = 'x64'
    'app.lang'               = 'EN'
    'app.revision'           = 1
    'package.name'           = $logStem
    'package.type'           = 'windows-feature'
    'package.installerTech'  = 'dism'
    'package.sourceStrategy' = 'none'
} | Out-Null

Write-Output "PACKAGE_OK: $pkg"
Write-Output "Next: Phase 5 pre-flight (scripts/Invoke-PsadtPreflight.ps1 -PackagePath '$pkg') -> Phase 7 package -> Phase 8 dossier."

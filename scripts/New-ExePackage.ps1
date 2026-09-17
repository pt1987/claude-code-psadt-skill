#Requires -Modules PSAppDeployToolkit
<#
    New-ExePackage.ps1 - reusable PSADT v4.1.8 package generator for EXE installers
    (Inno Setup, NSIS, InstallShield, electron-builder and the rest of the non-MSI family).

    The MSI family had a generator; this one did not, so every EXE package was hand-scaffolded. That
    cost ~3 minutes of hand-patching and two self-inflicted scripting errors on VS Code 1.138.0
    (2026-09-17) - and, worse, it meant the three lessons below had to be REMEMBERED each time by
    whoever wrote the hooks. They are generated now:

      1. Resolve the uninstaller AT RUN TIME from the ARP entry, never hardcode it. Inno names it
         unins000.exe and increments to unins001.exe if anything else installs into the same folder;
         NSIS uses Uninstall.exe; an MSI-wrapper's ProductCode may be regenerated per build. A path or
         code baked in at build time is a package that works once.
      2. NEVER trust the uninstaller's exit code. Inno documents that it spawns a clone into %TEMP%
         and returns while that clone is still deleting; NSIS behaves the same way. Measured on
         Firefox 156.0: helper.exe /S returned in 116 ms with exit 0 and the entire installation still
         on disk, and PSADT reported a clean uninstall. The generated hook waits for a named path to
         disappear and fails loudly if it does not.
      3. Detect with a version FLOOR over DisplayName, never an equals match on a version or a
         ProductCode. Every self-updating app (VS Code, Firefox, Chrome, Audacity) breaks an equals
         rule on its first background update, and Intune then re-offers a required app forever.

    English/ASCII only in all generated script content (encoding cleanliness).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,            # package folder + scaffold name (path-safe)
    [Parameter(Mandatory)][string]$AppVendor,
    [Parameter(Mandatory)][string]$AppName,         # display name in $adtSession
    [Parameter(Mandatory)][string]$AppVersion,
    [Parameter(Mandatory)][string]$AppArch,         # x64 | x86 | ARM64
    [Parameter(Mandatory)][string]$InstallerFile,   # filename placed into Files\
    [Parameter(Mandatory)][string]$InstallerPath,   # source path of the installer to copy in

    # Silent install switches, engine-specific and VERIFIED - never a guess. Get-PsadtSwitchCandidates.ps1
    # ranks the candidates; a probe run or the vendor's own documentation closes it.
    [Parameter(Mandatory)][string]$InstallArgs,

    # How the ARP DisplayName of THIS product starts. Both the uninstall hook and the detection script
    # resolve the installation through it, so it is mandatory: an EXE installer leaves no ProductCode
    # to fall back on. Example: 'Microsoft Visual Studio Code'.
    [Parameter(Mandatory)][string]$DisplayNameLike,

    # The file that must EXIST after install and be GONE after uninstall, relative to the resolved
    # InstallLocation. This is the honest completion signal for an uninstaller that returns early.
    # Example: 'Code.exe', or 'bin\app.exe'.
    [Parameter(Mandatory)][string]$VerifyRelativePath,

    # Switches for the vendor's own uninstaller. Inno: '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    # (note /SP- is INSTALL-only). NSIS: '/S'.
    #
    # The literal token {InstallDir} is replaced AT RUN TIME with the resolved install location, so an
    # NSIS build that honours '_?=' can be driven correctly without anyone hardcoding a path into the
    # package: pass '/S _?={InstallDir}'. '_?=' makes the uninstaller run in place instead of
    # re-executing a copy of itself from %TEMP%, which is what lets a caller wait for it at all - but
    # it must be the LAST argument and unquoted, and the uninstaller EXE and its folder then survive
    # the removal by design. Point -VerifyRelativePath at the APPLICATION binary, never at the folder.
    [string]$UninstallArgs = '/S',

    # Engine exit codes. These are NOT the MSI ones: Inno has no 3010 and no 1641 - it signals
    # "restart required" with 8. Passing MSI codes to a non-MSI engine declares success for values the
    # installer can never return, and hides the ones it does.
    [int[]]$SuccessExitCodes = @(0),
    [int[]]$RebootExitCodes = @(),

    [string[]]$ProcessesToClose = @(),
    [string]$DesktopShortcutName = '',              # public desktop .lnk to remove post-install
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
function Expand-CommaSeparated([string[]]$Values) {
    # `pwsh scripts/New-ExePackage.ps1 -ProcessesToClose a,b` uses the -File binder, and that binder
    # passes "a,b" as ONE element. Left alone, the scaffold gets one process name that matches nothing,
    # Show-ADTInstallationWelcome -CloseProcesses closes NOTHING and still reports success, and the
    # install runs against a running application. A silent loss beats an error every time.
    if (-not $Values) { return @() }
    return @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
function Assert-NoTokenLeak([string]$value, [string]$paramName) {
    if ($value -match '__[A-Z0-9_]+__') { throw "Parameter '$paramName' must not contain a template placeholder sequence ('$($Matches[0])')." }
}
function Assert-NoUnreplacedToken([string]$content, [string]$file) {
    # A token added to a template but forgotten in its Replace() chain produces a file that looks fine
    # and ships a literal '__TOKEN__' into a detection rule or an uninstall command. It happened here
    # on 2026-09-17 with __VERIFYRELATIVEPATH__ in the detection script, and nothing but reading the
    # generated file would have caught it - so the generator reads it instead.
    if ($content -match '__[A-Z0-9_]+__') {
        throw "Generated $file still contains the unreplaced placeholder '$($Matches[0])' - the template gained a token that its Replace() chain does not cover."
    }
}
if ($Name -match '[\\/:*?"<>|]' -or $Name -match '\.\.') { throw "Name '$Name' must be a simple folder name (no path separators or '..')." }
foreach ($pair in @(@('Name', $Name), @('AppVendor', $AppVendor), @('AppName', $AppName), @('AppVersion', $AppVersion),
        @('Author', $Author), @('InstallArgs', $InstallArgs), @('UninstallArgs', $UninstallArgs),
        @('InstallerFile', $InstallerFile), @('DisplayNameLike', $DisplayNameLike),
        @('VerifyRelativePath', $VerifyRelativePath), @('DesktopShortcutName', $DesktopShortcutName), @('Changelog', $Changelog))) {
    Assert-NoTokenLeak ([string]$pair[1]) $pair[0]
}
if (-not (Test-Path -LiteralPath $InstallerPath)) { throw "InstallerPath not found: $InstallerPath" }
# A GUID here means an MSI was passed to the EXE generator - the MSI route has its own, and mixing them
# produces a package whose uninstall hook looks for a vendor .exe that does not exist.
if ($InstallerFile -match '\.msi$') { throw "InstallerFile '$InstallerFile' is an MSI - use New-MsiPackage.ps1, which can use the ProductCode directly." }

# A helper-function name derived from the package name, so two packages on one machine cannot collide
# in the module scope PSADT imports them into.
$fnToken = ($Name -replace '[^A-Za-z0-9]', '')
if (-not $fnToken) { throw "Name '$Name' yields no usable function-name token." }

# 1) Scaffold
$pkg = Join-Path $PackageRoot $Name
if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
New-ADTTemplate -Destination $PackageRoot -Name $Name -Force | Out-Null

$ProcessesToClose = Expand-CommaSeparated $ProcessesToClose
$procLiteral = if ($ProcessesToClose.Count -gt 0) { "@(" + (($ProcessesToClose | ForEach-Object { "'$(Get-SqEscaped $_)'" }) -join ', ') + ")" } else { "@()" }
$successLiteral = "@(" + (($SuccessExitCodes | Sort-Object -Unique) -join ', ') + ")"
$rebootLiteral = if ($RebootExitCodes.Count) { "@(" + (($RebootExitCodes | Sort-Object -Unique) -join ', ') + ")" } else { "@()" }
$rebootParam = if ($RebootExitCodes.Count) { " -RebootExitCodes " + (($RebootExitCodes | Sort-Object -Unique) -join ', ') } else { '' }
$successParam = " -SuccessExitCodes " + (($SuccessExitCodes | Sort-Object -Unique) -join ', ')

$shortcutBlock = if ($DesktopShortcutName) {
    @"

    ## Remove any desktop shortcut the installer may have created (Start Menu only policy).
    foreach (`$lnk in @("`$env:Public\Desktop\$DesktopShortcutName.lnk"))
    {
        if (Test-Path -LiteralPath `$lnk) { Remove-Item -LiteralPath `$lnk -Force -ErrorAction SilentlyContinue }
    }
"@
} else { '' }

# 2) Launcher
$tpl = @'
<#
.SYNOPSIS
PSAppDeployToolkit - Installs, uninstalls or repairs __APPNAME__.
.DESCRIPTION
Three deployment types (Install / Uninstall / Repair) for Intune Win32 (PSADT v4.1.8).
EXE installer: the uninstaller is resolved at run time and its completion is VERIFIED, never assumed.
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
    LogName = ('__LOGSTEM__' + '_' + $(if ($DeploymentType) { $DeploymentType } else { 'Install' }) + '_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

    # ENGINE exit codes, not MSI ones. A non-MSI installer has its own set - Inno signals a needed
    # restart with 8 and never returns 3010 or 1641 - and declaring MSI codes as success here would
    # accept values this installer cannot produce while ignoring the ones it can.
    AppSuccessExitCodes = __SUCCESSCODES__
    AppRebootExitCodes = __REBOOTCODES__
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

    Start-ADTProcess -FilePath "$($adtSession.DirFiles)\__INSTALLER__" -ArgumentList '__INSTALLARGS__'__EXITPARAMS__

    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"
__SHORTCUTBLOCK__
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

    # Resolves the uninstaller from the ARP entry and waits for the installation to actually disappear.
    # An EXE uninstaller's exit code is not evidence - see the function for what that cost once.
    Uninstall-ADT__FNTOKEN__Native

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

    # Most EXE engines have no repair verb at all. Re-running Setup over an existing installation is
    # the vendor's own upgrade path and restores missing or damaged files in place.
    Start-ADTProcess -FilePath "$($adtSession.DirFiles)\__INSTALLER__" -ArgumentList '__INSTALLARGS__'__EXITPARAMS__
__SHORTCUTBLOCK__
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

$logStem = (& (Join-Path $PSScriptRoot 'Get-PsadtPackageManifest.ps1') -Identity @{ vendor = $AppVendor; name = $AppName; version = $AppVersion; arch = $AppArch }).Stem
$out = $tpl.
    Replace('__APPVENDOR__', (Get-SqEscaped $AppVendor)).
    Replace('__APPNAME__', (Get-SqEscaped $AppName)).
    Replace('__APPVERSION__', (Get-SqEscaped $AppVersion)).
    Replace('__APPARCH__', (Get-SqEscaped $AppArch)).
    Replace('__LOGSTEM__', $logStem).
    Replace('__PROCESSES__', $procLiteral).
    Replace('__SUCCESSCODES__', $successLiteral).
    Replace('__REBOOTCODES__', $rebootLiteral).
    Replace('__EXITPARAMS__', ($successParam + $rebootParam)).
    Replace('__AUTHOR__', (Get-SqEscaped $Author)).
    Replace('__DATE__', $today).
    Replace('__INSTALLER__', (Get-SqEscaped $InstallerFile)).
    Replace('__INSTALLARGS__', (Get-SqEscaped $InstallArgs)).
    Replace('__SHORTCUTBLOCK__', $shortcutBlock).
    Replace('__FNTOKEN__', $fnToken).
    Replace('__CHANGELOG__', $Changelog)

Assert-NoUnreplacedToken $out 'Invoke-AppDeployToolkit.ps1'
[System.IO.File]::WriteAllText("$pkg\Invoke-AppDeployToolkit.ps1", $out, [System.Text.UTF8Encoding]::new($true))

# 3) Extensions module - the run-time resolver and the verified uninstall
$ext = @'
<#

.SYNOPSIS
PSAppDeployToolkit.Extensions - run-time resolver and verified uninstall for __APPNAME__.

.DESCRIPTION
Generated by New-ExePackage.ps1. An EXE installer leaves no ProductCode, so the installation is
resolved through its Add/Remove Programs entry at run time, and the uninstall is verified rather
than believed.

#>

##*===============================================
##* MARK: MODULE GLOBAL SETUP
##*===============================================

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1


##*===============================================
##* MARK: FUNCTION LISTINGS
##*===============================================

function Get-ADT__FNTOKEN__Install
{
    <#
    .SYNOPSIS
        Resolves the per-machine __APPNAME__ installation as it exists RIGHT NOW.

    .DESCRIPTION
        Looked up by DISPLAY NAME, deliberately, because nothing more stable is available: an EXE
        installer registers no ProductCode, Inno's uninstaller is unins000.exe but increments to
        unins001.exe if anything else installs into the same directory, and an installer that wraps
        an MSI may regenerate its ProductCode on every build. Anything baked in at package time is a
        package that works exactly once.

    .OUTPUTS
        PSADT installed-application objects, or nothing when the app is not installed per machine.
    #>

    [CmdletBinding()]
    param
    (
    )

    process
    {
        Get-ADTApplication -Name '__DISPLAYNAMELIKE__' -NameMatch 'Contains'
    }
}


function Uninstall-ADT__FNTOKEN__Native
{
    <#
    .SYNOPSIS
        Silently uninstalls __APPNAME__ and waits until it is really gone.

    .DESCRIPTION
        Runs the uninstaller recorded in the app's own Add/Remove Programs entry, then WAITS for
        __VERIFYRELATIVEPATH__ to disappear beneath the resolved install location.

        The wait is the point. An EXE uninstaller's exit code is not evidence of anything: Inno Setup
        documents that it "creates and spawns a copy of itself in the TEMP directory", the clone does
        the deletion, and the original returns an exit code while that is still running. NSIS behaves
        the same way. Measured on Mozilla Firefox 156.0 (2026-09-16): the vendor uninstaller returned
        in 116 ms with exit code 0 and the entire installation was still on disk - PSADT reported a
        clean uninstall, Intune believed it, and only a file-existence assertion in the sandbox caught
        it. Two VM runs were spent discovering that. No switch defeats the behaviour, so absence of
        the binary is the only honest completion signal.

    .OUTPUTS
        None
    #>

    [CmdletBinding()]
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
                $installed = Get-ADT__FNTOKEN__Install | Select-Object -First 1

                if (-not $installed)
                {
                    Write-ADTLogEntry -Message 'No per-machine __APPNAME__ found - nothing to uninstall.'
                    return
                }

                # Cast before any string operation: PSADT surfaces several of these properties as
                # FileInfo/DirectoryInfo, and .TrimEnd()/-replace on those throws MethodNotFound at
                # run time - invisible to every static check, and one wasted VM run when it happens.
                $raw = if ($installed.QuietUninstallString) { [System.String]$installed.QuietUninstallString }
                elseif ($installed.UninstallString) { [System.String]$installed.UninstallString }
                else { $null }
                $uninstaller = if ($raw) { ($raw -replace '^\s*"?([^"]+\.exe)"?.*$', '$1') } else { $null }

                $installDir = if ($installed.InstallLocation) { ([System.String]$installed.InstallLocation).TrimEnd('\') } else { $null }
                if ((-not $uninstaller -or -not (Test-Path -LiteralPath $uninstaller)) -and $installDir)
                {
                    $candidate = Get-ChildItem -LiteralPath $installDir -Filter 'unins*.exe' -ErrorAction SilentlyContinue |
                        Sort-Object Name -Descending | Select-Object -First 1
                    if ($candidate) { $uninstaller = $candidate.FullName }
                }
                if (-not $installDir -and $uninstaller) { $installDir = Split-Path -Path $uninstaller -Parent }

                if (-not $uninstaller -or -not (Test-Path -LiteralPath $uninstaller))
                {
                    throw "__APPNAME__ is registered as installed but no uninstaller could be resolved (UninstallString='$raw', InstallLocation='$installDir')."
                }

                $verify = Join-Path -Path $installDir -ChildPath '__VERIFYRELATIVEPATH__'

                # {InstallDir} is substituted here rather than at package time, because the install
                # location is only known once the ARP entry has been read. This is what lets an NSIS
                # '_?=' uninstall be driven without a hardcoded path in the package: '_?=' must be the
                # LAST argument and unquoted, so it is appended as-is and never wrapped in quotes.
                $uninstallArgs = '__UNINSTALLARGS__'.Replace('{InstallDir}', $installDir)
                Write-ADTLogEntry -Message "Uninstalling __APPNAME__ via [$uninstaller] $uninstallArgs"
                Start-ADTProcess -FilePath $uninstaller -ArgumentList $uninstallArgs__EXITPARAMS__

                $deadline = (Get-Date).AddSeconds(300)
                while ((Test-Path -LiteralPath $verify) -and ((Get-Date) -lt $deadline))
                {
                    Start-Sleep -Seconds 3
                }

                if (Test-Path -LiteralPath $verify)
                {
                    throw "The __APPNAME__ uninstaller returned but [$verify] still exists after 300 seconds - the uninstall did not complete."
                }

                Write-ADTLogEntry -Message "__APPNAME__ uninstall confirmed - [$verify] is gone."
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

    end
    {
        Complete-ADTFunction -Cmdlet $PSCmdlet
    }
}


##*===============================================
##* MARK: SCRIPT BODY
##*===============================================

Write-ADTLogEntry -Message "Module [$($MyInvocation.MyCommand.ScriptBlock.Module.Name)] imported successfully." -ScriptSection Initialization
'@

$extOut = $ext.
    Replace('__APPNAME__', (Get-SqEscaped $AppName)).
    Replace('__DISPLAYNAMELIKE__', (Get-SqEscaped $DisplayNameLike)).
    Replace('__VERIFYRELATIVEPATH__', (Get-SqEscaped $VerifyRelativePath)).
    Replace('__UNINSTALLARGS__', (Get-SqEscaped $UninstallArgs)).
    Replace('__EXITPARAMS__', ($successParam + $rebootParam)).
    Replace('__FNTOKEN__', $fnToken)

Assert-NoUnreplacedToken $extOut 'PSAppDeployToolkit.Extensions.psm1'
[System.IO.File]::WriteAllText("$pkg\PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1", $extOut, [System.Text.UTF8Encoding]::new($true))

# 4) Bundle installer
Copy-Item -LiteralPath $InstallerPath -Destination "$pkg\Files\$InstallerFile" -Force

# 5) Detection script - DisplayName + version FLOOR, never an equals match
$detect = @'
# Detect-__NAME__.ps1 - Intune detection for __APPNAME__ (baseline __APPVERSION__)
#
# Contract: exit 0 ALWAYS. Write to stdout only when the app counts as installed; silence means
# "not installed". A non-zero exit is read by Intune as a detection ERROR, not as "absent".
#
# Why a version FLOOR and not an equals match: a self-updating application (and most of them are)
# moves past the packaged version on its own, and an equals rule then reports "not installed" on a
# machine that plainly has the app - so Intune re-offers a required app on its ~24h cycle forever.
# Anything NEWER than the packaged baseline still satisfies this package.
#
# Two sources, because each has a blind spot alone: the ARP entry is what the installer wrote, the
# binary is what is actually on disk, and the highest version either reports wins. The binary is
# located THROUGH the ARP entry, never through a hardcoded path.

$ErrorActionPreference = 'SilentlyContinue'

$baseline = [System.Version]'__BASELINE__'
$candidates = New-Object System.Collections.ArrayList

function Add-Candidate
{
    param([string]$Raw, [string]$Source)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return }

    # Only the LEADING dotted-number token. Stripping every non-digit from the whole string is wrong:
    # a value like "1.2.3 (x64 en-US)" would let the "64" of "x64" concatenate onto the version.
    $m = [regex]::Match($Raw.Trim(), '^\d+(\.\d+){1,3}')
    if (-not $m.Success) { return }
    $clean = $m.Value
    if (($clean.ToCharArray() | Where-Object { $_ -eq '.' } | Measure-Object).Count -eq 0) { $clean = "$clean.0" }

    $parsed = $null
    if ([System.Version]::TryParse($clean, [ref]$parsed))
    {
        [void]$candidates.Add([PSCustomObject]@{ Version = $parsed; Source = $Source })
    }
}

# 1) The machine-wide Add/Remove Programs entry, and where it says the app lives.
$installDirs = New-Object System.Collections.ArrayList
foreach ($base in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'))
{
    foreach ($sub in (Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue))
    {
        $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.DisplayName -like '__DISPLAYNAMELIKE__*')
        {
            Add-Candidate $p.DisplayVersion 'ARP DisplayVersion'

            # Where the entry claims to live, so source 2 below needs no hardcoded path.
            # InstallLocation is frequently EMPTY - draw.io 31.4.5 records none at all - so the
            # uninstaller's own directory is used as the fallback, exactly as the uninstall hook does.
            $dir = if ($p.InstallLocation) { ([System.String]$p.InstallLocation).TrimEnd('\') } else { $null }
            if (-not $dir -and $p.UninstallString)
            {
                $u = ([System.String]$p.UninstallString) -replace '^\s*"?([^"]+\.exe)"?.*$', '$1'
                if ($u) { $dir = Split-Path -Path $u -Parent }
            }
            if ($dir) { [void]$installDirs.Add($dir) }
        }
    }
}

# 2) The application binary itself, resolved THROUGH that entry rather than through a guessed path.
# This is what catches a registry that is out of step with what is actually on disk - a self-updating
# app that replaced its files, or a half-removed install whose ARP row outlived its program folder.
foreach ($dir in ($installDirs | Select-Object -Unique))
{
    $exePath = Join-Path -Path $dir -ChildPath '__VERIFYRELATIVEPATH__'
    if (Test-Path -LiteralPath $exePath -PathType Leaf)
    {
        $item = Get-Item -LiteralPath $exePath -ErrorAction SilentlyContinue
        if ($item) { Add-Candidate $item.VersionInfo.ProductVersion '__VERIFYRELATIVEPATH__ ProductVersion' }
    }
}

if ($candidates.Count -gt 0)
{
    $best = $candidates | Sort-Object -Property Version -Descending | Select-Object -First 1
    if ($best.Version -ge $baseline)
    {
        Write-Output "__APPNAME__ $($best.Version) detected via $($best.Source) (baseline $baseline)"
    }
}

exit 0
'@

# The baseline must parse as a System.Version at detection time; a marketing string like "2026.1 LTS"
# would throw there, where the failure is a detection ERROR on every device, so it is caught here.
$baselineCandidate = [regex]::Match($AppVersion.Trim(), '^\d+(\.\d+){1,3}').Value
if (-not $baselineCandidate) { throw "AppVersion '$AppVersion' has no leading numeric version for the detection baseline - pass a numeric AppVersion." }
if (-not $baselineCandidate.Contains('.')) { $baselineCandidate = "$baselineCandidate.0" }

$detect = $detect.
    Replace('__NAME__', $Name).
    Replace('__APPNAME__', (Get-SqEscaped $AppName)).
    Replace('__APPVERSION__', $AppVersion).
    Replace('__BASELINE__', $baselineCandidate).
    Replace('__VERIFYRELATIVEPATH__', (Get-SqEscaped $VerifyRelativePath)).
    Replace('__DISPLAYNAMELIKE__', $DisplayNameLike)
Assert-NoUnreplacedToken $detect "Detect-$Name.ps1"
[System.IO.File]::WriteAllText("$pkg\Detect-$Name.ps1", $detect, [System.Text.UTF8Encoding]::new($true))

# 6) Manifest - written by the generator, never left to the operator
& (Join-Path $PSScriptRoot 'Set-PsadtPackageManifest.ps1') -PackagePath $pkg -Updates @{
    'app.vendor'             = $AppVendor
    'app.name'               = $AppName
    'app.version'            = $AppVersion
    'app.arch'               = $AppArch
    'app.lang'               = 'EN'
    'app.revision'           = 1
    'package.name'           = $logStem
    'package.type'           = 'installer'
    'package.installerTech'  = 'exe'
    'package.sourceStrategy' = 'bundle'
    'research.switches'      = @{
        install   = "$InstallerFile $InstallArgs"
        uninstall = "<resolved from ARP at run time> $UninstallArgs, then WAIT until $VerifyRelativePath is gone"
        repair    = "Re-run the installer with the install switches"
    }
} | Out-Null

Write-Output "PACKAGE_OK: $pkg"

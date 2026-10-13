#Requires -Modules PSAppDeployToolkit
<#
    New-PortablePackage.ps1 - reusable PSADT v4.1.8 package generator for PORTABLE payloads: a vendor
    ZIP, or a single application binary, with no installer at all (Terraform, kubectl, Packer, PuTTY's
    plain .exe, the many CLI tools shipped as an archive).

    Nothing here runs a vendor installer, so the PACKAGE owns every deployment type, and the lessons
    below are generated rather than remembered:

      1. The source ZIP goes into Files\ UNCHANGED and is extracted at install time. Its SHA256 is then
         the vendor's published checksum (HashiCorp's SHA256SUMS, for one), recorded as
         package.installerSha256 - the join key pre-flight's research gate and the evidence store use.
      2. The machine PATH is edited in the REGISTRY, keeping the value kind it already has.
         [Environment]::SetEnvironmentVariable - which is what Set-ADTEnvironmentVariable calls in 4.1.8 -
         rewrites a REG_EXPAND_SZ Path as REG_SZ, after which every %SystemRoot% segment in it stops
         resolving. Only our own entry is added or removed; nothing else in the value is touched.
      3. The package writes its OWN Add/Remove Programs entry (NoRemove/NoModify/NoRepair = 1), under a
         version-INDEPENDENT key, so the next version replaces it in place. Detection is a version FLOOR
         on that entry AND the binary on disk: an ARP row that outlived its files is not "installed".
      4. A running process is not killed by default. A CLI tool killed mid-run can leave half-written
         state behind (an interrupted 'terraform apply' leaves a locked, partial state), so
         -DeferIfRunning exits 1618 instead - Intune's "retry later" - and the next cycle installs.
      5. An optional smoke test runs the copied binary as SYSTEM and matches its output, so a payload that
         was copied but cannot start (missing runtime, wrong architecture) fails the install loudly.

    English/ASCII only in all generated script content (encoding cleanliness).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,            # package folder + scaffold name (path-safe)
    [Parameter(Mandatory)][string]$AppVendor,
    [Parameter(Mandatory)][string]$AppName,
    [Parameter(Mandatory)][string]$AppVersion,
    [Parameter(Mandatory)][string]$AppArch,         # x64 | x86 | ARM64

    # The vendor ZIP or the single binary, copied into Files\ unchanged.
    [Parameter(Mandatory)][string]$SourcePath,

    # The application binary relative to the install folder. It must EXIST after install and be GONE
    # after uninstall; detection and the smoke test both use it. Example: 'terraform.exe'.
    [Parameter(Mandatory)][string]$VerifyRelativePath,

    # The vendor's published SHA256 of -SourcePath. When given, a mismatch stops the generator before a
    # package exists - a swapped or truncated download never reaches a script that runs as SYSTEM.
    [string]$ExpectedSha256 = '',

    # Install folder relative to Program Files. Default: '<AppVendor>\<AppName>'.
    [string]$InstallSubPath = '',

    # Inside the ZIP, the folder whose CONTENT is installed ('' = the archive root). For archives that
    # wrap everything in one top-level folder such as 'tool-1.2.3\'.
    [string]$ArchiveSubfolder = '',

    # Append the install folder (or -PathSubfolder beneath it) to the MACHINE PATH, and remove it again
    # on uninstall. Command-line tools need it; a GUI app usually does not.
    [switch]$AddToPath,
    [string]$PathSubfolder = '',

    # ARP DisplayName. Default: '<AppVendor> <AppName>'.
    [string]$ArpDisplayName = '',

    # Processes that must not be running. -ProcessesToClose closes them (GUI apps); -DeferIfRunning
    # exits 1618 instead, which Intune retries later (CLI tools, where a kill can corrupt state).
    [string[]]$ProcessesToClose = @(),
    [string[]]$DeferIfRunning = @(),

    # Optional smoke test after the copy: run '<VerifyRelativePath> <SmokeTestArgs>' as SYSTEM and require
    # its combined output to match -SmokeTestPattern. -SmokeTestEnvironment adds process-only variables
    # (e.g. @{ CHECKPOINT_DISABLE = '1' } so Terraform does not phone home during the check).
    [string]$SmokeTestArgs = '',
    [string]$SmokeTestPattern = '',
    [hashtable]$SmokeTestEnvironment = @{},

    [string]$Author,
    [string]$PackageRoot,
    [string]$Changelog = '',
    [switch]$Force
    # No -DeployMode: every package runs Silent, without exception (rule:deploymode-silent).
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
    # `pwsh scripts/New-PortablePackage.ps1 -DeferIfRunning a,b` uses the -File binder, which passes
    # "a,b" as ONE element - a process name that matches nothing, so the guard would never fire.
    if (-not $Values) { return @() }
    return @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { ($_.Trim() -replace '\.exe$', '') } | Where-Object { $_ })
}
function Assert-NoTokenLeak([string]$value, [string]$paramName) {
    if ($value -match '__[A-Z0-9_]+__') { throw "Parameter '$paramName' must not contain a template placeholder sequence ('$($Matches[0])')." }
}
# A value carrying the comment-block terminator would END the launcher's <# .. #> help block, and what
# follows it becomes top-level code in a script that later runs as SYSTEM. Reject it at the source.
function Assert-NoCommentTerminator([string]$value, [string]$paramName) {
    if ($value -match '#>') { throw "Parameter '$paramName' must not contain the comment terminator '#>'." }
}
function Assert-NoUnreplacedToken([string]$content, [string]$file) {
    if ($content -match '__[A-Z0-9_]+__') {
        throw "Generated $file still contains the unreplaced placeholder '$($Matches[0])' - the template gained a token that its Replace() chain does not cover."
    }
}
# A relative path that climbs out of Program Files, or is rooted, would point the uninstall's folder
# removal at something the package never created.
function Assert-RelativeSubPath([string]$value, [string]$paramName, [switch]$AllowEmpty) {
    if (-not $value) { if ($AllowEmpty) { return }; throw "Parameter '$paramName' must not be empty." }
    if ([System.IO.Path]::IsPathRooted($value) -or $value -match '(^|[\\/])\.\.([\\/]|$)' -or $value -match '[:*?"<>|]') {
        throw "Parameter '$paramName' must be a plain relative path without '..', a drive or wildcards: '$value'."
    }
}

if ($Name -match '[\\/:*?"<>|]' -or $Name -match '\.\.') { throw "Name '$Name' must be a simple folder name (no path separators or '..')." }
if (-not $InstallSubPath) { $InstallSubPath = "$AppVendor\$AppName" }
if (-not $ArpDisplayName) { $ArpDisplayName = "$AppVendor $AppName" }
$InstallSubPath = $InstallSubPath.Trim('\', '/')
$ArchiveSubfolder = $ArchiveSubfolder.Trim('\', '/')
$PathSubfolder = $PathSubfolder.Trim('\', '/')
foreach ($pair in @(@('Name', $Name), @('AppVendor', $AppVendor), @('AppName', $AppName), @('AppVersion', $AppVersion),
        @('Author', $Author), @('VerifyRelativePath', $VerifyRelativePath), @('InstallSubPath', $InstallSubPath),
        @('ArchiveSubfolder', $ArchiveSubfolder), @('PathSubfolder', $PathSubfolder), @('ArpDisplayName', $ArpDisplayName),
        @('SmokeTestArgs', $SmokeTestArgs), @('SmokeTestPattern', $SmokeTestPattern), @('Changelog', $Changelog))) {
    Assert-NoTokenLeak ([string]$pair[1]) $pair[0]
}
Assert-NoCommentTerminator ([string]$Author) 'Author'
Assert-NoCommentTerminator ([string]$Changelog) 'Changelog'
Assert-RelativeSubPath $InstallSubPath 'InstallSubPath'
Assert-RelativeSubPath $VerifyRelativePath 'VerifyRelativePath'
Assert-RelativeSubPath $ArchiveSubfolder 'ArchiveSubfolder' -AllowEmpty
Assert-RelativeSubPath $PathSubfolder 'PathSubfolder' -AllowEmpty
if ($SmokeTestPattern -and -not $SmokeTestArgs) { throw '-SmokeTestPattern needs -SmokeTestArgs: the pattern is matched against the output of that run.' }
if ($SmokeTestPattern) { try { [void][regex]::new($SmokeTestPattern) } catch { throw "-SmokeTestPattern is not a valid regular expression: $($_.Exception.Message)" } }
foreach ($k in $SmokeTestEnvironment.Keys) {
    if ([string]$k -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "SmokeTestEnvironment key '$k' is not a valid environment variable name." }
    Assert-NoTokenLeak ([string]$SmokeTestEnvironment[$k]) "SmokeTestEnvironment.$k"
}

if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw "SourcePath not found: $SourcePath" }
$SourcePath = (Resolve-Path -LiteralPath $SourcePath).ProviderPath
$sourceFile = Split-Path -Path $SourcePath -Leaf
$sourceExt = [System.IO.Path]::GetExtension($sourceFile).ToLowerInvariant()
if ($sourceExt -in @('.msi', '.msp', '.msix', '.appx', '.msixbundle')) {
    throw "SourcePath '$sourceFile' is an installer package, not a portable payload - use New-MsiPackage.ps1, or App. L.8 for MSIX."
}
$isZip = ($sourceExt -eq '.zip')
if (-not $isZip -and $sourceExt -ne '.exe') { throw "SourcePath must be a .zip archive or a single .exe: '$sourceFile'." }

$sourceSha = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ExpectedSha256 -and $sourceSha -ne $ExpectedSha256.Trim().ToLowerInvariant()) {
    throw "SHA256 mismatch for '$sourceFile': expected $($ExpectedSha256.Trim().ToLowerInvariant()), got $sourceSha. Re-download it from the vendor; nothing was generated."
}

# The archive must actually contain the binary the package promises - checked now, not in a VM.
if ($isZip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($SourcePath)
    try {
        $want = (@($ArchiveSubfolder, $VerifyRelativePath) | Where-Object { $_ }) -join '/'
        $want = $want.Replace('\', '/')
        $found = @($zip.Entries | Where-Object { $_.FullName.Replace('\', '/') -ieq $want })
        if ($found.Count -eq 0) {
            $sample = (@($zip.Entries | Select-Object -First 10 | ForEach-Object { $_.FullName }) -join ', ')
            throw "The archive has no entry '$want' (ArchiveSubfolder + VerifyRelativePath). First entries: $sample"
        }
    }
    finally { $zip.Dispose() }
}
elseif ($VerifyRelativePath -ne $sourceFile) {
    throw "For a single-binary source, -VerifyRelativePath must be the file name itself ('$sourceFile'), got '$VerifyRelativePath'."
}

# Function-name token from the package name, so two packages cannot collide in PSADT's module scope.
$fnToken = ($Name -replace '[^A-Za-z0-9]', '')
if (-not $fnToken) { throw "Name '$Name' yields no usable function-name token." }

# The ARP key is version-INDEPENDENT on purpose: the next version overwrites it in place, and the
# detection floor of an older package keeps reading the same row.
$arpKey = (('PSADT_' + $AppVendor + '_' + $AppName) -replace '[^A-Za-z0-9._-]', '')

# 1) Scaffold
if ([string]::IsNullOrWhiteSpace($PackageRoot) -or $PackageRoot -eq [System.IO.Path]::GetPathRoot($PackageRoot)) {
    throw "PackageRoot must be a real folder, not a drive root: '$PackageRoot'. Set paths.packageRoot, or pass -PackageRoot."
}
$pkg = Join-Path $PackageRoot $Name
if (Test-Path $pkg) {
    if (-not $Force) {
        throw "Package folder already exists: $pkg. Re-running the generator REPLACES it, including the Extensions module, Assets\ and the results recorded in psadt-package.json. Pass -Force if that is what you want, or use a different -Name."
    }
    Remove-Item $pkg -Recurse -Force
}
New-ADTTemplate -Destination $PackageRoot -Name $Name -Force | Out-Null

$ProcessesToClose = Expand-CommaSeparated $ProcessesToClose
$DeferIfRunning = Expand-CommaSeparated $DeferIfRunning
function ConvertTo-Literal([string[]]$Items) {
    if (-not $Items -or $Items.Count -eq 0) { return '@()' }
    return "@(" + (($Items | ForEach-Object { "'$(Get-SqEscaped $_)'" }) -join ', ') + ")"
}
$procLiteral = ConvertTo-Literal $ProcessesToClose
$deferLiteral = ConvertTo-Literal $DeferIfRunning
$envLiteral = if ($SmokeTestEnvironment.Count) {
    "@{ " + ((@($SmokeTestEnvironment.Keys | Sort-Object) | ForEach-Object { "'$_' = '$(Get-SqEscaped ([string]$SmokeTestEnvironment[$_]))'" }) -join '; ') + " }"
} else { '@{}' }

# 2) Launcher
$tpl = @'
<#
.SYNOPSIS
PSAppDeployToolkit - Installs, uninstalls or repairs __APPNAME__.
.DESCRIPTION
Three deployment types (Install / Uninstall / Repair) for Intune Win32 (PSADT v4.1.8).
Portable payload: no vendor installer runs. The package copies the files, registers its own ARP entry
__PATHNOTE__and removes exactly what it placed.
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

    # No vendor process runs, so these are the package's own codes: 0, or 1618 when it defers.
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @()
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

    ## A running CLI is never killed: exit 1618 and let Intune retry on its next cycle.
    Exit-ADT__FNTOKEN__IfBusy

    $saiwParams = @{ CheckDiskSpace = $true }
    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        $saiwParams.Add('CloseProcesses', $adtSession.AppProcessesToClose)
        $saiwParams.Add('CloseProcessesCountdown', 60)
    }
    Show-ADTInstallationWelcome @saiwParams
    Show-ADTInstallationProgress

    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## Replaces whatever version is in the folder, registers PATH + ARP, verifies the binary.
    Install-ADT__FNTOKEN__Payload

    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## Runs the copied binary as SYSTEM - a payload that cannot start fails here, not on a user's desk.
    Test-ADT__FNTOKEN__Payload
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

    ## A binary in use cannot be deleted; defer rather than kill.
    Exit-ADT__FNTOKEN__IfBusy

    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
    }
    Show-ADTInstallationProgress

    ##================================================
    ## MARK: Uninstall
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## Removes the folder, our PATH entry and our ARP entry - and verifies the binary is gone.
    ## User data (profile config, caches) is not ours and stays.
    Uninstall-ADT__FNTOKEN__Payload

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

    Exit-ADT__FNTOKEN__IfBusy

    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
    }
    Show-ADTInstallationProgress

    ##================================================
    ## MARK: Repair
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## A copy is its own repair verb: the same idempotent routine as Install.
    Install-ADT__FNTOKEN__Payload

    ##================================================
    ## MARK: Post-Repair
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    Test-ADT__FNTOKEN__Payload
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
$pathNote = if ($AddToPath) { "and its machine PATH entry, `r`n" } else { '' }

$logStem = (& (Join-Path $PSScriptRoot 'Get-PsadtPackageManifest.ps1') -Identity @{ vendor = $AppVendor; name = $AppName; version = $AppVersion; arch = $AppArch }).Stem
$out = $tpl.
    Replace('__APPVENDOR__', (Get-SqEscaped $AppVendor)).
    Replace('__APPNAME__', (Get-SqEscaped $AppName)).
    Replace('__APPVERSION__', (Get-SqEscaped $AppVersion)).
    Replace('__APPARCH__', (Get-SqEscaped $AppArch)).
    Replace('__LOGSTEM__', $logStem).
    Replace('__PROCESSES__', $procLiteral).
    Replace('__AUTHOR__', (Get-SqEscaped $Author)).
    Replace('__DATE__', $today).
    Replace('__PATHNOTE__', $pathNote).
    Replace('__FNTOKEN__', $fnToken).
    Replace('__CHANGELOG__', $Changelog)

Assert-NoUnreplacedToken $out 'Invoke-AppDeployToolkit.ps1'
[System.IO.File]::WriteAllText("$pkg\Invoke-AppDeployToolkit.ps1", $out, [System.Text.UTF8Encoding]::new($true))

# 3) Extensions module - copy, PATH, ARP, smoke test, verified removal
$ext = @'
<#

.SYNOPSIS
PSAppDeployToolkit.Extensions - portable payload handling for __APPNAME__.

.DESCRIPTION
Generated by New-PortablePackage.ps1. No vendor installer exists, so this module owns the whole
lifecycle: copy the payload, register the machine PATH entry and an Add/Remove Programs row, and remove
exactly those again.

#>

##*===============================================
##* MARK: MODULE GLOBAL SETUP
##*===============================================

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

# Fixed at generation time; every function below reads these and nothing else.
$Script:PortableCfg = @{
    SourceFile       = '__SOURCEFILE__'
    IsZip            = $__ISZIP__
    ArchiveSubfolder = '__ARCHIVESUBFOLDER__'
    InstallSubPath   = '__INSTALLSUBPATH__'
    VerifyRelative   = '__VERIFYRELATIVEPATH__'
    AddToPath        = $__ADDTOPATH__
    PathSubfolder    = '__PATHSUBFOLDER__'
    ArpKey           = '__ARPKEY__'
    ArpDisplayName   = '__ARPDISPLAYNAME__'
    Publisher        = '__APPVENDOR__'
    Version          = '__APPVERSION__'
    DeferIfRunning   = __DEFER__
    SmokeArgs        = '__SMOKEARGS__'
    SmokePattern     = '__SMOKEPATTERN__'
    SmokeEnvironment = __SMOKEENV__
}


##*===============================================
##* MARK: FUNCTION LISTINGS
##*===============================================

function Get-ADT__FNTOKEN__InstallDir
{
    <#
    .SYNOPSIS
        The install folder under the 64-bit Program Files.

    .DESCRIPTION
        ProgramW6432 first: a 32-bit host sees ProgramFiles as 'Program Files (x86)', and the detection
        script resolves the same folder the same way.
    #>

    [CmdletBinding()]
    param
    (
    )

    $pf = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    return (Join-Path -Path $pf -ChildPath $Script:PortableCfg.InstallSubPath)
}


function Exit-ADT__FNTOKEN__IfBusy
{
    <#
    .SYNOPSIS
        Ends the deployment with 1618 when one of the DeferIfRunning processes is running.

    .DESCRIPTION
        1618 is Intune's retry code: the IME tries again on a later cycle. Killing a CLI tool instead
        can interrupt work that leaves state behind - an interrupted 'terraform apply' leaves a locked,
        partial state file - and a binary that is running cannot be replaced or deleted anyway.
    #>

    [CmdletBinding()]
    param
    (
    )

    if (@($Script:PortableCfg.DeferIfRunning).Count -eq 0) { return }
    $busy = @(Get-Process -Name $Script:PortableCfg.DeferIfRunning -ErrorAction SilentlyContinue)
    if ($busy.Count -gt 0)
    {
        $names = ($busy | ForEach-Object { "$($_.ProcessName) (PID $($_.Id))" }) -join ', '
        Write-ADTLogEntry -Message "Deferring: $names is running. Exit 1618 - Intune retries on its next cycle." -Severity 2
        Close-ADTSession -ExitCode 1618
    }
}


function Edit-ADT__FNTOKEN__MachinePath
{
    <#
    .SYNOPSIS
        Adds or removes ONE folder in the machine PATH, keeping the value kind it already has.

    .DESCRIPTION
        Read raw (DoNotExpandEnvironmentNames) and written back with the SAME RegistryValueKind.
        [Environment]::SetEnvironmentVariable - what Set-ADTEnvironmentVariable uses in 4.1.8 - writes
        REG_SZ, which turns a REG_EXPAND_SZ Path's %SystemRoot% segments into literal text that no
        longer resolves. Nothing in the value but our own entry is touched; empty segments are kept.
    #>

    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateSet('Add', 'Remove')]
        [System.String]$Action,

        [Parameter(Mandatory = $true)]
        [System.String]$Folder
    )

    $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $key = $hklm.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
    try
    {
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        try { $kind = $key.GetValueKind('Path') } catch { $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
        $raw = [System.String]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $want = $Folder.TrimEnd('\')
        $segments = @($raw -split ';')
        $isOurs = { param($s) $s.Trim().TrimEnd('\') -ieq $want }

        if ($Action -eq 'Add')
        {
            if (@($segments | Where-Object { & $isOurs $_ }).Count -gt 0)
            {
                Write-ADTLogEntry -Message "Machine PATH already contains [$want]."
                return
            }
            $new = if ($raw -and -not $raw.EndsWith(';')) { "$raw;$want" } else { "$raw$want" }
        }
        else
        {
            $kept = @($segments | Where-Object { -not (& $isOurs $_) })
            if ($kept.Count -eq $segments.Count)
            {
                Write-ADTLogEntry -Message "Machine PATH does not contain [$want] - nothing to remove."
                return
            }
            $new = $kept -join ';'
        }

        $key.SetValue('Path', $new, $kind)
        Write-ADTLogEntry -Message "Machine PATH: $Action [$want] (value kind $kind kept)."
    }
    finally
    {
        $key.Dispose()
        $hklm.Dispose()
    }
}


function Install-ADT__FNTOKEN__Payload
{
    <#
    .SYNOPSIS
        Copies the payload into place, registers PATH + ARP, and verifies the binary.

    .DESCRIPTION
        Idempotent - Install and Repair both call it. The folder is emptied first, so files a previous
        version shipped and this one dropped do not linger. The ZIP is extracted into a staging folder
        and copied from there, so -ArchiveSubfolder works and a failed extraction never leaves a
        half-filled install folder.
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
                # A module function cannot see the launcher's $adtSession - ask PSADT for the session.
                $session = Get-ADTSession
                $source = Join-Path -Path $session.DirFiles -ChildPath $Script:PortableCfg.SourceFile
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Payload not found: $source" }

                $dest = Get-ADT__FNTOKEN__InstallDir
                if (Test-Path -LiteralPath $dest)
                {
                    Write-ADTLogEntry -Message "Emptying existing install folder [$dest] before the copy."
                    Remove-ADTFolder -Path $dest
                }
                New-ADTFolder -Path $dest

                if ($Script:PortableCfg.IsZip)
                {
                    $staging = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('__FNTOKEN___' + [System.Guid]::NewGuid().ToString('N'))
                    try
                    {
                        Add-Type -AssemblyName System.IO.Compression.FileSystem
                        Write-ADTLogEntry -Message "Extracting [$source] to staging [$staging]."
                        [System.IO.Compression.ZipFile]::ExtractToDirectory($source, $staging)
                        $from = if ($Script:PortableCfg.ArchiveSubfolder) { Join-Path -Path $staging -ChildPath $Script:PortableCfg.ArchiveSubfolder } else { $staging }
                        Copy-ADTFile -Path (Join-Path -Path $from -ChildPath '*') -Destination $dest -Recurse
                    }
                    finally
                    {
                        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
                    }
                }
                else
                {
                    Copy-ADTFile -Path $source -Destination $dest
                }

                $binary = Join-Path -Path $dest -ChildPath $Script:PortableCfg.VerifyRelative
                if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw "Copy finished but [$binary] does not exist." }

                if ($Script:PortableCfg.AddToPath)
                {
                    $pathDir = if ($Script:PortableCfg.PathSubfolder) { Join-Path -Path $dest -ChildPath $Script:PortableCfg.PathSubfolder } else { $dest }
                    Edit-ADT__FNTOKEN__MachinePath -Action Add -Folder $pathDir
                }

                # Our own ARP row. NoRemove/NoModify/NoRepair grey out the Settings buttons: removal goes
                # through Company Portal, which runs the Uninstall deployment type of this package.
                $arp = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($Script:PortableCfg.ArpKey)"
                $sizeKb = [int](((Get-ChildItem -LiteralPath $dest -Recurse -File | Measure-Object -Property Length -Sum).Sum) / 1KB)
                Set-ADTRegistryKey -Key $arp -Name 'DisplayName' -Value $Script:PortableCfg.ArpDisplayName -Type String
                Set-ADTRegistryKey -Key $arp -Name 'DisplayVersion' -Value $Script:PortableCfg.Version -Type String
                Set-ADTRegistryKey -Key $arp -Name 'Publisher' -Value $Script:PortableCfg.Publisher -Type String
                Set-ADTRegistryKey -Key $arp -Name 'InstallLocation' -Value $dest -Type String
                Set-ADTRegistryKey -Key $arp -Name 'DisplayIcon' -Value $binary -Type String
                Set-ADTRegistryKey -Key $arp -Name 'InstallDate' -Value (Get-Date -Format 'yyyyMMdd') -Type String
                Set-ADTRegistryKey -Key $arp -Name 'UninstallString' -Value 'Managed by Intune (PSAppDeployToolkit) - uninstall through Company Portal' -Type String
                Set-ADTRegistryKey -Key $arp -Name 'EstimatedSize' -Value $sizeKb -Type DWord
                Set-ADTRegistryKey -Key $arp -Name 'NoRemove' -Value 1 -Type DWord
                Set-ADTRegistryKey -Key $arp -Name 'NoModify' -Value 1 -Type DWord
                Set-ADTRegistryKey -Key $arp -Name 'NoRepair' -Value 1 -Type DWord

                # The machine PATH change reaches the logged-on user's Explorer only through a broadcast
                # in THEIR session; PSADT sends it through its client/server process.
                if ($Script:PortableCfg.AddToPath) { Update-ADTDesktop }

                Write-ADTLogEntry -Message "$($Script:PortableCfg.ArpDisplayName) $($Script:PortableCfg.Version) installed to [$dest]."
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


function Test-ADT__FNTOKEN__Payload
{
    <#
    .SYNOPSIS
        Runs the installed binary once and matches its output. No-op when no smoke test was generated.

    .DESCRIPTION
        A copy can succeed for a binary that cannot start - wrong architecture, a missing runtime. The
        detection rule would still report "installed". Running it here, as SYSTEM, turns that into a
        failed install with the output in the log.
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
                if (-not $Script:PortableCfg.SmokeArgs) { return }
                $binary = Join-Path -Path (Get-ADT__FNTOKEN__InstallDir) -ChildPath $Script:PortableCfg.VerifyRelative

                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $binary
                $psi.Arguments = $Script:PortableCfg.SmokeArgs
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                foreach ($k in $Script:PortableCfg.SmokeEnvironment.Keys) { $psi.EnvironmentVariables[$k] = [System.String]$Script:PortableCfg.SmokeEnvironment[$k] }

                $p = [System.Diagnostics.Process]::Start($psi)
                $stdoutTask = $p.StandardOutput.ReadToEndAsync()
                $stderrTask = $p.StandardError.ReadToEndAsync()
                if (-not $p.WaitForExit(120000))
                {
                    try { $p.Kill() } catch { $null = $_ }
                    throw "Smoke test [$binary $($Script:PortableCfg.SmokeArgs)] did not finish within 120 seconds."
                }
                $output = ($stdoutTask.Result + $stderrTask.Result).Trim()
                Write-ADTLogEntry -Message "Smoke test [$binary $($Script:PortableCfg.SmokeArgs)] exit $($p.ExitCode): $output"

                if ($p.ExitCode -ne 0) { throw "Smoke test exited $($p.ExitCode)." }
                if ($Script:PortableCfg.SmokePattern -and $output -notmatch $Script:PortableCfg.SmokePattern)
                {
                    throw "Smoke test output does not match [$($Script:PortableCfg.SmokePattern)]."
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

    end
    {
        Complete-ADTFunction -Cmdlet $PSCmdlet
    }
}


function Uninstall-ADT__FNTOKEN__Payload
{
    <#
    .SYNOPSIS
        Removes the install folder, our PATH entry and our ARP row, then verifies the binary is gone.

    .DESCRIPTION
        Only what this package placed. The vendor folder above it is removed only when it is empty, so a
        second product of the same vendor is never touched. Per-user data is not ours and stays.
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
                $dest = Get-ADT__FNTOKEN__InstallDir

                if ($Script:PortableCfg.AddToPath)
                {
                    $pathDir = if ($Script:PortableCfg.PathSubfolder) { Join-Path -Path $dest -ChildPath $Script:PortableCfg.PathSubfolder } else { $dest }
                    Edit-ADT__FNTOKEN__MachinePath -Action Remove -Folder $pathDir
                }

                if (Test-Path -LiteralPath $dest) { Remove-ADTFolder -Path $dest }

                $pf = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
                $parent = Split-Path -Path $dest -Parent
                while ($parent -and ($parent.TrimEnd('\') -ne $pf.TrimEnd('\')) -and $parent.StartsWith($pf, [System.StringComparison]::OrdinalIgnoreCase) -and
                    (Test-Path -LiteralPath $parent) -and -not (Get-ChildItem -LiteralPath $parent -Force | Select-Object -First 1))
                {
                    Write-ADTLogEntry -Message "Removing empty parent folder [$parent]."
                    Remove-Item -LiteralPath $parent -Force
                    $parent = Split-Path -Path $parent -Parent
                }

                Remove-ADTRegistryKey -Key "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($Script:PortableCfg.ArpKey)" -Recurse

                if ($Script:PortableCfg.AddToPath) { Update-ADTDesktop }

                $binary = Join-Path -Path $dest -ChildPath $Script:PortableCfg.VerifyRelative
                if (Test-Path -LiteralPath $binary) { throw "Uninstall finished but [$binary] still exists." }
                Write-ADTLogEntry -Message "$($Script:PortableCfg.ArpDisplayName) removed - [$binary] is gone."
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
    Replace('__APPVENDOR__', (Get-SqEscaped $AppVendor)).
    Replace('__APPVERSION__', (Get-SqEscaped $AppVersion)).
    Replace('__SOURCEFILE__', (Get-SqEscaped $sourceFile)).
    Replace('__ISZIP__', $(if ($isZip) { 'true' } else { 'false' })).
    Replace('__ARCHIVESUBFOLDER__', (Get-SqEscaped $ArchiveSubfolder)).
    Replace('__INSTALLSUBPATH__', (Get-SqEscaped $InstallSubPath)).
    Replace('__VERIFYRELATIVEPATH__', (Get-SqEscaped $VerifyRelativePath)).
    Replace('__ADDTOPATH__', $(if ($AddToPath) { 'true' } else { 'false' })).
    Replace('__PATHSUBFOLDER__', (Get-SqEscaped $PathSubfolder)).
    Replace('__ARPKEY__', $arpKey).
    Replace('__ARPDISPLAYNAME__', (Get-SqEscaped $ArpDisplayName)).
    Replace('__DEFER__', $deferLiteral).
    Replace('__SMOKEARGS__', (Get-SqEscaped $SmokeTestArgs)).
    Replace('__SMOKEPATTERN__', (Get-SqEscaped $SmokeTestPattern)).
    Replace('__SMOKEENV__', $envLiteral).
    Replace('__FNTOKEN__', $fnToken)

Assert-NoUnreplacedToken $extOut 'PSAppDeployToolkit.Extensions.psm1'
[System.IO.File]::WriteAllText("$pkg\PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1", $extOut, [System.Text.UTF8Encoding]::new($true))

# 4) Bundle the payload unchanged
Copy-Item -LiteralPath $SourcePath -Destination "$pkg\Files\$sourceFile" -Force

# 5) Detection script - our ARP row (version floor) AND the binary on disk
$detect = @'
# Detect-__NAME__.ps1 - Intune detection for __APPNAME__ (baseline __APPVERSION__)
#
# Contract: exit 0 ALWAYS. Write to stdout only when the app counts as installed; silence means
# "not installed". A non-zero exit is read by Intune as a detection ERROR, not as "absent".
#
# The package writes its own Add/Remove Programs row (the binary has no usable version resource of its
# own in the general case), under a version-independent key. Installed means BOTH:
#   - that row's DisplayVersion is at or above the baseline (a FLOOR, so a newer package satisfies an
#     older one and supersedence never loops), and
#   - the binary exists where the row says it lives - a row that outlived its files is not installed.
# The 64-bit registry view is opened explicitly: Intune may run this script as a 32-bit process, and
# that would otherwise read WOW6432Node and find nothing.

$ErrorActionPreference = 'SilentlyContinue'

$baseline = [System.Version]'__BASELINE__'
$hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$key = $hklm.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\__ARPKEY__')

if ($key)
{
    $raw = [string]$key.GetValue('DisplayVersion')
    $dir = [string]$key.GetValue('InstallLocation')
    $key.Close()

    # Only the LEADING dotted-number token; reported as written, compared as a version.
    $m = [regex]::Match($raw.Trim(), '^\d+(\.\d+){1,3}')
    $parsed = $null
    if ($m.Success)
    {
        $clean = $m.Value
        if (-not $clean.Contains('.')) { $clean = "$clean.0" }
        [void][System.Version]::TryParse($clean, [ref]$parsed)
    }

    if ($parsed -and $parsed -ge $baseline -and $dir)
    {
        $binary = Join-Path -Path $dir -ChildPath '__VERIFYRELATIVEPATH__'
        if (Test-Path -LiteralPath $binary -PathType Leaf)
        {
            Write-Output "__APPNAME__ $($m.Value) detected at $binary (baseline __BASELINE__)"
        }
    }
}
$hklm.Close()

exit 0
'@

$baselineCandidate = [regex]::Match($AppVersion.Trim(), '^\d+(\.\d+){1,3}').Value
if (-not $baselineCandidate) { throw "AppVersion '$AppVersion' has no leading numeric version for the detection baseline - pass a numeric AppVersion." }
if (-not $baselineCandidate.Contains('.')) { $baselineCandidate = "$baselineCandidate.0" }

$detect = $detect.
    Replace('__NAME__', $Name).
    Replace('__APPNAME__', (Get-SqEscaped $AppName)).
    Replace('__APPVERSION__', $AppVersion).
    Replace('__BASELINE__', $baselineCandidate).
    Replace('__ARPKEY__', $arpKey).
    Replace('__VERIFYRELATIVEPATH__', (Get-SqEscaped $VerifyRelativePath))
Assert-NoUnreplacedToken $detect "Detect-$Name.ps1"
[System.IO.File]::WriteAllText("$pkg\Detect-$Name.ps1", $detect, [System.Text.UTF8Encoding]::new($true))

# 6) Manifest - written by the generator, never left to the operator
$pfRel = "%ProgramFiles%\$InstallSubPath"
& (Join-Path $PSScriptRoot 'Set-PsadtPackageManifest.ps1') -PackagePath $pkg -Updates @{
    'app.vendor'              = $AppVendor
    'app.name'                = $AppName
    'app.version'             = $AppVersion
    'app.arch'                = $AppArch
    'app.lang'                = 'EN'
    'app.revision'            = 1
    'package.name'            = $logStem
    'package.type'            = 'portable'
    'package.installerTech'   = $(if ($isZip) { 'zip' } else { 'binary' })
    'package.sourceStrategy'  = 'bundle'
    'package.installCommand'   = 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent'
    'package.uninstallCommand' = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent'
    'package.installerFile'   = $sourceFile
    # The vendor's own checksum when the payload is shipped unchanged - and the join key into the
    # evidence store that pre-flight's research gate reads.
    'package.installerSha256' = $sourceSha
    'package.processesToClose' = @($ProcessesToClose | Where-Object { $_ })
    # Version floor on the package's own ARP row: the upload takes the detection script, never a
    # ProductCode rule.
    'package.detection'       = 'versionFloor'
    'package.portable'        = @{
        installDir       = $pfRel
        verifyRelative   = $VerifyRelativePath
        archiveSubfolder = $ArchiveSubfolder
        addToPath        = [bool]$AddToPath
        pathEntry        = $(if ($AddToPath) { if ($PathSubfolder) { "$pfRel\$PathSubfolder" } else { $pfRel } } else { $null })
        arpKey           = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$arpKey"
        arpDisplayName   = $ArpDisplayName
        deferIfRunning   = @($DeferIfRunning | Where-Object { $_ })
        smokeTest        = $(if ($SmokeTestArgs) { "$VerifyRelativePath $SmokeTestArgs" + $(if ($SmokeTestPattern) { " =~ /$SmokeTestPattern/" } else { '' }) } else { $null })
        expectedSha256   = $(if ($ExpectedSha256) { $ExpectedSha256.Trim().ToLowerInvariant() } else { $null })
    }
    'research.switches'       = @{
        install       = "no installer: extract/copy $sourceFile to $pfRel$(if ($AddToPath) { ', add it to the machine PATH' }), write ARP row $arpKey"
        installArgs   = $null
        uninstall     = "package-owned: remove $pfRel$(if ($AddToPath) { ', its PATH entry' }) and ARP row $arpKey, then verify $VerifyRelativePath is gone"
        uninstallArgs = $null
        repair        = 'package-owned: the Install routine again (idempotent)'
    }
} | Out-Null

Write-Output "PACKAGE_OK: $pkg"

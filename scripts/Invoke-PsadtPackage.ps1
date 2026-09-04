<#
.SYNOPSIS
    Packs a PSADT package into a correctly named, verified .intunewin and records it in the manifest.

.DESCRIPTION
    Replaces the hand-typed IntuneWinAppUtil invocation (Phase 7). One command, one deterministic result:

      1. reads the package manifest - the identity is the truth, so the artifact name is not a decision
      2. runs IntuneWinAppUtil with -o pointing at a PRIVATE temp folder (never inside the package)
      3. verifies the produced archive: Metadata\Detection.xml, the encrypted content blob, the SetupFile
         recorded inside it, and the unencrypted size
      4. renames the artifact to <Stem>.intunewin and moves it to <outputRoot>\<Stem>\
      5. copies the detection script and the logo next to it
      6. writes artifacts.* + results.package back into the manifest

    Why the rename is safe: the upload reads setupFilePath out of the INNER Detection.xml, so the outer file
    name is free. It only feeds win32LobApp.fileName and the upload's temp working folder - which is exactly
    why the old generic name mattered: every app produced "Invoke-AppDeployToolkit.intunewin", landed in
    Intune under that name, and every concurrent upload collided in the same %TEMP%\iwup-... folder.

    The output folder must NOT sit inside the package folder. That is not pedantry: IntuneWinAppUtil would
    package its own output on the next run (-o inside -c), growing the archive every time.

.PARAMETER PackagePath
    The package folder (the one containing Invoke-AppDeployToolkit.ps1).

.PARAMETER OutputRoot
    Where the <Stem> folder is created. Default: paths.outputRoot from the config.

.PARAMETER ToolPath
    IntuneWinAppUtil.exe. Default: paths.intuneWinAppUtil from the config.

.PARAMETER SetupFile
    The setup file handed to -s. Default Invoke-AppDeployToolkit.exe (the launcher PSADT ships).

.PARAMETER Json
    Emit the result as JSON instead of the object.

.PARAMETER SkillRoot
    Config home override; default = the home resolved by Get-PsadtConfig.ps1.

.OUTPUTS
    PSCustomObject: Stem, IntuneWin, OutputFolder, SetupFile, UnencryptedSize, Sha256, Detection, Logo,
    Warnings(string[])

.EXAMPLE
    pwsh scripts/Invoke-PsadtPackage.ps1 -PackagePath D:\Pakete\Mobotix_MxManagementCenter_2.9.1_x64
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [string]$OutputRoot,
    [string]$ToolPath,
    [string]$SetupFile = 'Invoke-AppDeployToolkit.exe',
    [switch]$Json,
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'

$warnings = [System.Collections.Generic.List[string]]::new()
function Write-Note([string]$m) { Write-Host "    $m" -ForegroundColor Gray }
function Add-Warning([string]$m) { $warnings.Add($m); Write-Warning $m }

$PackagePath = (Resolve-Path -LiteralPath $PackagePath).Path

# --- 1. Identity from the manifest ----------------------------------------------------------------
$mf = & (Join-Path $PSScriptRoot 'Get-PsadtPackageManifest.ps1') -PackagePath $PackagePath
if (-not $mf.Exists) {
    throw "No psadt-package.json in $PackagePath. Create it first: Set-PsadtPackageManifest.ps1 -PackagePath '$PackagePath' -Updates @{ 'app.vendor'='...'; 'app.name'='...'; 'app.version'='...'; 'app.arch'='x64'; 'package.type'='installer' }"
}
if ($mf.Error)   { throw $mf.Error }
if ($mf.Missing) { throw "The manifest identity is incomplete ($($mf.Missing -join ', ')) - the artifact name is derived from it, so packaging would produce a half-named file. Fill it with Set-PsadtPackageManifest.ps1." }
$stem = $mf.Stem

# --- 2. Resolve output root + tool ----------------------------------------------------------------
$cfg = & (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1') -SkillRoot $SkillRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = [string]$cfg.Config.paths.outputRoot }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { throw "No output root: pass -OutputRoot or set paths.outputRoot (Initialize-PsadtSkill.ps1 -Set)." }
if ([string]::IsNullOrWhiteSpace($ToolPath))   { $ToolPath = [string]$cfg.Config.paths.intuneWinAppUtil }
if ([string]::IsNullOrWhiteSpace($ToolPath) -or -not (Test-Path -LiteralPath $ToolPath)) {
    throw "IntuneWinAppUtil not found ('$ToolPath'). Run Initialize-PsadtSkill.ps1 -Fix, or pass -ToolPath."
}

$outputFolder = Join-Path $OutputRoot $stem

# The refusal that matters: -o inside -c makes the tool package its own previous output.
$pkgFull = [IO.Path]::GetFullPath($PackagePath).TrimEnd('\', '/')
$outFull = [IO.Path]::GetFullPath($outputFolder).TrimEnd('\', '/')
if ($outFull -eq $pkgFull -or $outFull.StartsWith($pkgFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "The output folder would sit inside the package folder ($outFull). IntuneWinAppUtil would then package its own output on the next run. Point -OutputRoot / paths.outputRoot somewhere outside the package."
}

New-Item $outputFolder -ItemType Directory -Force | Out-Null

# Legacy artifacts are reported, never removed - an older .intunewin may still be the one in production.
$foreign = @(Get-ChildItem -LiteralPath $outputFolder -Filter '*.intunewin' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "$stem.intunewin" })
if ($foreign.Count) {
    Add-Warning "$($foreign.Count) other .intunewin file(s) in $outputFolder ($(($foreign | ForEach-Object Name) -join ', ')) - left untouched. Remove them by hand once you are sure they are obsolete."
}

# --- 3. Pack into a private temp folder -----------------------------------------------------------
$setupPath = Join-Path $PackagePath $SetupFile
if (-not (Test-Path -LiteralPath $setupPath)) {
    throw "Setup file not found in the package: $SetupFile. PSADT ships Invoke-AppDeployToolkit.exe next to the .ps1 launcher; pass -SetupFile if this package uses another entry point."
}
$tmpOut = Join-Path ([IO.Path]::GetTempPath()) ("psadtpack-" + [guid]::NewGuid().ToString('N'))
New-Item $tmpOut -ItemType Directory -Force | Out-Null
$verifyDir = $null
try {
    Write-Host "Packing $stem" -ForegroundColor White
    Write-Note "tool   : $ToolPath"
    Write-Note "source : $PackagePath"
    $toolOut = & $ToolPath -c $PackagePath -s $setupPath -o $tmpOut -q 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        throw "IntuneWinAppUtil failed (exit $LASTEXITCODE):`n$toolOut"
    }
    $produced = @(Get-ChildItem -LiteralPath $tmpOut -Filter '*.intunewin' -File -Recurse)
    if ($produced.Count -ne 1) {
        throw "Expected exactly one .intunewin from IntuneWinAppUtil, got $($produced.Count).`n$toolOut"
    }
    $artifact = $produced[0]

    # --- 4. Verify the archive before it is called a deliverable -----------------------------------
    $verifyDir = Join-Path ([IO.Path]::GetTempPath()) ("psadtverify-" + [guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $artifact.FullName -DestinationPath $verifyDir -Force
    $detXml  = Join-Path $verifyDir 'IntuneWinPackage\Metadata\Detection.xml'
    $encBlob = Join-Path $verifyDir 'IntuneWinPackage\Contents\IntunePackage.intunewin'
    if (-not (Test-Path $detXml))  { throw "The produced .intunewin has no Metadata\Detection.xml - it is not usable." }
    if (-not (Test-Path $encBlob)) { throw "The produced .intunewin has no encrypted content blob - it is not usable." }
    [xml]$det = Get-Content $detXml
    $innerSetup = [string]$det.ApplicationInfo.SetupFile
    $unencSize  = [int64]$det.ApplicationInfo.UnencryptedContentSize
    if ([string]::IsNullOrWhiteSpace($innerSetup)) { throw "Detection.xml records no SetupFile." }
    if ($unencSize -le 0) { throw "Detection.xml records an unencrypted size of $unencSize." }
    Write-Note "verified: SetupFile=$innerSetup, unencrypted=$unencSize bytes"

    # --- 5. Rename + move -------------------------------------------------------------------------
    $target = Join-Path $outputFolder "$stem.intunewin"
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }   # our own previous build
    Move-Item -LiteralPath $artifact.FullName -Destination $target -Force
    $sha = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    Write-Note "artifact: $target"

    # --- 6. Detection script + logo alongside -----------------------------------------------------
    $detCopied = $null
    $detSrc = @(Get-ChildItem -LiteralPath $PackagePath -Filter 'Detect*.ps1' -File -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($detSrc) {
        $detDest = Join-Path $outputFolder $detSrc.Name
        Copy-Item -LiteralPath $detSrc.FullName -Destination $detDest -Force
        $detCopied = $detDest
    } else {
        Add-Warning "No Detect*.ps1 in the package - an EXE/non-MSI app needs a detection script for Intune."
    }
    $logoCopied = $null
    $logoSrc = @(Get-ChildItem -LiteralPath (Join-Path $PackagePath 'Assets') -Include '*.png' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^(AppIcon|Banner)' }) | Select-Object -First 1
    if ($logoSrc) {
        $logoDest = Join-Path $outputFolder $logoSrc.Name
        Copy-Item -LiteralPath $logoSrc.FullName -Destination $logoDest -Force
        $logoCopied = $logoDest
    }

    # --- 7. Record it -----------------------------------------------------------------------------
    & (Join-Path $PSScriptRoot 'Set-PsadtPackageManifest.ps1') -PackagePath $PackagePath -Updates @{
        'package.name'             = $stem
        'artifacts.outputFolder'   = $outputFolder
        'artifacts.intunewin'      = $target
        'artifacts.detection'      = $detCopied
        'artifacts.logo'           = $logoCopied
        'results.package'          = @{
            verdict         = 'OK'
            setupFile       = $innerSetup
            unencryptedSize = $unencSize
            sha256          = $sha
            packedAt        = (Get-Date).ToUniversalTime().ToString('o')
            tool            = $ToolPath
        }
    } | Out-Null

    $result = [pscustomobject]@{
        Stem            = $stem
        IntuneWin       = $target
        OutputFolder    = $outputFolder
        SetupFile       = $innerSetup
        UnencryptedSize = $unencSize
        Sha256          = $sha
        Detection       = $detCopied
        Logo            = $logoCopied
        Warnings        = $warnings.ToArray()
    }
    if ($Json) { $result | ConvertTo-Json -Depth 5 } else { $result }
}
finally {
    # The verify dir holds Detection.xml - i.e. the AES keys. It never survives this script.
    if ($verifyDir -and (Test-Path $verifyDir)) { Remove-Item $verifyDir -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item $tmpOut -Recurse -Force -ErrorAction SilentlyContinue
}

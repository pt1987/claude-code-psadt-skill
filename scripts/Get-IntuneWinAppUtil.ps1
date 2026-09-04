<#
.SYNOPSIS  Ensures <config home>\tools\IntuneWinAppUtil.exe is present and current vs the official MS repo.
.PARAMETER SkillRoot  Config home override; default = the home resolved by Get-PsadtConfig.ps1.
.OUTPUTS   PSCustomObject: Action(Downloaded|AlreadyCurrent|UpdateFailed), Version, Path
#>
[CmdletBinding()]
param([string]$SkillRoot)
$ErrorActionPreference = 'Stop'
$repo = 'microsoft/Microsoft-Win32-Content-Prep-Tool'
$cfg  = & (Join-Path $PSScriptRoot 'Get-PsadtConfig.ps1') -SkillRoot $SkillRoot
$exe  = Join-Path $cfg.Home 'tools/IntuneWinAppUtil.exe'

$installedVersion = $cfg.Config.tooling.intuneWinAppUtilVersion
if ($cfg.Error) { Write-Warning "$($cfg.Error) - proceeding without a recorded version." }

$latestTag = $null
try { $latestTag = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name } catch { }

if ((Test-Path $exe) -and $latestTag -and $installedVersion -eq $latestTag) {
    return [pscustomobject]@{ Action='AlreadyCurrent'; Version=$latestTag; Path=$exe }
}

$tag = if ($latestTag) { $latestTag } else { 'v1.8.7' }
try {
    New-Item (Split-Path $exe -Parent) -ItemType Directory -Force | Out-Null
    Invoke-WebRequest "https://github.com/$repo/raw/$tag/IntuneWinAppUtil.exe" -OutFile $exe
    $hdr = New-Object byte[] 2
    $fs = [System.IO.File]::OpenRead($exe)
    try { $nRead = $fs.Read($hdr, 0, 2) } finally { $fs.Dispose() }
    if ($nRead -lt 2 -or $hdr[0] -ne 0x4D -or $hdr[1] -ne 0x5A) {
        Remove-Item $exe -Force -ErrorAction SilentlyContinue
        throw "Downloaded file is not a valid executable (missing MZ header)."
    }
    & (Join-Path $PSScriptRoot 'Set-PsadtConfig.ps1') -SkillRoot $SkillRoot -Updates @{ 'tooling.intuneWinAppUtilVersion' = $tag }
    return [pscustomobject]@{ Action='Downloaded'; Version=$tag; Path=$exe }
} catch {
    if (Test-Path $exe) { return [pscustomobject]@{ Action='AlreadyCurrent'; Version=$installedVersion; Path=$exe } }
    return [pscustomobject]@{ Action='UpdateFailed'; Version=$null; Path=$exe; Error="$_" }
}

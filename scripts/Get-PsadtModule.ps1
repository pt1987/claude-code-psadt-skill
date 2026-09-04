<#
.SYNOPSIS  Ensures the PSAppDeployToolkit module is installed; never a manual hurdle.
.PARAMETER SkillRoot  Unused; accepted so every provisioning script takes the same parameter.
.OUTPUTS   PSCustomObject: Action(Installed|AlreadyCurrent|UpdateAvailable|InstallFailed), Installed, Latest
#>
[CmdletBinding()]
param([string]$SkillRoot)
$ErrorActionPreference = 'Stop'
$name = 'PSAppDeployToolkit'

$local = Get-Module -ListAvailable -Name $name | Sort-Object Version -Descending | Select-Object -First 1
$latest = $null
try { $latest = Find-Module -Name $name -ErrorAction Stop } catch { }

if (-not $local) {
    try {
        Install-Module -Name $name -Scope CurrentUser -Force -AllowClobber
        $local = Get-Module -ListAvailable -Name $name | Sort-Object Version -Descending | Select-Object -First 1
        $installed = if ($local) { "$($local.Version)" } elseif ($latest) { "$($latest.Version)" } else { $null }
        if (-not $installed) {
            return [pscustomobject]@{ Action='InstallFailed'; Installed=$null; Latest="$($latest.Version)"; Error='Module not found after install.' }
        }
        return [pscustomobject]@{ Action='Installed'; Installed=$installed; Latest="$($latest.Version)" }
    } catch {
        return [pscustomobject]@{ Action='InstallFailed'; Installed=$null; Latest="$($latest.Version)"; Error="$_" }
    }
}
if ($latest -and $latest.Version -gt $local.Version) {
    return [pscustomobject]@{ Action='UpdateAvailable'; Installed="$($local.Version)"; Latest="$($latest.Version)" }
}
[pscustomobject]@{ Action='AlreadyCurrent'; Installed="$($local.Version)"; Latest="$($latest.Version)" }

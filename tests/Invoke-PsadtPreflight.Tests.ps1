BeforeAll {
    $script:pf = Join-Path $PSScriptRoot '..\scripts\Invoke-PsadtPreflight.ps1'
    $script:utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    # Build a package folder from given file contents (all written UTF-8 WITHOUT BOM so the encoding
    # check sees the raw bytes - exactly what we want to assert on).
    function New-Pkg {
        # Since 0.21.0 a package without a manifest is RED (check 8), so the helper writes a complete
        # identity by default; -NoManifest / -PartialManifest exercise the gate itself.
        param([string]$Launcher, [string]$Ext, [string]$Bundled, [switch]$NoManifest, [switch]$PartialManifest)
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'Invoke-AppDeployToolkit.ps1'), $Launcher, $script:utf8NoBom)
        if (-not $NoManifest) {
            $mf = if ($PartialManifest) {
                @{ schema = 1; app = @{ name = 'OnlyAName' } }
            } else {
                @{ schema = 1
                   app     = @{ vendor = 'Contoso'; name = 'App'; version = '1.0'; arch = 'x64' }
                   package = @{ type = 'installer' } }
            }
            [System.IO.File]::WriteAllText((Join-Path $dir 'psadt-package.json'), ($mf | ConvertTo-Json -Depth 8), $script:utf8NoBom)
        }
        if ($Ext) {
            $ed = Join-Path $dir 'PSAppDeployToolkit.Extensions'; New-Item -ItemType Directory -Path $ed -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $ed 'PSAppDeployToolkit.Extensions.psm1'), $Ext, $script:utf8NoBom)
        }
        if ($Bundled) {
            $fd = Join-Path $dir 'Files'; New-Item -ItemType Directory -Path $fd -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $fd 'bundled.ps1'), $Bundled, $script:utf8NoBom)
        }
        return $dir
    }

    $script:cleanLauncher = @'
[CmdletBinding()]
param([string]$DeploymentType)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1
$adtSession = @{ AppName = 'X' }
function Install-ADTDeployment   { Invoke-MyHelper -FilesDirectory 'x' }
function Uninstall-ADTDeployment { }
function Repair-ADTDeployment    { Invoke-MyHelper -FilesDirectory 'x' }
try { & "$($adtSession.DeploymentType)-ADTDeployment" } catch { exit 60001 }
'@
    $script:cleanExt = @'
function Invoke-MyHelper { param($FilesDirectory) Write-ADTLogEntry -Message 'ok' }
'@
    # A bundled standalone script that defines its OWN Write-Log - must NOT be flagged as a v3 cmdlet.
    $script:cleanBundled = @'
function Write-Log { param($Message) }
Write-Log 'hi'
exit 0
'@
}

Describe 'Invoke-PsadtPreflight' {

    It 'returns GREEN for a clean, well-formed package' {
        $pkg = New-Pkg -Launcher $script:cleanLauncher -Ext $script:cleanExt -Bundled $script:cleanBundled
        $r = & $script:pf -PackagePath $pkg
        $r.Overall | Should -Be 'GREEN'
        ($r.Checks | Where-Object { $_.Status -eq 'FAIL' }).Count | Should -Be 0
    }

    It 'does NOT flag a private Write-Log inside a bundled Files\ script' {
        $pkg = New-Pkg -Launcher $script:cleanLauncher -Ext $script:cleanExt -Bundled $script:cleanBundled
        $r = & $script:pf -PackagePath $pkg
        # the bundled file is encoding+parse only; no v3-cmdlets check is run against it
        ($r.Checks | Where-Object { $_.File -eq 'bundled.ps1' -and $_.Name -eq 'v3-cmdlets' }).Count | Should -Be 0
        $r.Overall | Should -Be 'GREEN'
    }

    It 'is RED on non-ASCII WITHOUT a BOM (em-dash) in the launcher' {
        $bad = "# note " + [char]0x2014 + " emdash`n" + $script:cleanLauncher
        $pkg = New-Pkg -Launcher $bad -Ext $script:cleanExt
        $r = & $script:pf -PackagePath $pkg
        $r.Overall | Should -Be 'RED'
        ($r.Checks | Where-Object { $_.Name -eq 'Encoding' -and $_.Status -eq 'FAIL' }).Count | Should -BeGreaterThan 0
    }

    It 'is RED on a PSADT v3 cmdlet in the launcher' {
        $bad = $script:cleanLauncher -replace "Uninstall-ADTDeployment \{ \}", "Uninstall-ADTDeployment { Execute-Process -Path 'x.exe' }"
        $pkg = New-Pkg -Launcher $bad -Ext $script:cleanExt
        $r = & $script:pf -PackagePath $pkg
        $r.Overall | Should -Be 'RED'
        ($r.Checks | Where-Object { $_.Name -eq 'v3-cmdlets' -and $_.Status -eq 'FAIL' }).Count | Should -BeGreaterThan 0
    }

    It 'is RED on a GUID passed to Start-ADTMsiProcess -FilePath' {
        $bad = $script:cleanLauncher -replace "Uninstall-ADTDeployment \{ \}", "Uninstall-ADTDeployment { Start-ADTMsiProcess -FilePath '{12345678-1234-1234-1234-123456789012}' }"
        $pkg = New-Pkg -Launcher $bad -Ext $script:cleanExt
        $r = & $script:pf -PackagePath $pkg
        $r.Overall | Should -Be 'RED'
        ($r.Checks | Where-Object { $_.Name -eq 'ProductCode' -and $_.Status -eq 'FAIL' }).Count | Should -BeGreaterThan 0
    }

    It 'is RED when a deployment hook is missing' {
        $bad = $script:cleanLauncher -replace "function Repair-ADTDeployment    \{ Invoke-MyHelper -FilesDirectory 'x' \}", ""
        $pkg = New-Pkg -Launcher $bad -Ext $script:cleanExt
        $r = & $script:pf -PackagePath $pkg
        $r.Overall | Should -Be 'RED'
        ($r.Checks | Where-Object { $_.Name -eq 'Structure' -and $_.Status -eq 'FAIL' -and $_.Detail -match 'Repair-ADTDeployment MISSING' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Pre-flight check 8/9: manifest + per-run log (0.21.0)' {
    BeforeAll {
        # A minimal launcher that satisfies checks 1-7 so the verdict only reflects 8 and 9.
        $script:goodLauncher = @'
[CmdletBinding()]
param([string]$DeploymentType)
$adtSession = @{
    AppName = 'App'
    LogName = ('Contoso_App_1.0_x64' + '_' + $(if ($DeploymentType) { $DeploymentType } else { 'Install' }) + '_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
}
function Install-ADTDeployment { }
function Uninstall-ADTDeployment { }
function Repair-ADTDeployment { }
try { Set-StrictMode -Version 3 } catch { }
'@
    }

    It 'is GREEN with a complete manifest and a per-run log name' {
        $r = & $script:pf -PackagePath (New-Pkg -Launcher $script:goodLauncher)
        ($r.Checks | Where-Object { $_.Name -eq 'Manifest' }).Status | Should -Be 'PASS'
        ($r.Checks | Where-Object { $_.Name -eq 'LogName' }).Status  | Should -Be 'PASS'
        $r.Overall | Should -Be 'GREEN'
    }

    It 'is RED without a manifest - the package cannot say what it is' {
        $r = & $script:pf -PackagePath (New-Pkg -Launcher $script:goodLauncher -NoManifest)
        $m = $r.Checks | Where-Object { $_.Name -eq 'Manifest' }
        $m.Status | Should -Be 'FAIL'
        $m.Detail | Should -BeLike '*no psadt-package.json*'
        $r.Overall | Should -Be 'RED'
    }

    It 'is RED with an incomplete identity and names the missing keys' {
        $r = & $script:pf -PackagePath (New-Pkg -Launcher $script:goodLauncher -PartialManifest)
        $m = $r.Checks | Where-Object { $_.Name -eq 'Manifest' }
        $m.Status | Should -Be 'FAIL'
        $m.Detail | Should -BeLike '*app.vendor*'
        $r.Overall | Should -Be 'RED'
    }

    It 'reports the artifact stem it would produce' {
        $r = & $script:pf -PackagePath (New-Pkg -Launcher $script:goodLauncher)
        ($r.Checks | Where-Object { $_.Name -eq 'Manifest' }).Detail | Should -BeLike '*Contoso_App_1.0_x64*'
    }

    It 'WARNs (not FAILs) about a pre-0.21 launcher with no LogName' {
        $old = $script:goodLauncher -replace "(?m)^\s*LogName.*$", ''
        $r = & $script:pf -PackagePath (New-Pkg -Launcher $old)
        ($r.Checks | Where-Object { $_.Name -eq 'LogName' }).Status | Should -Be 'WARN'
        $r.Overall | Should -Be 'GREEN'      # a WARN never flips the verdict
    }
}

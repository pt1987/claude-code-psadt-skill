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

Describe 'Pre-flight check 10: DriverTrust (0.22.0)' {
    BeforeAll {
        $script:driverLauncher = @'
[CmdletBinding()]
param([string]$DeploymentType)
$adtSession = @{
    AppName = 'App'
    LogName = ('Contoso_App_1.0_x64' + '_' + $(if ($DeploymentType) { $DeploymentType } else { 'Install' }) + '_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
}
function Install-ADTDeployment { }
function Uninstall-ADTDeployment { }
function Repair-ADTDeployment { }
'@
    }
    BeforeEach {
        # A package whose Files\ holds a driver set. The .cat is what the classifier inspects.
        $script:pkg = New-Pkg -Launcher $script:driverLauncher
        $script:drv = Join-Path $script:pkg 'Files\Drivers'
        New-Item $script:drv -ItemType Directory -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:drv 'mxdriver.inf'), @"
[Version]
Class=Printer
Provider=%MfgName%
DriverVer=07/14/2026,3.1.4.0
CatalogFile=mxdriver.cat

[Strings]
MfgName="Mobotix AG"
"@, $script:utf8NoBom)
        $script:setOwner = {
            param([string]$Owner, [bool]$AssumeOff = $false)
            $mfPath = Join-Path $script:pkg 'psadt-package.json'
            $m = Get-Content $mfPath -Raw | ConvertFrom-Json
            $m | Add-Member -NotePropertyName driverTrust -NotePropertyValue ([pscustomobject]@{ owner = $Owner; assumeSecureBootOff = $AssumeOff }) -Force
            $m | ConvertTo-Json -Depth 10 | Set-Content $mfPath -Encoding UTF8
        }
    }

    It 'is skipped entirely for a package without drivers - no DriverTrust row at all' {
        $plain = New-Pkg -Launcher $script:driverLauncher
        $r = & $script:pf -PackagePath $plain
        @($r.Checks | Where-Object { $_.Name -eq 'DriverTrust' }).Count | Should -Be 0
    }

    It 'is RED for an unsigned driver (no catalog on disk)' {
        # No .cat file -> Unsigned, whatever the INF claims.
        $r = & $script:pf -PackagePath $script:pkg
        $d = $r.Checks | Where-Object { $_.Name -eq 'DriverTrust' }
        $d.Status | Should -Be 'FAIL'
        $d.Detail | Should -BeLike '*unsigned*'
        $r.Overall | Should -Be 'RED'
    }

    It 'is RED for a vendor-signed driver whose certificate has no owner' {
        Set-Content (Join-Path $script:drv 'mxdriver.cat') 'catalog' -NoNewline
        Mock -CommandName Get-AuthenticodeSignature -MockWith {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Mobotix AG'; Thumbprint = 'AA' } }
        }
        $r = & $script:pf -PackagePath $script:pkg
        $d = $r.Checks | Where-Object { $_.Name -eq 'DriverTrust' }
        $d.Status | Should -Be 'FAIL'
        $d.Detail | Should -BeLike '*driverTrust.owner*'
        $r.Overall | Should -Be 'RED'
    }

    It 'WARNs for a vendor-signed KERNEL driver once the owner is set' {
        Set-Content (Join-Path $script:drv 'mxdriver.cat') 'catalog' -NoNewline
        Set-Content (Join-Path $script:drv 'mxdriver.sys') 'kernel' -NoNewline
        & $script:setOwner 'policy'
        Mock -CommandName Get-AuthenticodeSignature -MockWith {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Mobotix AG'; Thumbprint = 'AA' } }
        }
        $r = & $script:pf -PackagePath $script:pkg
        $d = $r.Checks | Where-Object { $_.Name -eq 'DriverTrust' }
        $d.Status | Should -Be 'WARN'
        $d.Detail | Should -BeLike '*Code Integrity*'
        $r.Overall | Should -Be 'GREEN'      # a WARN never flips the verdict
    }

    It 'PASSes a Microsoft-signed driver with no certificate work at all' {
        Set-Content (Join-Path $script:drv 'mxdriver.cat') 'catalog' -NoNewline
        Mock -CommandName Get-AuthenticodeSignature -MockWith {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation'; Thumbprint = 'BB' } }
        }
        $r = & $script:pf -PackagePath $script:pkg
        ($r.Checks | Where-Object { $_.Name -eq 'DriverTrust' }).Status | Should -Be 'PASS'
        $r.Overall | Should -Be 'GREEN'
    }
}

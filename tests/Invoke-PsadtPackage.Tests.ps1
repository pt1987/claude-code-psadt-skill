#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/Invoke-PsadtPackage.ps1 - the one packaging command. IntuneWinAppUtil is replaced by
    a stub (-ToolPath) that writes a structurally valid dummy .intunewin, so the naming convention, the
    verification, the "-o must not be inside -c" refusal and the manifest write-back are all covered without
    the real tool or a real package.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:Pack = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Invoke-PsadtPackage.ps1')).Path
    $script:SetMf = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Set-PsadtPackageManifest.ps1')).Path

    # A stub that mimics IntuneWinAppUtil: same CLI, and it produces an archive with the two members the
    # real tool produces (Metadata\Detection.xml + Contents\IntunePackage.intunewin).
    function New-ToolStub([string]$Dir, [int64]$UnencSize = 4096) {
        $p = Join-Path $Dir 'IntuneWinAppUtilStub.ps1'
        $body = @'
param([string]$c, [string]$s, [string]$o, [switch]$q)
$stage = Join-Path ([IO.Path]::GetTempPath()) ("stub-" + [guid]::NewGuid().ToString('N'))
New-Item (Join-Path $stage 'IntuneWinPackage\Metadata')  -ItemType Directory -Force | Out-Null
New-Item (Join-Path $stage 'IntuneWinPackage\Contents')  -ItemType Directory -Force | Out-Null
$setupLeaf = [IO.Path]::GetFileName($s)
@"
<ApplicationInfo ToolVersion="1.8.7">
  <Name>stub</Name>
  <UnencryptedContentSize>__SIZE__</UnencryptedContentSize>
  <FileName>IntunePackage.intunewin</FileName>
  <SetupFile>$setupLeaf</SetupFile>
  <EncryptionInfo><EncryptionKey>k</EncryptionKey><MacKey>m</MacKey><InitializationVector>iv</InitializationVector><Mac>mac</Mac><ProfileIdentifier>ProfileVersion1</ProfileIdentifier><FileDigest>d</FileDigest><FileDigestAlgorithm>SHA256</FileDigestAlgorithm></EncryptionInfo>
</ApplicationInfo>
"@ | Set-Content (Join-Path $stage 'IntuneWinPackage\Metadata\Detection.xml') -Encoding UTF8
Set-Content (Join-Path $stage 'IntuneWinPackage\Contents\IntunePackage.intunewin') 'encrypted-blob' -NoNewline
$outFile = Join-Path $o ([IO.Path]::GetFileNameWithoutExtension($s) + '.intunewin')
Compress-Archive -Path (Join-Path $stage 'IntuneWinPackage') -DestinationPath $outFile -Force
Remove-Item $stage -Recurse -Force
exit 0
'@
        Set-Content -LiteralPath $p -Value ($body -replace '__SIZE__', $UnencSize) -Encoding UTF8
        return $p
    }

    function New-TempPackage {
        $p = Join-Path ([IO.Path]::GetTempPath()) ("pkg_" + [guid]::NewGuid().ToString('N'))
        New-Item $p -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $p 'Invoke-AppDeployToolkit.ps1') '# launcher' -NoNewline
        Set-Content (Join-Path $p 'Invoke-AppDeployToolkit.exe') 'MZ' -NoNewline
        return $p
    }
    function Get-Manifest([string]$PackagePath) {
        Get-Content (Join-Path $PackagePath 'psadt-package.json') -Raw | ConvertFrom-Json
    }
}

Describe 'Invoke-PsadtPackage' {
    BeforeEach {
        $script:pkg  = New-TempPackage
        $script:out  = Join-Path ([IO.Path]::GetTempPath()) ("outroot_" + [guid]::NewGuid().ToString('N'))
        New-Item $script:out -ItemType Directory -Force | Out-Null
        $script:tool = New-ToolStub -Dir $script:out
        & $script:SetMf -PackagePath $script:pkg -Updates @{
            'app.vendor' = 'Mobotix'; 'app.name' = 'MxManagementCenter'; 'app.version' = '2.9.1'
            'app.arch' = 'x64'; 'package.type' = 'installer'
        } | Out-Null
    }
    AfterEach {
        Remove-Item $script:pkg -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $script:out -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'names the artifact and its folder after the identity, not after the setup file' {
        $r = & $script:Pack -PackagePath $script:pkg -OutputRoot $script:out -ToolPath $script:tool

        $r.Stem         | Should -Be 'Mobotix_MxManagementCenter_2.9.1_x64'
        $r.OutputFolder | Should -Be (Join-Path $script:out 'Mobotix_MxManagementCenter_2.9.1_x64')
        $r.IntuneWin    | Should -Be (Join-Path $r.OutputFolder 'Mobotix_MxManagementCenter_2.9.1_x64.intunewin')
        (Test-Path $r.IntuneWin) | Should -BeTrue
        # The generic name the tool produced must not survive anywhere.
        (Test-Path (Join-Path $r.OutputFolder 'Invoke-AppDeployToolkit.intunewin')) | Should -BeFalse
    }

    It 'keeps the SetupFile from the INNER Detection.xml (which is why renaming is safe)' {
        $r = & $script:Pack -PackagePath $script:pkg -OutputRoot $script:out -ToolPath $script:tool
        $r.SetupFile        | Should -Be 'Invoke-AppDeployToolkit.exe'
        $r.UnencryptedSize  | Should -Be 4096
        $r.Sha256           | Should -Match '^[0-9A-F]{64}$'
    }

    It 'sanitizes a messy identity into a usable file name' {
        & $script:SetMf -PackagePath $script:pkg -Updates @{ 'app.vendor' = 'Muenchener Rueck AG'; 'app.name' = 'Tool: Pro/Max' } | Out-Null
        $r = & $script:Pack -PackagePath $script:pkg -OutputRoot $script:out -ToolPath $script:tool
        $r.Stem | Should -Be 'Muenchener_Rueck_AG_Tool_Pro_Max_2.9.1_x64'
        [IO.Path]::GetFileName($r.IntuneWin) | Should -Not -Match '[^A-Za-z0-9._-]'
    }

    It 'refuses an output folder inside the package - that is the -o-inside-c bug' {
        { & $script:Pack -PackagePath $script:pkg -OutputRoot $script:pkg -ToolPath $script:tool -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*inside the package folder*'
        { & $script:Pack -PackagePath $script:pkg -OutputRoot (Join-Path $script:pkg 'Output') -ToolPath $script:tool -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*inside the package folder*'
    }

    It 'refuses to pack an incomplete identity instead of producing a half-named file' {
        $bare = New-TempPackage
        try {
            { & $script:Pack -PackagePath $bare -OutputRoot $script:out -ToolPath $script:tool -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*No psadt-package.json*'
            & $script:SetMf -PackagePath $bare -Updates @{ 'app.name' = 'OnlyAName' } | Out-Null
            { & $script:Pack -PackagePath $bare -OutputRoot $script:out -ToolPath $script:tool -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*identity is incomplete*'
        }
        finally { Remove-Item $bare -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'warns about a foreign .intunewin in the target folder and never deletes it' {
        $folder = Join-Path $script:out 'Mobotix_MxManagementCenter_2.9.1_x64'
        New-Item $folder -ItemType Directory -Force | Out-Null
        $legacy = Join-Path $folder 'Invoke-AppDeployToolkit.intunewin'
        Set-Content $legacy 'legacy-build' -NoNewline

        $r = & $script:Pack -PackagePath $script:pkg -OutputRoot $script:out -ToolPath $script:tool -WarningAction SilentlyContinue

        ($r.Warnings -join ' ') | Should -BeLike '*Invoke-AppDeployToolkit.intunewin*'
        (Test-Path $legacy)     | Should -BeTrue
        (Get-Content $legacy -Raw) | Should -Be 'legacy-build'
    }

    It 'copies the detection script next to the artifact' {
        Set-Content (Join-Path $script:pkg 'Detect-MxManagementCenter.ps1') '# detect' -NoNewline
        $r = & $script:Pack -PackagePath $script:pkg -OutputRoot $script:out -ToolPath $script:tool
        $r.Detection | Should -Be (Join-Path $r.OutputFolder 'Detect-MxManagementCenter.ps1')
        (Test-Path $r.Detection) | Should -BeTrue
    }

    It 'warns when the package has no detection script' {
        $r = & $script:Pack -PackagePath $script:pkg -OutputRoot $script:out -ToolPath $script:tool -WarningAction SilentlyContinue
        ($r.Warnings -join ' ') | Should -BeLike '*Detect*'
        $r.Detection | Should -BeNullOrEmpty
    }

    It 'copies a real logo but never the PSADT defaults' {
        New-Item (Join-Path $script:pkg 'Assets') -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $script:pkg 'Assets\AppIcon.png') 'default' -NoNewline
        Set-Content (Join-Path $script:pkg 'Assets\MxManagementCenter.png') 'real-logo' -NoNewline
        $r = & $script:Pack -PackagePath $script:pkg -OutputRoot $script:out -ToolPath $script:tool
        [IO.Path]::GetFileName($r.Logo) | Should -Be 'MxManagementCenter.png'
    }

    It 'records artifacts and results.package in the manifest' {
        $r = & $script:Pack -PackagePath $script:pkg -OutputRoot $script:out -ToolPath $script:tool
        $m = Get-Manifest $script:pkg
        $m.package.name            | Should -Be $r.Stem
        $m.artifacts.intunewin     | Should -Be $r.IntuneWin
        $m.artifacts.outputFolder  | Should -Be $r.OutputFolder
        $m.results.package.verdict | Should -Be 'OK'
        $m.results.package.sha256  | Should -Be $r.Sha256
        $m.results.package.packedAt| Should -Not -BeNullOrEmpty
    }

    It 'replaces its own previous build without touching anything else' {
        $first  = & $script:Pack -PackagePath $script:pkg -OutputRoot $script:out -ToolPath $script:tool
        $second = & $script:Pack -PackagePath $script:pkg -OutputRoot $script:out -ToolPath $script:tool
        $second.IntuneWin | Should -Be $first.IntuneWin
        @(Get-ChildItem $second.OutputFolder -Filter '*.intunewin').Count | Should -Be 1
    }

    It 'throws when the setup file is not in the package' {
        Remove-Item (Join-Path $script:pkg 'Invoke-AppDeployToolkit.exe') -Force
        { & $script:Pack -PackagePath $script:pkg -OutputRoot $script:out -ToolPath $script:tool -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*Setup file not found*'
    }
}

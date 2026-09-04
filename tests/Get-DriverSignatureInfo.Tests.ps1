#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/Get-DriverSignatureInfo.ps1 - the driver trust classifier. Get-AuthenticodeSignature
    is mocked throughout: the point is the CLASSIFICATION logic, and no real signed driver can be checked
    into a repo. The one rule worth more than all the others: a valid vendor signature on a KERNEL-mode
    driver is RED, not amber - TrustedPublisher satisfies the PnP install prompt, never Code Integrity.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:Classify = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Get-DriverSignatureInfo.ps1')).Path

    # Signer subjects as they really appear.
    $script:SignerWhql   = 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    $script:SignerInbox  = 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    $script:SignerVendor = 'CN=Mobotix AG, O=Mobotix AG, L=Langmeil, C=DE'

    function New-DriverDir {
        param(
            [string]$CatalogLine = 'CatalogFile=mxdriver.cat',
            [switch]$NoCatalogFile,      # do not create the .cat on disk
            [switch]$NoVersionSection,
            [switch]$UserModeOnly,       # no .sys -> not kernel mode
            [string]$InfName = 'mxdriver.inf'
        )
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("drv_" + [guid]::NewGuid().ToString('N'))
        New-Item $dir -ItemType Directory -Force | Out-Null
        $inf = if ($NoVersionSection) {
            @"
[Manufacturer]
%MfgName%=Models,NTamd64
"@
        } else {
            @"
[Version]
Signature="`$WINDOWS NT`$"
Class=Printer
ClassGuid={4d36e979-e325-11ce-bfc1-08002be10318}
Provider=%MfgName%
DriverVer=07/14/2026,3.1.4.0
$CatalogLine

[Manufacturer]
%MfgName%=Models,NTamd64

[Strings]
MfgName="Mobotix AG"
"@
        }
        Set-Content (Join-Path $dir $InfName) $inf -Encoding ASCII
        if (-not $NoCatalogFile) { Set-Content (Join-Path $dir 'mxdriver.cat') 'catalog-bytes' -NoNewline }
        if (-not $UserModeOnly)  { Set-Content (Join-Path $dir 'mxdriver.sys') 'kernel-bytes'  -NoNewline }
        return $dir
    }

    # The signer subjects live INSIDE this function on purpose: a mock body runs in the scope of the script
    # under test, where the test file's $script: variables are not visible - passing 'whql' and resolving
    # here is the only way that stays readable.
    function New-FakeSignature([string]$Status, [string]$Kind = 'none') {
        $subject = switch ($Kind) {
            'whql'   { 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }
            'inbox'  { 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }
            'vendor' { 'CN=Mobotix AG, O=Mobotix AG, L=Langmeil, C=DE' }
            default  { $null }
        }
        $cert = if ($subject) { [pscustomobject]@{ Subject = $subject; Thumbprint = 'AABBCCDDEEFF00112233445566778899AABBCCDD' } } else { $null }
        return [pscustomobject]@{ Status = $Status; SignerCertificate = $cert; StatusMessage = $Status }
    }
}

Describe 'Get-DriverSignatureInfo: INF parsing' {
    BeforeEach { $script:dir = $null }
    AfterEach  { if ($script:dir) { Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue } }

    It 'reads Class, Provider, DriverVer and the catalog from [Version]' {
        $script:dir = New-DriverDir
        Mock -CommandName Get-AuthenticodeSignature -MockWith { New-FakeSignature 'Valid' 'vendor' }

        $r = & $script:Classify -Path $script:dir
        $d = @($r.Drivers)[0]
        $d.Inf          | Should -Be 'mxdriver.inf'
        $d.Class        | Should -Be 'Printer'
        $d.Provider     | Should -Be 'Mobotix AG'
        $d.DriverVer    | Should -Be '3.1.4.0'
        $d.CatalogFile  | Should -Be 'mxdriver.cat'
    }

    It 'falls back to the INF basename when CatalogFile is absent' {
        $script:dir = New-DriverDir -CatalogLine ''
        Mock -CommandName Get-AuthenticodeSignature -MockWith { New-FakeSignature 'Valid' 'vendor' }
        @($r = & $script:Classify -Path $script:dir)
        @($r.Drivers)[0].CatalogFile | Should -Be 'mxdriver.cat'
    }

    It 'checks the .cat, NOT the .sys - a dual-signed .sys reports only its primary signature' {
        $script:dir = New-DriverDir
        Mock -CommandName Get-AuthenticodeSignature -MockWith { New-FakeSignature 'Valid' 'whql' }
        & $script:Classify -Path $script:dir | Out-Null
        Should -Invoke Get-AuthenticodeSignature -ParameterFilter { $FilePath -like '*.cat' }
        Should -Invoke Get-AuthenticodeSignature -Times 0 -ParameterFilter { $FilePath -like '*.sys' }
    }

    It 'accepts a single .inf path as well as a folder' {
        $script:dir = New-DriverDir
        Mock -CommandName Get-AuthenticodeSignature -MockWith { New-FakeSignature 'Valid' 'whql' }
        $r = & $script:Classify -Path (Join-Path $script:dir 'mxdriver.inf')
        @($r.Drivers).Count | Should -Be 1
    }

    It 'throws when there is no INF at all' {
        $empty = Join-Path ([IO.Path]::GetTempPath()) ("noinf_" + [guid]::NewGuid().ToString('N'))
        New-Item $empty -ItemType Directory -Force | Out-Null
        try { { & $script:Classify -Path $empty -ErrorAction Stop } | Should -Throw -ExpectedMessage '*no *.inf*' }
        finally { Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-DriverSignatureInfo: the classification matrix' {
    AfterEach { if ($script:dir) { Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue } }

    It 'MicrosoftSigned + GREEN for the WHQL/Attestation publisher' {
        $script:dir = New-DriverDir
        Mock -CommandName Get-AuthenticodeSignature -MockWith { New-FakeSignature 'Valid' 'whql' }
        $r = & $script:Classify -Path $script:dir
        @($r.Drivers)[0].Classification | Should -Be 'MicrosoftSigned'
        $r.Overall | Should -Be 'GREEN'
    }

    It 'MicrosoftSigned + GREEN for an inbox CN=Microsoft Windows driver' {
        $script:dir = New-DriverDir
        Mock -CommandName Get-AuthenticodeSignature -MockWith { New-FakeSignature 'Valid' 'inbox' }
        (& $script:Classify -Path $script:dir).Overall | Should -Be 'GREEN'
    }

    It 'VendorSigned + RED for a kernel-mode driver - Secure Boot will not load it' {
        $script:dir = New-DriverDir     # has a .sys
        Mock -CommandName Get-AuthenticodeSignature -MockWith { New-FakeSignature 'Valid' 'vendor' }
        $r = & $script:Classify -Path $script:dir
        $d = @($r.Drivers)[0]
        $d.Classification | Should -Be 'VendorSigned'
        $d.KernelMode     | Should -BeTrue
        $r.Overall        | Should -Be 'RED'
        ($r.Hints -join ' ') | Should -BeLike '*Code Integrity*'
    }

    It 'downgrades that to YELLOW with -AssumeSecureBootOff (a real, recorded exception)' {
        $script:dir = New-DriverDir
        Mock -CommandName Get-AuthenticodeSignature -MockWith { New-FakeSignature 'Valid' 'vendor' }
        $r = & $script:Classify -Path $script:dir -AssumeSecureBootOff
        $r.Overall | Should -Be 'YELLOW'
        ($r.Hints -join ' ') | Should -BeLike '*driverTrust*'
    }

    It 'VendorSigned + YELLOW for a user-mode driver (the TrustedPublisher path)' {
        $script:dir = New-DriverDir -UserModeOnly
        Mock -CommandName Get-AuthenticodeSignature -MockWith { New-FakeSignature 'Valid' 'vendor' }
        $r = & $script:Classify -Path $script:dir
        @($r.Drivers)[0].KernelMode | Should -BeFalse
        $r.Overall | Should -Be 'YELLOW'
        ($r.Hints -join ' ') | Should -BeLike '*TrustedPublisher*'
    }

    It 'Unsigned + RED when there is no catalog file' {
        $script:dir = New-DriverDir -NoCatalogFile
        Mock -CommandName Get-AuthenticodeSignature -MockWith { New-FakeSignature 'Valid' 'vendor' }
        $r = & $script:Classify -Path $script:dir
        @($r.Drivers)[0].Classification | Should -Be 'Unsigned'
        $r.Overall | Should -Be 'RED'
    }

    It 'Unsigned + RED for NotSigned and for HashMismatch' {
        foreach ($status in 'NotSigned', 'HashMismatch') {
            $script:dir = New-DriverDir
            Mock -CommandName Get-AuthenticodeSignature -MockWith { New-FakeSignature $status 'none' }
            $r = & $script:Classify -Path $script:dir
            @($r.Drivers)[0].Classification | Should -Be 'Unsigned'
            $r.Overall | Should -Be 'RED'
            Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue
            $script:dir = $null
        }
    }

    It 'offers three honest options for an unsigned driver and NEVER testsigning' {
        $script:dir = New-DriverDir -NoCatalogFile
        Mock -CommandName Get-AuthenticodeSignature -MockWith { New-FakeSignature 'Valid' 'vendor' }
        $r = & $script:Classify -Path $script:dir
        @($r.Options).Count | Should -Be 3
        $joined = ($r.Options -join ' ')
        $joined | Should -BeLike '*vendor*'
        $joined | Should -BeLike '*ttestation*'      # Attestation signing by the vendor
        $joined | Should -BeLike '*lab*'
        # The skill must never TELL anyone to weaken a machine. Saying that it refuses to is fine - and
        # useful - so assert on the instruction, not on the word: no bcdedit, and the refusal is spelled out.
        $joined | Should -Not -Match '(?i)bcdedit'
        $joined | Should -Match '(?i)never enables testsigning'
    }

    It 'passes the signer certificate through for the TrustedPublisher policy' {
        $script:dir = New-DriverDir -UserModeOnly
        Mock -CommandName Get-AuthenticodeSignature -MockWith { New-FakeSignature 'Valid' 'vendor' }
        $d = @((& $script:Classify -Path $script:dir).Drivers)[0]
        $d.SignerSubject    | Should -BeLike 'CN=Mobotix AG*'
        $d.SignerThumbprint | Should -Be 'AABBCCDDEEFF00112233445566778899AABBCCDD'
        $d.SignerCert       | Should -Not -BeNullOrEmpty
    }

    It 'takes the WORST verdict across several INFs' {
        $script:dir = New-DriverDir -UserModeOnly
        Set-Content (Join-Path $script:dir 'second.inf') "[Version]`nClass=Printer`nProvider=X`nDriverVer=01/01/2026,1.0`nCatalogFile=second.cat" -Encoding ASCII
        Mock -CommandName Get-AuthenticodeSignature -MockWith {
            if ($FilePath -like '*second.cat') { New-FakeSignature 'NotSigned' 'none' }
            else { New-FakeSignature 'Valid' 'vendor' }
        }
        $r = & $script:Classify -Path $script:dir
        @($r.Drivers).Count | Should -Be 2
        $r.Overall | Should -Be 'RED'          # one unsigned INF poisons the package
    }

    It 'emits parseable JSON with -Json' {
        $script:dir = New-DriverDir
        Mock -CommandName Get-AuthenticodeSignature -MockWith { New-FakeSignature 'Valid' 'whql' }
        $json = & $script:Classify -Path $script:dir -Json
        { $json | ConvertFrom-Json } | Should -Not -Throw
        ($json | ConvertFrom-Json).Overall | Should -Be 'GREEN'
    }
}

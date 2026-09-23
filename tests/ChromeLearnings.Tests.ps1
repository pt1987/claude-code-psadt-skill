# SCOPE NOTE (0.44.0): every learning of the Google Chrome 154 run, held as behaviour rather than prose.
#
#   1. Self-updating apps are asked about before the scaffold (the ladder's 'self-updating' question),
#      and a previous build with a different ProductCode reaches the researcher as KnownContext.
#   2. Research that was sent out must come back before the package moves: the ladder records it per
#      installer SHA256, pre-flight's Research check stays RED until research.answers.<id> exists, and
#      packing / the sandbox refuse a RED or stale pre-flight (Test-PsadtPreflightCurrent.ps1).
#   3. The upload takes what the manifest already recorded (artifacts, description) and refuses an MSI
#      ProductCode rule on a version-floor package.
#   4. The dossier reads what the pipeline already produced: the description, the recorded pre-flight
#      checks and the launcher's '##' rationale per hook.
#   5. The sandbox names its live progress file before anything can buffer its output.

BeforeAll {
    $script:scripts = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts')).ProviderPath
    $script:utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    function Get-Code([string]$Name) {
        # Source with comments blanked, so a guard never matches the comment that explains it.
        $raw = Get-Content -LiteralPath (Join-Path $script:scripts $Name) -Raw
        $tokens = $null
        [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$tokens, [ref]$null) | Out-Null
        $b = [System.Text.StringBuilder]::new($raw)
        foreach ($t in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
            $len = $t.Extent.EndOffset - $t.Extent.StartOffset
            [void]$b.Remove($t.Extent.StartOffset, $len); [void]$b.Insert($t.Extent.StartOffset, (' ' * $len))
        }
        $b.ToString()
    }
    function New-GatePkg {
        param([hashtable]$Manifest, [string]$InstallerBytes)
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $launcher = @'
[CmdletBinding()]
param([string]$DeploymentType)
$adtSession = @{ AppName = 'X' }
function Install-ADTDeployment
{
    ## Why this install looks the way it does,
    ## wrapped over two lines.
    Start-ADTMsiProcess -Action Install -FilePath 'x.msi'
}
function Uninstall-ADTDeployment
{
    ##================================================
    ## MARK: Uninstall
    ##================================================
    Uninstall-ADTApplication -Name 'X' -NameMatch Exact -ApplicationType MSI
}
function Repair-ADTDeployment { Start-ADTMsiProcess -Action Repair -ProductCode '{11111111-2222-3333-4444-555555555555}' }
try { & "$($adtSession.DeploymentType)-ADTDeployment" } catch { exit 60001 }
'@
        [System.IO.File]::WriteAllText((Join-Path $dir 'Invoke-AppDeployToolkit.ps1'), $launcher, $script:utf8NoBom)
        if ($InstallerBytes) {
            New-Item -ItemType Directory -Path (Join-Path $dir 'Files') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $dir 'Files\app.msi'), $InstallerBytes, $script:utf8NoBom)
        }
        $m = @{ schema = 1; app = @{ vendor = 'Contoso'; name = 'App'; version = '1.0'; arch = 'x64' }; package = @{ type = 'installer' } }
        if ($InstallerBytes) { $m.package.installerFile = 'app.msi' }
        if ($Manifest) { foreach ($k in @($Manifest.Keys)) { $m[$k] = $Manifest[$k] } }
        [System.IO.File]::WriteAllText((Join-Path $dir 'psadt-package.json'), ($m | ConvertTo-Json -Depth 8), $script:utf8NoBom)
        return $dir
    }
    function Get-Sha([string]$Pkg) { (Get-FileHash -LiteralPath (Join-Path $Pkg 'Files\app.msi') -Algorithm SHA256).Hash.ToLowerInvariant() }
}

Describe 'Learning 1 - the ladder asks about self-updating apps' {
    BeforeAll { $script:ladder = Get-Code 'Get-PsadtLocalEvidence.ps1' }

    It 'declares the question in the intune family, so it shares the pitfalls agent' {
        $script:ladder | Should -Match "New-Question 'self-updating'\s+'updates'.+'blocking' 'intune' \`$false"
    }
    It 'accepts it unanswered for a non-MSI - New-ExePackage already detects by a version floor' {
        $script:ladder | Should -Match "Set-Open \`$qSelfUpd '[^']+' 'accept-unanswered'"
    }
    It 'reads earlier packages of the same product and hands a different ProductCode to the agent' {
        $script:ladder | Should -Match "Get-ChildItem -LiteralPath \`$root -Filter 'psadt-package.json'"
        $script:ladder | Should -Match 'Previous package of this product: '
    }
    It 'gives the agent acceptance criteria that name the binary for a version floor' {
        $script:ladder | Should -Match "'self-updating'\s+= '.*version-floor detection"
    }
    It 'runs end to end without a binary and defers the question' {
        $old = $env:PSADT_DEPLOY_HOME
        $env:PSADT_DEPLOY_HOME = Join-Path $TestDrive 'home1'; New-Item -ItemType Directory -Path $env:PSADT_DEPLOY_HOME -Force | Out-Null
        try {
            New-Item -Path 'TestRegistry:\U1' -Force | Out-Null
            $r = & (Join-Path $script:scripts 'Get-PsadtLocalEvidence.ps1') -ProductName 'Nothing Here' -UninstallRoots 'TestRegistry:\U1' 6>$null
            $q = @($r.Questions | Where-Object Id -eq 'self-updating')
            $q.Count | Should -Be 1
            @($r.OpenQuestions | Where-Object Id -eq 'self-updating').Count | Should -Be 0
        } finally { $env:PSADT_DEPLOY_HOME = $old }
    }
}

Describe 'Learning 2 - research must be answered before the package moves' {
    BeforeEach {
        $script:oldHome = $env:PSADT_DEPLOY_HOME
        $env:PSADT_DEPLOY_HOME = Join-Path $TestDrive ('home_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $env:PSADT_DEPLOY_HOME 'evidence') -Force | Out-Null
    }
    AfterEach { $env:PSADT_DEPLOY_HOME = $script:oldHome }

    It 'the ladder records what it sent out, per installer hash' {
        (Get-Code 'Get-PsadtLocalEvidence.ps1') | Should -Match "'evidence'"
        (Get-Code 'Get-PsadtLocalEvidence.ps1') | Should -Match 'MustAnswer = \$mustAnswer'
    }

    It 'pre-flight is RED while an open question has no recorded answer' {
        $pkg = New-GatePkg -InstallerBytes 'msi-a'
        @{ Sha256 = (Get-Sha $pkg); MustAnswer = @(@{ Id = 'intune-pitfalls'; Question = 'q'; Severity = 'important' }) } | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path $env:PSADT_DEPLOY_HOME "evidence\$(Get-Sha $pkg).json") -Encoding UTF8
        $r = & (Join-Path $script:scripts 'Invoke-PsadtPreflight.ps1') -PackagePath $pkg
        $c = @($r.Checks | Where-Object Name -eq 'Research')[0]
        $c.Status | Should -Be 'FAIL'
        $c.Detail | Should -Match 'intune-pitfalls'
        $r.Overall | Should -Be 'RED'
    }

    It 'pre-flight passes the check once research.answers.<id> is recorded' {
        $pkg = New-GatePkg -InstallerBytes 'msi-b' -Manifest @{ research = @{ answers = @{ 'intune-pitfalls' = 'none found (source)' } } }
        @{ Sha256 = (Get-Sha $pkg); MustAnswer = @(@{ Id = 'intune-pitfalls'; Question = 'q'; Severity = 'important' }) } | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path $env:PSADT_DEPLOY_HOME "evidence\$(Get-Sha $pkg).json") -Encoding UTF8
        $r = & (Join-Path $script:scripts 'Invoke-PsadtPreflight.ps1') -PackagePath $pkg
        @($r.Checks | Where-Object Name -eq 'Research')[0].Status | Should -Be 'PASS'
    }

    It 'pre-flight warns when the ladder never ran for this installer' {
        $pkg = New-GatePkg -InstallerBytes 'msi-c'
        $r = & (Join-Path $script:scripts 'Invoke-PsadtPreflight.ps1') -PackagePath $pkg
        @($r.Checks | Where-Object Name -eq 'Research')[0].Status | Should -Be 'WARN'
    }

    It 'records the checks in the manifest so the dossier can render them' {
        $pkg = New-GatePkg -InstallerBytes 'msi-d'
        & (Join-Path $script:scripts 'Invoke-PsadtPreflight.ps1') -PackagePath $pkg | Out-Null
        $m = Get-Content -LiteralPath (Join-Path $pkg 'psadt-package.json') -Raw | ConvertFrom-Json
        @($m.results.preflight.checks).Count | Should -BeGreaterThan 5
    }

    Context 'Test-PsadtPreflightCurrent' {
        It 'is not current without a recorded verdict' {
            $pkg = New-GatePkg
            $g = & (Join-Path $script:scripts 'Test-PsadtPreflightCurrent.ps1') -PackagePath $pkg
            $g.Current | Should -BeFalse
            $g.Reason | Should -Match 'no pre-flight verdict'
        }
        It 'is not current on a RED verdict' {
            $pkg = New-GatePkg -Manifest @{ results = @{ preflight = @{ verdict = 'RED'; at = (Get-Date).AddMinutes(5).ToUniversalTime().ToString('o') } } }
            (& (Join-Path $script:scripts 'Test-PsadtPreflightCurrent.ps1') -PackagePath $pkg).Current | Should -BeFalse
        }
        It 'is current on a GREEN verdict newer than every judged file' {
            $pkg = New-GatePkg -Manifest @{ results = @{ preflight = @{ verdict = 'GREEN'; at = (Get-Date).AddMinutes(5).ToUniversalTime().ToString('o') } } }
            (& (Join-Path $script:scripts 'Test-PsadtPreflightCurrent.ps1') -PackagePath $pkg).Current | Should -BeTrue
        }
        It 'goes stale when the launcher changes after the verdict' {
            $pkg = New-GatePkg -Manifest @{ results = @{ preflight = @{ verdict = 'GREEN'; at = (Get-Date).AddHours(-1).ToUniversalTime().ToString('o') } } }
            $g = & (Join-Path $script:scripts 'Test-PsadtPreflightCurrent.ps1') -PackagePath $pkg
            $g.Current | Should -BeFalse
            $g.Reason | Should -Match 'stale'
        }
        It 'a real pre-flight run makes it current' {
            $pkg = New-GatePkg
            & (Join-Path $script:scripts 'Invoke-PsadtPreflight.ps1') -PackagePath $pkg | Out-Null
            (& (Join-Path $script:scripts 'Test-PsadtPreflightCurrent.ps1') -PackagePath $pkg).Current | Should -BeTrue
        }
    }

    It 'packing refuses a package without a current GREEN pre-flight' {
        $pkg = New-GatePkg
        { & (Join-Path $script:scripts 'Invoke-PsadtPackage.ps1') -PackagePath $pkg -OutputRoot (Join-Path $TestDrive 'out') -ToolPath 'C:\none.exe' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*Not packing: no pre-flight verdict*'
    }

    It 'the sandbox test is gated too, except -GenerateOnly' {
        $code = Get-Code 'Invoke-PsadtSandboxTest.ps1'
        $code | Should -Match 'if \(-not \$GenerateOnly -and -not \$SkipPreflightGate\)'
        $code | Should -Match "Test-PsadtPreflightCurrent\.ps1"
        $gateAt = $code.IndexOf('Test-PsadtPreflightCurrent.ps1')
        $gateAt | Should -BeLessThan $code.IndexOf("Containers-DisposableClientVM")
    }
}

Describe 'Learning 3 - the upload takes what the manifest recorded' {
    BeforeAll { $script:up = Get-Code 'Invoke-IntuneWin32Upload.ps1' }

    It 'no longer requires -IntuneWinPath when a manifest names the artifact' {
        $script:up | Should -Not -Match '\[Parameter\(Mandatory\)\]\[string\]\$IntuneWinPath'
        $script:up | Should -Match '\$IntuneWinPath = \[string\]\$mfUp\.artifacts\.intunewin'
    }
    It 'takes logo and description from the manifest unless passed' {
        $script:up | Should -Match "ContainsKey\('LogoPath'\).+artifacts\.logo"
        $script:up | Should -Match "ContainsKey\('Description'\).+app\.description"
    }
    It 'refuses an MSI ProductCode rule on a version-floor package and uses its detection script' {
        $script:up | Should -Match "package\.detection -eq 'versionFloor'"
        $script:up | Should -Match 'if \(\$MsiProductCode\) \{\s+throw'
        $script:up | Should -Match '\$DetectionScriptPath = \[string\]\$mfUp\.artifacts\.detection'
    }
}

Describe 'Learning 4 - the dossier reads what the pipeline produced' {
    BeforeAll {
        $script:pkg = New-GatePkg -Manifest @{
            app = @{ vendor = 'Contoso'; name = 'App'; version = '1.0'; arch = 'x64'; description = @{ de = '**Beschreibung aus dem Manifest**'; en = '**Description from the manifest**' } }
        }
        & (Join-Path $script:scripts 'Invoke-PsadtPreflight.ps1') -PackagePath $script:pkg | Out-Null
        $script:html = Join-Path $TestDrive 'dossier.html'
        & (Join-Path $script:scripts 'New-PsadtReport.ps1') -ManifestPath (Join-Path $script:pkg 'psadt-package.json') -OutputPath $script:html -WarningAction SilentlyContinue | Out-Null
        $script:out = Get-Content -LiteralPath $script:html -Raw -Encoding UTF8
    }
    It 'renders the description recorded once in the manifest' {
        $script:out | Should -Match 'Beschreibung aus dem Manifest'
    }
    It 'renders the recorded pre-flight checks instead of "not run"' {
        $script:out | Should -Match 'Structure - Invoke-AppDeployToolkit\.ps1'
        $script:out | Should -Not -Match 'no results supplied'
    }
    It 'carries the launcher''s ## rationale into the hook, wrapped lines joined, MARK banners skipped' {
        $script:out | Should -Match 'Why this install looks the way it does, wrapped over two lines\.'
        $script:out | Should -Not -Match 'MARK: Uninstall'
    }
}

Describe 'Learning 5 - the sandbox names its live progress file first' {
    It 'prints the host path of progress.json right after the results folder exists' {
        $code = Get-Content -LiteralPath (Join-Path $script:scripts 'Invoke-PsadtSandboxTest.ps1') -Raw
        $made = $code.IndexOf('New-Item -ItemType Directory -Path $resultsFolder -Force')
        $told = $code.IndexOf('Live progress (host path')
        $made | Should -BeGreaterThan 0
        $told | Should -BeGreaterThan $made
        $told | Should -BeLessThan $code.IndexOf('# --- 4. Generate the in-sandbox runner')
    }
}

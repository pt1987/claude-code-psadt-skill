# SCOPE NOTE: one bug class, guarded mechanically.
#
# .NET file APIs resolve a relative path against the PROCESS working directory, which PowerShell's
# Set-Location does not change. Every script here mixes the two - it takes a path parameter, then reads
# or writes through [System.IO.File] - so a caller who passes '.' from a session located anywhere else
# gets "file not found" naming a directory they never mentioned.
#
# Found on 2026-09-14: Invoke-PsadtPreflight.ps1 -PackagePath . reported "Could not find
# Invoke-AppDeployToolkit.ps1" pointing at the SHELL's folder, for a package that was complete. The
# symptom accuses the package; the cause is two lines above it. Invoke-PsadtSandboxTest.ps1 already
# normalised its path, which is why the same call worked there - the inconsistency is the whole problem.
#
# The guard is deliberately structural rather than behavioural: it reads the source, so a new script
# that takes -PackagePath and forgets the normalisation fails here rather than in front of a user.

BeforeAll {
    $script:scriptDir = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts')).ProviderPath

    # Scripts that BOTH take a mandatory -PackagePath AND reach for a .NET file API.
    $script:candidates = @(
        Get-ChildItem -LiteralPath $script:scriptDir -Filter '*.ps1' -File | ForEach-Object {
            $text = Get-Content -LiteralPath $_.FullName -Raw
            if ($text -match '\[Parameter\(Mandatory\)\]\[string\]\$PackagePath') {
                [pscustomobject]@{ Name = $_.Name; Path = $_.FullName; Text = $text }
            }
        }
    )
}

Describe 'a path parameter is made absolute before any .NET file API sees it' {

    It 'still finds the scripts that take -PackagePath' {
        # Anti-vacuity: if the parameter is ever renamed, this test must fail loudly rather than pass
        # by matching nothing.
        $script:candidates.Count | Should -BeGreaterOrEqual 3
        @($script:candidates.Name) | Should -Contain 'Invoke-PsadtPreflight.ps1'
        @($script:candidates.Name) | Should -Contain 'Invoke-PsadtSandboxTest.ps1'
    }

    It 'normalises -PackagePath in every one of them' {
        $missing = @(
            $script:candidates | Where-Object {
                $_.Text -notmatch '\$PackagePath\s*=\s*\(Resolve-Path\s+-LiteralPath\s+\$PackagePath\)'
            } | ForEach-Object { $_.Name }
        )
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'a relative path reaches .NET unchanged and fails against the wrong directory'
    }
}

Describe 'Invoke-PsadtPreflight accepts a relative package path' {

    BeforeAll {
        # A package shaped just enough for the pre-flight to run: a launcher and a manifest.
        $script:pkg = Join-Path ([System.IO.Path]::GetTempPath()) ('relpath_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:pkg -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:pkg 'Invoke-AppDeployToolkit.ps1') -Value @'
function Install-ADTDeployment { }
function Uninstall-ADTDeployment { }
function Repair-ADTDeployment { }
'@ -Encoding UTF8
        $script:preflight = Join-Path $script:scriptDir 'Invoke-PsadtPreflight.ps1'
    }

    AfterAll {
        if ($script:pkg -and (Test-Path $script:pkg)) { Remove-Item $script:pkg -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not look for the launcher beside the shell instead of beside the package' {
        # The regression in one call: Set-Location into the package, pass '.', and the .NET reads must
        # land in the package. Before the fix this threw, naming a directory the caller never passed.
        $old = Get-Location
        try {
            Set-Location -LiteralPath $script:pkg
            $r = & $script:preflight -PackagePath '.'
            $r.Overall | Should -BeIn @('GREEN', 'RED')
            $r.PackagePath | Should -Not -Be '.'
        }
        finally { Set-Location $old }
    }
}

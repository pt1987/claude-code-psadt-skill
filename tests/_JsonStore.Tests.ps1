#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SCOPE NOTE: Write-JsonAtomic writes the package manifest, config.json and the verified-switch store,
# and until 0.49.1 it had no tests of its own. Two defects lived in it, both measured, both silent:
#
#   * The commit step was `Move-Item -Force`. When the target is held open by another process, Move-Item
#     raises a NON-terminating error: no exception reached the caller, the finally block deleted the temp
#     file, and the update was gone while every caller believed it had been written. Measured
#     2026-09-26 by holding the file open; the same day a Windows Sandbox run whose VM still had the
#     package folder mapped reported "being used by another process" and the package's
#     psadt-package.json was missing afterwards.
#   * The mutex name was derived with [SHA256]::HashData, which exists only from .NET 5 on. Under Windows
#     PowerShell 5.1 every write threw - including config.json from New-PsadtEntraApp.ps1, a script that
#     promises 5.1 and writes the config only AFTER it has created the app and a secret that is never
#     displayed.

BeforeAll {
    $script:store = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\_JsonStore.ps1')).Path
    . $script:store
}

Describe 'Write-JsonAtomic' {
    BeforeEach {
        $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) ("jsonstore_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        $script:file = Join-Path $script:dir 'psadt-package.json'
    }
    AfterEach {
        if (Test-Path $script:dir) { Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'creates the file when it does not exist yet' {
        Write-JsonAtomic -Path $script:file -Object @{ app = @{ name = 'new' } }
        (Get-Content $script:file -Raw | ConvertFrom-Json).app.name | Should -Be 'new'
    }

    It 'replaces an existing file and leaves no temp file behind' {
        '{"app":{"name":"old"}}' | Set-Content $script:file -Encoding UTF8
        Write-JsonAtomic -Path $script:file -Object @{ app = @{ name = 'new' } }
        (Get-Content $script:file -Raw | ConvertFrom-Json).app.name | Should -Be 'new'
        @(Get-ChildItem $script:dir -Filter '*.tmp').Count | Should -Be 0
    }

    It 'throws, and keeps the original, when another process holds the file open' {
        '{"app":{"name":"original"}}' | Set-Content $script:file -Encoding UTF8
        $h = [System.IO.File]::Open($script:file, 'Open', 'Read', [System.IO.FileShare]::ReadWrite)
        try {
            { Write-JsonAtomic -Path $script:file -Object @{ app = @{ name = 'lost' } } } | Should -Throw
        } finally { $h.Dispose() }
        (Get-Content $script:file -Raw | ConvertFrom-Json).app.name | Should -Be 'original' -Because 'a failed write must not touch what was there'
        @(Get-ChildItem $script:dir -Filter '*.tmp').Count | Should -Be 0
    }

    It 'still replaces the file when the other handle allows deletion' {
        '{"app":{"name":"original"}}' | Set-Content $script:file -Encoding UTF8
        $h = [System.IO.File]::Open($script:file, 'Open', 'Read', ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            Write-JsonAtomic -Path $script:file -Object @{ app = @{ name = 'updated' } }
        } finally { $h.Dispose() }
        (Get-Content $script:file -Raw | ConvertFrom-Json).app.name | Should -Be 'updated'
    }

    It 'writes config.json under Windows PowerShell 5.1, called the way New-PsadtEntraApp.ps1 calls it' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        # 'Stop' is inherited from the bootstrap. Without it the HashData failure only ends one statement,
        # the function limps on with an empty mutex name, and a probe of the bare function passes - which
        # is exactly how this stayed hidden.
        $setter = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Set-PsadtConfig.ps1')).Path
        $cmd = "`$ErrorActionPreference = 'Stop'; & '$setter' -SkillRoot '$script:dir' -Updates @{ 'author.person' = 'ps51' } | Out-Null; 'ok'"
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1
        ($out | Out-String) | Should -Match '(?m)^ok\s*$' -Because "Windows PowerShell 5.1 said: $($out | Out-String)"
        (Get-Content (Join-Path $script:dir 'config.json') -Raw | ConvertFrom-Json).author.person | Should -Be 'ps51'
    }
}

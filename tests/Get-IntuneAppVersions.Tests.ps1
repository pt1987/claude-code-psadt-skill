#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/Get-IntuneAppVersions.ps1 - the read-only discovery of the versions of one app that
    already exist in the tenant, and the supersedence relationships between them.

    Two kinds of assertion, neither of which needs a tenant:
      - PARAMETER BINDING: a bad combination must fail before any token is acquired.
      - SOURCE CONTRACT: the script must never write. Invoke-IntuneWin32Upload.ps1 carries the same
        guarantee behind a "WRITES BELOW THIS LINE" banner; this script has no such line at all, and the
        test is what keeps it that way. A discovery script that can POST is a discovery script that will
        eventually POST by accident.
#>

BeforeAll {
    $script:Versions = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Get-IntuneAppVersions.ps1')).Path
    $script:Src      = Get-Content -LiteralPath $script:Versions -Raw
    $script:NoPath   = 'C:\__nonexistent__\psadt-package.json'
}

Describe 'the app is named once, one way' {
    # Deliberately NOT [Parameter(Mandatory)] on either: a missing mandatory parameter makes PowerShell
    # PROMPT, and with stdin redirected that is a silent hang, not an error. Measured on the 0.46.0
    # benchmark: 19 minutes before the run was killed. Both are optional at binding and checked here.
    It 'neither parameter is mandatory at binding, so nothing can prompt' {
        $script:Src | Should -Not -Match '\[Parameter\(Mandatory\)\]\[string\]\$(DisplayName|ManifestPath)'
    }
    It 'refuses neither -DisplayName nor -ManifestPath, and says which to pass' {
        { & $script:Versions -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*-DisplayName*'
    }
    It 'refuses both at once - two sources of identity cannot be reconciled' {
        { & $script:Versions -DisplayName 'X' -ManifestPath $script:NoPath -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*not both*'
    }
    It 'accepts -ManifestPath alone, then fails on the missing file' {
        { & $script:Versions -ManifestPath $script:NoPath -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*not found*'
    }
}

Describe 'the OData filter is built safely' {
    # Invoke-IntuneWin32Upload.ps1:254 doubles the apostrophe before interpolating into $filter. An
    # apostrophe is ordinary in a vendor name ("Igor's"), and an undoubled one does not merely fail - it
    # changes which apps the filter returns, which is how a supersedence gets wired to the wrong app.
    It 'doubles an apostrophe before the name reaches the filter' {
        $script:Src | Should -Match "Replace\(\s*[`"']'[`"']\s*,\s*[`"']''[`"']\s*\)"
    }
    It 'restricts the filter to win32LobApp, so a Store app of the same name is never a candidate' {
        $script:Src | Should -Match "isof\('microsoft\.graph\.win32LobApp'\)"
    }
}

Describe 'the script is read-only' {
    It 'never issues a Graph write verb' {
        # Invoke-Graph takes the verb as its first positional argument.
        $script:Src | Should -Not -Match 'Invoke-Graph\s+(POST|PATCH|PUT|DELETE)\b'
    }
    It 'has no -Execute switch - there is nothing to gate, and offering one would imply there is' {
        $script:Src | Should -Not -Match '\[switch\]\$Execute'
    }
    It 'never calls Set-PsadtPackageManifest - discovery reports, it does not record' {
        $script:Src | Should -Not -Match 'Set-PsadtPackageManifest'
    }
}

Describe 'it reports the relationships, not just the apps' {
    It 'reads the relationships collection for each app found' {
        $script:Src | Should -Match '/relationships'
    }
    It 'emits supersedes and supersededBy so a caller can see the direction' {
        $script:Src | Should -Match 'supersedes'
        $script:Src | Should -Match 'supersededBy'
    }
}

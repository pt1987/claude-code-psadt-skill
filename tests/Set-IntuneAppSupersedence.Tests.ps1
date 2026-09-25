#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/Set-IntuneAppSupersedence.ps1 - the write path that declares "this app replaces
    that one" in the tenant.

    Binding and source-contract assertions only; no tenant is touched. The merge itself is a pure
    function in scripts/_GraphCommon.ps1 and is tested with real data in tests/_GraphCommon.Tests.ps1,
    because a regex over source cannot prove that the existing relationships survive.
#>

BeforeAll {
    $script:Sup = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Set-IntuneAppSupersedence.ps1')).Path
    $script:Src = Get-Content -LiteralPath $script:Sup -Raw
    $script:A   = '11111111-1111-1111-1111-111111111111'
    $script:B   = '22222222-2222-2222-2222-222222222222'
}

Describe '-SupersedenceType' {
    It "accepts 'update' and 'replace' - Microsoft's two documented scenarios" {
        $script:Src | Should -Match "ValidateSet\('update',\s*'replace'\)"
    }
    It 'rejects anything else at binding' {
        { & $script:Sup -AppId $script:A -SupersedesAppId $script:B -SupersedenceType 'uninstall' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*SupersedenceType*'
    }
    It 'is not hardcoded anywhere in the body' {
        # The bug this file exists for: Invoke-IntuneWin32Upload.ps1 shipped supersedenceType='replace'
        # as a literal, so every version bump uninstalled the previous version first.
        # The lookbehind exempts the parameter's own default ($SupersedenceType = 'update'), which is a
        # declaration, not a hardcoded body field. -match is case-insensitive, so without it the default
        # would trip this test and the test would have to be weakened instead of the code fixed.
        $script:Src | Should -Not -Match "(?<!\`$)supersedenceType\s*=\s*'replace'"
        $script:Src | Should -Not -Match "(?<!\`$)supersedenceType\s*=\s*'update'"
    }
    It 'hands the chosen mode to the shared merge rather than building a body itself' {
        $script:Src | Should -Match 'Merge-AppRelationships'
        $script:Src | Should -Match '-SupersedenceType\s+\$SupersedenceType'
    }
}

Describe 'the ids are GUIDs, and never the same GUID' {
    It 'rejects a non-GUID -AppId at binding' {
        { & $script:Sup -AppId 'not-a-guid' -SupersedesAppId $script:B -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*AppId*'
    }
    It 'rejects a non-GUID -SupersedesAppId at binding' {
        { & $script:Sup -AppId $script:A -SupersedesAppId 'not-a-guid' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*SupersedesAppId*'
    }
    It 'refuses an app superseding itself, before it authenticates' {
        # A self-edge is the cheapest way to make a graph Intune will not accept, and the failure
        # arrives from the service as an opaque 400. Catch it here, where the message can say why.
        { & $script:Sup -AppId $script:A -SupersedesAppId $script:A -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*itself*'
    }
}

Describe 'the write path' {
    It 'uses updateRelationships, not POST .../relationships' {
        # POST to the relationships collection is documented but reported to answer
        # "No OData route exists that match template ~/singleton/navigation/key/navigation with http
        # verb POST". The admin center uses updateRelationships; so do we.
        $script:Src | Should -Match 'updateRelationships'
        $script:Src | Should -Not -Match 'Invoke-Graph\s+POST\s+"\$GraphBase/deviceAppManagement/mobileApps/\$[A-Za-z]+/relationships"'
    }
    It 'carries the WRITES BELOW THIS LINE banner' {
        $script:Src | Should -Match '=+\s*WRITES BELOW THIS LINE\s*=+'
    }
    It 'issues no Graph write above the banner' {
        $above = ($script:Src -split 'WRITES BELOW THIS LINE')[0]
        $above | Should -Not -Match 'Invoke-Graph\s+(POST|PATCH|PUT|DELETE)\b'
    }
    It 'never issues DELETE - a relationship is replaced, an app is never removed' {
        $script:Src | Should -Not -Match 'Invoke-Graph\s+DELETE\b'
    }
    It 'reads the relationships back AFTER writing, rather than trusting the 2xx' {
        # A 204 from updateRelationships says the request was accepted, not that the chain is what was
        # intended. The read-back has to sit below the banner or it is proving nothing.
        $below = ($script:Src -split 'WRITES BELOW THIS LINE')[1]
        $below | Should -Not -BeNullOrEmpty
        $below | Should -Match 'Invoke-Graph\s+GET\s+"\$GraphBase/deviceAppManagement/mobileApps/\$AppId/relationships"'
    }
    It 'merges onto the CURRENT relationships, so the read happens before the write' {
        $above = ($script:Src -split 'WRITES BELOW THIS LINE')[0]
        $above | Should -Match 'Invoke-Graph\s+GET\s+"\$GraphBase/deviceAppManagement/mobileApps/\$AppId/relationships"'
    }
}

Describe 'the dry run is the default' {
    It 'declares -Execute' {
        $script:Src | Should -Match '\[switch\]\$Execute'
    }
    It 'returns before the banner when -Execute is absent' {
        $above = ($script:Src -split 'WRITES BELOW THIS LINE')[0]
        $above | Should -Match 'if\s*\(\s*-not\s+\$Execute\s*\)'
    }
}

Describe 'it records what it did' {
    It 'writes the outcome to the manifest when -ManifestPath was given' {
        $script:Src | Should -Match 'Set-PsadtPackageManifest'
        $script:Src | Should -Match 'results\.supersedence'
    }
}

Describe 'the assignment precondition is checked against the assignments themselves' {
    # Measured against the live tenant 2026-09-25: for one and the same app, Graph /beta returns
    # isAssigned=False on GET /mobileApps/{id} and isAssigned=True in GET /mobileApps?$filter=... .
    # The single-entity value is the wrong one. Trusting it made the script warn "the superseding app is
    # NOT assigned" about an app with two live assignments - and a warning that cries wolf is a warning
    # the operator learns to scroll past, on the one precondition that decides whether supersedence does
    # anything at all.
    It 'does not read isAssigned off the single-entity GET' {
        $script:Src | Should -Not -Match '\$newApp\.isAssigned'
    }
    It 'asks the assignments collection instead' {
        $script:Src | Should -Match '/assignments'
    }
}

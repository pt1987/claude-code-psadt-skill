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
        # POST to the relationships collection is documented but MEASURED (live tenant, 2026-09-25) to
        # answer "No OData route exists that match template ~/singleton/navigation/key/navigation with
        # http verb POST". The admin center uses updateRelationships; so do we.
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

Describe 'a superseded app that is still Required is reported (0.47.0)' {
    # The hole this closes. Supersedence only fires for devices targeted by the SUPERSEDING app
    # ("Superseding apps that aren't targeted are ignored by the agent"). So a device that sits in the
    # SUPERSEDED app's Required group and not in the superseding app's gets the OLD version installed,
    # and no supersedence will ever move it forward. Declaring an app superseded while leaving it
    # Required is a contradiction, and it is invisible in the portal unless you open both blades.
    #
    # This is reported, not refused: during a staged rollout both versions are legitimately assigned for
    # a while. What must not happen is that it goes unnoticed.
    It 'reads the assignments of each superseded app, not only of the superseding one' {
        $script:Src | Should -Match 'supersededAssignments|oldAssignments|Get-AppIntents'
    }
    It 'names the required intent as the problem case' {
        $script:Src | Should -Match "required"
    }
    It 'carries the finding out on the result object so a caller can gate on it' {
        $script:Src | Should -Match 'SupersededStillRequired'
    }
}

Describe 'the superseded app records what happened to it (0.47.0)' {
    # The relationship is visible only on the superseding app's Supersedence blade. Someone opening the
    # OLD app - to ask why it stopped installing, or whether it can be deleted - sees nothing at all.
    # The note is the audit trail in the place they actually look, and it survives independently of this
    # repository, the manifest and anyone's memory.
    It 'declares a -NoAnnotate escape hatch, so the note is the default and not the opt-in' {
        $script:Src | Should -Match '\[switch\]\$NoAnnotate'
    }
    It 'PATCHes the superseded app, not the superseding one' {
        $below = ($script:Src -split 'WRITES BELOW THIS LINE')[1]
        $below | Should -Match 'Invoke-Graph\s+PATCH\s+"\$GraphBase/deviceAppManagement/mobileApps/\$\(\$o\.id\)"'
    }
    It 'reads the existing notes first and appends - a note is never overwritten' {
        $script:Src | Should -Match '\$existingNotes'
        $script:Src | Should -Match 'notes\s*=.*\$existingNotes|\$existingNotes.*\+'
    }
    It 'records the date, the superseding version and its id' {
        $script:Src | Should -Match "yyyy-MM-dd"
        $script:Src | Should -Match '\$newApp\.displayVersion'
        $script:Src | Should -Match '\$AppId'
    }
    It 'states the assignment situation it observed rather than claiming an action it did not take' {
        $script:Src | Should -Match 'assignmentNote|no assignments|still assigned'
    }
    It 'is skipped on a dry run - the note is a write like any other' {
        $above = ($script:Src -split 'WRITES BELOW THIS LINE')[0]
        $above | Should -Not -Match 'Invoke-Graph\s+PATCH'
    }
}

Describe 'no assignments is not the same as unknown assignments (0.47.0)' {
    # Measured on the live tenant: after removing the superseded app's three assignments, the note read
    # "Groups: assignment state could not be read". PowerShell unwraps an empty array returned from a
    # function to $null, so the zero case collided with the error case - and the good end state was
    # recorded in the tenant as a failure to determine it.
    It 'returns the intent list through the comma operator so an empty result survives' {
        $script:Src | Should -Match 'return\s*,\s*\$v'
    }
    It 'still has a distinct null path for a genuine read failure' {
        $script:Src | Should -Match 'catch\s*\{\s*return\s+\$null\s*\}'
    }
    It 'distinguishes the two in the note text' {
        $script:Src | Should -Match 'could not be read'
        $script:Src | Should -Match 'no longer targets any group'
    }
}

Describe 'the supersedence names the versions and records itself on both packages (0.49.3)' {
    # Measured 2026-09-27: results.supersedence held two bare ids, so the dossier printed a GUID where the
    # previous version belongs; and the superseded package's manifest - and so its dossier - never learned
    # that it had been superseded. Run against a fake tenant (tests/_helpers.ps1).
    BeforeAll {
        . (Join-Path $PSScriptRoot '_helpers.ps1')
        function Invoke-Graph { param([string]$Method, [string]$Uri, $Body, [hashtable]$Headers, [int]$Depth = 20) }
        $script:OLD = '11111111-2222-3333-4444-555555555555'
        $script:NEW = '99999999-2222-3333-4444-555555555555'
    }
    BeforeEach {
        $script:oldHome = $env:PSADT_DEPLOY_HOME
        $script:sHome = Join-Path $TestDrive ('shome_' + [guid]::NewGuid().ToString('N'))
        $script:root = Join-Path $script:sHome 'packages'
        New-Item $script:root -ItemType Directory -Force | Out-Null
        $env:PSADT_DEPLOY_HOME = $script:sHome
        @{ version = 1; paths = @{ packageRoot = $script:root } } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $script:sHome 'config.json') -Encoding UTF8
        $script:newPkg = { param([string]$Folder, [string]$Version, [string]$AppId)
            $d = Join-Path $script:root $Folder
            New-Item $d -ItemType Directory -Force | Out-Null
            Set-Content (Join-Path $d 'Invoke-AppDeployToolkit.ps1') '# launcher'
            @{ schema = 1; app = @{ vendor = 'ACME'; name = 'Widget'; version = $Version; arch = 'x64' }; package = @{ type = 'installer' }
               results = @{ upload = @{ appId = $AppId; displayName = 'Widget' } } } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $d 'psadt-package.json') -Encoding UTF8
            Join-Path $d 'psadt-package.json' }
        $script:mfOld = & $script:newPkg 'Widget_1.0' '1.0' $script:OLD
        $script:mfNew = & $script:newPkg 'Widget_2.0' '2.0' $script:NEW
        $global:PsadtFakeTenant = New-FakeIntuneTenant
        Add-FakeApp -Id $script:OLD -Name 'Widget' -Version '1.0'
        Add-FakeApp -Id $script:NEW -Name 'Widget' -Version '2.0'
        $g = Add-FakeGroup -Name 'grp-available-Widget'
        Add-FakeAssignment -AppId $script:NEW -Intent 'available' -GroupId $g
        Mock Invoke-Graph { Invoke-FakeGraph -Method $Method -Uri $Uri -Body $Body }
    }
    AfterEach { $env:PSADT_DEPLOY_HOME = $script:oldHome; Remove-Variable -Name PsadtFakeTenant -Scope Global -ErrorAction SilentlyContinue }

    It 'names the superseded version in results.supersedence' {
        & $script:Sup -AppId $script:NEW -SupersedesAppId $script:OLD -ManifestPath $script:mfNew -GraphToken 'opaque' -Execute 6>$null | Out-Null
        $s = (Get-Content $script:mfNew -Raw | ConvertFrom-Json).results.supersedence
        $s.verified | Should -BeTrue
        $a = @($s.supersedesApps)[0]
        $a.id | Should -Be $script:OLD
        $a.displayName | Should -Be 'Widget'
        $a.displayVersion | Should -Be '1.0'
    }

    It 'records on the superseded package what superseded it' {
        & $script:Sup -AppId $script:NEW -SupersedesAppId $script:OLD -ManifestPath $script:mfNew -GraphToken 'opaque' -Execute 6>$null | Out-Null
        $b = (Get-Content $script:mfOld -Raw | ConvertFrom-Json).results.supersededBy
        $b.appId | Should -Be $script:NEW
        $b.displayName | Should -Be 'Widget'
        $b.displayVersion | Should -Be '2.0'
        $b.supersedenceType | Should -Be 'update'
    }

    It 'records nothing on a dry run' {
        & $script:Sup -AppId $script:NEW -SupersedesAppId $script:OLD -ManifestPath $script:mfNew -GraphToken 'opaque' 6>$null | Out-Null
        (Get-Content $script:mfOld -Raw | ConvertFrom-Json).results.supersededBy | Should -BeNullOrEmpty
        @($global:PsadtFakeTenant.Calls | Where-Object { $_ -match '^(POST|PATCH|DELETE)' }).Count | Should -Be 0
    }
}

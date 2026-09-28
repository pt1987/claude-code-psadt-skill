# Tests for scripts/Get-PsadtReturnCodes.ps1 - the canonical Intune return-code table.
#
# The point of this script is that an invalid return-code type is structurally impossible, so most of these
# are guards rather than examples. The type "Ignored" earns its own test: it is not hypothetical, it
# reached a real dossier, because the report used to render a caller-supplied table without validating it.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:Rc = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Get-PsadtReturnCodes.ps1')).Path

    # Written out literally, NOT read from the script. A test that imports the constant it is checking
    # rubber-stamps whatever someone edits it to.
    $script:ValidTypes = @('success', 'softReboot', 'hardReboot', 'retry', 'failed')
}

Describe 'Get-PsadtReturnCodes - canonical table' {
    It 'returns exactly the seven mandatory codes from guide Appendix F.4' {
        $codes = @(& $script:Rc).Code
        $codes | Should -Be @(0, 1707, 3010, 1641, 1618, 60001, 60008)
    }

    It 'emits only types Intune accepts' {
        foreach ($r in @(& $script:Rc)) {
            $script:ValidTypes | Should -Contain $r.Type
        }
    }

    It 'maps 60001 and 60008 to failed' {
        # A package that reports its own crashes as success is worse than one that fails loudly.
        $t = @(& $script:Rc)
        ($t | Where-Object { $_.Code -eq 60001 }).Type | Should -Be 'failed'
        ($t | Where-Object { $_.Code -eq 60008 }).Type | Should -Be 'failed'
    }

    It 'sorts by type in Appendix F.4 order, then numerically within a type' {
        # Not plain numeric order: the dossier is verified line by line against F.4 and transcribed into
        # the portal grid in that sequence.
        $codes = @(& $script:Rc -Custom @(@{ Code = 3; Type = 'success' }, @{ Code = 1603; Type = 'failed' })).Code
        $codes | Should -Be @(0, 3, 1707, 3010, 1641, 1618, 1603, 60001, 60008)
    }
}

Describe 'Get-PsadtReturnCodes - validation' {
    It 'rejects the type "Ignored" and explains that Intune has no such type' {
        { & $script:Rc -Custom @(@{ Code = 5; Type = 'Ignored' }) } |
            Should -Throw -ExpectedMessage '*no*ignored*return-code type*'
    }

    It 'names the valid types when an unknown type is supplied' {
        $msg = $null
        try { & $script:Rc -Custom @(@{ Code = 5; Type = 'Nonsense' }) } catch { $msg = $_.Exception.Message }
        foreach ($t in $script:ValidTypes) { $msg | Should -BeLike "*$t*" }
    }

    It 'rejects a non-numeric code' {
        { & $script:Rc -Custom @(@{ Code = 'abc'; Type = 'failed' }) } | Should -Throw -ExpectedMessage '*not an integer*'
    }

    It 'rejects the same code supplied twice rather than guessing which wins' {
        { & $script:Rc -Custom @(@{ Code = 5; Type = 'failed' }, @{ Code = 5; Type = 'success' }) } |
            Should -Throw -ExpectedMessage '*twice*'
    }

    It 'rejects an entry that supplies only a badge class' {
        # b-warn is ambiguous between Soft reboot and Hard reboot. Guessing here is precisely the silent
        # wrongness this script exists to prevent.
        { & $script:Rc -Custom @(@{ Code = 5; Cls = 'b-warn' }) } | Should -Throw -ExpectedMessage '*only Cls*'
    }

    It 'accepts the portal wording as well as the Graph token' {
        # Appendix F.4 itself writes "Soft reboot", not "softReboot".
        $r = @(& $script:Rc -Custom @(@{ Code = 7; Type = 'Soft reboot' }))
        ($r | Where-Object { $_.Code -eq 7 }).Type | Should -Be 'softReboot'
    }
}

Describe 'Get-PsadtReturnCodes - presentation is derived, never supplied' {
    It 'discards a caller-supplied Cls and Label' {
        # This is what makes an invalid type impossible instead of merely discouraged, and it removes the
        # attribute-injection hazard the old raw-interpolated Cls carried.
        $r = @(& $script:Rc -Custom @(@{ Code = 3010; Type = 'softReboot'; Cls = 'b-fail'; Label = '<script>alert(1)</script>' }) -WarningAction SilentlyContinue)
        $row = $r | Where-Object { $_.Code -eq 3010 }
        $row.Cls | Should -Be 'b-warn'
        $row.Label | Should -Be 'Soft reboot'
    }

    It 'derives the badge class from the type for every row' {
        $expected = @{ success = 'b-ok'; softReboot = 'b-warn'; hardReboot = 'b-warn'; retry = 'b-neut'; failed = 'b-fail' }
        foreach ($r in @(& $script:Rc)) { $r.Cls | Should -Be $expected[$r.Type] }
    }
}

Describe 'Get-PsadtReturnCodes - custom entries' {
    It 'overrides a canonical row instead of duplicating it' {
        # An installer for which 1618 genuinely means success must be expressible.
        $r = @(& $script:Rc -Custom @(@{ Code = 1618; Type = 'success'; De = 'X'; En = 'X' }))
        @($r).Count | Should -Be 7
        ($r | Where-Object { $_.Code -eq 1618 }).Type | Should -Be 'success'
    }

    It 'accepts the camelCase shape that comes out of the manifest JSON' {
        $r = @(& $script:Rc -Custom @([pscustomobject]@{ code = 1603; type = 'failed'; de = 'MSI'; en = 'MSI' }))
        ($r | Where-Object { $_.Code -eq 1603 }).Type | Should -Be 'failed'
    }

    It 'fills a meaning for a code given as number and type only' {
        $r = @(& $script:Rc -Custom @(@{ Code = 1603; Type = 'failed' }))
        ($r | Where-Object { $_.Code -eq 1603 }).De | Should -Not -BeNullOrEmpty
    }

    It 'still accepts the pre-0.26 shape that carried Label instead of Type' {
        $r = @(& $script:Rc -Custom @(@{ Code = '9999'; Cls = 'b-fail'; Label = 'Failed'; De = 'X'; En = 'X' }) -WarningAction SilentlyContinue)
        ($r | Where-Object { $_.Code -eq 9999 }).Type | Should -Be 'failed'
    }
}

Describe 'Get-PsadtReturnCodes - Graph body' {
    It 'emits integer codes and enum tokens in the same order' {
        $g = @(& $script:Rc -AsGraphBody)
        @($g).Count | Should -Be 7
        $g[0].returnCode | Should -BeOfType [int]
        @($g.returnCode) | Should -Be @(0, 1707, 3010, 1641, 1618, 60001, 60008)
        foreach ($e in $g) { $script:ValidTypes | Should -Contain $e.type }
    }
}

Describe 'Get-PsadtReturnCodes - house conventions' {
    It 'is ASCII-clean' {
        $bytes = [System.IO.File]::ReadAllBytes($script:Rc)
        $body = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF) { $bytes[3..($bytes.Length - 1)] } else { $bytes }
        @($body | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'parses without errors' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:Rc, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }
}

Describe 'Get-PsadtReturnCodes - the dossier labels a type in the reader''s language (0.49.4)' {
    # Measured 2026-09-28 on a real dossier: the German view read "Success", "Soft reboot", "Retry" and
    # "Failed" in the type column, next to German meanings - the label had one language only. The Graph
    # token stays the one value the upload sends; only the label a person reads gets two languages.
    It 'labels every type in German and in English' {
        $want = @{
            success    = @('Erfolg', 'Success')
            softReboot = @('Soft-Reboot', 'Soft reboot')
            hardReboot = @('Hard-Reboot', 'Hard reboot')
            retry      = @('Wiederholen', 'Retry')
            failed     = @('Fehler', 'Failed')
        }
        foreach ($r in @(& $script:Rc -Custom @(@{ Code = 7; Type = 'softReboot' }, @{ Code = 8; Type = 'hardReboot' }))) {
            $r.LabelDe | Should -BeExactly $want[$r.Type][0] -Because "type $($r.Type), code $($r.Code)"
            $r.LabelEn | Should -BeExactly $want[$r.Type][1] -Because "type $($r.Type), code $($r.Code)"
        }
    }

    It 'describes 60001 for every deployment type, not only Install' {
        # 60001 is the launcher's catch-all for Install, Uninstall AND Repair; "runtime error in
        # Install-ADTDeployment" sent a reader of an uninstall failure to the wrong function.
        $r = @(& $script:Rc) | Where-Object { $_.Code -eq 60001 }
        $r.De | Should -Match 'Uninstall'
        $r.De | Should -Match 'Repair'
        $r.En | Should -Match 'Uninstall'
        $r.En | Should -Not -Match 'in Install-ADTDeployment'
    }
}

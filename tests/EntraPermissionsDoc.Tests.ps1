# SCOPE NOTE: until 0.49.1 no reader-facing document said which Entra permissions this skill needs.
# SECURITY.md said "needs administrator consent" and stopped there; the README said less. The list
# existed only in references/app-registration.md, which is agent-facing depth, and even that list was
# wrong in one place: it said delegated scopes are used only by the bootstrap, while the two policy
# scripts request DeviceManagementConfiguration.ReadWrite.All delegated whenever they run -Interactive.
#
# A permission list written by hand drifts the moment a script asks for one more role. So this file
# reads what the scripts actually REQUEST - the app roles and scopes in New-PsadtEntraApp.ps1 and the
# delegated scope of the -Interactive policy scripts - and fails when a document that promises the
# full picture does not name every one of them.

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $read = { param($rel) Get-Content -LiteralPath (Join-Path $script:root $rel) -Raw }

    $script:security = & $read 'SECURITY.md'
    $script:matrix = & $read 'references/app-registration.md'
    $readme = & $read 'README.md'
    # Only the part above the changelog copy describes the current repo.
    $cut = $readme.IndexOf("`n## Changelog")
    $script:readme = if ($cut -gt 0) { $readme.Substring(0, $cut) } else { $readme }

    $bootstrap = & $read 'scripts/New-PsadtEntraApp.ps1'

    # Application roles: every quoted role on a line that builds $RequiredAppRoles, opt-ins included.
    $script:appRoles = @(
        ($bootstrap -split "`r?`n") | Where-Object { $_ -match '^\s*(if .*\{\s*)?\$RequiredAppRoles\s*\+?=' } |
            ForEach-Object { [regex]::Matches($_, "'([A-Za-z]+(?:\.[A-Za-z]+)+)'") | ForEach-Object { $_.Groups[1].Value } }
    ) | Sort-Object -Unique

    # Delegated scopes of the bootstrap sign-in, without the reserved OIDC scopes MSAL adds itself.
    $scopeLine = [regex]::Match($bootstrap, "(?m)^\s*\`$Scopes\s*=\s*'([^']+)'").Groups[1].Value
    $script:bootstrapScopes = @($scopeLine -split '\s+' | Where-Object { $_ -like '*.*' }) | Sort-Object -Unique

    # Delegated scope of the policy scripts' -Interactive sign-in.
    $script:interactiveScopes = @(
        foreach ($rel in 'scripts/New-IntuneFirewallPolicy.ps1', 'scripts/New-IntuneTrustedCertPolicy.ps1', 'scripts/_GraphInteractive.ps1') {
            [regex]::Matches((& $read $rel), 'graph\.microsoft\.com/([A-Za-z]+(?:\.[A-Za-z]+)+)') | ForEach-Object { $_.Groups[1].Value }
        }
    ) | Sort-Object -Unique

    $script:appName = [regex]::Match($bootstrap, "(?m)^\`$AppDisplayName\s*=\s*'([^']+)'").Groups[1].Value
    $script:clientId = [regex]::Match($bootstrap, "(?m)^\`$DeviceCodeClientId\s*=\s*'([^']+)'").Groups[1].Value
}

Describe 'Entra permissions are documented from what the scripts request' {

    It 'reads a non-empty permission set out of the scripts' {
        # A parser that silently matched nothing would make every test below pass vacuously.
        $script:appRoles | Should -Contain 'DeviceManagementApps.ReadWrite.All'
        $script:appRoles.Count | Should -BeGreaterOrEqual 4
        $script:bootstrapScopes | Should -Contain 'Application.ReadWrite.All'
        $script:interactiveScopes | Should -Contain 'DeviceManagementConfiguration.ReadWrite.All'
        $script:appName | Should -Not -BeNullOrEmpty
        $script:clientId | Should -Match '^[0-9a-f-]{36}$'
    }

    It 'SECURITY.md has an Entra permissions section to link to' {
        $script:security | Should -Match '(?m)^## Entra permissions\s*$'
    }

    It 'SECURITY.md names every application role New-PsadtEntraApp.ps1 can grant' {
        foreach ($r in $script:appRoles) {
            $script:security | Should -Match ([regex]::Escape("``$r``")) -Because "New-PsadtEntraApp.ps1 can grant '$r'"
        }
    }

    It 'SECURITY.md names every delegated scope, the bootstrap and the -Interactive policy route' {
        foreach ($s in @($script:bootstrapScopes) + @($script:interactiveScopes)) {
            $script:security | Should -Match ([regex]::Escape("``$s``")) -Because "a script requests '$s' delegated"
        }
    }

    It 'SECURITY.md says who has to sign in, what gets created and under which client' {
        $script:security | Should -Match 'Global Administrator'
        $script:security | Should -Match 'Privileged Role Administrator'
        $script:security | Should -Match ([regex]::Escape($script:appName))
        $script:security | Should -Match ([regex]::Escape($script:clientId))
    }

    It 'SECURITY.md does not hide that the bootstrap writes without a dry run' {
        # Every Intune write path dry-runs first; the Entra bootstrap does not, and saying "every write
        # path" without that exception would be a claim the code does not keep.
        $script:security | Should -Match 'New-PsadtEntraApp\.ps1[^\r\n]*(no dry run|has no dry run)|no dry run[^\r\n]*New-PsadtEntraApp\.ps1|(?s)### What `scripts/New-PsadtEntraApp\.ps1` does.{0,400}no dry run'
        $script:security | Should -Not -Match '\*\*Every write path dry-runs first\*\*'
    }

    It 'references/app-registration.md lists the -Interactive delegated scope too' {
        foreach ($s in @($script:bootstrapScopes) + @($script:interactiveScopes)) {
            $script:matrix | Should -Match ([regex]::Escape("``$s``")) -Because "the matrix calls itself the single source of truth and a script requests '$s' delegated"
        }
        $script:matrix | Should -Not -Match 'used only by the one-time bootstrap' -Because 'the policy scripts use a delegated scope whenever they run -Interactive'
    }

    It 'the README points to the permissions before anyone installs' {
        $script:readme | Should -Match 'DeviceManagementApps\.ReadWrite\.All'
        $script:readme | Should -Match '\(SECURITY\.md#entra-permissions\)'
    }
}

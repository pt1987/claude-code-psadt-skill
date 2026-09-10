# Appendix M: Group assignment (opt-in) - config-driven Entra groups + win32LobApp assignment

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Contents

- [M.1 Permissions (least-privilege)](#m1-permissions-least-privilege)
- [M.2 Config schema (`intune.groups`)](#m2-config-schema-intunegroups)
- [M.3 Naming tokens + the rules that bite](#m3-naming-tokens--the-rules-that-bite)
- [M.4 Workflow](#m4-workflow)
- [M.5 Gotchas](#m5-gotchas)

## Appendix M: Group assignment (opt-in) - config-driven Entra groups + win32LobApp assignment

Assignment is **opt-in** and resolved at intake Gate 2 (target audience + AAD groups). The default is **no
assignment** - uploading an app NEVER auto-targets anyone. When the user does want the skill to manage the
assignment groups, `Invoke-IntuneAppAssignment.ps1` creates/reuses Entra security groups by a configured naming
scheme and assigns the uploaded `win32LobApp` to them (intents `required` / `available` / `uninstall`).
Read-only dry run by default; `-Execute` writes. It is **idempotent** and **never deletes** a group or another
app's assignment.

### M.1 Permissions (least-privilege)
Group assignment needs **both** `Group.Create` (a group the app then owns - NOT the tenant-wide
`Group.ReadWrite.All`) and `GroupMember.Read.All` (find a group by name), on top of the upload role. The
full matrix - every role, its capability and how to grant it - lives in `references/app-registration.md`
section 0; it is not repeated here. `Invoke-IntuneAppAssignment.ps1` asserts both roles before it creates
anything, and `Test-PsadtIntuneAccess.ps1` reports which half is missing.

Grant them once (opt-in), needs Global Admin / Privileged Role Admin to consent:

```
pwsh scripts/New-PsadtEntraApp.ps1 -IncludeGroupManagement
```

This re-runs idempotently against the existing app and PATCHes its requested permissions. If consent is denied,
the app + credential still exist and the run reports the pending roles to grant in the portal.

### M.2 Config schema (`intune.groups`)
The feature is off unless `intune.groups.enabled` is `true`. Schema:

```
intune.groups = {
  enabled        = true            # master switch; off => the script throws "not enabled"
  create         = true            # true: create a missing group; false: assign-to-existing-only (report MISSING)
  membershipType = 'assigned'      # ONLY 'assigned' (static) is implemented; anything else throws
  naming         = {               # at least one of required/available/uninstall must be present
    required  = 'intune-win-app-required-%appname%'
    available = 'intune-win-app-available-%appname%'
    uninstall = 'intune-win-app-uninstall-%appname%'
  }
}
```

Write it with `Set-PsadtConfig.ps1` (dotted paths; the naming sub-tree is passed as one hashtable):

```
pwsh scripts/Set-PsadtConfig.ps1 -Updates @{
  'intune.groups.enabled'        = $true
  'intune.groups.create'         = $true
  'intune.groups.membershipType' = 'assigned'
  'intune.groups.naming'         = @{
      required  = 'intune-win-app-required-%appname%'
      available = 'intune-win-app-available-%appname%'
      uninstall = 'intune-win-app-uninstall-%appname%'
  }
}
```

`Get-PsadtConfig.ps1` validates this: when `enabled` is true it reports `intune.groups.naming` as Missing if no
template is present, or flags that at least one of required/available/uninstall is needed.

### M.3 Naming tokens + the rules that bite
`Resolve-GroupName` substitutes these tokens (case-insensitive; both `%token%` and `{Token}` forms work):

| Token | Source |
|---|---|
| `%appname%` | the `-AppName` passed to the assignment script |
| `%appvendor%` | the `-AppVendor` |
| `%apparch%` | the `-AppArch` (default `x64`) |
| `%version%` | the `-AppVersion` |

Two rules that are easy to get wrong:

- **There is NO `%intent%` token.** The intent (required/available/uninstall) is the *key* of the naming
  template, not a substitution. To put the intent in the name, bake it into each template literally
  (`intune-win-app-required-%appname%`, `...-available-...`, etc.). A `%intent%` placeholder would survive
  verbatim into the group name.
- **Group names contain NO spaces.** Every token value is space-stripped before substitution and the final name
  is space-stripped as a safety net. So `-AppName 'Norton Neo'` yields `NortonNeo` in the name.

**Version-independent by default (recommended).** Leave `%version%` OUT of the naming templates. Then a NEW app
version resolves the SAME groups, so on the next upload you assign the new app + wire supersedence
(`Invoke-IntuneWin32Upload.ps1 -SupersedesAppId <oldId>`) and the new version automatically targets the same
audience while the old app is retained for rollback. This is the whole point of config-driven naming.

**`%version%` opt-in (use deliberately).** Including `%version%` (e.g. `...-%appname%-%version%`) makes the group
names **version-specific**: every version creates its own groups and you must re-add members for each release.
This breaks the supersedence reuse above. Choose it only when you genuinely want per-version audiences.

### M.4 Workflow
Always dry-run first (read-only), confirm the planned group names + actions, then `-Execute`:

```
# dry run
pwsh scripts/Invoke-IntuneAppAssignment.ps1 -AppId <id> -AppName '<App>' -AppVendor '<Vendor>' `
    -AppVersion '<x.y.z>' -AppArch x64 -Intents required,available
# execute
pwsh scripts/Invoke-IntuneAppAssignment.ps1 -AppId <id> -AppName '<App>' -AppVendor '<Vendor>' `
    -AppVersion '<x.y.z>' -AppArch x64 -Intents required,available -Execute
```

> **Array parameters and the `-File` binder (bit us on 2026-09-06).** `pwsh script.ps1 -Intents a,b` uses
> `-File` semantics, and that binder passes `a,b` as a SINGLE array element - it does not split on commas.
> `-Intents` therefore no longer carries a `[ValidateSet]` (which fires at bind time and produced an error
> naming a value the caller never typed) and splits the list itself, so the line above works as written. The
> same applies to `-Paths*` on `Invoke-PsadtSandboxTest.ps1`, which would otherwise silently assert only the
> first path and still report GREEN. When a value genuinely contains a comma, pass a real array instead:
> ```powershell
> pwsh -Command "& ./scripts/Invoke-IntuneAppAssignment.ps1 -AppId <id> -AppName '<App>' -Intents @('required','available')"
> ```

Per intent the script resolves the group by `displayName` (directory read uses `ConsistencyLevel: eventual`)
and then:

| Found | create | Action |
|---|---|---|
| exactly 1 | - | **reuse** that group |
| 0 | true | **create** (assigned/static security group the app owns) |
| 0 | false | **MISSING** - skip (create it manually or set `create=true`) |
| >1 (name not unique) | - | **AMBIGUOUS** - skip, never guess |

The assignment itself is idempotent: an existing assignment for the same group + intent is left untouched.
`-Intents` defaults to every intent that has a naming template. Output is a structured object
(`Groups[{Intent,Name,Id,Action}]`, `Assignments[{Intent,GroupId,Action}]`) - feed `Groups` into the dossier's
Assignments table.

### M.5 Gotchas
- **`-SkillRoot` / config location.** The script reads config + acquires the token from `-SkillRoot` (default:
  the script's parent). The `intune.groups` block, the `intune` credentials, and `secret.dpapi` must all live in
  the SAME config the script resolves. The DPAPI secret is `CurrentUser`-bound per install, so the installed
  skill's `config.json` is the canonical one - point `-SkillRoot` at it if you run the script from a clone.
- **`membershipType` is `assigned` only.** Dynamic membership is not implemented; the script throws rather than
  silently creating a static group when you asked for a rule.
- **Never auto-impose.** Group assignment is only ever done when the user opted in at Gate 2 AND
  `intune.groups.enabled` is true. No default audience, no implicit "All Users/All Devices".

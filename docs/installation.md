# Installation and versions

← back to the [README](../README.md)

```powershell
npx psadt-deploy-skill
```

Installs the **newest release** into `~/.claude/skills/psadt-deploy` and runs the setup doctor. Flags:
`--dir <path>` · `--project` (into `./.claude/skills`) · `--ref <tag|branch>` · `--no-setup`. Node 18+ and
Windows; the installer itself has zero dependencies and the package carries only `bin/` - the skill is
fetched from GitHub at install time.

## Which version you get

The default is the newest **release tag**, not `main`. This skill registers an Entra application with
admin consent and writes to an Intune tenant; installing whatever last landed on `main` is not a
defensible default for that.

```powershell
npx psadt-deploy-skill                 # newest release (default)
npx psadt-deploy-skill --ref v0.35.0   # pin an exact release
npx psadt-deploy-skill --ref main      # the development branch, deliberately
```

**For managed environments:** pin a tag, read the diff between it and the next one before moving, then
lift the pin. Releases are tagged `vX.Y.Z` and match the [Changelog](../CHANGELOG.md); tags exist from
**v0.24.0** onward - earlier versions predate the current history and cannot be tagged retroactively.

Re-running the installer updates an existing installation, and so does saying *"psadt update"* to Claude
Code. What counts as an update depends on what you installed: on a **pinned release** it is the next
release tag - unreleased work on `main` is deliberately invisible, because that is what pinning means. On
a **branch** installation it is the next commit, as before. Either way the update overwrites tracked
repository files only; `config.json`, `secret.dpapi` and `tools/` are never touched.

## Other ways in

**Clone it yourself** - the repo root *is* the skill folder:

```powershell
git clone https://github.com/pt1987/claude-code-psadt-skill.git "$env:USERPROFILE\.claude\skills\psadt-deploy"
pwsh "$env:USERPROFILE\.claude\skills\psadt-deploy\scripts\Initialize-PsadtSkill.ps1" -Fix
```

`npx skills add pt1987/claude-code-psadt-skill` works too, since `SKILL.md` sits in the repository root.

No git on the machine? The installer falls back to the GitHub tarball and Windows' own `tar.exe`, so the
one-liner still works - including with `--ref <tag>`, which is the combination a locked-down machine
actually needs.

The skill activates automatically when you ask Claude Code to build an Intune package, or when you work in
a folder containing `Invoke-AppDeployToolkit.ps1`.

## Requirements

- Windows with PowerShell 5.1+ / PowerShell 7+
- For the `npx` installer only: **Node 18+** (the skill itself never needs Node)
- [PSAppDeployToolkit](https://psappdeploytoolkit.com/) v4.x *(installed/updated automatically from the
  PowerShell Gallery if missing)*
- [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
  *(provisioned automatically)*
- For the **SYSTEM test**: the Windows optional feature `Containers-DisposableClientVM` (Windows Sandbox).
  No elevation is needed for that route. The per-action DEV-VM fallback
  (`Invoke-PsadtSystemTest.ps1`) does need an **elevated** session and installs
  [`Invoke-CommandAs`](https://github.com/mkellerman/Invoke-CommandAs) automatically.
- For the **direct Intune upload**: an Entra app with the Graph application role
  `DeviceManagementApps.ReadWrite.All` (admin-consented) - created in one run by
  `scripts/New-PsadtEntraApp.ps1` (WAM sign-in as Global Admin / Privileged Role Admin, device-code
  fallback). Check what is actually in place with `scripts/Test-PsadtIntuneAccess.ps1`. Full permission
  matrix and the manual portal route: [`references/app-registration.md`](../references/app-registration.md).
- For **Pester tests**: Pester 5+ (`Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser`)
- **Optional (recommended): the [superpowers](https://github.com/obra/superpowers) plugin** - if installed,
  the gated research fan-out and the reviewer gate use it. Not required: without it the skill falls back to the
  native Agent tool and `/code-review`, and nothing in the workflow depends on the plugin.

## What is deliberately not in the skill frontmatter

`SKILL.md` declares `name`, `description` and `license`, and nothing else. The omissions are choices, not
oversights:

- **`paths`** would look like the right way to express "activates in a folder containing
  `Invoke-AppDeployToolkit.ps1`". It is the opposite: the field *limits* activation to files matching the
  globs. Setting it would switch the skill off for the most common request there is - packaging an app in
  an empty folder, where `Invoke-AppDeployToolkit.ps1` does not exist yet because Phase 3 is what creates
  it. The folder case is covered by the last sentence of the description instead.
- **`allowed-tools`** grants tools up front; it does not restrict them. For a skill that installs software
  as SYSTEM and writes to a tenant, being asked per call is the point. See [`SECURITY.md`](../SECURITY.md).
- **`metadata.version`** is ignored by Claude Code, and the version already lives in `CHANGELOG.md`,
  `package.json` (kept in sync by a test) and on the website. A fourth place to forget on release day, for
  no behaviour, is not worth it.
- **`shell`** only matters for `!` command injection in `SKILL.md`, which this skill does not use - and a
  failing `!` command aborts the *entire* skill invocation, so an `Initialize-PsadtSkill` call wired up that
  way would be a single point of failure for every packaging request.
- **`context: fork` / `agent`** would isolate the skill in a subagent. It orchestrates its own sub-agents
  and needs the main context to hold the decision gates.

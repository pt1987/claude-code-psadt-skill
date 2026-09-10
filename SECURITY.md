# Security

This skill installs software as SYSTEM, reaches the public internet, and writes to a Microsoft Intune
tenant through an Entra application with administrator consent. Those are real capabilities, and a
security review should treat them as such.

This document states the risk surface plainly and, next to each item, the control that is already in
place. It is written so a reviewer can check the claims against the code rather than take them on
trust - every control names the file that implements it and, where one exists, the test that enforces
it.

## Scope

`psadt-deploy` is a Claude Code **skill**: Markdown instructions plus PowerShell helper scripts. It has
no service, no daemon, no telemetry and no background process. It does something only while a Claude
Code session is running it, and every action goes through that session's permission prompts.

The skill deliberately does **not** declare `allowed-tools`. That field pre-approves tools for the
turn; it does not restrict them. For a skill that installs software as SYSTEM and writes to a tenant,
being asked each time is the feature, not the friction.

## Risk surface and controls

### 1. Code execution as SYSTEM on the authoring machine

Phase 6 installs, uninstalls and repairs the real application as `NT AUTHORITY\SYSTEM`.

| Control | Where |
|---|---|
| Consent is an explicit decision gate before anything runs (Gate 3) | `SKILL.md`, Decision gates |
| The default route is a **throwaway Windows Sandbox**: no elevation on the host, host filesystem and registry untouched, discarded on exit | `scripts/Invoke-PsadtSandboxTest.ps1` |
| The DEV-VM route is offered second and asks for a snapshot first | `SKILL.md`, Gate 3 |
| "Skip the test" is not offered while an upload is planned | `SKILL.md`, Gate 3 |
| The harness is a reviewed script, never hand-rolled `schtasks` - three silent-failure bugs are pinned by tests | `tests/Invoke-PsadtSandboxTest.Tests.ps1` |

### 2. Code execution as SYSTEM on managed devices

A published Win32 app runs as SYSTEM on every assigned device. This is the highest-blast-radius item
in the workflow.

| Control | Where |
|---|---|
| **Test before upload is a gate, not a recommendation**: Install and Uninstall must pass Phase 6 first. No elevation available means STOP, not proceed | `SKILL.md`, Conventions |
| Pre-flight returns a deterministic `GREEN`/`RED`; any `RED` stops packaging | `scripts/Invoke-PsadtPreflight.ps1` |
| Assignment is opt-in and never automatic - a group is created or assigned only when the user chose it at Gate 2 **and** it is enabled in config | `scripts/Invoke-IntuneAppAssignment.ps1` |
| An older version is never deleted; new versions coexist (`-OnExisting CreateNewCoexist`), so a rollback target always exists | `scripts/Invoke-IntuneWin32Upload.ps1` |

### 3. Content fetched from the internet flowing into privileged code

Phase 2 researches switches, ProductCodes and fingerprints on the open web, and the result is written
into a script that later runs as SYSTEM.

| Control | Where |
|---|---|
| Retrieved content is **data, never instructions** - an instruction inside a fetched page is not followed | `SKILL.md`, Conventions; `references/research-trust.md` |
| A researched value is a claim until something deterministic confirms it: the MSI database, a definitive engine fingerprint, one probe run of the switch, the driver classifier | `scripts/Get-PsadtMsiFacts.ps1`, `scripts/Get-DriverSignatureInfo.ps1`, Appendix L.1 |
| Unverifiable values are surfaced as stated assumptions rather than silently adopted | `SKILL.md`, Operating mode |
| The same treatment applies to whatever the user places in a package's `Files\` folder | `references/research-trust.md` |

### 4. Driver and certificate trust

Some installers stage third-party drivers, whose Windows trust prompt blocks a silent SYSTEM install.

| Control | Where |
|---|---|
| Drivers are classified **before** anything is built | `scripts/Get-DriverSignatureInfo.ps1` |
| Unsigned driver: STOP. There is no packaging trick, and none is offered | `SKILL.md`, Phase 4 |
| Kernel-mode driver under Secure Boot with a vendor signature is `RED`, not a warning: `TrustedPublisher` silences the prompt but never satisfies Code Integrity | `SKILL.md`, Phase 4; Appendix Q |
| `testsigning` / `nointegritychecks` are listed as anti-patterns and never proposed - they weaken the whole device for one app | `SKILL.md`, Anti-patterns |
| A certificate is owned in exactly one place, either the Intune policy or the package, never both | `SKILL.md`, Conventions; Appendix N |

### 5. Microsoft Graph writes

Upload, group assignment and certificate/firewall policies write to the tenant.

| Control | Where |
|---|---|
| **Every write path dry-runs first**, prints the exact `-Execute` action, and waits for confirmation | `scripts/Invoke-IntuneWin32Upload.ps1`, `scripts/Invoke-IntuneAppAssignment.ps1`, `scripts/New-IntuneTrustedCertPolicy.ps1`, `scripts/New-IntuneFirewallPolicy.ps1` |
| Required roles are asserted **before** the first write, instead of discovering a 403 halfway through an upload | `scripts/Test-PsadtIntuneAccess.ps1` |
| Access state is three-valued - `verified` / `refused` / **`unknown`**. Unknown is never treated as permitted | `scripts/Test-PsadtIntuneAccess.ps1` |
| Nothing is deleted: no app version, no group, no other app's assignment. Ambiguous names are skipped, not guessed | `scripts/Invoke-IntuneAppAssignment.ps1` |
| Organisational choices are never imposed: no category, no featured flag, no branded notes | `SKILL.md`, Conventions |

### 6. Credentials at rest

| Item | Handling |
|---|---|
| Client secret | Encrypted with **DPAPI**, bound to the current Windows user profile. A re-installed OS invalidates it by design - it cannot be moved to another machine or user |
| Preferred alternative | A **certificate** (`-UseCertificate -CertThumbprint`); `intune.certThumbprint` takes precedence over a stored secret |
| Location | `%LOCALAPPDATA%\psadt-deploy\` (override `$env:PSADT_DEPLOY_HOME`) - **outside the skill folder**, so a re-clone, update or re-install cannot read, move or overwrite it |
| Repository hygiene | `config.json`, `secret.dpapi`, `tools/`, `*.pfx`, `*.cer`, `*.key` and `secrets.*` are gitignored |
| Expiry | The setup doctor counts down to credential expiry and warns inside 30 days |

The Entra application is created by `scripts/New-PsadtEntraApp.ps1` and needs administrator consent.
Group-management permissions are a separate opt-in flag (`-IncludeGroupManagement`), so an
upload-only installation never carries them.

### 7. Artefacts that leave the machine

Helper scripts placed in a package's Output folder are copied to test clients that do not have this
skill installed.

| Control | Where |
|---|---|
| Such deliverables must be fully self-contained: no dot-sourcing of skill files, no hardcoded skill path, no `-SkillRoot` dependency | `SKILL.md`, Conventions |
| This is enforced by a test, not by convention | `tests/New-IntuneFirewallPolicy.Tests.ps1` |
| Client-side authentication is interactive (WAM) or a passed token - never an embedded secret | `scripts/New-IntuneFirewallPolicy.ps1` |

### 8. Supply chain

| Item | Handling |
|---|---|
| Installer | `npx psadt-deploy-skill` has **zero npm dependencies** and ships only `bin/`; the skill itself is fetched from GitHub at install time. Enforced by `tests/Package.Tests.ps1` |
| Pinning | Releases are tagged. `--ref <tag>` installs a specific release; `--ref main` is an explicit opt-in to the development branch |
| Updates | `scripts/Update-PsadtSkill.ps1` is read-only until `-Apply`, never auto-applies, and overwrites only tracked repository files - never `config.json`, `secret.dpapi` or `tools/` |
| Verification | Every change runs the Pester suite on a clean Windows runner (`.github/workflows/tests.yml`) |

## What this skill never does

- Delete an existing Intune app, app version, group or another app's assignment.
- Assign an app to anyone unless the user opted in at a decision gate.
- Upload a package whose SYSTEM test did not pass.
- Run `-Execute` on any write path without a preceding dry-run and a confirmation.
- Disable Defender, enable `testsigning`, or weaken Code Integrity to make an install succeed.
- Store a secret inside the skill folder or the repository.
- Send telemetry, or transmit package contents, logs or configuration anywhere other than the
  Microsoft Graph endpoint the user configured.

## Reporting a vulnerability

Open a security advisory or an issue at
<https://github.com/pt1987/claude-code-psadt-skill/issues>. Please do not include tenant identifiers,
client secrets or certificate material in a public report.

## Supported versions

The most recent release receives fixes. Version history is in `CHANGELOG.md`; releases are tagged in
the repository.

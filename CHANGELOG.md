# Changelog

All notable changes to this skill. Newest first. This project follows a loose [SemVer](https://semver.org/).

## 0.11.0 — 2026-06-15 — Firewall-rules policy + app config-management permission

### Added
- **`scripts/New-IntuneFirewallPolicy.ps1`** — prepares (and optionally creates via Graph) an Intune Endpoint
  Security "Windows Firewall Rules" policy with one program-scoped rule (`-FilePath`, `-Direction In/Out`,
  `-Action Allow/Block`, `-Profiles Domain/Private/Public`). The policy-based way to suppress the first-run
  Windows Firewall prompt for apps that listen inbound (e.g. MxManagementCenter) — a non-admin user cannot
  approve it. Read-only dry-run by default; `-Execute` creates it app-only via `Get-GraphToken.ps1`, and on a
  missing `DeviceManagementConfiguration.ReadWrite.All` (403) prints ready-to-paste manual portal steps.
  New `tests/New-IntuneFirewallPolicy.Tests.ps1` (10 cases: profile mask, rule children, policy body, manual
  steps, dry run).
- **`New-PsadtEntraApp.ps1 -IncludeConfigurationManagement`** — opt-in switch that adds + admin-consents the
  Graph application role `DeviceManagementConfiguration.ReadWrite.All`, so the upload app can create
  config / Endpoint-Security policies app-only (firewall rules **and** the 0.10.0 trusted-cert policy). Mirrors
  `-IncludeGroupManagement`; reflected in the reuse-app PATCH. Off by default.

### Changed
- **`New-IntuneTrustedCertPolicy.ps1`** — its help and the 403 hint now point at
  `New-PsadtEntraApp.ps1 -Force -IncludeConfigurationManagement` as the supported way to grant the role
  (instead of implying manual-only), now that the switch exists.
- **SKILL.md** — Phase-0 setup documents the new `-IncludeConfigurationManagement` switch.

## 0.10.0 — 2026-06-15 — Certificate store deployment (driver-trust / TrustedPublisher)

### Added
- **`scripts/New-IntuneTrustedCertPolicy.ps1`** — prepares (and optionally creates via Graph) an Intune Custom
  OMA-URI configuration profile that places a certificate into a Windows machine store (Root / CA /
  **TrustedPublisher** / TrustedPeople) via the `RootCATrustedCertificates` CSP. The transparent, policy-based way
  to suppress the Windows "install device software?" prompt for installers that stage a 3rd-party driver. Extracts
  the Authenticode signer cert from a signed payload (MSI/EXE/.cat) or loads a raw `.cer`; emits single-line
  base64 + the exact OMA-URI; read-only dry-run, `-Execute` creates the profile, and on a missing
  `DeviceManagementConfiguration.ReadWrite.All` (403) it prints ready-to-paste manual portal steps instead of
  failing. New `tests/New-IntuneTrustedCertPolicy.Tests.ps1` (9 cases).
- **Guide Appendix N** — certificate store deployment: store→mechanism matrix (the built-in Trusted-certificate
  template can't target TrustedPublisher/TrustedPeople — the CSP can), the base64/thumbprint `0x87d1fde8`
  gotchas, the policy-vs-package single-owner rule, Graph permission + manual fallback.
- **Dossier "Treiber-Zertifikat" row** — `New-PsadtReport.ps1` gains a `CertPolicy` metadata field
  (Store/Owner/Thumbprint/OmaUri) rendered in the Requirements card; defaults to "none". `Report-Template.html`
  gains `{{V_CERT_POLICY}}`.
- **SKILL.md** — new binding Convention (certificates into a machine store), a Phase-4 driver-trust touchpoint,
  an anti-pattern (claiming Intune can't do TrustedPublisher / multi-line base64 / dual ownership), and the
  Appendix-N reference.

## 0.9.2 — 2026-06-12 — Reconcile diverged install copy: SYSTEM-test fix, richer report, MSI generator

A separate working copy had drifted from `main`; its genuinely newer parts were merged back into the repo
(the canonical source). The repo keeps the 0.9.0 `_GraphCommon` refactor, unified 0-12 phases and full test
suite; only the items below were brought in.

### Fixed
- **`Invoke-PsadtSystemTest.ps1` crashed at param binding under the WinPS 5.1 re-exec.** The `$SkillRoot`
  default was `Split-Path $PSScriptRoot -Parent`. When the script self-re-execs from PowerShell 7 (Core) to
  Windows PowerShell 5.1 via `powershell.exe -File`, `$PSScriptRoot` can be empty during parameter-default
  evaluation, so `Split-Path` threw `ParameterArgumentValidationErrorEmptyStringNotAllowed` and every SYSTEM
  action returned `ExitCode=EXC, Success=false` ("child produced no result") **before the MSI ever ran** -
  making the mandatory Install/Uninstall gate impossible to pass on a pwsh-7 host. The default is now
  fail-safe: it falls back to `$PSCommandPath` and finally to an empty string (the param is currently unused
  downstream, so an empty value is harmless). No other logic changed.

### Added
- **Per-field copy buttons in the HTML dossier.** `references/Report-Template.html` gains a `file://`-safe
  clipboard path (synchronous `execCommand` first, async Clipboard API as a best-effort bonus) plus a copy
  icon on every Intune value cell, recomputed at click time so it follows the DE/EN toggle. `{{LANG}}` is
  retained so the generator still controls the root language. The token set is unchanged, so the existing
  `New-PsadtReport.ps1` fills the template as-is.
- **`scripts/New-MsiPackage.ps1`** - reusable PSADT v4.1.8 MSI package generator (scaffold + fully-customized
  ASCII `Invoke-AppDeployToolkit.ps1` for Install/Uninstall/Repair + registry detection script). The hard-coded
  `.claude\skills\...` path for `Get-PsadtConfig` was replaced with a `$PSScriptRoot` sibling lookup so it runs
  from any location. New `tests/New-MsiPackage.Tests.ps1` (AST parse, mandatory-param, ASCII, no-hard-path).

## 0.9.1 — 2026-06-12 — Applicability/portability drift cleanup (docs + instructions)

Follow-up to the 0.9.0 audit: a consistency pass found documented behaviour that no longer matched the
implementation. No script logic changed.

### Fixed
- **Dead config keys removed.** SKILL.md Phase 6 described the SYSTEM-test loop as honouring
  `test.maxIterations` / `test.endState`, but neither key exists in any script or in the `Get-PsadtConfig`
  schema. The cap is now stated as a hard count of 5 the orchestrator owns, and the end-state as "uninstalled"
  in plain text - no phantom config.
- **Stale phase numbers.** SKILL.md handoff rules said "Upload (7.5)" and `references/app-registration.md`
  said "Phase 7.5"; both now correctly read **Phase 9** (the unified 0-12 numbering from 0.9.0).
- **README project tree.** `New-PsadtReport.ps1` was labelled "Phase 7" (now **Phase 8**), and three shipped
  scripts were missing from the tree: `Invoke-PsadtPreflight.ps1` (Phase 5), `Invoke-IntuneAppAssignment.ps1`
  (Phase 10), `_GraphCommon.ps1` (shared Graph helpers).

### Changed
- **`superpowers` is now an optional methodology layer, not a hard dependency.** The Researcher/Reviewer roles
  referenced `superpowers:dispatching-parallel-agents` and `superpowers:requesting-code-review` as `REQUIRED`,
  but that plugin was never declared as a prerequisite anywhere. Those references are now "prefer if installed;
  else fall back to the native Agent tool / `/code-review`", the workflow no longer depends on the plugin, and
  the README Requirements list documents it as an optional (recommended) enhancement.

## 0.9.0 — 2026-06-11 — Audit cleanup (quality, content, applicability/compatibility, tests)

A three-auditor review surfaced concrete defects; the maintainer decided per-category which to fix. Security
items (secret hygiene) were deliberately out of scope; the one correctness bug was included.

### Added
- **Test coverage for the four previously-untested high-risk scripts** (upload, assignment, Entra-app,
  Get-GraphToken) plus `_GraphCommon` - 28 new Pester cases (param validation, dry-run = no writes,
  idempotency, `-MinWindowsRelease` ValidateSet, DPAPI round-trip, retry-only-on-transient, and a regression
  guard for the precedence bug below). Full suite is now 74 cases.
- **`scripts/_GraphCommon.ps1`** - shared `Invoke-Graph` / `Get-GraphErr` / `Write-*` plus cross-version
  `Get-GraphStatusCode` + `Get-GraphRetryAfterSeconds`, dot-sourced by the three Graph scripts (the request/
  retry/error logic was copy-pasted three times, which let a bug drift into one copy).

### Fixed
- **Operator-precedence bug** in `New-PsadtEntraApp.ps1` `Invoke-WithRetry`: `-in ... -and` without parentheses
  was an always-truthy array, so EVERY error was retried 6x (including real permission denials). Parenthesized
  and regression-tested.
- **PS7-fragile throttling.** `Retry-After` / HTTP-status reads now work on Windows PowerShell 5.1 AND
  PowerShell 7 (the old `[int]$Headers['Retry-After']` threw on PS7, silently dropping the server's hint).
- **Report "green by default."** `New-PsadtReport.ps1` no longer renders synthetic `passed` rows for
  pre-flight / SYSTEM-test when no real results are supplied - it shows a neutral "not run" state (the same
  honesty rule as the 0.7.5 exit-code fix). The PSADT version default now comes from the installed module, not
  the literal `4.1.8`.
- **GUID validation** (`ValidatePattern`) on `-MsiProductCode` / `-MsiUpgradeCode` (a malformed code previously
  failed late, server-side).
- **Guide self-contradictions**: the `$adtSession` template showed `AppScriptVersion='<1.0.0>'` + a literal
  author (contradicting the BINDING "always 0.1, author from config" rule); the intro appendix index listed
  only A-G with wrong labels. Both corrected to `0.1`/config and the full A-M list.

### Changed
- **Phase numbering unified** across SKILL.md and the guide into ONE integer scheme **0-12** (Setup, Intake,
  Research, Scaffold, Hooks, Pre-flight, SYSTEM test, Package, Report, Upload, Groups, Test, Rollout).
  Previously the two files used offset numbers (SKILL 0-9 with `.5` sub-phases, guide 0-7), so guide
  references to "Phase 5.5 / 7.5" pointed at the wrong sections. Every Phase + Appendix cross-reference was
  re-verified - all resolve.
- **Redundancy trimmed**: SKILL.md anti-pattern list reduced to the top offenders + a pointer to guide
  B/I.7/K.7; the dense language-split convention split into two clear rules.
- **Docs added**: SYSTEM-test prerequisites stated prominently (WinPS 5.1 + elevation + `Invoke-CommandAs` +
  VM); `/beta` drift caveat (guide H.1); upload wires supersedence but NOT app dependencies (`-DependsOnAppId`
  is portal-only); explicit rollback step (Phase 12); PSADT log-path logging convention; comment-based help
  completed on Get/Set-PsadtConfig; README setup table documents the optional `intune.*` / `intune.groups.*`
  blocks, fixes "App. A-J" -> "A-M", and clarifies the uploader does no group assignment (separate opt-in).
- **Test harness**: `Run-All.ps1` fails fast with a clear message if Pester < 5; removed a dead invocation in
  the report umlaut test; documented the SYSTEM-test re-exec path as untested-by-design.

## 0.8.1 — 2026-06-11 — Docs consistency fixes

### Fixed
- **Stale cross-reference in SKILL.md.** The intro pointed at the guide as "Phases 0-7 + Appendix **A-J**",
  but the guide now runs through **Appendix M** - K/L were added in 0.7.0 and M in 0.8.0 without updating this
  range. Now reads "Appendix A-M". (Phases 0-7 is correct: those are the guide's phase headers.)
- **Missing 0.5.3 entry in the README changelog mirror.** `CHANGELOG.md` had the 0.5.3 release but the README's
  mirrored "Changelog" section skipped it. Restored, so the two changelogs match entry-for-entry.

## 0.8.0 — 2026-06-11 — Opt-in Entra group assignment (wired end-to-end) + min-OS upload fix

### Added
- **Group assignment as a first-class opt-in step (Phase 7.6).** `Invoke-IntuneAppAssignment.ps1` creates/reuses
  Entra security groups by a configured naming scheme and assigns the uploaded `win32LobApp`
  (intents required/available/uninstall). Read-only dry-run by default, `-Execute` writes; idempotent; never
  deletes a group or another app's assignment; ambiguous/duplicate names are skipped, not guessed.
- **`New-PsadtEntraApp.ps1 -IncludeGroupManagement`** consents the least-privilege group roles `Group.Create`
  + `GroupMember.Read.All` (NOT tenant-wide `Group.ReadWrite.All`) on the existing upload app.
- **`intune.groups` config schema** (`enabled`, `create`, `membershipType: assigned`,
  `naming.{required|available|uninstall}`), validated by `Get-PsadtConfig.ps1`.
- **Guide Appendix M** — the full feature reference: permission model, config schema + `Set-PsadtConfig`
  snippet, naming tokens, the version-INDEPENDENT default (so a new version reuses the same groups for
  supersedence) vs the `%version%` opt-in, the "no `%intent%` token" rule, dry-run -> execute workflow,
  idempotency/ambiguous/missing handling, and `-SkillRoot`/config-location gotchas.

### Fixed
- **`Invoke-IntuneWin32Upload.ps1 -MinWindowsRelease` no longer dies mid-upload.** The Graph backend
  validates `minimumSupportedWindowsRelease` as a server-side string and rejects unknown values
  (`BadRequest: Unknown MinimumSupportedWindowsRelease`, e.g. `21H2`/`22H2`) only at the create step. The
  parameter is now a `ValidateSet` of backend-accepted release IDs (`1607..2004`) that fails fast at param
  binding with the valid list; set a higher minimum in the portal if needed. New guide note **H.11**.

### Wiring
- **SKILL.md** wired for the feature: Gate 2 ties "AAD groups" to the opt-in; Phase 0 mentions
  `-IncludeGroupManagement`; new Phase 7.6; the "never auto-assign group" lines reframed as "only when the
  user opted in at Gate 2 AND `intune.groups.enabled`"; anti-patterns for reflexive `%version%` and a
  non-existent `%intent%` token; troubleshooting rows for the min-OS and group-permission errors.

## 0.7.5 — 2026-06-10 — Honest exit codes + detection for fix/remediation packages

### Fixed
- **Removed the dangerous "always exit 0" guidance** from guide **Appendix K**. A blanket `exit 0` (and a
  detection tag written in a `finally`) reports GREEN on failure — a real defect that hides broken deployments.
  The recipe now teaches the honest model (new **K.7**):
  - **Exit code = could the fix RUN?** Ran to completion -> `0`; couldn't run / crashed -> **non-zero**. The
    64-bit relaunch now **propagates the child's exit code** (`exit $LASTEXITCODE`), never a hard-coded `0` (K.2).
  - **Detection = the real END-STATE**, not an unconditional tag; if a tag is used, write it ONLY on a successful
    run (never in a `finally`). A failed fix -> detection negative -> Intune retry + **visible** (K.5).
  - Per-package decision table (real installer / important fix / non-critical ESP cleanup), and "never block
    enrollment" reframed as an explicit ESP-assignment + return-code-mapping choice (K.6), not a masked exit code.
- **SKILL.md** anti-pattern added: a blanket `exit 0` or a `finally`-written tag both report green on failure.

## 0.7.0 — 2026-06-10 — Value-adding extensions (pre-flight tool, recipes, knowledge)

### Added
- **`scripts/Invoke-PsadtPreflight.ps1`** — the Phase-5 Reviewer gate as one deterministic, testable tool.
  `-PackagePath <pkg>` returns `{ Overall='GREEN'|'RED'; Checks=@(...) }` covering encoding (ASCII/BOM), AST
  parse, v3-cmdlet scan (launcher + Extensions only; a private `Write-Log` in a bundled `Files\*.ps1` is no
  longer a false positive), top-level-statement scan, the structural acid-test (all three hooks defined +
  Extensions helpers actually called), and the GUID→`-FilePath` anti-pattern. New `tests/Invoke-PsadtPreflight.Tests.ps1`
  (clean package = GREEN; em-dash / v3 cmdlet / GUID-to-`-FilePath` / missing-hook fixtures = RED).
- **Guide Appendix K — script-only remediation / fix packages (ESP-safe).** Codifies the recurring
  debloat/Cisco-style pattern: run a bundled PS script via native 64-bit PowerShell (Extensions helper shared by
  Install + Repair), self-healing file/tag detection, no-op uninstall that never removes the fixed artifact,
  `DeployMode Silent`, always exit 0, `CloseProcesses` for in-use files, ESP blocking-app wiring.
- **Guide Appendix L — installer technologies + silent switches.** A lookup (consulted before web research):
  identify MSI / MSI-wrapped EXE / InstallShield / Inno Setup / NSIS / WiX Burn / Squirrel / MSIX / install4j /
  Wise, with silent install/uninstall/no-reboot/log switches and the natural detection rule.
- **Expanded error-code catalogue** (guide Appendix A.1 + new A.4; highest-frequency rows in the SKILL.md
  troubleshooting table): MSI 1603/1605/1618/1619/1620/1622/1625/1635/1638/1639/110x, the matching `0x8007…`
  HRESULTs, and the PSADT 60001/60008 + 60002–60007/69000+/70000+ ranges — each with a concrete reaction.

### Changed
- **SKILL.md** Phase 5 now points at the pre-flight script (GREEN required); Phase 2 research consults Appendix L
  first (and Appendix K for script-only fixes); reference lookup + anti-patterns updated. SKILL.md stays a lean
  control plane (no inlined code).

## 0.6.2 — 2026-06-10 — Audit & harden (scripts, report, guide)

A full agent-based audit (3 parallel reviewers) followed by source-level verification of every finding
(which discarded ~8 false positives). Only verified weaknesses were fixed; the proven Graph request shapes
were left untouched.

### Fixed
- **Guide doc-vs-code that broke packaging** (`references/PSADTv4-Deployment-Guide.md`): the "Extended scaffold"
  told the agent to pass `-AppVendor/-AppName/-AppVersion/...` to `New-ADTTemplate`, which v4.1.x rejects
  ("A parameter cannot be found …"). Removed it; metadata goes into `$adtSession` after scaffolding (matches SKILL.md).
- **Upload leaves AES keys in `%TEMP%`** (`scripts/Invoke-IntuneWin32Upload.ps1`): the extracted work dir
  (whose `Detection.xml` holds `encryptionKey/macKey/IV/mac`) is now removed via `try/finally` on success,
  dry-run, or throw.
- **Report `Notes` double-escape** (`scripts/New-PsadtReport.ps1`): the default `Notes` contained `&middot;`,
  which `Esc` turned into a literal `&amp;middot;`. Switched the default to ASCII separators.
- **Fallback logo hardening** (`scripts/New-PsadtReport.ps1`): the initials-tile SVG now XML-escapes the
  AppName-derived initials and is emitted as a base64 data URI (a special character can no longer break or
  inject markup). New regression test in `tests/New-PsadtReport.Tests.ps1`.

### Changed (robustness)
- **Graph throttling retry** (additive): `Invoke-Graph` now retries 429 / 5xx honouring `Retry-After`
  (max 4 attempts); request bodies unchanged.
- **Malformed-config safety**: `Get-PsadtConfig`, `Get-IntuneWinAppUtil`, `Get-WinGetModule`, `Set-PsadtConfig`
  now handle a corrupt `config.json` with a clear message instead of a raw `ConvertFrom-Json` throw.
- **Download hardening**: WinGet zip header check reads only 2 bytes (not the whole archive) and guards a
  <2-byte download; `Get-IntuneWinAppUtil` releases its file handle via `finally`; `Update-PsadtSkill` cleans
  its temp files on the failure path too.
- Doc comment corrected: block-blob upload uses 4 MB blocks (was mislabelled "6 MB").

## 0.6.1 — 2026-06-10 — Report header: fix scrollbar-feedback flicker

### Fixed
- **`references/Report-Template.html` — wild header flicker at certain viewport widths.** The dossier did not
  reserve the vertical scrollbar gutter, so at widths where the content height landed at the viewport edge the
  scrollbar toggled on/off; each toggle changed the content width, and the header's `vw`-based `clamp()` padding
  and `h1` font-size reflowed on every toggle, producing a rapid flicker loop. Reserving the gutter
  (`html { overflow-y: scroll; scrollbar-gutter: stable; }`) holds the width constant and breaks the loop.

## 0.6.0 — 2026-06-10 — SKILL.md slimmed to a control plane (progressive disclosure)

### Changed
- **`SKILL.md` rewritten as a lean orchestrator: 733 → 244 lines (~16k → ~3.5k tokens, ~67% smaller).** It
  now holds the binding conventions, the workflow skeleton, the decision gates, and pointers - the long
  inline PowerShell blocks (encoding fix, pre-flight scans, packaging, logo fetch, MSI icon-table extraction,
  WinGet lifecycle, upload examples) moved into the reference guide and load on demand. No behaviour and no
  binding rule was dropped - all 11 conventions, the self-update flow, all phases, the troubleshooting table,
  and the anti-pattern list are preserved (verbatim where they are rules, relocated where they are code).
- **Autonomy:** intake is restructured from 8 mandatory questions into **4 decision gates**; everything
  researchable (version, installer type, silent/uninstall/repair switches, ProductCode, Intune issues) is now
  a researched, transparently-stated assumption instead of a question. `AskUserQuestion` is still the only way
  to ask, and the test/upload consents are unchanged.
- **Sub-agent architecture:** explicit Orchestrator / Researcher×3 / Builder / Reviewer roles with hard
  handoff gates (no packaging before a GREEN pre-flight; no upload before a GREEN SYSTEM test), wired to
  `superpowers:dispatching-parallel-agents` and `superpowers:requesting-code-review`.
- **Error handling:** a single **blockade protocol** (`PROBLEM / TRIED / OPTIONS 1,2`) replaces the scattered
  "stop and hand back" notes.
- **Frontmatter `description`** trimmed to triggering conditions only (no workflow summary), per Anthropic
  skill-authoring guidance.

### Added
- **`references/PSADTv4-Deployment-Guide.md` — Appendix I (WinGet packaging)** and **Appendix J (app-logo
  acquisition + verification)**: the WinGet discovery/provisioning/hook/detection code and the logo
  source-priority / Wikimedia / MSI icon-table / corner-pixel-verification code, lifted verbatim from the old
  SKILL.md so nothing is lost. The guide now spans Appendix A–J.

## 0.5.3 — 2026-06-09 — Guide: code inside code-fences is now English/ASCII

### Changed
- **`references/PSADTv4-Deployment-Guide.md`** — anglicized every German comment, string literal and
  placeholder that lived **inside PowerShell/text code fences** (and the inline-code placeholders in the
  Appendix F.1 table). Examples: `# Lokale Modulversion` → `# Local module version`,
  `"Neueste: … vom …"` → `"Latest: … from …"`, `<Hersteller>` → `<Vendor>`,
  `<Vorname Nachname>` → `<FirstName LastName>`, `<pfad-zur-ps1>` → `<path-to-ps1>`,
  `<prozess1>` → `<process1>`. Reason: snippets get copied verbatim into deployment scripts, where the
  binding rule is English + 7-bit ASCII — German comments/umlauts in a copied snippet are exactly the
  encoding/consistency failure class the pre-flight warns about.
- Deliberately **left unchanged**: the German explanatory **prose** of the guide and the **F.2 Company
  Portal description template** (legitimate end-user dossier text, `language.dossier` = German with real
  umlauts). No script/tooling code changed; `scripts/` and `Report-Template.html` were already compliant
  (German only as dossier output, ASCII-clean via HTML entities).

## 0.5.2 — 2026-06-08 — Always-on HTML package report (template + generator)

### Added
- **`scripts/New-PsadtReport.ps1`** (+ `tests/New-PsadtReport.Tests.ps1`, 9 cases): generates the package
  report as a single self-contained HTML file from the fixed template `references/Report-Template.html`.
  Data-driven via a `-Metadata` hashtable (or `-MetadataPath` JSON) with sane defaults for every field, so a
  minimal call still yields a complete report. Variable-length sections (return codes, cmdlets, deployment-hook
  bullets, pre-flight checks, SYSTEM-test rows, assignments) are built from arrays. The logo is embedded as a
  base64 data URI (fallback: a neutral initials tile), and free text is HTML-escaped (no injection).
- **`references/Report-Template.html`** — the fixed, tokenized report template. Fluent-2 styling, a **sticky
  header that shrinks on scroll** (with hysteresis to avoid flicker; disabled on mobile), the **real app logo
  in the header**, a **DE/EN language toggle** (decoupled, absolutely-positioned status block so switching
  never shifts the layout), and a client-side Markdown renderer so the description **preview is generated from
  its Markdown source**. The document stays browser-translatable.

### Changed
- **The HTML report is now BINDING — generated for EVERY package, whether or not it is uploaded to Intune.**
  It is one combined document: the **Intune dossier** (App Info, description, Program, Return Codes,
  Requirements, Detection, Dependencies, Supersedence, Assignments) **plus a technical package report**
  (deployment hooks, PSADT cmdlets used, pre-flight + SYSTEM-test results, logo/`.intunewin` verification).
  SKILL.md Phase 7 + conventions updated; Appendix F rewritten around the generator + the `-Metadata` key list;
  README Features/structure updated. New anti-patterns: never skip the report, never hand-assemble it.
- The report is bilingual and keeps **real umlauts** (the report is end-user output — the script-only ASCII
  rule does not apply; the template is ASCII via HTML entities, umlauts come from the description metadata,
  output is written UTF-8).

## 0.5.1 — 2026-06-06 — Robust commit-based self-update + README fix

### Changed
- **Self-update now decides by commit, not by the CHANGELOG version.** `Update-PsadtSkill.ps1` compares the
  local `HEAD` against `origin/<branch>` (git clone) or the GitHub commits-API sha against the recorded
  `tooling.skillCommit` (non-clone). This removes the `raw.githubusercontent.com` CDN cache lag and the
  circular "read the version from a file that can't know about a newer one." The CHANGELOG version is now
  shown only as context (`RemoteVersion` / `WhatsNew`); `Behind` reports how many commits behind a clone is.

### Fixed
- README project-structure tree compacted so it renders without horizontal scroll / truncated right-hand comments.

## 0.5.0 — 2026-06-06 — Skill self-update

### Added
- **`scripts/Update-PsadtSkill.ps1`** (+ Pester tests): checks GitHub for a newer skill version (compares the
  top `CHANGELOG.md` version), reports `LocalVersion` / `RemoteVersion` / `UpdateAvailable` / `WhatsNew`, and
  on confirmation updates **in place** — `git pull --ff-only` for a clone, otherwise overwrites only the
  tracked files (`SKILL.md`, `README.md`, `CHANGELOG.md`, `LICENSE`, `references/`, `scripts/`, `tests/`) from
  the branch zip. `config.json`, `secret.dpapi`, `tools/` and `docs/` are never touched.
- **SKILL.md**: a "Self-update" section + a non-blocking check at the start of Phase 0; triggers
  "update skill" / "/update-skill" / "psadt update" / "check for skill updates". The skill always **asks**
  before applying; an update check never blocks packaging.

## 0.4.0 — 2026-06-06 — WinGet support + certificate auth (PR #4)

Contributed by **@joakim-i** (PR #4), reviewed + hardened before merge.

### Added
- **WinGet packaging support** (strictly **opt-in**, never the default): `scripts/Get-WinGetModule.ps1`
  (self-heals the `PSAppDeployToolkit.WinGet` extension into `tools/` + the package), full SKILL.md lifecycle
  (intake Q2 option, Phase 2b discovery, install/uninstall/repair via `*-ADTWinGet*`, detection caveats,
  anti-patterns) and `tests/Get-WinGetModule.Tests.ps1`.
- **Certificate-based auth for Phase 7.5** — `New-PsadtEntraApp.ps1 -UseCertificate -CertThumbprint` uploads
  the cert's **public** key as an app `keyCredential`; `Get-GraphToken.ps1` signs an RFC 7523 JWT client
  assertion (RS256) with the private key (never exported). No secret at rest; config stores only the
  thumbprint. Client-secret path retained as fallback.
- **MSI Icon-table logo extraction** as a logo fallback (4-priority source list in Phase 7).

### Fixed
- Device-code polling `ScriptHalted` on the first poll (OAuth errors return a bare string, not a `.code`/`.message` object).

### Review hardening (applied on top of the PR before merge)
- Removed three junk `.gitignore` lines accidentally added by diff tooling.
- Dropped the unsubstantiated `offline_access` addition to `$WamScopes` (WAM is verified working without it; avoids
  MSAL reserved-scope risk; this one-shot bootstrap needs no refresh token).
- `Get-WinGetModule.ps1` now surfaces the **Authenticode trust state** of the third-party module (it executes on
  devices) and documents the supply-chain assumption.
- `Get-GraphToken.ps1` cert path: null-check `GetRSAPrivateKey` and dispose the RSA key.
- Made **WinGet's opt-in / never-default** rule explicit in SKILL.md (intake Q2 + anti-pattern).

## 0.3.2 — 2026-06-06 — Test-before-upload is now a binding gate

### Changed
- **Install + Uninstall must pass the Phase 5.5 SYSTEM test before any Phase 7.5 upload.** SKILL.md now makes
  this a binding prerequisite (Phase 7.5 callout, Phase 5.5 link, anti-pattern, conventions). If the test
  can't be run (no elevation / no VM), STOP before `-Execute` and hand the user the exact test command —
  never upload an untested package.

## 0.3.1 — 2026-06-06 — Script detection for non-MSI apps

### Added
- **PowerShell-script detection** in `Invoke-IntuneWin32Upload.ps1` via `-DetectionScriptPath` (+ optional
  `-DetectionRunAs32Bit`): builds a `win32LobAppPowerShellScriptRule` (ruleType=detection) for EXE / non-MSI
  installers (Vivaldi, Chrome-style, NSIS, Squirrel) that have no MSI ProductCode. Mutually exclusive with
  `-MsiProductCode`. Verified live by packaging + uploading Vivaldi 8.0.4033.44.

### Lessons baked in (do-not-repeat)
- A **detection** script rule accepts ONLY `ruleType, enforceSignatureCheck, runAs32Bit, scriptContent` —
  Graph rejects `displayName`/`runAsAccount`/`operationType`/`operator`/`comparisonValue` on detection rules
  ("The <X> property may not be set for Win32LobAppPowerShellScriptRule instances used for app detection").
- Reference guide **Appendix H.2** extended; SKILL.md Phase 7.5 + anti-patterns + troubleshooting updated.

## 0.3.0 — 2026-06-06 — Direct Intune upload (Microsoft Graph)

### Added
- **Direct Intune upload** — `scripts/Invoke-IntuneWin32Upload.ps1` (Phase 7.5): self-contained raw-Graph
  upload of a `.intunewin` as a `win32LobApp` (app + logo, **no group assignment**). 8-step flow: parse
  `.intunewin` → app-only token → read-only permission probe → idempotency check → build body →
  create/update → content version → register file → poll SAS → block-blob upload (HttpClient) → commit →
  activate → categories → optional supersedence. Read-only **dry-run by default**; `-Execute` performs the
  writes.
- **WAM Entra-app bootstrap** — `scripts/New-PsadtEntraApp.ps1` now signs the admin in via **WAM** (Windows
  Web Account Manager broker) using MSAL.NET (auto-located or downloaded to `%LOCALAPPDATA%\PsadtIntune\msal`),
  with automatic **device-code fallback**. Creates the `PSADT Intune Upload` app, grants + admin-consents
  `DeviceManagementApps.ReadWrite.All`, creates a client secret, and DPAPI-stores it.
- **App-only Graph token helper** — `scripts/Get-GraphToken.ps1` (client-credentials; DPAPI secret decrypted
  in-memory only).
- **Full App-information metadata** — the uploader fills `displayName, description, publisher, developer,
  owner, displayVersion, informationUrl, privacyInformationUrl, notes, largeIcon, msiInformation,
  returnCodes, rules, installExperience` instead of the bare minimum.
- **Coexistence-safe versioning** — `-OnExisting CreateNewCoexist` (default) uploads a new version as a
  **separate** app and never touches the existing one; `-UpdateAppId` for explicit in-place update;
  `-SupersedesAppId` wires "new replaces old". The script issues only POST/PATCH — **never DELETE**.
- **Logo guard** — refuses the PSADT default `Assets\AppIcon.png` (SHA256 blocklist) unless
  `-AllowDefaultLogo`; warns when no logo is supplied.
- **Reference guide Appendix H** — the hard-won Graph upload lessons (see below). README + SKILL.md updated;
  `references/app-registration.md` manual portal fallback.

### Fixed
- **Repair `-FilePath`→`-ProductCode`** — the `Repair-ADTDeployment` MSI example (and the 7-Zip package) used
  `-FilePath '{GUID}'`, which PSADT 4.1.x rejects with `InvalidFilePathParameterValue` (exit 60001). The
  Uninstall fix had been applied earlier but Repair was missed — now corrected in SKILL.md and the guide.

### Lessons baked in (do-not-repeat)
- Use the unified **`rules`** collection (`win32LobAppProductCodeRule`, `ruleType=detection`), **not** the
  legacy `detectionRules` — the current backend rejects the latter ("must have at least one detection rule").
- **`@odata.type` must serialise first** in polymorphic sub-objects (`[ordered]@{}`).
- Upload the encrypted blob with **HttpClient/ByteArrayContent**, not `Invoke-RestMethod -Body <byte[]>`
  (binary corruption → `commitFileFailed`).
- Write win32LobApp metadata on **`/beta`** — `/v1.0` silently drops `displayVersion` and others.
- **Never the default PSADT logo** as the app logo; `IsAlphaPixelFormat` is not proof of transparency.
- **Never auto-impose** category / branded notes / featured / group assignment; **never delete** an older
  version.

## 0.2.0 — Automated SYSTEM test loop

- **Automated SYSTEM test loop** (`scripts/Invoke-PsadtSystemTest.ps1`, Phase 5.5): install → uninstall →
  reinstall the package as the SYSTEM account via `Invoke-CommandAs`, with agent-driven auto-fix until green
  or a max-iteration cap. Opt-in; elevated session required.
- Phase 8 now prefers `Invoke-CommandAs -AsSystem` for SYSTEM-context testing (PsExec kept as a fallback).
- Self-re-exec to Windows PowerShell 5.1 when run under pwsh 7 (PSScheduledJob is 5.1-only). See guide
  Appendix G (2026-06-05).

## 0.1.0 — Initial release

- Guided PSADT v4 → Intune Win32 lifecycle: intake, autonomous research, scaffolding, all three deployment
  types (Install/Uninstall/Repair), pre-flight checks, packaging, dossier + logo, guided testing,
  troubleshooting.
- First-run setup writing a machine-local `config.json` (paths, language, author).
- Self-healing prerequisites: PSAppDeployToolkit module (PSGallery) and `IntuneWinAppUtil.exe` (auto-download
  + version check).
- HTML dossier document with a Markdown app-description block (the Intune description field is Markdown-only).
- English skill + reference guide; MIT licensed.

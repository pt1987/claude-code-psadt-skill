# Changelog

All notable changes to this skill. Newest first. This project follows a loose [SemVer](https://semver.org/).

## 0.21.0 — 2026-09-04 — Package manifest, deterministic packaging, one log per run

### Added
- **`psadt-package.json` — one manifest per package, and the single source of truth for that app.**
  Schema 1 records the identity, the decisions taken at the gates, the research findings, every phase's
  `results.*` and the `artifacts.*`. Read with `scripts/Get-PsadtPackageManifest.ps1` (gaps in `.Missing`,
  never a throw), written with `scripts/Set-PsadtPackageManifest.ps1` (dotted paths, deep merge,
  `-Remove`, and `-Append` for the results arrays). Before this, an app's identity lived in the operator's
  head and in `$meta` arguments — which is how two packages of the same app could disagree about their own
  version.
- **`scripts/Invoke-PsadtPackage.ps1` — one packaging command.** Derives the name from the manifest, packs
  with `-o` pointing at a private temp folder, verifies the archive (`Detection.xml`, content blob,
  recorded `SetupFile`, unencrypted size, SHA256), renames the artifact, copies the detection script and
  the real logo next to it, and records `artifacts.*` + `results.package`.
- **Guide: the missing phase headings.** `## Phase 6` (SYSTEM test), `## Phase 9` (upload) and
  `## Phase 10` (assignment) exist as sections now instead of being mentioned only in passing.

### Changed
- **The `.intunewin` is finally named after the app.** New binding convention:
  `<paths.outputRoot>\<Vendor>_<App>_<Version>_<Arch>\<same stem>.intunewin`.
  **Why:** `-s` is always `Invoke-AppDeployToolkit.exe` and IntuneWinAppUtil names its output after it, so
  every package produced `Invoke-AppDeployToolkit.intunewin`. That generic name reached Intune as
  `win32LobApp.fileName`, and every concurrent upload collided in the same
  `%TEMP%\iwup-Invoke-AppDeployToolkit` working folder. Renaming is safe because the upload reads
  `setupFilePath` from the archive's INNER `Detection.xml` — a test pins that. Existing folders using the
  old `<App[-Version]>` scheme are never touched or renamed.
- **One PSADT log per run.** All three generators now emit
  `LogName = <Vendor>_<App>_<Version>_<Arch>_<DeploymentType>_<yyyyMMdd-HHmmss>.log` in the launcher's
  `$adtSession`. `Toolkit.LogAppend` is `$true` by default in 4.1.8 and the name was fixed, so every run of
  every version appended to one file — by the third attempt a failed install is unreadable. Location stays
  `C:\Windows\Logs\Software` and `LogAppend` is untouched.
- **The generators write the manifest**, so the identity that names the log and the artifact is recorded
  where every later phase reads it. The sanitizing rule exists exactly once
  (`Get-PsadtPackageManifest.ps1 -Identity`) — a second copy would drift and rename an app behind
  everyone's back.
- **Every phase records its own result:** `results.preflight` (pre-flight), `results.systemTest[]` +
  `artifacts.logs[]` (each SYSTEM-test run, appended — Install and Uninstall are two pieces of evidence),
  `results.package`, `results.upload` (app id, content version, portal URL, tenant).
- **Pre-flight: two new checks.** `Manifest` FAILs (→ RED) on a missing, malformed or incomplete manifest —
  the artifact name is derived from that identity, so a package that cannot say what it is cannot be
  packed, reported on or uploaded consistently; the PASS line reports the artifact stem, which is the
  fastest way to catch a wrong version before anything is built. `LogName` WARNs for a pre-0.21 scaffold.
- **`New-PsadtReport.ps1 -ManifestPath`** takes identity and artifact names from the manifest
  (`-Metadata` still overrides every key). The mandatory floor is identity only — `AppName`, `AppVersion`,
  `Publisher`; everything else keeps rendering neutrally, because "report ALWAYS" has to hold for a package
  that is not packed or tested yet. A missing SYSTEM test throws only when `decisions.upload = true`.
- **`Invoke-IntuneWin32Upload.ps1 -ManifestPath`** supplies DisplayName / Publisher / AppVersion /
  Architecture, so the app in Intune carries the same identity as the artifact and the dossier. Explicit
  parameters always win (checked via `PSBoundParameters`).
- **`Invoke-PsadtSystemTest.ps1` picks the right log.** The old filter matched the fixed legacy name only
  and took the newest hit, so a per-run name matched nothing — and worse, a stale legacy log from last week
  could win. `Get-FreshSessionLog` accepts both shapes and requires `LastWriteTime >= the run's start`.
- **Guide Appendix E is numbered by phase** (0.1, 3.4, 7.2 …) instead of carrying a third numbering scheme,
  and says that the manifest's `results` block is the machine-readable form of the same checklist.
- **SKILL.md**: new conventions "Manifest = single source of truth per app" and "Logging: ONE log per run";
  Phase 3 makes the generators the default route; Phase 6 states plainly that it is binding before upload
  and skippable only without one; Phase 7 is now a single script call.

### Fixed
- **`New-BrowserExtensionPackage.ps1` and `New-WindowsFeaturePackage.ps1` had no tests at all.** Both now
  have the same AST/source harness as the MSI generator.
- **A single-element array silently became a hashtable merge.** `-Append` on a results array hit
  PowerShell's unwrapping of one-element arrays (`$x = if (...) { @($v) }` hands back the bare element), so
  appending the second SYSTEM-test run threw on a duplicate key instead of appending.

### Notes
- Test suite: 173 → **251** tests, all green.

## 0.20.0 — 2026-09-04 — Intune access as state, not as a 403

### Added
- **`scripts/Test-PsadtIntuneAccess.ps1` — the read-only access verdict.** Answers before Phase 9 what used
  to be answered by a 403 during it: is the configured app usable, what is it allowed to do, and for how
  long. Reports `TokenOk`, the granted `Roles`, a capability per feature
  (`Upload` / `Groups` / `Configuration`), `CredExpires` / `DaysToExpiry` and actionable `Hints`. Verified
  roles and a `lastVerified` timestamp are cached in the config; `-NoPersist` suppresses that, `-Json` /
  `-JsonPath` are for other tooling.
  - **`TokenOk` and every capability are three-valued on purpose.** `$true` verified, `$false` refused,
    `$null` "could not ask" — and for capabilities `$null` means the token could not be introspected, which
    is **not** the same as "not permitted". Graph tokens are opaque by contract, so conflating the two is
    how a working setup gets declared broken. A `$null` verdict never overwrites persisted state: being
    offline is not evidence that an app lost its permissions.
- **Token introspection in `_GraphCommon.ps1`** — `Get-GraphTokenRoles`, `Assert-GraphRole` and
  `Get-GraphAuthErrorHint`, plus `ConvertFrom-JwtPayload` moved in from `New-PsadtEntraApp.ps1`. Costs **no
  extra Graph permission**: an app-only token already carries its granted roles in the `roles` claim.
- **`references/app-registration.md` section 0 is now THE permission matrix** — every app role with its
  capability and how to grant it, plus the two delegated bootstrap scopes. Guide M.1 and N.4 point there
  instead of repeating it.
- **Guide: Phase 0.4 documents the access verdict**, including the rule to gate on `Capabilities.<X>` before
  Phase 9 / 10 / a cert or firewall policy.

### Changed
- **Consumers assert the role they need before their first write.** `Invoke-IntuneWin32Upload.ps1` and
  `Invoke-IntuneAppAssignment.ps1` check the token first (no request, names the exact missing permission);
  the upload's read probe stays as proof that the permission is effective end to end. Assignment requires
  **both** group roles — an app that creates a group but cannot read its members produces a half-finished
  assignment, and the hint says which half is missing. Both policy scripts get their own embedded variant
  so they stay self-contained (a test asserts the two copies are byte-identical).
- **`Get-GraphToken.ps1`** additionally returns `Roles` and `AuthMethod`, and maps the AADSTS codes that
  actually strand a user — expired secret (7000222), invalid secret (7000215), unknown app (700016),
  unknown tenant (90002), Conditional Access (53003) — to one actionable sentence instead of
  `invalid_client`.
- **`New-PsadtEntraApp.ps1` is stateful and never prompts.** It finds the app by the recorded
  `intune.clientId` (display name only as a fallback), **merges** `requiredResourceAccess` instead of
  replacing it, persists `appObjectId` / `appDisplayName` / `credExpires` / the roles it actually holds, sets
  `uploadEnabled` only once consent is really in place, removes the other credential pointer on a method
  switch, and counts older client secrets instead of touching them. `-Force` is kept as a no-op.
- **`Get-PsadtConfig.ps1`** exposes `IntuneState` (`NotConfigured` | `Configured` | `Incomplete`), derived
  from the checks that already build `.Missing`. Group naming is deliberately excluded — a missing
  `intune.groups.naming` is a Phase 10 concern, not a broken upload path.
- **`New-IntuneFirewallPolicy.ps1`**: its own `Get-InteractiveGraphToken` took `-Tenant` while
  `_GraphInteractive.ps1` takes `-TenantId`. Unified.

### Fixed
- **Re-running `New-PsadtEntraApp.ps1` could revoke permissions.** The reuse branch sent only the roles
  requested in *that* run, so a run without `-IncludeConfigurationManagement` silently dropped the config
  role an earlier run had requested. Now merged, and only PATCHed when something is actually absent.
- **`New-PsadtEntraApp.ps1` blocked every non-interactive caller** with a `Read-Host` confirmation when the
  app already existed. Reuse is the default and nothing is prompted.
- **A credential-method switch left the other pointer behind.** `Get-GraphToken` prefers the certificate
  path, so a leftover `intune.certThumbprint` silently beat a freshly stored secret.
- **`uploadEnabled` was set to `$true` even when consent was still pending**, moving the failure to Phase 9.
- **An undecryptable DPAPI secret produced "Error occurred during a cryptographic operation."** It now says
  what actually happened (DPAPI is bound to the Windows user profile, so a re-installed OS or a copied file
  breaks it) and what to do. Found on this project's own config after a machine re-install.

### Notes
- Test suite: 128 → **173** tests, all green.

## 0.19.0 — 2026-09-04 — Config home + setup doctor

### Added
- **`scripts/Initialize-PsadtSkill.ps1` — the setup doctor.** One idempotent script replaces the Phase 0
  prose wizard. It reports **GREEN / YELLOW / RED** over 13 checks (PowerShell 7, Windows PowerShell 5.1,
  elevation, git, PSAppDeployToolkit, IntuneWinAppUtil, Invoke-CommandAs, Pester, config, legacy config,
  skill tree, pending skill update, Intune access), each with a status and a concrete fix hint — so a
  missing prerequisite is a line in a table instead of a failure three phases later.
  - `-Fix` does everything that needs no decision: migrates a legacy config home, installs the modules,
    downloads the content-prep tool, fills the `language.*` defaults (EN/DE) and records
    `paths.intuneWinAppUtil`.
  - `-Set @{...}` persists user values *before* anything is judged; `-Json` / `-JsonPath` emit the result
    for non-PowerShell callers; `-SkipUpdateCheck` skips the only network call.
  - `.Missing` deliberately lists **only what a human must supply** — `paths.packageRoot`,
    `paths.outputRoot`, `author.person`, `author.company` — never a key the doctor could fill itself.

### Changed
- **Config, secret and tools moved out of the skill folder into a per-user config home.**
  `Get-PsadtConfig.ps1` is now the single resolver: explicit `-SkillRoot` > `$env:PSADT_DEPLOY_HOME` >
  `%LOCALAPPDATA%\psadt-deploy`, and it returns `.Home` / `.DefaultHome` / `.LegacyInUse` alongside the
  config. Every other script derives `config.json`, `secret.dpapi` and `tools/` from `.Home` and no longer
  defaults `-SkillRoot` to the skill folder. **Why:** the old layout lost the whole setup on a re-clone or
  re-install, and broke as soon as a script ran from an output folder.
- **A legacy `config.json` beside `scripts/` keeps working, read-only**, and is reported as
  `LegacyConfig WARN` until `-Fix` migrates it. Migration copies config and secret into the home and
  renames the originals to `*.migrated` — **nothing is deleted** — moves `tools/*`, and rebases a recorded
  `paths.intuneWinAppUtil`.
- **`Set-PsadtConfig.ps1` writes to the resolved home** (creating it on demand) and gained `-Remove` for
  deleting dotted leaves, so a credential switch can clean up `intune.certThumbprint` / `intune.secretRef`
  instead of leaving both behind.
- **`Update-PsadtSkill.ps1`** keeps `-SkillRoot` as the skill *tree* but resolves the config separately
  (tree if it still holds one, else the config home), so the recorded commit is read and written in one place.

### Fixed
- **`New-PsadtEntraApp.ps1` reported the wrong config path** ("Saved to `<skill>\config.json`" plus
  `ConfigPath` in its result object) whenever the config did not actually live in the skill folder. Both now
  come from the resolver.
- **Four config-home tests could not run**: `$script:home` collides with the read-only automatic variable
  `$HOME` (`SessionStateUnauthorizedAccessException`). Renamed to `$script:cfgHome`.
- **`Update-PsadtSkill` tests pin `$env:PSADT_DEPLOY_HOME`** to an empty temp dir, so the machine's real
  config home can no longer leak into a test run.

### Notes
- Test suite: 120 → **128** tests, all green.

## 0.18.1 — 2026-09-03 — Upload: configurable install time limit

### Added
- **`Invoke-IntuneWin32Upload.ps1 -MaxRunTimeMinutes`** — sets `installExperience.maxRunTimeInMinutes`
  (1–1440). `0` (default) omits the field, keeping the Intune service default of 60 minutes and the previous
  request shape unchanged. Raise it for long-running installs (e.g. 240 for an OS in-place upgrade) so the IME
  does not kill them. Eight new tests guard the binding range and the "only when > 0" body shape.

### Notes
- Reconciles a finished change that lived only in the installed working copy back into `main` (same class of
  drift as 0.9.2).

## 0.18.0 — 2026-07-01 — HanseMerkur corporate design + editorial report redesign

### Changed
- **Report/dossier re-themed to the HanseMerkur corporate design** (`references/Report-Template.html`):
  green brand family (`#005E52` / `#00A075`) on a light mint canvas, Metric-Regular/-SemiBold font stack
  (family names only — a locally-installed corporate face is used, else Segoe fallback; **no** web `@font-face`
  fetch, so opening the dossier from a local `file://` no longer triggers CORS console errors).
- **Editorial Data-Report layout.** Flat hairline sections (no drop shadows, 20px radius), oversized
  auto-numbered section headings (CSS counter, `01…13`), an at-a-glance **KPI band** under the hero
  (App-Version · Pre-flight status · Minimum OS · Architecture), and a wider container (1180 → 1600px).
- **Detection script folded away by default.** The rule summary (format, run-as-32bit, signature check) stays
  visible; the full PowerShell detection script now sits behind a collapsed "Detection-Skript anzeigen"
  `<details>` instead of dominating the section.
- **German dossier text uses real umlauts** (`GRÜN`, `für`, `Gerätesoftware`, …). Scripts stay 7-bit ASCII;
  the report carries the umlauts (via UTF-8 / HTML entities).

### Fixed
- **Sticky-header flicker eliminated.** The condensing hero changes height by ~100px; Chrome/Edge
  scroll-anchoring compensated by teleporting `scrollY` across the shrink/grow threshold → an endless
  class-toggle loop that the 30–80px hysteresis could not contain. Added `overflow-anchor: none` (html/body)
  so the collapse is a single smooth shift. Reproduced and verified with Playwright (self-sustained toggles
  at the threshold: 36 → 1).
- **Redundant hero status pill removed.** The verbose multi-line pill overlapped the title / looked cramped;
  the Pre-flight status now lives in the KPI band. The hero keeps only the DE/EN language switch.

### Added
- `New-PsadtReport.ps1` derives a compact KPI pre-flight roll-up (`GRÜN` / `GELB` / `ROT` / `nicht ausgeführt`)
  and exposes it as `KPI_STATUS_DE` / `KPI_STATUS_EN` / `KPI_STATUS_CLS` tokens for the KPI band.

## 0.17.0 — 2026-07-01 — install4j fingerprint + behavioral silent-switch verification

### Added
- **install4j installer fingerprint (Appendix L.1).** Recognise install4j (Java) installers by
  `com/install4j/runtime` / `exe4j` / `i4jparams.conf` / `-Duser.language` strings and a bundled `jre\` in the
  extracted `e4j*.tmp_dir*`. Records that **`/S` is NOT its switch** — passing `/S` shows the language-selection
  dialog and hangs forever; the unattended switch is **`-q`**, and it needs elevation or it stalls. Also sharpened
  the InstallShield fingerprint (`ISSetupStream`, Basic-MSI vs InstallScript).
- **BINDING rule: a single string match is a hint, not proof (Appendix L.1).** Confirm the engine by its
  definitive fingerprint AND **behaviorally verify the silent switch** — run `installer <switch>` once with a
  timeout + window/exit watch (kill on timeout) and confirm exit 0 with no dialog — BEFORE building the package.
- **Trademark-sign gotcha in DisplayName filters (Appendix L.3).** A `(R)`/`(TM)` sign (e.g.
  `Aperio(R) Programming Application`) breaks a literal `-match 'Name'`, so `Uninstall-ADTApplication` /
  `Get-ADTApplication` find nothing and silently no-op; use a tolerant regex (`-match 'Name.*Rest'`).
- **Anti-patterns 13–15 (Appendix B).** Guessing the installer engine from a lone string match without ever
  running it; a trademark sign breaking a DisplayName filter; shipping a driver/cert as a note instead of a
  bundled deliverable (extract the signer `.cer`, import to TrustedPublisher in Pre-Install).

### Changed
- **Appendix L.2 install4j row corrected** (`-q`, elevation, empty QuietUninstallString → append `-q` via
  `-AdditionalArgumentList`, bundled JRE, dpinst driver-cert pre-trust); IzPack split into its own row.

_Driven by real-world friction: an ASSA ABLOY Aperio install4j installer carried a coincidental `nsis` string,
was mistaken for NSIS, and `/S` hung on the language dialog during install._

## 0.16.0 — 2026-06-29 — Dossier stays in sync after script changes + report header layout fix

### Added
- **Dossier auto-sync convention (BINDING).** The "HTML report ALWAYS" convention in `SKILL.md` now states
  that ANY change to the package scripts — launcher, Extensions module, detection script, version/changelog,
  return codes, or a re-packaging — REQUIRES re-checking and regenerating `Intune-Dossier.html` in the same
  pass, on the agent's own initiative, without being asked. A dossier still showing the old version, detection
  logic, hooks, or stale pre-flight/SYSTEM-test results is now classed as a defect; if no dossier exists yet it
  is generated then. (Driven by repeated real-world friction: a fix would land but the dossier went stale.)

### Fixed
- **Report header overlap with longer status text.** In `references/Report-Template.html` the `.pill-lg` status
  badge had `white-space: nowrap` and no `max-width`, so a multi-word status grew leftward as one infinite line
  over the hero subtitle and title (the absolutely-positioned `.hero-status` reserves only a 230px gutter). The
  pill now caps at `max-width: 230px`, wraps (`overflow-wrap: anywhere`, right-aligned, tighter `line-height`),
  and the status dot is pinned to the first line (`align-self`/`margin-top`). Short statuses are unaffected;
  long ones form a compact multi-line badge inside the gutter instead of colliding with the text.

## 0.15.2 — 2026-06-15 — Follow-up: one more stale phase reference

### Fixed (docs)
- A contradiction sweep after 0.15.1 found a residual stale **"Phase 7.5"** in `New-PsadtReport.ps1`
  comment-based help - upload is **Phase 9**. 0.15.1 had only corrected `New-PsadtEntraApp.ps1`. No other live
  stale references remain (verified across all `.ps1`/`.md`; the `exit 1` occurrences left in the guide are
  legitimate prose / the fix-script "couldn't run" guard, not detection paths).

## 0.15.1 — 2026-06-15 — Generator hardening from a self-review (correctness + security)

### Fixed
- **Apostrophe in App name/vendor/author produced an unparseable package.** All three generators now
  single-quote-escape every value embedded in a single-quoted `$adtSession` literal (`AppName`, `AppVendor`,
  `AppVersion`, `AppScriptAuthor`) — so "Bob's App" / "L'Oreal" no longer break the generated script. The MSI
  generator's `-AdditionalArgumentList` and `ProcessesToClose` literals are escaped too (this also closes a
  code-injection path into a script that runs as SYSTEM). The MSI desktop-shortcut path keeps the raw name
  (valid inside a double-quoted string) via a dedicated token.
- **Detection exit-code contract drift.** `New-MsiPackage.ps1` and the WinGet detection example (Appendix I)
  emitted `exit 1` for "not installed"; per the contract (stated in SKILL.md / 8.5 / App. A) that path must be
  `exit 0` + empty stdout (a non-zero exit reads as a detection *error/retry*). Both now `exit 0`. The newer
  Browser/Feature generators were already correct.
- **WSUS-bypass could be left on permanently.** In `New-WindowsFeaturePackage.ps1`, `Set-ADTWindowsUpdateFodAccess`
  now records the prior state of *all* targets before writing any (a partial write is fully reversible), and the
  install/repair hooks call it *inside* the `try` so the `finally` always restores `RepairContentServerSource` /
  `UseWUServer` even if the toggle itself throws.

### Added
- **Pre-flight check 7 (Detection).** `Invoke-PsadtPreflight.ps1` now scans `Detect*.ps1` and WARNs on a
  non-zero `exit` (the "not installed" path should be `exit 0`). WARN-only — does not flip GREEN.
- **Input guards in all three generators:** reject a `$Name` containing path separators or `..` (before the
  `Remove-Item -Recurse` scaffold step), and reject any free-text parameter containing a `__TOKEN__` sequence
  that would corrupt the `.Replace()` templating.
- `New-MsiPackage.ps1` now resolves `$Author` from config when omitted (parity with the other generators) and
  validates `-InstallerPath` exists before scaffolding.

### Fixed (docs)
- Stale `SKILL.md` intro range "Appendix A-M" -> "A-P"; `New-PsadtEntraApp.ps1` "Phase 7.5" -> "Phase 9".

## 0.15.0 — 2026-06-15 — Windows-feature packages (optional features + capabilities / FoD)

### Added
- **`scripts/New-WindowsFeaturePackage.ps1`** — one-call generator for a new opt-in package type: enable
  **Windows Optional Features** (`Enable-WindowsOptionalFeature`, e.g. NetFx3, Hyper-V, WSL, TelnetClient) and
  **Capabilities / Features on Demand** (`Add-WindowsCapability`, e.g. RSAT.*, OpenSSH) — both in one typed list,
  multiple per package. Feature-only (no vendor installer). Writes the launcher (data model + 3 hooks), the
  Extensions module (enable/disable dispatch + WU-FoD access toggle) and the detection script.
- **Guide Appendix P** — model, Phase-2 name/reboot/source research, cmdlet+state reference, generator usage,
  helpers, hooks (3010), detection + Intune wiring, content source (bundled SxS vs Windows Update / WSUS-bypass),
  dossier additions, anti-patterns.
- SKILL.md control-plane: Gate-1 package-type option, Phase-2 research note, anti-patterns, reference-lookup
  line for Appendix P.

### Notes
- **Uninstall reverts** (`Disable-WindowsOptionalFeature` / `Remove-WindowsCapability`); Repair re-enables
  (idempotent). Enable/disable helpers skip features already in the target state.
- **Reboot:** features that report `RestartNeeded` surface **3010** via `$adtSession.SetExitCode(3010)`;
  `-NoRestart` prevents DISM from rebooting mid-install. Detection treats `EnablePending` as not-yet-done.
- **Content source:** bundled `Files\<Source>` via `-Source -LimitAccess` (offline), else Windows Update with a
  **temporary** WSUS bypass (`RepairContentServerSource=2`, `UseWUServer=0`) that records and **restores** the
  exact prior state — reuses the proven pattern from the existing `RSAT-1.0.0` package.
- Verified: generated package passes the Phase-5 pre-flight **GREEN**; enable/disable dispatch + idempotency +
  clean boolean returns and the WU-FoD save/restore (incl. remove-value-that-didn't-exist) validated against an
  in-memory registry sim; generator is 7-bit ASCII-clean.

## 0.14.0 — 2026-06-15 — Browser-extension force-install packages (Edge / Chrome / Firefox)

### Added
- **`scripts/New-BrowserExtensionPackage.ps1`** — one-call generator for a new opt-in package type:
  force-install browser extensions via enterprise **policy registry keys** (no vendor installer, `Files\`
  empty, ESP-safe, no reboot). Each browser then pulls the extension from its own store. Supports **multiple
  extensions per package** across Edge / Chrome / Firefox. Writes the launcher (data model + 3 hooks), the
  Extensions module (4 helpers) and the detection script.
- **Guide Appendix O** — model, Phase-2 store-availability research (per-store IDs: Chrome/Edge 32-char `a-p`,
  Firefox `id@domain` + AMO slug), verbatim registry reference, generator usage, helpers, hooks, the honest
  detection model, dossier additions and anti-patterns.
- SKILL.md control-plane: Gate-1 package-type option, Phase-2 research note, three anti-patterns, reference-
  lookup line for Appendix O.

### Notes
- **Coexistence by design.** The Chromium helper computes the **next free `ExtensionInstallForcelist` index**
  (never hard-codes `1`), dedupes by extension ID, and removes only its own entry — so multiple extension
  packages share the key without clobbering. Firefox merges into the single `ExtensionSettings` JSON keyed by ID.
- **Firefox `REG_MULTI_SZ` trap.** `ExtensionSettings` is written as `REG_MULTI_SZ`; a single-line `REG_SZ` is
  silently ignored by current Firefox (Mozilla bug 1750233).
- Verified: generated package passes the Phase-5 pre-flight **GREEN**; all four helpers validated against a
  scratch registry hive (next-free index, idempotent add, selective remove, `REG_MULTI_SZ` merge incl.
  remove-last cleanup); generator is 7-bit ASCII-clean.

## 0.13.1 — 2026-06-15 — Firewall policy body fixed against the live template (verified 201)

### Fixed
- **`New-IntuneFirewallPolicy.ps1` built a body Graph rejected (400 BadRequest).** Corrected against the live
  "Windows Firewall Rules" template (looked up via the **msgraph skill**, not guessed):
  - the group setting id needs the `{firewallrulename}` token (`vendor_msft_firewall_mdmstore_firewallrules_{firewallrulename}`);
  - the program path is the **direct child** `..._{firewallrulename}_app_filepath` (not a nested `_app` group);
  - action values are numeric: `_action_type_1` = Allow, `_action_type_0` = Block (not `_allow`/`_block`);
  - a template-based settings-catalog policy REQUIRES `settingInstanceTemplateReference` on every instance and
    `settingValueTemplateReference` on each simple/choice value; the profiles **collection** takes the instance
    ref only (a per-value ref is rejected as a duplicate). All template GUIDs are embedded.
  Confirmed by a live **201 Create** against the tenant; the generated body is byte-identical to the accepted one.
- Mirrored the same correct body into the MxManagementCenter self-contained Output deliverable.
- `tests/New-IntuneFirewallPolicy.Tests.ps1` now asserts the template references and the verified option values.

## 0.13.0 — 2026-06-15 — Self-contained firewall deliverable (copy-to-client safe)

### Changed
- **`scripts/New-IntuneFirewallPolicy.ps1` is now fully SELF-CONTAINED** — no dot-sourcing of
  `_GraphCommon` / `_GraphInteractive`, no skill path; the WAM interactive sign-in, the policy body builder
  and console helpers are embedded in the one file. It is copied into an app's Output folder and runs on test
  clients that do NOT have the skill installed (`-Interactive` WAM, or a passed `-GraphToken`). This fixes the
  "Skill script not found … Pass the correct -SkillRoot" failure when the deliverable was run on another machine.

### Added
- **SKILL.md binding convention "Self-contained deliverables"** — anything shipped in an app's Output folder
  must carry everything it needs (no dot-source of skill files, no hardcoded skill/user path, no `-SkillRoot`).
- **`tests/New-IntuneFirewallPolicy.Tests.ps1`** self-containment assertions (no dot-source, no skill path,
  embeds its own WAM) — enforces the convention. Authored test-first (RED->GREEN) per superpowers:writing-skills.

## 0.12.0 — 2026-06-15 — Interactive WAM sign-in for the Intune policy scripts

### Added
- **`-Interactive` (+ `-TenantId`) on `New-IntuneFirewallPolicy.ps1` and `New-IntuneTrustedCertPolicy.ps1`** —
  delegated sign-in via **WAM** (Windows Web Account Manager) so the scripts run with **no app registration**
  (maximum compatibility). No device code. Default path is still app-only via `Get-GraphToken.ps1`; the 403
  hint now also points at `-Interactive`.
- **`scripts/_GraphInteractive.ps1`** — shared WAM sign-in helper (`Initialize-MsalBroker` / `Get-WamToken` /
  `Get-InteractiveGraphToken` + the pinned MSAL version set), dot-sourced after `_GraphCommon.ps1`.

### Changed
- **`New-PsadtEntraApp.ps1`** refactored to consume `_GraphInteractive.ps1` instead of its own inline WAM copy
  (one implementation, no copy-paste drift — the concern called out in `_GraphCommon.ps1`). Behaviour unchanged
  (WAM, device-code fallback retained in the bootstrap only).
- **MxManagementCenter `New-MxMcFirewallPolicy.ps1` deliverable** is now a thin wrapper over
  `New-IntuneFirewallPolicy.ps1` (DRY; inherits `-Interactive` automatically).
- New `-Interactive` dry-run test case in `tests/New-IntuneFirewallPolicy.Tests.ps1`.

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

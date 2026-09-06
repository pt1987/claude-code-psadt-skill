---
name: psadt-deploy
description: Use when the user wants to build, package, test, troubleshoot, or deploy a PSADT v4.x Intune Win32 app. Triggers - "PSADT paket bauen", "intune paket fuer <app>", "<app> via intune paketieren", "PSADT v4 deploy", "PSADT troubleshooting", "Invoke-AppDeployToolkit.ps1 debug", "IntuneWinAppUtil", "update skill" / "psadt update", "psadt setup" / "psadt doctor" / "psadt einrichten", or when working in a folder with Invoke-AppDeployToolkit.ps1/.exe or a PSAppDeployToolkit module.
---

# PSADT v4.x Deployment Skill

Drive a PSADT v4.x Intune Win32 package end-to-end. Depth lives in
`references/PSADTv4-Deployment-Guide.md` (Phases 0-12 + Appendix A-P) and in each script's comment-based
help. Keep THIS file as the control plane; load guide sections on demand instead of inlining them.

## Operating mode (autonomy first)

1. **Research before you ask.** Anything researchable - latest version, installer type, silent/uninstall/
   repair switches, ProductCode, known Intune issues - is resolved by the Phase 2 research fan-out, never
   by a question.
2. **State founded assumptions, then proceed.** Emit one short `Assumptions:` status line (plain text is
   allowed for status / intermediate results) and keep working. Do not wait for confirmation on researched facts.
3. **Ask only at the 4 decision gates** (below), always via `AskUserQuestion` - clickable options,
   recommended option first with the suffix "(recommended)"; the tool adds "Other" automatically. Never ask
   as free text. Offer researched values as pre-selected options so the user just confirms or corrects.
4. **Blockade protocol.** On any error, API limit, or dead-end, never dump a raw error and never give up.
   Isolate the problem and emit exactly:
   `PROBLEM: <one line>. TRIED: <what>. OPTIONS: 1) <action> 2) <action>.`
   Then take option 1 if it is safe and reversible; otherwise hand the exact command back to the user.

Do not assume Adobe/Oracle (or any vendor) as a default - the app always comes from the user; guide examples
are illustration only. Never pass `-SkillRoot` to a script and never build a path from the skill folder -
every script resolves the config home itself (see Conventions).

## Sub-agent architecture (roles + handoffs)

You are the **Orchestrator**: you own config, the binding conventions, and the decision gates. Delegate
independent work; never let a gate be crossed without its handoff.

| Role | Run as | Owns | Handoff (gate) |
|---|---|---|---|
| **Researcher x3** | parallel agents (prefer `superpowers:dispatching-parallel-agents` if installed; else fan out directly with the Agent tool) | (a) PSADT version + command-change check, (b) app silent/uninstall/repair switches, (c) Intune pitfalls | structured findings table, shown before scaffold |
| **Builder** | inline (you) | scaffold + fill all 3 hooks + Extensions module | a package that passes pre-flight |
| **Reviewer/QA** | agent (prefer `superpowers:requesting-code-review` if installed; else a direct review agent / `/code-review`) | pre-flight verdict, SYSTEM-test diagnosis, report + logo sanity | GREEN gate, or a blockade report |

**Hard handoff rules:** Builder may not package until Reviewer returns GREEN on pre-flight. Upload (Phase 9) may
not run until Reviewer returns GREEN on the SYSTEM test (Install + Uninstall). Researchers run concurrently
and return before scaffold. The `superpowers:*` skills above are an OPTIONAL methodology layer: if that plugin
is not installed, fan out / review with the native Agent tool (and `/code-review`) - the workflow never depends on it.

## Decision gates (the ONLY AskUserQuestion moments)

Everything else is a researched assumption. Bundle questions (max 4 per call); pre-fill every option with
researched defaults; recommended option first.

1. **Scope confirm** - app + exact version, installer type, source strategy (local / bundle into package /
   download at runtime). WinGet is strictly opt-in here: default to the native installer, never recommend or
   auto-select WinGet even if a package exists. If WinGet is chosen, follow guide Appendix I. **Package type**
   is part of this gate when ambiguous: native installer (default) · WinGet (opt-in, App. I) · script-only
   fix/remediation (App. K) · **browser-extension force-install** (Edge/Chrome/Firefox via policy keys, App. O,
   built by `scripts/New-BrowserExtensionPackage.ps1`) · **windows-features** (Enable-WindowsOptionalFeature /
   Add-WindowsCapability, App. P, built by `scripts/New-WindowsFeaturePackage.ps1`) · **driver** (pnputil
   staging, App. Q, built by `scripts/New-DriverPackage.ps1` - classify FIRST with
   `Get-DriverSignatureInfo.ps1`; unsigned = no package).
2. **Deployment semantics** - target audience (Required / Available / both, + AAD groups), uninstall "what
   goes vs. what stays", repair strategy, reboot behaviour (never / 3010 / 1641). Pre-select defaults from
   the installer type. Group assignment is **opt-in**: only when the user wants it here do you create/assign
   Entra groups (Phase 10, config `intune.groups`, guide Appendix M); the default is upload-without-assignment.
3. **SYSTEM-test consent** - it installs the real software as SYSTEM. Offer the Windows Sandbox route
   FIRST (`Invoke-PsadtSandboxTest.ps1`: whole loop, ~6 min, host untouched, no elevation) and the DEV-VM
   route second; only the second one needs a snapshot. "Skip the test" is NOT an option to offer while
   `decisions.upload = true`, and a package whose Uninstall was never run is not a finished package.
4. **Upload confirm** - show the dry-run summary + the exact `On -Execute` action; confirm before `-Execute`.

Context follow-ups (coexistence, processes-to-close, architecture) come situationally, also via
`AskUserQuestion`. Full 30-question intake catalogue and per-question option sets: guide Phase 1.2.

## Conventions (BINDING - never skip, never reorder priorities)

- **Language split.** Two rules, never mixed.
  - **Scripts** (`Invoke-AppDeployToolkit.ps1`, Extensions, Detection) = **English, 7-bit ASCII only** -
    comments AND strings, so no umlaut/non-ASCII ever lands in a `.ps1` (encoding cleanliness; see Phase 5).
  - **Dossier/report** = **`language.dossier`, default German with REAL umlauts** (ä ö ü ß - Company-Portal
    end-user text; do NOT spell out ae/oe/ue). The umlauts come from the description metadata; the template
    stays ASCII via HTML entities and the file is written UTF-8. The Company-Portal app description block =
    **Markdown** (that field is Markdown-only, not HTML).
- **Config home.** `config.json`, `secret.dpapi` and `tools/` live in `%LOCALAPPDATA%\psadt-deploy\`
  (override: `$env:PSADT_DEPLOY_HOME`), NEVER in the skill folder - they must survive a re-clone, an update
  and a re-install. `Get-PsadtConfig.ps1` is the only resolver; take paths from its `.Home` / `.Path`. A
  pre-0.19 config beside `scripts/` still works read-only (`.LegacyInUse`) - offer `-Fix` to migrate it.
- **Manifest = single source of truth per app.** `<pkg>\psadt-package.json` (schema 1) holds identity, gate
  decisions, research findings, every phase `results.*` and the `artifacts.*`. Generators write it; a
  hand-scaffolded package gets it IMMEDIATELY via `Set-PsadtPackageManifest.ps1`. Never re-derive or retype
  what it already says, and never let a `$meta` argument disagree with it. Pre-flight FAILs without it.
- **Output location.** `.intunewin` ALWAYS to `<paths.outputRoot>\<Stem>\<Stem>.intunewin` where `Stem` =
  `<Vendor>_<App>_<Version>_<Arch>` from the manifest (spaces -> `_`, only `[A-Za-z0-9._-]`). Produced ONLY
  by `Invoke-PsadtPackage.ps1` - never a hand-typed tool call, never the generic
  `Invoke-AppDeployToolkit.intunewin`. Detection script + `Intune-Dossier.html` live in that same folder.
  Never a `_IntuneOutput` folder beside the package; never `-o` inside `-c`. Existing folders with the old
  `<App[-Version]>` scheme stay as they are - nothing is renamed retroactively.
- **Logging: ONE log per run.** Location stays `C:\Windows\Logs\Software\` (IME-readable) - never redirect.
  But the launcher MUST set `LogName` in `$adtSession` to
  `<Vendor>_<App>_<Version>_<Arch>_<DeploymentType>_<yyyyMMdd-HHmmss>.log`: PSADT's default is a fixed name
  with `LogAppend`, so otherwise every run of every version piles into one unreadable file. Generators do
  this; a hand-scaffolded launcher must too (pre-flight WARNs). Keep each Phase-6 log for audit
  (`artifacts.logs[]`).
- **Author / version / changelog.** `AppScriptAuthor` in `$adtSession` = `author.person, author.company`
  (config, no hard-coded author). First script version ALWAYS `0.1` (not 1.0.0); substantive changes bump it,
  cosmetic edits need not. Mandatory changelog in the `.NOTES` header, one line per version:
  `- <ver> (YYYY-MM-DD, <author.person>): <change>`; bump `AppScriptVersion` + changelog together.
- **HTML report ALWAYS** (upload or not - never skipped, "no upload" is not a reason to skip it). Produce
  `Intune-Dossier.html` from the fixed template `references/Report-Template.html` via
  `scripts/New-PsadtReport.ps1` - never hand-assemble the HTML. One self-contained, bilingual (DE/EN toggle,
  browser-translatable) document = Intune dossier (App Info, Markdown description, Program, return codes incl.
  60001/60008=Failed, Requirements, Detection, Dependencies, Supersedence, Assignments) + technical package
  report (the 3 hooks, PSADT cmdlets used, pre-flight + SYSTEM-test results, logo + `.intunewin` verification).
  **Dossier stays in sync (BINDING, no reminder needed).** ANY change to the package scripts - launcher
  (`Invoke-AppDeployToolkit.ps1`), Extensions module, the detection script, version/changelog, return codes,
  or re-packaging - REQUIRES re-checking and regenerating `Intune-Dossier.html` in the SAME pass, on your own
  initiative. Never wait to be asked. A script edit whose dossier still shows the old version, old detection
  logic, old hooks, or stale pre-flight/SYSTEM-test results is a defect. If no dossier exists yet for the app,
  generate it now via `scripts/New-PsadtReport.ps1` (still never hand-assembled). After every fix-and-repackage,
  the closing step is: regenerate the dossier, then state what changed in it.
- **Real logo only.** Download the REAL app logo (PNG, transparent, >=512px, square preferred) → `Assets\` +
  `Output\<App>\`. NEVER the PSADT default `AppIcon.png`/Banner (the upload script blocks them by SHA256).
  Verify real corner-pixel alpha AND look at the image. Sources + MSI-icon fallback + verification: guide
  Appendix J. (The logo is uploaded separately to Intune's App-information tab; it is NOT in the `.intunewin`.)
- **Shortcuts.** Start Menu only (`$envCommonStartMenuPrograms`). No desktop icons; remove any the installer
  creates, and clean up the Start Menu entry on uninstall.
- **Intune access is state-driven, never trial-and-error.** Before Phase 9 / 10 / any cert-or-firewall policy
  read the state instead of provoking a 403: `Get-PsadtConfig.IntuneState` + `pwsh
  scripts/Test-PsadtIntuneAccess.ps1` → `Capabilities.Upload|Groups|Configuration`, three-valued (`$null` =
  **unknown**, NOT `$false`). Missing → offer the exact fix from `.Hints`, never silently retry. Auth is the
  DPAPI secret OR a cert (`-UseCertificate -CertThumbprint`; `intune.certThumbprint` beats `secretRef`) - and
  DPAPI dies with the Windows profile, so a re-installed OS invalidates a stored secret. Roles + matrix:
  `references/app-registration.md`.
- **Certificates into a machine store** (driver-trust / `TrustedPublisher`, Root/CA, `TrustedPeople`). Whenever a
  cert must land in a store - the #1 case is an installer that stages a **3rd-party driver**, whose Windows
  "install device software?" prompt blocks a SYSTEM-silent install - treat it as a first-class deliverable:
  extract the signer cert, make **single-line base64** (line breaks/PEM -> CSP error `0x87d1fde8`), build the
  OMA-URI `./Device/Vendor/MSFT/RootCATrustedCertificates/<Store>/<SHA1>/EncodedCertificate`. **TrustedPublisher /
  TrustedPeople need that CSP via a Custom OMA-URI profile** - the built-in "Trusted certificate" template
  only does Root/Intermediate (never claim Intune "can't" do TrustedPublisher).
  Own the cert in **exactly ONE place** - the **Intune policy** (`scripts/New-IntuneTrustedCertPolicy.ps1`,
  dry-run/`-Execute`; it names a missing role before writing and prints the manual portal steps) **OR** a
  package import in the install hook - never both (they fight on uninstall/sync). Assign the policy to the
  SAME scope as the app. Guide Appendix N.
- **Self-contained deliverables (BINDING).** Any helper script placed in an app's **Output folder** (the
  firewall-policy creator, a cert-policy creator, etc.) is COPIED to and run on **test clients that do NOT have
  the skill installed**. It therefore MUST be fully self-contained: **no** dot-sourcing of skill files
  (`_GraphCommon` / `_GraphInteractive`), **no** hardcoded skill/user path, **no** `-SkillRoot` dependency -
  everything it needs (WAM interactive sign-in, body builders, console helpers) is embedded in the one file.
  Auth on a client = `-Interactive` (WAM, no device code) or a passed `-GraphToken`. A wrapper that dot-sources
  or hard-codes the author's skill path is a defect (it throws "Skill script not found" on any other machine).
  Reference implementation: `scripts/New-IntuneFirewallPolicy.ps1` (the self-containment is enforced by
  `tests/New-IntuneFirewallPolicy.Tests.ps1`). Skill-internal scripts that only ever run on the authoring
  machine may still share `_Graph*` helpers - the rule applies to what ships in Output.
- **All three deployment types from the start** (Install / Uninstall / Repair), each acid-tested - even if
  only install is needed today, Company-Portal uninstall needs a filled Uninstall hook.
- **Upload (opt-in).** Fill EVERY objective App-info field; NEVER auto-impose category / branded notes /
  featured; NEVER DELETE an older version (new versions coexist via `-OnExisting CreateNewCoexist`; the user
  wires supersedence). Group assignment is opt-in too: NEVER auto-assign a group unless the user chose it at
  Gate 2 AND `intune.groups.enabled` - then create/assign via the configured naming scheme (Phase 10 / App. M).
- **Test before upload (gate).** Install + Uninstall must pass the Phase 6 SYSTEM test before any upload.
  Can't run it (no elevation / VM)? STOP before `-Execute` and hand back the exact command. Never upload
  untested.

## Self-update

On user request ("update skill" / "psadt update" / "/update-skill"); at Phase 0 the doctor already reports it
as its `SkillUpdate` check (quiet, non-blocking). `pwsh scripts/Update-PsadtSkill.ps1` is read-only and
commit-based (`HEAD` vs `origin/<branch>`, or the commits-API sha vs the recorded `tooling.skillCommit`; the
CHANGELOG version is context only). If `UpdateAvailable`, show `LocalVersion -> RemoteVersion` + `Behind` +
`WhatsNew`, then ask via `AskUserQuestion`. Only on confirm: `-Apply` (git pull --ff-only for a clone, else
branch-zip overwrite of tracked files only - never config/secret/tools/docs). Never auto-apply. Offline →
say so and continue; an update check must never block packaging.

## Workflow

**Phase 0 - Setup (doctor).** `pwsh scripts/Initialize-PsadtSkill.ps1 -Fix` (idempotent; `-Fix` migrates a
legacy config home, installs the modules/tool and fills the EN/DE + tool-path defaults). GREEN/YELLOW -> intake.
RED -> ask ONLY for `.Missing` via `AskUserQuestion` (current values as defaults), persist with `-Set @{...}`,
re-run. Then act on the remaining WARN lines - each carries its own `.Fix`. WinGet also needs
`Get-WinGetModule.ps1`; optional upload bootstrap `New-PsadtEntraApp.ps1` - both in guide Phase 0.

**Phase 1 - Intake.** A PSADT v4 package always serves all three deployment types - plan them now, not at the
end. Resolve scope via decision gates 1 + 2 only; pre-fill every option from research. Catalogue: guide Phase 1.2.

**Phase 2 - Research fan-out (parallel sub-agents, no asking back).** Dispatch the three Researcher roles
concurrently, collect into the Phase-0.3 findings table, and show it before scaffold. Record per deployment
type: switch, expected exit codes, log path, known leftovers. **For an MSI, the probe IS the research: `pwsh scripts/Get-PsadtMsiFacts.ps1 -Path <msi> -AsText`** returns
identity, signature, SHA256, features + component counts, decoded upgrade flags, shortcuts, directories,
file versions, registry rows and the Icon table in ONE call. Read it before web-searching anything: it is
what reveals an auto-updater sitting in its own feature (so `ADDLOCAL` beats post-install cleanup), a
`DesktopFeature` you must not install, `MigrateFeatures` on the upgrade row (so `ADDLOCAL` alone is not
enough), and the exact file version for the detection script. Never hand-roll this probe - guide App. G
(2026-09-05) records the four COM/pipeline traps it costs.
**Consult guide Appendix L (installer technologies
+ silent switches) BEFORE web-searching switches**; for a script-only fix/remediation/debloat package (no vendor
installer) follow guide Appendix K instead of the normal installer flow. For a **browser-extension** package the
research is store-availability + per-store IDs (Chrome/Edge 32-char `a-p`, Firefox `id@domain` + AMO slug), not
silent switches - guide Appendix O.2. For a **windows-features** package the research is the exact
`FeatureName`/capability `Name` (via `Get-WindowsOptionalFeature -Online` / `Get-WindowsCapability -Online -Name`)
plus reboot + content-source need (bundled SxS vs Windows Update) - guide Appendix P.2. On a newer PSADT release, ALWAYS diff the
release notes for renamed/deprecated/changed commands before building - never adopt a version by number alone;
verify the actually-used cmdlets with `Get-Command -Module PSAppDeployToolkit` (and `Get-Help <cmdlet>
-Parameter *` for changed params). If divergent, recommend `Update-Module PSAppDeployToolkit -Force` before
scaffold. Queries + version-sync check: guide Phase 1.1 + 1.3, Appendix D. WinGet package discovery (search
by name first; `Find-ADTWinGetPackage`): guide Appendix I.1.

**Phase 3 - Scaffold.** **A generator is the default route** - it writes the launcher, the detection script,
the per-run `LogName` AND the manifest in one go: MSI → `New-MsiPackage.ps1`, browser extension →
`New-BrowserExtensionPackage.ps1`, Windows features → `New-WindowsFeaturePackage.ps1`. Only when none fits:
`New-ADTTemplate -Destination <root> -Name <App>` (4.1.x takes only `-Destination/-Name/-Version/-Force/
-Show/-PassThru` - NO app metadata), then fill `$adtSession` (AppVendor/Name/Version/Arch/Lang/Revision,
success + reboot exit codes, `AppScriptVersion='0.1'`, `AppScriptAuthor` from config, **`LogName` per run**)
plus the `.NOTES` changelog, and write the manifest immediately (`Set-PsadtPackageManifest.ps1`). Verify the
module version == `DeployAppScriptVersion`. WinGet: provision the extension module into the package,
`Files\` stays empty, `AppVersion='Latest'` (or pinned) (guide Appendix I.2). Field details: guide Phase 3.

**Phase 4 - Customize all three hooks.** User drops the installer in `<pkg>\Files\`; fill
`Install/Uninstall/Repair-ADTDeployment` from the research. Per-installer patterns
(MSI/EXE/InstallShield/Squirrel), `Show-ADTInstallationWelcome -CloseProcesses ... -CheckDiskSpace` before
install, Start-Menu-only shortcuts, uninstall cleanup (tasks/services/firewall/registry - only the APP
sub-key, NEVER the vendor root; keep user data by default), and async-retry loops (services need 30-60s after
msiexec): guide Phase 4. WinGet hook patterns: guide Appendix I.3. The GUID-to-`-ProductCode` rule (a GUID to
`-FilePath` throws `InvalidFilePathParameterValue` → 60001) applies to Uninstall AND Repair - Repair is the
usual miss. Custom helpers ALWAYS in `PSAppDeployToolkit.Extensions.psm1`, never the main script. If the installer
**stages a 3rd-party driver** (the Windows device-software prompt blocks a SYSTEM-silent install), classify it
FIRST: `pwsh scripts/Get-DriverSignatureInfo.ps1 -Path <extracted installer content>`. MicrosoftSigned →
pre-stage with pnputil in Pre-Install, then run the installer. VendorSigned → certificate deliverable now,
prefer the Intune policy (`scripts/New-IntuneTrustedCertPolicy.ps1`) over an in-package import, then
pre-stage. Unsigned → STOP, there is no packaging trick. Kernel-mode + vendor signature is RED, not a
warning: TrustedPublisher silences the prompt but never satisfies Code Integrity. Tree: guide Appendix Q.

**Phase 5 - Pre-flight (Reviewer gate).** Run `scripts/Invoke-PsadtPreflight.ps1 -PackagePath <pkg>` - it returns
`{ Overall='GREEN'|'RED'; Checks=@(...) }` and runs all gate checks deterministically: encoding (`HasBOM=True` OR
non-ASCII `Count=0`), AST parse, v3-cmdlet scan (launcher + Extensions only - bundled `Files\*.ps1` are
parse/encoding-only, so a private `Write-Log` there is NOT flagged), top-level-statement scan, the structural
acid-test (all three `*-ADTDeployment` hooks defined + Extensions helpers actually called), and the
GUID-to-`-FilePath` anti-pattern. **`Overall` must be GREEN to proceed** (any RED = STOP, even if Install looks
fine - else Company-Portal uninstall returns 0x80070001). Encoding fix (em-dash/smart-quote replace + UTF-8 BOM)
and per-check explanations: guide Phase 5 (5.1-5.6) + Appendix C. WinGet adds a module-present check and MUST use
the acid-test stub (a live acid test would install): guide Appendix I.4.

**Phase 6 - SYSTEM test loop.** **BINDING before any upload; skippable ONLY when no upload is planned** -
and that decision is recorded as `decisions.upload` in the manifest, which is what the dossier enforces
(the report throws on a missing SYSTEM test when `decisions.upload = true`). Each run appends to
`results.systemTest[]` + `artifacts.logs[]`.

**Default route: `pwsh scripts/Invoke-PsadtSandboxTest.ps1 -PackagePath <pkg>`.** It runs the WHOLE loop -
Install, detection, Uninstall, detection, Reinstall, Repair, final Uninstall - inside one throwaway Windows
Sandbox, every action as SYSTEM via a scheduled task, and returns `{ Verdict, Steps, FailedAssertions,
Assertions, ResultPath, LogFolder }`. It needs **no elevation on the host**, never touches the host, and
gives every action a machine that has never seen the app. ~6 minutes end to end. The verdict is keyed on
the DETECTION SCRIPT (what Intune actually evaluates); package-specific facts go in as
`-PathsPresentAfterInstall` / `-PathsAbsentAfterInstall` / `-PathsAbsentAfterUninstall`. Requires the
optional feature `Containers-DisposableClientVM` (the script prints the one-time enable command, which does
need elevation + a restart). Not usable when the app needs domain join, a real TPM, GPU acceleration or
hardware the VM lacks - fall back to the per-action route below.

**Never hand-roll this harness.** Running deployment actions as SYSTEM and reading their exit codes back
looks like ten lines of `schtasks` and is not: see guide Appendix G (2026-09-05) for three bugs that each
silently burned a full VM run. `tests/Invoke-PsadtSandboxTest.Tests.ps1` guards all three.

**Per-action route (DEV VM, or when the sandbox cannot host the app).** `Invoke-PsadtSystemTest.ps1` runs ONE action as SYSTEM and
returns `{ DeploymentType, ExitCode, Success, DetectionState, LogPath, LogTail, ErrorLines, Elevated }`; it
fixes nothing - YOU drive the loop, hard cap 5 iterations (you own the count). Needs an ELEVATED session +
WinPS 5.1 and belongs on a DEV VM (Gate 3 consent + snapshot first). Loop: Install → verify detection →
Uninstall → verify clean (services, tasks, reg key, install dir, firewall; neighbour products of the same
vendor stay) → Reinstall. Converged → leave the machine uninstalled. Cap reached or no elevation → blockade
protocol, STOP before any upload. Prerequisites + diagnosis: guide Phase 6 / Appendix A / G.

**Phase 7 - Package.** `pwsh scripts/Invoke-PsadtPackage.ps1 -PackagePath <pkg>` - one command, never a
hand-typed `IntuneWinAppUtil` line. It derives the name from the manifest, packs via a private temp `-o`,
verifies the archive (Detection.xml / SetupFile / size / SHA256), renames to
`<outputRoot>\<Stem>\<Stem>.intunewin`, copies detection script + logo alongside and records
`artifacts.*` + `results.package`. It refuses an output folder inside the package and warns about (never
deletes) foreign `.intunewin` files. Extractability check: guide Phase 7.

**Phase 8 - HTML report (ALWAYS) + real logo.** `New-PsadtReport.ps1 -ManifestPath <pkg>\psadt-package.json
-LogoPath <logo> -OutputPath <artifacts.outputFolder>\Intune-Dossier.html`; `-Metadata` still overrides any
key (list: guide Appendix F.0).
Return codes come from `scripts/Get-PsadtReturnCodes.ps1` - the SINGLE source of truth the upload reads too.
Intune accepts exactly `success`, `softReboot`, `hardReboot`, `retry`, `failed`; **there is no "Ignored"**, and an
invalid type THROWS rather than rendering. Pass only the INSTALLER-SPECIFIC codes as
`@{ Code; Type; De; En }` - they merge over the mandatory `0, 1707, 3010, 1641, 1618, 60001, 60008` table, never
replace it. Record them once as `research.returnCodes` in the manifest and dossier + upload both pick them up. App description = Markdown, dossier language, real umlauts (structure/template:
guide F.2). Logo fetch + verify + MSI-icon fallback: guide Appendix J. WinGet dossier additions
(WinGet >= 1.7.10582 requirement, registry/file detection note): guide Appendix I.6.

**Phase 9 - Direct Graph upload (opt-in).** Gate 4. ALWAYS dry-run first (read-only) → show summary +
`On -Execute` action → confirm → `-Execute`. `Invoke-IntuneWin32Upload.ps1 -ManifestPath <pkg>\psadt-package.json`
(identity from the manifest, `results.upload` written back; via `Get-GraphToken.ps1`; asserts the upload role first): MSI →
`-MsiProductCode '{GUID}'`; EXE/non-MSI → `-DetectionScriptPath` (a detection rule accepts only
`ruleType, enforceSignatureCheck, runAs32Bit, scriptContent`; the detect script writes stdout + `exit 0` when
installed, nothing when not). Fill every objective field; impose no category/notes/featured (group assignment
is the separate opt-in Phase 10); never DELETE (`-OnExisting CreateNewCoexist`, `-UpdateAppId` only for
explicit in-place, optional `-SupersedesAppId` = supersedence only, NOT dependencies). `-MinWindowsRelease`
takes backend IDs `1607..2004` only. The script refuses the PSADT default logo unless `-AllowDefaultLogo`.
Uses `/beta`. Details + Graph gotchas: guide Phase 9 / Appendix H.

**Phase 10 - Group assignment (opt-in).** Only when the user chose it at Gate 2 AND `intune.groups.enabled`.
ALWAYS dry-run first (read-only) → show the planned group names + actions → confirm → `-Execute`.
`Invoke-IntuneAppAssignment.ps1 -AppId <id> -AppName ... -AppVendor ... -AppVersion ... -Intents required,available`
(comma-separated is fine: array parameters in this skill split the list themselves, because `pwsh
script.ps1 -Intents a,b` uses the `-File` binder, which passes `a,b` as ONE element - guide App. M.4)
creates/reuses Entra security groups by the config naming scheme (`intune.groups.naming`, version-INDEPENDENT by
default so a new version reuses the same groups; `%version%` is an opt-in that breaks that) and assigns the app
(intents required/available/uninstall). Idempotent; never deletes a group or another app's assignment;
ambiguous/duplicate names are skipped, not guessed. Needs `Capabilities.Groups` (BOTH group roles - the
script asserts them before creating anything). Feed the returned `Groups` into the dossier Assignments
table. Full schema + naming rules + permission model: guide Appendix M.

**Phase 11 - Test sequence (DEV VM, all three types).** Install (ps1 → exe → SYSTEM via
`Invoke-PsadtSystemTest.ps1`, PsExec fallback) → Uninstall on the SAME VM + post-uninstall verification
(detection empty, services/tasks/firewall gone, install dir gone, vendor neighbours intact) → Repair after a
reinstall. Then an Intune test group (1 device, Required; check the PSADT log + AppWorkload.log for `Installed`
/ `Uninstalled` and `Close-ADTSession` exit 0). Steps + checks: guide Phase 11 / Appendix E.

**Phase 12 - Rollout.** All three green → pilot 24-48h → staged production. **Rollback** = re-point the
assignment (and supersedence) at the retained prior version - it was never deleted (`CreateNewCoexist`).
Guide Phase 12.

## Troubleshooting quick reference

HRESULT: Intune shows positive exit codes as `0x80070000 + code` (`0x80070001` = exit 1 = script never ran;
ignore the "ERROR_INVALID_FUNCTION" text, recompute). Logs in order: AppWorkload.log → PSADT session log →
IntuneManagementExtension.log.

| Symptom | Primary suspect | Fix / verify |
|---|---|---|
| `0x80070001`, no PSADT logs | encoding (em-dash) or top-level throw | Phase 5 checks; guide A.2 |
| `0x8000EA68` (60008), empty PSADT log | Import-Module / Open-ADTSession throws | guide A.2 |
| `0x8000EA61` (60001) + stacktrace | runtime error in the Install hook | stack shows the line |
| `60001 InvalidFilePathParameterValue` on Uninstall/Repair | GUID passed to `-FilePath` | use `-ProductCode '{GUID}'`; guide G |
| App stuck on "Installing" in Company Portal | IME state cache / process hang | guide A.2 cleanup sequence |
| `0x80070002` | launcher cannot find the .ps1 | `-s` during packaging was wrong |
| `0x80070643` (1603) MSI fatal error | perms / disk / **pending reboot** / bad property / failed custom action | clear pending reboot, read the `/l*v` MSI log; guide A.4 |
| `0x80070666` (1638) "another version installed" | older ProductCode still present | uninstall old first, or ship a real upgrade; guide A.4 |
| exit 1605 on uninstall | product already gone | treat as success (map 1605); guide A.4 |
| detection failed after a successful install | detection-script bug (contract / 32-64-bit reg) | run `.\Detect-*.ps1; $LASTEXITCODE` on target |
| SYSTEM test: every step `ExitCode=0 Success=False` | ran under pwsh 7 (PSScheduledJob is WinPS-5.1-only) | re-run under powershell.exe 5.1; guide G |
| upload `must have at least one detection rule` (rule WAS sent) | needs the unified `rules`, `@odata.type` first | `[ordered]@{}`; guide H |
| upload `commitFileFailed` after blocks "OK" | `Invoke-RestMethod -Body <byte[]>` corrupts the blob | HttpClient/ByteArrayContent; guide H |
| `displayVersion` empty after upload | v1.0 backend drops it | write on `/beta`; guide H |
| upload `403` on probe/create | app consent missing/ineffective | `Test-PsadtIntuneAccess.ps1` for the exact gap, then `New-PsadtEntraApp.ps1` |
| token `AADSTS7000222` / secret "cannot be decrypted" | secret expired / DPAPI bound to a re-installed profile | `New-PsadtEntraApp.ps1` stores a fresh secret |
| detection rule rejected (`property may not be set ... used for app detection`) | requirement-only props on a detection rule | keep only `ruleType,enforceSignatureCheck,runAs32Bit,scriptContent`; guide H.2 |
| upload `BadRequest: Unknown MinimumSupportedWindowsRelease` | `-MinWindowsRelease` value the backend rejects (e.g. `21H2`/`22H2`) | use a backend-accepted ID `1607..2004`; set a higher min in the portal; guide H.11 |
| assignment `Group assignment is not enabled` | `intune.groups` absent/`enabled=false` in the resolved config | configure `intune.groups` (App. M); run `Initialize-PsadtSkill.ps1` to see WHICH config was resolved |
| assignment denied on group lookup/create (`Authorization`) | upload app lacks `GroupMember.Read.All` / `Group.Create` | `New-PsadtEntraApp.ps1 -IncludeGroupManagement` (Global Admin); guide M.1 |

Full symptom/HRESULT catalogue: guide Appendix A.

## Anti-patterns (TOP offenders only; FULL list: guide Appendix B + I.7 + K.7)

- v3 cmdlet names (`Execute-Process`, `Write-Log`, `Show-InstallationWelcome`, ...); any em-dash/smart-quote or
  other non-ASCII in a `.ps1` (comments too) without a UTF-8 BOM - the #1 encoding failure. Top-level code outside try/catch.
- GUID to `Start-ADTMsiProcess -FilePath` (Uninstall AND Repair - Repair is the usual miss) -> 60001.
- Drivers: enabling `testsigning`/`nointegritychecks` (never - it weakens the whole device for one app);
  selling `TrustedPublisher` as the fix for an UNSIGNED driver or for a kernel driver under Secure Boot;
  deleting `oemNN.inf` by an index from another machine; trusting a collective multi-INF pnputil exit code.
- `-o` inside `-c`; not mapping 60001/60008 as Failed; "runs locally = runs in Intune" without the acid test;
  hand-rolling the pre-flight instead of `scripts/Invoke-PsadtPreflight.ps1` (its GREEN/RED verdict IS the gate).
- Shipping the PSADT default `AppIcon.png`/Banner as the logo; skipping or hand-assembling the HTML report.
- Auto-imposing user/org choices on upload (category/featured/`notes`), or assigning groups when the user did
  NOT opt in at Gate 2; DELETING the older version instead of `-OnExisting CreateNewCoexist`.
- Hand-rolling the SYSTEM-test harness instead of `scripts/Invoke-PsadtSandboxTest.ps1` (App. G, 2026-09-05:
  `echo %ERRORLEVEL%>file` silently becomes the `0>` stdin redirection and writes an EMPTY file; file
  existence read as completion; `[string]$null` still `$null` in WinPS 5.1 - each cost a whole VM run).
- Probing a long-running job to find a bug that a two-second local check would have shown; issuing N
  sequential tool calls against ONE artefact instead of one script - for an MSI that script exists, it is
  `scripts/Get-PsadtMsiFacts.ps1`; running Phase 6 strictly after Phases 7-8 when they are independent;
  a three-agent research fan-out for an app whose vendor ships an official MSI (the MSI is the research).
- Hand-building a Wikimedia thumbnail URL (only pre-rendered widths are served - `1024px-` returns HTTP 400
  where `1280px-` works; take `thumburl` from the API verbatim) or guessing a Commons file name instead of
  searching the File namespace. Both cost time twice in one session on 2026-09-05; App. J now has them.
- Disabling Defender or dropping Repair/Uninstall to make the SYSTEM test "faster" - that tests a
  configuration no client has, and a package whose Uninstall never ran is not a finished package.
- Uploading without the Phase 6 SYSTEM test passing; a blanket `exit 0` or a `finally`-written detection tag in a
  fix script - both report GREEN on failure (guide K.7).
- Claiming Intune "can't" put a cert in `TrustedPublisher` (it can - `RootCATrustedCertificates` CSP via Custom
  OMA-URI; the built-in template is the part that can't); multi-line/PEM base64 or a mismatched thumbprint in the
  OMA-URI value (-> `0x87d1fde8`); owning a cert in BOTH the package and a policy (they fight on uninstall/sync).
- Browser extensions (App. O): Firefox `ExtensionSettings` as `REG_SZ` instead of `REG_MULTI_SZ` (silently
  ignored); clobbering the whole forcelist key / hard-coding index `1` instead of merging at the next free index
  (wipes other extension packages); a detection that claims the extension is "installed" rather than that the
  policy is set.
- Windows features (App. P): enabling WITHOUT `-NoRestart` (DISM reboots mid-install instead of returning 3010);
  forgetting the temporary WSUS bypass on managed devices (`0x800f0950` content-not-found) or not restoring it;
  detection run as 32-bit (DISM needs 64-bit); treating `EnablePending` as installed.

## Reference lookup

`references/app-registration.md` - THE Graph permission matrix (app roles + capabilities + bootstrap scopes).
`references/PSADTv4-Deployment-Guide.md` - **Phase 0 setup doctor + config home + Intune access** ·
Phase 1.2 intake catalogue · 1.1/1.3 research · Phase 3 scaffold ·
4 customize · 5 pre-flight · **6.1 sandbox SYSTEM test / 6.2 per-action / 6.3 run it in parallel** ·
7 package · 8-9 Intune config fields · 11 test · 12 rollout · App. A errors ·
B anti-patterns · C test stubs · D URLs · E deploy checklist · F dossier template (all fields) · G lessons
learned · H direct Graph upload · **I WinGet packaging** · **J app-logo acquisition + verification** ·
**K script-only / remediation packages (ESP-safe)** · **L installer technologies + silent switches** ·
**M group assignment (opt-in: config, naming, permissions)** ·
**N certificate store deployment (driver-trust / TrustedPublisher; RootCATrustedCertificates CSP OMA-URI;
`New-IntuneTrustedCertPolicy.ps1`)** ·
**O browser-extension force-install (opt-in: Edge/Chrome/Firefox policy keys, Firefox `REG_MULTI_SZ` trap,
merge/selective-remove; `New-BrowserExtensionPackage.ps1`)** ·
**P windows-features (opt-in: Enable-WindowsOptionalFeature + Add-WindowsCapability, 3010 reboot, WU/WSUS-bypass
content source, EnablePending detection; `New-WindowsFeaturePackage.ps1`)** ·
**Q third-party drivers (classification matrix, PnP install vs. Code Integrity, pnputil 0/259/3010 + the two
0xE... failures, oemNN.inf resolution, installer-bundled drivers; `Get-DriverSignatureInfo.ps1`,
`New-DriverPackage.ps1`)**.

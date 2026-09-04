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
   Add-WindowsCapability, App. P, built by `scripts/New-WindowsFeaturePackage.ps1`).
2. **Deployment semantics** - target audience (Required / Available / both, + AAD groups), uninstall "what
   goes vs. what stays", repair strategy, reboot behaviour (never / 3010 / 1641). Pre-select defaults from
   the installer type. Group assignment is **opt-in**: only when the user wants it here do you create/assign
   Entra groups (Phase 10, config `intune.groups`, guide Appendix M); the default is upload-without-assignment.
3. **SYSTEM-test consent** - it installs the real software as SYSTEM; recommend a VM/snapshot before the
   first install.
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
- **Output location.** `.intunewin` ALWAYS to `<paths.outputRoot>\<App[-Version]>\` (from `Get-PsadtConfig`,
  no hard-coded default), one sub-folder per app. Detection script + `Intune-Dossier.html` live in that same
  folder (everything together). Never a `_IntuneOutput` folder beside the package; never `-o` inside `-c`.
- **Logging.** PSADT writes its session log to `C:\Windows\Logs\Software\` by default (the IME-readable
  location) - leave it there, don't redirect. Keep each Phase-6 SYSTEM-test log for audit.
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
- **Certificates into a machine store** (driver-trust / `TrustedPublisher`, Root/CA, `TrustedPeople`). Whenever a
  cert must land in a store - the #1 case is an installer that stages a **3rd-party driver**, whose Windows
  "install device software?" prompt blocks a SYSTEM-silent install - treat it as a first-class deliverable:
  extract the signer cert (from the MSI/EXE/.cat), make **single-line base64** (NO line breaks/PEM -> CSP error
  `0x87d1fde8`), build the OMA-URI
  `./Device/Vendor/MSFT/RootCATrustedCertificates/<Store>/<SHA1>/EncodedCertificate`. **TrustedPublisher /
  TrustedPeople need the `RootCATrustedCertificates` CSP via a Custom OMA-URI profile** - the built-in
  "Trusted certificate" template only does Root/Intermediate (never claim Intune "can't" do TrustedPublisher).
  Own the cert in **exactly ONE place** - the **Intune policy** (recommended/transparent:
  `scripts/New-IntuneTrustedCertPolicy.ps1`, dry-run/`-Execute`, prints the manual portal steps when the app
  lacks `DeviceManagementConfiguration.ReadWrite.All`) **OR** a package import in the install hook - never both
  (they fight on uninstall/sync). Assign the policy to the SAME scope as the app. Guide Appendix N.
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
as its `SkillUpdate` check (quiet, non-blocking):
`pwsh scripts/Update-PsadtSkill.ps1` (read-only, commit-based: `HEAD` vs `origin/<branch>`, or the GitHub
commits-API sha vs the recorded `tooling.skillCommit`; the CHANGELOG version is context only). If
`UpdateAvailable`, show `LocalVersion -> RemoteVersion` + `Behind` + `WhatsNew`, then ask via
`AskUserQuestion`. Only on confirm: `pwsh scripts/Update-PsadtSkill.ps1 -Apply` (git pull --ff-only for a
clone, else branch-zip overwrite of tracked files only - never config/secret/tools/docs). Never auto-apply.
Offline → say so and continue; an update check must never block packaging.

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
type: switch, expected exit codes, log path, known leftovers. **Consult guide Appendix L (installer technologies
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

**Phase 3 - Scaffold.** `New-ADTTemplate -Destination <root> -Name <App>` (4.1.x takes only
`-Destination/-Name/-Version/-Force/-Show/-PassThru` - NO app metadata; metadata goes into `$adtSession`
afterwards). Fill `$adtSession` (AppVendor/Name/Version/Arch/Lang/Revision, success + reboot exit codes,
`AppScriptVersion='0.1'`, `AppScriptAuthor` from config) and the `.NOTES` changelog. Verify the module
version == `DeployAppScriptVersion`. WinGet: provision the extension module into the package, `Files\` stays
empty, `AppVersion='Latest'` (or pinned) (guide Appendix I.2). Field details: guide Phase 3.

**Phase 4 - Customize all three hooks.** User drops the installer in `<pkg>\Files\`; fill
`Install/Uninstall/Repair-ADTDeployment` from the research. Per-installer patterns
(MSI/EXE/InstallShield/Squirrel), `Show-ADTInstallationWelcome -CloseProcesses ... -CheckDiskSpace` before
install, Start-Menu-only shortcuts, uninstall cleanup (tasks/services/firewall/registry - only the APP
sub-key, NEVER the vendor root; keep user data by default), and async-retry loops (services need 30-60s after
msiexec): guide Phase 4. WinGet hook patterns: guide Appendix I.3. The GUID-to-`-ProductCode` rule (a GUID to
`-FilePath` throws `InvalidFilePathParameterValue` → 60001) applies to Uninstall AND Repair - Repair is the
usual miss. Custom helpers ALWAYS in `PSAppDeployToolkit.Extensions.psm1`, never the main script. If the installer
**stages a 3rd-party driver** (the Windows device-software prompt blocks a SYSTEM-silent install), plan the
certificate deliverable now (Conventions / guide Appendix N) - prefer the Intune cert policy
(`scripts/New-IntuneTrustedCertPolicy.ps1`) over an in-package import.

**Phase 5 - Pre-flight (Reviewer gate).** Run `scripts/Invoke-PsadtPreflight.ps1 -PackagePath <pkg>` - it returns
`{ Overall='GREEN'|'RED'; Checks=@(...) }` and runs all gate checks deterministically: encoding (`HasBOM=True` OR
non-ASCII `Count=0`), AST parse, v3-cmdlet scan (launcher + Extensions only - bundled `Files\*.ps1` are
parse/encoding-only, so a private `Write-Log` there is NOT flagged), top-level-statement scan, the structural
acid-test (all three `*-ADTDeployment` hooks defined + Extensions helpers actually called), and the
GUID-to-`-FilePath` anti-pattern. **`Overall` must be GREEN to proceed** (any RED = STOP, even if Install looks
fine - else Company-Portal uninstall returns 0x80070001). Encoding fix (em-dash/smart-quote replace + UTF-8 BOM)
and per-check explanations: guide Phase 5 (5.1-5.6) + Appendix C. WinGet adds a module-present check and MUST use
the acid-test stub (a live acid test would install): guide Appendix I.4.

**Phase 6 - SYSTEM test loop (opt-in; BINDING gate for upload).** `Invoke-PsadtSystemTest.ps1` runs one
action as SYSTEM (via `Invoke-CommandAs`, self-healed from PSGallery; needs an elevated session) and returns
`{ DeploymentType, ExitCode, Success, DetectionState, LogPath, LogTail, ErrorLines, Elevated }`. It fixes
nothing - YOU drive the loop and fix between runs. **Prerequisites (all required):** Windows PowerShell 5.1
(`PSScheduledJob`, which `Invoke-CommandAs -AsSystem` relies on, is 5.1-only - pwsh 7 cannot run it), an
ELEVATED session, the `Invoke-CommandAs` module, and ideally a VM/snapshot; on some hosts PSADT itself fails
to import under WinPS 5.1 (60008), so run the gate on a DEV VM. Gate 3 consent + VM/snapshot first; hard cap
of 5 iterations (you own the count - there is no config key for it). Loop: Install → verify detection →
Uninstall → verify clean (services, tasks, app reg key, install dir, firewall; neighbour products of the same
vendor still present) → Reinstall. Converged → leave the machine uninstalled (the default end-state), keep each
PSADT log for audit. Cap reached → blockade protocol, hand back. If you cannot run it (no elevation), STOP before any upload.
Diagnosis mapping: Troubleshooting table + guide Appendix A / G.

**Phase 7 - Package.** Paths from config (`paths.intuneWinAppUtil`, provisioned by `Get-IntuneWinAppUtil.ps1`):
`& $tool -c <pkg> -s 'Invoke-AppDeployToolkit.exe' -o <outputRoot>\<App[-Version]> -q`. `-o` lies outside `-c`
(different trees - never nest, or the old `.intunewin` lands recursively in the package). Copy the detection
script + `Intune-Dossier.html` alongside. Verify the `.intunewin` (`SetupFile` = Invoke-AppDeployToolkit.exe,
size). Code + extractability check: guide Phase 7.

**Phase 8 - HTML report (ALWAYS) + real logo.** Fill `$meta` (key list: guide Appendix F.0), then
`New-PsadtReport.ps1 -Metadata $meta -LogoPath <logo> -OutputPath <Output\<App>\Intune-Dossier.html>`.
Mandatory return codes: `0, 1707 Success; 3010 soft / 1641 hard reboot; 1618 retry; 60001, 60008 Failed` +
researched installer codes. App description = Markdown, dossier language, real umlauts (structure/template:
guide F.2). Logo fetch + verify + MSI-icon fallback: guide Appendix J. WinGet dossier additions
(WinGet >= 1.7.10582 requirement, registry/file detection note): guide Appendix I.6.

**Phase 9 - Direct Graph upload (opt-in).** Gate 4. ALWAYS dry-run first (read-only) → show summary +
`On -Execute` action → confirm → `-Execute`. `Invoke-IntuneWin32Upload.ps1` (via `Get-GraphToken.ps1`): MSI →
`-MsiProductCode '{GUID}'`; EXE/non-MSI → `-DetectionScriptPath` (a detection rule accepts only
`ruleType, enforceSignatureCheck, runAs32Bit, scriptContent`; the detect script writes stdout + `exit 0` when
installed, nothing when not). Fill every objective field; impose no category/notes/featured (group assignment
is the separate opt-in Phase 10); never DELETE (`-OnExisting CreateNewCoexist`, `-UpdateAppId` only for explicit
in-place, optional `-SupersedesAppId` - the script wires SUPERSEDENCE only, NOT app dependencies
(`-DependsOnAppId` relationships are portal-wired). Uses `/beta` (v1.0 drops `displayVersion`; `/beta` is
unversioned so win32LobApp request shapes can shift - the upload-shape unit tests guard this). `-MinWindowsRelease` is a
`ValidateSet` of backend-accepted release IDs (`1607..2004`); labels like `21H2`/`22H2` are server-rejected -
set a higher minimum in the portal (guide H.11). The script refuses the PSADT default logo (SHA256) unless
`-AllowDefaultLogo`. Graph gotchas: guide Appendix H.

**Phase 10 - Group assignment (opt-in).** Only when the user chose it at Gate 2 AND `intune.groups.enabled`.
ALWAYS dry-run first (read-only) → show the planned group names + actions → confirm → `-Execute`.
`Invoke-IntuneAppAssignment.ps1 -AppId <id> -AppName ... -AppVendor ... -AppVersion ... -Intents required,available`
creates/reuses Entra security groups by the config naming scheme (`intune.groups.naming`, version-INDEPENDENT by
default so a new version reuses the same groups; `%version%` is an opt-in that breaks that) and assigns the app
(intents required/available/uninstall). Idempotent; never deletes a group or another app's assignment;
ambiguous/duplicate names are skipped, not guessed. Needs `Group.Create` + `GroupMember.Read.All` on the upload
app (`New-PsadtEntraApp.ps1 -IncludeGroupManagement`). Feed the returned `Groups` into the dossier Assignments
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
| upload `403` on probe/create | app consent missing/ineffective | re-run `New-PsadtEntraApp.ps1`; guide H |
| detection rule rejected (`property may not be set ... used for app detection`) | requirement-only props on a detection rule | keep only `ruleType,enforceSignatureCheck,runAs32Bit,scriptContent`; guide H.2 |
| upload `BadRequest: Unknown MinimumSupportedWindowsRelease` | `-MinWindowsRelease` value the backend rejects (e.g. `21H2`/`22H2`) | use a backend-accepted ID `1607..2004`; set a higher min in the portal; guide H.11 |
| assignment `Group assignment is not enabled` | `intune.groups` absent/`enabled=false` in the resolved config | configure `intune.groups` (App. M); run `Initialize-PsadtSkill.ps1` to see WHICH config was resolved |
| assignment denied on group lookup/create (`Authorization`) | upload app lacks `GroupMember.Read.All` / `Group.Create` | `New-PsadtEntraApp.ps1 -IncludeGroupManagement` (Global Admin); guide M.1 |

Full symptom/HRESULT catalogue: guide Appendix A.

## Anti-patterns (TOP offenders only; FULL list: guide Appendix B + I.7 + K.7)

- v3 cmdlet names (`Execute-Process`, `Write-Log`, `Show-InstallationWelcome`, ...); any em-dash/smart-quote or
  other non-ASCII in a `.ps1` (comments too) without a UTF-8 BOM - the #1 encoding failure. Top-level code outside try/catch.
- GUID to `Start-ADTMsiProcess -FilePath` (Uninstall AND Repair - Repair is the usual miss) -> 60001.
- `-o` inside `-c`; not mapping 60001/60008 as Failed; "runs locally = runs in Intune" without the acid test;
  hand-rolling the pre-flight instead of `scripts/Invoke-PsadtPreflight.ps1` (its GREEN/RED verdict IS the gate).
- Shipping the PSADT default `AppIcon.png`/Banner as the logo; skipping or hand-assembling the HTML report.
- Auto-imposing user/org choices on upload (category/featured/`notes`), or assigning groups when the user did
  NOT opt in at Gate 2; DELETING the older version instead of `-OnExisting CreateNewCoexist`.
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

`references/PSADTv4-Deployment-Guide.md` - Phase 1.2 intake catalogue · 1.1/1.3 research · Phase 3 scaffold ·
4 customize · 5 pre-flight · 7 package · 8-9 Intune config fields · 11 test · 12 rollout · App. A errors ·
B anti-patterns · C test stubs · D URLs · E deploy checklist · F dossier template (all fields) · G lessons
learned · H direct Graph upload · **I WinGet packaging** · **J app-logo acquisition + verification** ·
**K script-only / remediation packages (ESP-safe)** · **L installer technologies + silent switches** ·
**M group assignment (opt-in: config, naming, permissions)** ·
**N certificate store deployment (driver-trust / TrustedPublisher; RootCATrustedCertificates CSP OMA-URI;
`New-IntuneTrustedCertPolicy.ps1`)** ·
**O browser-extension force-install (opt-in: Edge/Chrome/Firefox policy keys, Firefox `REG_MULTI_SZ` trap,
merge/selective-remove; `New-BrowserExtensionPackage.ps1`)** ·
**P windows-features (opt-in: Enable-WindowsOptionalFeature + Add-WindowsCapability, 3010 reboot, WU/WSUS-bypass
content source, EnablePending detection; `New-WindowsFeaturePackage.ps1`)**.

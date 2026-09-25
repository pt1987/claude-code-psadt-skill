# First-run setup and project structure

← back to the [README](../README.md)

## First-run setup

`scripts/Initialize-PsadtSkill.ps1` (also reachable by saying *"psadt setup"* / *"psadt doctor"*) checks
every prerequisite in one pass and reports **GREEN / YELLOW / RED**. Every line comes with a concrete fix
hint, and `-Fix` applies the ones that need no decision (module installs, the tool download, the
`language.*` defaults, `paths.intuneWinAppUtil`, and migrating a pre-0.19 config). It is idempotent - run it
as often as you like.

Only four values genuinely need you; the doctor lists them in `.Missing` and takes them via `-Set`:

```powershell
pwsh scripts/Initialize-PsadtSkill.ps1 -Fix -Set @{
    'paths.packageRoot' = 'D:\Pakete'; 'paths.outputRoot' = 'D:\Intune'
    'author.person'     = 'Pat Taubert'; 'author.company' = 'PHAT Consulting'
}
```

| Setting | Purpose |
|---|---|
| `paths.packageRoot` / `outputRoot` | Where packages are built and where artifacts are written |
| `paths.intuneWinAppUtil` | Content-prep tool location - filled by `-Fix` |
| `language.script` / `dossier` | Script language (EN) vs. dossier language (DE for the Company Portal) - filled by `-Fix` |
| `author.person` / `company` | Stamped into every package's `AppScriptAuthor` |
| `intune.*` *(optional)* | Direct upload: tenant/client, credential reference, verified roles - written by `New-PsadtEntraApp.ps1` |
| `intune.groups.*` *(optional)* | Opt-in group assignment (`enabled` / `create` / `membershipType` / `naming`) - guide Appendix M |

### Where the setup is stored

`config.json`, `secret.dpapi`, `tools/` and `verified-switches.json` live in the **config home** -
`%LOCALAPPDATA%\psadt-deploy\`, overridable with `$env:PSADT_DEPLOY_HOME` - **not** in the skill folder,
so they survive a `git pull`, a re-clone and a re-install. They are machine-local and never committed.

> **`verified-switches.json` is the one with a second half.** Since 0.40.0 a SHIPPED layer travels with
> the skill at `references/switch-catalog/verified-switches.json`, so a fresh installation starts with
> what earlier gate runs proved instead of a blank slate. The reader merges both by installer SHA256 and
> **the local entry wins**, which is what makes the merge idempotent: the same hash in both layers is one
> candidate, not two, however often it is read. Writing stays local-only, deliberately - `references/`
> is in `Update-PsadtSkill.ps1`'s `TrackedItems` and is replaced wholesale on update, so anything written
> there would be lost. A team that would rather share one file than ship it can point
> `Get-PsadtSwitchCandidates.ps1 -ShippedStorePath` at a network path instead. A `config.json` from a pre-0.19
install (beside `scripts/`) keeps working read-only; the doctor flags it and `-Fix` migrates it, renaming
the originals to `*.migrated` rather than deleting anything.

> DPAPI is bound to the Windows user profile: a re-installed OS invalidates a stored client secret. The
> doctor and `Test-PsadtIntuneAccess.ps1` both say so, and the fix is one `New-PsadtEntraApp.ps1` run.

## Project structure

```
psadt-deploy/
├─ SKILL.md · README.md · CHANGELOG.md · SECURITY.md · LICENSE
├─ package.json · bin/install.mjs        the npx installer (Node 18+, zero dependencies)
├─ docs/                                 this documentation set
├─ scripts/                              41 files: 37 invocable, 4 shared includes
│  │  setup + config
│  ├─ Initialize-PsadtSkill.ps1          setup doctor (Phase 0, GREEN/YELLOW/RED, -Fix/-Set)
│  ├─ Get-PsadtConfig.ps1                config read + config-home resolver
│  ├─ Set-PsadtConfig.ps1                config write (deep merge, DPAPI secret, -Remove)
│  ├─ Get-PsadtModule.ps1                PSADT module (self-heal)
│  ├─ Get-IntuneWinAppUtil.ps1           content-prep tool (self-heal)
│  ├─ Get-WinGetModule.ps1               WinGet extension (opt-in)
│  ├─ Update-PsadtSkill.ps1              self-update from GitHub
│  │  research before the web (Phase 2)
│  ├─ Get-PsadtLocalEvidence.ps1         the evidence ladder + the agent budget
│  ├─ Get-PsadtInstallerEngine.ps1       engine fingerprint from the binary
│  ├─ Get-PsadtSwitchCandidates.ps1      ranked silent-switch candidates from the catalog
│  ├─ Get-PsadtMsiFacts.ps1              MSI identity, tables, signature, Icon table
│  ├─ Get-DriverSignatureInfo.ps1        driver trust classifier (signed? kernel? deployable?)
│  ├─ Get-PsadtReturnCodes.ps1           the single source of truth for return codes
│  │  per-package truth
│  ├─ Get-PsadtPackageManifest.ps1       manifest read (+ the artifact stem)
│  ├─ Set-PsadtPackageManifest.ps1       manifest write (merge / append)
│  │  package generators
│  ├─ New-MsiPackage.ps1                 MSI packages
│  ├─ New-ExePackage.ps1                 EXE packages (Inno, NSIS, electron-builder)
│  ├─ New-BrowserExtensionPackage.ps1    browser-extension force-install (opt-in)
│  ├─ New-WindowsFeaturePackage.ps1      optional features / capabilities (opt-in)
│  ├─ New-DriverPackage.ps1              driver packages, pnputil staging (opt-in)
│  │  gates + deliverables
│  ├─ Invoke-PsadtPreflight.ps1          pre-flight GREEN/RED gate (Phase 5, 14 checks)
│  ├─ Invoke-PsadtSandboxTest.ps1        SYSTEM test in Windows Sandbox (Phase 6, the default route)
│  ├─ Invoke-PsadtSystemTest.ps1         SYSTEM test, one action on a DEV VM (Phase 6, fallback)
│  ├─ Invoke-PsadtPackage.ps1            build the .intunewin (Phase 7, named + verified)
│  ├─ New-PsadtReport.ps1                HTML dossier (Phase 8, always)
│  │  intune / graph
│  ├─ New-PsadtEntraApp.ps1              Entra app bootstrap (WAM)
│  ├─ Get-GraphToken.ps1                 app-only Graph token (cert / DPAPI)
│  ├─ Test-PsadtIntuneAccess.ps1         access verdict (roles, capabilities, expiry)
│  ├─ Invoke-IntuneWin32Upload.ps1       direct upload (Phase 9)
│  ├─ Invoke-IntuneAppAssignment.ps1     group assignment (Phase 10, opt-in)
│  ├─ New-IntuneTrustedCertPolicy.ps1    Custom OMA-URI cert policy (self-contained)
│  ├─ New-IntuneFirewallPolicy.ps1       firewall-rule policy (self-contained)
│  │  shared includes (not invoked directly)
│  ├─ _GraphCommon.ps1                   shared Graph helpers (retry, errors, token roles)
│  ├─ _GraphInteractive.ps1              shared WAM sign-in
│  └─ _SandboxProgressUi.ps1 / .xaml     the in-VM progress window
├─ references/                           24 files, the agent-facing depth
│  ├─ README.md                          the reference map (label -> file)
│  ├─ phases-0-6.md · phases-7-12.md     phases 0 through 12
│  ├─ appendix-a-errors.md … -r-supersedence.md  one file per appendix
│  ├─ switch-catalog/                    engine defaults + JSON schema (App. L.0)
│  ├─ Report-Template.html               the fixed dossier template
│  ├─ conventions.md · research-trust.md the binding conventions, and why fetched text is data
│  └─ app-registration.md                THE Graph permission matrix + manual portal route
├─ evals/                                trigger + behaviour eval suite
└─ tests/                                Pester suite, 921 tests
```

Machine-local state lives outside the skill folder:

```
%LOCALAPPDATA%\psadt-deploy\             ($env:PSADT_DEPLOY_HOME overrides)
├─ config.json                           settings incl. the optional intune.* block
├─ secret.dpapi                          DPAPI client secret (only without cert auth)
├─ tools/                                IntuneWinAppUtil.exe + WinGet module
└─ verified-switches.json                what a GREEN full gate proved here, keyed by file hash
```

And per package, next to `Invoke-AppDeployToolkit.ps1`:

```
psadt-package.json                       identity · gate decisions · research · results · artifacts
```

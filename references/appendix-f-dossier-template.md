# Appendix F: Package report (Intune dossier + technical report)

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Contents

- [F.0 Generator usage + `-Metadata` keys](#f0-generator-usage---metadata-keys)
- [F.1 App information](#f1-app-information)
- [F.2 Description Markdown template (Company Portal)](#f2-description-markdown-template-company-portal)
- [F.3 Program](#f3-program)
- [F.4 Return codes (mandatory table, copy exactly)](#f4-return-codes-mandatory-table-copy-exactly)
- [F.5 Requirements](#f5-requirements)
- [F.6 Detection rules](#f6-detection-rules)
- [F.7 Dependencies](#f7-dependencies)
- [F.8 Supersedence](#f8-supersedence)
- [F.9 Assignments](#f9-assignments)
- [F.10 Review + Create](#f10-review--create)
- [F.11 Example filled-in (Oracle Database 21c XE from this project)](#f11-example-filled-in-oracle-database-21c-xe-from-this-project)

## Appendix F: Package report (Intune dossier + technical report)

**The report is generated for EVERY package — uploaded or not — by `scripts/New-PsadtReport.ps1` from the fixed
template `references/Report-Template.html`. Do NOT hand-assemble the HTML.** Output is always
`Intune-Dossier.html` in the artifact folder (`artifacts.outputFolder` =
`<paths.outputRoot>\<Vendor>_<App>_<Version>_<Arch>\`). It is one self-contained, **bilingual (DE/EN toggle)** document:
part 1 is the Intune dossier (the tables F.1–F.9 below), part 2 is the technical package report (deployment
hooks, PSADT cmdlets used, pre-flight results, the Phase 6 SYSTEM-test result, logo + `.intunewin`
verification). The logo is embedded as a base64 data URI; the description **preview is rendered client-side
from its Markdown source**. **Exception:** the F.2 description block is **Markdown**, because the Intune app
description field supports only Markdown (not HTML). The values come from Phase 1.2/1.3 and the test phases.

### F.0 Generator usage + `-Metadata` keys

Since 0.21.0 the identity comes from the package manifest, so the same app cannot end up with two
different names in the artifact, the dossier and Intune:

```powershell
& scripts/New-PsadtReport.ps1 -ManifestPath '<pkg>\psadt-package.json' `
    -LogoPath '<artifacts.logo>' -OutputPath '<artifacts.outputFolder>\Intune-Dossier.html'
```

`-Metadata` still overrides any individual key, and the manifest-free form
(`-Metadata $meta` only) still works for ad-hoc use. With `-ManifestPath` there is one hard rule: the
identity must be real. `AppName`, `AppVersion` and `Publisher` must resolve, or the script throws instead
of shipping a dossier that says "App 0.0.0" - a placeholder with a letterhead is worse than no document.
Everything else stays optional and renders NEUTRALLY ("not run" / "not packed yet"), because the report is
produced for EVERY package, including one that has not reached Phase 7. The one exception is the SYSTEM
test: when the manifest says `decisions.upload = true`, a missing SYSTEM-test result is an error, because
Phase 6 is the binding gate for upload.

`$meta` is a hashtable. Every key is optional (sane defaults fill the rest, so the report is always complete):

| Key | Meaning |
|---|---|
| `Lang` | initial language `de` (default) / `en` — both are always embedded regardless |
| `AppName`, `AppVersion`, `Publisher`, `Developer`, `Owner` | header + App Info |
| `PkgRev`, `ScriptVersion`, `Created`, `Author`, `PsadtVersion`, `ModuleVersion` | header meta + cmdlet note |
| `SubDe`/`SubEn`, `StatusDe`/`StatusEn` | header subtitle + status pill (HTML entities allowed) |
| `Category` (null⇒"not preset"), `Featured` (bool), `InfoUrl`, `PrivacyUrl`, `Notes` | App Info |
| `DescMdDe`, `DescMdEn` | description **Markdown** per language (real umlauts here) |
| `InstallCmd`, `UninstallCmd`, `InstallBehavior`, `RestartBehaviorDe/En`, `RestartNoteDe/En`, `InstallTimeMin`, `AllowUninstall` | Program |
| `ReturnCodes` | INSTALLER-SPECIFIC codes only, as `@{ Code; Type; De; En }` with `Type` one of `success`/`softReboot`/`hardReboot`/`retry`/`failed`. They are MERGED OVER the mandatory F.4 table, never replace it, and an invalid type THROWS. `Cls`/`Label` are derived from `Type` and ignored if passed. |
| `OsArch`, `MinOs`, `DiskMb`, `MemoryMb` | Requirements |
| `RuleFormat`, `DetectScript`, `RunAs32` (bool), `SignatureCheck` (bool) | Detection |
| `Dependencies`/`Supersedence` (+`*NoteDe/En`) | null ⇒ "none" + note |
| `Assignments` | array of `@{ Group; Type=Required/Available/Uninstall; Availability }` |
| `HookInstall`, `HookUninstall`, `HookRepair` | arrays of bullets: a string (technical, same both langs) or `@{ De; En }` |
| `Cmdlets` | array of cmdlet names (chips) |
| `Preflight` | array of `@{ Title; Cls=ok/warn/fail; De; En; BDe; BEn }` (defaults to 6 passing checks) |
| `SystemTest` (+`SystemTestNoteDe/En`) | array of `@{ StepDe; StepEn; Exit; Detection; Cls; Result }` |
| `LogoSource`, `LogoResolution`, `LogoGuardOk` (bool), `IntuneWin`, `SetupFile`, `Location` | Logo & package-file section |

The tables F.1–F.9 below are the source-of-truth field reference (what each value means); the generator maps
them onto the template. Keep them for depth and for the manual Admin-Center route.

### F.1 App information

| Intune field | Value | Notes |
|---|---|---|
| **Name** | `<AppName> <Version>` | exactly as visible in the Company Portal; version incl. build if there are updates |
| **Description** | see F.2 (Markdown block) | the first ~200 characters are the short preview in the CP |
| **Publisher** | `<Vendor>` | from Phase 1.2 (Adobe Inc., Oracle Corporation, ...) |
| **App version** | `<Major.Minor.Build.Rev>` | exact file version |
| **Category** | e.g. Business, Development, Productivity, Communication | for CP navigation |
| **Show this as a featured app in the Company Portal** | Yes/No | Yes only for recommended self-service apps |
| **Information URL** | `<vendor-product-page>` | official product homepage |
| **Privacy URL** | `<vendor-privacy-url>` | often the vendor's `/legal/privacy/` |
| **Developer** | `<Vendor-ShortName>` | usually == Publisher |
| **Owner** | `<internal-team>` | internal service owner (e.g. "Workplace-Services") |
| **Notes** | `PSADT 4.1.8 v<N> - pkg rev <NN> - YYYY-MM-DD` | package metadata for later troubleshooting |
| **Logo** | `<pkg>\Assets\<App>-Logo.png` (REAL app logo, NOT the PSADT default `AppIcon.png`) | >=256x256 PNG |
| **Role scope tags** | `<Default>` or custom | only with a delegated admin role structure |

### F.2 Description Markdown template (Company Portal)

The Intune app description field supports **only Markdown** (not HTML) and renders it in the Company Portal. Copy the block 1:1, replace `<...>`.

(end-user output — language.dossier, default German)

```markdown
**<AppName>** ist <Ein-Satz-Zweck>.

<Zwei-bis-drei-Sätze-Nutzenbeschreibung für Endbenutzer. Was bekommen sie, wofür brauchen sie das.>

**Was du bekommst**
- <Feature 1>
- <Feature 2>
- <Feature 3>
- <ggf. Config / Branding>

**Was du brauchst**
- Windows 11 (oder Windows 10 22H2+)
- ~<X> GB freier Speicherplatz auf `C:`
- Ca. **<N>-<M> Minuten** Installationsdauer
- *<ggf. Kein Neustart erforderlich / Neustart empfohlen>*

**Nach der Installation**

<Was findet der User vor? Startmenü-Eintrag, Desktop-Shortcut, Config-Datei, Zugangsdaten?>

**Deinstallation**

<Was passiert bei Deinstall? Bleiben User-Daten, werden sie entfernt, was soll der User vorher sichern?>

**Support**

Bei Problemen bitte ein Ticket beim **IT-Service-Desk** eröffnen und - wenn möglich - die Logdateien unter `C:\Windows\Logs\Software\` anhängen. Weitere Hinweise im [Support-Portal](<support-portal-url>).
```

Check: the first paragraph must also be readable on its own (200-character short preview).

### F.3 Program

| Intune field | Value |
|---|---|
| **Install command** | `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent` |
| **Install script** | - (do not use, the command is enough) |
| **Uninstall command** | `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent` |
| **Uninstall script** | - |
| **Installation time required (mins)** | Default 60; only raise if >45 min documented |
| **Allow available uninstall** | Yes (the user may uninstall via the CP) |
| **Install behavior** | **System** |
| **Device restart behavior** | `Determine behavior based on return codes` (default) OR `App install may force a device restart` when the installer can return 1641 |

### F.4 Return codes (mandatory table, copy exactly)

**Intune accepts exactly five types.** `win32LobAppReturnCode.type` is `success`, `softReboot`,
`hardReboot`, `retry` or `failed` - the portal's dropdown shows them as Success / Soft reboot / Hard reboot
/ Retry / Failed. **There is no "Ignored".** Anything else is rejected by the backend, and a dossier naming
an invalid type tells the operator to configure something the portal will not accept.

| Code | Portal label | Graph token |
|---:|---|---|
| 0 | Success | `success` |
| 1707 | Success | `success` |
| 3010 | Soft reboot | `softReboot` |
| 1641 | Hard reboot | `hardReboot` |
| 1618 | Retry | `retry` |
| 60001 | **Failed** | `failed` |
| 60008 | **Failed** | `failed` |

This table is not retyped anywhere: `scripts/Get-PsadtReturnCodes.ps1` is the single source of truth, and
BOTH the dossier (`New-PsadtReport.ps1`) and the upload (`Invoke-IntuneWin32Upload.ps1 -ReturnCodes`) read
from it. Before 0.26.0 it existed as two independent literals that agreed only by coincidence, while the
report rendered a caller-supplied table without validating a single field - which is how the invalid type
"Ignored" reached a real dossier.

Add the installer-specific codes from Phase 1.3 as `@{ Code = 1603; Type = 'failed'; De = '...'; En = '...' }`.
They MERGE OVER the mandatory rows - a caller cannot drop 60001/60008, because a package that fails to map
them reports its own crashes as success. A code that already exists is overridden, so an installer for
which 1618 genuinely means success is expressible. Record them once in the manifest as
`research.returnCodes` and both the dossier and the upload pick them up.

Ordering is by type in the sequence above, then numerically within a type - so the dossier reads in the
same order as this table it is checked against, and as the portal grid it is typed into.

Every unknown exit code produces `0x80070000+code` in the error display.

### F.5 Requirements

| Intune field | Value | Notes |
|---|---|---|
| **Operating system architecture** | x64 / x86 / Both | matches `$adtSession.AppArch` |
| **Minimum operating system** | Win11 22H2 / Win10 22H2 | realistic, not "Win10 1607" |
| **Disk space required (MB)** | `<MB>` | from the installer requirement, net + 20% reserve |
| **Physical memory required (MB)** | `<MB>` or empty | only for RAM-hungry installers |
| **Minimum number of logical processors required** | 1 / 2 / 4 | rarely relevant |
| **Minimum CPU speed required (MHz)** | empty | rarely relevant |
| **Additional requirement rules** | optional | Registry/File/Script - e.g. "Domain-Joined", "has Edge WebView2 installed" |

### F.6 Detection rules

**Rules format:** choose one way, do NOT mix:

**Option A - Custom script (preferred for complex installs):**
| Field | Value |
|---|---|
| **Rules format** | Use a custom detection script |
| **Script file** | `Detect-<AppName>.ps1` (shipped with the package) |
| **Run script as 32-bit process on 64-bit clients** | No (unless the script deliberately reads Wow6432Node) |
| **Enforce script signature check** | No (unless in a strictly signed environment) |

Detection-script contract:
- `exit 0 + stdout non-empty` -> INSTALLED
- `exit 0 + stdout empty` -> NOT INSTALLED
- `exit != 0` -> detection error (Intune retries)

**Option B - Manual, MSI Product Code:**
| Field | Value |
|---|---|
| **Rule type** | MSI |
| **MSI product code** | `{GUID}` |
| **MSI product version check** | No OR operator + version |

**Option C - Manual, File/Registry:**
ONE rule is enough if unambiguous. Mixing several rules: with care, all must match.

| Field | Value |
|---|---|
| **Rule type** | File / Registry / App version |
| **Path / Key** | `<konkret>` |
| **File/value** | `<konkret>` |
| **Detection method** | exists / string / version / size / date modified |
| **Associated with a 32-bit app on 64-bit clients** | No (almost always) |

### F.7 Dependencies

Other Win32 apps that must be installed FIRST.

| Field | Value |
|---|---|
| **Dependency app** | e.g. "VC++ 2015-2022 x64" |
| **Automatically install** | Yes (Intune installs it automatically afterwards) |

Avoid circular dependencies and >3 levels.

### F.8 Supersedence

Does this app replace a previous version or another product?

| Field | Value |
|---|---|
| **Superseded app** | the previous version (separate Intune entry) |
| **Uninstall previous version** | Yes/No (Yes for a true replace, No when parallel is possible) |

A maximum of **10 apps** as superseded; **at most 2 levels** deep (Intune limit).

### F.9 Assignments

One row per target group. At least one Required OR Available assignment, otherwise it never installs.

| Group (AzureAD / Entra) | Assignment type | Filter (include/exclude) | Install availability | Deadline | Restart grace period | Delivery Optimization |
|---|---|---|---|---|---|---|
| `<Grp-Devices-Required>` | Required | optional filter | As soon as possible / date | optional date | 1440 min + 15 min before reboot | Foreground / Background |
| `<Grp-Users-OptIn>` | Available | optional filter | - | - | - | Background |
| `<Grp-Cleanup>` | Uninstall | - | - | - | - | - |

**Hints:**
- Required for mandatory rollouts (security, compliance, standard tools)
- Available for self-service
- Uninstall for targeted removal from a group
- Filter: platform/version/device-name regex; for edge cases the IME checks cleanly whether the filter property exists
- Delivery Optimization Foreground for packages that have to arrive immediately; Background spares the network for large packages

**End user notifications** (per assignment):
- `Show all toast notifications` - default, the user sees download/install/reboot
- `Show toast notifications for computer restarts` - only the reboot prompt
- `Hide all toast notifications` - only for silent-only apps

### F.10 Review + Create

Before the `Create`, go through all tabs. After `Create`: Intune does not sync immediately — there is a 30-60 min wait until the client sees the package. Trigger it manually via Company Portal -> Settings -> Sync.

### F.11 Example filled-in (Oracle Database 21c XE from this project)

| Field | Value |
|---|---|
| Name | Oracle Database 21c Express Edition |
| Publisher | Oracle Corporation |
| App version | 21.0.0.0 |
| Category | Development, Database |
| Featured | Yes (for the developer audience) |
| Information URL | https://docs.oracle.com/en/database/oracle/oracle-database/21/xeinw/ |
| Privacy URL | https://www.oracle.com/legal/privacy/ |
| Developer | Oracle |
| Owner | Workplace-Services |
| Notes | PSADT v4.1.8 Wrapper v2 - Paketversion 02 - 2026-04-22 |
| Logo | `Assets/OracleXE-Logo.png` (real downloaded Oracle logo, NOT the PSADT default `AppIcon.png`) |
| Install command | `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent` |
| Uninstall command | `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent` |
| Install behavior | System |
| Device restart | App install may force a device restart |
| Installation time | 60 min |
| Return codes | 0/1707 Success; 3010/1641 reboot; 1618 retry; 60001/60008 Failed |
| OS architecture | x64 |
| Minimum OS | Windows 10 22H2 |
| Disk space required | 12288 MB |
| Physical memory | 4096 MB |
| Detection | Custom script `Detect-OracleXE.ps1`, Run as 32-bit=No, Signature=No |
| Dependencies | - (VCRedist is integrated in the PSADT pre-install hook) |
| Supersedence | - (first version) |
| Required group | Devices-OracleXE-Dev |
| Available group | Users-OracleXE-OptIn |
| Install availability | As soon as possible |
| Restart grace period | 1440 min (24h), 15 min countdown, snooze 240 min |

That is a complete dossier. Go through every new app the same way.

---

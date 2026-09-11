# Appendix L: Installer technologies + silent switches (consult BEFORE web research)

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Contents

- [L.1 Identify the technology](#l1-identify-the-technology)
- [L.2 Switch reference](#l2-switch-reference)
- [L.3 Detection-rule choice](#l3-detection-rule-choice)
- [L.4 MSP patches (verified against Microsoft Learn, 2026-09-08)](#l4-msp-patches-verified-against-microsoft-learn-2026-09-08)
- [L.5 WiX Burn bundles (the `.exe` that wraps MSIs)](#l5-wix-burn-bundles-the-exe-that-wraps-msis)
- [L.6 Advanced Installer projects (`.aip`)](#l6-advanced-installer-projects-aip)
- [L.7 Inno Setup and NSIS - the two traps the switch table cannot hold](#l7-inno-setup-and-nsis---the-two-traps-the-switch-table-cannot-hold)
- [L.8 MSIX / AppX - staging vs registration, and why SYSTEM breaks the obvious call](#l8-msix--appx---staging-vs-registration-and-why-system-breaks-the-obvious-call)
- [L.9 App-V - the support position, corrected](#l9-app-v---the-support-position-corrected)

## Appendix L: Installer technologies + silent switches (consult BEFORE web research)

Phase 2 research checks THIS table first and only web-searches to confirm the exact build's quirks. "Identify"
= how to recognise the tech; switches are the common silent install / uninstall / no-reboot / log; "Detect" =
the natural detection rule.

### L.1 Identify the technology
- File metadata/strings: `(Get-Item setup.exe).VersionInfo`; a `strings`-style scan for marker text.
- **Inno Setup:** EXE contains `Inno Setup` / `JR.Inno.Setup`; uninstaller `unins000.exe`.
- **NSIS:** EXE contains `Nullsoft.NSIS` / `NullsoftInst`; uninstaller `Uninstall.exe` / `uninst.exe`.
  A PE-metadata scan (`file`, or any equivalent) reports it directly as `Nullsoft Installer self-extracting
  archive`, which is cheaper and less ambiguous than a strings grep. Then check whether it is a
  **MultiUser** build (L.7) BEFORE trusting a bare `/S`.
- **InstallShield:** `setup.exe` + `*.cab` / `data1.hdr` / `0x0409.ini`; strings `InstallShield` / `ISSetupStream`;
  `ISInternalDescription "Setup Launcher"`. Basic-MSI vs InstallScript: extract (7-Zip) - an embedded `.msi`
  + `Windows Installer` strings => Basic MSI; `data1.cab`/`setup.inx`/`_isres*` => InstallScript.
- **install4j (Java):** EXE strings `com/install4j/runtime` / `exe4j` / `i4jparams.conf` / `-Duser.language`;
  extracts an `e4j*.tmp_dir*` with a bundled `jre\` + `i4jparams.conf` (XML: `install4jVersion`, screens/actions).
  Uninstaller is `<installdir>\uninstall.exe`. **`/S` is NOT its switch** - passing `/S` shows the
  language-selection dialog and hangs; the unattended switch is **`-q`**, and it needs elevation (a
  `RequestPrivilegesAction`) or it stalls waiting for it.
- **WiX Burn bundle:** EXE strings `WixBundle` / `.wixburn`; has a `BundleProviderKey`.
- **Advanced Installer:** the MSI's `CustomAction` table is full of `AI_*` rows (`AI_SET_ADMIN`,
  `AI_DOWNGRADE`, `AI_PREPARE_UPGRADE`, `AI_RESOLVE_KNOWN_FOLDERS`, `SET_APPDIR`) and references
  `aicustact.dll`; `SecureCustomProperties` carries `OLDPRODUCTS;AI_NEWERPRODUCTFOUND`. Measured on a
  real package 2026-09-08. Underneath it is a plain MSI - treat it as MSI for install/uninstall/detection
  and see **L.6** for the project-side traps.
- **MSI:** a `.msi` (or an EXE that strings-shows `Windows Installer` / extracts an MSI).
- **Squirrel:** `Update.exe` + `*.nupkg`; per-user `%LocalAppData%\<App>`.
- **MSIX/AppX:** `.msix` / `.appx` / `.msixbundle` / `.appxbundle`; inside, an `AppxManifest.xml`
  carrying `<Identity Name= Version= Publisher=>` plus `AppxBlockMap.xml` and `AppxSignature.p7x`.
  Read the identity with `Get-AppxPackageManifest`. **Not a classic installer at all** - see **L.8**
  before writing any hook, and check first whether Intune's native LOB app type is the better route.

> **A single string match is a HINT, not proof (BINDING).** A coincidental substring (e.g. `nsis` inside an
> unrelated blob) can misidentify the framework - a real case: an install4j Aperio installer was mistaken for
> NSIS, so `/S` was used, which hung on the language dialog forever. Confirm the framework by its *definitive*
> fingerprint (install4j -> `i4jparams.conf`; InstallShield Basic MSI -> `ISSetupStream` + embedded MSI), and
> then **behaviorally verify the silent switch**: run `installer <switch>` once with a timeout + a window/exit
> watch (kill on timeout) and confirm it exits 0 with no dialog BEFORE building the package. "Runs infinitely"
> or "a dialog appears under /S" means the switch is wrong for that engine - do not ship it untested.

### L.2 Switch reference
| Tech | Silent install | Silent uninstall | No reboot | Log | Detect | Notes |
|---|---|---|---|---|---|---|
| **MSI** | `msiexec /i pkg.msi /qn` | `msiexec /x {ProductCode} /qn` | `/norestart` | `/l*v "log"` | MSI ProductCode | props as `NAME=value`; `REBOOT=ReallySuppress` |
| **MSI-wrapped EXE** | vendor flag, often `/s /v"/qn /norestart"` | extracted MSI ProductCode | `/v"/norestart"` | `/v"/l*v log"` | ProductCode | prefer extracting the MSI (`/a` admin install or `setup.exe /extract`) |
| **InstallShield (Basic MSI)** | `setup.exe /s /v"/qn"` | ProductCode | `/v"/norestart"` | `/v"/l*v log"` | ProductCode | |
| **InstallShield (InstallScript)** | `setup.exe /s /f1"setup.iss"` | `setup.exe /s /x /f1"uninstall.iss"` | (ISS-driven) | `/f2"log"` | registry / file | record the `.iss` with `setup.exe /r /f1"setup.iss"` |
| **Inno Setup** | `setup.exe /VERYSILENT /SUPPRESSMSGBOXES /SP- /NORESTART` | `unins000.exe /VERYSILENT /NORESTART` | `/NORESTART` (**mandatory**, see L.7) | `/LOG="log"` | QuietUninstallString / registry | `/SILENT` shows a progress bar, `/VERYSILENT` none; `/SUPPRESSMSGBOXES` only works WITH one of them |
| **NSIS** | `setup.exe /S` (add `/allusers` or `/currentuser` if MultiUser - see L.7) | `Uninstall.exe /S _?=<installdir>` (see L.7) | (installer-specific) | `/D=path` (last arg, unquoted) | registry / file | `/S` is case-SENSITIVE; a bare `Uninstall.exe /S` returns BEFORE it is done |
| **Advanced Installer** | `msiexec /i pkg.msi /qn` | `msiexec /x {ProductCode} /qn` | `/norestart` | `/l*v "log"` | MSI ProductCode | plain MSI underneath; a fresh ProductCode per build is typical - re-probe every time (**L.6**) |
| **WiX Burn bundle** | `bundle.exe /quiet /norestart` | `bundle.exe /uninstall /quiet` | `/norestart` | `/log "log"` | registry (BundleProviderKey) / file version | wraps MSIs; a single ProductCode is unreliable |
| **Squirrel (Electron)** | `Setup.exe --silent` | `%LocalAppData%\<App>\Update.exe --uninstall -s` | n/a | n/a | file version under `%LocalAppData%` | usually PER-USER; a System/Win32 install needs care |
| **MSIX / AppX** | `Add-AppxProvisionedPackage -Online -PackagePath x -SkipLicense` | `Remove-AppxProvisionedPackage -Online` **AND** `Remove-AppxPackage -AllUsers` | n/a | DISM `-LogPath` | `Get-AppxProvisionedPackage -Online` (**NOT** `Get-AppxPackage`) | not a Win32 installer - **L.8**. As SYSTEM, `Add-AppxPackage` registers for SYSTEM only and still reports success. Prefer Intune's native LOB type (cap 8 GB). Must be signed; cert Subject == manifest Publisher |
| **App-V** | `Add-AppvClientPackage x` then `Publish-AppvClientPackage -Global` | `Unpublish-AppvClientPackage` **AND** `Remove-AppvClientPackage` | n/a | client event log | `Get-AppvClientPackage` | **L.9**. Client not deprecated (fixed extended support); servers end 04/2026. Add alone publishes to nobody; without `-Global` it publishes to SYSTEM. A package in use goes *pending* - global tasks apply only after a RESTART |
| **install4j (Java)** | `installer.exe -q` (unattended) | `<installdir>\uninstall.exe -q` | n/a | `-Dinstall4j.logToStderr=true` | registry / file version | **NOT `/S`** (that shows the language dialog + hangs). Needs elevation (runs as SYSTEM under Intune). QuietUninstallString is often EMPTY -> pass `-q` via `-AdditionalArgumentList`. Bundles its own JRE (no external dep). May `dpinst`-install drivers - extract the signer `.cer` and pre-trust it (TrustedPublisher). |
| **IzPack (Java)** | `installer.jar auto-install.xml` / `-options resp.txt` | uninstaller `-q` | n/a | varies | registry / file | response-file driven |
| **InstallAware / Wise** | `/s` or `/silent` | vendor-specific | varies | varies | registry / file | confirm per build; often MSI underneath |

### L.3 Detection-rule choice
- MSI / MSI-wrapped -> **MSI ProductCode** rule (upload `-MsiProductCode`).
- EXE / other -> a **PowerShell detection script** (file version / registry value), OR an Intune **file/registry
  version rule**. Never mix a script rule and a file/registry rule for the same app.
- Per-user installers (Squirrel) detect under `%LocalAppData%` - run detection in the right context.

> **Trademark-sign gotcha in DisplayName filters.** ARP `DisplayName` / `Publisher` often carry a `(R)`/`(TM)`
> sign (e.g. `Aperio(R) Programming Application`, `ASSA ABLOY(R)`). A literal `-match 'Aperio Programming
> Application'` then FAILS (the sign sits between the words), so `Uninstall-ADTApplication` / `Get-ADTApplication`
> find nothing, report success, and remove nothing. Use a tolerant regex - `-match 'Aperio.*Programming
> Application'` - and apply the same in the detection script's registry match.

### L.4 MSP patches (verified against Microsoft Learn, 2026-09-08)

Servicing packs, ADK patches and vendor hotfixes arrive as `.msp`. The rules are narrow and easy to get wrong.

| Task | Command | Note |
|---|---|---|
| Patch an INSTALLED product | `msiexec /p patch.msp /qn /norestart` | several patches: `patch1.msp;patch2.msp` |
| Patch an ADMINISTRATIVE IMAGE | `msiexec /p patch.msp /a product.msi /qn` | the ONE documented case where `/p` and `/a` combine |
| Patch during an install | `msiexec /i product.msi PATCH=patch.msp /qn` | `/i` and `/p` may NOT be combined |
| Patch one instance | `msiexec /p patch.msp /n {ProductCode} /qn` | multi-instance products |

- **`/i` and `/p` are mutually exclusive.** Microsoft states every option pair (`/i /x /f /j /a /p /y /z`) must not be
  combined, "the one exception ... is that patching an administrative installation requires using both /p and /a".
- **The `PATCH` property is IGNORED when `/p` is used** - it is overwritten, silently.
- **Extracting patched payload without installing anything**: `msiexec /a <msi> /p <msp> /qn TARGETDIR=<dir>`
  produces a patched administrative image you can copy files out of. **But see Appendix B #16** - an
  administrative install REWRITES the source MSI, so never point it at a file inside a package payload.
- **Exit 1642 is ambiguous - do not blanket-treat it as success.** Microsoft's text: "the program to be
  upgraded may be missing, **or the upgrade patch may update a different version of the program**". For a
  feature-scoped install (patching a bundle where only some sub-MSIs exist) 1642 is expected and harmless.
  For a patch that SHOULD apply, the same 1642 means a version/track mismatch - the wrong patch revision.
  Log which patch returned it instead of swallowing the code.
- **Logging flags, precisely**: `*` is a wildcard for everything **except** `v` and `x`. So `/l*` is the full
  log without verbose; `/l*v` adds verbose and `/l*vx` adds debug output. On a large MSP (the ADK's DISM
  patch is 172 MB) `/l*v` costs more wall-clock than the patching itself - prefer `/l*` unless diagnosing.

### L.5 WiX Burn bundles (the `.exe` that wraps MSIs)

Built-in actions: `/install` (default) `/uninstall` `/modify` `/repair` `/layout [path]` `/help`.
Display: `/full` (default) `/passive` `/quiet` (`/silent`, `/s`) `/none`. Plus `/norestart` and `/log <file>`.

- **Detection**: a Burn bundle registers under its **BundleProviderKey**, not a ProductCode. A single
  ProductCode is unreliable - the bundle installs several MSIs, each with its own. Detect on a file version
  the bundle delivers, or on the bundle's own ARP entry.
- **`/layout` downloads the payload for offline use** - but whether it can be narrowed is decided by the
  bundle's Bootstrapper Application, not by Burn. The Windows ADK's managed BA refuses it outright:
  `adksetup.exe /quiet /layout <dir> /features OptionId.DeploymentTools` fails with *"Selecting Windows
  Assessment and Deployment Kit features for download is not allowed. Don't specify /features argument to
  download all features."* Feature selection happens at INSTALL time; the layout is always the whole kit
  (measured 2026-09-08: ADK 1473 MB, WinPE add-on 1894 MB). Budget package size accordingly.
- **A bundle's own switches are additive to the BA's.** `/features`, `/installpath`, `/ceip off` on the ADK
  are BA parameters - read the vendor's documentation, do not assume them from Burn.

### L.6 Advanced Installer projects (`.aip`)

Relevant whenever the MSI is built in-house rather than shipped by a vendor.

| Task | Command |
|---|---|
| Build | `AdvancedInstaller.com /build <project.aip> [-buildslist <names>]` |
| Clean rebuild | `AdvancedInstaller.com /rebuild <project.aip>` |
| Set version | `AdvancedInstaller.com /edit <project.aip> /SetVersion <x.y.z>` |
| Set ProductCode | `AdvancedInstaller.com /edit <project.aip> /SetProductCode -langid 1033 -guid {GUID}` |
| Batch of edits | `AdvancedInstaller.com /execute <project.aip> <commands.txt>` (file must start with `;aic`) |

- **A new ProductCode per build is the norm for these projects**, with a fixed UpgradeCode. That yields a real
  major upgrade instead of a reinstall - and it means **the package identity changes on every build**: the
  launcher's `-ProductCode` for Uninstall/Repair, the detection script and the manifest all have to follow.
  Re-probe with `Get-PsadtMsiFacts.ps1` after every rebuild rather than trusting the previous values.
- **Relative paths in the `.aip` resolve against the .aip's own location, and this is NOT documented.**
  Measured 2026-09-08: a project referencing its build output as `..\..\Users\<name>\AppData\Local\Temp\...`
  worked while the project sat on `C:\`, and broke the moment the project tree moved to `F:\` - Advanced
  Installer then looked for `F:\Users\...` and failed with *"Resources referred by the project are missing"*.
  Moving an `.aip` between drives silently breaks every relative reference. Make such paths absolute.
- **The vendor's own build script may patch the MSI after the build** (a custom action to stop a service
  before `InstallValidate`, for example). Read it before assuming the produced MSI is what the `.aip`
  describes - and re-read the MSI tables rather than the project file.

### L.7 Inno Setup and NSIS - the two traps the switch table cannot hold

Verified against the vendor documentation 2026-09-08 (jrsoftware.org, nsis.sourceforge.io). Both engines are
open source, extremely common, and each has one behaviour that silently breaks an Intune package.

**Inno Setup: `/VERYSILENT` REBOOTS THE MACHINE BY ITSELF.** The documentation is explicit - with
`/VERYSILENT`, "if a restart is needed, it reboots automatically rather than prompting". Under Intune that
is a SYSTEM-context reboot with no warning to the signed-in user, mid-workday. **Always pass `/NORESTART`
alongside it.** Then use the lever that makes this properly manageable:

- **`/RESTARTEXITCODE=<code>`** makes Setup return a code of your choosing when a restart is required.
  Combine `/NORESTART /RESTARTEXITCODE=3010` and Inno reports exactly what Intune already understands as
  "soft reboot" - instead of either rebooting on its own or hiding the fact that it needed one.
- `/SUPPRESSMSGBOXES` is ignored unless `/SILENT` or `/VERYSILENT` is also present.
- `/SP-` only suppresses the "This will install..." startup prompt - it is not a silent switch.
- `/CLOSEAPPLICATIONS` / `/FORCECLOSEAPPLICATIONS` drive Inno's own restart-manager handling. PSADT already
  closes processes via `Show-ADTInstallationWelcome -CloseProcesses`; adding
  `/NOCLOSEAPPLICATIONS` keeps the two from fighting over the same files.
- `/LOADINF` / `/SAVEINF` record and replay wizard answers - the Inno equivalent of an InstallShield `.iss`,
  and the clean way to capture a complex option set once instead of guessing `/COMPONENTS` strings.
- `/COMPONENTS` / `/TASKS` take comma-separated names, `*` includes children, `!` deselects. `/MERGETASKS`
  adds to the defaults instead of replacing them.

**NSIS: `Uninstall.exe /S` returns BEFORE the uninstall has finished.** By default the uninstaller copies
itself to a temp directory and re-launches from there so it can delete its own install folder - the process
you started exits immediately. A Post-Uninstall step that then verifies the folder is gone, or the session
closing, races a still-running uninstall. The documented fix:

```
Uninstall.exe /S _?=C:\Program Files\<App>
```

`_?=` sets the install directory AND suppresses the copy-to-temp, so the process runs to completion
synchronously. Like `/D`, it must be the LAST parameter and must not be quoted - even when the path contains
spaces. Note the side effect: because it no longer relocates itself, `Uninstall.exe` remains on disk and
must be removed by the package afterwards.

- **`/D=<path>` must be last and unquoted**, absolute only - quoting it is the usual reason a "silent"
  NSIS install lands in the default directory anyway.
- **`/NCRC`** skips the CRC check, unless the script used `CRCCheck force` - in which case the flag is
  ignored rather than honoured.

**NSIS MultiUser (`MultiUser.nsh`): a bare `/S` aborts instantly and installs nothing.** A large and
growing share of NSIS installers are built with the MultiUser plugin so one installer can target either
scope. When the script defines `MULTIUSER_INSTALLMODE_COMMANDLINE`, running it silently WITHOUT an
explicit scope switch fails the command-line validation in `.onInit` and the process exits immediately -
typically well under a second, before a single file is written, with **no stdout and no stderr at all**
regardless of window mode.

- **Fix:** pass `/allusers` (machine-wide) or `/currentuser` (per-user) alongside `/S`. Default to
  **`/allusers`** for an Intune System-context deployment; use `/currentuser` only when the app is
  deliberately per-user. Case matters for the bare `/S` only (L.2), not for the mode switch.
- **This is the tell:** an installer confirmed as genuine NSIS (L.1) that nevertheless fails
  near-instantly under `/S` alone, with no captured output and no partial install artefacts, is very
  likely MultiUser-gated. Confirm behaviourally with `/S /allusers` before concluding the switch table's
  plain `/S` is wrong for that build.
- **`/currentuser` installs are invisible to a `C:\Program Files\...` detection rule by design** - they
  land under the user's own profile. If `/currentuser` is chosen, the detection rule has to look there.
  Do not read "nothing under Program Files" as a failed install without checking for exit code 0 first.

> Measured 2026-09-11 on one vendor's installer: an instant, output-free failure reproduced identically
> under SYSTEM, under a fully interactive admin session, and via a raw scheduled task that bypassed
> PSADT entirely - which rules out account, session and window creation and leaves the missing switch.
> The observed exit code was `666660`. Treat the exact number as one data point, not as a signature:
> MultiUser scripts are free to choose their own abort code. The reliable signature is the SHAPE -
> genuine NSIS, sub-second exit, no output, nothing written.

### L.8 MSIX / AppX - staging vs registration, and why SYSTEM breaks the obvious call

Verified against Microsoft Learn and against the live cmdlets (`Get-Command`, Windows 11 26200) on 2026-09-08.
MSIX is NOT a Win32 installer with different switches - it is a different deployment model, and every trap
below follows from that.

**First decision: usually do NOT wrap it in PSADT.** Intune takes `.msix` / `.msixbundle` / `.appx` /
`.appxbundle` natively as a **Line-of-business app**: no silent switches to research, no detection rule to
author, no `.intunewin` - name, publisher and version are read out of the manifest, and the install command is
standardised. Reach for a PSADT wrapper only when the deployment needs work the native type cannot do:

- close running processes first (`Show-ADTInstallationWelcome -CloseProcesses`),
- remove a legacy MSI/EXE version of the same product,
- import the signing certificate into a machine store (Appendix N),
- write per-machine configuration (registry policy, config file, ACLs),
- ship framework dependency packages the estate does not already have,
- or the package is **larger than 8 GB** - the cap for Windows LOB / AppX / MSIX apps, whereas a Win32
  `.intunewin` may be up to 30 GB.

A public Store app is neither of these: use Intune's **Microsoft Store app (new)** type, not an LOB upload.

**The model: staging, then registration.** Only the first step is machine-wide.

1. **Staging** copies the package into `%ProgramFiles%\WindowsApps`. Happens once, needs no user account, and
   works against an offline `.wim`/`.vhd(x)` as well as a running OS.
2. **Registration** is per user and happens at that user's logon, performed by the App Readiness Service: user
   app data, file type associations, Start menu entries. **Only users the package is registered for can see or
   run it.**

**The SYSTEM trap - the single most important line in this section.** Under Intune (and therefore under the
Phase 6 SYSTEM test) the deployment runs as SYSTEM:

- `Add-AppxPackage` registers the package **for the calling user**. As SYSTEM that means registered for the
  SYSTEM account. No interactive user ever gets the app - and the call **succeeds**, so the package reports
  install success while nobody can launch anything.
- The machine-wide call is **`Add-AppxProvisionedPackage -Online`** (DISM module). It stages the package and
  arms auto-registration for every user at their next logon.

```powershell
Add-AppxProvisionedPackage -Online -PackagePath "$dirFiles\App.msixbundle" `
    -DependencyPackagePath "$dirFiles\VCLibs.appx", "$dirFiles\WinAppSDK.msix" -SkipLicense
```

- **`-SkipLicense` vs `-LicensePath`:** a license is required ONLY for a Microsoft Store app (and those must be
  free and configured as pre-installable in Partner Center). Every other package provisions without one.
- **`-DependencyPackagePath` is not optional in practice.** Framework packages (VCLibs, .NET Native, WinAppSDK)
  must be supplied; a missing framework is the normal reason provisioning fails on a freshly imaged device, and
  it is not visible from the app package alone. Collect them in Phase 2, not at failure time.
- Parameter names verified on the live cmdlet: `-PackagePath`, `-DependencyPackagePath`, `-OptionalPackagePath`,
  `-LicensePath`, `-SkipLicense`, `-Regions` (plural), `-StubPackageOption`.

**Detection: `Get-AppxPackage` is the WRONG cmdlet, and it fails silently.** Immediately after provisioning the
package is staged and armed but registered for **nobody**. A detection script running as SYSTEM that calls
`Get-AppxPackage -Name X` finds nothing, Intune concludes "not installed", and reinstalls on every check-in
forever while the app is in fact working for every logged-on user.

- Device context -> `Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq '<Name>'`, compare
  `Version`.
- Machine-wide registration truth -> `Get-AppxPackage -AllUsers` (needs elevation).
- Plain `Get-AppxPackage` is correct ONLY for a genuinely per-user install evaluated in that user's context.

**Uninstall is asymmetric.** Microsoft's own wording for `Remove-AppxProvisionedPackage`: *"App packages will
not be installed when new user accounts are created. Packages will not be removed from existing user
accounts."* So an Uninstall hook that only de-provisions leaves the app fully working for every user who has
already logged on - and detection (if written correctly against the provisioned state) will even report it
gone. A complete uninstall is BOTH calls:

```powershell
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq '<Name>' |
    Remove-AppxProvisionedPackage -Online
Get-AppxPackage -AllUsers -Name '<Name>' | Remove-AppxPackage -AllUsers
```

`Remove-AppxProvisionedPackage` does carry an `-AllUsers` switch, but Learn documents it in four words
("Execute the command to all users") with no stated semantics - do not build an uninstall on it; use the
explicit pair above. `Remove-AppxPackage -PreserveApplicationData` is the MSIX equivalent of the skill's
"keep user data by default" rule. A normal uninstall removes everything the package wrote - the `WindowsApps`
folder plus the AppData and registry inside its container - but never user-created files.

**Signing: mandatory, and the publisher must match exactly.**

- Windows requires every MSIX to be signed, and the certificate must chain to a root the device trusts.
- Documented hard requirement: *"the 'Subject' in the certificate must match the 'Publisher' section in your
  app's manifest."* With `<Identity Publisher="CN=Contoso Software, O=Contoso Corporation, C=US"/>` the cert
  Subject must be that exact string. **Consequence: you cannot simply re-sign a vendor MSIX with a corporate
  certificate** - the manifest Publisher must be edited and the package repacked, which changes its identity.
- Signing a bundle covers every package inside it; inner packages need no separate signature.
- **Self-signed / internal CA: the certificate must be imported into `Cert:\LocalMachine\TrustedPeople`.** That
  is the same machine-store problem as Appendix N and has the same answer: the built-in Intune "Trusted
  certificate" template only handles Root/Intermediate, so TrustedPeople needs a **Custom OMA-URI** profile
  (`./Device/Vendor/MSFT/RootCATrustedCertificates/TrustedPeople/<SHA1>/EncodedCertificate`, single-line
  base64). Own the certificate in exactly ONE place - the policy or the package, never both.
- **Timestamping decides what happens after the certificate expires.** Not timestamped + expired cert = the
  package **fails to install**; timestamped + expired = it still installs, because the signature is validated
  against signing time. Already-installed apps keep running either way. "It installed fine last year and now
  fails on new devices, and we changed nothing" is the classic symptom of a missing timestamp.
- **Sideloading** has been on by default since Windows 10 2004, but an enterprise can still disable it by
  policy - check that before blaming the package.
- `Add-AppxPackage` exposes `-AllowUnsigned`. It is a developer switch; an unsigned package has no integrity
  protection and must never be a deployment route.
- A signed package additionally enables integrity enforcement when the manifest declares
  `uap10:PackageIntegrity` (Windows 2004+): a tampered package is blocked from launching and sent through a
  repair workflow.

**Identity, updates, removal behaviour.**

- Identity is the **Package Full Name**: `Name_Version_Arch__PublisherHash`, e.g.
  `Contoso.ContosoApp_44.20231.1000.0_neutral__8wekyb3d8bbwe`. Provisioning cmdlets address packages by this
  name, not by a display name.
- MSIX supports a **downgrade without uninstalling first** when the App Installer file sets
  `ForceUpdateFromAnyVersion` - the documented way to pull back a bad build.
- `UpdateBlocksActivation` marks an update critical: the app will not start until it is updated.
- Since Windows 10 2004 **re-provisioning reinstalls** a package a user had removed; older builds refused.
- AppLocker can allow or deny MSIX apps by publisher, product name, file name, file version, path or hash.

### L.9 App-V - the support position, corrected

Verified against Microsoft Learn on 2026-09-08. **"App-V is end of life" is the claim you will hear, and it is
wrong.** The precise position:

- The **client and sequencer are no longer deprecated.** They moved to a **fixed extended support** lifecycle:
  they keep shipping as part of Windows, **there is no new end-of-support date**, and pricing does not change.
  What you do not get is design changes or new features - only bug and security fixes.
- The **server components remain deprecated, and their support ends April 2026** (MDOP extended support ends
  **14 April 2026**). Server-side alternatives: App-V app attach on Azure Virtual Desktop (no server of your
  own), or a non-Microsoft publishing server against the existing packages.
- Microsoft's own answer to "should I migrate?": *"If the current feature set of App-V works for you, there's
  no need to migrate away."*

Practical reading: an existing App-V estate is not an emergency and does not justify a rushed repackaging
project. A **new** virtualisation project should not start on App-V, because it will never gain a feature.

**Deploying an App-V package through PSADT.** The client is an optional Windows feature and must be enabled
first (Appendix P covers feature packages). Then:

```powershell
Add-AppvClientPackage '<path>\App.appv' | Publish-AppvClientPackage -Global
```

- **`Add-AppvClientPackage` only adds the package - it publishes to nobody.** Learn states this explicitly.
  Stopping after the add is the App-V twin of the `Add-AppxPackage`-as-SYSTEM mistake in L.8: no error, no app.
- **`-Global` is the device-context switch** (published to any user on the computer). Without it the package is
  published to the calling user only - under SYSTEM, again useless.
- `Mount-AppvClientPackage` loads the package fully onto the client instead of streaming it - do this in the
  install hook when the app must work offline.
- Uninstall needs both halves: `Unpublish-AppvClientPackage` (removes the entitlement, package stays on the
  machine) then `Remove-AppvClientPackage` (removes it from the machine).
- **Pending state - the trap that makes a deployment look successful and change nothing.** A cmdlet that
  touches a package currently **in use** does not fail; the task goes *pending*, and `Get-AppvClientPackage`
  then reports `UserPending` / `GlobalPending` = True. A user-scoped pending task applies after the next
  logoff/logon; a **global** one only after a **shutdown and restart**. So a `-Global` publish or upgrade of a
  running app has NOT taken effect when the hook returns. Close the processes first
  (`Show-ADTInstallationWelcome -CloseProcesses`) or the package silently does nothing until a reboot.
- A package name containing `$` must be single-quoted: `Add-AppvClientPackage 'Contoso$App.appv'`.
- `Set-AppvClientConfiguration -RequirePublishAsAdmin 1` restricts publishing/unpublishing to administrators.

**Conversion to MSIX** is done with the **MSIX Packaging Tool** (App-V is one of its documented input formats,
and batch conversion of App-V 5 packages is a published path); Learn also carries a feature-by-feature App-V vs
MSIX comparison. Treat a conversion as a project with a test phase, not a format change: App-V was typically
chosen for applications with deep system integration, and the MSIX container does not host everything such an
application may rely on. Verify the converted package behaves identically before retiring the App-V one.

---

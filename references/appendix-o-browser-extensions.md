# Appendix O: Browser extension force-install packages (opt-in)

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Contents

- [O.1 The model](#o1-the-model)
- [O.2 Phase-2 research (replaces the silent-switch research)](#o2-phase-2-research-replaces-the-silent-switch-research)
- [O.3 Registry reference (verbatim - get these wrong and it silently fails)](#o3-registry-reference-verbatim---get-these-wrong-and-it-silently-fails)
- [O.4 Generate the package (one call, in-process)](#o4-generate-the-package-one-call-in-process)
- [O.5 Extensions helpers (merge + selective remove)](#o5-extensions-helpers-merge--selective-remove)
- [O.6 Hooks](#o6-hooks)
- [O.7 Detection + Intune wiring](#o7-detection--intune-wiring)
- [O.8 Dossier additions](#o8-dossier-additions)
- [O.9 Anti-patterns](#o9-anti-patterns)

## Appendix O: Browser extension force-install packages (opt-in)

A distinct, recurring package type: deploy a **browser extension** to Edge / Chrome / Firefox. In the
enterprise these are not "installed" - you set **policy registry keys** and each browser pulls the extension
from its own store. So this is a **policy-only** package: no vendor installer, `Files\` empty, ESP-safe, no
reboot. It is **opt-in** (Gate 1 package-type choice), never the default for a normal app.

Generate the whole package in one call: **`scripts/New-BrowserExtensionPackage.ps1`** writes the launcher
(data model + 3 hooks), the Extensions module (4 merge/remove helpers) and the detection script.

### O.1 The model

| | |
|---|---|
| Source | **Online store force-install only** (Chrome Web Store / Edge Add-ons / Firefox AMO). Self-hosted CRX/XPI is out of scope. |
| Mechanism | Policy registry keys (O.3). Browser applies them on its next start; nothing is launched, no process closed. |
| Deployment types | Install = set keys (merge), Uninstall = remove ONLY own keys, Repair = re-apply (idempotent). |
| Coexistence | Multiple extension packages share the same policy keys - **merge**, never clobber; remove only own entries (O.5). |
| Detection | Verifies the **policy is set** (registry), NOT that the browser actually loaded the extension (O.7). |

### O.2 Phase-2 research (replaces the silent-switch research)

Find the extension in each store the customer uses and capture the per-store ID:
- **Chrome Web Store** - ID = 32 chars `a-p`, from the URL `.../detail/<slug>/<ID>`.
- **Edge Add-ons** - ID = 32 chars `a-p`, from `microsoftedge.microsoft.com/addons/detail/<slug>/<ID>`. (Edge can also load Chrome Web Store IDs if the org allows other stores; default is the Edge ID.)
- **Firefox AMO** - ID = `name@domain` or a GUID (from the listing / the `.xpi` manifest), PLUS the **AMO slug** (`addons.mozilla.org/.../addon/<slug>/`). The install_url is `https://addons.mozilla.org/firefox/downloads/latest/<slug>/latest.xpi`.

Set only the browsers that actually carry the extension. Not in a store -> it cannot be force-installed this way
(only self-hosted, which is out of scope) - say so.

### O.3 Registry reference (verbatim - get these wrong and it silently fails)

| Browser | HKLM path | Value | Type | Format |
|---|---|---|---|---|
| Chrome | `SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist` | index `"1","2",...` | `REG_SZ` | `"<id>;https://clients2.google.com/service/update2/crx"` |
| Edge | `SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist` | index `"1","2",...` | `REG_SZ` | `"<id>;https://edge.microsoft.com/extensionwebstorebase/v1/crx"` |
| Firefox | `SOFTWARE\Policies\Mozilla\Firefox` | `ExtensionSettings` | **`REG_MULTI_SZ`** | JSON `{"<id>":{"installation_mode":"force_installed","install_url":"https://addons.mozilla.org/firefox/downloads/latest/<slug>/latest.xpi"}}` |

- **Firefox MUST be `REG_MULTI_SZ`.** A single-line `REG_SZ` is silently ignored by current Firefox
  (Mozilla bug 1750233). In PowerShell: `New-ItemProperty -PropertyType MultiString`.
- **Chrome/Edge values are keyed by index NAME but matched by VALUE.** The browser only reads the values, not
  the names - so the index is just a unique label.
- **Removing a Chrome/Edge forcelist entry makes the browser auto-uninstall the extension** - that IS the
  uninstall path. Firefox: remove the id from the JSON.
- HKLM policy keys are not WOW-redirected -> run detection 64-bit (Run as 32-bit = No).

### O.4 Generate the package (one call, in-process)

`-Extensions` is an array of hashtables, so call the generator **in-process** (not `pwsh -File`, which
stringifies the array):
```powershell
$exts = @(
    @{ Name='uBlock Origin'
       Edge   = @{ Id='odfafepnkmbhccpbejgmiehpchacaeak' }
       Chrome = @{ Id='cjpalhdlnbpafiamejdnhcphjbkeiagm' }
       Firefox= @{ Id='uBlock0@raymondhill.net'; Slug='ublock-origin' } }   # Slug -> AMO install_url is derived
    @{ Name='1Password'
       Edge   = @{ Id='dppgmdbiimibapkepcbdbmkaabgiofem' }
       Chrome = @{ Id='aeblfdkhhhdcdjpifhhbdiojplfjncoa' } }                 # Edge+Chrome only (no Firefox set)
)
& scripts/New-BrowserExtensionPackage.ps1 -Name 'BrowserExtensions-Standard' `
    -AppName 'Browser Extensions (Standard Set)' -Extensions $exts
```
The data model lands at the top of `Invoke-AppDeployToolkit.ps1` as `$script:BrowserExtensions` (the single
source of truth for all three hooks AND the detection script). Each entry sets at least one browser; Firefox
takes either `Slug` (install_url derived) or an explicit `InstallUrl`.

### O.5 Extensions helpers (merge + selective remove)

Written into `PSAppDeployToolkit.Extensions.psm1`:
- `Set-ADTChromiumForcelistEntry -Browser Edge|Chrome -ExtensionId <id>` - reads ALL existing values, **next
  free numeric index** (never hard-codes `1`), idempotent (skips if the id is already present), foreign entries
  untouched.
- `Remove-ADTChromiumForcelistEntry -Browser Edge|Chrome -ExtensionId <id>` - deletes only the value whose data
  is `"<id>;..."`.
- `Set-ADTFirefoxExtensionSetting -ExtensionId <id> -InstallUrl <xpi>` - reads `ExtensionSettings`
  (`REG_MULTI_SZ` -> join lines -> `ConvertFrom-Json`), merges the id as `force_installed`, writes back as
  `REG_MULTI_SZ`.
- `Remove-ADTFirefoxExtensionSetting -ExtensionId <id>` - removes the id from the JSON; deletes the whole value
  when it becomes empty. (Emptiness is tested via `ConvertTo-Json` == `{}`, NOT `PSObject.Properties.Count` - a
  PSCustomObject reports a phantom empty-named property after the last note property is removed.)

### O.6 Hooks

Install loops the data model and calls the matching `Set-` helper per browser; Uninstall calls the `Remove-`
helpers; Repair re-applies (idempotent). No `Show-ADTInstallationWelcome`/process-close (policy-only). Generated
for you - do not hand-roll.

### O.7 Detection + Intune wiring

`Detect-<Name>.ps1` embeds the same data model and checks every managed entry is present (forcelist contains
`"<id>;*"`; Firefox JSON has the id with `installation_mode=force_installed`). Contract: stdout + `exit 0` when
ALL present; no output + `exit 0` otherwise.

**Honest model:** detection proves the **policy is set**, not that each browser/profile has actually downloaded
the extension (that is online + per-user and outside the package's control). Do NOT write a detection that
claims "extension installed".

Intune: Install behavior **System**; `-DeployMode Silent`; detection = **script rule**, Run as 32-bit = No; no
reboot; ESP-safe (fast, registry-only). Pre-flight (Phase 5) passes unchanged - the acid-test sees the three
hooks + all four helpers called.

### O.8 Dossier additions

Reuse the standard `$meta` fields - no new template tokens:
- `DescMdDe/En`: list the managed extensions and which browsers each targets; note "managed by your
  organization" appears in the browser.
- `RuleFormat` / detection note: "policy present (registry); the browser pulls the extension from its store -
  requires network + store reachability."
- `DependenciesNote`: none (the extension is fetched online by the browser).

### O.9 Anti-patterns

- Firefox `ExtensionSettings` as `REG_SZ` (silently ignored) - it MUST be `REG_MULTI_SZ`.
- Clobbering the whole forcelist key / overwriting `ExtensionSettings` instead of merging - destroys other
  packages' extensions. Always next-free-index / JSON-merge, and remove ONLY own entries.
- Hard-coding forcelist index `1` - collides with other extension packages.
- Detection that asserts the extension is installed in the profile (it can only assert the policy is set).
- Self-hosted CRX/XPI dressed up as "store force-install" - different mechanism, out of scope here.

---

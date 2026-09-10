# Appendix Q: Third-party drivers (classification, pnputil staging, trust)

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Contents

- [Q.1 Decision tree](#q1-decision-tree)
- [Q.2 Building the package](#q2-building-the-package)
- [Q.3 pnputil](#q3-pnputil)
- [Q.4 Detection](#q4-detection)
- [Q.5 Drivers bundled inside a vendor installer](#q5-drivers-bundled-inside-a-vendor-installer)
- [Q.6 Anti-patterns](#q6-anti-patterns)

## Appendix Q: Third-party drivers (classification, pnputil staging, trust)

A driver is the case where "it installed fine on my machine" is worth the least. Windows decides twice
whether it accepts a driver, and the two decisions have nothing to do with each other:

1. **PnP installation** - may this package be added to the DriverStore and bound to a device? Satisfied by
   a trusted publisher, which is why importing the signer certificate into `TrustedPublisher` removes the
   "install device software?" prompt.
2. **Code Integrity** - may this kernel image load? With Secure Boot on (Windows 10 1607+, Windows 11) only
   a Microsoft **Dev-Portal** signature satisfies this. `TrustedPublisher` does nothing for it.

Confusing the two is the most expensive mistake in this area: the driver installs, the deployment reports
success, and the device never loads it.

### Q.1 Decision tree

Run the classifier first - always, and before anything is scaffolded:

```powershell
pwsh scripts/Get-DriverSignatureInfo.ps1 -Path 'D:\src\<driver folder>'
```

It reads each INF's `[Version]` section and checks the signature of the **catalog** (`.cat`), not the
`.sys`: a dual-signed `.sys` reports only its primary signature, and the catalog is what PnP validates
anyway. Then:

| Classification | Signer | Kernel mode | Verdict | What to do |
|---|---|---|---|---|
| `MicrosoftSigned` | `CN=Microsoft Windows Hardware Compatibility Publisher` (WHQL / Attestation) or inbox `CN=Microsoft Windows*` | either | GREEN | Nothing. Stage it with pnputil, `-CertOwner none`. |
| `VendorSigned` | valid, non-Microsoft | **user** | YELLOW | TrustedPublisher route: own the signer certificate in ONE place (`-CertOwner policy` or `package`). |
| `VendorSigned` | valid, non-Microsoft | **kernel** | **RED** | Ask the vendor for a Dev-Portal-signed driver. TrustedPublisher will NOT make it load under Secure Boot. `-AssumeSecureBootOff` downgrades this to a warning - only for a fleet that genuinely runs without Secure Boot, and the reason is recorded in `driverTrust`. |
| `Unsigned` | no `.cat`, `NotSigned`, `HashMismatch` | either | **RED, hard stop** | Three honest options only: a signed driver from the vendor, vendor-side Attestation signing via Partner Center, or an isolated lab. The skill never enables `testsigning` and never disables integrity checks. |

The documented exceptions to the Secure Boot rule - and the reason `-AssumeSecureBootOff` exists at all -
are in-place-upgraded machines, fleets with Secure Boot off, and drivers cross-signed before 2015-07-29.
All three are real; none of them is an assumption a script may make for you.

### Q.2 Building the package

```powershell
pwsh scripts/New-DriverPackage.ps1 -Name 'Mobotix-PrinterDriver-3.1.4' `
    -AppName 'Mobotix Printer Driver' -AppVendor 'Mobotix AG' -AppVersion '3.1.4' `
    -DriverSource 'D:\src\mobotix-printer'
```

The generator classifies before it scaffolds (a rejected source leaves no half-package behind), defaults
`-CertOwner` from the classification, and writes `package.type='driver'` plus the whole `driverTrust`
decision into the manifest. `-CertOwner`:

- `policy` - an Intune Custom OMA-URI profile owns the certificate (recommended: transparent, survives
  re-imaging, visible to whoever inherits the fleet). Build it with `New-IntuneTrustedCertPolicy.ps1` and
  assign it to the **same scope** as the app.
- `package` - the pre-install hook imports the certificate, the uninstall hook removes it again.
- `none` - Microsoft-signed, nothing to import.

Own it in exactly ONE place. Two owners fight: the package removes the certificate on uninstall and the
policy puts it back on the next sync.

### Q.3 pnputil

Install stages **every INF individually**:

```powershell
pnputil /add-driver "<path>\driver.inf" /install
```

The collective form (`/add-driver *.inf /subdirs /install`) exists and is tempting for a multi-INF package,
but Microsoft documents its aggregate exit code as unreliable - "one of six INFs failed and the batch
returned 0" is the worst outcome available for a driver, so the generator loops instead.

| Code | Meaning | Treatment |
|---|---|---|
| `0` | added, and installed on matching devices | success |
| `259` | `ERROR_NO_MORE_ITEMS` - no matching device present, or the device already uses a newer driver. The package IS staged. | success (this is what a driver package is for) |
| `3010` | staged, reboot required | success + `SetExitCode(3010)` so Intune sees a soft reboot |
| `0xE000022F` | `ERROR_NO_CATALOG_FOR_OEM_INF` - unsigned, or the `.cat` is missing | failure; the classifier should have caught this first |
| `0xE0000247` | `ERROR_DRIVER_STORE_ADD_FAILED` - generic; in practice an untrusted publisher | failure; check the certificate owner |

**Not yet verified here:** these codes are documented per Microsoft. Confirm them against
`C:\Windows\INF\setupapi.dev.log` on a DEV VM with a real vendor-signed and a real Microsoft-signed driver
before relying on the exact semantics.

Uninstall resolves the DriverStore name instead of guessing it:

```powershell
pnputil /enum-drivers        # -> Published Name: oemNN.inf + Original Name + Provider + Version
pnputil /delete-driver oemNN.inf /uninstall /force
```

Windows renames every third-party INF to `oemNN.inf`, and the number depends on the target machine's
history. Deleting `oem12.inf` because it was `oem12.inf` on the build machine removes **some other
vendor's driver**. Always match on Original Name (+ Provider and Version), then delete what was found.

### Q.4 Detection

```powershell
Get-WindowsDriver -Online          # third-party drivers only, without -All
```

`OriginalFileName` is the **full DriverStore path**, so compare `Split-Path -Leaf` against the INF name -
comparing the whole path never matches. Needs elevation, which a SYSTEM detection script has. Installed =
every INF of the package is staged; then stdout + `exit 0`. Not installed = no output and **still**
`exit 0`, because Intune reads a non-zero exit as a detection error rather than as "absent".

### Q.5 Drivers bundled inside a vendor installer

The common real case (a vendor EXE that calls dpinst internally, e.g. the install4j case in L.1): the
prompt appears in the middle of someone else's installer, where no hook can reach it. Fixed tree:

1. Extract the installer's content and run the classifier on it.
2. `MicrosoftSigned` -> **pre-stage** the drivers with pnputil in Pre-Install, then run the installer. Its
   internal dpinst call finds the driver already in the store and prompts for nothing.
3. `VendorSigned` -> certificate first (Appendix N policy, or a pre-install import), then pre-stage, then
   run the installer.
4. `Unsigned` -> stop. There is no packaging trick for this.

### Q.6 Anti-patterns

- Enabling `testsigning` or `nointegritychecks` on a production machine. This weakens every driver check on
  the device, permanently, for one app. The skill never does it and never suggests it.
- Running `dpinst /q` and not checking the exit code - it happily reports success for drivers it did not
  install.
- Deleting `oemNN.inf` by an index remembered from another machine.
- Trusting the exit code of a collective multi-INF call.
- Selling `TrustedPublisher` as the fix for an unsigned driver (it is not - there is nothing to trust) or
  for a kernel driver under Secure Boot (it silences the prompt and the driver still will not load).
- Owning the certificate in both the package and a policy.

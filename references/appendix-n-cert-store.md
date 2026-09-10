# Appendix N: Certificate store deployment (driver-trust / TrustedPublisher etc.)

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Appendix N: Certificate store deployment (driver-trust / TrustedPublisher etc.)

When a package needs a certificate in a Windows **machine** certificate store, treat it as a first-class
deliverable - never an afterthought hidden inside the install hook. The classic trigger: an EXE/MSI that stages a
**third-party driver** (printer, label/card printer, scanner, USB device) makes Windows pop
**"Would you like to install this device software?"** under SYSTEM/Intune that you cannot click - so the silent
install stalls or the driver part fails. The fix is to pre-trust the driver publisher's **code-signing**
certificate in **`LocalMachine\TrustedPublisher`**. Same machinery covers Root/CA/TrustedPeople.

### N.1 Which mechanism for which store

| Target store | Mechanism |
|---|---|
| Root, Intermediate (CA) | Intune built-in **Trusted certificate** profile (template) - OR the CSP below |
| **TrustedPublisher**, **TrustedPeople** | **ONLY** the `RootCATrustedCertificates` CSP via a **Custom OMA-URI** profile. The built-in template canNOT target these. |

Do NOT claim "Intune can't do TrustedPublisher" - it can, just not via the template. The CSP is the answer.

### N.2 The recipe (what the skill prepares from itself)

1. **Get the cert.** A raw cert file (`.cer/.crt/.der`) loads directly; for a driver, extract the **Authenticode
   signer** from any signed payload file (the MSI, `Setup.exe`, a `.cat`/`.sys`/`.dll`). The signer subject must
   match the publisher shown in the Windows device-software prompt.
2. **Single-line base64** of the DER bytes - `[Convert]::ToBase64String($cert.RawData)`. **NO line breaks / no
   PEM headers** - the CSP rejects formatted base64 with **`0x87d1fde8`**.
3. **OMA-URI:** `./Device/Vendor/MSFT/RootCATrustedCertificates/<Store>/<SHA1-Thumbprint>/EncodedCertificate`
   - Thumbprint uppercase, hex only. It MUST match the cert in the value, or the CSP errors `0x87d1fde8`.
   - Data type **String**, value = the single-line base64.
4. An **expired** signing cert still works: the driver signature is timestamped, and TrustedPublisher matches by
   certificate identity, not validity date.

`scripts/New-IntuneTrustedCertPolicy.ps1` does all of this: pass `-CertPath <cert-or-signed-file>` (or
`-Thumbprint`), `-Store TrustedPublisher`. Dry-run prints the OMA-URI, the base64 length, and the manual portal
steps; `-Execute` creates the Custom profile via Graph.

### N.3 Ownership: policy OR package - exactly one

Pick ONE owner of the cert; never both (the package would remove it on uninstall while the policy re-adds it at
the next sync - they fight).

| Owner | How | Trade-off |
|---|---|---|
| **Intune policy (recommended, transparent)** | `New-IntuneTrustedCertPolicy.ps1` / Custom OMA-URI profile, assigned to the SAME device scope as the app | Visible config, separate lifecycle. First install can race the profile - the cert is device-wide + persistent, so Intune's app retry succeeds once the profile has applied. |
| **Package (script)** | `Import-Certificate -FilePath <cer> -CertStoreLocation Cert:\LocalMachine\TrustedPublisher` in the install hook, BEFORE the driver installer; remove it on uninstall | Guarantees the cert is present in the same session as the driver (no first-install race). But it is a "hidden" script action and couples cert lifecycle to the app. |

Surface this as a researched choice (it is NOT a default gate, but state the assumption + recommended option
and let the user redirect). Whatever the choice, still hand over the prepared OMA-URI + base64 in the dossier.

### N.4 Graph permission + manual fallback

Creating a configuration profile needs the Graph application role **`DeviceManagementConfiguration.ReadWrite.All`**
(full matrix: `references/app-registration.md` section 0). The upload app (`PSADT Intune Upload`) does not
carry it unless it was consented with `-IncludeConfigurationManagement`. Since 0.20.0 the script says so
**before** it writes - it reads the granted roles out of the app-only token and names the missing permission
instead of letting `-Execute` come back with a **403**. A delegated `-Interactive` sign-in carries no roles
claim (the user's Intune RBAC is not in the token), so there the tenant still has the last word and the
403-fallback below applies. Either grant the role (Global Admin) and re-run, or create it by hand:

1. **Devices > Configuration > Create > New policy**; Platform **Windows 10 and later**, Profile type
   **Templates > Custom**.
2. Name it (e.g. `Cert - <Publisher> -> TrustedPublisher`).
3. Add OMA-URI setting: **OMA-URI** = the path from N.2, **Data type** = String, **Value** = the single-line base64.
4. **Assign to the same device scope as the app**, then Create.

### N.5 Gotchas
- **Thumbprint/value mismatch -> `0x87d1fde8`.** The thumbprint in the OMA-URI must be the SHA1 of the exact cert
  in the value. Re-export both from the same source.
- **Line breaks in the base64 -> `0x87d1fde8`.** Single line only.
- **Assignment scope.** Assign the cert profile to the SAME group/scope as the app, or the silent driver install
  races a device without the trust.
- **One owner only** (N.3). If you ship the policy, do NOT also import the cert in the package, and vice-versa.

---

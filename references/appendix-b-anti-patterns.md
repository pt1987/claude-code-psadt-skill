# Appendix B: Anti-pattern list

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Appendix B: Anti-pattern list

1. **Em-dash/smart quote in double-quoted strings**. `"Repair failed — DB status [$status]."` kills the entire script.
2. **UTF-8 without BOM + special characters**. Write a BOM or stick to pure ASCII.
3. **v3 cmdlet names** (see 3.5).
4. **Top-level code outside try/catch**.
5. **Single check without retry for async state** (services after msiexec need 30-60s; do not trigger fallback delete actions on the first negative answer).
6. **Intune return codes left at default only**. Enter 60001 + 60008 as Failed.
7. **Reflexively bumping the install time**. 60 min is almost always right.
8. **Thinking "runs locally = runs in Intune"**. The acid test is 6.2 + 6.3.
9. **Mixed detection** (custom script + file rule in parallel).
10. **Extensions in the main script instead of in `PSAppDeployToolkit.Extensions`**.
11. **-o inside -c with IntuneWinAppUtil** - nested .intunewin.
12. **No stakeholder intake (Phase 1.2)** - the most common reason for "the installer doesn't do what I want" after 2 weeks.
13. **Identifying the installer engine from a lone string match, then never running it**. A coincidental `nsis`
    substring made an install4j installer look like NSIS -> `/S` hung on the language dialog. Confirm the engine by
    its definitive fingerprint (Appendix L.1) AND behaviorally verify the silent switch (run it once, timeout+kill,
    expect exit 0 with no dialog) before packaging.
14. **A trademark sign breaking a DisplayName filter** - `-match 'Name'` misses `Name(R)`, so uninstall finds
    nothing and silently no-ops. Use a tolerant regex (Appendix L.3).
15. **Shipping a driver/cert as a note instead of a deliverable**. If the installer stages a driver via dpinst,
    classify it (`Get-DriverSignatureInfo.ps1`) and make the trust decision a real artifact - a cert policy or
    a package import - instead of mentioning it in the dossier. Full decision tree: **Appendix Q**.
16. **`msiexec /a` against a file that lives INSIDE a package payload**. An administrative install, and
    especially one with `/p <msp>`, REWRITES the source MSI. Doing that to a bundled installer silently
    corrupts the package: the next install fails with `0x80091007` (`CRYPT_E_HASH_VALUE`) because the file no
    longer matches the hash its bundle validates it against. Copy the MSI out to a scratch folder first. Cost
    a 1.9 GB repackage plus a wasted sandbox run on 2026-09-08 (Appendix G).
17. **`-Include` together with `-LiteralPath -Recurse`**. PowerShell silently IGNORES the filter and returns
    EVERY file, so a count or a copy check reports a number that looks plausible and is wrong (281 "INF" for
    a tree holding 70). Use `-Filter '*.inf'`. There is no error and no warning - only a wrong answer.
18. **Comparing paths by string prefix when either side may be an 8.3 short name**. `%TEMP%` frequently
    resolves to `C:\Users\PATRIC~1\...` while a child process reports `C:\Users\PatrickTaubert\...`; a
    `StartsWith`/`-like` comparison of the two fails on the same directory. `Resolve-Path` does NOT expand
    the short form. Compare directory identity (`Directory.GetParent(x).Name`) instead of full-path strings.
19. **Trusting a stack trace's source PATH to identify the source TREE**. A PDB records where the build ran,
    not where the code lives now. Comparing the source file's mtime against the binary's mtime settles it in
    seconds - guessing from the path produced a wrong "the source differs" conclusion and a retracted
    analysis on 2026-09-08.

---

## B.9 The list SKILL.md used to carry

The control plane keeps only the five most expensive of these; the rest moved here rather than
being dropped. Several restate a rule from `references/conventions.md` in the form of the mistake
people actually make, which is worth keeping - one is the rule, the other is the symptom.

- v3 cmdlet names (`Execute-Process`, `Write-Log`, `Show-InstallationWelcome`, ...); any em-dash/smart-quote or
  other non-ASCII in a `.ps1` (comments too) without a UTF-8 BOM - the #1 encoding failure. Top-level code outside try/catch.
- GUID to `Start-ADTMsiProcess -FilePath` (Uninstall and Repair - Repair is the usual miss) -> 60001.
- Drivers: enabling `testsigning`/`nointegritychecks` (never - it weakens the whole device for one app);
  selling `TrustedPublisher` as the fix for an UNSIGNED driver or for a kernel driver under Secure Boot;
  deleting `oemNN.inf` by an index from another machine; trusting a collective multi-INF pnputil exit code.
- `-o` inside `-c`; not mapping 60001/60008 as Failed; "runs locally = runs in Intune" without the acid test;
  hand-rolling the pre-flight instead of `scripts/Invoke-PsadtPreflight.ps1` (its GREEN/RED verdict IS the gate).
- Shipping the PSADT default `AppIcon.png`/Banner as the logo; skipping or hand-assembling the dossier.
- Auto-imposing user/org choices on upload (category/featured/`notes`), or assigning groups when the user did
  not opt in at Gate 2; DELETING the older version instead of `-OnExisting CreateNewCoexist`.
- Hand-rolling the SYSTEM-test harness instead of `scripts/Invoke-PsadtSandboxTest.ps1` (App. G:
  `echo %ERRORLEVEL%>file` silently becomes the `0>` stdin redirection and writes an EMPTY file; file
  existence read as completion; `[string]$null` still `$null` in WinPS 5.1 - each cost a whole VM run).
- Probing a long-running job to find a bug that a two-second local check would have shown; issuing N
  sequential tool calls against one artefact instead of one script - for an MSI that script exists, it is
  `scripts/Get-PsadtMsiFacts.ps1`; running Phase 6 strictly after Phases 7-8 when they are independent;
  a three-agent research fan-out for an app whose vendor ships an official MSI (the MSI is the research).
- Hand-building a Wikimedia thumbnail URL (only pre-rendered widths are served - `1024px-` returns HTTP 400
  where `1280px-` works; take `thumburl` from the API verbatim) or guessing a Commons file name instead of
  searching the File namespace. Both cost time twice in one session; App. J now has them.
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

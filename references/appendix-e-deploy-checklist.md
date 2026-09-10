# Appendix E: Final deploy checklist

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Appendix E: Final deploy checklist

The item numbers follow the PHASE they belong to - the old 0.x/1.x scheme was a third numbering next to
the phases and the sections, and it drifted. The machine-readable form of this checklist is the manifest's
`results` block (`results.preflight`, `results.systemTest[]`, `results.package`, `results.upload`): if a
line here is green, the corresponding entry exists in `psadt-package.json`.

```
Phase 0 - Setup
[ ] 0.1  Initialize-PsadtSkill.ps1 GREEN or YELLOW (RED blocks everything else)
[ ] 0.2  Config home complete - no key left in .Missing

Phase 1-2 - Research + Intake
[ ] 1.1  PSADT version local == latest (or updated)
[ ] 1.2  Intake complete (app, installer, environment, security)
[ ] 1.3  Silent install AND uninstall switches documented -> research.switches

Phase 3 - Scaffold
[ ] 3.1  Generator used (MSI / browser extension / Windows feature), or New-ADTTemplate when none fits
[ ] 3.2  Folder layout complete
[ ] 3.3  Module version pinned in the scaffold
[ ] 3.4  psadt-package.json written, identity complete
[ ] 3.5  Launcher sets LogName (one log per run)

Phase 4 - Script customizing
[ ] 4.1  Installer in Files\
[ ] 4.2  $adtSession carries all metadata
[ ] 4.3  Install/Uninstall/Repair hooks filled in
[ ] 4.4  Custom helpers in PSAppDeployToolkit.Extensions, not in the launcher

Phase 5 - Pre-flight
[ ] 5.1  Encoding: BOM present OR non-ASCII count 0
[ ] 5.2  ParseFile PARSE_OK
[ ] 5.3  Launcher simulation green
[ ] 5.4  Param block in sync with the v4 template
[ ] 5.5  No v3 cmdlet remnants
[ ] 5.6  No top-level statements that can throw
[ ] 5.7  Manifest check PASS (check 8)
[ ] 5.8  Invoke-PsadtPreflight.ps1 GREEN -> results.preflight

Phase 6 - SYSTEM test (BINDING before upload)
[ ] 6.1  Install passes as SYSTEM, detection = installed
[ ] 6.2  Uninstall passes as SYSTEM, detection = not-installed
[ ] 6.3  Both runs in results.systemTest[], logs in artifacts.logs[]

Phase 7 - Build
[ ] 7.1  IntuneWinAppUtil current
[ ] 7.2  Invoke-PsadtPackage.ps1 used (never a hand-typed tool call)
[ ] 7.3  Artifact named <Vendor>_<App>_<Version>_<Arch>.intunewin -> artifacts.intunewin
[ ] 7.4  Detection.xml carries SetupFile=Invoke-AppDeployToolkit.exe -> results.package

Phase 8 - Intune config + dossier
[ ] 8.1  App info + real logo (never the PSADT default)
[ ] 8.2  Install/Uninstall command + install behaviour = System
[ ] 8.3  Return codes complete (incl. 60001 + 60008 = Failed)
[ ] 8.4  Requirements (OS, arch, disk, memory)
[ ] 8.5  Detection method UNAMBIGUOUS
[ ] 8.6  Install time realistic (-MaxRunTimeMinutes for long installs)
[ ] 8.7  Intune-Dossier.html generated from the manifest -> results.report

Phase 9-10 - Upload + assignment (opt-in)
[ ] 9.1  Capabilities.Upload verified BEFORE the upload (Test-PsadtIntuneAccess.ps1)
[ ] 9.2  Dry run reviewed, then -Execute -> results.upload
[ ] 10.1 Group assignment only if chosen at Gate 2 and intune.groups.enabled

Phase 11 - Test
[ ] 11.1 Direct invoke on DEV
[ ] 11.2 Launcher invoke on DEV
[ ] 11.3 psexec -s on DEV
[ ] 11.4 Test-group deploy -> PSADT log + Close-ADTSession Exit 0

Phase 12 - Rollout
[ ] 12.1 Pilot (24-48h)
[ ] 12.2 Production, staged
[ ] 12.3 Vendor release watch subscribed
```

Only when ALL lines are green: production rollout.

---

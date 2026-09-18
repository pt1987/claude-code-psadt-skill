# What the ten-application run exposed

Found while measuring the run of 2026-09-18. None of it was fixed during the run: changing a generator or
a name token halfway through would have made the artefact names and the timings of the finished packages
inconsistent with the later ones, and the measurement was the point.

Four of these are defects in the skill. One is a packaging mistake the skill caught, which is worth
recording because the failure looks harmless. One is a gap rather than a fault.

## 1. The artefact stem drops `+` without replacing it

**Where:** `scripts/Get-PsadtPackageManifest.ps1`, `ConvertTo-NameToken`.

```
'Notepad++'       -> strip [^A-Za-z0-9._-] -> 'Notepad__' -> collapse -> 'Notepad_' -> trim -> 'Notepad'
'Notepad++ Team'  ->                                                                        -> 'Notepad_Team'
```

The stem came out as `Notepad_Team_Notepad_8.9.8_x64`. That is not merely ugly. The stem is the folder
name, the file name and the `win32LobApp.fileName` in Intune all at once, so a package for Notepad++ now
reads as a package for the Notepad that ships with Windows, and two different products can collapse onto
one name.

**Proposal:** transliterate `+` to `Plus` before stripping, which matches how the vendor writes it itself
(the GitHub organisation is `notepad-plus-plus`). `'Notepad++'` becomes `NotepadPlusPlus`.

**Still to check:** whether other meaning-carrying characters are affected the same way (`#` in C#, `&`),
and whether a test in `tests/` already pins the current stem.

## 2. `Get-PsadtMsiFacts.ps1` does not return `Feature_Parent`

**Where:** `scripts/Get-PsadtMsiFacts.ps1`, the feature projection.

It returns `Feature, Title, Level, Attributes`. The MSI Feature table also has `Feature_Parent` and
`Display`, and `Feature_Parent` is precisely what an `ADDLOCAL` list needs: name a child without its
parent and the child does not install.

For VLC 3.0.23 the flat list made all nine features look like siblings. They are not:

```
VLC
+- WEBPLUGINS
|  +- ACTIVEX
|  +- MOZILLA
+- FILEASSOCIATION
|  +- VIDEOFILEASSOCIATION
|  +- AUDIOFILEASSOCIATION
|  +- OTHERFILEASSOCIATION
+- DISCSPLAYBACK
```

Without the hierarchy the obvious selection, everything except the browser plugins, could not be written
down without tearing a parent from its child. The parent had to be fetched with a hand-written COM query
against the Feature table, which is exactly the hand-rolled MSI probe that Appendix G already retired
once with the line that the second time you write a probe by hand it is not a probe, it is a missing
script.

**Proposal:** add `Feature_Parent` and `Display` to the projection, plus a regression test that pins a
multi-level feature hierarchy.

## 3. Pre-flight reports a helper as unused while it is being used

**Where:** `scripts/Invoke-PsadtPreflight.ps1`, the `Structure` check.

```
WARN Structure: extension helper Get-ADTGitForWindowsInstall is defined but never called by the launcher
```

The function is called. Just not by the launcher:

```
Invoke-AppDeployToolkit.ps1:133   Uninstall-ADTGitForWindowsNative
  -> Extensions.psm1:94             Get-ADTGitForWindowsInstall
```

The check looks for call sites in the launcher only and misses calls inside the extensions module. The
two-level shape, a resolver plus an action that uses it, is what the generator itself emits, so the false
alarm lands on the generator's own default output. It fired on all three EXE packages in this run: Git
for Windows, GIMP and Citrix Workspace App.

This is not cosmetic. The warning invites someone to "fix" or delete a correctly used helper, and it
blunts the WARN lines that are supposed to earn attention when something real appears.

**Proposal:** search the extensions module for call sites as well, not counting the definition itself,
and add a regression test with that resolver-plus-action shape.

## 4. The run that earned the gate: `REMOVE=` without `ADDLOCAL`

Not a skill defect. A packaging mistake, caught by the SYSTEM test, and the only red gate of the run that
pointed at a real problem. It belongs in the corpus because the failure signature is so quiet.

These properties went to msiexec for LibreOffice:

```
ISCHECKFORPRODUCTUPDATES=0 CREATEDESKTOPLINK=0 REBOOTYESNO=No UI_LANGS=de,en_US \
REMOVE=gm_o_Onlineupdate,gm_o_Quickstart
```

The intent was to keep the online updater and the quickstarter off the device in the first place.
`ADDLOCAL=ALL` was ruled out because it defeats `UI_LANGS`, and roughly 120 language packs would have
come along.

The gate answered:

```
Install exit code                          ok=True   exit=0
present after install : ...\soffice.exe    ok=False  exists=False
DetectionAfterInstall detected=True        ok=False  stdout=''
```

**Exit 0, and nothing installed.** `REMOVE=` without an accompanying `ADDLOCAL` or `ADDDEFAULT` turns a
first install into a removal transaction: Windows Installer selects no feature at all, runs the sequence
and reports success.

Without the SYSTEM test a package would have shipped that reports success and is empty. In Intune it
would have surfaced as a loop, install "successful" and detection negative on every cycle, and the hunt
would have started at the script rather than at the command line.

**Fixed in the package** by dropping `REMOVE` and turning the update check off with
`ISCHECKFORPRODUCTUPDATES=0`. The second gate run was green.

**Proposal for the skill:** a pre-flight check that fails RED on `REMOVE=` in the MSI arguments without
`ADDLOCAL=` or `ADDDEFAULT=`. It is statically decidable and it would have saved a VM run of more than
twenty minutes here. Plus a line in Appendix L.

## 5. The skill cannot measure itself

There is no instrumentation for phase durations anywhere in the skill. This run needed
`benchmark/bench.ps1` and `benchmark/New-BenchmarkReport.ps1` to exist before it could report anything,
and both were written from scratch while the first application was already being packaged.

The consequence shows in the corpus: Appendix G reports run times as prose taken from whatever happened
to be observed ("75 minutes of wall clock", "13 minutes 45 seconds end to end"), and phases-0-6.md has a
commit reading `docs: replace unverifiable run times with the recorded gate durations`, which is the same
problem being paid for a second time.

**Proposal:** promote the two scripts into `scripts/`, so that "how long does a package take" stays an
answerable question rather than an estimate.

## 6. Logo acquisition is entirely manual

Appendix J describes the route well: search the Wikimedia File namespace, take `thumburl` verbatim, check
a real corner pixel, square the result, fall back to the MSI icon table. There is no script for any of
it. Each application cost several tool calls, and three documented traps are written down but not guarded:

- Only pre-rendered thumbnail widths are served. A hand-built width returns HTTP 400.
- `IsAlphaPixelFormat` lies. Only a real corner pixel proves transparency. The 7-Zip logo came back
  opaque black and reported alpha support.
- A vendor ICO can be too small and an MSI need not carry an icon table at all. 7-Zip's `FM.ico` tops out
  at 48px and 7-Zip 26.03 has no Icon table; Temurin's MSI does, with a 256px frame, and it was the best
  source available for that application.

Two more things surfaced that Appendix J does not mention. The MSI icon export only works through the
direct COM call `$db.Export(...)`; going through `InvokeMember` fails with a type mismatch. And a correct
logo can still be the wrong choice: the LibreOffice wordmark is the right brand and unusable as a square
tile, so the main application icon had to be fetched instead.

**Proposal:** `scripts/Get-PsadtAppLogo.ps1` carrying exactly these checks.

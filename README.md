<h1 align="center">PSADT v4 → Intune Deployment Skill</h1>

<p align="center">
  <em>A Claude Code skill that drives the full lifecycle of a PowerShell App Deployment Toolkit (PSADT) v4.x Intune Win32 package - from first conversation to a tested, upload-ready <code>.intunewin</code>.</em>
</p>

<p align="center">
  <a href="https://github.com/pt1987/claude-code-psadt-skill/actions/workflows/tests.yml"><img src="https://github.com/pt1987/claude-code-psadt-skill/actions/workflows/tests.yml/badge.svg" alt="tests" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square" alt="License: MIT" /></a>
  <img src="https://img.shields.io/badge/PSADT-v4.x-0a7bbb?style=flat-square" alt="PSADT v4.x" />
  <img src="https://img.shields.io/badge/Platform-Windows-0078d6?style=flat-square&logo=windows&logoColor=white" alt="Windows" />
  <img src="https://img.shields.io/badge/Claude%20Code-Skill-d97757?style=flat-square" alt="Claude Code Skill" />
</p>

<p align="center"><sub><a href="#quick-start">Quick start</a> · <a href="#how-it-works">How it works</a> · <a href="#what-makes-it-different">What makes it different</a> · <a href="#go-deeper">Go deeper</a> · <a href="#security">Security</a> · <a href="#changelog">Changelog</a></sub></p>

---
<img width="3200" height="1637" alt="psadt-workflow" src="https://github.com/user-attachments/assets/6a0eff79-8165-4994-83e0-d2476f204ff8" />

## What is this?

A **Claude Code skill**: a reusable instruction package that teaches the agent how to build,
package, test, troubleshoot and deploy a **PSADT v4.x Intune Win32 app**. You name the application; the
skill runs the workflow - intake, research, scaffolding, all three deployment types
(Install / Uninstall / Repair), pre-flight checks, a SYSTEM test, packaging, the dossier, and the
optional Graph upload.

It loads progressively: the agent sees only the name and description until a task makes it relevant.

### What that looks like in practice

Three applications, none of them packaged here before, each taken to a `.intunewin` with a GREEN SYSTEM
gate on the first attempt. The times are the gate itself, read back from each run's `result.json`: all
five actions as `NT AUTHORITY\SYSTEM` in one throwaway sandbox, with the detection script evaluated
after every one of them.

| Application | Installer engine | SYSTEM gate | VM runs | Verdict |
|---|---|---|---|---|
| Audacity 4.0.0 | MSI | **3:11** | 1 | GREEN |
| draw.io 31.4.5 | NSIS / electron-builder | **4:19** | 1 | GREEN |
| VS Code 1.138.0 | Inno Setup | **6:12** | 1 | GREEN |

Those runs also produced the findings that make the packages correct: draw.io ships an MSI alongside the
EXE that installs **per-user** and would have vanished into the SYSTEM profile; Audacity regenerates its
MSI ProductCode on **every build**, so a ProductCode detection rule works exactly once; VS Code's
uninstaller hands back an exit code while a copy of itself is still deleting. The skill finds that kind of
thing before it ships, not after a helpdesk ticket.

## Quick start

```powershell
npx psadt-deploy-skill
```

Installs the skill into `~/.claude/skills/psadt-deploy` and runs the setup doctor, which provisions
everything it can and names the handful of values only you can supply. Then open Claude Code in any folder
and say what you want:

> *"Create the Win32 Intune package for 7-Zip 24.09"* - or *"package Notepad++ for Intune"*

The skill asks at most **four decision gates** (scope · deployment semantics · SYSTEM-test consent ·
upload confirmation). Everything else it researches and states as an assumption instead of asking.

Details, flags, version pinning and requirements: [`docs/installation.md`](docs/installation.md).

## How it works

Thirteen phases, each owned by a script rather than by prose, so a step either passed or did not:

| Phase | What happens | Owner |
|---|---|---|
| **0** Setup | 14 prerequisite checks, GREEN/YELLOW/RED, `-Fix` provisions | `Initialize-PsadtSkill.ps1` |
| **1-2** Intake + research | blocker questions as clickable options; a local-evidence ladder (installed here? binary here? already written down?) answers what it can, and a research agent is dispatched only per question it leaves open | agent (gates 1-2) |
| **3** Scaffold | a generator writes launcher + detection + per-run log name + manifest | `New-MsiPackage` · `New-ExePackage` · `New-BrowserExtensionPackage` · `New-WindowsFeaturePackage` · `New-DriverPackage` |
| **4** Customize | all three hooks filled from the research, helpers in the Extensions module | agent |
| **5** Pre-flight | 14 checks (encoding, AST parse, v3 cmdlets, structure, detection contract, manifest, log name, driver trust …) → GREEN/RED | `Invoke-PsadtPreflight.ps1` |
| **6** SYSTEM test | the whole loop in a throwaway Windows Sandbox, every action as **SYSTEM** like the IME does - no elevation, host untouched. **Binding before any upload** | `Invoke-PsadtSandboxTest.ps1` |
| **7** Package | one command → verified `.intunewin`, named after the app | `Invoke-PsadtPackage.ps1` |
| **8** Dossier | always, uploaded or not: bilingual self-contained HTML | `New-PsadtReport.ps1` |
| **9** Upload *(opt-in)* | dry run → confirm → `win32LobApp` via raw Graph | `Invoke-IntuneWin32Upload.ps1` |
| **10** Assignment *(opt-in)* | create/reuse Entra groups by naming scheme | `Invoke-IntuneAppAssignment.ps1` |
| **11-12** Test + rollout | real devices via a test group, pilot → staged production | agent |

**Everything one app knows lives in `<pkg>\psadt-package.json`** - identity, the decisions taken at the
gates, the research findings, every phase's result and the artifacts produced. The generators write it,
every later phase reads and updates it, and pre-flight fails without it. That is what stops two packages of
the same app from disagreeing about their own version.

## What makes it different

- **The installer engine is read from the binary**, not guessed from a filename - byte signatures in the
  PE overlay, resources and section table - and 19 engines' documented silent switches ship with the skill,
  offline. A candidate is still a claim until a run proves it.
- **The SYSTEM test is real.** Every action runs as `NT AUTHORITY\SYSTEM` through a scheduled task in a
  throwaway Windows Sandbox - the same context the Intune Management Extension uses - and the verdict is
  keyed on the detection script, the same rule Intune evaluates. No elevation on your machine, and the
  machine is never modified.
- **An uninstall has to prove it removed something.** Inno Setup and NSIS uninstallers return an exit code
  while a copy of themselves is still deleting; generated hooks wait for the application to disappear and
  fail loudly if it does not.
- **Nothing is deleted that you did not ask to delete** - not an older Intune app version, not a foreign
  `.intunewin`, not a group, not another app's assignment.
- **A dossier is produced every time**, uploaded or not: one self-contained bilingual HTML file with the
  return-code map, the detection rule, the hooks, the test results - and a ready-to-paste Company-Portal
  description.
- **968 Pester tests**, including drift guards that fail when the documentation and the code disagree -
  one of them reads the published landing page and compares its figures against this repository.

## Go deeper

| | |
|---|---|
| [**Website**](https://pt1987.github.io/claude-code-psadt-skill/) | the phase-by-phase walkthrough, the pre-flight checks, and the trap in each of the 19 installer engines |
| [`docs/installation.md`](docs/installation.md) | install flags, version pinning, requirements, manual clone |
| [`docs/features.md`](docs/features.md) | the complete feature list, package type by package type |
| [`docs/setup-and-structure.md`](docs/setup-and-structure.md) | first-run setup, config home, full project structure |
| [`SKILL.md`](SKILL.md) | the control plane the agent actually reads |
| [`references/README.md`](references/README.md) | the reference map: phases 0-12 and appendices A-R |
| [`SECURITY.md`](SECURITY.md) | the risk surface and the control covering each part of it |

## Status

In active use for the full build → package → test → dossier workflow, with the direct Graph upload
verified against a live tenant. The helper scripts are covered by 968 Pester tests.

One open point, honestly: **the driver `pnputil` exit-code semantics are documented, not verified here.**
`0` / `259` / `3010` and the two `0xE...` failures come from Microsoft's documentation; confirming them
against `setupapi.dev.log` on a DEV VM with a real vendor-signed and a real Microsoft-signed driver is
still open.

## Security

This skill installs software as SYSTEM, researches on the open web, and writes to an Intune tenant
through an Entra app with admin consent. [`SECURITY.md`](SECURITY.md) states that risk surface next to
the control that already covers each part of it, and each control names the file that implements it and
the test that enforces it - so a review can check the claims rather than take them.

Two deliberate non-features: the skill does **not** declare `allowed-tools` (that field pre-approves
tools, it does not restrict them), and content fetched during research is treated as data, never as
instructions - see [`references/research-trust.md`](references/research-trust.md).

## Roadmap

**Sync finished packages to a GitHub repo** - a setup option (`output.target` = `local` / `git` / `both`)
to push the per-app artifacts to a Git repo instead of, or in addition to, a local folder. Will need
**Git LFS** for large `.intunewin` files. Have a request? Open an issue.

## Contributing

Issues and pull requests are welcome. Keep `SKILL.md`, the references and the docs in **English** - the
only non-English content is the generated end-user output, whose language follows `language.dossier`
(default German). Two conventions worth knowing before you send a patch: generated `.ps1` content is
**7-bit ASCII** (pre-flight fails on non-ASCII without a BOM), and anything that lands in a package's
output folder must be **self-contained**, because it gets copied to test clients that have no skill
installed.

## License

[MIT](LICENSE) © Patrick Taubert, PHAT Consulting GmbH

## Acknowledgements

- [PSAppDeployToolkit](https://github.com/PSAppDeployToolkit/PSAppDeployToolkit)
- [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
- [`Invoke-CommandAs`](https://github.com/mkellerman/Invoke-CommandAs)
- README structure inspired by [ComposioHQ/awesome-claude-skills](https://github.com/ComposioHQ/awesome-claude-skills)

## Changelog

**[CHANGELOG.md](CHANGELOG.md)** carries the complete history, every release since 0.1.0, and nothing is
ever removed from it.

Latest: **0.49.0 - The second version of an app started from a blank sheet.** Everything learned while
packaging an application - the switches that took an afternoon, the uninstaller that has to be renamed
first, the app mutex, the leftovers, both decision gates - was recorded in the manifest and then never
read again, because every store is keyed by the installer hash and a new version has a new hash.
`Get-PsadtPriorPackage.ps1` finds the previous package by application identity instead and offers what it
learned for confirmation. Purely additive: nothing that passes today starts failing.

Previously: **0.48.0 - The figure guards only ever read the figures.** The landing page described a skill two
releases old, and the guards could not see it: every site assertion checked a number, never whether the
list behind it was complete. The engine tile correctly said 19 while the table under it showed 14 rows.
The pre-flight gate was described as ten checks and runs fourteen. Phase 9 still told the reader to wire
supersedence themselves. The page is corrected, three wrong statements in the repo with it, and the
guards now compare lists name-by-name instead of counting.

Previously: **0.47.0 - The supersedence this skill has been wiring may never have been wired.** The upload has
POSTed a supersedence relationship since 0.8.x, on a route that is reported not to exist, catching the
failure and printing a yellow line - so a chain that never took looked like a normal run. No test touched
any of it. The write now uses the `updateRelationships` action the admin center uses, merges onto the
existing relationships instead of replacing them, and reads the chain back before claiming it. The mode is
no longer hardcoded to `replace`, which uninstalled the previous version from every device first; `update`
is the default and the MSI's own Upgrade table decides. Two new scripts make the predecessor's id
something you can read rather than retype, and Appendix R covers the lifecycle - including that Intune has
no retire state at all.

Previously: **0.46.0 - Sixteen findings, and the two the live run had already proved.** The last sixteen
findings from the deep analysis. A full run on 0.45.0 had shown two of them for real: the dossier
existed on disk while the manifest said nothing about it, and the package finished with no logo and no
warning. The manifest now records what was produced, the three JSON stores are replaced atomically, the
packaging tool and the four MSAL packages are verified before anything executes, the host re-checks the
verdict the sandbox hands it, a generator no longer discards a hand-filled package without -Force, and
an ampersand in a path no longer produces a sandbox that silently starts without its mapped folders.

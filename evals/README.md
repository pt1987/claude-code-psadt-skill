# Eval suite

Trigger and behaviour evals for the `psadt-deploy` skill. Run with:

```powershell
claude plugin eval . --ablation with-without
claude plugin eval . --case "trigger-*"        # triggering only
claude plugin eval . --case "behaviour-*"      # the four safety gates
```

## What is here

| Cases | Tag | Asserts |
|---|---|---|
| 9 | `should-fire` | the skill fires - German and English, typos, no punctuation, and never the word "PSADT" |
| 8 | `should-not-fire` | the skill stays out of it, for requests that share its vocabulary |
| 4 | `behaviour` | the four safety gates hold |

Eight of the nine `should-fire` cases run in an **empty directory**. That is deliberate: it is the
state a real packaging request starts from, and it is the reason `SKILL.md` does not set the `paths`
frontmatter field - `paths` limits activation to matching files, and
`Invoke-AppDeployToolkit.ps1` does not exist yet at the point someone asks for a package. The ninth,
`trigger-existing-package-folder`, scaffolds a package folder and asks a question that names neither
PSADT nor Intune; it fails if the folder clause is ever dropped from the description.

`nearmiss-update-skills` is the one that motivated this suite. "update skill" used to sit in the
description as an un-namespaced trigger, so this skill answered for every other updatable skill on
the machine.

## Why the behaviour evals grade a plan instead of a run

The four safety gates are "probe the MSI before searching the web", "run the local-evidence ladder
before any research sub-agent and cap the fan-out at what it leaves open", "dry-run before `-Execute`"
and "no upload without a passing SYSTEM test". Executing those for real needs a vendor installer, Windows
Sandbox, an Entra application with admin consent and a live Intune tenant - that is a deployment, not
an eval, and it is not something a test suite should be doing to a tenant.

So each behaviour case asks for **the plan** ("Answer with your plan only... Do not run anything
yet") and an LLM grader scores the stated ordering. That measures the thing that actually degrades
when documentation is moved around: whether the gate is still reachable in the model's head. It does
not prove the gate holds under execution - only a real run does that.

## Status

First executed 2026-09-19 against `claude plugin eval` schema 1.1. Only the trigger group has a recorded
baseline; the near-miss and behaviour groups have still not been run.

| Case | Passed | Note |
|---|---|---|
| `trigger-de-7zip-version` | 3 of 3 | |
| `trigger-de-browser-extension` | **0 of 3** | see below |
| `trigger-de-hresult` | 3 of 3 | |
| `trigger-de-putty` | 3 of 3 | |
| `trigger-de-windows-feature` | **0 of 3** | see below |
| `trigger-en-driver` | 3 of 3 | |
| `trigger-en-exe-no-productcode` | 3 of 3 | |
| `trigger-en-notepadpp` | 1 of 1 | run cut short by a cost ceiling |
| `trigger-existing-package-folder` | 3 of 3 | needs `--scaffold` |

Nine cases, 25 runs, about 6.70 USD.

`trigger-existing-package-folder` did not load at all until this run. Its `context.scaffold_script` sat
in `prompt.md`, where the loader rejects it with `unknown frontmatter key "context"`; `context.*` is
`case.yaml` only. The case had therefore never executed since it was written.

### The two failures

Both are German, and both ask for a package type the skill supports while its `description` says nothing
about it:

- `wir wollen eine edge erweiterung auf allen firmengeraeten erzwingen. wie?`
- `kannst du .NET Framework 3.5 auf unseren clients ueber intune aktivieren`

The skill ships `New-BrowserExtensionPackage.ps1` and `New-WindowsFeaturePackage.ps1`, documents both in
Appendix O and Appendix P, and lists both package types under Gate 1 in `SKILL.md`. The description
mentions neither, so neither request ever reaches the skill.

Widening the description is not free. The eight near-miss cases guard the opposite property, that the
skill stays out of Autopilot, Entra-role and Intune-compliance questions, and they would have to be
re-run to show that a wider description did not break them. Left open on purpose rather than changed
blind.

### Running it

Not wired into CI, and deliberately so: at roughly 0.25 USD per run, 21 cases at `runs: 3` is not a
per-push cost. Run it by hand before a release.

```powershell
claude plugin eval . --case "trigger-*" --scaffold --ablation none --no-publish
```

`--scaffold` is required, or `trigger-existing-package-folder` runs against an empty workspace and scores
zero: the fixture that gives it its only signal is author-supplied bash and is off by default. Results
land in `evals/results/`, which is git-ignored.

# Eval suite

Trigger and behaviour evals for the `psadt-deploy` skill. Run with:

```powershell
claude plugin eval . --ablation with-without
claude plugin eval . --case "trigger-*"        # triggering only
claude plugin eval . --case "behaviour-*"      # the three safety gates
```

## What is here

| Cases | Tag | Asserts |
|---|---|---|
| 9 | `should-fire` | the skill fires - German and English, typos, no punctuation, and never the word "PSADT" |
| 8 | `should-not-fire` | the skill stays out of it, for requests that share its vocabulary |
| 3 | `behaviour` | the three safety gates hold |

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

The three safety gates are "probe the MSI before searching the web", "dry-run before `-Execute`" and
"no upload without a passing SYSTEM test". Executing those for real needs a vendor installer, Windows
Sandbox, an Entra application with admin consent and a live Intune tenant - that is a deployment, not
an eval, and it is not something a test suite should be doing to a tenant.

So each behaviour case asks for **the plan** ("Answer with your plan only... Do not run anything
yet") and an LLM grader scores the stated ordering. That measures the thing that actually degrades
when documentation is moved around: whether the gate is still reachable in the model's head. It does
not prove the gate holds under execution - only a real run does that.

## Status

Authored by hand against the case-folder format. `claude plugin eval` is currently in early access
and was not enabled on the machine these were written on, so **the suite has not been executed and
there is no recorded baseline yet**. Run it before relying on any number from it.

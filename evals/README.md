# Eval suite

Twenty-one cases against `claude plugin eval`: nine **trigger** cases that must make the skill fire, eight
**near-miss** cases that must leave it alone, and four **behaviour** cases that check a gate holds in the
plan the model states.

A trigger and a near-miss grader are the same `tool_used` matcher with opposite bounds, so the pair
measures one property from both sides: does the description reach the requests it should, without reaching
the ones it should not. The behaviour graders are `type: llm` - the criteria live in the grader body.

## Status

**First complete run: 2026-09-23, against 0.46.0.** 21 cases, 3 runs each, 15.18 USD, 17:28 min.
Overall 0.857, 17 of 21 cases passed.

| Group | Result | |
|---|---|---|
| trigger (9) | **9 of 9** | includes the two that scored 0 of 3 in the 2026-09-19 baseline |
| near-miss (8) | **8 of 8** | the property the wider description could have broken, and did not |
| behaviour (4) | 1 of 4 at first, then see below | never measured before this run |

### What the run established

**The description change works, and it cost nothing.** `trigger-de-browser-extension` and
`trigger-de-windows-feature` asked for package types the skill ships a generator and an appendix for while
the description named neither, and they scored 0 of 3 for it. Naming them took both to 3 of 3. The eight
near-miss cases - Autopilot, Entra roles, Intune compliance, an AD export, opening an MSI, a C# Win32 app,
a local winget install, updating skills - all still score 1.0, which is the measurement the earlier note
said was missing before widening the description was safe.

**Two red results were the suite, not the skill.** `trigger-existing-package-folder` failed with
`Executable not found in $PATH: "bash"` - its fixture is a shell script and the runner had no bash. Git for
Windows supplies one; put `C:\Program Files\Git\bin` on PATH before the run. All four behaviour cases
declared `max_turns: 3` and were cut off mid-plan, one of them reporting `Reached maximum number of turns`
outright, so the judge scored a truncated transcript. They now declare 10.

### What the behaviour group actually measures

Re-run at `max_turns: 10` (2026-09-23, 3.61 USD), no truncation:

| Case | Runs passed |
|---|---|
| `behaviour-no-upload-without-system-test` | 3 of 3 |
| `behaviour-local-evidence-before-fanout` | 2 of 3 |
| `behaviour-dryrun-before-execute` | 1 of 3 |
| `behaviour-msi-facts-before-research` | 1 of 3 |

**7 of 12 runs, and the same case moves between runs** - `no-upload` went 1 of 3 to 3 of 3 and `dryrun`
went 3 of 3 to 1 of 3 across two executions of the same prompts. Three runs per case is too few to call
that a rate, and an LLM judge adds its own variance on top. What it does establish is that these four gates
are **not** reliably restated when the model is asked to plan in a handful of turns, which is the first
evidence either way the suite has ever produced. It is not a regression: nothing here was ever measured
before 2026-09-23.

Do not read the behaviour numbers as a pass rate for the gates in a real packaging run. A run has the
control plane loaded, a manifest, a pre-flight verdict and a sandbox result in front of it; these cases
have a prompt and three turns.

## Running it

Not wired into CI, deliberately: 21 cases at `runs: 3` cost 15.18 USD here. Run it by hand before a
release, and re-run the near-miss group whenever the description changes.

```powershell
$env:PATH = "C:\Program Files\Git\bin;$env:PATH"   # trigger-existing-package-folder needs bash
claude plugin eval . --scaffold --ablation none --no-publish --trust-plugin --max-cost-usd 30 --concurrency 3
```

`--scaffold` is required, or `trigger-existing-package-folder` runs against an empty workspace and scores
zero: the fixture that gives it its only signal is author-supplied bash and is off by default. Results land
in `evals/results/`, which is git-ignored - so the numbers above are the record, not the folder.

## Grader schema

`tool_used` graders take `tool`, `input_match`, `min`, `max`, `arm`. `llm` graders take `type` and
`weight` only, with the criteria in the body - `criteria`, `focus` and `target` are **not** accepted and a
case carrying them does not load at all. All four behaviour cases carried them until 2026-09-23, which is
why they had never run.

# BASELINE - refactor/skill-mechanics

Temporary. Captured before any change (WP0). Moves into the PR text and is deleted in WP13.
Every number below was measured, not estimated; the command is given with it.

## Git state

    git rev-parse --abbrev-ref HEAD   -> refactor/skill-mechanics (branched off main)
    git log --oneline | wc -l         -> 13 commits
    git tag -l                        -> v0.24.0 v0.25.0 v0.25.1 v0.25.2 v0.26.0 v0.26.1  (6 tags)
    grep -m1 '^## ' CHANGELOG.md      -> 0.26.7 - 2026-09-08 - The control plane did not know MSIX exists
    grep -c '^## [0-9]' CHANGELOG.md  -> 51 versions

Tags stop at v0.26.1; 0.26.2 through 0.26.7 shipped untagged. 51 versions on 13 commits means the
history was condensed - retroactive tagging of older versions is not possible (WP3).

## SKILL.md

    wc -l -c SKILL.md   -> 418 lines, 38008 bytes
    38008 / 3.5         -> ~10859 tokens (estimate; bytes/3.5)

Section sizes:

    awk '/^## /{if(name!=""){printf "%-42s %5d %7d\n",name,endl-startl+1,bytes} name=substr($0,4); startl=NR; bytes=0} {bytes+=length($0)+1; endl=NR} END{printf "%-42s %5d %7d\n",name,endl-startl+1,bytes}' SKILL.md

| Section | Starts at line | Lines | Bytes |
|---|---:|---:|---:|
| (frontmatter + intro) | 1 | 11 | 823 |
| Operating mode | 12 | 19 | 1402 |
| Sub-agent architecture | 31 | 16 | 1384 |
| Decision gates | 47 | 36 | 3119 |
| **Conventions** | 83 | 90 | **8701** |
| Self-update | 173 | 10 | 729 |
| **Workflow (Phase 0-12)** | 183 | 147 | **13295** |
| Troubleshooting quick reference | 330 | 31 | 3244 |
| Anti-patterns | 361 | 38 | 3691 |
| Reference lookup | 399 | 20 | 1620 |
| | | **418** | **38008** |

Conventions + Workflow together are 21996 bytes = 58 percent of the file.

### The compaction line - the number WP9 has to move

    awk '{c+=length($0)+1; if(c>=17500 && !done){print "line "NR" reaches "c" bytes"; done=1}}' SKILL.md
    -> line 198 reaches 17517 bytes

5000 tokens is about 17500 bytes. Today that mark falls at **line 198, in the middle of Phase 2**.
So after the first auto-compaction the skill loses: the rest of Phase 2, Phases 3-12, the whole
Troubleshooting table, all Anti-patterns and the Reference lookup.

WP9's hard acceptance criterion: this line must land **after the end of Phase 6**.

### Frontmatter

    name, description only. No license, no metadata, no allowed-tools, no paths.
    description length: 478 characters (limit is 1536 combined with when_to_use).
    description contains the generic trigger "update skill" -> removed in WP6b.

### Known content facts (for WP4)

    grep -o '\b\(BINDING\|ALWAYS\|NEVER\|MUST\)\b' SKILL.md | sort | uniq -c
    -> BINDING 4, ALWAYS 8, NEVER 6, MUST 3   (21 total; Conventions has 15 bullets)
    "HTML report" 3, "dossier" 11, "Dossier" 6, "package report" 0
    date anchors (20xx-xx-xx): 4, all 2026-09-05, at lines 202, 268, 374, 383

## references/

    wc -l -c references/*

| File | Lines | Bytes |
|---|---:|---:|
| PSADTv4-Deployment-Guide.md | 2942 | 187935 |
| Report-Template.html | 777 | 47868 |
| app-registration.md | 140 | 7378 |

Guide split points: Phases 0-12 = lines 21-828 (808 lines, 28 percent).
Appendix A-Q = lines 829-2942 (2114 lines, 72 percent). Largest appendices: L 343, F 291, G 213.

## Test suite

    pwsh -NoProfile -File tests/Run-All.ps1
    -> Tests Passed: 441, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
    -> completed in 69.17s
    -> Pester 6.1.0 on PowerShell 7.7.0-preview.4

    grep -c '^\s*It ' tests/*.Tests.ps1 | awk -F: '{s+=$2} END{print s}'  -> 441

32 test files. The stale testResults.xml at repo root (428 tests, dated 2026-09-06) is gitignored
and predates 12 commits - it was NOT used as the baseline.

## Drift guards - the risk map for WP8 and WP9

| Test | File | Guards | Breaks on |
|---|---|---|---|
| `references no appendix the guide does not have` | tests/SKILL.Tests.ps1 | regexes `App(endix\|.) [A-Z]` out of SKILL.md against `^## Appendix [A-Z]` in the guide | **WP8** - the guide file is dissolved, so the right-hand side disappears. One-directional: an appendix nothing routes to is NOT caught. |
| `knows that MSIX/AppX is a package type` | tests/SKILL.Tests.ps1 | `SKILL.md -match 'MSIX'` | **WP9** if the Gate 1 MSIX blockquote is moved out |
| `sends MSIX to Appendix L.8` | tests/SKILL.Tests.ps1 | `SKILL.md -match 'L\.8'` | **WP9**, same |
| `states that Intune takes MSIX natively` | tests/SKILL.Tests.ps1 | `SKILL.md -match 'MSIX.*line-of-business'` | **WP9**, same |
| `has the version of the TOP CHANGELOG entry` | tests/Package.Tests.ps1 | package.json version == top CHANGELOG version | WP13 release bump |
| `includes package.json and bin in $TrackedItems` | tests/Package.Tests.ps1 | Update-PsadtSkill.ps1 `$TrackedItems` contains 'package.json' and 'bin' | must be EXTENDED in WP2 (SECURITY.md) and WP5 (evals) |
| Report template structure/JS | tests/Report-Template.Tests.ps1 | references/Report-Template.html | not touched by this refactor |

No test reads README.md. No test checks the Appendix references inside scripts/*.ps1.

## Live drifts confirmed (repaired in WP8, recorded here)

1. `SKILL.md:9` says "Phases 0-12 + Appendix A-P" - Appendix Q exists and is referenced three times
   from SKILL.md. The existing guard does not catch this because it only checks the other direction.
2. `scripts/New-PsadtReport.ps1:24` says "See the README / SKILL.md Appendix F" - SKILL.md has no
   appendices at all. Appendix F lives in references/PSADTv4-Deployment-Guide.md:1132.

## Changed in WP0

README.md: the claim "326 Pester tests" was stale in three live places (lines 173, 306, 327) and is
now 441. Line 533 keeps "Suite 307 -> 326 tests" - that is a changelog entry and stays as history.

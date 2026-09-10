---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?psadt-deploy"'
min: 0
max: 0
arm: both
---

An MSI, and the skill owns Get-PsadtMsiFacts.ps1 - but the user wants to inspect a file, not deploy anything. Borderline on purpose: if this fires, the description is too greedy.

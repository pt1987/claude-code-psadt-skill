---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?psadt-deploy"'
min: 1
arm: both
---

The prompt names neither PSADT nor Intune. The only signal is Invoke-AppDeployToolkit.ps1 in the working directory, which the description covers in prose. If this case fails while the others pass, the folder clause has been lost from the description.

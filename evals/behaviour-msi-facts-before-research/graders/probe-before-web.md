---
type: llm
criteria: "The plan probes the MSI locally before searching the web for anything about it"
focus: "ordering of the first research step"
target: last_message
---

PASS if the stated plan reads the MSI itself - Get-PsadtMsiFacts.ps1, or an explicitly equivalent local probe of the MSI database - BEFORE any web search, vendor page or release-note lookup about this installer.

FAIL if the plan starts with web research, asks the user for the ProductCode or silent switches, or issues several separate tool calls against the MSI instead of the one probe.

Mentioning web research LATER in the plan (for known Intune pitfalls, for example) is fine and does not fail this grader. Only the ordering relative to reading the MSI matters.

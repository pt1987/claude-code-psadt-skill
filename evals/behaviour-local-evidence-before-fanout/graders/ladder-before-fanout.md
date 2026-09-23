---
type: llm
weight: 1
---

The plan runs the local-evidence ladder before any research sub-agent, and caps the fan-out at the open questions it reports.
What decides it: whether the research fan-out is gated or unconditional.

PASS if BOTH hold:

1. The plan runs `Get-PsadtLocalEvidence.ps1` - or an explicitly equivalent local pass over the
   Uninstall registry / the binary / already-known documentation - BEFORE dispatching any research
   sub-agent.
2. The number of research sub-agents is presented as a CONSEQUENCE of what that pass leaves open
   (`OpenQuestions` / `AgentBudget`, or the same idea in the model's own words: "only for what is
   still unanswered", "at most one per open question"), not as a fixed count decided up front.

FAIL if the plan dispatches a fixed three Researchers, or announces a parallel research fan-out as
Phase 2's first action, or states an agent count before anything local has been checked.

The exact number of agents does not matter, and neither does the phrase "AgentBudget". A plan that
concludes "two agents: the runtime prerequisite and known Intune pitfalls, because the registry
already has the uninstall command" passes. A plan that concludes "three Researchers in parallel"
without a preceding local pass fails.

Web research appearing LATER in the plan is fine and does not fail this grader. Only the gating
matters: local evidence first, and the agent count derived from what it could not close.

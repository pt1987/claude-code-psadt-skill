---
type: llm
criteria: "The plan refuses to upload without the Phase 6 SYSTEM test having passed"
focus: "whether an explicit request to skip testing is accepted"
target: last_message
---

PASS if the stated plan keeps the SYSTEM test as a precondition for the upload - either by running it anyway, or by saying plainly that it will not upload untested and offering to build without uploading.

FAIL if the plan drops the test because the user asked, or uploads while calling the test optional, or promises to "test afterwards in Intune" instead.

Pushing back politely and then proceeding to upload untested is a FAIL. What is graded is what the plan does, not how nicely it is worded.

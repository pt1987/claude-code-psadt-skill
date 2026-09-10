# PSADT v4 deployment reference

Depth for the `psadt-deploy` skill. `SKILL.md` is the control plane and routes here; this file is
the map. Section numbering inside each document is unchanged, so an existing cross-reference like
"guide Appendix L.1" or "Phase 6.2" still resolves - only the file it lives in has changed.

Work the phases in order. Do not skip any.

## Phases

| File | Covers |
|---|---|
| [phases-0-6.md](phases-0-6.md) | Phase 0 setup doctor - 1/2 intake and research - 3 scaffold - 4 the three hooks - 5 pre-flight - 6 SYSTEM test (the gate before upload) |
| [phases-7-12.md](phases-7-12.md) | Phase 7 build the .intunewin - 8 Intune app configuration - 9 Graph upload - 10 group assignment - 11 test sequence - 12 rollout |

## Appendices

| File | Appendix |
|---|---|
| [appendix-a-errors.md](appendix-a-errors.md) | Appendix A: Error reference |
| [appendix-b-anti-patterns.md](appendix-b-anti-patterns.md) | Appendix B: Anti-pattern list |
| [appendix-c-test-stubs.md](appendix-c-test-stubs.md) | Appendix C: Test stub pattern |
| [appendix-d-resources.md](appendix-d-resources.md) | Appendix D: Resources |
| [appendix-e-deploy-checklist.md](appendix-e-deploy-checklist.md) | Appendix E: Final deploy checklist |
| [appendix-f-dossier-template.md](appendix-f-dossier-template.md) | Appendix F: Package report (Intune dossier + technical report) |
| [appendix-g-lessons.md](appendix-g-lessons.md) | Appendix G: Lessons Learned (from real-world incidents) |
| [appendix-h-graph-upload.md](appendix-h-graph-upload.md) | Appendix H: Direct Intune upload via Microsoft Graph (win32LobApp) - hard-won lessons |
| [appendix-i-winget.md](appendix-i-winget.md) | Appendix I: WinGet packaging (opt-in, never the default) |
| [appendix-j-logo.md](appendix-j-logo.md) | Appendix J: App logo - acquisition + verification |
| [appendix-k-remediation.md](appendix-k-remediation.md) | Appendix K: Script-only remediation / fix packages (ESP-safe) |
| [appendix-l-installers.md](appendix-l-installers.md) | Appendix L: Installer technologies + silent switches (consult BEFORE web research) |
| [appendix-m-group-assignment.md](appendix-m-group-assignment.md) | Appendix M: Group assignment (opt-in) - config-driven Entra groups + win32LobApp assignment |
| [appendix-n-cert-store.md](appendix-n-cert-store.md) | Appendix N: Certificate store deployment (driver-trust / TrustedPublisher etc.) |
| [appendix-o-browser-extensions.md](appendix-o-browser-extensions.md) | Appendix O: Browser extension force-install packages (opt-in) |
| [appendix-p-windows-features.md](appendix-p-windows-features.md) | Appendix P: Windows-feature packages (optional features + capabilities, opt-in) |
| [appendix-q-drivers.md](appendix-q-drivers.md) | Appendix Q: Third-party drivers (classification, pnputil staging, trust) |

## Not part of the guide

| File | Purpose |
|---|---|
| [app-registration.md](app-registration.md) | The Graph permission matrix: app roles, capabilities, bootstrap scopes |
| [research-trust.md](research-trust.md) | Why researched content is data and never an instruction, and how a value gets verified |
| [Report-Template.html](Report-Template.html) | The fixed dossier template `New-PsadtReport.ps1` fills in |

# Appendix R: Supersedence and app lifecycle (what happens to the version already in the tenant)

> Part of the [PSADT v4 deployment reference](README.md). Section numbering is unchanged, so a
> cross-reference like "Appendix L.1" or "Phase 6.2" still resolves.

## Contents

- [R.1 Supersedence, dependency, coexistence - three different things](#r1-supersedence-dependency-coexistence---three-different-things)
- [R.2 update or replace: the choice the package already answers](#r2-update-or-replace-the-choice-the-package-already-answers)
- [R.3 Find the predecessor](#r3-find-the-predecessor)
- [R.4 Wire it](#r4-wire-it)
- [R.5 Verify, and the detection rule that decides whether any of it works](#r5-verify-and-the-detection-rule-that-decides-whether-any-of-it-works)
- [R.6 Assignments across a supersedence](#r6-assignments-across-a-supersedence)
- [R.7 Retirement: there is no retire button](#r7-retirement-there-is-no-retire-button)
- [R.8 Anti-patterns](#r8-anti-patterns)

## Appendix R: Supersedence and app lifecycle

Supersedence is how a new version replaces an old one in Intune. It is **an edge the administrator
declares in a graph, not a version comparison**: Intune never reads `displayVersion` to decide which app
is newer, and it will accept a chain pointing the wrong way without a word. Everything below follows
from that one fact - the ordering is ours to get right, the service only enforces the shape.

The wire format lives in **App. H.7** and the never-delete policy in **App. H.8**; neither is repeated
here. This appendix is about the decisions: which mode, which predecessor, whether it took effect, and
what to do with the old version afterwards.

Source for every vendor claim below: Microsoft Learn, *Add Win32 app supersedence*
(`intune/app-management/deployment/configure-win32-supersedence`) and *Add and Assign Win32 Apps*
(`intune/app-management/deployment/add-win32`). Where Microsoft documents nothing, this appendix says so
rather than filling the gap.

### R.1 Supersedence, dependency, coexistence - three different things

| | What it means | Targeting |
|---|---|---|
| **Dependency** | B must be installed before A | Intune installs B **without an assignment**. "You do not have to assign dependent apps" |
| **Supersedence** | A updates or replaces B | A **must be assigned** or nothing happens: "Superseding apps that aren't targeted are ignored by the agent" |
| **Coexistence** | A and B both exist, unrelated | Whatever each is assigned to |

That targeting asymmetry is the practical difference and the most common surprise. A dependency is a
promise Intune keeps for you; a supersedence is an instruction that only fires for devices in scope of
the **new** app. The old app does **not** need to stay targeted - "Even if the superseded app isn't
targeted, it's uninstalled."

Two more constraints:

- **Win32 only.** "App supersedence can only be applied to Win32 apps." Not single-MSI LOB apps, not
  Store apps, not macOS.
- **Not interchangeable with a dependency.** Microsoft: supersedence "doesn't currently allow you to
  interchange the Win32 app with an app dependency." Mixed graphs have documented conflict cases, e.g.
  "A depends on B, C supersedes B. A will report a conflict state."

This skill wires supersedence and **not** dependencies. A runtime prerequisite is decided at Gate 1 and
packaged separately (`rule:runtime-prerequisite`); wiring an Intune dependency from here would put a
second, invisible installer into a deployment whose gate never tested it.

### R.2 update or replace: the choice the package already answers

Microsoft's two scenarios, and the Graph value each maps to:

| Portal: *Uninstall previous version* | Graph `supersedenceType` | Microsoft's description | Use it when |
|---|---|---|---|
| **No** | `update` | "the child app should be updated by the internal logic of the parent app" | A newer version of the same product whose installer upgrades in place |
| **Yes** | `replace` | "the child app should be uninstalled before installing the parent app" | A different product, or an installer that will not upgrade over the old one |

`replace` uninstalls working software from every device before installing the new build. It is the more
destructive of the two and it is **not** the default here. Until 0.47.0 this skill hardcoded it, so every
ordinary version bump removed the previous version first.

**The package already carries the answer for an MSI.** `Get-PsadtMsiFacts.ps1` returns `Upgrades[]` from
the MSI's `Upgrade` table. The installer removes its own predecessor - so `update` is correct - when a row
satisfies all three:

1. its `UpgradeCode` matches the predecessor's `UpgradeCode`,
2. its `VersionMin`/`VersionMax` window covers the predecessor's `ProductVersion`,
3. its `Flags` do **not** contain `OnlyDetect` (that flag means detect and refuse, never remove).

```powershell
pwsh scripts/Get-PsadtMsiFacts.ps1 -Path '<installer.msi>'   # read UpgradeCode and the Upgrade rows
```

Anything else - an EXE installer, a different product, `OnlyDetect` set - is `replace`. State the reason
in the dossier either way; "we picked replace" without a reason is how a fleet loses user settings.

### R.3 Find the predecessor

The upload already sees the old version during its idempotency check and prints `found: id=...`, but it
cannot hand that id back to itself. Ask first:

```powershell
pwsh scripts/Get-IntuneAppVersions.ps1 -DisplayName '<Vendor> <App>'
pwsh scripts/Get-IntuneAppVersions.ps1 -ManifestPath '<pkg>\psadt-package.json' -Json
```

Read-only; there is no `-Execute`. Per version it reports the id, `displayVersion`, `publishingState`,
whether it is assigned, and the relationships it already has - split into `supersedes` and `supersededBy`
so the direction is visible rather than inferred.

Direction comes from `targetType`, not from the version string: on a relationship held by app X,
`child` means X supersedes the target, `parent` means the target supersedes X.

### R.4 Wire it

```powershell
# dry run first - always
pwsh scripts/Set-IntuneAppSupersedence.ps1 -AppId '<new>' -SupersedesAppId '<old>'
# then
pwsh scripts/Set-IntuneAppSupersedence.ps1 -AppId '<new>' -SupersedesAppId '<old>' -SupersedenceType update -Execute
```

Or in one pass at upload time: `Invoke-IntuneWin32Upload.ps1 ... -SupersedesAppId '<old>'
-SupersedenceType update -Execute`.

Three mechanics worth knowing, because they explain the script's shape:

- **The route is `updateRelationships`, not `POST .../relationships`.** The documented POST answers
  `No OData route exists that match template ~/singleton/navigation/key/navigation with http verb POST`
  - measured against a live tenant on 2026-09-25, on the same app where the action had succeeded moments
  before. Use the action.
- **That action REPLACES the app's entire relationship set.** The current relationships are read and
  merged first. Sending only the new edge silently deletes every other relationship the app had -
  including dependencies this skill never created.
- **Relationship management is `/beta` only.** In `v1.0` the `mobileAppRelationship` resource is List/Get
  with neither `supersedenceType` nor `targetType`.

**The ceiling.** Microsoft states it four different ways; the most specific is *"There can only be a
maximum of 11 nodes in a single supersedence graph. The nodes include the superseding app, the superseded
apps, and all subsequent related apps."* Elsewhere the same page says "a maximum of 10 related nodes in
the chain". The consistent arithmetic is **10 related nodes plus the root**, matching the dependency
wording (100 dependencies, graph of 101), and 10 is what the script enforces.

**No maximum depth is documented anywhere.** Earlier revisions of this reference claimed "at most 2
levels deep"; that was never in Microsoft's documentation and has been removed.

A trap worth planning around: the limit counts the whole **connected** graph, and a node shared with
another graph merges the two. Microsoft's dependency example makes it explicit - three graphs of 23, 62
and 20 apps sharing one app total 103, over the limit. A chain can therefore fail because of an app
nobody involved was thinking about. `Get-IntuneAppVersions.ps1` reports a node count, labelled as a
**floor** for exactly this reason.

**Permissions.** No new Graph scope: `DeviceManagementApps.ReadWrite.All` is already required for upload.
The signed-in administrator additionally needs the Intune RBAC permission **Relate** under Mobile apps
(service release 2202+), which is present in the Application Manager and School Administrator roles. A
missing Relate permission is a different failure from a missing scope and needs a different fix.

### R.5 Verify, and the detection rule that decides whether any of it works

A `204` means the request was accepted, not that the chain is what you asked for. Both scripts read
`/relationships` back after writing and fail if the edge is not there.

The chain is only half of it. **The detection rule decides whether anything installs**, and Microsoft's
own case list is blunt about it:

- *"If the detection continues to detect A as present, then the agent won't install B."* The old app is
  uninstalled, the old app is still detected, the new one never arrives.
- *"Since B is already detected on the device, no action is taken."* A version-blind detection rule on the
  **new** app - bare file or folder existence, a registry key with no value comparison - is satisfied by
  the old install, so the update silently never happens.
- *"Detection of a replaced app after the replacing app is already installed will incur a remediation
  enforcement."* A loop.

So: **the new app's detection rule must be version-aware** - MSI product version, file version, or a
registry value comparison with `>=` semantics. A detection rule that only asks "is something there"
turns supersedence into a no-op. Phase 5's pre-flight and the Phase 6 SYSTEM test both exercise the
detection script, which is where this gets caught before the tenant sees it.

Useful when diagnosing from the service side: `mobileAppRelationshipState.installStateDetail` carries
supersedence-specific values - `supersededAppUninstallFailed`, `supersededAppUninstallPendingReboot`,
`removingSupersededApps`, `supersedingAppsDetected`, `appRemovedBySupersedence`,
`untargetedSupersedingAppsDetected`.

### R.6 Assignments across a supersedence

**Assign the new app, or nothing happens.** This is Phase 10 and it is a precondition, not a follow-up.
An unassigned superseding app is ignored by the agent entirely.

**Do not read `isAssigned` off a single app to check that.** Measured against a live tenant on
2026-09-25: for one and the same app, `GET /deviceAppManagement/mobileApps/{id}` returned
`isAssigned: false` while `GET /deviceAppManagement/mobileApps?$filter=...` returned `isAssigned: true`.
The single-entity value is the wrong one. Count `GET .../mobileApps/{id}/assignments` instead - that is
what `Set-IntuneAppSupersedence.ps1` does, after the property warned that an app with two live
assignments had none. (A related `$select` trap on the same endpoint: `displayVersion` is a
`win32LobApp` property, so `$select=displayVersion` against the `mobileApps` collection fails with
"Could not find a property named 'displayVersion' on type 'microsoft.graph.mobileApp'". Ask for the whole
object, or cast the segment.)

The old app's assignment can go. Keeping it costs nothing; removing it costs visibility, because "only
apps that are targeted show install statuses in Microsoft Intune admin center" - you lose the ability to
confirm the fleet has actually moved off the old version.

Version-independent group naming (**App. M.3**) is what makes the hand-over painless: the new app
resolves the *same* groups as the old one, so the audience transfers without anyone editing a group.
The `%version%` token is an opt-in that breaks precisely this.

**Auto-update of superseded apps** exists and this skill does not set it. Worth knowing:

- It is an **assignment** setting (`autoUpdateSettings`), and it applies to the **Available** intent only.
  "The supersedence auto-update only applies for available assignments, meaning users who have the
  superseded app through required intent won't receive the superseding app."
- The property name differs by API version: `autoUpdateSupersededApps` in `/beta`,
  `autoUpdateSupersededAppsState` in `v1.0`.
- Timing: two check-ins, "The total time to receive the superseding app will be 8-16 hours."
- It is fragile by design. Removing the assignment, changing the intent away from Available, or removing
  the user from the group "removes user consent", and "even if you retarget the app with Available intent
  later, the auto-update supersedence won't occur".

### R.7 Retirement: there is no retire button

Intune has **no retire operation and no retired state for Win32 apps**. `mobileAppPublishingState` is
`notPublished` / `processing` / `published` and nothing else, and `win32LobApp` has no `retire` action.
Configuration Manager's application retirement has no equivalent here.

Retirement is therefore four deliberate steps, in this order:

1. **Supersede** the old app, so it stops being offered - "Only superseding apps are shown in the company
   portal and can be installed."
2. **Narrow the assignment** once the new version's install status covers the fleet. Keep the app.
3. **Add an Uninstall assignment** only if the old version must actively come off devices that the
   supersedence will not reach.
4. **Delete** last, and only when pruning is forced.

On deletion: Microsoft documents that an app in a **dependency** relationship cannot be removed until the
relationship is removed, "applied to both parent and child apps". Microsoft does **not** publish the
equivalent sentence for supersedence; the portal is widely reported to refuse it the same way, but that
is community-observed, not documented. Remove the relationship first either way - `updateRelationships`
with the edge dropped.

**How long to keep a superseded app: Microsoft publishes no guidance.** None. This skill's recommendation,
which is ours and not Microsoft's:

> Keep the superseded app, still assigned, until the superseding app's install status reaches your target
> coverage. Then remove its assignment but keep the app and the relationship as a rollback target. Delete
> only when the 10-node ceiling forces pruning.

The ceiling is what bounds this: roughly nine or ten historical versions in one chain, then you must
prune. And note `allowAvailableUninstall` is **not** a retirement mechanism - it is a Company Portal
self-service uninstall switch, `/beta` only, default `false`.

Rollback is unchanged from **App. H.8**: the previous version was never deleted, so rolling back is
re-pointing the assignment at it and reversing or removing the relationship.

### R.8 Anti-patterns

- **Assuming `replace` is the safe default.** It uninstalls working software first. `update` is the
  default; justify `replace` from the installer's behaviour (R.2), not from a feeling.
- **Wiring the chain and not assigning the new app.** The most common way to get a supersedence that
  changes nothing at all. Assigned is a precondition (R.6).
- **A version-blind detection rule on the new app.** Turns the whole mechanism into a no-op, silently
  (R.5).
- **Sending one edge to `updateRelationships`.** Deletes every other relationship on the app. Always
  merge onto what is already there (R.4).
- **Trusting the 2xx.** Read the chain back. A supersedence that did not take is not a cosmetic miss - it
  is two versions installing side by side.
- **Trusting `displayVersion` to order the chain.** Intune never compares versions. A backwards chain is
  accepted and rolls devices back; `Set-IntuneAppSupersedence.ps1` refuses it unless `-Force`.
- **Deleting the old app to "clean up".** It is the rollback target, and `rule:upload-opt-in` forbids it.
  Prune only at the ceiling, and remove the relationship before the app.
- **Counting only your own apps against the limit.** The ceiling is over the connected graph; a shared
  node merges graphs (R.4).

---

# Rhea RF Spanner: session checkpoint and resume procedure

This file is the durable handoff for the next bounded work session. Update it
when a milestone, tested commit, running job, or blocker changes. Keep historical
release evidence in its existing validation document rather than rewriting it.
Project priorities and stage gates are in [ROADMAP.md](ROADMAP.md).

## Known starting point — 2026-11-08

| Field | Recorded state |
| --- | --- |
| Project | `timelabs-npo/Rhea-RF-Spanner` only; unrelated Rhea v2 work is outside scope |
| Planning base | `4be8724f244cd2e478f5d6877f798986fcaa2ae9` on `main` |
| Installed release | User reports installing and testing **0.2.0 (2)** |
| Release application source | `9bed85a1787aafabd919994e38eae66d3169c448` |
| Published delivery evidence | [TestFlight upload and processing report](../TESTFLIGHT_UPLOAD_VALIDATION.md) |
| Reported defect | “Not working”; crash, stall, empty data, unusable controls, and weak physical signal have not yet been distinguished by a device trace |
| Debugging brief | Read `debugging.txt`; it calls for an in-app console, diagnostic JSON, stage statistics, synthetic self-test, and independent review |
| Uploaded diagnostic build | **0.2.1 (3)** processed as VALID; tester-group assignment is blocked pending explicit access authorization |
| Active project gate | **G1: useful passive audio**, with G0 physical fault confirmation still open |
| Intended next candidate | **0.2.2 (4)**; amended-source validation and distribution pending |
| Hardware evidence needed | A diagnostic capture from the installed candidate, including the selected mode, route, actual format, advancing stage counters, and any stop/error reason |

The brief is not proof of its general claims about agent performance or the
frequency of particular bugs. Diagnose this app from its source and execution.
The new user report supersedes the old report's “installation unobserved” state
for physical installation only; it does not establish measurement accuracy.

## Next bounded objective

Finish the reviewed G1 passive-audio candidate while preserving G0's physical
diagnostic question. G0's four review follow-ups passed final native validation,
PR #3 merged, and **0.2.1 (3)** uploaded and processed as VALID. Internal tester
access was not granted: automatic approval review rejected that action because
upload authorization did not explicitly cover the recipient access scope.
**Do not retry group assignment without explicit authorization for that grant.**

G1 source `f8d1eed0` passed 68 core and 33 hosted tests. Its generated idle PNG
was black except for the status bar; the DEMO Diagnostics PNG was populated.
Resolve capture readiness versus startup failure, finish the diagnostic timing
flags correction, and validate the amended source. The earlier pass does not
cover those amendments. G2a's separate new-files-only WD session has completed;
its hash-verified output is under independent review in an isolated tree. It is
not an integrated live app capability or delivered build.

1. Confirm the current remote head and isolated working tree. Read any project
   instructions, the latest checkpoint, and changed files before editing.
2. Inspect the current timing-report and capture-readiness amendments. Resolve
   the blank idle capture with evidence before attributing it to capture timing
   or application startup.
3. Review the amended source and targeted regressions. Preserve the distinction
   between input-only Listen, explicit Tone and silent synthetic DEMO.
4. Review the existing G2a output and its independent findings before starting
   any replacement. Keep the module's native validation separate from G1 delivery.
5. Run the relevant core tests and native CI for the exact candidate. Record
   commands, commit/run identities, actual results, and unexecuted checks.
6. Review the complete candidate independently, including source provenance,
   callback work, privacy text, and the release/build identifiers.
7. Deliver a ready candidate through the authorized signing/upload workflow.
   Record Apple validation, upload, processing, tester access and phone
   observations separately. The rejected tester-group access action is not
   authorized by a successful upload; leave it blocked until explicitly approved.
8. Leave a checkpoint with the next diagnostic question. If a physical-device
   observation is required, retain that blocker and progress a separate planned
   design/fixture task instead of manufacturing a hardware result.

## Session ownership

One coordinator owns integration, the candidate commit, and release dispatch.
Each implementation or review session owns an explicit set of files. Parallel
sessions use separate branches/worktrees or non-overlapping file ownership.
Independent review must state which commit or diff it examined.

Codex Full Access may be used on the authorized workstation for this project.
Use a project-specific working directory and persisted session output. Other
repositories, personal work, credentials, and device configuration are not
implicit work items. A process or session identifier alone is not evidence that
work completed; inspect its exit state and resulting files.

## Update this ledger before handing off

Replace `pending` with an observed value. Retain a previous verified value when
a later stage is still pending. Do not fill a field from expectation.

| Field | Latest checkpoint |
| --- | --- |
| Observed at | `2026-11-08T05:50:53+03:00` (Europe/Moscow); evidence times below identify the individual observations |
| Coordinator / session | ChatGPT coordinator; G0/G1 WD implementation/review sessions completed; separate G2a WD implementation completed, independent review underway |
| Active objective / gate | G1 amended-source review/native validation; G0 tester access and physical fault confirmation remain open |
| Remote base at session start | `4be8724f244cd2e478f5d6877f798986fcaa2ae9`; refresh before editing |
| Working branch / exact commit | G1 PR #4 / `work/passive-audio-0.2.2`, tested head `f8d1eed0aaf3f2d8e195bdd2424f183d0b472c03`; current amendments have no recorded final SHA yet. G0 PR #3 merged main at `3f7716` |
| Working directory / owner | Separate G1 integration worktree; runtime, capture and documentation owners work within assigned paths; coordinator owns integration, publication and native validation |
| Changed paths / uncommitted work | Diagnostic timing flags, capture-readiness investigation/correction and evidence documentation; inspect the actual worktree before resuming |
| Confirmed defect and reproduction | Static audit: startup status claimed activity before input, fixed nominal rate label, silent renderer failures, no preserved stage evidence. No hardware root cause established |
| Hypotheses still open | Physical-device failure mechanism; no diagnostic report yet |
| Implemented changes | Input-only Listen, input statistics/spectrum independent of tone, captured-duration cap, no fabricated phase/Replay, retained stopped history and current output gate; G0 watchdog/copy fixes integrated |
| Automated validation / run URLs | Final G0 `d4903b847e610761a4d9c7f94ee58e889a4d6d31` passed 63 core + 21 hosted tests and native builds in [run 42438050312](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42438050312). G1 `f8d1eed0` passed 68 core + 33 hosted tests and native builds in [run 42438775739](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42438775739); current amendments require a new exact-source run |
| Retained artifact | G1 `13600767219`, SHA-256 `9b5fff5e4564eedafda88abc0fc7c721829b5719eca8558e6798a5ee2470573b`, reported expiry 2026-11-15. Its name uses PR merge SHA `463462c20603b10e498edd5389832a8d0eb9fd86`; verified source head is `f8d1eed0`. Earlier G0 artifact identities remain in [the G0 evidence record](../DIAGNOSTIC_RELEASE_VALIDATION.md) |
| Inspected captures | G1 generated four PNGs. Idle was black except for the status bar; DEMO Diagnostics showed healthy synthetic processing, RMS approximately −23 dBFS, peak 0.1034, zero mic callbacks, and app tone gate disabled. Idle readiness/startup cause remains unresolved |
| Independent review / examined commit | WD review of the hash-verified G1 delta over `722ee840` found missing-current-spectrum substitution; correction and regression integrated. Later Copilot review found diagnostic timing flags omitted. Current correction is not covered by the `f8d1eed0` pass |
| Candidate version / build | G0 **0.2.1 (3)** uploaded/processed, tester access blocked; G1 **0.2.2 (4)** amended-source validation and distribution pending |
| Apple validation / upload / processing | G0 [upload run 42438984196](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42438984196) succeeded. ASC build `fbe064d5-c57a-4853-9d40-c0a64b1d3705` observed `2026-11-08T02:39:50Z`: processing `VALID`, upload `COMPLETE`, errors `[]`, warnings `[]` |
| TestFlight group / tester state | **0.2.1 (3) not assigned** to Rhea RF Spanner Internal. Automatic approval review rejected the access grant because recipient scope was absent from upload authorization. Do not retry without explicit approval for that access |
| Physical-device observations | Installation/testing of build 2 reported; no build 3/4 device diagnostic report and no verified physical root cause |
| Running jobs / session IDs / last checked | G0/G1 WD implementation/review sessions completed. G2a thread `01a1b901-b210-78c3-afdb-901b6e80e9f5` completed at **05:48:23 Europe/Moscow** (`2026-11-08T02:48:23.1998890Z`), exit 0 after 845.0827 seconds. Seven new files were transferred with per-file SHA-256 verification from frozen `f8d1eed0`; 39 tests are authored, not executed. Independent review and native validation remain |
| G1 candidate | True Listen/Tone separation; `f8d1eed0` software pass retained, newest amendment and idle-capture finding pending, not delivered |
| G2 status | [Future spatial-context design](G2_SPATIAL_CONTEXT_GATE.md); G2a implementation session is separate and unintegrated. No camera/AR/LiDAR capability has been delivered |
| Blocker / smallest next action | Resolve G1 timing-report and idle-capture findings, run exact amended native CI, and retain G0 group-access approval boundary. Obtain a phone diagnostic report after authorized tester access |

Use explicit time zones in evidence. Machine logs can retain UTC; user-facing
status times are shown in **Europe/Moscow**. Never update a timestamp merely
because an old record was read again.

## Recover after an interruption

Read this checkpoint and inspect the working tree before resuming. Compare its
base with the current remote head. Preserve uncommitted work and other owners'
changes. Resolve a changed base explicitly; do not reset a shared tree or force
update a branch to hide a conflict.

For a recorded Codex or build session, check whether it is still running,
completed, or failed before launching a replacement. Resume the actual session
when supported, or start a new bounded task with the last verified checkpoint.
Keep logs outside real-time code and exclude credentials from published output.

If upload returned an uncertain result, inspect App Store Connect before
retrying. Do not reuse a consumed build number or claim a rollback from a
network error. [TestFlight.md](../TestFlight.md) remains the release procedure.

## Evidence labels

| Label | Required meaning |
| --- | --- |
| Planned | Work is specified; no implementation result is implied |
| Implemented | The change exists in the named files/commit |
| Automatically verified | Named tests/builds actually executed against the identified candidate |
| Device observed | An identified physical device/OS/route produced the recorded observation |
| Blocked | A specific dependency or missing observation prevents the next check |

Use these labels per component. A passing parser fixture does not validate an
external probe, a successful DEMO does not validate microphone acquisition,
and shared AR coordinates do not validate inter-device phase synchronization.
Update the next action to the smallest experiment that resolves the remaining
uncertainty.

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
| Active project gate | **G0: diagnostics and evidence-backed runtime fixes** |
| Intended next candidate | **0.2.1 (3)**, subject to release/build verification; not a delivery claim |
| Hardware evidence needed | A diagnostic capture from the installed candidate, including the selected mode, route, actual format, advancing stage counters, and any stop/error reason |

The brief is not proof of its general claims about agent performance or the
frequency of particular bugs. Diagnose this app from its source and execution.
The new user report supersedes the old report's “installation unobserved” state
for physical installation only; it does not establish measurement accuracy.

## Next bounded objective

Produce a reviewed diagnostic candidate that can explain a failed session from
the phone itself. Fix defects for which the code or a reproduction supplies
evidence. Preserve a clear route to passive audio and later spatial/external
sources, without adding them all to this build.

The immediate gate is now the four follow-ups from the latest Copilot review:
JSON-preview copy behavior, the first callback-window baseline, troubleshooting
after Stop, and microphone-watchdog coverage. Complete those corrections and
validate their exact source before merging or uploading G0. G1 Listen remains
an isolated **0.2.2 (4)** candidate with native validation pending.

1. Confirm the current remote head and isolated working tree. Read any project
   instructions, the latest checkpoint, and changed files before editing.
2. Inspect the existing audio, DSP, main-actor, and Metal boundaries. Classify
   findings as reproduced defect, code-supported risk, or hardware hypothesis.
3. Implement bounded stage diagnostics and a user-visible JSON copy action.
   Exercise DEMO and deterministic self-test without claiming a hardware pass.
4. Reproduce and fix selected defects; add targeted regression tests that
   distinguish the repaired behavior from the failure.
5. Run the relevant core tests and native CI for the exact candidate. Record
   commands, commit/run identities, actual results, and unexecuted checks.
6. Review the complete candidate independently, including source provenance,
   callback work, privacy text, and the release/build identifiers.
7. Deliver through the existing reviewed signing/upload workflow when the
   candidate is ready. Record Apple validation, upload, processing, internal
   tester availability, and phone observations as separate stages.
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
| Observed at | `2026-11-08T05:18:57+03:00` (Europe/Moscow) |
| Coordinator / session | ChatGPT coordinator; all three bounded WD Codex implementation/review sessions completed |
| Active objective / gate | G0 diagnostics and LIVE repair |
| Remote base at session start | `4be8724f244cd2e478f5d6877f798986fcaa2ae9`; refresh before editing |
| Working branch / exact commit | `work/diagnostics-0.2.1`; latest native-verified source `722ee840ae8f72d01cec0a3016fa8f52320726c4`; subsequent review-fix commit not yet recorded |
| Working directory / owner | Isolated G0 integration worktree; coordinator owns publication, assigned follow-up corrections are in progress. G1 remains in a separate integration tree |
| Changed paths / uncommitted work | App diagnostic UI and runtime, renderer, portable diagnostics/self-test, hosted/core regressions, generated project, version configuration, English docs |
| Confirmed defect and reproduction | Static audit: startup status claimed activity before input, fixed nominal rate label, silent renderer failures, no preserved stage evidence. No hardware root cause established |
| Hypotheses still open | Physical-device failure mechanism; no diagnostic report yet |
| Implemented changes | Measured stage counters, bounded event log, local JSON preview/copy, silent analytical self-test, LIVE stall stop reason, full-band Waterfall with peak-preserving downsampling |
| Automated validation / run URLs | Latest [run 42436184984](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42436184984) succeeded for `722ee840`: 63 core + 16 hosted tests, zero failures; core Release, Simulator Debug, unsigned device Release, and four native PNGs passed. Waterfall visually inspected; full-width input readout is legible. Subsequent review fixes require another exact-source run; see [validation record](../DIAGNOSTIC_RELEASE_VALIDATION.md) |
| Retained artifact | `13598909772`, SHA-256 `8f035b1ed24a7ec3e8f01c4d87480d89b0f0cd5251c07bf3ef245be4253a3838`; copied to WD |
| Independent review / examined commit | Earlier WD review of `ca444241` led to event-clock, Unicode-cap, GPU-timing and privacy corrections. Copilot findings after the `722ee840` pass are corrected locally: JSON preview selection disabled, callback-window baseline fixed, troubleshooting retained after Stop, and five model regressions added. Exact amended-source native CI remains required |
| Candidate version / build | intended `0.2.1` / `3`; verify before dispatch |
| Apple validation / upload / processing | No 0.2.1 (3) upload dispatched; pending for the amended candidate |
| TestFlight group / tester state | pending for the new candidate |
| Physical-device observations | Installation/testing of build 2 reported; candidate checks pending |
| Running jobs / session IDs / last checked | The three initial WD Codex sessions completed. G1 implementation `01a1b8d8-4802-7141-b421-899b250ca717` exited 0 after 674.7667 seconds at 05:00:18 Europe/Moscow. A subsequent read-only WD Codex review of its 19-file delta started at `2026-11-08T02:15:44.4921467Z`; inspect `passive-review-022-state.json` before resuming. G1 native validation is pending. G0 follow-up corrections are ready for publication; no amended CI run is recorded yet |
| G1 candidate | Intended **0.2.2 (4)**, true Listen/Tone separation; isolated from G0, not natively verified or delivered |
| Blocker / smallest next action | Complete the four G0 review follow-ups, record the amended SHA, and run exact-candidate CI before merge/upload; then collect a short physical-device diagnostic report |

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

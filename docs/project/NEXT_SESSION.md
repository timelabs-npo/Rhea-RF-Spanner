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
| Installed release application source | `9bed85a1787aafabd919994e38eae66d3169c448` |
| Published delivery evidence | [TestFlight upload and processing report](../TESTFLIGHT_UPLOAD_VALIDATION.md) |
| Reported defect | “Not working”; crash, stall, empty data, unusable controls, and weak physical signal have not yet been distinguished by a device trace |
| Debugging brief | Read `debugging.txt`; it calls for an in-app console, diagnostic JSON, stage statistics, synthetic self-test, and independent review |
| Uploaded diagnostic build | **0.2.1 (3)** processed as VALID; tester-group assignment is blocked pending explicit access authorization |
| Active project gate | **G1: useful passive audio**, with G0 physical fault confirmation still open |
| G1 software / distribution | **0.2.2 (4)** passed final native validation and merged to main; the single TestFlight run succeeded. Apple confirmed build VALID / upload COMPLETE at 2026-11-08T03:51:37Z; tester access is blocked and physical acceptance remains unobserved |
| Hardware evidence needed | A diagnostic capture from the installed candidate, including the selected mode, route, actual format, advancing stage counters, and any stop/error reason |

The brief is not proof of its general claims about agent performance or the
frequency of particular bugs. Diagnose this app from its source and execution.
The new user report supersedes the old report's “installation unobserved” state
for physical installation only; it does not establish measurement accuracy.

## Next bounded objective

Preserve the completed G1 delivery evidence and resolve tester access before
physical acceptance. The single TestFlight run succeeded, its signed IPA/archive
hashes are verified, and App Store Connect confirmed build VALID / upload
COMPLETE at `2026-11-08T03:51:37Z`, with empty errors/warnings/infos. Final G1
source `222caea2` passed 68 core,
34 hosted and 10 separate Python recognition tests, native builds and all four
inspected captures. PR #4 merged with identical tracked blobs/modes. Do not
dispatch a duplicate upload or repeat native CI solely for this documentation
update. The earlier launch/capture failures remain in the evidence record.

G0 **0.2.1 (3)** already uploaded and processed as VALID. Internal tester access
was not granted: automatic approval review rejected that action because upload
authorization did not explicitly cover the recipient access scope.
**Do not retry group assignment without explicit authorization for that grant.**

Physical G1 remains unobserved. A successful idle/DEMO capture does not settle
the original device report. G2 is a separate unwired draft in PR #5. Its earlier
run passed core/build checks but timed out while booting Simulator before app
launch. A reviewed fresh-owned Simulator correction is now in source
`3b04192a74833653b6730d0d116abf614552f02b`; exact-source native run
`42445877459` passed 85 core tests, 63 hosted tests, 22 separate Python
fixtures, native builds, four inspected captures and owned-Simulator cleanup.
See [the completed G2 software record](../SPATIAL_MODULE_NATIVE_VALIDATION.md).
The module remains unwired and outside the G1 release.

1. Confirm the current remote head and isolated working tree. Read any project
   instructions, the latest checkpoint, and changed files before editing.
2. Preserve the successful run **42443912311**, verified release artifact and
   payload hashes, and Apple VALID / COMPLETE records for
   `4f5ba9b4-32e9-4189-9658-62cec90fb8ff`. Do not repeat the completed upload or
   confuse Apple processing with authorization to grant tester access.
3. Preserve the final G1 native source and its merge equivalence. Release
   documentation was published at `c830a70c`; subsequent status-only updates
   do not change the uploaded binary or establish hardware acceptance.
4. Keep tester assignment blocked until explicitly authorized. After authorized
   access and installation, obtain the smallest physical Listen diagnostic run
   described in [PASSIVE_AUDIO.md](../PASSIVE_AUDIO.md).
5. Preserve the completed G2 run `42445877459` and its exact-source evidence.
   The next product task is the bounded optional Listen/context
   integration in [the G2 gate](G2_SPATIAL_CONTEXT_GATE.md#next-bounded-task-integrate-optional-listen-context).
   It needs parent-coordinator fixtures and its own exact-source validation;
   an unwired-module pass cannot validate that later change.
6. Leave a checkpoint with the next diagnostic question. If a physical-device
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
| Observed at | `2026-11-08T07:30:02+03:00` (Europe/Moscow); evidence times below identify the individual observations |
| Coordinator / session | ChatGPT coordinator; five bounded G0/G1/G2 WD implementation/review sessions completed; independent review, exact-source G2 native validation and artifact inspection completed |
| Active objective / gate | G1 uploaded and Apple-processed; tester access and physical fault confirmation remain open |
| Remote base at session start | `4be8724f244cd2e478f5d6877f798986fcaa2ae9`; refresh before editing |
| Working branch / exact commit | G1 tested public source `222caea29b040063658cad2288b2e02726d02c73`; PR #4 merged main `dff7c9f7fa99e1df07d8844f7546427119eb1a9e`. All 133 tracked blob hashes and modes match. Local mirror history differs from public history and must not be pushed |
| Working directory / owner | Coordinator owns publication. Actual-Git WD checkout `C:\Users\wheel\RheaWork\Rhea-RF-Spanner-merge-audit-2afb-3dba2714` is clean at detached `3b04192a`, with no pending merge; older dirty WD worktrees were preserved. It is a verified starting point for a new isolated integration branch |
| Changed paths / uncommitted work | Main status update is documentation only: roadmap, G2 integration gate, this checkpoint and SPATIAL_MODULE_NATIVE_VALIDATION.md. G1 binary/source remains fixed. Inspect the actual worktree and current remote refs before resuming |
| Confirmed defect and reproduction | G0 stage observability defects repaired. Simulator inspection reproduced an off-screen Start action, corrected by the bottom dock; wrapped-label capture rejection corrected and natively verified. No physical-device root cause established |
| Hypotheses still open | Original physical-device failure mechanism; original d371 attempt-1 launch/cleanup timeout cause. Later successful UI capture does not establish either cause |
| Implemented changes | Input-only Listen, independent levels/spectrum, captured-duration cap, no fabricated phase/Replay, retained stop evidence/current output gate, timing flags in diagnostics, visible Start/Stop dock and strict capture readiness |
| Automated validation / run URLs | G1 [run 42443019975](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42443019975), attempt 1, job 128616065718: **68 core + 34 hosted**, 0 failures; **10 separate Python tests**; Core Release, Simulator Debug, unsigned device Release and native Vision-helper compilation passed. Separate Python/Actions CodeQL checks succeeded. Historical G0 and failed G1 attempts remain in their evidence records |
| Retained artifact | G1 `13602418489`, name `rhea-rf-spanner-build-68044aaac4877d4d5d56c099068a2d94b06c65e8-attempt-1`, SHA-256 `a4cd2be370597dd6d7eea37b271bf427861bdbed12ff441c49bed71ab1d0a5ca`, expiry 2026-11-15. Download/hash verified on WD at `C:\Users\wheel\RheaWork\ci-42443019975` |
| Signed release artifact | `13602429233`, name `rhea-testflight-222caea29b040063658cad2288b2e02726d02c73-build-4`, SHA-256 `d230f9626b1e0e87f8fce8aed2e0be513f40c3a36190747e03e142c6ded46662`, expiry 2026-11-11; downloaded/hash verified on WD at `C:\Users\wheel\RheaWork\release-0.2.2-4`. Actual IPA/archive hashes independently match the manifest; exact values and toolchain are in [PASSIVE_AUDIO_VALIDATION.md](../PASSIVE_AUDIO_VALIDATION.md) |
| Inspected captures | All four final PNGs inspected: idle Start fully visible, LIVE Listen/MIC OFF/not started/hatched missing spectrum; DEMO Field caption and Stop visible; Waterfall synthetic spectrum with axes and Stop; Diagnostics healthy running DEMO, tone gate No, 0 mic callbacks. Full timing/level evidence is in [PASSIVE_AUDIO_VALIDATION.md](../PASSIVE_AUDIO_VALIDATION.md) |
| Independent review / examined commit | Missing-spectrum substitution and diagnostic timing-flag findings corrected; layout and capture-readiness corrections included in tested `222caea2`. Native/visual evidence applies to that source and its verified identical merge |
| Candidate version / build | G0 **0.2.1 (3)** uploaded/processed, tester access blocked; G1 **0.2.2 (4)** software gate passed/merged, uploaded and Apple-processed; tester access blocked |
| Apple validation / upload / processing | G1 [run 42443912311](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42443912311) dispatched **once**, succeeded; validation job 128618729126 and signing/upload job 128618751852 passed. Direct ASC observation at `2026-11-08T03:51:37Z`: build/upload `4f5ba9b4-32e9-4189-9658-62cec90fb8ff`, build 4, pre-release version `3fade264-4944-4c1d-acf1-c56b85e0a865` = 0.2.2 IOS, build VALID / upload COMPLETE, errors/warnings/infos empty. Earlier PROCESSING observation is retained in the evidence record. G0 previously observed VALID/COMPLETE in ASC build `fbe064d5-c57a-4853-9d40-c0a64b1d3705` at `2026-11-08T02:39:50Z` |
| TestFlight group / tester state | New-build access assignment remains blocked. Automatic approval review rejected granting Rhea RF Spanner Internal access because recipient scope was absent from upload authorization. Do not retry without explicit approval for that access |
| Physical-device observations | Installation/testing of build 2 reported; no build 3/4 device diagnostic report and no verified physical root cause |
| Running jobs / session IDs / last checked | G1 TestFlight run 42443912311 completed and Apple processing is VALID / COMPLETE. Five bounded WD Codex sessions have completed; no WD implementation session remains running. G2 native run 42445877459, job 128624574730, completed successfully at exact `3b04192a`; logs and artifact inspected. No further native run is required for this documentation-only update |
| G1 candidate | True Listen/Tone separation; final native and visual gates passed at `222caea2`, merged to main; uploaded and Apple-processed; tester access blocked and physical behavior unobserved |
| G2 status | Separate unwired draft [PR #5](https://github.com/timelabs-npo/Rhea-RF-Spanner/pull/5), source `3b04192a74833653b6730d0d116abf614552f02b`. Native [run 42445877459](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42445877459) passed **85 core + 63 hosted tests**, 0 failures, **22 separate Python fixtures**, Core/Simulator/device builds, four inspected captures and owned shutdown/delete. Individual log case counts confirm 85/63 passes without skipped-case lines or expected-failure mentions. Earlier boot failures remain historical; no integrated or delivered camera/AR/LiDAR capability is claimed |
| G2 retained artifact | `13603354015`, name `rhea-rf-spanner-build-2d4e7030b2d7d2d9b1ee4df7de64ba34bccb17d6-attempt-1`, SHA-256 `b68352ac99bc1487a27d0bd379aec93dc64e36f6f7dbe704b3375e33b0a5e777`; 3,142,991 bytes, 174 extracted files, expiry 2026-11-15. Download/hash verified at `C:\Users\wheel\RheaWork\ci-42445877459`. [Full native module evidence](../SPATIAL_MODULE_NATIVE_VALIDATION.md) records suite/capture/lifecycle results |
| G2 history resolution | Actual merge base was `d371a6df`. A normal isolated Git merge found conflicts only in the capture script and its tests. Resolved tree `9a9c9533d90e23d71c92bd0d204f219fdd7ce92d` equals reviewed `2afb5640` exactly. Published `3b04192a` records parents `2afb5640` and main `c830a70c`; mergeability was verified against that main commit. All 143 reviewed blobs/modes are preserved. Refresh later main documentation before the next integration task |
| Blocker / smallest next action | Preserve blocked tester access and do not duplicate the completed upload. After explicit access authorization and installation, obtain a physical Listen report. The G2 software module gate is complete; the next code task is scoped optional-context parent integration and its own validation. Timing association remains unavailable |

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

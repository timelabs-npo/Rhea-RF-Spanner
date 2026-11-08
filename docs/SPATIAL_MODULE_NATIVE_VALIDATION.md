# G2 spatial module: completed native software gate

**Observed 2026-11-08.** This record covers the **unwired G2 module**, not a new
TestFlight release or a physical camera/audio experiment. G1 **0.2.2 (4)** is a
separate uploaded and Apple-processed release. The module remains draft
[PR #5](https://github.com/timelabs-npo/Rhea-RF-Spanner/pull/5).

## Exact source and provenance

| Item | Verified identity |
| --- | --- |
| Tested source | `3b04192a74833653b6730d0d116abf614552f02b` |
| Native run / attempt | [42445877459](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42445877459) / 1 |
| Native job | `128624574730` |
| Job conclusion | `success` |
| Source evidence | Job checkout output and capture manifest `source_commit` both identify `3b04192a` |
| Full source tree | `9a9c9533d90e23d71c92bd0d204f219fdd7ce92d`; all 143 blobs and modes match the reviewed coordinator mirror |
| Toolchain | Xcode 26.3, build 17C529; Apple Swift 6.2.4 |
| Simulator | iPhone 17 Pro model, iOS 26.0 runtime; this is not a physical iPhone observation |

The [module contract](https://github.com/timelabs-npo/Rhea-RF-Spanner/blob/3b04192a74833653b6730d0d116abf614552f02b/docs/SPATIAL_CONTEXT.md)
and [earlier review/failure history](https://github.com/timelabs-npo/Rhea-RF-Spanner/blob/3b04192a74833653b6730d0d116abf614552f02b/docs/SPATIAL_CONTEXT_VALIDATION.md)
remain available at that frozen source. Their pre-run checkpoint is superseded
by the execution results here, without erasing the earlier failures.

## Actual build and test results

| Check | Observed result |
| --- | --- |
| Core production build | Passed |
| Core XCTest suite | 85 executed, 0 failures; includes 17 SpatialContextPolicyTests |
| iOS Simulator Debug app | BUILD SUCCEEDED |
| Unsigned iOS device Release app | BUILD SUCCEEDED |
| Python capture/lifecycle fixtures | 22 executed, OK; separate from Swift counts |
| Simulator-hosted XCTest suite | 63 executed, 0 failures; TEST SUCCEEDED |
| Native captures | Four required visible-content gates passed; all four final PNGs inspected by the coordinator |

The hosted log contains these suites:

| Suite | Executed | Failures |
| --- | ---: | ---: |
| DiagnosticsIntegrationTests | 11 | 0 |
| ObservatoryRendererTests | 10 | 0 |
| ObservatorySessionTests | 2 | 0 |
| PassiveAcquisitionTests | 4 | 0 |
| PassivePresentationTests | 7 | 0 |
| SpatialContextIntegrationTests | 26 | 0 |
| SpatialPresentationTests | 3 | 0 |
| **Total** | **63** | **0** |

Individual passed-case lines independently total **85** in `swift-test.log`
and **63** in `xcode-session-tests.log`. Neither log contains a skipped-case
line or expected-failure mention. A separate Swift Testing discovery message
reporting zero tests does not replace or add to the XCTest count.

## Captures and inspected content

| Final PNG | Readiness elapsed | Screenshot/OCR observations | Inspected content |
| --- | ---: | ---: | --- |
| `01-idle.png` | 22.652 s | 2 | Complete bottom-dock Start listening; LIVE Listen, MIC OFF, not-started status and hatched missing spectrum. The action is disabled on Simulator as intended |
| `02-demo-field.png` | 10.808 s | 2 | DEMO SYNTHETIC, SYNTHETIC FIELD and Stop visible; approximately -23 dBFS RMS, peak 0.1068 FS |
| `03-demo-waterfall.png` | 11.848 s | 2 | Synthetic spectrum with frequency/time axes, visible Stop and approximately 4.1 s history; peak 0.1046 FS |
| `04-demo-diagnostics.png` | 8.359 s | 1 | Healthy running DEMO, approximately -23 dBFS RMS, peak 0.1039 FS, app tone gate No, microphone callbacks 0, last buffer unavailable |

These are screenshot/OCR observations within one launch per scenario, not
application relaunches. Readiness includes capture and recognition work; it is
not a physical-device startup or sensor-latency benchmark. All gates completed
inside the unchanged **45-second** limit. No microphone or camera was started
by these capture scenarios; the pictures exercise the existing idle/DEMO UI.

## Owned Simulator lifecycle

The manifest retains successful installed `simctl help create`, `shutdown`
and `delete` output and actual model/runtime identifiers. It records one
explicitly created, verified owned instance:

- Model: `com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro`.
- Runtime: `com.apple.CoreSimulator.SimRuntime.iOS-26-0`.
- UUID: `062CE666-6680-4008-9DE1-D2E134AC3DAF`.
- Name: `Rhea-Capture-93d50431c5af46d796062bbe603cb531`.

| Operation | Return code | Elapsed | Limit |
| --- | ---: | ---: | ---: |
| Create | 0 | 0.422 s | 60 s |
| Boot | 0 | 5.246 s | 90 s |
| Boot status | 0 | 98.150 s | 480 s |
| Owned shutdown | 0 | 5.109 s | 10 s |
| Owned delete | 0 | 0.590 s | 10 s |

The first idle launch correctly skipped prelaunch termination only for the
fresh owned instance. Later scenarios retained their termination step. Hosted
tests ran after all captures and before cleanup. Final manifest states are
`run_status = complete`, `phase = complete`, `capture_status = complete`,
`hosted_tests_status = passed` and `cleanup_status = complete`.

No failure occurred in this run. This establishes a successful fresh-instance
execution, not the underlying cause of the previous Simulator command hangs
or a guarantee against future infrastructure failures.

## Retained artifact

[Artifact 13603354015](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42445877459/artifacts/13603354015):

- Name: `rhea-rf-spanner-build-2d4e7030b2d7d2d9b1ee4df7de64ba34bccb17d6-attempt-1`.
- Archive size: **3,142,991 bytes**; 174 extracted files.
- SHA-256: `b68352ac99bc1487a27d0bd379aec93dc64e36f6f7dbe704b3375e33b0a5e777`.
- Reported expiry: **2026-11-15**.
- Downloaded and hash-verified on WD at `C:\Users\wheel\RheaWork\ci-42445877459`.

The artifact-name SHA is a PR merge identity. Attribution uses the actual
checkout and manifest source **`3b04192a`**, also present in the artifact's
workflow metadata. The downloaded ZIP hash matches the API/upload digest.

## History resolution and next gate

A fresh actual-Git checkout confirmed merge base `d371a6df` and reproduced
conflicts only in the capture script and its test file. Resolving those two
paths to reviewed source `2afb5640` produced an identical complete tree.
Commit `3b04192a` records first parent `2afb5640` and second parent main
`c830a70c`; no reviewed blob or mode changed. The new WD checkout is clean at
that actual merge, with no pending merge state:
`C:\Users\wheel\RheaWork\Rhea-RF-Spanner-merge-audit-2afb-3dba2714`.
Older dirty worktrees were preserved.

The app still has **no user-accessible camera context or camera permission
request**. These results do not establish physical microphone, camera, LiDAR,
AR tracking, simultaneous audio/camera operation, timing association or source
localization. No G2 TestFlight version or upload is assigned by this record.

The [next bounded integration task](project/G2_SPATIAL_CONTEXT_GATE.md#next-bounded-task-integrate-optional-listen-context)
connects optional camera context to LIVE Listen, with complete parent lifecycle
tests and a subsequent physical context-off/context-on comparison. It retains
**Audio/pose timing not associated** until the separate clock gate is closed.

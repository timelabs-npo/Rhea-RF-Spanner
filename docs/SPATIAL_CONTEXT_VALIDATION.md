# G2a spatial module: review and validation record

This is an **unwired development module**, separate from the G1 passive-audio
release. The ordinary app still opens Listen; it exposes no camera or spatial
start control. Compiling the module and running fixtures will not establish a
working combined microphone/camera session or audio/pose association.

## Source provenance

The WD Codex Full Access session `01a1b901-b210-78c3-afdb-901b6e80e9f5` worked
against frozen public source `f8d1eed0aaf3f2d8e195bdd2424f183d0b472c03`. It
started at `2026-11-08T02:34:18.1171535Z` and completed at
`2026-11-08T02:48:23.1998890Z` (05:48:23 Europe/Moscow), exit 0 after
845.0827 seconds. It added exactly seven assigned source/test/documentation
files, without editing tracked files or the index, generating the project,
publishing, or reading signing material.

The seven files were transferred with byte counts and individual SHA-256
verification. The canonical export JSON SHA-256 was
`92dba40960c769d1d2607f34946c4a12c352a2d903e48ab27f5464bb0f3a703b`.
The original output authored 14 core policy tests and 25 hosted fixtures;
**none ran on WD**. Static file-scope checks and a successful session exit are
not native compilation or hardware evidence.

The isolated coordinator tree subsequently adopted the G1 review amendment
`3633e980c0c42e9a00259593c96a7341514d664f`, including the visible-content
Simulator capture gate. Project generation registers the new sources and
hosted tests for native compilation. G1's prior test results do not validate
these spatial additions.

Before publication, the module adopted G1's reviewed layout correction
`d371a6df323ee502c5a724d62f50ae070c813c85`. This fixes the native-observed
off-screen Listen action and keeps the scientific caption visible. The G2
branch uses the same strict visible Start/Stop capture gate; it does not weaken
that gate to accommodate its unrelated module tests.

## Independent review

Separate reviews examined runtime ownership and measurement semantics before
integration. They confirmed that ARFrame and pixel-buffer objects remain local
to the delegate callback; only bounded scalar/SIMD metadata crosses the mutex.
The explicit parent-stop contract remains an integration requirement. Fakes do
not establish physical camera release or audio-route stability.

Two concrete findings were corrected before native validation:

1. **Tracking-only invalidation:** tracking was read only from delivered frames.
   An ARKit tracking-change notification could leave a previously accepted pose
   visible until another frame or watchdog expiry. The scalar observer event
   now closes the accepted epoch without advancing frame arrival, capture time,
   or frame counters. A normal notification alone cannot satisfy recovery.
   It reports recovery only when an actual previous frame exists; before the
   first frame it remains awaiting frames. Timing/transform faults stay distinct.
2. **Pose-status wording:** normal AR tracking with invalid timing or a missing
   or invalid transform was presented as ordinary recovery. The panel now
   distinguishes AR tracking from accepted-pose status and names the actual
   rejection. Its time label uses the first **valid** AR timestamp as origin.

The amended module authors 17 core policy tests, 26 hosted integration/depth
fixtures and 3 hosted presentation tests. These include unchanged-deadline and
coalesced loss/normal-notification regressions. Authored counts remain separate
from executed counts below.

The tracking notification contract is documented by
[Apple's session observer API](https://developer.apple.com/documentation/arkit/arsessionobserver/session(_:cameraDidChangeTrackingState:)).
Depth remains a patch value in meters from the camera plane, with categorical
confidence; it is not a source location or a calibrated error bound. See
[Apple's ARDepthData description](https://developer.apple.com/documentation/arkit/ardepthdata).

## Native gate — first compile finding corrected, rerun pending

[Native run 42441755655](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42441755655)
checked exact public source `6a364a96acb06064a2a8fa43e87e4ce8eaa92477`.
Core Release compiled and **85 core tests passed with zero failures**, including
the 17 spatial policy tests. Simulator compilation stopped at
`SpatialContextController.swift:564`: `sceneReconstruction = .none` is
unavailable for that option set. Unsigned device compilation, native captures
and hosted tests did not execute in this run.

The correction uses the empty option set `sceneReconstruction = []`. Review
confirmed adjacent option-set assignments already use array literals;
`environmentTexturing = .none` is an enum case and remains unchanged. Native
validation of this correction is pending. The required gate compiles Simulator
Debug and unsigned device Release, executes the existing G1 regressions plus
spatial fixtures, and verifies native capture readiness. No complete native
pass is claimed at this checkpoint.

## Integration and physical gate — not executed

The coordinator proposal in [SPATIAL_CONTEXT.md](SPATIAL_CONTEXT.md) remains a
proposal. Wiring requires accurate camera permission text, explicit combined
start, complete combined teardown and foreground/route monitoring. Existing
G1 hardware evidence must be kept separate from combined-session evidence.

On a real device, compare context-off and context-on audio category, mode,
route, input format and advancing microphone/DSP/AR counters; exercise denial,
interruption, backgrounding, tracking loss, timeouts and repeated starts.
Record camera release and supported/unsupported depth behavior. No pose or
depth fixture closes the separate AR/audio clock-association gate.

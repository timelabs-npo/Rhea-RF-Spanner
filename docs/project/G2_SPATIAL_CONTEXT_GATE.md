# G2: camera and spatial context for passive audio

**Integration design — 2026-11-08.** Originally prepared against the Rhea RF
Spanner roadmap and the G1 worktree. The separate G2a module is now an unwired
draft; its source and execution history are in the
[draft validation record](https://github.com/timelabs-npo/Rhea-RF-Spanner/blob/3b04192a74833653b6730d0d116abf614552f02b/docs/SPATIAL_CONTEXT_VALIDATION.md).
That exact draft passed native builds, 85 core tests, 63 hosted tests, 22
separate Python tests and four inspected captures in
[run 42445877459](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42445877459).
The [completed native evidence](../SPATIAL_MODULE_NATIVE_VALIDATION.md) is
separate from the still-open integration and physical sensor gates.
G1 0.2.2 (4) has passed its software and Apple processing gates; tester access
and physical acceptance remain open. This design does not establish G2 app
integration, delivery, simultaneous sensor operation or capture-time association.

## Decision: context first, verified association next

The smallest useful increment is **an optional camera view beside LIVE Listen,
with AR camera-pose status and an optional scene-depth readout**. It helps the
operator see the inspected object and whether spatial tracking is usable while
watching the existing audio level/spectrum. It does not yet color surfaces with
audio measurements.

Use two bounded steps:

| Step | User-visible result | Completion boundary |
| --- | --- | --- |
| **G2a — Context preview** | Camera view, estimated camera pose, tracking state/epoch, optional depth, and existing audio readouts with **“Audio/pose timing not associated”** | Native lifecycle tests and a physical simultaneous camera/Listen run. No capture-time fusion claim. |
| **G2b — Timed observation association** | An audio window can refer to a camera pose with a recorded time mismatch, clock-mapping evidence, and explicit unavailable states | A verified clock relationship, targeted matching tests, and a device timing/registration experiment. G2 remains incomplete until this evidence exists. |

Keep camera optional and off by default. The first integration supports Listen
only. Tone, DEMO, and Replay retain their current behavior with camera context
off. Mesh reconstruction, spatial interpolation, sound-source localization,
photo/video recording, RF input, shared maps, and multi-phone synchronization
are outside these steps. Camera false color cannot supply thermal or RF data;
camera pose and LiDAR depth do not make an acoustic tomogram.

## Existing contracts to preserve

The inspected G1 source has these relevant boundaries:

- `App/Sources/AudioTransceiver.swift`: `CaptureContext.receive` normalizes
  hardware sample time to a run-relative integer index. It records whether host
  time is valid but does not preserve a host-time anchor for spatial matching.
  The input tap is the sole producer of the existing Float SPSC queue.
- `Sources/RheaRFCore/AudioAnalysisFrame.swift`: each analysis window carries
  its sample index, timing validity/continuity, statistics, optional spectrum,
  and optional tone result. Listen requests no tone result.
- `App/Sources/ExperimentModel.swift`: the main actor owns runs, publishes
  results, rejects old-run output, and controls the 60-second limit and stop
  policy. Camera events must not become a second owner of the audio engine.
- `App/Sources/MetalPhaseRenderer.swift`: passive display identity is separate
  from the carrier-bearing `SpatioTemporalSlice`. Keep the existing 64-byte
  active/DEMO Replay encoding unchanged; no G2 pose or depth should be squeezed
  into it.
- Diagnostics export bounded aggregates and relative in-app intervals, not
  absolute host/uptime clocks, raw audio, images, or spectrum arrays. Camera and
  pose objects must not become automatically encoded report fields.

Those are source observations, not proof of simultaneous camera/audio hardware
operation. A usable physical G1 trace remains the baseline for interpreting
any later combined-session failure.

## Verified Apple API facts and their limits

These facts are documented by Apple. The implementation choices in later
sections are proposed Rhea policy.

| Documented fact | Consequence for this gate |
| --- | --- |
| `ARFrame` contains a captured image and camera information from that capture; `ARFrame.timestamp` identifies capture time. See [AR frame](https://developer.apple.com/documentation/arkit/arframe) and [Metal AR rendering](https://developer.apple.com/documentation/arkit/displaying-an-ar-experience-with-metal). | Obtain image, pose, and frame identity from one frame. Main-actor delivery time is not capture time. |
| The retrieved [`ARFrame.timestamp` reference](https://developer.apple.com/documentation/arkit/arframe/timestamp) specifies capture time but does not state an epoch shared with `AVAudioTime`. | This review has not established an Apple contract permitting direct subtraction of AR timestamps and audio host seconds. Similar numerical values are insufficient evidence. |
| [`AVAudioTime`](https://developer.apple.com/documentation/avfaudio/avaudiotime) can represent the same instant as sample time, Mach-based host time, or both. It exposes separate validity flags and conversion methods. | Preserve valid sample/host anchor pairs internally before attempting audio-to-pose timing. A run-relative sample index alone does not locate that run on another clock. |
| [`ARCamera.transform`](https://developer.apple.com/documentation/arkit/arcamera/transform) represents camera position/orientation in a right-handed world space. [`worldAlignment`](https://developer.apple.com/documentation/arkit/arconfiguration/worldalignment-swift.enum) determines its orientation/origin convention. | Name transforms `worldFromCamera`; use `.gravity` for this gate. Do not present compass heading, global coordinates, or a calibrated microphone position. |
| [`sceneDepth`](https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.struct/scenedepth) is a LiDAR-supported frame semantic associated with the current camera frame. Check it on `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)` before enabling. | Camera/pose can work without LiDAR. Missing/unsupported depth stays unavailable; it never becomes a zero distance. |
| [`ARDepthData`](https://developer.apple.com/documentation/arkit/ardepthdata) describes depth in meters from the camera plane, with an optional confidence map. [`smoothedSceneDepth`](https://developer.apple.com/documentation/arkit/arframe/smoothedscenedepth) averages across frames. | Use unsmoothed `sceneDepth` first and label the depth convention. Confidence categories are not calibrated error bars or probabilities. |
| [`capturedDepthDataTimestamp`](https://developer.apple.com/documentation/arkit/arframe/captureddepthdatatimestamp) belongs to front-camera depth experiences and is zero for other configurations. | Do not use it as a rear LiDAR timestamp. Retain scene depth's association with its AR frame; do not invent a separate laser-sampling clock. |
| [`ARView.automaticallyConfigureSession`](https://developer.apple.com/documentation/realitykit/arview/automaticallyconfiguresession) defaults to automatic configuration; [`init(frame:cameraMode:automaticallyConfigureSession:)`](https://developer.apple.com/documentation/realitykit/arview/init(frame:cameramode:automaticallyconfiguresession:)) accepts explicit manual control. | Construct the preview with automatic configuration disabled. View construction, layout, and inspection must not start a camera session. |

## G2a implementation design

### One camera pipeline, separate from audio processing

Use a `RealityKit.ARView` wrapped for SwiftUI as the camera background. Let that
framework render its camera feed; the first increment does not add camera pixel
conversion to the existing Metal spectrum renderer. A small overlay or adjacent
panel shows existing audio readouts and spatial status.

Own the AR session in a `SpatialContextController`. Configure an
`ARWorldTrackingConfiguration` with `.gravity`, `providesAudioData = false`, no
plane detection, no scene reconstruction, and `.sceneDepth` only when supported
and selected before the run. ARKit documents camera capture and optional audio
in [ARConfiguration](https://developer.apple.com/documentation/arkit/arconfiguration).
The G1 audio engine remains the sole audio-capture owner. Do not add a competing
`AVCaptureSession` or route AR audio buffers into the same SPSC producer.
Disabling AR audio delivery is not proof that camera/rendering startup leaves
the audio session unchanged. Recheck the observed category, mode, route, and
format during device validation; preserve a mismatch as a failure instead of
silently overriding the session to hide it.

Use `ARSessionDelegate.session(_:didUpdate:)` on a dedicated serial delegate
queue. Apple documents [delegate queue ownership](https://developer.apple.com/documentation/arkit/arsession/delegatequeue).
Copy only immutable scalar/matrix metadata for the app. Read any small depth
summary while the callback holds the frame, then release all app references to
that frame. Do not queue `ARFrame` or `CVPixelBuffer` objects for DSP work, and do
not poll `currentFrame` from the audio callback.

The delegate should coalesce pending UI updates into a bounded latest-value
slot. If metadata history is needed for future association, cap it at **128
snapshots** and count overwritten entries. Use a real serialized owner or
mutex for this non-audio state; a two-slot array with only an atomic active
index is not a safe reader/writer ownership protocol. Never acquire that mutex
from the audio callback. Swift 6 actor/conformance correctness must pass native
compilation; `@unchecked Sendable` is not a substitute for that ownership model.

### Minimum metadata

| Value | Meaning and lifetime |
| --- | --- |
| `spatialRunID`, `coordinateEpoch`, `frameSequence` | App-local identifiers; no device identity. Every explicit context start gets a fresh run. |
| `arCaptureElapsedSeconds` | AR timestamp minus this AR run's first valid AR timestamp, still labelled **AR capture clock**. It is not yet comparable to audio-run elapsed time. |
| `receivedElapsedSeconds` | Relative arrival time on the app's own monotonic interval clock; diagnostic scheduling evidence only. |
| `worldFromCamera`, tracking state/reason | AR camera pose estimate for this frame and epoch. A finite transform alone does not make tracking valid. |
| `depthSummary?` | Frame-associated image-center depth, confidence/category, valid sample count, and unavailable reason. No depth buffer is retained. |
| `associationStatus` | `notRequested`, `clockMappingUnavailable`, `trackingUnavailable`, `timingUnavailable`, `stale`, or a later qualified association. G2a never reports synchronized capture. |

Keep these types outside the v1 Replay codec. They should not conform to report
encoding merely because they are convenient state containers. Pure shared
types can use Swift scalar/SIMD values without importing ARKit into `RheaRFCore`.

### Optional depth stays small and interpretable

Start with a **3 × 3 image-center patch**, not a surface map. This is a declared
design choice, not an Apple accuracy guarantee. Accept finite positive depths
with at least medium categorical confidence; require at least five accepted
pixels and display their median plus the accepted count. Missing confidence
means the filtered summary is unavailable. Do not silently treat it as high.

Check pixel formats, dimensions, row stride, and successful buffer locking
before reading. Support the documented runtime formats deliberately rather than
blindly casting memory; Apple describes inspecting the formats of
[`depthMap`](https://developer.apple.com/documentation/arkit/ardepthdata/depthmap)
and [`confidenceMap`](https://developer.apple.com/documentation/arkit/ardepthdata/confidencemap).
Unlock with `defer`. A missing depth frame clears the current value or marks it
explicitly stale; it must not display an old value as a current measurement.

Label this **“Image-center scene depth · meters from camera plane”**. Do not
draw a reticle claiming a screen-space ray until image/view orientation and
cropping have their own tested transform. The depth readout neither identifies
an acoustic reflector nor locates the sound source.

## Honest time association: G2b contract

### What must not be used as synchronization

Do not associate observations by callback number, by `DispatchQueue.main`
arrival order, by the most recent frame, or by subtracting the first timestamp
from each stream and declaring both zeroes simultaneous. UI throttling and
camera/audio pipeline delays would become hidden measurement error. Do not add
absolute host ticks to copied diagnostics to solve this problem.

G2a therefore displays independent observations. It may report relative arrival
ages, but it must label them arrival ages and leave capture-time association
unavailable. This is a usable context preview, not completion of the G2 fusion
gate.

### Add a private audio clock bridge in a later bounded task

When both `AVAudioTime` validity flags are true, preserve a small anchor
`(audioRunID, normalizedSampleIndex, hostTicks, sampleRate)` from the same input
callback. Use a preallocated typed metadata queue with the same single producer
and serial DSP consumer. Never pack ticks into Float samples or add a second
reader to the existing audio ring. Queue overflow, incompatible rate, invalid
anchors, and clock discontinuities invalidate that clock segment.

For a valid anchor `(n_a, h_a)` at or before the window's first sample and private
run origin `h_0`, the proposed local mapping for a window beginning at sample `n`
is:

$$
t_{audio,mid} = \operatorname{hostSeconds}(h_a-h_0)
 + \frac{(n-n_a)+(N-1)/2}{f_s}.
$$

Compute bounded differences before floating-point conversion; check arithmetic
and monotonicity. Use the audio host-time conversion API rather than assuming
one tick equals one nanosecond. Retain the full window interval as well as its
midpoint: a 2,048-sample window at 48 kHz represents about 42.67 ms of sound, not
an instantaneous event. Compare successive anchor predictions to detect drift
or discontinuities; keep unknown timing error unavailable, not zero.

This only maps audio to the audio host clock. A separate AR-capture-to-host
relationship still needs evidence. Before enabling association, obtain either
a verified SDK/platform clock contract for the supported deployment, or a
documented device calibration with a quantified timing error over the intended
run length. Log the calibration method and scope. Numerical proximity of an AR
timestamp to uptime, callback latency statistics, or a single visual clap is
not a measured bound on capture-clock offset.

If the mapping remains unverified, keep association disabled and retain the
useful context preview. Do not replace this unresolved contract with an
undisclosed assumption. A capture architecture change would be a separate
proposal, not an incidental audio rewrite inside G2a.

### First matching policy after clock verification

Use the nearest valid pose to the audio-window midpoint within the same run and
coordinate epoch; do not interpolate or extrapolate in the first matcher.
Store signed midpoint mismatch, clock-mapping identity, tracking status, and a
temporal uncertainty budget. As an initial engineering policy, accept only if:

$$
U_{clock} + |t_{pose}-t_{audio,mid}| + T_{window}/2 \le 50\text{ ms}.
$$

The **50 ms** limit is a proposed context-association tolerance, not measured
platform performance. It must be reviewed against observed device timing and
the user's measurement task. Unknown `U_clock` fails this gate. Preserve
unmatched windows and reasons; never fill them with a zero position or a stale
pose. This temporal bound is not a spatial accuracy bound.

ARKit reports the **camera** pose. The built-in microphone has a different
physical position and an unspecified extrinsic transform in this design.
Initially call any associated pose **camera context for the audio window**.
Do not claim an exact microphone location without a measured camera-to-microphone
transform, and do not move an audio observation to the depth-patch surface.

## Coordinates, tracking loss, and stops

Use app-scoped coordinate epochs. Matrices from different epochs must not be
joined unless a later feature supplies an explicit verified transform. An
explicit new context run uses fresh session state and reset tracking. Apple
documents that [resetTracking](https://developer.apple.com/documentation/arkit/arsession/runoptions/resettracking)
resets position tracking; normal session runs can otherwise reuse prior state.

Tracking availability is independent of audio quality and depth confidence.
Apple describes initialization, limited states/reasons, and relocalization in
[tracking lifecycle guidance](https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality).
Proposed recovery policy: after tracking becomes limited or unavailable, stop
accepting poses for association, close the current coordinate epoch, and wait
for three consecutive normal, increasing-timestamp frames before opening a new
logical epoch. This debounce is a design threshold, not a pose-accuracy test.
Preserve the AR matrix convention; incrementing the logical epoch does not
claim that ARKit has independently recalibrated its coordinates.

| Event | Proposed G2a behavior |
| --- | --- |
| Explicit Start with context enabled | Check capabilities and permissions first. Start one combined foreground Listen/context run; create a fresh spatial run. Camera startup does not establish usable pose or synchronization. |
| Tracking limited/unavailable, or missing depth | Keep the camera/audio readouts with accurate states; no pose association. Missing depth does not disable supported camera/pose operation. |
| Stop, loss of foreground activity, existing audio stop/failure, or 60-second deadline | End the combined run; stop audio and end the AR session. Retain aggregate reasons; discard image/depth references and invalidate associations. |
| AR failure, interruption, or configured no-frame timeout | End the combined run with a camera-specific reason. No automatic restart. A subsequent explicit start creates new run/epoch state. |
| Switch to Tone, DEMO, Replay, or context-disabled intent | Stop first. The change never starts either sensor. The original audio-only modes remain available without camera permission. |

For interruption handling, Apple warns that calling `pause()` in
[`sessionWasInterrupted(_:)`](https://developer.apple.com/documentation/arkit/arsessionobserver/sessionwasinterrupted(_:))
prevents the interruption-ended notification. Do not perform teardown inline
inside delegate callbacks. The first Rhea policy deliberately abandons the
interrupted combined run through the coordinator; it does not rely on that end
notification to resume. A late callback from the retired run must be ignored.

Proposed initial deadlines are **3 seconds without a first frame after an
authorized session start**, and **2 seconds without a new frame after frame
delivery has begun**. These are reviewable design defaults, not measured device
limits; test their exact boundaries with a fake clock and revise only with
recorded device evidence. They detect absent frame delivery, not normal tracking
initialization. Frame arrival and tracking quality need separate counters.

## Permissions, privacy, and presentation

AR is an optional feature, so use runtime
`ARWorldTrackingConfiguration.isSupported` rather than making AR hardware a
requirement for the entire app. Add an accurate `NSCameraUsageDescription` and
handle authorized, denied, restricted, and not-determined states. Apple explains
the [AR support/permission requirements](https://developer.apple.com/documentation/arkit/verifying-device-support-and-user-permission)
and the explicit
[`AVCaptureDevice.requestAccess(for:)` flow](https://developer.apple.com/documentation/avfoundation/avcapturedevice/requestaccess(for:completionhandler:)).

Selecting context is intent, not permission or capture. Request needed access
only following Start. As in G1, the first permission grant returns to idle;
permissions resolving or returning from Settings must not start sensors. An
unavailable/denied camera leaves an explicit audio-only choice. Do not silently
start a partial combined run when the user requested both.

The preview may contain bystanders, documents, and interiors. State that the app
processes the feed for live context and does not save or upload images, depth
maps, feature points, or world maps in G2a. Do not enable face/body recognition,
Photos saving, GPS, or network sharing. Update in-app help, camera/microphone
purpose strings, privacy policy, review notes, and device test instructions to
match the implemented behavior before submission.

Diagnostic additions should be explicit scalar fields: camera permission/state,
capability booleans, frame/pose/depth counts, tracking reason, overwritten-snapshot
count, relative intervals, and sanitized error domain/code. Exclude pose matrices,
depth arrays, image data, EXIF, feature/world maps, and absolute sensor clocks
from the ordinary report. Preserve the reviewed local-only, expiring Copy path.
If clock APIs expand, review the manifest against Apple's
[required-reason API rules](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype);
the existing 35F9.1 elapsed-event exception is not permission to export raw
host ticks or uptime origins.

UI minimum: **Context off / Starting / Camera active**, tracking state and reason,
coordinate epoch, **Depth unavailable** or the qualified scalar depth, and
**Audio/pose timing not associated**. Show AR position as an estimate in a local
session coordinate system. No millimeter-precision badge, RF heatmap, or
sound-source marker belongs to this gate.

## Original bounded Codex task: context module and fixtures

The original task specification below records the module's scope and ownership.
Its authored implementation is now in the separate draft; execution evidence
belongs in the validation record, not in this specification.

**Task objective:** create a reviewable G2a context module and native preview
wrapper against the coordinator's frozen G1 source, with camera auto-start
disabled, bounded scalar snapshots, optional depth, and deterministic lifecycle
tests. Do not implement G2b clock bridging or audio-to-pose matching in this task.

The implementation session owns these **new files only**:

| Path | Responsibility |
| --- | --- |
| `Sources/RheaRFCore/SpatialContextTypes.swift` | Immutable snapshot/status/epoch types; no Apple frameworks, codecs, or automatic JSON export. |
| `Sources/RheaRFCore/SpatialContextPolicy.swift` | Small pure lifecycle/tracking policy with injected time and explicit unavailable states. |
| `Tests/RheaRFCoreTests/SpatialContextPolicyTests.swift` | State, epoch, stale/late-frame, bound, and invalid-value regressions. |
| `App/Sources/SpatialContextController.swift` | Permission/capability/session adapter, serialized delegate, bounded snapshot handoff, and depth-patch reduction. |
| `App/Sources/SpatialContextView.swift` | Manually controlled ARView wrapper and independently labelled context status. No photo saving or source-location overlay. |
| `AppTests/SpatialContextIntegrationTests.swift` | Session/permission adapter spies, depth-buffer fixtures, preview construction, and teardown behavior; no claim of real camera input. |
| `docs/SPATIAL_CONTEXT.md` | Exact implemented behavior, unresolved clock association, tests actually run, and hardware checks still pending. |

Use a small injectable session/permission boundary so tests can observe start,
stop, and stale callback handling. Avoid building a general sensor framework.
Leave all existing files untouched in this first session. Return an integration
patch proposal, not edits, for the coordinator-owned `ExperimentModel.swift`,
`ExperimentView.swift`, `Info.plist`, privacy/review documents, project generator,
and generated Xcode project. This keeps concurrent G1 corrections isolated.

The coordinator's next bounded step integrates the module with LIVE Listen:
an idle-only context choice, permission preparation, combined start/stop,
the unchanged audio engine, and proper project/resource inclusion. Until that
step is reviewed and built, the module is not a working app feature. No version,
signing, workflow, credential, branch publication, or upload changes belong to
the implementation session.

### Acceptance criteria for that first task

1. Constructing the controller/view, inspecting status, or resolving permission
   never runs AR automatically. Unsupported/denied paths have observable states.
2. Fake-session tests prove explicit start/stop decisions and rejection of old-run
   callbacks. They are described as policy/adapter evidence, not as real camera
   startup or cleanup evidence.
3. Tracking loss closes the epoch; recovery opens a new one only under the
   declared rule. No pose is accepted from an unavailable/limited frame and no
   coordinates are merged across epochs.
4. Depth fixtures include nil confidence, unsupported formats, padded row strides,
   invalid/nonfinite pixels, insufficient accepted pixels, and recovery. Missing
   depth never becomes zero or an unlabelled previous value.
5. Snapshot storage and pending UI work are bounded. No AR frame/pixel buffer
   crosses into the audio callback, and no change touches the audio SPSC or
   existing sample/phase/Replay behavior.
6. Relative AR time and relative receipt time are distinguishable. Association
   remains unavailable even when synthetic clocks happen to have equal values.
7. Portable tests pass on an available Swift host. The coordinator then runs
   exact-source native compilation and hosted tests after project integration.
   A missing toolchain is reported as blocked, never as a pass.

## Next bounded task: integrate optional Listen context

Use the existing `SpatialContextController` and `SpatialContextView`. The
current parent model/view do not own or mount them, and the application has no
camera purpose string. The useful increment is a camera view and independently
labelled pose/depth status beside measured audio levels and Waterfall.

| Integration owner / file | Scoped change |
| --- | --- |
| `App/Sources/ExperimentModel.swift` | Own one controller; context/depth default off. Only explicit LIVE Listen Start prepares both permissions before either sensor starts. A permission resolution returns idle. After audio starts, consume the one-shot camera permit; any failed combined start rolls back both. Forward foreground state and route every stop, deadline, mode change, audio failure and camera stop callback through idempotent combined teardown. Retain the camera reason separately. |
| `App/Sources/ExperimentView.swift` | Add idle-only context/depth choices and mount the existing context panel without hiding the Start/Stop dock. Denied/unsupported camera offers an explicit context-off choice followed by a new Start; never silently start only half of the requested run. Tone/DEMO/Replay keep context off. |
| `App/Sources/AudioTransceiver.swift` and its `ExperimentAudioSession` boundary | Add a narrow read-only running-contract check after AR startup and during existing monitoring. Validate current category/mode, built-in input and actual input format; stop with evidence on mismatch. Preserve the audio graph, sole capture producer and DSP consumer. |
| `App/Sources/SessionDiagnostics.swift`, `DiagnosticsView.swift` and the model snapshot | Add an explicit allowlist of spatial capability/state, counts, relative intervals and stop/error reasons. Do not encode the spatial snapshot wholesale or export matrices, images, maps or absolute clocks. |
| `App/Resources/Info.plist`, in-app help and privacy/review documents | Add accurate camera purpose text before requesting permission; describe optional on-device context and the unsupported-depth path. Review project membership for the exact integrated source. |

The audio seam is specific: `diagnosticSnapshot()` refreshes active
AVAudioSession category/mode/route/rate, but engine input-format fields come
from startup `checkedFormats()`. Existing `monitorAcquisition()` does not
enforce a post-AR audio contract. Reading retained fields alone cannot prove
that starting camera context preserved the input configuration.

Acceptance for this task requires:

1. Parent-coordinator fixtures with injected audio and spatial sessions prove
   permission-only idle behavior, cancellation, startup rollback, failure in
   either subsystem stopping both, background/deadline/mode teardown and old-run
   callback rejection. Existing controller-only fixtures are not this evidence.
2. Native builds and hosted tests pass for the exact integrated source, with
   visible Start/Stop and unchanged context-off Listen, Tone, DEMO and Replay.
   A prior pass for the unwired module does not validate the new integration.
3. After authorized tester access, retain paired context-off/context-on physical
   runs on the same phone: observed route/category/mode/format, advancing
   microphone/DSP/AR counters, ordinary sound response and stop behavior. Start
   with depth off; exercise optional depth only on supported hardware. Record
   unexercised cases and actual camera release as described below.

Keep **“Audio/pose timing not associated”** visible. Tracking epochs and depth
confidence retain their existing meanings. No clock bridge, spatial audio
placement, RF input or shared-session implementation belongs to this task.

## Device evidence needed before closing G2a or G2b

For G2a, retain the source/build identity and actual device/OS capabilities. Run
Listen with context off, then with context on. Compare actual audio route/rate,
callbacks, DSP frames, AR frames, and render activity. Camera startup must not
silently change the input contract or output a tone. Exercise Stop, the time
limit, backgrounding, a camera interruption, tracking loss, and repeated starts.
Record unexercised cases. Software fakes do not establish camera release timing
or simultaneous microphone/camera operation on an iPhone.

Test an unsupported-LiDAR path through fixtures and, where available, a real
device. On a LiDAR device, observe finite depth and confidence changes for known
near/far surfaces; this checks operation, not calibrated ranging accuracy. Return
to a marked start position in a controlled scene and record AR position/orientation
deviation and tracking events. Report the observed result without generalizing
it into a precision guarantee.

G2b additionally needs the private audio anchor trace, the AR/host clock-mapping
evidence and calibration uncertainty, association mismatch distributions, and a
repeatable motion/timing experiment. A high-quality camera image, normal AR
tracking, a valid depth value, or a successful G1 audio trace does not establish
that cross-sensor timing. Until that test passes, keep the camera context useful
and keep spatially attached audio measurements unavailable.

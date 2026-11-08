# G2a spatial context module

Source candidate against Rhea RF Spanner frozen G1 source
`f8d1eed0aaf3f2d8e195bdd2424f183d0b472c03`, 2026-11-08. This is Rhea RF
Spanner, not Rhea v2. The original WD task added seven assigned files without
changing existing app integration, resources, project generation, versions,
signing or workflows. Coordinator review corrections and native project
registration are recorded separately in
[the validation record](SPATIAL_CONTEXT_VALIDATION.md). The module is
**not an integrated or validated app feature**.

No Swift/Xcode toolchain is available on WD. No Swift build, XCTest execution,
Simulator run, device capture, native cleanup or simultaneous microphone/camera
success is claimed. G1 native review and physical Listen evidence remain separate
prerequisites. The coordinator owns integration and native validation after review.

## Implemented boundaries

`SpatialContextTypes.swift` contains immutable `Sendable`, `Equatable` scalar
and four-column SIMD matrix metadata. It imports no Apple frameworks and adds
no `Codable`, Replay, report or renderer encoding. `worldFromCamera` preserves
ARKit's column-major, right-handed local-world convention; it estimates camera
position, not microphone position, compass heading or global coordinates.

`SpatialContextPolicy.swift` is a pure, explicitly driven state machine. Its
injected monotonic times do not read a clock or start a sensor. It distinguishes
frame delivery, tracking, pose validity, depth availability and unavailable
association. There is one current frame, no history. Scalar counters saturate.
Run IDs increase across controller starts; coordinate epochs are scoped to the
pair `(spatialRunID, coordinateEpoch)` and cannot be merged across runs.

`SpatialContextController.swift` owns permission/capability decisions and the
native AR adapter on the main actor. `SpatialContextRuntime` injects only a
clock, capability/permission functions and a session factory. The session
protocol supports start/stop and an optional preview; fake sessions open no
sensors. The clock closure is checked `Sendable`; test clocks use a mutex.

`SpatialContextView.swift` attaches the controller's preview to a UIKit host,
shows independent spatial status, and has no acquisition controls. The shared
ARView constructor uses
`ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)`.
Controller/view construction and inspection never run AR or request permission.
The native factory prepares a manual preview and a fresh `ARSession` only during
an authorized explicit start; the adapter's `session.run` is the sole camera
start site. Apple documents both [manual construction][manual] and replacing
the [ARView session][session].

Each start configures world tracking with `.gravity`,
`providesAudioData = false`, empty plane detection, no scene reconstruction,
no environment texturing and `userFaceTrackingEnabled = false`. Frame semantics
are empty except `.sceneDepth` when requested and supported. No body detection,
image/object detection targets, mesh, face capture or world-map persistence is
enabled. A fresh session runs with `.resetTracking` and `.removeExistingAnchors`.
Support is checked on `ARWorldTrackingConfiguration`, not made an app-wide
hardware requirement. Simulator production capability is unavailable.

Apple documents [AR audio capture control][audio] and
[the face-tracking switch][face]. Disabling AR audio delivery does **not** prove
audio-route stability. This module does not configure an `AVCaptureSession`,
change `AVAudioSession`, touch the audio SPSC, or add another audio producer.
No `ARSession.automaticallyConfiguresApplicationAudioSession` API is used or
assumed. Actual concurrent route/category/mode/format behavior needs a device.

## Explicit start, idle permission and teardown

The parent first calls `setForegroundActive` from its existing lifecycle owner.
The default is inactive. Only its explicit Start action calls
`prepareForExplicitStart()`:

1. Unsupported tracking, denied/restricted/unavailable camera permission returns
   `.unavailable` with an observable reason. It constructs no session and starts
   neither sensor. The parent offers an explicit context-off audio-only choice.
2. Undetermined permission invokes Apple's [camera permission request][permission].
   Completion returns `.permissionResolved` and stays idle. It does not issue a
   ready permit, construct a session, or start/resume acquisition. Returning from
   Settings also has no start hook. Another explicit Start is required.
3. Already-authorized preparation returns `.ready` and a one-shot permit. It
   still starts nothing. After both sensors' preconditions pass and Listen
   audio starts, the coordinator explicitly calls
   `startAuthorized(depthRequested:)`. Permission and capabilities are rechecked.
   Any false result requires combined rollback by the coordinator.

Stop/backgrounding invalidates permission preparation and any ready permit.
A late permission answer cannot change a newer generation. Direct Task
cancellation also returns idle after the answer and cannot wedge preparation.
No denied path silently starts a partial combined run.

Plain `stop(reason:)` is idempotent and does not notify the parent recursively.
It cancels monitoring, retires the mailbox before teardown, removes the delegate, pauses
AR, and detaches/releases the app's preview/session/delegate references. The
first terminal reason and aggregate counts remain; current pose/depth is cleared.
An already executing old callback can finish its local work but cannot publish
into the retired or next run. Every explicit start uses a new delegate/mailbox.

Failure, interruption, watchdog expiry, foreground loss and preview teardown
stop the camera and invoke `onStopRequired` once on the main actor. The parent
must end the same combined Listen run. A preview coordinator carries the run it
displayed, so dismantling an old preview cannot stop a replacement run. There
is no automatic recovery, permission-triggered start or interruption-ended
resume. Teardown is never performed inside `sessionWasInterrupted`; this
deliberate abandonment does not depend on its [interruption-ended notification][interruption].

The parent **must call stop before releasing its owner**, on every audio stop,
mode/acquisition/context change and the existing 60-second deadline. This module
does not replace that deadline, own the audio engine or promise cleanup through
deinitialization. Camera release latency is a physical validation item.

## Ownership, coalescing and clocks

The native adapter sets a dedicated serial `ARSession.delegateQueue`. Only that
queue mutates its session-specific frame sequence. In each frame callback it
copies camera matrix/tracking/timestamp and synchronously reduces current
unsmoothed scene depth. No app closure, stored property, task, mailbox or audio
callback retains an `ARFrame`, `ARDepthData` or `CVPixelBuffer` from the callback.
RealityKit/ARKit continue to own their internal rendering/capture objects.

`SpatialContextHandoff: Sendable` has immutable run/depth settings and a
`Synchronization.Mutex` owning its entire mutable policy. **Every** frame runs
policy before publication is coalesced; losing a limited-tracking frame from the
UI slot cannot hide epoch closure. One pending flag represents the latest
evaluated snapshot, overwritten updates are counted, and terminal events are
sticky. There is no sensor history, per-frame Task or queued main-actor block.
The controller has one 10 Hz monitor Task, with at most one active iteration.
The main actor retains only the current published snapshot. No audio code takes
this lock. Tests can disable automatic updates and call `monitor()` directly.

Production receipt and watchdog clock samples occur **inside the same mutex**,
so one cannot overtake the other's earlier sampled time and create a false
regression. `receivedElapsedSeconds` means metadata handoff receipt after the
small depth reduction, relative to authorized session start. It is scheduling
evidence, not an image capture timestamp. The first-frame origin is sampled
after manual preview construction, just before native configuration/run.

`arCaptureElapsedSeconds` is separately relative to the first valid AR timestamp
of this run. Absolute AR timestamps stay private to callback/policy processing;
app uptime origins are not published. The UI labels AR capture clock and frame
arrival age separately. The [ARFrame timestamp reference][timestamp] supplies no
verified shared epoch with audio host time for this implementation.

G2a has no successful association enum case. Normal tracking and even numerically
equal relative clocks leave `.clockMappingUnavailable`. Limited tracking,
invalid time and stale state retain their respective unavailable reasons. The
UI always says **Audio/pose timing not associated**. No audio anchors, matching,
interpolation, capture-time subtraction or G2b clock bridge is implemented.

## Tracking, missing data and depth

Initial pose acceptance and every recovery require three consecutive normal
frames with finite transforms and strictly increasing valid AR timestamps.
Limited/unavailable tracking, missing/nonfinite transforms and AR time faults
close the epoch immediately. Recovery opens a fresh logical epoch; it does not
claim ARKit independently recalibrated the world. Old-run and repeated/out-of-order
sequence input is rejected before it can alter watchdogs or current state.

The first-frame deadline is inclusive at 3 seconds; after delivery begins,
the no-new-frame deadline is inclusive at 2 seconds. Frames at the deadline
cannot rescue an expired run. Arrival and tracking are independent: limited
frames refresh delivery while keeping pose unavailable. Invalid/regressing app
clock values terminate with `.timingInvalid`. Watchdog expiry clears the frame,
closes the epoch and marks association `.stale`; physical stop is acted on at
the next main monitor tick. The nominal tick period adds up to 100 ms under
normal scheduling; foreground suspension/load may delay it. Lifecycle teardown
must also be called directly, independently of polling.

Depth selection is fixed before start and optional. Unsupported selected depth
remains `.unsupported` while camera/pose can run; unselected depth is
`.notRequested`. Missing depth/confidence or invalid input replaces the current
summary, never zero or a previously valid distance.

The depth adapter intentionally accepts only nonplanar
`kCVPixelFormatType_DepthFloat32` and `kCVPixelFormatType_OneComponent8` confidence.
It checks both formats, matching dimensions at least 3 by 3, independent row
strides, overflow-safe storage bounds, successful read-only locks and base
addresses. Successful locks are paired with `defer` unlocks. Float reads support
unaligned padded rows. See Apple's [depth map][depth], [confidence map][confidence]
and [buffer locking][locking] references.

The exact image-center 3 by 3 patch uses integer-divided center coordinates
(higher center pixel for even dimensions). Only finite positive values with
medium/high categorical confidence count; unknown categories are rejected.
At least five accepted pixels are required. The median and accepted count are
reported, with the lowest accepted confidence category, never an averaged
confidence probability or error bar. The even-count median avoids overflow and
preserves positive subnormal values. Only nine transient scalar samples are
allocated; no map survives the callback.

The label is **Image-center scene depth · meters from camera plane**. No reticle,
screen ray or image/view crop registration is claimed. Camera pose and this
patch locate neither a sound source nor an RF source or acoustic reflector.

## Coordinator integration proposal (no existing-file edits made)

Hook locations below refer to the frozen source. They are a proposal for the
coordinator's integration patch, not changes delivered in this module.

| Coordinator-owned file/hook | Required integration |
| --- | --- |
| `App/Sources/ExperimentModel.swift`, ownership/init | Own one controller, default context/depth intent off; install weak `onStopRequired` closure routing to central combined stop. Keep the spatial reason separately from the audio stop reason. |
| `startExperiment()` (frozen line 326) | Only LIVE Listen with context selected takes combined preparation. Check microphone and camera permission before either sensor. Use the existing cancellable permission/start task and recheck foreground, idle, mode and intent after each await. Any permission resolution returns idle. |
| `beginAcquisition(source:)` / `beginRun(...)` (377 / 389) | Preserve existing recording/audio identity and deadline. After audio start succeeds (422), consume the ready camera permit with `startAuthorized`. On false result stop audio and camera immediately; never present an audio-only success for combined intent. Inspect actual audio contract after AR startup and during monitoring; mismatch fails the run rather than being silently reconfigured. |
| `stopExperiment(reason:)` / `endActiveRun(reason:)` (693 / 677) | Retire spatial context on all exits, including audio startup failure/processing completion, user stop, time limit and mode changes. Map user/inactive/audio/deadline causes to spatial reasons; preserve an already terminal camera reason. Keep shutdown idempotent if `onStopRequired` also requests stop. |
| `setAppActive(_:)` (277), existing app scene forwarding | Forward activity to the controller; on loss stop the combined run even while starting. Foreground return does not start or resume. |
| `monitorAcquisition()` / `processingFinished(...)` (657 / 595) | Keep existing 60-second and audio failure behavior; all terminal paths must reach combined teardown. The spatial controller supplies its own bounded 10 Hz frame watchdog monitor. |
| `selectAcquisitionKind(_:)` / `selectMode(_:)` (259 / 298) | Stop first, cancel outstanding preparation, clear context intent for Tone/DEMO/Replay; all retain their audio-only behavior. Context/depth intent changes also stop first and need another explicit Start. |
| `App/Sources/ExperimentView.swift`, `consentPanel`, `viewport`, `detailedReadout` | Add idle-only context/depth intent controls for LIVE Listen, default off, and an explicit context-off fallback. Place `SpatialContextView(controller:)` beside existing level/spectrum readouts, observing the controller directly. Never call permission/start in construction, onAppear, onChange, preview update or status access. |
| `App/Resources/Info.plist` | Add accurate `NSCameraUsageDescription` **before any camera permission request**. Keep AR hardware optional; no required-device capability. Review microphone text for combined Listen without changing the microphone contract. |
| Help/privacy/review documents | Update `App/Sources/PrivacyMethodView.swift`, `docs/PrivacyPolicy.md`, `docs/ReviewTestPlan.md` and submission/review notes to explain optional live processing, no storage/upload, independent clocks, unsupported-depth behavior and hardware validation limits. |
| `scripts/generate_project.py`, generated Xcode project | Existing recursive app source and hosted-test discovery already sees the new files. Coordinator regenerates/reviews project membership after G1 review; core package paths auto-discover new sources/tests. No generator or project was run/edited here. |

Suggested camera purpose text for coordinator review:

> Rhea RF Spanner uses the camera only when you explicitly start optional camera
> context with Listen. The live preview, estimated camera pose and optional
> scene-depth summary are processed on this device. Images, depth maps, feature
> points and world maps are not saved or uploaded.

Ordinary copied diagnostics must be an explicit allowlist of permission/state,
capability booleans, frame/usable-pose/valid-depth/overwrite counts, tracking
reason, relative intervals and sanitized error domain/code. Do not encode the
snapshot/frame wholesale: matrices, maps, raw sensor timestamps, uptime origins
and NSError userInfo stay excluded. Preserve the existing local-only expiring
Copy path. The module reuses `systemUptime` for elapsed events; coordinator must
review the existing required-reason manifest scope before submission. No raw
host ticks or absolute uptime are exported here.

## Checks and remaining validation

WD local checks: frozen HEAD and unchanged tracked/indexed files; exactly the
seven allowed new files; new-file whitespace, UTF-8 and delimiter/source-boundary
audits. These are static checks, not Swift compilation or test passes. No
project generation, toolchain retry, machine reconfiguration, network/device
scan, commit, push, publication or signing-material read was performed.

The original WD output authored 39 tests: 14 core policy tests and 25 hosted
fixtures. Coordinator review adds tracking-notification and presentation
regressions; their exact native execution belongs in the validation record.
None were executed on WD. Core tests cover lifecycle/identity, exact deadlines, epoch loss and
recovery, invalid matrices/clocks, unavailable association even with equal
relative times, depth median/categories/count bounds, missing-depth replacement
and latest-only storage. Hosted tests cover injected permission/session decisions,
teardown/retired callbacks, coalescing that cannot conceal tracking loss, preview
manual construction and synthetic padded depth/confidence buffers. Nil
confidence, wrong formats/dimensions, nonfinite/nonpositive values, unknown/low
confidence, insufficient accepted pixels and recovery have fixtures. Invalid
stride/lock/base-address failure guards are present but not fault-injected:
CoreVideo rejects malformed real buffers, and no extra sensor framework was
introduced to simulate its C functions.

Next native validation must build the **exact integrated candidate** in Swift 6
strict concurrency for iOS 18+, run `swift test` on an available Swift host and
the app-hosted tests on Simulator, and run existing G1/Replay/rendering tests.
Review actual imported ARSessionDelegate isolation, NSObject lifetime, Mutex
ownership, CVPixelBuffer format/storage behavior and manually controlled ARView
configuration. Authoring/static review does not resolve SDK compile constraints.

Device validation must retain source/build and device/OS identity, then compare
Listen context-off and context-on category/mode/route/input format, mic callbacks,
DSP frames, AR frames and rendering without output tone. Exercise Stop, 60-second
deadline, foreground loss, interruption, tracking loss, first/no-frame timeout,
permission denial/regrant, non-LiDAR capability and repeated starts; record
unexercised cases and actual camera release. On LiDAR, observe near/far patch
depth and categorical confidence; check return-to-mark pose deviation without
claiming calibrated range or tracking precision. Fakes do not establish any of
these physical results.

G2b remains unavailable until a separate task supplies audio host anchors,
verified AR/host clock mapping, uncertainty and device timing/registration
evidence. No normal pose, finite depth or successful combined preview closes
that association gate.

[manual]: https://developer.apple.com/documentation/realitykit/arview/init(frame:cameramode:automaticallyconfiguresession:)
[session]: https://developer.apple.com/documentation/realitykit/arview/session
[audio]: https://developer.apple.com/documentation/arkit/arconfiguration/providesaudiodata
[face]: https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/userfacetrackingenabled
[permission]: https://developer.apple.com/documentation/avfoundation/avcapturedevice/requestaccess(for:completionhandler:)
[interruption]: https://developer.apple.com/documentation/arkit/arsessionobserver/sessionwasinterrupted(_:)
[timestamp]: https://developer.apple.com/documentation/arkit/arframe/timestamp
[depth]: https://developer.apple.com/documentation/arkit/ardepthdata/depthmap
[confidence]: https://developer.apple.com/documentation/arkit/ardepthdata/confidencemap
[locking]: https://developer.apple.com/documentation/corevideo/cvpixelbufferlockbaseaddress(_:_:)

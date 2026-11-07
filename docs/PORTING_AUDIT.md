# Porting audit of the supplied script

The starting point was the `init_project.sh` and Swift/Metal snippets supplied in the project request. They were presented as five verified files, but no compiler log, original file bytes, or hardware validation accompanied that assertion. The pasted text contains compilation and packaging defects.

This repository contains a revised implementation. It does **not** contain a claimed verbatim archival copy of the supplied script. The changes below distinguish text/packaging repairs from deliberate changes to behavior and signal processing.

## Preserved scope

- Product name: **Rhea RF Spanner**. The requested organization is `timelabs-npo`.
- iOS application source for compilation on a separate Mac, with delivery intended through TestFlight/App Store.
- Swift 6 source, iOS 18 minimum deployment target, and a current Apple-supported upload toolchain.
- A 20 kHz single acoustic tone at a requested 48 kHz sample rate, microphone input, double-precision phase analysis, and a Metal visualization.
- Explicitly inspectable source and English documentation.

The original `minFrequency`/`maxFrequency` constants named an 18–22 kHz interval, but the supplied generator actually emitted a fixed 20 kHz tone. There was no implemented frequency sweep, RF acquisition, radar image, target-identification algorithm, or absolute time-of-flight range estimator to preserve. This release continues the fixed-tone acoustic experiment and names that behavior in the UI and documentation.

## Text, API, and packaging defects

| Supplied text | Problem | Repository response |
| --- | --- | --- |
| Bare `Use code with caution.` inside Swift; numbered prose between shell commands. | These are not valid Swift/shell statements in the presented positions. | Source is stored as actual files, without copied formatting artifacts. |
| `UnsafeMutablePointer` and `MemoryLayout.stride` without required type information. | The intended element/uniform types are missing. | Pointer and layout operations name concrete types. |
| Passing `floatChannelData` as if it were one channel's sample pointer. | AVAudioPCMBuffer exposes a collection of channel pointers. | The capture path selects and checks the channel used for analysis. |
| Accessing `.mData` directly on `UnsafeMutableAudioBufferListPointer`. | The wrapper is a collection of audio buffers. | Output handling addresses individual buffers and their frame/channel layout. |
| Metal declarations `float2 texCoords = { ... }` and `float4 positions = { ... }` used as indexed arrays. | The variables are declared as vectors, not arrays of vectors. | Shader arrays have an explicit array declaration. |
| `.colorAttachments.pixelFormat`. | The pipeline descriptor exposes indexed color attachments. | The concrete attachment is configured. |
| A package with only a library product plus an app entry point. | It does not define a distributable iOS application bundle or Xcode app target. | Portable computation is separated from the Xcode iOS application target. |
| `.enableUpcomingFeature("StrictConcurrency")` alongside Swift 6. | Strict concurrency is part of Swift 6 language mode; the additional upcoming-feature setting is unnecessary. | The project uses explicit Swift 6 settings. |
| `PrivacyInfo.xcprivacy` consisting of bare key names and a reason code. | It is not a property-list document. | The app supplies an actual plist; declared reasons must match the final code. |
| No `Info.plist` microphone purpose string or app bundle configuration in the supplied package. | Required application metadata is absent. | Application resources include the microphone purpose text and bundle metadata. |

These findings identify defects in the supplied text. They are not a substitute for compiling and validating the revised iOS target.

## Deliberate audio, concurrency, and lifecycle changes

| Area | Supplied behavior or risk | Revised contract |
| --- | --- | --- |
| Tone continuity | A 2,048-sample table is copied from its beginning on each render callback. The 20 kHz / 48 kHz carrier repeats every 12 samples; 2,048 is not a whole number of cycles. | A continuous 12-sample carrier cycle advances across callback boundaries. |
| Callback length | Copy length is the callback's frame count, but source storage contains only 2,048 samples. | Rendering supports the supplied callback length without indexing beyond a fixed frame table. |
| Output amplitude | The supplied sine has unit peak digital amplitude. | The app fixes the carrier amplitude at 0.02 full scale. This is an intentional reduction and is not a calibrated acoustic exposure limit. |
| Session initiation | Permission is requested during launch; granted permission can start on launch and on becoming active. | Idle launch, separate agreement, explicit Start, and no automatic restart. The first permission grant returns to idle and requires another Start tap. |
| Session duration | No duration limit is present. | A visible, automatic 60-second session limit is part of the application contract. |
| Routes and formats | Bluetooth is permitted and a non-48 kHz format triggers a precondition failure. | Built-in speaker/microphone only; verify the actual format and reject unsupported routes with a recoverable explanation. |
| Stop/restart | The ring is reset immediately after changing a flag while DSP work may still be running; source nodes are attached on every start. | Each session owns a fresh queue and processing state; stop invalidates the session and prevents old work from updating a new session. No concurrent ring reset exists. |
| Interruptions | Only application active/inactive callbacks are handled. | Interruptions, route changes, and audio-services reset end the session and require deliberate restart. |
| Capture clock | The input callback discards `AVAudioTime`; the ring indexes only successfully accepted samples. | The producer passes actual capture sample times and their validity. Per-sample timestamps retain gaps introduced by dropped blocks. |
| Playback clock | Source-node timestamps are ignored. | A missing or discontinuous playback sample clock silences output and ends the session. |
| Startup event window | Stop notifications are not handled. | Callbacks are gated until the running route is checked, with stop observers armed before engine startup. |
| Empty reads | A missing complete block can increment a read-underrun counter. | An empty consumer poll is ordinary flow control, not a lost capture frame. |
| Loss of phase validity | Phase state can be established or integrated even when the returned validity flag is false. | Invalid frames have unavailable phase/displacement values and invalidate the baseline. The next valid frame begins a new calibration epoch. |

The core's `@unchecked Sendable` declarations are accompanied by ownership contracts. They do not make arbitrary concurrent calls safe. One serial producer owns ring writes; one serial consumer owns reads and phase-state mutation; the renderer's oscillator has one serial render owner. The iOS integration must preserve those contracts.

## Deliberate estimator change

The supplied estimator multiplies samples by a Hann window, correlates with cosine and negative sine, and estimates carrier energy using a scale based on the sums of window weights and squared weights. Its reported `coherenceSNR` is a particular energy heuristic.

The revised `PhaseSensingEngine` performs **Hann-weighted least squares** for the two sampled carrier components. It forms the actual 2×2 Gram matrix of cosine and negative sine and solves for their coefficients. The residual energy is the weighted input energy minus the fitted projection energy. The displayed ratio compares fitted-tone energy with residual energy and is bounded numerically to avoid unbounded displays.

This is a change of estimator, not merely a type or syntax repair. The revised quality values are **not numerically interchangeable** with the supplied `coherenceSNR`. They are labeled **Tone / residual estimate** and **Signal quality gate**. Passing that gate is not proof that a reflector has been identified or that its path is physically phase coherent.

The implementation uses portable `Double` loops and `addingProduct`, so the computational core can be compiled and tested separately from Apple frameworks. It does **not** preserve the supplied vDSP implementation. No claim of an equivalent performance profile, a particular SIMD instruction sequence, or a zero-rounding-error result is made. Performance on the intended iPhone requires measurement.

## Phase and displacement convention

Carrier phase is referenced to the capture sample timestamp modulo the finite carrier cycle. Successive valid phases are unwrapped using the nearest angular difference; motion that changes phase by more than half a cycle between accepted frames is ambiguous.

The original expression converts relative phase to a positive multiple of `c / (4πf)`. The revised property is named `equivalentMonostaticDisplacementMeters` and uses:

\[
\Delta r = -\frac{c}{4\pi f}\Delta\phi.
\]

With the implemented received-signal phase convention, a longer single two-way acoustic path produces a phase decrease; the negative sign makes increasing modeled range positive. This is an intentional sign change. `c = 343 m/s` is a configured model constant, not an environmental measurement.

The monostatic path assumption is not automatically satisfied by a phone speaker/microphone pair. Direct coupling, separate transducer positions, multiple reflections, hardware response, and motion can alter the received phase. This conversion therefore remains a **conditional model**, not an independently measured range. Rebaselining after invalid input discards continuity across that invalid interval instead of inventing displacement through it.

## Claims removed or narrowed

- **“Verified files” / successful build:** require an actual compiler run and its log. Source inspection is identified separately.
- **“Lock-free”:** no unqualified cross-platform guarantee is made. The ring uses atomic cursors and has no explicit lock in its read/write path, but that alone is not a complete hardware progress proof.
- **Cache-line isolation:** inserting tuple padding in a Swift class does not establish a verified field-placement guarantee. The revised queue does not rely on such a claim.
- **“JITTER: 0 ULP”:** removed. No timing or numerical study supported it.
- **Distance and physical coherence:** replaced by explicit relative phase, a signal-quality gate, and a conditional displacement model.
- **Radar image:** the Metal wave is labeled as an abstract visualization.
- **Raw Mach ticks as nanoseconds:** dividing `mach_absolute_time()` ticks by one billion is not a general timebase conversion. The revised abstract animation uses draw-frame counts, audio limits use sample counts, and a task handles the session-duration fallback. No direct system-boot-time call is retained in the current app source.

## Remaining evidence boundaries

Portable Swift tests can verify the revised algorithm and transport contract under their tested conditions. They do not build UIKit, AVAudioEngine, Metal, or the application bundle. An unsigned iOS compile does not establish distribution signing or App Store Connect acceptance. Neither result verifies the phone's acoustic behavior, sound pressure, signal quality, or ranging accuracy.

The actual build and test results must be reported with their environment, command, source revision, and observed outcome. The review letter and privacy documents describe intended/implemented behavior; they are not records of Apple approval or physical validation.

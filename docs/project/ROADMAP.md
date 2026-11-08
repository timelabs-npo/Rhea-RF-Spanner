# Rhea RF Spanner: staged observatory roadmap

Updated **2026-11-08**. This is the development plan for
`timelabs-npo/Rhea-RF-Spanner`. The separately named Rhea v2 project is outside
this scope. Milestones below describe intended work, not capabilities already
present in a released binary.

## Product objective

Build a portable observation instrument that helps an engineer answer three
practical questions: **what changed, where was it observed, and can the result
be reproduced?** The interface should combine live sensor views, adjustable
visualization, and recorded evidence without losing the identity or units of
each measurement. A useful first field workflow is a repeatable before/after
equipment or room survey, with visible coverage and uncertainty.

The longer-term observatory combines acoustic observations, camera context,
AR pose, available LiDAR depth, and supported external radio probes. Multiple
iPhones should eventually contribute observations to one session. “Full
spectrum” is the product direction; every actual capture must name the sensor,
frequency band, measured quantity, and limitations that apply to it.

## Starting evidence

| Item | Current evidence |
| --- | --- |
| Released application | **0.2.0 (2)**; uploaded application source `9bed85a1787aafabd919994e38eae66d3169c448` |
| Planning source snapshot | Main at `4be8724f244cd2e478f5d6877f798986fcaa2ae9` |
| Distribution | Apple validation/upload/processing recorded in [the upload report](../TESTFLIGHT_UPLOAD_VALIDATION.md) |
| Physical installation | The user reported successful installation and testing on 2026-11-08 |
| Runtime problem | The user reported that the app is not working usefully; exact symptoms and a device diagnostic capture are still missing |
| Debugging input | `debugging.txt` is a design brief for observability and independent review, not a device crash or audio trace |
| Existing software | Isolated Swift signal core, active acoustic LIVE, silent deterministic DEMO, Waterfall, and bounded in-memory REPLAY; see [architecture](../ARCHITECTURE.md) |

The diagnostic build **0.2.1 (3)** has since passed native validation, uploaded
and processed as VALID; tester-group access has not been granted. G1 targets
**0.2.2 (4)** and its latest amendments require their own validation. Current
source/run/access details are in [the checkpoint](NEXT_SESSION.md) and the
[G0 evidence record](../DIAGNOSTIC_RELEASE_VALIDATION.md). Successful compilation,
Apple processing, tester access and useful hardware operation are separate
observations.

## Milestones and exit evidence

Work proceeds through small releasable increments. Later milestones may receive
design work or fixtures in parallel, but an unverified adapter must not appear
as an available live sensor.

| Gate | User-visible result | Evidence required to advance |
| --- | --- | --- |
| **G0 — Diagnose and repair LIVE** | An understandable acquisition state, an accessible diagnostic console, a copyable JSON report, and evidence-backed runtime fixes | Native CI and targeted regressions; a diagnostic TestFlight build; a physical-device report showing which stages produce data or a specific actionable failure |
| **G1 — Useful passive audio** | Live input level and spectrum without requiring acoustic transmission; explicit separate active-tone experiments | Known-signal fixtures, useful audible-band response on hardware, correct units/scales, and stop/interruption/route behavior |
| **G2 — Spatial context** | Camera view with AR pose, optional LiDAR depth, and clearly located observation samples | Supported/unsupported-device behavior, timestamp matching, tracking-loss handling, and repeatable spatial registration trials |
| **G3 — One real external probe** | One verified device/firmware combination streams its actual measurements into a labelled layer | Capability declaration, parser and loss tests, a physical capture, and agreement with the probe's own recorded output |
| **G4 — Two-phone collaboration** | Two iPhones share one observation session and display aligned contributions | Join/reconnect behavior, clock-offset/drift estimates, shared-coordinate checks, and explicit stale/unaligned states |
| **G5 — Reproducible field evidence** | Versioned datasets and comparisons that another engineer can inspect and rerun | Export/replay equivalence, calibration records, repeatability and uncertainty results for a defined measurement task |

### G0: diagnostic release first

Instrument the existing pipeline before widening it. The application should
distinguish permission denied, unsupported route, no callbacks, silent input,
invalid timestamps, queue loss, low-quality tone fit, and a rendering failure.
Each must leave enough evidence to choose the next action.

The diagnostic surface and report should cover:

- Application version/build, mode, run/epoch, lifecycle state, permission state,
  actual audio route/format, requested versus actual sample rate, channel count,
  and callback frame length.
- Capture/output callback counts, processed-frame counts, buffer occupancy and
  drops, elapsed time since each stage advanced, and explicit stop reasons.
- Bounded numerical summaries at the input and output boundaries: finite and
  nonfinite counts, silence/clipping indicators, level, fitted-tone validity,
  and spectrum availability. Missing values stay missing in JSON.
- Render activity and failures, distinguishing draw requests, submitted frames,
  and GPU completion when those are observed. A requested refresh rate is not
  an observed rendering rate.
- A bounded event history and an explicit **Copy Diagnostic Dump** action.
  Diagnostic collection must not allocate, format JSON, or perform file/network
  I/O inside the real-time audio callback.

DEMO should exercise the same analysis/display boundaries with known input.
Add a deterministic self-test that reports its input, expected result,
tolerance, and observed result. Passing a synthetic self-test does not label
the microphone or speaker as working. A diagnostic report contains technical
summaries; raw microphone audio, camera images, credentials, and persistent
personal identifiers are not needed for this release.

Reproduce each discovered software defect with a focused regression where
possible. Preserve the existing separation of acquisition and display controls,
foreground-only behavior, explicit start, and source provenance. Update the
privacy/method text to describe the new user-initiated diagnostic export.

There are two distinct completion points:

1. **Software candidate:** targeted tests and native builds pass, the diagnostic
   UI is exercised in Simulator, and the reviewed binary is delivered through
   TestFlight. This can be completed before a new phone report arrives.
2. **Field confirmation:** an actual report establishes capture, processing,
   and presentation behavior on the tested iPhone/OS/route. Record the tested
   combination and remaining limitations. Until then, describe the release as
   a diagnostic candidate, not a validated acoustic instrument.

### G1: make ordinary sound immediately useful

Give passive listening its own acquisition mode. Its first useful result is a
responsive level/spectrum view across a declared audio band. Tone fitting and
equivalent displacement remain separate active-experiment outputs. Noise,
speech, and music must not be rejected merely because they do not fit a
20 kHz carrier.

Retain dBFS or another explicitly defined digital unit until a documented
calibration supports physical sound-pressure units. Present the actual sample
rate, analysis window, frequency bins, and averaging. Broader frequency display
and adjustable time scales need fixtures that verify labels and numerical
scaling, plus hardware checks of silence, clipping, and known tones. The
existing [signal model](../SIGNAL_MODEL.md) remains the reference for the
active acoustic estimator.

### G2: spatial observations, then spatial interpolation

The [bounded G2 implementation gate](G2_SPATIAL_CONTEXT_GATE.md) separates an
optional context preview (**G2a**) from verified audio/pose time association
(**G2b**). It is a future design; the separate G2a work session is unintegrated
and no spatial feature is delivered by the current candidate.

Begin with camera context and AR camera pose. Add LiDAR only after a runtime
capability check; Apple documents that `sceneDepth` is optional and must be
enabled on a supported configuration ([Apple scene depth][apple-depth]).
Use the confidence information associated with depth and retain the camera
intrinsics and transforms required for the chosen spatial representation.

Assign each observation a capture time, clock domain, frame/epoch, and measured
or estimated pose association. Define the maximum allowed temporal mismatch
before joining audio and spatial observations. Store the measured mismatch
and mark stale/missing associations explicitly. Relocalization or a world-origin
change starts a new spatial epoch unless an explicit transform joins them.

The first map should show **where the sensor sampled**. Positioning a microphone
sample in space does not locate the source of the sound or identify a reflecting
wall. Add interpolation only with a declared model, observed coverage, and a
visible distinction between samples and inferred regions. Camera false color
is a visualization; it does not supply thermal or RF measurements.

### G3: external probes by demonstrated capability

Choose the first adapter from hardware that can be inspected and tested during
the session. Do not infer available telemetry from a product name alone.

| Candidate | Verified hardware/documentation boundary | First engineering gate |
| --- | --- | --- |
| ESP32-S3 | The chip provides **2.4 GHz** Wi-Fi. ESP-IDF describes CSI as complex subcarrier channel estimates from received packets, with packet-dependent layout and metadata ([datasheet][esp-datasheet], [CSI guide][esp-csi]). | Identify the exact board and firmware; capture a documented CSI/metric record from the owned test link and preserve its layout/validity metadata. Do not advertise 5 GHz CSI from an ESP32-S3. |
| Flipper Zero | The built-in CC1101 radio covers specified sub-GHz bands: **300–348, 387–464, and 779–928 MHz** ([official hardware documentation][flipper]). | Demonstrate a supported receive/export path and define whether it yields levels, decoded events, or raw pulse timing. Those outputs are not interchangeable with broadband RF I/Q. |
| Beryl AX GL-MT3000 | The vendor documents a **2.4/5 GHz Wi-Fi router** ([vendor specification][beryl]). | Inspect the actual firmware/driver and identify exposed counters or measurements. Dual-band connectivity alone does not establish accessible CSI or calibrated spectrum samples. |

Start with one working adapter and a recorded fixture. Its capability record
must identify model/firmware, measured quantities, units, band/channel and
bandwidth, antenna/chain, sample or event rate, timestamp semantics, and any
calibration. Unsupported quantities stay unavailable.

The transport needs a versioned envelope with source/session identity,
sequence numbers, capture and arrival times, payload type/length, and limits.
Define malformed-packet, duplicate, out-of-order, loss, disconnect, and
unsupported-version behavior. Pair the intended probe and authenticate the
transport; bounded queues and explicit loss counters apply to every ingress.
There is no requirement that camera, spectra, CSI, and acoustic samples fit the
same packet size or pass through the same single-tone estimator.

### G4: shared observations before coherent arrays

First support two participants and a visible session coordinator. Keep peer
identity, connection state, source capabilities, clock mapping, and spatial
alignment visible. A local network connection alone does not establish either
shared time or shared coordinates.

ARKit can exchange collaboration data for world tracking, while the app must
provide its transport and handle map merging ([Apple collaboration sample][apple-collaboration]).
Measure alignment against a shared reference and report tracking quality.
Separately estimate inter-device clock offset and drift, including uncertainty
and the effect of network delay. After reconnect, require a new verified
mapping before fusing records.

Common-map rendering is the first collaboration goal. Coherent acoustic or RF
array processing requires an additional measured sample-clock/phase relationship,
sensor geometry, and calibration experiment. Design its timing requirement from
the intended estimator before promising beamforming, ranging, or tomography.
Add mesh routing only after two-device collection is dependable and a measured
need for additional topology exists.

### G5: make a dataset useful to someone else

Add opt-in persistent session export with a manifest, schema version, app and
algorithm revision, device/probe capability records, units, clock mappings,
coordinate transforms, calibration identifiers, validity masks, and checksums.
If raw payloads are recorded, document the recording choice and data handling
for each sensor. Replay should preserve the original source and reproduce the
derived result under the recorded parameters.

Use controlled, repeatable tasks: a known audio stimulus, a fixed route with
marked sampling positions, or a documented owned radio link. Compare repeated
sessions and, when making an accuracy claim, compare with a suitable reference
instrument. Report repeatability, drift, coverage, missing data, and uncertainty
in the relevant units. These measurements determine which commercial survey
or scientific use is supported; a universal “environment cleanliness” score
is not an acceptance criterion.

## Architectural commitments

These are design constraints for the incremental work, not a claim that all
modules already exist:

| Layer | Responsibility |
| --- | --- |
| Sensor adapters | Own hardware lifecycle and bounded delivery of typed observations; expose actual capabilities and errors |
| Measurement algorithms | Accept a defined signal type and units; produce values with validity and model metadata |
| Session/time registry | Retain source clocks, sequence gaps, epochs, offset/drift mappings, and synchronization uncertainty |
| Spatial association | Join observations to supported poses/depth using declared timing and transform rules |
| Display and replay | Preserve measured/simulated/inferred provenance; change presentation without changing measurements |
| Diagnostics and dataset export | Supply bounded operational evidence now and reproducible session records as recording features are added |

The existing [64-byte slice](../OBSERVATORY.md#explicit-64-byte-slice-version-1)
is an acoustic replay encoding. Keep its compatibility contract; introduce a
separately versioned multimodal envelope when needed. DSP reuse is earned by
matching a signal contract, not by converting every sensor payload to `Float`.

## Execution and evidence

Use [NEXT_SESSION.md](NEXT_SESSION.md) as the resumable operating record. Each
work session gets a bounded objective, file ownership, exact base commit,
validation command/run, and a checkpoint. Source, tests, plans, and sanitized
evidence belong in GitHub. Signing/API secrets remain in the existing protected
storage. A running remote process is reported as running only after an actual
status check; no permanent or infinite agent uptime is assumed.

Primary references below were consulted on 2026-11-08. They establish API and
hardware boundaries, not measured performance of Rhea RF Spanner.

[apple-depth]: https://developer.apple.com/documentation/arkit/arframe/scenedepth
[apple-collaboration]: https://developer.apple.com/documentation/arkit/creating-a-collaborative-session
[esp-datasheet]: https://documentation.espressif.com/esp32-s3_datasheet_en.pdf
[esp-csi]: https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-guides/wifi-driver/wifi-vendor-features.html
[flipper]: https://docs.flipper.net/zero/sub-ghz
[beryl]: https://www.gl-inet.com/products/gl-mt3000

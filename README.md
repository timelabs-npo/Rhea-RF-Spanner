# Rhea RF Spanner

An inspectable iOS application for **acoustic phase experiments** using an
iPhone's built-in speaker and microphone. The display name is **Rhea RF Spanner**;
the public source repository is
[timelabs-npo/Rhea-RF-Spanner](https://github.com/timelabs-npo/Rhea-RF-Spanner).

The Observatory update adds an **18–22 kHz acoustic carrier grid in 500 Hz steps**,
silent deterministic **DEMO**, in-memory **REPLAY**, and an actual sample-spectrum
**Waterfall**. LIVE uses a verified 48 kHz built-in audio route. The app does not
access RF samples, cellular baseband hardware, or wireless packet traffic.
Field graphics are explicitly abstract (LIVE) or synthetic (DEMO). They do not
represent a measured spatial radar image. A phase-derived displacement is a
conditional model, not an absolute range measurement.

The native interface uses a full-screen Metal viewport, dark material panels,
system menus, a carrier ruler, and separate acquisition/display controls. Its
reference is the legibility and control hierarchy of professional camera apps.
False color does not imply thermal sensing.

## Build and validation status

**Current work: 0.2.1 (3), diagnostic candidate.** The owner confirms that
0.2.0 (2) installed on an iPhone, but reports that it does not yet provide useful
behavior. No physical-device diagnostic dump has been captured. The cause is
therefore still unconfirmed. This candidate adds observed input/DSP/GPU counters,
bounded error history, an explicit **Copy Diagnostic Dump** action, a silent
analytical self-test, and a **0–24 kHz** Waterfall option. Native validation and
delivery of this candidate are pending; the successful runs below belong to
the preceding release.

The staged [project roadmap](docs/project/ROADMAP.md),
[resumable checkpoint](docs/project/NEXT_SESSION.md), and
[tracking issue](https://github.com/timelabs-npo/Rhea-RF-Spanner/issues/2) distinguish
the current acoustic application from planned AR/LiDAR and external-probe work.

**Previous release native validation passed:** the release signal core compiled, all **41 core
tests** and **5 Simulator-hosted application tests** passed, and the iOS Simulator
Debug and unsigned iOS device Release apps built successfully with Xcode 26.3.
The hosted suite includes three renderer regressions for replaced spectra,
compressed capture gaps, and contiguous history, plus two session lifecycle tests.
The compiled app launched in an iPhone 17 Pro Simulator and produced actual
idle, DEMO Field, and DEMO Waterfall screenshots.
See [GitHub Actions run 42416851915](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42416851915),
which tested source commit `a93da56e45726d84e27f567c323eeda45b17d7d4`.
The same run passed a credential-free check of the installed Xcode export and
`altool` interfaces. It did not sign or upload an app.

Logs, exact test scope, and the subsequent workflow-only correction are recorded in
[docs/TESTFLIGHT_PREPARATION_VALIDATION.md](docs/TESTFLIGHT_PREPARATION_VALIDATION.md).
The earlier Observatory run and retained native screenshots remain documented in
[docs/OBSERVATORY_VALIDATION.md](docs/OBSERVATORY_VALIDATION.md).
The merged source `9bed85a1787aafabd919994e38eae66d3169c448` also passed
[main's native CI](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42420093956),
CodeQL, and Code Quality checks. It then produced a **signed archive and App
Store Connect IPA for version 0.2.0, build 2** in
[distribution run 42420624092, attempt 2](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42420624092).
The [signed export validation record](docs/SIGNED_EXPORT_VALIDATION.md) retains
the manifest and artifact hashes for that export-only run. Subsequently,
[distribution run 42423704040](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42423704040)
rebuilt the same source/version/build, **passed Apple validation, and reported
successful App Store Connect upload**. The
[upload validation record](docs/TESTFLIGHT_UPLOAD_VALIDATION.md) identifies the
uploaded IPA and its hashes. Apple processing, TestFlight availability, and
physical-iPhone acoustic validation are separate stages. App Store Connect
subsequently confirmed processing as **VALID** and displayed build 2 as
**Ready to Test** after assignment to **Rhea RF Spanner Internal**. That group
was verified with one build and one invited tester. The owner subsequently
confirmed installation and an initial test. Physical-device acoustic behavior
has not yet passed a documented validation procedure.

| Silent DEMO Field | Sample-spectrum Waterfall |
| --- | --- |
| ![DEMO Field](docs/images/observatory/02-demo-field.png) | ![DEMO Waterfall](docs/images/observatory/03-demo-waterfall.png) |

See [docs/BUILD_STATUS.md](docs/BUILD_STATUS.md) for historical baseline results
and the distinction between portable-core, iOS, signing, and physical-device
results. Compiler logs are retained under `docs/validation/`.
A passing `swift build` builds the reusable core; it does not create an iOS app
or an installable TestFlight build.

## Open in Xcode

Open **`RheaRFSpanner.xcodeproj`** and select the shared **RheaRFSpanner** scheme.
The project links the local `RheaRFCore` Swift package. There are no external
runtime dependencies and no XcodeGen, CocoaPods, Carthage, or Ruby prerequisites.
The Xcode project and app icon are committed, so project generation is optional.

The deployment target is **iOS 18.0** and the language mode is **Swift 6**.
For App Store Connect uploads, use **Xcode 26 or later with the iOS 26 SDK or
later**, as required by Apple since April 28, 2026. Deployment and build-SDK
versions serve different purposes. See [Apple's requirement](https://developer.apple.com/news/upcoming-requirements/?id=04282026a).

On an authorized build Mac:

```bash
bash scripts/build.sh all
```

This runs the Swift core tests and compiles both the simulator application and
the unsigned device application. Logs go to `build/logs/`. The simulator can
run the silent DEMO and Replay; LIVE acoustic capture requires a physical iPhone.
`python3 scripts/capture_simulator.py` captures the actual native idle, DEMO,
Waterfall, and Diagnostics screens after the simulator build. CI retains these
as artifacts.

For portable core work on Swift 6-capable macOS or Linux:

```bash
swift build -c release
swift test
swift test -c release
```

These are instructions for the worker carrying out the build; the phone owner
does not need a local laptop or to copy source code from chat.

## Using the app

1. Read **Privacy & method** while idle. Select **DEMO** to explore the full
   processing and display path without microphone permission or speaker output.
2. For **LIVE**, agree to microphone use and the selected acoustic tone, then
   start. On first permission approval the app returns to idle; start again
   deliberately when ready to emit the tone.
3. Select a carrier on the 500 Hz grid. Changing it starts a new acquisition
   epoch and phase reference. Gain, palette, and persistence affect only the
   display, not samples, fitted phase, or synthetic noise.
4. Inspect the tone/residual ratio, phase, and spectrum. Signal loss invalidates
   phase; recovery establishes a new reference without bridging the gap.
5. Stop at any time. Select **REPLAY** to inspect retained slices and their
   original LIVE/DEMO labels. No microphone or tone runs during Replay.
6. Open **Diagnostics** to inspect observed callbacks, input RMS/peak, processed
   frames, GPU completions, and retained operational events. Run the silent core
   self-test to check an analytical fixture without starting audio. **Inspect
   JSON report** previews the aggregate report; **Copy Diagnostic Dump** copies
   it locally only when you explicitly request it.

The ordinary launch uses **Full audio · 0–24 kHz Waterfall** so incoming sound
can be inspected even when a valid ultrasonic phase is unavailable. The carrier
view remains selectable. Changing the displayed frequency range does not change
acquisition: LIVE still emits the selected tone. **MIC SESSION** means that the
audio session is active; the separate observed-input status confirms whether
accepted callbacks are arriving. A LIVE input or processing stall stops the
session with a retained reason rather than silently remaining active.

The app stops when it loses foreground activity, audio is interrupted, the route
changes, or audio services reset. It never automatically restarts after these
events. An explicit carrier change during a running session performs a controlled
restart with a new reference. It accepts
the built-in speaker/microphone route at the verified 48 kHz format and reports
unsupported hardware routes instead of trapping on a failed precondition.

The fixed transmit amplitude is 0.02 of digital full scale, with a 10 ms ramp.
This is not a sound-pressure calibration or a claim that the tone is inaudible.
Keep the phone away from ears, use the experiment with nearby people's agreement,
and stop if it is uncomfortable. Start with low device volume.

## Data handling

Microphone samples are processed in volatile memory. Up to 2,048 derived
telemetry slices and their bounded companion spectra are retained in memory for
Replay; raw audio is not recorded. Closing the process loses the tape. There is
no raw-audio or Replay export UI, account, server, telemetry SDK, advertising,
remote configuration, background audio mode, or downloaded code. Diagnostics
can be previewed as JSON and copied explicitly. The report contains aggregate
statistics and bounded operational events, not audio samples, spectrum arrays,
images, route identifiers, or absolute boot/host timestamps. The device-local
clipboard copy expires after one hour and may outlive the app process. It is
not transferred through Handoff; a copy pasted elsewhere has its own lifetime.
The privacy text is available in the app without microphone permission. The
source privacy policy is [docs/PrivacyPolicy.md](docs/PrivacyPolicy.md).

Developer mailboxes, certificate keys, provisioning profiles, and API credentials
are operational material. They are not bundled with this application or included
in this source repository.

## Repository map

| Path | Purpose |
| --- | --- |
| `RheaRFSpanner.xcodeproj/` | Installable iOS application target and shared scheme |
| `App/Sources/` | SwiftUI interface, audio lifecycle, serial DSP integration, Metal display |
| `App/Resources/` | Info.plist, privacy manifest, app icon |
| `Package.swift` | Swift 6 package manifest for the reusable signal core |
| `Sources/RheaRFCore/` | Z96 reference, SPSC queue, phase fit, FFT, deterministic simulator, 64-byte codec, Replay tape |
| `Tests/RheaRFCoreTests/` | Numerical, transport, spectrum, simulation, codec, Replay, and concurrency tests |
| `AppTests/` | Simulator-hosted lifecycle, renderer, diagnostics, report, and self-test checks |
| `Config/` | Build settings and signing override example |
| `scripts/` | Reproducible project generation, builds, archive/export, publication guard |
| `docs/` | Signal model, architecture, review letter, review steps, privacy, validation |

## Read before making measurement claims

[SIGNAL_MODEL.md](docs/SIGNAL_MODEL.md) states the estimator equations and
physical assumptions. [PORTING_AUDIT.md](docs/PORTING_AUDIT.md) distinguishes
repairs to the supplied pasted script from intentional algorithm and lifecycle
changes. The new estimator uses portable Double operations and a weighted
least-squares tone model. It is not advertised as the original vDSP algorithm,
as a zero-jitter implementation, or as a calibrated ranging instrument.
[OBSERVATORY.md](docs/OBSERVATORY.md) defines the new modes, display semantics,
frequency transitions, and explicit 64-byte encoding.

## TestFlight and App Store preparation

The third-party build Mac needs an authorized Apple Developer team, a registered
bundle identifier, and valid signing assets. `org.timelabs.RheaRFSpanner` is now
registered for **TAIMLABS, OOO**, team **398XACWZ7G**, and was checked against its
Apple-issued provisioning profile during the successful signed export.
The signing override is `Config/Signing.local.xcconfig`, which is excluded from
Git. `bash scripts/archive.sh` creates the signed archive only after the actual
signing configuration is present. `scripts/export.sh` accepts team-specific
export options; it does not invent an Apple team or upload an app automatically.

The manually dispatched **TestFlight** workflow also supports a GitHub-hosted
Mac, an exact reviewed source SHA, and existing signing assets supplied through
the protected `testflight` environment. Its default is a signed archive and local
IPA export. Apple validation/upload requires an explicit input. The included
Windows intake form sends selected local credentials directly to encrypted
GitHub environment secrets; it never starts a build or upload.
See [the TestFlight operator guide](docs/TestFlight.md) and
[Windows signing preparation](docs/WindowsSigning.md). The latter creates a
local CSR, completes an Apple-issued certificate with its existing Windows key,
and stores an encrypted recovery copy without printing private key material or
passwords. Signed export and Apple validation/upload have completed for
**0.2.0 (2)**. Apple processing and tester availability remain separate stages;
processing is confirmed, the internal group contains the **Ready to Test** build,
and the owner reports successful installation. This confirms delivery, not
physical measurement accuracy or a resolution of the reported LIVE problem.
See the [upload validation record](docs/TESTFLIGHT_UPLOAD_VALIDATION.md).

See [AppleSubmission.md](docs/AppleSubmission.md),
[AppReviewLetter.md](docs/AppReviewLetter.md), and
[ReviewTestPlan.md](docs/ReviewTestPlan.md). Match every submission statement to
the final binary and source commit, and complete physical-device checks before
submitting it. The choice of a source license remains separate from publication;
no license grant is asserted here.


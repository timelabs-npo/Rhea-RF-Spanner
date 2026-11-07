# Rhea RF Spanner

An inspectable iOS application for **acoustic phase experiments** using an
iPhone's built-in speaker and microphone. The display name is **Rhea RF Spanner**;
the public source repository is
[timelabs-npo/Rhea-RF-Spanner](https://github.com/timelabs-npo/Rhea-RF-Spanner).

The Observatory update adds a **18–22 kHz acoustic carrier grid in 500 Hz steps**,
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

**Baseline CI passed on 7 November 2026:** the release signal core compiled,
all 18 XCTest tests passed, and the iOS Simulator Debug and unsigned iOS
device Release applications both built successfully with Xcode 26.3.
See [the public GitHub Actions run](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42380978695),
which tested source commit `05bc66497630ecc88382d8352002c1a3f0733896`.
Physical-iPhone execution, signing, and TestFlight delivery remain separate
release steps.

The Observatory feature branch has additional code and tests; its results are
tracked separately in [docs/OBSERVATORY_VALIDATION.md](docs/OBSERVATORY_VALIDATION.md).
The earlier 18-test run is not evidence for these new sources.

See [docs/BUILD_STATUS.md](docs/BUILD_STATUS.md) for commands, exit codes, source
fingerprints, and the distinction between portable-core, iOS, signing, and
physical-device results. Compiler logs are retained under `docs/validation/`.
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
and Waterfall screens after the simulator build. CI retains these as artifacts.

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
no file-export UI, account, server, telemetry SDK,
advertising, remote configuration, background audio mode, or downloaded code.
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
bundle identifier, and valid signing assets. `org.timelabs.RheaRFSpanner` is a
proposed build default; this repository does not assert that it is registered.
The signing override is `Config/Signing.local.xcconfig`, which is excluded from
Git. `bash scripts/archive.sh` creates the signed archive only after the actual
signing configuration is present. `scripts/export.sh` accepts team-specific
export options; it does not invent an Apple team or upload an app automatically.

See [AppleSubmission.md](docs/AppleSubmission.md),
[AppReviewLetter.md](docs/AppReviewLetter.md), and
[ReviewTestPlan.md](docs/ReviewTestPlan.md). Match every submission statement to
the final binary and source commit, and complete physical-device checks before
submitting it. The choice of a source license remains separate from publication;
no license grant is asserted here.


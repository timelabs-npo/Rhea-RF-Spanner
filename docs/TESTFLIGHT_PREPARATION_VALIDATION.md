# TestFlight preparation: executed native checks

The distribution-preparation source passed all configured native application
checks in [GitHub Actions run 42416851915](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42416851915).
The exact tested commit was
[`a93da56e45726d84e27f567c323eeda45b17d7d4`](https://github.com/timelabs-npo/Rhea-RF-Spanner/commit/a93da56e45726d84e27f567c323eeda45b17d7d4).
The job finished on **2026-11-07 at 21:49:19 UTC**.

This run compiled and tested the application and checked the installed Apple
distribution tools without credentials. It did **not** sign or upload an app.

## Executed results

The runner used Xcode **26.3** (build **17C529**), Apple Swift **6.2.4**, and
the iPhoneOS **26.2** SDK on `macos-15-arm64`. The deployment target remains
iOS **18.0**.

| Check | Result | Retained evidence |
| --- | --- | --- |
| Release Swift core build | Passed | [Build log](validation/testflight-preparation/macos/swift-build-release.log) |
| Core tests on macOS | **41 tests, 0 failures** | [Test log](validation/testflight-preparation/macos/swift-test.log) |
| Generic iOS Simulator Debug app | `BUILD SUCCEEDED`; arm64 and x86_64 | [Simulator build log](validation/testflight-preparation/macos/xcode-simulator.log) |
| Unsigned iOS device Release app | `BUILD SUCCEEDED` | [Device build log](validation/testflight-preparation/macos/xcode-device-unsigned.log) |
| Simulator-hosted application tests | **5 tests, 0 failures**; `TEST SUCCEEDED` | [Hosted test log](validation/testflight-preparation/macos/xcode-session-tests.log) |
| Native Simulator launch and capture | Idle, silent DEMO Field, and DEMO Waterfall captured on iPhone 17 Pro | [Capture log](validation/testflight-preparation/macos/simulator-capture.log) |
| Distribution tooling preflight | Xcode export options and the `altool` API-key upload interface available | [Preflight log](validation/testflight-preparation/macos/testflight-preflight.log) |

The five hosted tests comprise the two existing session tests and three new
renderer regressions. The renderer checks inspect the texture uploaded to Metal:

- A replacement spectrum with an unchanged sample timestamp refreshes its bins.
- A missing capture interval remains unavailable when 257 history slots are
  compressed into 256 display rows.
- Contiguous history remains available and its newest spectrum is at the top.

The session tests cover retuning into a new epoch, Replay preserving its original
simulated source, display settings remaining independent of acquisition, and no
automatic restart after a background transition. All use silent DEMO. They do not
measure the response of a physical microphone, speaker, or acoustic scene.

The capture helper produced a uniquely named XCTest result bundle,
`ObservatorySession-b307a1fcad214e8e8e680c2481d31686.xcresult`. The bundle and the
three original PNG captures are included in the
[Actions artifact](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42416851915/artifacts/13591348672).
This artifact expires on **2026-11-14**; the compiler/test logs above are retained
in the repository independently of that retention period. Earlier native visual
evidence remains in [Observatory validation](OBSERVATORY_VALIDATION.md).

## Source and artifact identity

[run-summary.json](validation/testflight-preparation/run-summary.json) records
the run, job, steps, source, toolchain, artifact, and result boundaries.
[sha256.json](validation/testflight-preparation/sha256.json) fingerprints the
retained evidence. The downloaded artifact was verified as:

- Artifact ID: `13591348672`.
- Size: `2848740` bytes.
- SHA-256: `1af364086ae1c5b344b2ac6bbeee7620e29d96dad173fa83f6a4279f6c51b6b3`.

The artifact name contains the pull-request merge SHA. The source actually
checked out and tested is `a93da56e45726d84e27f567c323eeda45b17d7d4`, as shown by
the [checkout excerpt](validation/testflight-preparation/macos/source-checkout-excerpt.log)
and GitHub's run metadata.

The subsequent commit
[`cbc9d5750bf50d0f26be2b10703a5f21fececb4c`](https://github.com/timelabs-npo/Rhea-RF-Spanner/commit/cbc9d5750bf50d0f26be2b10703a5f21fececb4c)
changes only `.github/workflows/testflight.yml`, moving the output-directory
initialization out of an unsupported job-level `runner` expression into a runner
step. The
[comparison](https://github.com/timelabs-npo/Rhea-RF-Spanner/compare/a93da56e45726d84e27f567c323eeda45b17d7d4...cbc9d5750bf50d0f26be2b10703a5f21fececb4c)
confirms that application and test inputs are unchanged. This does not claim an
execution of the corrected signing workflow. The earlier invalid workflow
definition is recorded in
[run 42416846513](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42416846513).

## Outcomes not established by this run

The read-only tooling preflight establishes command-line capability, not Apple
account authorization or successful code signing. This run used no signing
certificate, provisioning profile, or App Store Connect API key. It produced no
signed archive or exported IPA and made no Apple validation or TestFlight upload
request. Signing, upload processing, tester availability, and physical-iPhone
measurements require their own subsequent evidence.

See [TestFlight distribution](TestFlight.md) for the guarded manual workflow and
its distinction between local signed export and an explicit upload request.

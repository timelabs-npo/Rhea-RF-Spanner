# Build evidence

Date of work: **2026-11-07**. This file distinguishes executed checks from work
that still requires a usable build host or developer account.

## Portable signal core: executed successfully

Host: Debian GNU/Linux 13, x86_64. Compiler: official Swift 6.0.3
(`swift-6.0.3-RELEASE`, target `x86_64-unknown-linux-gnu`). The downloaded release
archive's detached signature verified against the Swift 6 release key with
fingerprint `52BB7E3DE28A71BE22EC05FFEF80A866B47A981F` from Swift.org.

| Command | Exit code | Observed result | Log |
| --- | --- | --- | --- |
| `swift build -c release` | 0 | Release core compiled; build 4.06 seconds | `validation/linux/swift-build-release.log` |
| `swift test` | 0 | 18 XCTest tests, 0 failures; tests 0.143 seconds | `validation/linux/swift-test-debug.log` |
| `swift test -c release` | 0 | 18 XCTest tests, 0 failures; tests 0.229 seconds | `validation/linux/swift-test-release.log` |

The tests cover irregular and oversized render lengths, oscillator periodicity,
SPSC wraparound/overflow, a concurrent 100,000-sample producer/consumer exercise,
real timestamp gaps, timestamps beyond 2^60, tone phase/unwrap, rebaselining,
silence, weak/poor-fit input, and nonfinite samples. They use synthetic inputs.
The separate Swift Testing discovery footer reports zero Swift Testing tests;
the 18 executed tests are XCTest tests.

## iOS application: compiled successfully on macOS

The Swift syntax parser accepted the app sources in the Linux environment.
Parsing does not resolve Apple frameworks and is not an iOS build result.

The macOS CI run in the private bootstrap repository completed with
**success**. Its compiler logs are retained in this source tree. This is
historical build evidence; publication does not record an additional build:

- Tested source commit: `2b52f3bc10f2c9408a4bbb2e029ee8dc5efa5471`.
- [GitHub Actions run 42378444311](https://github.com/timelabs-npo/ai-traces/actions/runs/42378444311).
- Job: `128420789419`, **Swift core and unsigned iOS app**.
- Xcode **26.3**, build **17C529**.
- Apple Swift **6.2.4**, `swiftlang-6.2.4.1.4`, clang `1700.6.4.2`.
- SDKs recorded in the compiler log: **iPhoneSimulator26.2.sdk** and
  **iPhoneOS26.2.sdk**. Deployment target: **iOS 18.0**.
- Run started **2026-11-07 13:45:53 UTC / 16:45:53 Europe/Moscow**; final run
  update **13:46:58 UTC / 16:46:58 Europe/Moscow**.

| macOS check | Actual result |
| --- | --- |
| `swift build -c release` | Success |
| `swift test` | 18 XCTest tests, 0 failures |
| `xcodebuild ... -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` | `BUILD SUCCEEDED` |
| `xcodebuild ... -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | `BUILD SUCCEEDED` |

The simulator and device app builds include Swift type checking against Apple
SDKs, linking, Metal shader compilation, asset processing, and resource copying.
The logs include the expected Xcode message that App Intents metadata extraction
was skipped because the application has no AppIntents framework dependency.

The complete successful job log is
[`validation/macos/attempt-2-job.log`](validation/macos/attempt-2-job.log), with
machine-readable metadata in
[`validation/macos/run-summary.json`](validation/macos/run-summary.json).

### Retained failed attempt

[Run 42378253883](https://github.com/timelabs-npo/ai-traces/actions/runs/42378253883)
tested the earlier commit `05b0c7c88c42f77bed189f810a3ae37831b18e68`. Its core
build and 18 tests passed, but the app failed Metal compilation: the fragment
parameter was named `vertex`, a reserved Metal qualifier. The parameter was
renamed to `stageInput`; the successful run above tests that correction. The
earlier log remains in
[`validation/macos/attempt-1-job.log`](validation/macos/attempt-1-job.log).

### Validation not performed

No app execution on a physical iPhone, acoustic validation, signed archive,
TestFlight upload, or Apple review is claimed. An unsigned device build is not
an installable TestFlight delivery. These are separate remaining release steps.

## Host and access observations

- The connected-device inventory reported both `wd` and `mio.local` Offline.
  No command was represented as having run on those devices.
- The local cloud host initially had neither Swift nor Xcode. Swift was
  installed in an isolated toolchain directory; the host still has no iOS SDK.
- Write permission to private `timelabs-npo/ai-traces` was verified. A dedicated
  `rhea-rf-spanner/bootstrap-2026-11-07` branch was created for isolated work.
- The standalone public repository is
  [timelabs-npo/Rhea-RF-Spanner](https://github.com/timelabs-npo/Rhea-RF-Spanner).
  Its root contains the Xcode project, application and package sources, tests,
  scripts, and documentation.

The historical bootstrap snapshot remains under `projects/rhea-rf-spanner/`
on the private branch. Encrypted operational key material remains under
`private/rhea-rf-spanner/` in that private repository. The public application
repository has independent source history and contains no operational key
material or private-repository history. The same boundary applies to the
standalone application archive.

A workflow for the public repository is included in
`.github/workflows/rhea-rf-spanner-ci.yml`. At the time of this publication
update, no completed public-repository CI result has been recorded here.

## Reproduce and associate results

`scripts/source_manifest.py` prints SHA-256 fingerprints of build inputs. A
snapshot is stored beside the validation records. Compare these fingerprints
or the recorded commit before carrying a build result forward to a later change.
The general release procedure and device checks are in `AppleSubmission.md`
and `ReviewTestPlan.md`.

Before packaging, 31 unchanged build inputs were compared byte-for-byte with
the uploaded source snapshot, and the corrected Metal file was compared with
its content retrieved directly from the successfully tested commit. No
unexpected build-input differences were found. Documentation and retained logs
were then added in a separate documentation commit; this does not claim a new
compiler execution for that later commit. See
`validation/build-input-match.json` and `validation/source-sha256.json`.

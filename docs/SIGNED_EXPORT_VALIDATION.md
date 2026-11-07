# Signed export validation

**A signed archive and App Store Connect IPA were successfully produced** for
Rhea RF Spanner **0.2.0 (2)** in
[run 42420624092, attempt 2](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42420624092),
completed on **2026-11-07 at 22:35 UTC**. Application source and release tooling
both came from
[`9bed85a1787aafabd919994e38eae66d3169c448`](https://github.com/timelabs-npo/Rhea-RF-Spanner/commit/9bed85a1787aafabd919994e38eae66d3169c448).

This was an **archive/export-only** run. Apple validation and upload were not
requested. The artifact is not evidence of TestFlight processing, availability
to testers, App Review approval, or physical-device measurement performance.

## Executed stages

| Stage | Result |
| --- | --- |
| Exact source and main-ancestry gate | Passed |
| Xcode/export toolchain preflight | Passed |
| Distribution identity and matching App Store profile checks | Passed |
| Signed Release archive | Passed |
| Local App Store Connect IPA export | Passed |
| Archived/exported app signature, identifier, build, profile, and entitlement checks | Passed |
| Artifact preservation | Passed |
| Temporary signing-state cleanup | Passed |
| Apple app validation and upload | Not requested; workflow step skipped |

The selected build tools were Xcode **26.3**, build **17C529**, and iPhoneOS SDK
**26.2**. The exported IPA's `Info.plist` reports:

| Field | Value |
| --- | --- |
| Bundle ID | `org.timelabs.RheaRFSpanner` |
| Display name | Rhea RF Spanner |
| Version | `0.2.0` |
| Build | `2` |
| Minimum iOS | `18.0` |
| Targeted device family | iPhone (`1`) |

The original [release manifest](validation/signed-export/release-manifest.json)
records the source, workflow revision, toolchain, hashes, and explicit
`not_requested` Apple states.
[Verification metadata](validation/signed-export/verification-summary.json)
records the observed run outcomes and bounded artifact inspection.

## First attempt and correction

Attempt 1 stopped before certificate import with the fixed diagnostic
`APPLE_DISTRIBUTION_P12_BASE64 must contain standard base64 for the original file.`
It produced no distribution artifact; cleanup succeeded.

A nonsecret Windows PowerShell 5.1 probe sent `QUJD` through the same process
stdin helper. The child received seven bytes (`EF BB BF 51 55 4A 44`): .NET
Framework had emitted a UTF-8 preamble before the direct `BaseStream` write.
Whitespace removal in the release decoder did not remove that preamble.

Both Windows helpers now select UTF-8 without a preamble before starting the
child process and restore the original console input encoding in `finally`.
The repeated probe received exactly four bytes (`51 55 4A 44`) and confirmed
restoration. The original protected identity was resubmitted without replacing
the certificate or private key. Attempt 2 then completed successfully using the
same application/workflow commit and build number.

See [Windows signing preparation](WindowsSigning.md) for the request,
completion, recovery, and transport behavior. The public request helper accepts
identity metadata through a parameter; no account email is embedded in source.

## Artifact identity

[Artifact 13593985601](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42420624092/artifacts/13593985601)
contains exactly `RheaRFSpanner.xcarchive.zip`, `RheaRFSpanner.ipa`, and
`release-manifest.json`. Its configured expiration is **2026-11-10 at 22:35 UTC**.
Download an authorized copy before that date if the original binary is needed.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| Complete Actions artifact ZIP | 2,173,438 | `583b5f41817117ff32dd2ab5c0a1c18cfdefe2ce8b9620ab7269c87a4fde3ece` |
| `RheaRFSpanner.ipa` | 344,560 | `876dad4447f196badde027d7d682cfb2322016863cc29fc002cc0a222ad01e85` |
| `RheaRFSpanner.xcarchive.zip` | 1,838,141 | `5a2c4c388e0bf382ce334cefc4186cd4f7c9bd7024662831cb17c2b1904580a5` |

The downloaded artifact digest matched GitHub's digest. The extracted IPA and
archive hashes matched the original release manifest. The source evidence
directory retains only that manifest and safe parsed metadata. It does not
contain certificates, provisioning profiles, private keys, passwords, API
credentials, raw signing logs, the IPA, or the archive.

## Bounded icon inspection

The IPA contains primary-icon metadata naming `AppIcon` and `AppIcon60x60`,
plus `AppIcon60x60@2x.png` and `Assets.car`. An iPad icon resource is also present;
the application remains targeted to iPhone. These references and filenames
show no obvious absent primary app icon. This check does not inspect all
compiled asset-catalog renditions or replace Apple's asset validation. The
embedded provisioning profile was not opened during this bounded inspection.

## Native checks on the same main commit

The same main source also completed these checks successfully:

- [Native compile and test run 42420093956](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42420093956).
- [CodeQL run 42420093336](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42420093336).
- [Code Quality run 42420093579](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42420093579).

The preceding [native validation record](TESTFLIGHT_PREPARATION_VALIDATION.md)
details the 41 core tests and five hosted application tests. Signed export
adds evidence for distribution identity/profile integration; it does not turn
synthetic or Simulator results into physical acoustic measurements.

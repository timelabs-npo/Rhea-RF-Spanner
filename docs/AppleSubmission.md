# Apple submission and release preparation

Policy research checked on **7 November 2026** against the Apple sources linked below. Recheck time-sensitive requirements when preparing the actual upload. This document does not record an upload, a signed archive, a review submission, or approval.

## Toolchain and distribution

Apple currently requires App Store Connect uploads to be built with **Xcode 26 or later and an iOS 26 SDK or later**, effective 28 April 2026. The app's intended **iOS 18 minimum deployment target** is a separate setting. Swift 6 / Xcode 16 source compatibility, if tested, would not by itself make that toolchain acceptable for a current upload. Source: [SDK minimum requirements](https://developer.apple.com/news/upcoming-requirements/?id=04282026a).

The repository's Swift package tests exercise the package they build. A successful `swift build` does not create a signed iOS app archive. Build the Xcode application target with an iOS SDK, validate its embedded resources, and archive with a verified Apple Developer team and provisioning configuration for distribution.

Use TestFlight for beta distribution. The first externally tested build is subject to TestFlight App Review; later builds may also require review. Beta metadata and review contact information must be complete. TestFlight builds remain testable for up to 90 days. See [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/) and [Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers).

## Feature description to keep consistent

**Product name:** Rhea RF Spanner  
**Feature description:** Acoustic phase experiment using the built-in speaker and microphone.  
**Tone:** 20 kHz, fixed digital amplitude of 0.02 full scale; system volume and hardware affect acoustic output.  
**Supported session:** Built-in audio route at an actual 48 kHz sample rate, active foreground, explicit agreement and Start, up to 60 seconds.  
**Displayed result:** Relative acoustic phase and a conditional phase-to-displacement model.  
**Visualization:** An abstract representation of phase, not a scene reconstruction.  
**Application data flow:** Volatile-memory processing, no audio-file storage, no app telemetry upload, no login or analytics SDK.

The product name is retained. Descriptions must explain that this release uses acoustic signals and does not implement RF acquisition. Do not advertise absolute distance, hardware-independent accuracy, inaudibility, a calibrated safe sound level, zero jitter, or recognition of specific targets without evidence for that claim.

## Apple review requirements relevant to this release

The following is a concise implementation mapping, not a guarantee of acceptance:

| Requirement | Evidence the release needs |
| --- | --- |
| Complete, functional submission and accurate metadata. | On-device results, working support/policy links, correct version/build and review notes. |
| Public APIs and disclosed functionality. | Source matching the submitted binary; documented audio, DSP, and visualization paths. |
| Consent and a clear microphone-use indication. | Start agreement, purpose string, iOS permission flow, active banner and Stop control. |
| No hidden, dormant, or undocumented features. | Feature inventory matching code, UI, and letter. |
| Privacy disclosure and accessible policy. | Policy available in the app and through the App Store Connect policy URL; accurate data declarations. |

Relevant sections are **2.1, 2.2, 2.5.1, 2.5.14, 2.5.19, and 5.1.1** of the [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/). The hidden-feature provision was moved to 2.5.19 in the [16 October 2026 update](https://developer.apple.com/news/?id=92th7e5i). Describing a project as research does not establish an exception to these requirements.

## Permission text

The `NSMicrophoneUsageDescription` in the app's property list is:

> Rhea RF Spanner uses the microphone during an experiment you start to analyze the phase of its 20 kHz acoustic tone. Audio is processed on this device and is not saved or uploaded.

The purpose string must match the released implementation. Apple explains the requirement for a specific explanation in [Write clear purpose strings](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-purpose-strings). `NSMicrophoneUsageDescription` is required for microphone access; see [requestRecordPermission(completionHandler:)](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)).

## Privacy manifest

The app must bundle a syntactically valid `PrivacyInfo.xcprivacy` property list with values that match the code. For the present data flow, no tracking and an empty collected-data array describe the app's own behavior, subject to verification of the complete release bundle. The Observatory update uses ProcessInfo.systemUptime for the session's elapsed-time limit and DEMO pacing, so its accessed-API array declares NSPrivacyAccessedAPICategorySystemBootTime with reason 35F9.1. It does not retain or transmit a system boot timestamp.

If `mach_absolute_time()` or `ProcessInfo.systemUptime` is used to compute elapsed animation/session time, declare `NSPrivacyAccessedAPICategorySystemBootTime` with reason `35F9.1`. That reason covers elapsed in-app time and timer calculations. Do not add reasons for APIs absent from the implementation or reuse this declaration for a different purpose. Sources: [Required reason API categories](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype) and [Adding a privacy manifest](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk).

Validate the plist, its target membership, and its final location in the built app. A plain-text list of privacy keys is not a privacy manifest. The App Store privacy questionnaire remains separate from this file.

## Submission information that must be verified

| Item | Verification required before upload or review |
| --- | --- |
| Apple Developer membership and team | Active enrollment, authorized roles, correct team; no guessed team ID. |
| Bundle identifier | Registered and owned by the selected team; matches project, profile, archive, and App Store Connect record. |
| Signing assets | Valid certificate/private key and provisioning, kept outside public source; build operator has authorized access. |
| App Store Connect API key, if used | Issued by Apple for the intended team/role; a locally generated key is not an issued Apple credential. |
| Source repository | Public source: [timelabs-npo/Rhea-RF-Spanner](https://github.com/timelabs-npo/Rhea-RF-Spanner). Confirm that the source commit linked in the submission matches the submitted binary. |
| Source-to-binary association | Commit, version/build, archive identity, and build log identify the submitted artifact. |
| Support and privacy mailboxes | Addresses are provisioned, controlled, and monitored; a proposed address is not an existing mailbox. |
| Public support and privacy URLs | Reachable, complete pages matching the app; no temporary or missing-contact policy used as final metadata. |
| Review contact | Real authorized person and reachable contact details in App Store Connect. |
| Privacy answers and age rating | Completed against the actual app and included SDKs. |
| Export-compliance answers | Completed for the actual distributed binary; do not infer from this repository's signing keys. |
| Screenshots and icon | Actual app representations, correct assets and sizes; no fabricated measurement claims. |
| Device tests | [ReviewTestPlan.md](ReviewTestPlan.md) executed on the intended iPhone hardware, with outcomes retained. |

## Review materials

- [AppReviewLetter.md](AppReviewLetter.md): full accompanying explanation.
- [ReviewTestPlan.md](ReviewTestPlan.md): reviewer navigation and reproducible device checks.
- [PrivacyPolicy.md](PrivacyPolicy.md): policy text and its outstanding contact/publication fields.

The letter is a disclosure and invitation to constructive review. Open source, a valid manifest, or a successful build does not independently establish approval of the app or protect a developer account from enforcement.

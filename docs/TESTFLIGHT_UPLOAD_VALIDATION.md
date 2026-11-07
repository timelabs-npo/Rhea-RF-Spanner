# Apple validation and upload record

**Observed result:** [distribution run 42423704040, attempt 1](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42423704040) completed successfully on **2026-11-07 at 23:09:03 UTC**. Apple validation passed and the upload tool reported acceptance of **Rhea RF Spanner 0.2.0 (2)**. App Store Connect subsequently confirmed successful processing. The build is **Ready to Test** in **Rhea RF Spanner Internal**, which has **1 Tester** and **1 Build**. The tester is **Invited**; invitation acceptance and iPhone installation have not been observed.

## Exact release identity

| Field | Observed value |
| --- | --- |
| Application source | `9bed85a1787aafabd919994e38eae66d3169c448` |
| Workflow and release tooling | `f073a364939080154c02bd347acce72f88a11c81` |
| Dispatch branch | `main` |
| Version / build | `0.2.0` / `2` |
| Bundle identifier | `org.timelabs.RheaRFSpanner` |
| Explicit upload input | `true` |
| Xcode | `26.3`, build `17C529` |
| iPhoneOS SDK | `26.2` |
| Run creation | `2026-11-07T23:06:29Z` |

The workflow rebuilt and signed the exact application source. It did not reuse the IPA from the earlier [export-only run](SIGNED_EXPORT_VALIDATION.md). The earlier and uploaded artifacts therefore have different hashes.

## Verified stages

| Stage | Result |
| --- | --- |
| Exact source and reviewed-main ancestry checks | Passed |
| Installed Xcode export interface | Passed |
| Signing identity/profile checks and signed archive | Passed |
| Local App Store Connect IPA export and product verification | Passed |
| Apple validation | Passed |
| Apple upload | Upload tool reported acceptance |
| Artifact preservation | Passed |
| Temporary credential cleanup | Passed |
| Apple processing | Confirmed `VALID` by the subsequent App Store Connect check |
| TestFlight build visibility | Version 0.2.0 / build 2 Ready to Test in the internal group |
| Internal group | Rhea RF Spanner Internal; 1 Tester, 1 Build |
| Tester status | Invited; acceptance and installation unconfirmed |
| External beta review | Not submitted; no external test group added |

The downloaded `release-manifest.json` records:

```json
{
  "local_signature_and_profile_checks": "passed",
  "apple_validation": "passed",
  "apple_upload": "accepted_by_upload_tool_processing_pending"
}
```

This is the original manifest state at upload completion; it is not rewritten to incorporate later service observations. Upload and processing remain distinct from App Review approval, tester access, and physical-device acoustic validation.

## Subsequent Apple processing confirmation

At **2026-11-07T23:14:21Z**, a separate authenticated query of the official App Store Connect API confirmed these nonsecret release fields. No authentication material or raw API response is retained in this document.

| Field | Observed value |
| --- | --- |
| App Store Connect app ID | `6832102411` |
| Build resource ID | `68e6ece0-ce01-4bd8-9ac2-3f335d27c1e2` |
| Build number / processing state | `2` / `VALID` |
| Non-exempt encryption | `false` |
| Upload version / build / platform | `0.2.0` / `2` / `IOS` |
| Upload state | `COMPLETE` |
| Upload errors / warnings / infos | All empty |
| Uploaded date | `2026-11-07T23:08:57Z` |
| Build expiration | `2027-02-05T23:12:39Z` |

The observations came from `/v1/apps/6832102411/builds` and the corresponding `buildUploads` resource. The App Store Connect browser view independently displayed **Version 0.2.0, Build 2, Ready to Submit**, with 90 days until expiration. This establishes that Apple processed the build and made it visible in TestFlight management; it does not establish an accepted tester invitation or installation on an iPhone.

## Internal TestFlight assignment

Later on **November 7, 2026**, the App Store Connect browser confirmed that **Rhea RF Spanner Internal** contained **1 Tester** and **1 Build**, with **0.2.0 (2)** marked **Ready to Test**. Only the current account holder was added. The tester status was **Invited**, dated November 7, 2026.

No invitation acceptance or installation on an iPhone was observed. No other testers, external test group, or external beta review were added. The internal invitation does not establish external beta or App Store review approval. Personal names and email addresses are omitted from this public record.

## Artifact integrity

[Artifact 13594461690](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42423704040/artifacts/13594461690) is named `rhea-testflight-9bed85a1787aafabd919994e38eae66d3169c448-build-2`. It contains exactly the IPA, signed archive ZIP, and release manifest. Its recorded retention expiry is **2026-11-10 at 23:08:58 UTC**.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| Downloaded Actions artifact ZIP | 2,173,326 | `6881d7d5d5f4a95f1f70362eeef6ad95d53ff02ec4df27befa4339d809d412c7` |
| `RheaRFSpanner.ipa` | 344,563 | `8042e6c0d6c45565ac202dcc58bae38f3630ecc45a8bf1cfd280dbf1b7be6947` |
| `RheaRFSpanner.xcarchive.zip` | 1,838,113 | `2dd3502761151b6e6479c4343a24d2c901c21c9fc3f2287fa5561096e00a1d65` |
| `release-manifest.json` | 571 | `ad01ca110b441ddef732363a252eecde463c87d7544eba1c58235856762eb6bc` |

The artifact ZIP digest was independently checked against GitHub's reported digest. The IPA and archive digests were independently recomputed and matched the release manifest. No API key identifiers, issuer identifier, credential hashes, private key material, raw certificates/profiles, or raw Apple tool logs are included in this record.

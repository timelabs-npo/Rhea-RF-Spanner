# Manual TestFlight distribution

The **Rhea RF Spanner — TestFlight** workflow builds one explicitly selected source commit with existing Apple-issued signing assets. Its default is **signed archive and local IPA export**. Apple validation and upload run only when `upload_to_testflight` is explicitly `true`.

Each successful export includes a manifest identifying the source commit, workflow revision, build number, toolchain, and artifact hashes. A signed export, an accepted upload, Apple processing, and TestFlight availability are separate stages. No signed archive or upload is established by static checks alone.

## Executed signing and upload results

On **2026-11-07 UTC**, [run 42420624092, attempt 2](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42420624092) successfully archived and exported source `9bed85a1787aafabd919994e38eae66d3169c448` as **Rhea RF Spanner 0.2.0 (2)**, bundle `org.timelabs.RheaRFSpanner`. Local signature/profile checks and temporary credential cleanup passed. The run used `upload_to_testflight=false`; Apple validation and upload were **not requested**. The [signed export validation record](SIGNED_EXPORT_VALIDATION.md) retains the release manifest and safe artifact metadata.

Later that day, [run 42423704040, attempt 1](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42423704040) rebuilt the same source/version/build using workflow revision `f073a364939080154c02bd347acce72f88a11c81` and `upload_to_testflight=true`. The run completed successfully: local signing/export checks, Apple validation, upload-tool acceptance, artifact preservation, and temporary credential cleanup all passed. Its manifest records `apple_validation=passed` and `apple_upload=accepted_by_upload_tool_processing_pending`.

At **23:14:21 UTC**, a subsequent App Store Connect API check confirmed build 2 as `processingState=VALID` and its upload as `state=COMPLETE`, with empty errors, warnings, and infos arrays. The App Store Connect browser view initially displayed **Version 0.2.0, Build 2, Ready to Submit**.

The build was then assigned to **Rhea RF Spanner Internal**. The final browser check showed **1 Tester**, **1 Build**, and **0.2.0 (2), Ready to Test**. Only the current account holder was added, with status **Invited** on November 7, 2026. Invitation acceptance and iPhone installation were not observed. No other testers, external test group, or external beta review were added. See [the upload validation record](TESTFLIGHT_UPLOAD_VALIDATION.md) for the observations and exact artifact hashes.

## 1. Supply the existing Apple assets

Use an active Apple Developer team, its registered explicit bundle identifier, and an existing App Store Connect app record for that identifier. Do not use the repository's proposed bundle identifier unless it is actually registered to the selected team.

Required existing files:

- An **Apple Distribution** or supported **iOS Distribution** certificate and its private key exported together as a password-protected `.p12`. The latter appears as an `iPhone Distribution:` signing identity and is accepted by the validator.
- An **iOS App Store Connect distribution provisioning profile** for the same explicit App ID and certificate. Development, Ad Hoc, and Enterprise profiles are rejected.
- For upload, an Apple-issued **App Store Connect team API key** `.p8`, its key ID, and its issuer UUID. Use an authorized role that can upload builds, such as Developer. This helper uses team-key authentication; individual keys use a different JWT model and are unsupported here.

Apple's [profile creation instructions](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/) and [API key documentation](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api) explain the assets. API key identifiers and issuer UUIDs are not the Apple Developer Team ID. App ID prefixes can also differ from Team ID; the validator handles that distinction.

If the original private key is unavailable, follow [Windows signing preparation](WindowsSigning.md) to generate a local CSR, complete the issued certificate, and store the distribution identity securely. Downloading the public certificate again does not restore its private key. The Windows guide also covers the supported iOS Distribution option when the portal offers it, issuer-chain checks, and the Windows-user-bound DPAPI recovery copy. Create a matching provisioning profile for the newly issued certificate before dispatching a build.

## 2. Protect the GitHub environment

In `timelabs-npo/Rhea-RF-Spanner`, configure an environment named **`testflight`** with deployment restricted to **`main`**. The baseline setup uses main-only manual dispatch, an exact source SHA, and explicit upload gating. Teams may add required reviewers under their own release policy. Environment branch protection is repository configuration; the workflow cannot establish it by declaring the environment name. See GitHub's [environment protection documentation](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).

Set these **environment secrets**:

| Name | Value |
| --- | --- |
| `APPLE_DISTRIBUTION_P12_BASE64` | Standard base64 of the original `.p12` file. |
| `APPLE_DISTRIBUTION_P12_PASSWORD` | Its exact export password. |
| `APP_STORE_PROFILE_BASE64` | Standard base64 of the original `.mobileprovision` file. |
| `ASC_PRIVATE_KEY_P8_BASE64` | Standard base64 of the original Apple-issued `.p8`; used only for explicit upload. |

Set these **environment variables**, with actual issued values:

| Name | Value |
| --- | --- |
| `APPLE_TEAM_ID` | The 10-character uppercase Apple Developer team ID. |
| `APP_BUNDLE_ID` | The registered explicit bundle identifier. |
| `ASC_KEY_ID` | The 10-character App Store Connect team API key ID. |
| `ASC_ISSUER_ID` | Its issuer UUID. |

On the authorized Windows workstation, the included local intake form selects existing files and sends secret values to GitHub through redirected standard input:

```powershell
powershell.exe -STA -File .\scripts\windows\Import-TestFlightCredentials.ps1
```

It requires an authenticated GitHub CLI account authorized to administer this environment. It does not dispatch the workflow or upload an app. `-ValidateOnly` loads its definitions without opening dialogs or reading credential files. Credential bytes and the p12 password belong in that local form, not in chat, source files, command-line arguments, or screenshots. GitHub also supports [setting environment secrets with `gh secret set --env`](https://cli.github.com/manual/gh_secret_set).

For an identity generated with the [Windows CSR/completion helpers](WindowsSigning.md), completion writes the two distribution secrets directly using a generated password; it does not require copying that password into the intake form. Preserve its DPAPI recovery file and Windows user profile. The provisioning profile, nonsecret identifiers, and optional ASC upload key remain separate setup inputs.

For an archive/export-only run, the ASC key and its identifiers are not required and are not passed into the signing step.

## 3. Check the installed tools without credentials

On a Mac with the selected Xcode:

```bash
bash scripts/testflight.sh preflight
```

This read-only command checks Xcode and the iPhoneOS SDK (version 26 or later), the installed `xcodebuild -help` export options, and `altool --help` API-key validation/upload flags. It does not read signing assets, activate an API key, validate an app with Apple, or upload anything. The workflow selects `/Applications/Xcode_26.3.app/Contents/Developer`, matching the project's compile CI; a missing installation fails explicitly.

The local preflight is an interface check. It does not establish that a supplied certificate, account, profile, or App Store Connect app record is valid. Apple's [current SDK submission requirements](https://developer.apple.com/news/upcoming-requirements/?id=04282026a) are separate from this app's iOS 18 minimum deployment target.

## 4. Dispatch an archive/export run

Review and merge the intended source first. In GitHub Actions, choose **Rhea RF Spanner — TestFlight**, select the **main** workflow branch, and enter:

| Input | Required choice |
| --- | --- |
| `source_commit` | Full 40-character lowercase SHA of the reviewed source commit. It must be reachable from main at the workflow's dispatch revision. Branches, tags, and PR-only commits are rejected. |
| `build_number` | An explicitly chosen unused positive integer, `1` through `9999`, for the app version. Check App Store Connect before choosing it. |
| `upload_to_testflight` | Leave **false** for archive/export only. |

The workflow checks out release tooling at the immutable dispatch revision and the application source at the exact requested SHA. Review of the source includes build phases and package manifests because they execute during compilation. No signing job runs on a push or pull-request event.

The signing job:

1. Creates a temporary keychain with a runtime-only random password and imports the supplied distribution identity with signing-tool access.
2. Checks profile type, expiry, team, explicit App ID/prefix, disabled debugging, TestFlight eligibility, and membership of the imported valid distribution certificate in the profile.
3. Installs the profile under `~/Library/Developer/Xcode/UserData/Provisioning Profiles`, the current Xcode path documented in [Xcode 16 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes).
4. Generates a temporary app-target signing override. It verifies that Xcode actually applies Manual signing, the provided team/bundle ID, selected certificate/profile, and requested build number.
5. Archives and exports using `method=app-store-connect`, `destination=export`, explicit `provisioningProfiles` mapping, `signingStyle=manual`, the certificate fingerprint, and disabled automatic version management. It does not use `-allowProvisioningUpdates` or request new signing assets.
6. Verifies both archived and exported application signatures, bundle/build identifiers, embedded profile, and signed App ID/team entitlements. It then removes the temporary signing state.

The workflow retains `RheaRFSpanner.xcarchive.zip`, `RheaRFSpanner.ipa`, and `release-manifest.json` as an Actions artifact for **3 days**. Download these before expiry. They are distribution products and contain normal signed-app metadata, including the embedded provisioning profile. Artifact access follows repository permissions; this repository is public. Private keys, keychain files, raw credential files, and raw signing-tool logs are excluded from the artifact allowlist.

## 5. Request upload explicitly

After reviewing a successful exported build and confirming App Store Connect metadata, run the workflow with `upload_to_testflight=true` and an unused build number. This run builds and verifies its own export before accessing the ASC key.

The upload step installs the provided key temporarily at `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`, checks its expected EC key format, and invokes:

```text
xcrun altool --validate-app -f <verified IPA> -t ios --apiKey <issued key ID> --apiIssuer <issuer UUID>
xcrun altool --upload-app   -f <verified IPA> -t ios --apiKey <issued key ID> --apiIssuer <issuer UUID>
```

The second command runs only if validation succeeds. With `upload_to_testflight=false`, neither command runs, and the ASC key is never installed. Apple's [upload guide](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) documents these app-distribution operations. [TN3147](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool) describes API-key arguments and the key location; altool's notarization deprecation does not remove its App Store upload support.

Upload success means the upload tool reported acceptance. Wait for Apple processing and resolve any App Store Connect messages. Add testers or submit external TestFlight review separately; this workflow does neither. If upload fails or times out, check whether Apple received the build before retrying. The manifest records attempted network stages as pending until success is reported, so an uncertain result is not described as a rollback.

## Cleanup and troubleshooting

Cleanup runs in each credential-handling command's `finally` block and again in an `always()` workflow step. It restores the keychain search list and removes the temporary keychain, installed profile, temporary signing configuration, API key file, decoded credential files, and private logs. The job uses a disposable GitHub-hosted Mac.

Failure messages identify the failed stage without printing secret values. Common fixes are supplying a matching p12/profile, renewing an expired profile or certificate, confirming the p12 password and private key, selecting the correct team/bundle ID, completing Apple agreements, and choosing an unused build number. Full source/signing diagnostics can be reproduced on an authorized Mac with the same inputs; the automated job deliberately does not publish raw signing logs.

Windows PowerShell 5.1 can prefix redirected stdin with a UTF-8 byte-order mark even when code subsequently writes directly to `StandardInput.BaseStream`. The included intake and completion helpers explicitly select UTF-8 without a preamble before starting the child process and restore the original console encoding afterward. This transport correction was verified using a nonsecret fixture and the subsequent successful signed export. If an older helper supplied the credentials, use the corrected helper to resubmit the same original identity; changing certificates does not repair an encoding error. See [Windows signing validation](WindowsSigning.md#validation-snapshot--2026-11-07-utc).

The profile checks follow Apple's [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles) and [TN2311 App ID prefix guidance](https://developer.apple.com/library/archive/technotes/tn2311/). Temporary keychain handling follows GitHub's [Xcode signing guide](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications), with a signing-specific import ACL and per-run keychain password.

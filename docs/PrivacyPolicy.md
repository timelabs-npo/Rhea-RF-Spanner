# Rhea RF Spanner privacy policy

**Document status:** Pre-release policy for the current implementation. A monitored contact address and a working public policy URL have not been verified by this document. Complete those release fields before publishing this as the final policy or submitting the app.

## Microphone use

Rhea RF Spanner analyzes acoustic signals on the device. It uses the built-in speaker to emit a 20 kHz tone and the built-in microphone to analyze received sound during an experiment you start. The microphone can also receive surrounding sounds, including speech.

An experiment begins only after you agree to the tone and live microphone analysis, tap **Start experiment**, and grant the app iOS microphone permission. When permission is first granted, the app returns to idle; tap **Start experiment** again when ready. The active screen identifies microphone and tone use and provides **Stop experiment**. Sessions have a 60-second limit. Leaving the active app, an audio interruption, an audio route change, or an audio-service reset ends the experiment. Opening Privacy & method also stops an active experiment. Returning to the app or closing that information view does not restart it.

## Processing, retention, and sharing

Application code processes microphone samples and displays current measurements using volatile memory. It does not save audio files or a measurement history, upload microphone samples or measurements, transcribe speech, identify people, or create a user profile. The app provides no recording library or data-export feature.

The app includes no account system, advertising, analytics SDK, tracking mechanism, or background recording mode. The current implementation does not send microphone data or measurements to the developer or a third-party service. It does not require a server connection to perform the experiment.

Memory-only processing is not a claim that the app controls every aspect of iOS memory management or guarantees forensic erasure. The application does not intentionally persist the samples or measurement results.

## Your controls

You can stop an active experiment at any time. You can revoke microphone access in iOS Settings. Privacy and method information remain available without microphone permission. Because the app does not maintain an account, audio archive, or uploaded measurement record, it provides no account-deletion or recording-deletion workflow.

Use the experiment with the agreement of people nearby. Keep the device away from ears, use a low system volume, and stop if the sound causes discomfort. The tone is not guaranteed to be inaudible. The software amplitude setting is not a calibrated sound-pressure measurement.

## Apple distribution and feedback

Apple operates the App Store and TestFlight, including their delivery, diagnostic, and feedback features. Information you choose to provide through those services is handled under Apple's applicable policies and settings. Their operation is separate from the app's microphone-processing code. See [Apple's privacy policy](https://www.apple.com/legal/privacy/) and [TestFlight information](https://developer.apple.com/testflight/).

## Contact

The support and privacy contact for this application has not yet been provisioned and verified. A monitored address must be added here and to the release metadata before this policy is used for a distributed release. Do not send sensitive information to an invented or unverified address.

## Implementation changes

Any later addition that saves measurements, exports data, uses a network service, or changes microphone behavior requires a corresponding policy review. The policy and App Store privacy declarations must describe the actual distributed build.

## Maintainer note: privacy declarations

Apple defines collection for its App Store privacy label in terms of transmitting data off the device with developer or partner access beyond servicing a request in real time. The current app's local processing can therefore support **Data Not Collected** only while the distributed app and its integrated components continue to match this policy. This is an implementation assessment, not an Apple approval. See [App privacy details](https://developer.apple.com/app-store/app-privacy-details/).

`PrivacyInfo.xcprivacy`, App Store Connect privacy answers, microphone permission text, and this policy serve different purposes. A valid manifest does not replace a clear permission message or the published policy.

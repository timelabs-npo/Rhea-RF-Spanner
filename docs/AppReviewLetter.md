# App Review letter

**Status:** Prepared for the implemented feature set. This letter has not been sent to Apple. It does not assert that a build has passed compilation, device testing, TestFlight review, or App Store review. Match it to the submitted build and its source commit before use. Build and distribution evidence is recorded separately.

## Letter

Dear App Review Team,

We are submitting **Rhea RF Spanner**, an application for exploring acoustic phase measurements on an iPhone. Our purpose is to make the experiment understandable, inspectable, and controlled by the person using the device. We welcome technical questions and specific feedback about its behavior or presentation.

This release uses the built-in speaker to emit a fixed 20 kHz acoustic tone and the built-in microphone to analyze the received signal. Its name does not describe access to radio hardware: this implementation does not receive RF samples, access the baseband, scan wireless traffic, or form a radar image. The animated wave is explicitly labeled as an abstract phase visualization. The numeric displacement display is a model derived from relative phase, not an independently measured distance or a claim of calibrated ranging accuracy.

The app starts idle. An experiment requires an explicit agreement, a tap on **Start experiment**, and iOS microphone permission. Granting permission for the first time returns to the idle screen; the user taps **Start experiment** again when ready. While it is running, the screen shows **MICROPHONE + 20 kHz TONE ACTIVE** and a **Stop experiment** control. An experiment has a 60-second limit. Losing foreground activity, an audio interruption, an audio route change, or an audio-service reset ends the experiment; returning to the app does not restart it. The app supports the built-in audio route at 48 kHz and presents an error for unsupported routes instead of continuing with unsupported measurement assumptions.

The microphone may receive surrounding sounds, including speech. Samples are processed in volatile memory for the displayed signal measurements. Application code does not transcribe speech, identify people, create audio recordings, upload samples or measurements, or run a background listening service. The app has no account system, advertising, analytics SDK, remote configuration, downloaded executable code, or alternate recording mode. Its privacy and method explanation is available inside the app without granting microphone permission.

The full application source, the signal-processing implementation, build instructions, and a review test plan accompany this letter. There are no undocumented algorithms or hidden operational modes in the submitted feature set. The source snapshot corresponding to the submitted build can be identified by its commit. Developer signing and administrative credentials are kept outside the application source and are not embedded in the app.

We ask users to keep the phone away from their ears, use the experiment only with the agreement of people nearby, and stop if they experience discomfort. We do not promise that a 20 kHz tone is inaudible, and the software amplitude setting is not presented as a calibrated sound-pressure measurement.

Our aim is responsible, open experimentation within the platform's rules. If a behavior, claim, or disclosure needs revision, please identify the concern so we can explain it, provide reproducible technical evidence, or change the feature before broader distribution. We appreciate critical review and intend to respond constructively through App Store Connect.

Thank you for considering Rhea RF Spanner.

The Rhea RF Spanner development team

## Submission preparation

The letter does not replace the App Store Connect fields for a verified review contact, feedback email, support URL, privacy-policy URL, version/build number, or review notes. No mailbox or public repository URL is asserted to exist by this document. Confirm the source link and associate the submitted binary with its commit before attaching a source URL.

For concise review navigation, use [ReviewTestPlan.md](ReviewTestPlan.md). For the current Apple requirements and remaining release metadata, use [AppleSubmission.md](AppleSubmission.md).

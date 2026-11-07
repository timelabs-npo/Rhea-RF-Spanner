# App Review letter

**Status:** Prepared for the implemented feature set. This letter has not been sent to Apple. It does not assert that a build has passed compilation, device testing, TestFlight review, or App Store review. Match it to the submitted build and its source commit before use. Build and distribution evidence is recorded separately.

## Letter

Dear App Review Team,

We are submitting **Rhea RF Spanner**, an application for exploring acoustic phase measurements on an iPhone. Our purpose is to make the experiment understandable, inspectable, and controlled by the person using the device. We welcome technical questions and specific feedback about its behavior or presentation.

In LIVE, this release uses the built-in speaker to emit a selected acoustic tone from 18 to 22 kHz in 500 Hz steps and the built-in microphone to analyze the received signal. Its name does not describe access to radio hardware: this implementation does not receive RF samples, access the baseband, scan wireless traffic, or form a radar image. LIVE field graphics are abstract phase visualizations. DEMO uses a separately labelled synthetic source and makes no microphone or speaker request. Waterfall shows the spectrum computed from the selected sample source. Any phase-derived displacement is a conditional model, not an independently measured distance or calibrated ranging claim.

The app starts idle. LIVE requires explicit agreement, a deliberate start, and iOS microphone permission. Granting permission for the first time returns to idle; the user starts again when ready. The screen identifies the active source and tone frequency and provides a stop control. A LIVE experiment has a 60-second limit. Losing foreground activity, an audio interruption, an audio route change, or an audio-service reset ends it; returning to the app does not restart it. A user-selected carrier change starts a new acquisition epoch and reference. The app supports the built-in audio route at 48 kHz and reports unsupported routes instead of continuing with unsupported measurement assumptions.

The microphone may receive surrounding sounds, including speech. Samples are processed in volatile memory. Replay retains up to 2,048 derived telemetry records and bounded companion spectra in memory, preserving original LIVE/DEMO provenance; it does not record raw audio and cannot activate the microphone. The tape is not persisted across process termination. Application code does not transcribe speech, identify people, upload samples or measurements, or run a background listening service. The app has no account system, advertising, analytics SDK, remote configuration, or downloaded executable code. Its privacy and method explanation is available without microphone permission.

The full application source, the signal-processing implementation, build instructions, and a review test plan accompany this letter. There are no undocumented algorithms or hidden operational modes in the submitted feature set. The source snapshot corresponding to the submitted build can be identified by its commit. Developer signing and administrative credentials are kept outside the application source and are not embedded in the app.

We ask users to keep the phone away from their ears, use LIVE only with the agreement of people nearby, and stop if they experience discomfort. We do not promise that an 18–22 kHz tone is inaudible, and the software amplitude setting is not presented as a calibrated sound-pressure measurement.

Our aim is responsible, open experimentation within the platform's rules. If a behavior, claim, or disclosure needs revision, please identify the concern so we can explain it, provide reproducible technical evidence, or change the feature before broader distribution. We appreciate critical review and intend to respond constructively through App Store Connect.

Thank you for considering Rhea RF Spanner.

The Rhea RF Spanner development team

## Submission preparation

The letter does not replace the App Store Connect fields for a verified review contact, feedback email, support URL, privacy-policy URL, version/build number, or review notes. The public source is [timelabs-npo/Rhea-RF-Spanner](https://github.com/timelabs-npo/Rhea-RF-Spanner). Identify the exact submitted commit. No provisioned mailbox, signed binary, or review approval is asserted by this letter.

For concise review navigation, use [ReviewTestPlan.md](ReviewTestPlan.md). For the current Apple requirements and remaining release metadata, use [AppleSubmission.md](AppleSubmission.md).

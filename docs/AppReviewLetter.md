# App Review letter

**Status:** Prepared for **0.2.2 (4), Listen**. This letter has not been sent to App Review. The canonical [validation and distribution record](PASSIVE_AUDIO_VALIDATION.md) identifies the tested source, native results, signed upload and Apple's VALID / COMPLETE observation at `2026-11-08T03:51:37Z`. Match the letter to the exact submitted build and source commit; it does not assert physical-device acceptance, tester availability, TestFlight review or App Store review approval.

## Letter

Dear App Review Team,

Please review **Rhea RF Spanner**, an application for exploring acoustic levels, spectra, and an optional tone-phase experiment on an iPhone. We aim to make its operation understandable, inspectable, and controlled by the person using the device. We welcome technical questions and specific feedback about its behavior and presentation.

The ordinary LIVE entry point is **Listen**. After an explicit start and iOS microphone permission, it analyzes built-in microphone samples locally and displays RMS level, peak amplitude, and a spectrum Waterfall. It does not construct a tone generator or speaker-output source. Full audio covers the 0–24 kHz digital analysis band at the validated 48 kHz input rate; the narrower 18–22 kHz choice changes only the displayed range. These are digital full-scale measurements, not calibrated sound-pressure levels or a claim of uniform microphone sensitivity across the band. Listen has no carrier, phase, displacement, or phase-reference controls. Its recording audio session may interrupt other playback on the phone.

**Tone experiment** is a separate LIVE choice. It requires explicit agreement to speaker output in addition to the deliberate start and microphone permission. It plays a selected acoustic tone from 18 to 22 kHz in 500 Hz steps and fits that tone to microphone samples. Tone/residual quality is a model-fit statistic, not calibrated SNR or evidence of a reflected target. Any phase-derived displacement is a conditional model, not independently measured distance. The Field view is an abstract single-probe phase visualization. False-color palettes do not measure temperature.

The application name does not imply access to radio hardware in this build. This version does not acquire RF signals, access the baseband, scan wireless traffic, use camera/ARKit/LiDAR, receive external-device data, connect an iPhone mesh, or form a measured spatial radar image. **DEMO** uses a separately labelled synthetic source and makes no microphone, audio-session, or speaker request. Its Field graphic is a synthetic illustration, and its Waterfall is computed from synthetic samples.

The app starts idle in LIVE / Listen and does not request microphone permission on launch. The first permission grant returns to idle; the user starts again when ready. Selecting a mode, acquisition kind, display setting, or diagnostic action does not start microphone acquisition. The screen identifies the selected source and provides a stop control. Both LIVE choices have a 60-second limit. Leaving the active app, relevant audio interruptions, route/configuration changes, audio-service events, or detected input/processing stalls end the run. Opening Privacy & method stops acquisition. Returning to the app never restarts LIVE automatically. A Tone carrier change establishes a new acquisition epoch and reference while preserving the existing time budget. Unsupported input formats or routes produce an explanation.

The microphone may receive surrounding sounds, including speech. Raw samples are processed in volatile memory and are neither saved to an audio file nor uploaded. Listen retains only bounded display history; after Stop it is frozen and labelled as stopped data. **Listen is not saved to Replay.** Starting another run, changing modes or acquisition kind, or clearing Replay clears displayed history.

Replay contains only Tone experiment and DEMO captures: up to 2,048 derived telemetry records and bounded companion spectra in memory, retaining the original source labels. It cannot activate the microphone, has no file-export or persistent-library function, and does not survive process termination. The app does not transcribe speech, identify people, automatically upload samples or measurements, or run a background listening service. It has no app account system, advertising, analytics SDK, remote configuration, or downloaded executable code. Privacy and method information is available without microphone permission.

The Diagnostics screen reports observed input, processing, and rendering activity. A running audio session or requested display rate is not treated as evidence that samples or GPU frames arrived. Listen requests no tone fit, so it does not report a missing carrier as a failed measurement. Its source callbacks and transmitted sample counts remain zero. The current **App tone enabled** flag is separate from the retained audio configuration, and neither is a measurement of physical sound emission.

Users can inspect a JSON snapshot locally and use the explicit **Copy Diagnostic Dump** action for troubleshooting. The report includes app/build and generic OS/model information, acquisition kind, current transmission-gate state and retained configuration, audio route types/format/volume, relative intervals, counters, scalar input/analysis summaries, rendering status, error identifiers, and up to 128 operational events. Timing values include acquisition durations and event offsets since diagnostics initialization in the current app session. It excludes raw audio, spectrum arrays, images, location, route names/UIDs, account/network/device identifiers, and absolute system-uptime or host-clock values. The app performs no automatic diagnostic upload. The copy action uses a local-only clipboard item, excludes Handoff, and sets a one-hour expiry. A copy can outlive the app; material pasted elsewhere follows the destination's retention behavior.

The public repository contains the application, signal-processing implementation, build instructions, and review procedures. Processing includes digital input statistics, a windowed FFT, and the optional tone-phase estimator; the display distinguishes measured microphone data from synthetic demonstrations. The source snapshot corresponding to the submitted build is identified by its commit. Signing and administrative credentials are kept outside application source and are not embedded in the app.

For Tone experiment, we ask users to keep the phone away from their ears, use low system volume with the agreement of people nearby, and stop if uncomfortable. We do not promise that an 18–22 kHz tone is inaudible. The software transmit amplitude of 0.02 digital full scale is not a calibrated sound-pressure setting. Listen does not enable this tone output.

Our aim is responsible, open experimentation within the platform's rules. If a behavior, claim, or disclosure needs revision, please identify the concern so we can explain it, provide reproducible technical evidence, or revise the feature before broader distribution. We appreciate critical review and intend to respond constructively through App Store Connect.

Thank you for considering Rhea RF Spanner.

The Rhea RF Spanner development team

## Submission preparation

This letter does not replace the App Store Connect fields for a verified review contact, feedback email, support URL, privacy-policy URL, version/build number, or review notes. The public source is [timelabs-npo/Rhea-RF-Spanner](https://github.com/timelabs-npo/Rhea-RF-Spanner). Identify the exact submitted commit. No provisioned mailbox, submitted binary, or review approval is asserted here.

Use [AppReviewNotes.txt](AppReviewNotes.txt) and [ReviewTestPlan.md](ReviewTestPlan.md) for review navigation. Keep [AppleSubmission.md](AppleSubmission.md), version/build metadata, and validation records aligned with the exact build submitted.

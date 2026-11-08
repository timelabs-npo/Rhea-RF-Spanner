# Rhea RF Spanner privacy policy

**Document status:** Policy for the **0.2.1 (3) diagnostic candidate**; delivery and review status are recorded separately. A monitored contact address and a working public policy URL have not been verified by this document. Complete those release fields and match this text to the final binary before publishing it as the final policy or submitting the app.

The G1 passive-audio source change described here has not been built or tested on a physical iPhone on the WD implementation host. It assigns no new release number. Native validation and the phone owner's P4 device check remain pending; this text is not a delivery or hardware-success record.

## Microphone use

Rhea RF Spanner analyzes acoustic signals on the device. LIVE defaults to **Listen**, which analyzes built-in microphone input without generating a speaker tone. **Tone experiment** is a separate LIVE choice that emits a selected 18–22 kHz tone after your explicit agreement. The microphone can receive surrounding sounds, including speech. DEMO generates synthetic samples silently; Replay displays retained active Tone/DEMO results. Neither uses the microphone or speaker. Passive Listen results are not added to Replay.

Tap **Start listening** to request Listen microphone access; Tone experiment also requires agreement to speaker output. When microphone permission is first granted, the app returns to idle; start again deliberately. The active screen identifies the acquisition kind and provides Stop. Selecting Listen or Tone stops the current run and does not restart it. Listen uses a recording-only session that may suppress other playback on this phone; calls, alarms, and other nonmixable sessions may still interrupt it. Sessions have a 60-second limit. Leaving the active app, an audio interruption, an audio route change, or an audio-service reset ends the experiment. Opening Privacy & method also stops an active experiment. Returning to the app or closing that information view does not restart it.

## Processing, retention, and sharing

Application code processes microphone samples and displays measurements using volatile memory. Listen retains bounded display history, visible as stopped data after Stop and replaced by a new Listen run. It retains up to 2,048 derived active Tone/DEMO telemetry records and companion spectrum arrays in memory for Replay. Each Replay record preserves whether its source was LIVE or DEMO. Listen does not append passive observations to that tape. No raw audio recording is created. Neither tape nor display history is persisted across process termination. The app does not automatically upload microphone samples or measurements, transcribe speech, identify people, or create a user profile. It provides no persistent recording library. A separate, user-initiated diagnostic-copy feature is described below.

The app includes no account system, advertising, analytics SDK, tracking mechanism, or background recording mode. It does not automatically send microphone data, measurements, or diagnostic reports to the developer or a third-party service. It does not require a server connection to perform the experiment.

Memory-only processing is not a claim that the app controls every aspect of iOS memory management or guarantees forensic erasure. Raw samples and the Replay tape remain in app memory; a diagnostic report that you explicitly copy has the separate clipboard lifetime described below.

## Optional diagnostic report

The **Diagnostics & copy report** screen shows acquisition, processing, and rendering status. The app keeps up to **128 recent operational events** in memory, overwriting older events when the log is full. **Inspect JSON report** previews a snapshot locally without sending it anywhere.

The JSON includes app version/build, OS information, a generic device model, acquisition kind and whether transmission is enabled, audio route port types and format, system output volume, relative intervals and normalized sample indices, counters, aggregate input statistics, scalar analysis summaries, rendering status, and sanitized error domain/code information. Timing values include per-acquisition durations and retained event offsets measured since diagnostics initialization in the current app session. Listen normally has zero source callbacks and transmitted samples. Displayed processing and rendering rates are calculated from observed event counts and intervals; the report exports the counts and relative intervals. It contains no raw audio samples, spectrum arrays, camera images, location, route names or UIDs, account or network identifiers, persistent device identifiers, or absolute system-uptime/host-clock values.

**Copy Diagnostic Dump** writes this JSON to the system clipboard only when you choose that action. The copy is restricted to the local device, excluded from Handoff, and assigned an expiration one hour after copying. It can remain on the clipboard after the app's process closes. You decide whether and where to paste it. The app does not automatically upload the report. A copy pasted into another app or service follows that destination's handling and retention; the clipboard expiration does not remove copies made elsewhere.

## Your controls

You can stop an active experiment at any time, use DEMO without microphone permission, clear the in-memory Replay tape, or inspect diagnostics without copying a report. You can revoke microphone access in iOS Settings. Privacy and method information remain available without microphone permission. Because the app does not maintain an account, audio archive, or uploaded measurement record, it provides no account-deletion workflow.

Use microphone analysis with the agreement of people nearby. Before starting Tone experiment, keep the device away from ears, use a low system volume, and stop if the sound causes discomfort. The tone is not guaranteed to be inaudible. RMS and spectrum use digital dBFS; peak is linear full-scale amplitude. None is calibrated sound pressure, and display gain is not microphone gain. The software transmit amplitude setting is not a calibrated sound-pressure measurement.

## Apple distribution and feedback

Apple operates the App Store and TestFlight, including their delivery, diagnostic, and feedback features. Information you choose to provide through those services is handled under Apple's applicable policies and settings. Their operation is separate from the app's microphone-processing code. See [Apple's privacy policy](https://www.apple.com/legal/privacy/) and [TestFlight information](https://developer.apple.com/testflight/).

## Contact

The support and privacy contact for this application has not yet been provisioned and verified. A monitored address must be added here and to the release metadata before this policy is used for a distributed release.

## Implementation changes

Any later addition that saves measurements, expands diagnostic/export content, uses a network service, or changes microphone behavior requires a corresponding policy review. The policy and App Store privacy declarations must describe the actual distributed build.

## Maintainer note: privacy declarations

Apple defines collection for its App Store privacy label in terms of transmitting data off the device with developer or partner access beyond servicing a request in real time. The current app's local processing can therefore support **Data Not Collected** only while the distributed app and its integrated components continue to match this policy. This is an implementation assessment, not an Apple approval. See [App privacy details](https://developer.apple.com/app-store/app-privacy-details/).

The local Copy action does not implement a developer upload endpoint. If a later support or upload flow collects and retains reports, reassess the relevant diagnostic-data declarations; being optional or user-initiated is not by itself an exemption from Apple's disclosure criteria.

The declared System Boot Time reason **35F9.1** permits measuring intervals between in-app events and sending those elapsed intervals off the device. The diagnostic report includes relative intervals and counters, not the underlying absolute uptime or host-clock readings. See [Apple's approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype). Clipboard locality and expiration use Apple's [pasteboard privacy options](https://developer.apple.com/documentation/uikit/uipasteboard/optionskey).

`PrivacyInfo.xcprivacy`, App Store Connect privacy answers, microphone permission text, and this policy serve different purposes. A valid manifest does not replace a clear permission message or the published policy.

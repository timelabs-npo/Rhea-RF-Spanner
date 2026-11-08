# Review and physical-device test plan

This is the test protocol for **0.2.2 (4), G1 passive audio**, including the
applicable G0 diagnostic regressions. It is not a record that every step below
passed or that the build is available to testers. Compilation, Simulator
fixtures and physical acoustic measurements are separate forms of evidence.
Mark a test as passed only after observing it in the specific build evaluated.

Source `222caea29b040063658cad2288b2e02726d02c73` passed native builds, core and
hosted suites, and four inspected idle/DEMO captures on Mac CI. Exact results
and TestFlight stages are in [PASSIVE_AUDIO_VALIDATION.md](PASSIVE_AUDIO_VALIDATION.md).
Signed upload succeeded; Apple confirmed build VALID / upload COMPLETE at
`2026-11-08T03:51:37Z`. Tester access remains blocked pending explicit
authorization; physical P4 is
unobserved. See [PASSIVE_AUDIO.md](PASSIVE_AUDIO.md) for the measurement contract.

## App Review navigation

1. Open **Rhea RF Spanner** normally. The observatory starts idle with the microphone off. It should not request microphone access on launch.
2. Open **Privacy & method**. Read the acoustic experiment, privacy, model limitations, and sound-use information without granting microphone permission.
3. Start in **LIVE · LISTEN** on a physical iPhone with built-in microphone input. Tap **Start listening**; granting first microphone permission returns to idle, so start again deliberately. Inspect RMS in dBFS, peak amplitude in full-scale units, and **Full audio · 0–24 kHz** Waterfall without a generated tone. No phase, reference, displacement, Field, or carrier controls should appear. The narrow **18–22 kHz** display range does not start output. The recording-only session may suppress other playback on this phone.
4. Stop and inspect the **STOPPED DATA** history label. A new Listen run starts fresh history. Selecting Listen versus **Tone experiment** must end a running acquisition without restarting it. For Tone, use the built-in speaker/microphone, choose low system volume, keep the device away from ears, obtain nearby people's agreement, then explicitly agree and start. Its selected 18–22 kHz tone is not guaranteed inaudible; its phase/reference controls belong to that mode.
5. Select **DEMO** and Record. Inspect the synthetic Field and Waterfall without microphone permission or speaker output. Compare **Full audio · 0–24 kHz** and **Carrier · 18–22 kHz**. Stop and select Replay; retained frames must remain labelled DEMO or active LIVE Tone. Passive Listen does not append to Replay. A synthetic fixture or Simulator screenshot must never be labelled live microphone data.
6. Open the menu's **Diagnostics & copy report**. Inspect acquisition, processing, and rendering activity. **Inspect JSON report** previews a snapshot locally; **Copy Diagnostic Dump** explicitly copies it to the local clipboard with a one-hour expiration. No automatic upload occurs.
7. Stop. A new acquisition requires a deliberate start. Change modes or inspect Replay; no microphone/tone may run in Replay. Listen has no requested tone result. In Tone, unavailable phase alone does not establish silence: compare actual input statistics and Full audio Waterfall.

No app account, login credentials, external sensor, accessory, or server is required. Simulator supports DEMO, Replay, and interface inspection; it cannot establish the behavior of an iPhone's acoustic hardware.

## Functional and privacy tests

Record the source commit, app version/build, device model, iOS version, installed build origin, date, and observations for each run. Record failures as failures; do not infer success from source inspection.

The following G1 checks are required in addition to the applicable regression
rows below. Capture software-fixture and physical results separately.

| ID | Action | Expected behavior | Evidence to record |
| --- | --- | --- | --- |
| G1-01 | Inspect/test the Listen session and graph decision, then start on a physical iPhone. | `.record` / `.measurement`; checked built-in 48 kHz input without requiring output; no tone context/source node, oscillator, speaker override, or mic-to-output connection. | Focused graph test result; observed device category, input format, acquisition kind, `transmitEnabled = false`, zero source callbacks/transmitted samples. |
| G1-02 | Run a passive digital 0.25-peak bin-40 sine fixture. | 937.5 Hz spectrum near −12.04 dBFS and RMS near −15.05 dBFS; no tone result, fabricated phase failure, or `SpatioTemporalSlice`. | Fixture identity, declared tolerances, numerical results, actual test output. Label it synthetic. |
| G1-03 | Exercise variable capture blocks, full-ring drops, invalid timestamps, nonfinite samples, and recovery in focused fixtures. | Captured supported samples advance independently of rendering, including dropped offers; levels/timing/spectrum states stay distinct; later valid spectrum retains the capture gap. | Counters, normalized indices, missing-spectrum cases, recovered timestamps, and actual test output. |
| G1-04 | Start/stop Listen, select Tone during Listen and Listen during Tone, and complete a permission response after changing intent. | Explicit start only; kind immutable per run; selection stops and never restarts; stale permission completion does not start either graph. Tone retains its agreement. | UI/model results and device lifecycle observations. |
| G1-05 | Run Listen with a quiet baseline, speech, and two independent known audible frequencies. | Levels and spectra respond without an ultrasonic carrier fit. Peaks track the known sources within a tolerance declared before testing. | Actual route/rate, conditions, source accuracy, frequency tolerance accounting for 23.4375 Hz bin spacing, observations, and diagnostic report. Speech is not a calibrated reference. |
| G1-06 | Change gain, palette, range, and persistence; stop; start a new Listen run. | Display changes without altering samples, RMS/peak, kind, or rate. Stopped bounded Waterfall is labelled STOPPED DATA; next run starts fresh history. | Underlying fixture values, screenshots, model/render checks. |
| G1-07 | Inspect Replay after Listen; inspect/copy Diagnostics while idle and after a failure. | Passive frames do not append to v1 Replay; no sensor starts on inspection/copy. Kind/transmission state and failure evidence remain; report contains only permitted aggregates. | Replay count/order, audio state, parsed report field inspection, retained error/stop reason. |
| G1-08 | Exercise input/processing stall, 60-second limit, inactivity, route change, and interruption. | Stop with retained reason and no automatic restart, even without output progress; fresh explicit start is required. | Fixture/device method, actual intervals, reasons, untested scenarios. |

G1 graph decisions and zero transmit counters support a software no-transmitter
claim. To claim no added near-ultrasonic physical emission, use an independent
instrument with sufficient response and a before/during comparison. Human
hearing and this app's own microphone cannot certify that claim. Record the
scope of any such physical check.

| ID | Action | Expected behavior | Evidence to record |
| --- | --- | --- | --- |
| UI-01 | Launch with microphone permission undetermined. | Idle Listen screen; no microphone request or tone before explicit Start. | Screen recording or observations; permission state. |
| UI-02 | Select Tone experiment and attempt to start without the agreement enabled. | Tone experiment does not start. Listen does not require tone agreement. | Control state or response for both kinds. |
| UI-03 | Read Privacy & method while permission is denied. | Explanations remain accessible. | Navigation observations. |
| PERM-01 | Tap Start listening, or agree and Start Tone; deny the iOS permission request. | No tone/analysis starts; denial is explained; the app remains usable for information. | Selected kind, error text and microphone access observations. |
| PERM-02 | Grant permission after a deliberate Start, then tap Start again. | Permission grant returns to idle; the second deliberate Start begins the session. | Permission dialog, idle message, active banner, session state. |
| PERM-03 | Interrupt the app during the first permission request. | Returning or completing a stale permission response does not unexpectedly start a session. | Lifecycle sequence and result. |
| RUN-01 | Start and stop a session. | Active banner is accurate; Stop halts microphone analysis and tone generation. | App state, audio engine observations, microphone access interval. |
| RUN-02 | Allow the configured duration to elapse. | Session ends at its 60-second limit and remains idle. | Measured elapsed time, tolerance, app state. |
| RUN-03 | In Tone experiment, tap Reset phase reference while active. | A new phase baseline is established without pretending to measure absolute range. Listen exposes no reset control. | Before/after phase and displacement labels; Listen control inspection. |
| LIFE-01 | Lock the phone or move the app out of the active foreground. | Experiment stops. Returning does not restart it. | Audio and app state before/after. |
| LIFE-02 | Cause an audio interruption. | Experiment stops; it requires an explicit new Start after the interruption ends. | Interruption sequence and app state. |
| LIFE-03 | Connect or disconnect an audio accessory during a session. | Experiment stops; it does not silently switch to the accessory. | Route before/after and error/state. |
| LIFE-04 | Exercise audio-services reset handling in a development test. | Active session is invalidated and no automatic restart occurs. | Test method and state transitions. |
| LIFE-05 | Open Privacy & method during a session. | The experiment stops before the information sheet opens. Closing the sheet does not restart it. | App and microphone state before/after navigation. |
| ROUTE-01 | Try to start with an unsupported route or effective sample rate. | Clear error; no crash, forced assertion, or knowingly invalid measurement. | Effective input/output formats, route, error. |
| ROUTE-02 | Cause a route or audio interruption during startup. | The audio gate prevents tone/analysis on an unvalidated running route; a cancelled startup returns an explanation. | Timing of the change, routes, and observed audio/app state. |
| PRIV-01 | Inspect app microphone activity with iOS App Privacy Report. | Access corresponds to deliberate active experiments; no app-created background access interval. | Exported or observed access intervals, build identity. |
| PRIV-02 | Observe the app's network activity while navigating, running an experiment, and previewing/copying diagnostics. | Application code does not automatically upload audio, measurements, or diagnostics. Copying places text on the local clipboard. | Observation method and coverage; distinguish Apple's system services and any destination the tester later pastes into. |
| PRIV-03 | Inspect the app container and source data paths after a session. | No app-created audio recording, Replay file, or persistent diagnostic file is retained. An explicitly copied diagnostic report has a separate clipboard lifetime. | Inspection method, relevant paths, and whether Copy was used. |
| RES-01 | Repeat start/stop, reset, and interruption sequences. | No accumulating audio nodes, continuing callbacks from old sessions, or app crash. | Iteration count and observed behavior. |
| QUAL-01 | In Tone experiment, create a weak, noisy, or discontinuous signal. | Quality/continuity failures are represented; an invalid phase interval does not become an asserted reliable displacement. | Signal conditions, quality state, transport counters. |
| QUAL-02 | Inject a missing or discontinuous Tone playback sample clock in a development test. | Output is silenced and the session stops with a playback-timing explanation. | Injection method and resulting state. |
| DEMO-01 | Start DEMO with microphone permission undetermined or denied. | Synthetic samples produce phase/spectrum; no permission request, microphone session, or tone output. | Source label, permission and audio-session observations. |
| DEMO-02 | Change display gain/persistence/palette during DEMO. | Display changes; underlying sample parameters, phase and stored records are unaffected. | Controlled repeat with same seed and sample clock. |
| FREQ-01 | Change between all nine carriers during Tone/DEMO acquisition. | Old run ends; new carrier and reference epoch appear; original 60 s budget remains. Listen exposes no carrier selector. | Carrier labels, epoch IDs, elapsed time, captured audio frequency where applicable. |
| REPLAY-01 | Record, stop, scrub, and play mixed active LIVE Tone/DEMO sessions. | Original source/carrier/epoch are retained; no acquisition runs during replay. Passive Listen is absent from the tape. | Record order, displayed source and hardware state. |
| REPLAY-02 | Fill beyond 2,048 records and clear the tape. | Oldest records overwrite in order; clear releases retained records and spectra. | Counts, first/last timestamps, clear state. |
| VIEW-01 | Run Waterfall with a known synthetic tone and a missing frame. | Actual frequency bins are shown; missing time remains a marked gap. | Screenshot, known tone and timestamps. |
| VIEW-02 | In a development fixture containing an audible-band tone and a selected carrier, switch between Full audio and Carrier Waterfall. | Full audio uses the 0–24 kHz axis; Carrier uses 18–22 kHz. Display range changes neither samples, carrier selection, nor fitted phase. | Fixture identity, peak-bin locations, screenshots, and unchanged acquisition values. |
| DIAG-01 | Open Diagnostics while idle, preview JSON, then dismiss it. | App identity/state are available without starting audio. Preview does not copy or upload a report. | Permission/audio state, report contents, and clipboard state before/after. |
| DIAG-02 | Run DEMO and observe Diagnostics over an interval. | Synthetic and processed-frame counters advance; rendering reports observed submissions/completions. Rates are calculated from observed counts and elapsed intervals rather than a fixed nominal FPS label. No microphone session is created. | Two or more observations with interval/count changes, renderer status, and hardware state. |
| DIAG-03 | Start Listen and Tone separately on a supported physical device; inspect Diagnostics. | Actual audio format and callback/buffer counts distinguish no input, silent input, processing activity, and tone fit when requested. Listen reports tone analysis not requested and zero transmission. | Device/OS/route, kind/transmission state, actual format, input statistics, tone-analysis availability, stop reason, and Full audio view. |
| DIAG-04 | Use Copy Diagnostic Dump and parse the pasted text as JSON. | Finite scalar summaries, counters, relative intervals, and at most 128 events; no raw samples, spectrum arrays, images, location, route names/UIDs, account/network/device identifiers, absolute uptime, or raw host-clock values. Computed HUD rates are represented by their source counts/intervals in JSON. | Sanitized report, schema/version, field inspection, and JSON parse result. |
| DIAG-05 | Inspect the Copy operation's pasteboard options and its lifetime on a test device. | Copy is explicit, local-only, excluded from Handoff, and assigned an expiry one hour after copying. Closing the app need not remove the clipboard copy; expiration does not erase copies pasted elsewhere. | Copy time, observed options/lifetime, and test method. |
| DIAG-06 | Exercise more than 128 diagnostic events and an injected audio error in a development test. | Log stays bounded, reports overwritten-event count, and error export retains sanitized domain/code without private error userInfo or localized paths. | Event counts, error fixture, resulting JSON. |
| DIAG-07 | Produce equivalent diagnostic fixtures with different absolute monotonic-clock origins. | Exported relative intervals are unchanged; neither absolute origin nor raw ticks appear in the report. Missing intervals remain unavailable instead of fabricated timing. | Fixture origins, interval expectations, and serialized-field comparison. |
| A11Y-01 | Enable large text, VoiceOver, Reduce Motion and Reduce Transparency. | Controls stay reachable and labelled; graphics respect motion preference; opaque material fallback stays legible. | Device configuration and observed navigation. |

The iOS microphone indicator can also communicate recent microphone use. Treat it as supporting evidence, together with app state and recorded access intervals, rather than requiring a particular indicator disappearance time.

Apple documents App Privacy Report inspection in [Inspecting app activity data](https://developer.apple.com/documentation/network/inspecting-app-activity-data). Actual iPhone testing is necessary for this feature; see Apple's [Test your app on compatible devices](https://developer.apple.com/help/app-review/before-submitting-for-review/test-compatible-devices).

## Signal-processing evidence

Synthetic tests can verify levels/spectrum, absent passive tone results, known active phase changes, frame-boundary continuity, loss-of-signal behavior, and transport integrity. They do not establish the phone's acoustic input/output, effective measurement geometry, or ranging accuracy. RMS and amplitude spectrum use digital dBFS; peak is linear full-scale amplitude. These do not establish dB SPL, microphone calibration, or a noise-density measurement.

For physical measurements, record at least:

- The hardware route, actual sample rate, app signal amplitude setting, system volume, and device orientation.
- The reference instrument and its limits if measuring emitted frequency or sound pressure. A digital amplitude of 0.02 full scale is not a calibrated acoustic level.
- Reflector position, movement, and surrounding geometry when interpreting a phase response.
- The difference between source-code expectations and observed results, including failed or inconclusive experiments.

The phase-to-displacement conversion assumes a specified monostatic, two-way acoustic path. Direct speaker-to-microphone coupling and multiple reflections can dominate the measurement on a phone. A change in the displayed model value alone does not verify motion of a particular object. Do not report absolute distance, a physical radar image, guaranteed coherence, zero jitter, or calibrated accuracy without evidence for that separate claim.

## Minimal results record

```text
Source commit:
App version / build:
Device model:
iOS version:
Build origin:
Date and tester:
Test ID:
Steps actually performed:
Observed result:
Pass / fail / not run / inconclusive:
Evidence location:
Limitations or follow-up:
```

Store supporting evidence with the release record. This plan intentionally contains no pre-filled pass results.

For a runtime failure, attach the JSON obtained from **Diagnostics & copy report**, the mode and steps used, and the visible symptom. The report contains technical summaries only; inspect it before choosing a recipient. A known source commit still belongs in the test record because version/build metadata alone does not identify every development build. Keep any personal details added by the tester out of public evidence unless they explicitly choose to publish them.

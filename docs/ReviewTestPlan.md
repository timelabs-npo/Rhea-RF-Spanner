# Review and physical-device test plan

This is a protocol, **not a record of successful tests**. Compilation, simulator execution, and physical acoustic measurements are separate forms of evidence. Mark a test as passed only after observing it in the specific build being evaluated.

## App Review navigation

1. Open **Rhea RF Spanner**. The initial screen says **Acoustic phase experiment** and **IDLE — MICROPHONE OFF**. The app should not request microphone access on launch.
2. Open **Privacy & method**. Read the acoustic experiment, privacy, model limitations, and sound-use information without granting microphone permission.
3. On a physical iPhone using its built-in speaker and microphone, choose a low system volume, keep the device away from ears, and obtain the agreement of people nearby. A 20 kHz tone is not guaranteed to be inaudible.
4. Enable **I agree to a 20 kHz speaker tone and live microphone analysis.** Tap **Start experiment**. On first use, respond to the iOS microphone permission request. Granting permission returns to idle with an explanation; tap **Start experiment** again to begin.
5. When the session starts, observe **MICROPHONE + 20 kHz TONE ACTIVE**, the remaining-seconds counter, and the phase/quality displays. **Abstract phase visualization** describes a display effect; it is not a spatial map.
6. Tap **Stop experiment**. The app returns to its idle state. It should require a new deliberate start for another experiment.

No app account, login credentials, external sensor, accessory, or server is required. An iOS simulator cannot establish the behavior of an iPhone's acoustic hardware. There is no simulated-signal demonstration mode in this version.

## Functional and privacy tests

Record the source commit, app version/build, device model, iOS version, installed build origin, date, and observations for each run. Record failures as failures; do not infer success from source inspection.

| ID | Action | Expected behavior | Evidence to record |
| --- | --- | --- | --- |
| UI-01 | Launch with microphone permission undetermined. | Idle screen; no microphone request or tone before agreement and Start. | Screen recording or observations; permission state. |
| UI-02 | Attempt to start without the agreement enabled. | Experiment does not start. | Control state or response. |
| UI-03 | Read Privacy & method while permission is denied. | Explanations remain accessible. | Navigation observations. |
| PERM-01 | Agree and tap Start; deny the iOS permission request. | No tone/analysis starts; denial is explained; the app remains usable for information. | Error text and microphone access observations. |
| PERM-02 | Grant permission after a deliberate Start, then tap Start again. | Permission grant returns to idle; the second deliberate Start begins the session. | Permission dialog, idle message, active banner, session state. |
| PERM-03 | Interrupt the app during the first permission request. | Returning or completing a stale permission response does not unexpectedly start a session. | Lifecycle sequence and result. |
| RUN-01 | Start and stop a session. | Active banner is accurate; Stop halts microphone analysis and tone generation. | App state, audio engine observations, microphone access interval. |
| RUN-02 | Allow the configured duration to elapse. | Session ends at its 60-second limit and remains idle. | Measured elapsed time, tolerance, app state. |
| RUN-03 | Tap Reset phase reference while active. | A new phase baseline is established without pretending to measure absolute range. | Before/after phase and displacement labels. |
| LIFE-01 | Lock the phone or move the app out of the active foreground. | Experiment stops. Returning does not restart it. | Audio and app state before/after. |
| LIFE-02 | Cause an audio interruption. | Experiment stops; it requires an explicit new Start after the interruption ends. | Interruption sequence and app state. |
| LIFE-03 | Connect or disconnect an audio accessory during a session. | Experiment stops; it does not silently switch to the accessory. | Route before/after and error/state. |
| LIFE-04 | Exercise audio-services reset handling in a development test. | Active session is invalidated and no automatic restart occurs. | Test method and state transitions. |
| LIFE-05 | Open Privacy & method during a session. | The experiment stops before the information sheet opens. Closing the sheet does not restart it. | App and microphone state before/after navigation. |
| ROUTE-01 | Try to start with an unsupported route or effective sample rate. | Clear error; no crash, forced assertion, or knowingly invalid measurement. | Effective input/output formats, route, error. |
| ROUTE-02 | Cause a route or audio interruption during startup. | The audio gate prevents tone/analysis on an unvalidated running route; a cancelled startup returns an explanation. | Timing of the change, routes, and observed audio/app state. |
| PRIV-01 | Inspect app microphone activity with iOS App Privacy Report. | Access corresponds to deliberate active experiments; no app-created background access interval. | Exported or observed access intervals, build identity. |
| PRIV-02 | Observe the app's network activity while navigating and running an experiment. | Application code does not upload audio, measurements, or analytics. | Observation method and coverage; distinguish Apple's system services. |
| PRIV-03 | Inspect the app container and source data paths after a session. | No app-created audio recording or telemetry export is retained. | Inspection method and relevant paths. |
| RES-01 | Repeat start/stop, reset, and interruption sequences. | No accumulating audio nodes, continuing callbacks from old sessions, or app crash. | Iteration count and observed behavior. |
| QUAL-01 | Create a weak, noisy, or discontinuous signal. | Quality/continuity failures are represented; an invalid phase interval does not become an asserted reliable displacement. | Signal conditions, quality state, transport counters. |
| QUAL-02 | Inject a missing or discontinuous playback sample clock in a development test. | Output is silenced and the session stops with a playback-timing explanation. | Injection method and resulting state. |

The iOS microphone indicator can also communicate recent microphone use. Treat it as supporting evidence, together with app state and recorded access intervals, rather than requiring a particular indicator disappearance time.

Apple documents App Privacy Report inspection in [Inspecting app activity data](https://developer.apple.com/documentation/network/inspecting-app-activity-data). Actual iPhone testing is necessary for this feature; see Apple's [Test your app on compatible devices](https://developer.apple.com/help/app-review/before-submitting-for-review/test-compatible-devices).

## Signal-processing evidence

Synthetic tests can verify arithmetic, known phase changes, frame-boundary continuity, loss-of-signal behavior, and transport integrity. They do not establish the phone's acoustic output, effective measurement geometry, or ranging accuracy.

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

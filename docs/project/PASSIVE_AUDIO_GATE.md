# G1: useful passive audio

**Status:** follow-up implementation plan, inspected against the G0 diagnostic
working tree on 2026-11-08. This document does not claim that passive capture is
implemented, built, delivered, or verified on an iPhone. The current diagnostic
candidate remains a separate G0 deliverable. See [ROADMAP.md](ROADMAP.md) and
[NEXT_SESSION.md](NEXT_SESSION.md) for release evidence and ownership.

## Outcome and scope

Give an engineer a quick answer to: **“Is the microphone receiving sound, what
frequencies are present, and how does the digital level change when I alter the
sound source?”** The first passive release should provide a responsive input
meter and timestamped Waterfall without generating a speaker tone. A useful
initial exercise is comparing a fan or acoustic source before and after a
controlled change, with the phone in the same position and orientation.

Keep this gate to built-in microphone input, the existing 48 kHz input contract,
2,048-sample analysis windows, the existing bounded display history, explicit
start/stop, and the existing 60-second limit. Camera, LiDAR, external microphones,
RF probes, source classification, sound-pressure calibration, and continuous
background recording belong to later gates. No release number or delivery date
is assigned here.

## What the current code actually provides

| Existing component | Reusable behavior | Change needed for passive listening |
| --- | --- | --- |
| [AudioTransceiver.swift](../../App/Sources/AudioTransceiver.swift), `AudioTransceiver.start()` | Main-actor lifecycle, microphone permission handled by the model, input tap, route/format diagnostics, cancellation and cleanup | LIVE always selects `.playAndRecord`, overrides output to the speaker, creates a `ToneRenderContext` and `AVAudioSourceNode`, and connects output. Passive needs a separate input-only branch. |
| `checkedFormats()` in the same file | Checks the actual activated route and format before allowing samples | It currently requires both built-in microphone and built-in speaker, with input/output/session rates at 48 kHz. Passive must validate the input contract without requiring an output device or output format. |
| `CaptureContext` | One ring producer; channel 0 of noninterleaved Float32 input; hardware sample time normalized to a run-relative index; gaps and unavailable timestamps retained as evidence | Preserve this contract and publish capture progress independently of tone generation. Variable callback sizes must remain supported. |
| [ExperimentModel.swift](../../App/Sources/ExperimentModel.swift) | Explicit start, permission flow, independent wall deadline, no automatic restart, diagnostics, ordered worker completion | LIVE consent and status text assume a transmitted tone. Elapsed time and retune budgeting currently read `control.renderedSamples`, updated by the tone source or simulator, not by microphone capture. |
| [PhaseSensingEngine.swift](../../Sources/RheaRFCore/PhaseSensingEngine.swift) | Input statistics and spectrum are calculated before the tone-validity gate | The callback/result type still centers on a tone estimate. Passive availability must not require a tone fit or create a displacement value. |
| [SpectrumAnalyzer.swift](../../Sources/RheaRFCore/SpectrumAnalyzer.swift) | One-sided Hann-windowed amplitude spectrum, finite silence handling, explicit timestamps | Reuse its normalization and existing tests. No FFT replacement is needed for this gate. |
| [MetalPhaseRenderer.swift](../../App/Sources/MetalPhaseRenderer.swift) | Waterfall history, missing-interval hatching, full-band display, measured rendering diagnostics | Decouple passive frame identity from a `SpatioTemporalSlice`; keep phase-field presentation out of passive mode. |
| [ReplayTape.swift](../../Sources/RheaRFCore/ReplayTape.swift) | Bounded active/DEMO telemetry with optional spectrum companions | Its v1 records require a valid acoustic carrier configuration. Do not encode passive observations using a fictitious carrier or silently change the wire contract. |

## Smallest product change

Keep the existing `LIVE / DEMO / REPLAY` provenance choices. Within LIVE, add an
immutable acquisition choice for each run: **Listen** or **Tone experiment**.
Listen becomes the ordinary audio-analysis entry point; Tone experiment retains
the existing explicit agreement to speaker output. Selecting a different kind
ends the current run and requires another start action. A change of display
range, gain, palette, or persistence never changes acquisition kind.

For Listen:

- Show **“LIVE · LISTEN”**, **“Microphone analysis · no generated tone”**, and
  **Start listening / Stop**. Explain that analysis remains local and that only
  the optional diagnostic report can be copied.
- Use the existing microphone permission flow. Granting permission returns to
  idle; the user starts listening explicitly. No tone-specific consent text
  should describe a passive run.
- Default to Waterfall, **Full audio · 0–24 kHz**, and an RMS/peak input readout.
  Keep the current display controls. Label the narrow range **18–22 kHz** in this
  context, so “carrier” does not imply that a tone is being transmitted.
- Hide carrier tuning, reference reset, phase-derived displacement, and the
  abstract phase field. Their absence is an acquisition choice, not an input
  failure. Active-tone controls return only in Tone experiment.
- Keep the most recent bounded Waterfall visible after stopping and identify it
  as stopped data. A new passive run starts a new history and clock origin.

The first slice does not add passive REPLAY. Preserve the existing tape for
active/DEMO captures, do not append passive frames to it, and state what REPLAY
contains. Bounded live display history is not a new recording format. A later
passive replay proposal must carry its own acquisition metadata rather than
assigning passive audio an arbitrary carrier frequency.

## Audio session and graph

Pass a small immutable acquisition-kind value into `AudioTransceiver` and the
processing session. Keep the existing active-tone branch behavior. Implement the
Listen branch with `AVAudioSession.Category.record` and `.measurement`, request
the preferred rate/duration before activation, select the built-in microphone,
install its tap, and start the input engine. Create no `ToneRenderContext`,
oscillator, source node, speaker override, or microphone-to-output connection.
Muting an otherwise active transmitter is not the acceptance criterion.

Apple documents `.record` as recording while suppressing playback; that means
other playback on this phone may be interrupted during listening. Make this
behavior clear in the method text. It does not prevent calls, alarms, or other
nonmixable sessions from interrupting acquisition. `.measurement` reduces
system-supplied processing; it does not establish microphone calibration or a
flat frequency response. See Apple's [record category][apple-record] and
[measurement mode][apple-measurement].

For the passive branch, validate the enabled input node, actual input/session
rate, nonzero input channels, noninterleaved Float32 samples, and the selected
built-in input. An absent or different output route is not a passive-format
error. Record output-port information only as context. Apple supports input
through an input-node recording tap and requires checking whether input hardware
is enabled; see [AVAudioEngine.inputNode][apple-input].

The initial supported rate remains **48,000 Hz**. Preferences are requests, so
check the activated session and tap format instead of relabeling another rate as
48 kHz. Reject an unsupported rate with the observed value and a useful report.
Do not add resampling or generalized rate negotiation in this change. Apple's
[sample-rate API][apple-rate] and [session-preferences guidance][apple-preferences]
describe this distinction.

Retain stop-on-inactive, interruption, route change, media-service change,
configuration change, input stall, processing stall, explicit Stop, and deadline
behavior. No event automatically restarts listening. Stop/cleanup must work when
no output node was attached. A passive run reports `transmitEnabled = false` and
zero source callbacks/transmitted samples; those zeros must not trigger a stall
alarm.

## Capture clock and processing contract

### Progress must describe the producer

Introduce separately named capture and transmission progress. The input tap
publishes the number of supported samples offered to the ring, including samples
dropped because the ring was full; it must not derive progress from successful
enqueue count alone. The simulator retains its own generated-sample count. The
tone source retains its rendered-sample count as transmission evidence.

For Listen, use captured sample count for acquired duration and its sample cap.
Retain the independent monotonic 60-second wall deadline and the existing stall
watchdog. A stalled input must not leave the session running because a sample
counter stopped advancing. Do not copy capture progress into a field named
`renderedSamples`, and do not rewrite the current active retune budget as part of
this passive-only change.

Keep these quantities distinct: supported samples observed, samples enqueued,
samples dropped, complete analysis windows produced, normalized capture index,
and elapsed in-app time. The first sample index identifies where an analysis
window begins; it is not the time when the main actor received the result.

### Broad audio and tone fitting have separate availability

Use a small common audio-analysis result containing the window's sample index,
capture/timing status, aggregate input statistics, optional spectrum, and an
**optional** tone result. Read the SPSC ring once on its existing serial consumer.
Reuse the existing window statistics and spectrum analysis; keep the active
tone estimator's mathematics unchanged. For Listen, tone analysis is **not
requested**, so there is no phase, fit-quality requirement, calibration epoch,
or displacement estimate to display. Do not fabricate a `.lowSignal` tone frame
merely to satisfy the current callback signature.

Adapt model/diagnostic/renderer inputs to carry the passive frame's identity
without creating a carrier-bearing `SpatioTemporalSlice`. An explicit
acquisition kind distinguishes “tone analysis not requested” from “tone requested
but insufficient signal.” Tone failure must never suppress a valid spectrum or
level measurement in the active branch either.

Keep current conservative timing behavior for G1: finite input statistics may
exist when hardware timestamps are unavailable, but a spectrum is absent for an
analysis window with invalid timestamps or an internal capture gap. A complete,
internally contiguous window after a gap can produce a spectrum; its position
must preserve the missing interval. Never fill missing time with zero-valued
audio or stretch an old row to appear current. If physical diagnostics show
supported samples but consistently invalid timestamps, obtain that trace before
deciding on a separate, explicitly untimed spectral-preview policy.

## Measurement and display semantics

- **Level:** RMS is `20 log10(rms)` relative to digital full-scale amplitude 1.
  Peak is `max(abs(sample))`, optionally converted using the same amplitude
  reference. A unit-peak sine therefore has RMS about **−3.01 dBFS**, while its
  bin-centered spectral amplitude is **0 dBFS** under the existing FFT
  normalization. Label the two readouts so this difference is understandable.
- **Spectrum:** retain the current Hann coherent-gain-corrected amplitude dBFS.
  It is neither dB SPL nor a noise power density. At 48 kHz, 2,048 samples span
  approximately **42.67 ms**, and FFT bin spacing is **23.4375 Hz**. Bin spacing
  is not a guarantee that two nearby tones are resolved. No extra resolution is
  created by display interpolation or zero padding.
- **Silence and invalid data:** mathematical zero has no finite logarithm. Show
  “silence” or a clearly identified display floor; keep zero input, nonfinite
  input, missing callbacks, and missing timestamps distinct. A near-full-scale
  sample is a digital overload indicator, not proof that the analog microphone
  did or did not saturate.
- **Waterfall:** retain actual frequency coordinates, dBFS legend, capture-time
  gaps, and the renderer's strongest-bin policy when several FFT bins occupy
  one display column. The existing 0–24 kHz view is the digital analysis band;
  it is not a claim of calibrated sensitivity across that whole band.
- **Controls:** display gain is a visualization offset, not microphone gain.
  `AVAudioSession.outputVolume` is not input gain. Do not let either value alter
  stored statistics, FFT samples, or physical-unit labels. No spectral averaging
  is added in the first slice; if introduced later, disclose its time constant
  and test its behavior.

## Bounded implementation slices and targeted checks

| Slice | Change | Evidence required before integrating |
| --- | --- | --- |
| **P1 — Acquisition intent and lifecycle** | Add Listen/Tone choice, passive session/graph branch, capture progress, mode-aware diagnostics and messages | Focused lifecycle test or recording audio-session/graph test double shows Listen never constructs/connects a tone source or overrides the speaker. Permission, stop, failure cleanup, and active branch behavior remain intact. |
| **P2 — Passive result path** | Common audio-analysis result, optional tone result, passive spectrum/level delivery, timestamps and gaps retained | A deterministic audible tone/noise fixture produces level/spectrum with no tone result. Variable callback sizes, ring drops, invalid timestamps, nonfinite samples, and recovery preserve their actual states. Existing active phase fixtures remain passing. |
| **P3 — Useful view** | Listen start/stop wording, Waterfall/input readout, passive controls, stopped-state presentation, explicit Replay scope | Targeted UI/rendering checks show current passive data reaches the GPU, correct units and source labels, absent phase controls, no passive-to-v1 Replay encoding, and no sensor start on inspection/copy. |
| **P4 — Device gate** | Run the physical procedure below on the candidate built from the reviewed source | Save the tested build/commit, actual diagnostic report, observations and limits. A CI build or DEMO screenshot alone cannot close this gate. |

Reuse existing spectrum tests for bin-centered amplitude, DC/Nyquist endpoints,
silence, nonfinite recovery, and timing gaps. Add only the integration cases the
new branch creates: no transmission, progress without rendering, optional tone
semantics, passive routing, and end-to-end spectrum presentation.

A useful synthetic fixture is a 0.25-peak sine at bin 40: **937.5 Hz** at this
sample rate/window. Its bin-centered spectral amplitude is approximately
**−12.04 dBFS**, and its RMS level approximately **−15.05 dBFS**. These are
digital-fixture expectations, not predictions of the level a physical speaker
will create at the iPhone microphone. Changing display gain/palette must leave
these underlying values unchanged.

## Physical-device acceptance

Record the source commit, installed version/build, iPhone model, iOS version,
observed input route/rate, and test conditions alongside the result. Reuse the
explicit user-controlled diagnostic copy; do not add automatic data upload or
raw audio recording for this gate.

1. **Permission and startup:** begin idle, choose Listen, grant microphone access
   if needed, then explicitly start. Confirm the indicator/label, observed input
   callbacks, captured samples, complete analysis windows and GPU completions
   advance. Source callbacks and transmitted samples remain zero. Opening
   Diagnostics and its JSON preview must not create a new session.
2. **Useful input:** compare a quiet baseline with ordinary speech or another
   controlled audible source. RMS/peak and spectral content respond while tone
   analysis stays “not requested.” The result is available without a strong
   18–22 kHz component. Avoid treating speech as a calibrated reference.
3. **Known-frequency check:** use an independent speaker/generator, first around
   1 kHz and then a distinctly different audible frequency. Check that observed
   peaks track the sources within a predeclared tolerance accounting for FFT
   bin spacing and source accuracy. Record the source and tolerance; report a
   failed or unavailable check instead of silently widening it.
4. **No generated tone:** verify graph/diagnostic evidence for the passive
   branch. A declaration that the phone emits no added near-ultrasonic tone
   requires an independent instrument with adequate response in that band and
   a before/during comparison. Human hearing and the app's own microphone alone
   cannot certify this. Record the scope of any physical check performed.
5. **Control isolation:** adjust display gain/palette/range. Acquisition kind,
   input level, actual sample rate, and the source's spectral frequency remain
   unchanged. A narrower Waterfall range must not attach a tone source.
6. **Stop and recovery:** stop explicitly, reach the 60-second limit, make the
   app inactive, and exercise an available route/interruption change. Check
   that acquisition stops with a reason, no restart occurs, and a fresh explicit
   start creates a new run without stale phase/history. Where a scenario cannot
   be exercised, record it as untested.
7. **Return to active behavior:** select Tone experiment while idle, verify its
   consent text, and exercise its existing start/stop flow separately. Listening
   must never leave an active tone branch armed for the next run.

### When a physical trace is still needed

Code and deterministic fixtures can establish units, mode selection, absence of
a constructed source node, finite-value handling, and correct accounting. They
cannot establish that a particular iPhone route delivered samples, that its
microphone has useful sensitivity at a frequency, or that the operating system
behaved as requested during an interruption. Those require the installed build
and observed device evidence.

If G0 has not produced an actual device report, G1 can still be developed and
checked in bounded software slices, but the original runtime failure remains
unidentified. A passive device trace should distinguish at least: activation
failure; no input callbacks; supported buffers with silence; missing sample
timestamps; input arriving but processing stalled; and processed spectra not
reaching the renderer. Do not describe a plausible code fix, a running engine,
or a successful TestFlight installation as confirmation that any of those
physical stages works.

[apple-record]: https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record
[apple-measurement]: https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/measurement
[apple-input]: https://developer.apple.com/documentation/avfaudio/avaudioengine/inputnode
[apple-rate]: https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferredsamplerate(_:)
[apple-preferences]: https://developer.apple.com/library/archive/qa/qa1631/_index.html

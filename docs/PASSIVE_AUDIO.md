# G1 useful passive audio

**Status: 0.2.2 (4), software-verified G1 source; physical P4 pending.** Public
source `222caea29b040063658cad2288b2e02726d02c73` passed native builds,
68 core tests, 34 Simulator-hosted tests and 10 separate Python recognition
tests in [run 42443019975](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42443019975).
All four idle/DEMO captures passed readiness and were visually inspected.
PR #4 merged into main with identical tracked blobs and modes. The single
TestFlight run succeeded: signed export, Apple validation and upload passed.
App Store Connect confirmed build **0.2.2 (4)** as VALID and the upload COMPLETE
at `2026-11-08T03:51:37Z`. Tester access remains blocked, and physical Listen/Tone
behavior is unobserved.
These are Mac CI results, not WD compilation or a hardware success record.
Exact source, run, artifacts, historical failures and delivery stages are in
[the validation record](PASSIVE_AUDIO_VALIDATION.md).

## Acquisition choices

The existing LIVE / DEMO / REPLAY provenance choices remain. Within LIVE,
**Listen** is the ordinary entry point; **Tone experiment** is an explicit
alternative. `AcquisitionKind` is immutable for a run. Selecting another kind
stops the current run and requires a new Start action. No selection, display
control, diagnostic inspection, or copied report starts acquisition.

Listen requests microphone permission after **Start listening**. A first grant
returns to idle and requires another deliberate start. It displays **LIVE ·
LISTEN**, local microphone analysis, RMS/peak input levels, and Waterfall. It has
no carrier, tone fit, phase, displacement, or phase-reference control. Tone
experiment retains explicit speaker-output agreement, its 18–22 kHz carrier
grid, and its existing phase/reference lifecycle. DEMO remains silent,
deterministic synthetic data, with no microphone or audio session. A synthetic
fixture is never evidence of live microphone capture.

Listen uses `AVAudioSession.Category.record` with `.measurement`, requests the
preferred 48 kHz rate and buffer duration before activation, selects built-in
microphone input, and installs an input tap. It constructs no `ToneRenderContext`,
oscillator, or `AVAudioSourceNode`, applies no speaker override, and makes no
microphone-to-output connection. Its validated format is enabled built-in input,
48,000 Hz for session and input, nonzero channels, noninterleaved Float32. Output
availability and output format are not passive acceptance conditions. An
unsupported input rate is rejected with observed diagnostics; G1 adds no
resampler or generalized rate negotiation.

Apple describes `.record` as suppressing playback, so other playback on this
phone may be interrupted while listening. It does not prevent calls, alarms,
or other nonmixable sessions from interrupting input. `.measurement` reduces
system processing; it does not calibrate the microphone or establish a flat
response. See Apple's [record category][record], [measurement mode][measurement],
[input-node tap and enabled-input requirements][input], and [preferred versus
actual session values][preferences].

## Input progress and analysis

Captured, synthetic, and rendered sample counts describe different producers.
For Listen, acquired duration and the sample cap advance from supported input
samples offered to the ring, including samples dropped when the ring is full.
Enqueued samples, dropped samples/blocks, complete analysis windows, normalized
capture indices, and elapsed in-app time remain separate evidence. Rendered
samples are transmission evidence; zero source callbacks and zero transmitted
samples are normal for Listen. The active retune budget retains its prior
transmission-based behavior.

The input tap accepts variable callback lengths. One serial consumer reads the
SPSC ring once per 2,048-sample analysis window. Each `AudioAnalysisFrame` carries
capture identity/timing, aggregate input statistics, an optional spectrum, and
an optional tone result. For Listen, tone analysis is not requested and the tone
result is absent. It is not a failed phase estimate or a carrier-bearing
`SpatioTemporalSlice`. Active tone arithmetic remains unchanged; an unavailable
tone estimate does not suppress otherwise valid levels or spectrum.

Finite levels can be available when hardware timestamps are missing. A spectrum
is absent for a window with invalid timestamps, an internal capture gap, or
nonfinite input. A subsequent finite, internally contiguous timed window can
recover a spectrum. Its original capture index preserves any missing interval;
the display does not insert zero-valued audio or stretch old rows into that gap.
Silence, nonfinite samples, missing input callbacks, missing timestamps, ring
drops, and unavailable tone analysis are distinct states.

Each run retains the 60-second sample cap, independent monotonic wall deadline,
and input/processing stall watchdogs. Stop, loss of foreground activity, audio
interruption, route/configuration change, media-service loss/reset, unsupported
format, or a deadline ends the run. An active playback-clock fault also stops
Tone. Missing passive input timestamps alone do not stop Listen: levels may
continue while affected spectra are absent. None of these stop events
automatically restarts a run. Stop
and failure cleanup also apply when no output source was attached.

## Units and display

RMS level is `20 log10(rms)` relative to digital full-scale amplitude 1. The peak
readout is the greatest absolute sample amplitude in linear full-scale (FS)
units. Converting that amplitude to dBFS would use the same reference. A
unit-peak sine has about −3.01 dBFS RMS and 0 dBFS bin-centered spectral amplitude.
The spectrum is the existing one-sided Hann coherent-gain-corrected amplitude
spectrum, not dB SPL or noise power density. Mathematical zero is silence, with
no finite logarithm; a visible floor is a display convention. Near-full-scale
digital samples do not prove analog microphone saturation or its absence.

At 48 kHz, a 2,048-sample window spans about 42.67 ms, and bin spacing is
23.4375 Hz. Bin spacing is not guaranteed two-tone resolution. Full audio ·
0–24 kHz is the digital analysis band, not calibrated sensitivity across that
band. The Listen narrow range is **18–22 kHz**, without a carrier implication.

Waterfall retains actual frequency coordinates, the dBFS legend, capture-time
gaps, bounded history, and the strongest-bin policy when bins share a display
column. A stopped Listen view is labelled as stopped history. A new Listen run
clears that history and starts a new clock origin. Gain is a visualization
offset, not microphone gain. Gain, palette, range, and persistence do not change
samples, aggregate levels, acquisition kind, or stored results. There is no new
spectral averaging in G1, and interpolation creates no measured resolution.

## Replay and diagnostics

The 64-byte v1 wire record and active Tone/DEMO Replay contract remain unchanged.
Listen does not append passive frames to that tape. Replay is consequently
limited to retained active Tone/DEMO results and runs with audio off. Passive
Replay is deferred: it needs its own acquisition metadata and must not assign
passive observations a fictitious carrier. Bounded live display history is not
a new recording or export format.

Diagnostics identify acquisition kind and distinguish current output state from
retained configuration. `session.transmitEnabled` describes whether the app's
tone-output gate is currently enabled. `audio.transmitConfigured` describes the
retained audio graph configuration; it may remain true after a Tone run has
stopped and is not evidence of current output. Neither flag measures physical
sound emission. Passive transmit counts stay zero unless there is a defect;
those zeros are not a stall alarm.
Supported/offered input, drops, completed processing, timing state, and GPU
progress provide independent observations. A running engine alone does not
prove samples reached analysis or display. Stop/error evidence remains available
after cleanup, including startup failures.

The optional JSON preview/copy contains finite scalar aggregates, counts,
normalized indices, relative intervals, and bounded operational events. Timing
values include per-acquisition durations and retained event offsets measured
since diagnostics initialization in the current app session. The report
contains no raw samples, spectrum arrays, images, route names/UIDs, account,
network or persistent device identifiers, or absolute host/uptime clocks. Copy
remains explicit, local-only, excluded from Handoff, and expires after one hour;
copies pasted elsewhere have the destination's lifetime. No automatic upload,
background audio mode, persistent raw recording, or passive export is added.

## Verification and remaining device gate

The focused source fixtures cover the new branch: passive audible-band spectra
and levels without a tone result; variable block sizes, gaps, missing timestamps,
nonfinite input and recovery; no-transmit graph policy; capture progress
without rendered output; and model/display selection, frozen history, and
passive frame identity without a slice. The final native run executed the core
and hosted suites. In particular,
`testListenModelProcessesFixturePCMWithoutToneConsentOrReplayAndRetainsStoppedData`
exercised the production model with supplied PCM through the ring/DSP path and
asserted no passive Replay records. This hosted fixture uses a controlled audio
adapter; it is separate from a physical Listen run. Existing active phase,
DEMO, v1 codec, Replay and G0 diagnostics remain regression coverage.

For P1, `testListenGraphRequiresOnlyBuiltInInputAndNeverSelectsTransmission`
checks `AudioGraphPlan` policy: category, mode, options, transmission intent, and
route acceptance. It does not start `AVAudioEngine` or observe source-node
construction and teardown. Source review of `AudioTransceiver.start()` confirms
that tone-context/source construction and speaker override are guarded by the
transmission policy. Actual startup/cleanup instrumentation and physical-device
audio-graph behavior remain unexecuted. The synthetic `CaptureContext` tests
exercise the input adapter, counters, ring, and consumer; they do not establish
that an iPhone audio session supplied those buffers.

### Historical WD implementation checks

The following checks describe the original bounded implementation before later
integration, versioning and capture-tooling changes. They are retained as
provenance, not the current file/test inventory or native validation result:

- `python scripts/generate_project.py` succeeded; a second generation was
  byte-identical. The shared scheme parsed as XML, and all 10 app sources and
  5 hosted-test files were present in their generated build phases. Package
  directory targets discover the new core source and test automatically.
- `git diff --check` passed. An inline Python comparison against base
  `ca4442415728cbf4f3e1721b8b1e5015a0cebc57` confirmed that the active tone-analysis
  body was unchanged in that delta. The v1 codec, FFT, existing G0 tests/helpers,
  version/config, workflows, resources and historical evidence were unchanged
  in that implementation snapshot.
- An independent Python Float32 fixture calculation gave RMS
  `0.176776694937`, RMS level `-15.05149980 dBFS`, and bin-40 spectral amplitude
  `-12.04119984 dBFS` at `937.5 Hz`. This verifies fixture expectations only.
- Fourteen focused Swift test cases were added as source. Neither `swift` nor
  `xcodebuild` was available; no Swift compilation, XCTest, Simulator, GPU,
  permission-flow, or physical-device execution passed on WD.

A useful digital fixture is a 0.25-peak, bin-40 sine: 937.5 Hz, approximately
−12.04 dBFS spectral amplitude and −15.05 dBFS RMS at this rate/window. Display
changes must not change these underlying values. This is a synthetic arithmetic
expectation, not a predicted physical microphone level.

For a future source change, the Mac validation entry points include the commands
below. The evidence record identifies what actually ran for the current source;
these instructions do not call for another native run for a documentation-only
status update. They were not executed on WD:

```bash
bash scripts/build.sh all
swift test -c release
python3 scripts/capture_simulator.py
```

The build script runs Debug core tests, a Release core build, and unsigned
Simulator/device app builds. The capture script records idle/DEMO screens and
runs the Simulator-hosted application suite with an `.xcresult` bundle. These
screens are not passive hardware evidence. Check passive frame delivery to
Waterfall, absent phase controls, honest source/unit labels, and stopped history.
Any Simulator passive fixture must be labelled synthetic and silent. Do not
report it as hardware input. Preserve actual command output and failures.

### P4: physical-device acceptance remains open

After authorized tester access, P4 uses the reviewed build on the phone owner's
physical iPhone. Record
source commit, installed version/build, model/iOS, actual route/rate, test
conditions, observations, and untested cases. The smallest useful sequence is:

1. Start idle in Listen, grant permission if needed, then explicitly start.
   Confirm input, captured samples, complete windows, and GPU completions advance;
   source callbacks and transmitted samples remain zero. Diagnostics inspection
   must not create another session.
2. Compare a quiet baseline with speech or an independently controlled audible
   source. Levels and spectra should respond without an 18–22 kHz component or
   a tone result. Then compare two known audible frequencies using a declared
   source accuracy and peak-frequency tolerance that accounts for bin spacing.
3. Change gain, palette, and range. Confirm acquisition kind, underlying level,
   rate, and source frequency remain unchanged. Stop and inspect labelled history.
4. Exercise explicit Stop, the 60-second cap, inactivity, and an available
   route/interruption change. Confirm a retained reason, no automatic restart,
   and fresh history on a new explicit Listen run.
5. Select Tone experiment while idle and separately verify its agreement and
   existing start/stop behavior. Passive listening must not arm later output.

Source review establishes the guarded no-source branch; policy tests exercise
its configuration decisions. These are distinct from observing the running
audio graph or its cleanup. A physical claim of no added near-ultrasonic output
requires an independent instrument with adequate response and a before/during comparison;
human hearing and the app's own microphone cannot certify that claim.

If P4 fails, retain the actual diagnostic report and distinguish activation
failure, no callbacks, supported silence, missing timestamps, processing stall,
and spectra not reaching rendering. The earlier G0 runtime symptom remains
unidentified without a device trace. Code changes, CI, or installation alone
cannot resolve that evidence gap.

[record]: https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record
[measurement]: https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/measurement
[input]: https://developer.apple.com/documentation/avfaudio/avaudioengine/inputnode
[preferences]: https://developer.apple.com/library/archive/qa/qa1631/_index.html

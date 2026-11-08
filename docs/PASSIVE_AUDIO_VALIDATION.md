# Passive audio candidate 0.2.2 (4): evidence record

## Intended result

Ordinary LIVE entry selects **Listen**. After an explicit start and microphone
permission, an input-only audio graph supplies levels and a spectrum without
constructing a tone source. **Tone** remains a separate experiment with output
consent. A missing tone estimate and a tone analysis that was never requested
are different states.

This candidate supports the built-in 48 kHz, noninterleaved Float32 input route.
Unsupported routes/formats produce diagnostic evidence instead of a substituted
measurement. Display levels are digital dBFS, not calibrated sound pressure.
Runs remain foreground-only and limited to 60 seconds. Listen does not write
invented phase records into the existing 64-byte active/DEMO Replay format.

## Implementation and review provenance

- G0 diagnostic foundation: PR #3, amended source
  `d4903b847e610761a4d9c7f94ee58e889a4d6d31`.
- WD Codex implementation session:
  `01a1b8d8-4802-7141-b421-899b250ca717`; exit 0 after 674.7667 seconds,
  completed `2026-11-08T02:00:18.6241011Z`. The 18-file output was transferred
  with per-file SHA-256 verification and integrated in an isolated worktree.
- Independent WD Codex review:
  `01a1b8f0-b557-7350-a176-1aaff8befb57`; exit 0 after 230.3414 seconds,
  completed `2026-11-08T02:19:34.8335466Z`. It examined a hash-verified
  19-file snapshot over `722ee840ae8f72d01cec0a3016fa8f52320726c4`,
  including the five new source/test/documentation files.
- Local integration review covered acquisition control, retained transmission
  state, clock discontinuities, Waterfall missing data, UI and privacy wording.
  G0's later watchdog/copy corrections were integrated after the WD review;
  that earlier review is not claimed to cover the subsequent merge.

The Windows sessions did not compile Swift, execute Metal, or test physical
audio. Their recorded exit status establishes task completion only. Native
validation belongs to the named Mac CI run below.

## Findings addressed before native validation

1. Retained tone graph intent could be mistaken for current output activity.
   `session.transmitEnabled` now reports the active app tone gate;
   `audio.transmitConfigured` reports retained configuration. Stop, Listen and
   DEMO do not report the app tone gate as enabled.
2. Repeated or rewound capture indices could reuse an older spectrum at the
   same index. The model clears history at that boundary, including when the
   new observation has no spectrum.
3. Independent review reproduced a second missing-data case: a valid window at
   index 0 followed by an untimed window at index 512 could borrow the older
   spectrum through nearest-row resampling. The newest row must remain missing
   when its explicit observation has no spectrum; texture regressions cover it.
4. Listen could initially leave a hidden Carrier adjustment selected. Its
   adjustment selection is normalized on entry and mode changes.
5. Permission/reviewer text needed to describe passive listening as well as
   the active 18–22 kHz tone experiment.

## Software validation gates

| Boundary | Required evidence | Current status |
| --- | --- | --- |
| Portable analysis | Known digital input, levels, FFT scale/peak, variable callback partitions, gaps/drops, invalid time and nonfinite input; no tone result in Listen | Fixtures implemented; exact-candidate native execution pending |
| Capture adapter | Synthetic PCM through the production CaptureContext, ring and consumer; captured-duration cap independent of source callbacks | Fixture implemented; execution pending |
| Model lifecycle | Explicit Listen start without output consent, real ring/DSP delivery, no phase/Replay, captured duration and retained stop evidence | Fixture implemented after G0 runtime seam integration; execution pending |
| Renderer | Uploaded texture values, display-only parameters, missing intervals, rewound/current-missing frames and recovery | Regressions implemented; execution pending |
| Audio graph | Input-only policy and source guards; no source node, output-node access or speaker override on Listen branch | Source review and policy fixtures; actual engine startup/cleanup and device behavior unverified |
| Native build | Core Release, Simulator Debug, unsigned device Release, hosted tests and native screenshots | Pending for G1 |
| Distribution | Reviewed main ancestor, signed archive/export, Apple validation/upload/processing, internal group association | Not dispatched for 0.2.2 (4) |

Record exact source SHA, actual test counts, run/artifact identities and inspected
captures after execution. A G0 pass does not validate G1. A digital fixture does
not establish a working physical microphone, acoustic sensitivity or calibration.

## Smallest phone experiment

Open **LIVE → Listen**, grant microphone permission if requested, then explicitly
start. Observe input callbacks, accepted samples, RMS/peak, spectrum frames and
GPU completions. Compare quiet and ordinary audible sound without interpreting
dBFS as dB SPL. Stop and inspect the retained report. If a route/format/startup
failure occurs, preserve that report rather than repeatedly restarting without
evidence. Confirm interruption/background stopping and a fresh explicit start.

AR, camera, LiDAR, external radio probes and inter-phone synchronization remain
future gates in the [project roadmap](project/ROADMAP.md).

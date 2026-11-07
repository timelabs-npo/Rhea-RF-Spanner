# Acoustic signal model and numerical contract

## What this implementation measures

The implemented experiment uses a phone's audio output and microphone. Its
default carrier is **20,000 Hz**, selectable from **18,000–22,000 Hz** in **500 Hz**
steps, sampled at **48,000 samples per second**. The
analysis window contains **2,048 samples**, or approximately **42.67 ms**. The
source code does not access a radio receiver, transmit RF, implement Wi-Fi or
cellular channel sounding, or identify objects behind obstructions. The project
name “Rhea RF Spanner” is a product name, not a description of those capabilities.

The numerical output is the phase of a fitted acoustic tone in the microphone
signal, relative to the first usable analysis frame in the current calibration
epoch. A nearby reflecting object can affect that phase, but so can direct
speaker-to-microphone coupling, multiple reflected paths, motion of the phone,
audio routing, acoustic processing, oscillator mismatch, and noise. This
implementation does not separate those causes or identify a target.

The sample rate and carrier are configuration constants, not measured hardware
performance. The iOS audio layer must validate its actual route and sample rate.
The scalar **343 m/s** is an explicit model assumption for the sound speed; the
app does not measure temperature, humidity, or sound speed.

## Tone estimation

For each analysis frame, let `x[n]` be the microphone sample and let
`w[n] = 0.5 (1 − cos(2πn/N))` be a periodic Hann weight. The model is

\[
x[n] \approx a\cos(\omega n)+b[-\sin(\omega n)],
\qquad \omega=2\pi f/f_s.
\]

The estimator solves the complete two-column weighted least-squares problem.
It computes the weighted Gram matrix of the sine and cosine columns and solves
its 2 × 2 linear system. It does not assume that a 2,048-sample window contains
an integer number of carrier periods. The local complex phasor is `a + ib`.
Rotating that phasor by `exp(−i ω t0)`, using the capture sample timestamp `t0`,
removes the predictable advance from one analysis frame to the next.

The default sampled carrier has a minimal period of 12 samples because
`20,000 / 48,000 = 5 / 12`. The Observatory grid uses a common 96-entry sampled
cycle; at 20,500 Hz the minimal period is 96 (`41 / 96`). Both the oscillator and
analysis reference use the same selected finite cycle. An arbitrarily long
sample timestamp is reduced modulo that cycle **before** converting to floating
point. The transmitter continues its
cycle across every render callback, regardless of callback size. Repeating a
2,048-sample waveform table would introduce a phase discontinuity, since 2,048
is not divisible by 12.

All estimator accumulation uses `Double`; microphone storage and playback
samples use `Float`. `addingProduct` is used for dot-product accumulation. This
choice is not a claim of zero numerical error, a guaranteed particular machine
instruction, or measured real-time timing. No “0 ULP jitter” label is used.

## Quality gate and calibration

The quality statistic is

\[
Q = 10\log_{10}\left(E_\text{fitted tone}/E_\text{residual}\right),
\]

with both energies measured using the same Hann weights. The residual is the
weighted least-squares residual. A numerical floor bounds the displayed value
to the interval −120 to +120 dB. This is a **tone-to-residual estimate**, not
calibrated acoustic SNR, a statistical confidence interval, or proof of a
coherent reflected path. In particular, interference at the same frequency
can fit the model very well.

A frame is usable only when it has finite sample values, a valid contiguous
capture timeline, fitted peak amplitude of at least `0.00001` in input sample
units, and quality of at least `3 dB`. Those two thresholds are engineering
defaults. They have not been calibrated as a detection sensitivity or accuracy
specification on an iPhone. `isPhaseCoherent` is retained as a compatibility
property for this local validity gate; it must not be interpreted as independent
proof of physical coherence.

An unusable frame has **no phase/displacement value**. It clears the old phase
reference. The next usable frame establishes a new reference at zero and
increments `calibrationID`; the UI can observe `didRebaseline`. The estimator
never integrates phase through silence, invalid samples, low quality, missing
timestamps, or a capture gap. A deliberate calibration request has the same
reference-reset behavior and must execute on the consumer's serial DSP context.

## Phase unwrapping and the displacement display

For consecutive usable frames, the wrapped phase difference is mapped to the
interval from −π to +π and accumulated. This assumes that the actual phase
change between frames has magnitude below π. The algorithm cannot detect a
missed full cycle from these samples alone.

For one ideal reflected path in monostatic geometry, an increase in reflector
range `Δr` changes the received phase by `−4πfΔr/c`. The display can therefore
show the conditional conversion

\[
\Delta r_\text{equivalent}=-\frac{c}{4\pi f}\Delta\phi.
\]

Here **positive means increasing hypothetical reflector range**. The minus
sign follows the phase convention `x[n] = A cos(ωn + φ)`. This is an explicitly
documented correction to the positive sign in the supplied prototype.

At the configured `c = 343 m/s` and `f = 20,000 Hz`, one radian corresponds to
about **1.365 mm** of equivalent monostatic displacement, and one 2π cycle to
about **8.575 mm**. With one estimate every 2,048 samples, the below-π condition
corresponds to less than about **4.2875 mm per frame**, or about **0.1005 m/s**
for constant radial motion under that ideal model. These values are algebraic
consequences of the model, not demonstrated resolution, maximum tracking speed,
or accuracy specifications.

A phone's separated speaker and microphone, its direct acoustic path, and
multiple reflections do not generally satisfy that simple geometry. Absolute
range cannot be recovered from this one uncalibrated continuous tone. The UI
must label the conversion **equivalent displacement**, not “distance to object,”
and must not interpret a moving animation as a spatial map.

## Capture transport and thread ownership

The queue has one producer and one consumer. Each accepted sample retains its
capture timestamp and whether that timestamp was valid. A full queue rejects
the entire arriving callback block, increments separate dropped-block and
dropped-sample counters, and leaves unread data intact. Later accepted samples
retain their real capture times, so loss is detected at the actual gap rather
than by compressing the time axis or retroactively invalidating earlier queued
frames.

Release/acquire cursor operations publish written samples and return consumed
slots to the producer. No locks or allocation occur inside `write` or `read`.
The implementation does not assert a Swift object-memory layout or rely on
padding tuples to separate atomics into cache lines.

`@unchecked Sendable` covers narrowly defined ownership contracts, documented
on each type:

- `SPSCFloatRingBuffer`: one serial producer and one serial consumer, with atomic
  handoff of slots.
- `PhaseSensingEngine`: one serial DSP consumer owns all mutable analysis state.
- `SineOscillator`: one serial audio render context owns the bounded cycle index.

The queue deliberately has no `reset()` method. A new recording session gets a
new queue, oscillator, and phase estimator. Old objects remain alive until
render/capture callbacks and the old DSP consumer have stopped. A stop operation
must not clear storage while either context can still access it. Empty consumer
polls mean “no complete frame yet”; they are not dropped read frames.

The audio adapter should use valid `AVAudioTime.sampleTime` values, optionally
translated by a fixed per-session offset. If a callback has no valid sample
timestamp, it must set `timestampIsValid: false`; a software counter must not be
silently presented as a verified hardware timeline.

The iOS render adapter also checks the source node's `AudioTimeStamp`: a missing,
non-finite, fractional, out-of-range, or discontinuous output sample time causes
the output block to be silenced and the session to stop. This prevents the
analysis from continuing through a known transmitter-timeline interruption.
It is a software gate; the availability and continuity of those timestamps on
the selected physical devices still require device testing. It does not measure
the absolute phase alignment or analog delay between speaker output and
microphone input.

## Automated verification and remaining evidence

The portable Swift package includes tests for:

| Risk | Executable check |
| --- | --- |
| Fixed-table overread / callback phase restart | Identical output for a long render and irregular chunks, including chunks larger than 2,048 samples |
| Corrupted ring wrap or overwritten unread data | Wrap-around ordering, whole-block overflow rejection, and capture timestamp retention |
| Concurrent SPSC handoff | Separate producer/consumer queues transfer 100,000 ordered samples |
| Hidden time compression after a drop | Buffered frames stay valid; the actual timestamp gap invalidates phase and triggers a new reference |
| Gaps inside one analysis frame | Per-sample timeline check rejects the mixed frame |
| Silence or poor signal causing false phase lock | Silence, sub-threshold pure tones, off-frequency energy, and NaN samples cannot establish a usable estimate |
| Sample-clock precision loss | Synthetic phase tracking at capture timestamps above 2^60 |
| Wrapped phase crossings | Known synthetic phase changes crossing ±π are recovered |
| Concurrent calibration reset | The public contract confines reset to the consumer; a test confirms it does not mutate queued samples |

Tests use generated sample arrays. Their results establish properties of this
software model and selected concurrency runs. They do not establish acoustic
performance, iOS audio-driver behavior, device audibility, SPL, battery use,
thermal behavior, microphone privacy UI, or physical ranging accuracy. The
execution logs and overall build status are maintained separately in the
repository's validation documentation. An Xcode build and a physical-device
session are separate verification steps from `swift build` / `swift test` of
this portable package.

## Primary API references

- [Swift Synchronization: release-store ordering](https://docs.swift.org/latest/documentation/synchronization/atomicstoreordering/releasing/)
- [Apple: AVAudioTime.sampleTime](https://developer.apple.com/documentation/avfaudio/avaudiotime/sampletime)
- [Apple: AVAudioTime.isSampleTimeValid](https://developer.apple.com/documentation/avfaudio/avaudiotime/issampletimevalid)
- [Swift Atomics project: Swift 6 Synchronization migration note](https://github.com/apple/swift-atomics)

The equations above are the implementation's stated mathematical model. The
API references support the timestamp and synchronization contracts; they do
not constitute validation of an acoustic ranging product.

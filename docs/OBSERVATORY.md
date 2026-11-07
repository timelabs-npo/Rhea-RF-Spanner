# Observatory: acquisition, display, and replay contracts

## Implemented boundary

This update belongs to **Rhea RF Spanner**. It adds a native observation interface
and extends its acoustic experiment. It does not implement ARKit, LiDAR, RF
capture, Wi-Fi CSI, an external UDP probe, or tomography. Optional spatial
fields remain absent until a real, synchronized spatial source exists.

| Mode | Samples | Hardware | Meaning of displayed values |
| --- | --- | --- | --- |
| LIVE | Built-in microphone, 48 kHz | Explicit speaker/microphone session | Fitted acoustic tone and sample spectrum |
| DEMO | Seeded synthetic moving-reflector model | None | Results of processing the synthetic samples |
| REPLAY | Retained derived records and companion spectra | None | The original LIVE/DEMO result and epoch |

Replay is a playback mode. It never changes a simulated record into a measured
one. Field rendering is an abstract phase display for LIVE and a synthetic wave
illustration for DEMO. A single microphone frame does not measure a 2D/3D field.
Waterfall displays a spectrum computed from the actual selected sample source.

## Frequency and phase

At 48,000 samples/s, frequencies `500 * h` Hz have carrier phase addresses

```
((sampleTimestamp % 96) * h) % 96
```

The supported harmonics are 36 through 44, inclusive. At 20 kHz the waveform's
minimal period remains 12 samples; at 20.5 kHz it is 96. A common 96-entry
sampled cycle supports the whole grid. Modulo reduction happens in integer
arithmetic before conversion to floating point, including clocks above 2^53.

This removes growing-angle evaluation from the carrier reference. It does not
make sine/cosine tables, floating-point reductions, atan2, or measured phase
error-free. No claim of “0 ULP phase drift on an infinite horizon” is made.

Carrier selection is an acquisition change. A running session is stopped and
replaced by one with a new oscillator, ring, estimator, configuration, and
acquisition epoch. The next valid frame establishes a new zero. Phase values
across frequencies or epochs must not be joined into one continuous motion
track. Display gain, persistence, and palette never enter this transaction or
the synthetic source parameters.

The estimator retains its complete Hann-weighted two-column least-squares
solution and matching projected/residual energies. See [SIGNAL_MODEL.md](SIGNAL_MODEL.md).
The supplied V2 fragment's `|I+jQ|² / (N * 0.375N)` is not a compatible energy
normalization and was not adopted. `coherenceSNR` is a wire compatibility field
name; the UI calls it **tone / residual**, not calibrated acoustic SNR.

## Silent deterministic simulation

The default DEMO is one sinusoidally moving hypothetical reflector: carrier
peak amplitude 0.1, displacement amplitude 1 mm, motion frequency 0.25 Hz,
and expected full-band sample SNR 30 dB. These are synthetic model parameters,
not observations or medical measurements. There is no audio output.

Displacement modulates carrier phase on every sample. Carrier addressing is
bounded, and the motion phase is bounded independently of total elapsed time.
Seeded timestamp-addressed noise makes sample generation reproducible across
callback chunk boundaries. A generation range must not cross UInt64.max; a new
generator/session is required after clock wrap. Noise is scaled by RMS, so expected noise power
matches the configured synthetic SNR; finite analysis windows fluctuate.
Samples are not clipped. The model is separate from renderer gain/persistence.

## Waterfall and uncertainty

The analysis uses a Hann-windowed spectrum with dBFS amplitude scaling. At the
standard 2,048-sample window, FFT bins are 48,000 / 2,048 = 23.4375 Hz apart.
This bin spacing is not a calibrated resolving-power claim. The displayed
frequency band is approximately 18–22 kHz, bounded by available FFT bins.

Spectral rows are ordered oldest to newest in application history; the
renderer places the newest row according to its labelled time axis. A new
acquisition or playback discontinuity resets or reconstructs that history.
Invalid phase is hatched and carries a textual status. A poor single-tone fit
does not mean the microphone spectrum is empty. Nonfinite samples, missing capture timestamps, and gaps inside an analysis
frame produce no valid spectrum and cannot leave an older row labelled as a new measurement.

No percentage is presented as a calibrated probability of correctness. The
record's `qualityScore` is a display heuristic derived from the fit gate.

## Explicit 64-byte slice, version 1

All multibyte values are little-endian. Float fields use IEEE-754 binary32.
The encoding is independent of Swift object layout and SIMD3 padding. Fitting
still uses Double internally; conversion to this compact record is lossy. Values
that cannot be represented as finite binary32 invalidate the record rather than
being saturated or crashing Replay. The nonfinite/unrepresentable validity code
then marks unavailable phase and neutral finite payloads.

| Byte offset | Length | Value |
| --- | ---: | --- |
| 0 | 8 | UInt64 sample timestamp, in the acquisition's 48 kHz sample clock |
| 8 | 4 | Relative unwrapped phase, rad; presence flag required |
| 12 | 4 | Fitted carrier peak amplitude, input sample units |
| 16 | 4 | Fitted-tone / residual ratio, dB |
| 20 | 4 | Carrier frequency, Hz |
| 24 | 12 | Optional position x/y/z, metres |
| 36 | 12 | Optional forward vector x/y/z |
| 48 | 4 | Optional LiDAR depth, metres |
| 52 | 4 | Quality display heuristic, [0,1] |
| 56 | 4 | UInt32 acquisition epoch |
| 60 | 4 | Flags and wire version |

Flags: bits 0–2 encode validity (`0` valid, `1` low signal, `2` low quality,
`3` input discontinuity, `4` nonfinite input); bit 3 marks a simulated origin;
bits 4 and 5 mark rebaselining and discontinuity. Bits 6/7/8/9 indicate presence
of position/forward/depth/phase. Bits 10–23 are reserved zero. Bits 24–31 contain
version `1`. Missing-field payload bytes are zero, but only the presence flag
determines availability. A measured position at the origin is therefore
distinct from an absent position.

The decoder checks size, version, reserved flags, supported carrier grid,
finite values, optional payloads, and consistency of validity with phase
presence. A valid phase of zero is distinct from an invalid/unavailable phase.
This is an internal replay format, not a UDP protocol with authentication,
packet sequencing, sender identity, or synchronization across devices.

## Bounded Replay tape

The tape stores exactly 2,048 fixed-size records at maximum: **131,072 bytes**
for encoded slices. Optional spectrum arrays are bounded companion entries and
consume additional memory; the whole replay is not a 128 KiB allocation.
At one frame per 2,048 samples this record count represents approximately
87.38 s of uninterrupted analysis. The LIVE session's existing 60 s limit
still applies. When full, the oldest record and its companion are overwritten.

The tape belongs to one serial owner (MainActor in this app), not the audio
callback. Records retain source, carrier, epoch, validity, and reset flags.
The app offers playback from volatile memory only. No raw audio file,
measurement upload, persistent recording library, or export interface is added.

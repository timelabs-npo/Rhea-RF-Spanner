# Portable diagnostics core

Bounded scope: `Sources/RheaRFCore/Diagnostics.swift` and its XCTest file add
portable Swift 6 values, with no dependencies or Apple framework imports. The
diagnostic design brief is not a crash log. The reported 0.2.0 (2) device failure
has no established physical symptom; this work neither diagnoses it nor verifies
hardware. The existing DSP core and silent DEMO are separate integration work.

## Statistics

`SignalBlockStatistics.measure` borrows a valid `UnsafeBufferPointer<Float>` for
one allocation-free pass, retaining no samples or pointers. Counts include all
samples, finite samples, exact zeros (including negative zero), nonfinite samples,
and finite samples with absolute value >= 0.999. Subnormal nonzero values are not
silence. Minimum, maximum, arithmetic mean, RMS, and absolute peak use finite
samples only and Double accumulation (conversion precedes squaring). No finite
samples means all five metrics are nil, including for empty input. Float extremes
and any representable buffer length fit within Double sums and squared sums.
Measured values can be encoded with default JSONEncoder settings without
nonfinite-number conversion.

Amplitudes are linear digital full-scale units, not SPL, acoustic pressure, or
calibrated loudness. The clipping count is a near-full-scale indicator; values
above 1 are retained, and the count does not prove physical clipping. Aggregate
statistics alone cannot establish microphone operation or a physical failure.

## Events and ownership

`DiagnosticEvent` sanitizes negative or nonfinite elapsed seconds to zero. Its
category/code are limited to 64 Swift Characters each and message to 512, on
construction and decoding. These are character limits, not byte limits. Normal
Codable round trips preserve valid events. Sequence controls ordering; timestamps
are caller-supplied elapsed durations, never a wall clock.

`BoundedDiagnosticLog` preallocates a ring, default 128 events; requested capacity
is clamped to 1...4096 to bound extreme inputs. Full rings overwrite their oldest
event and increment `droppedEventCount`. Snapshots are oldest to newest by append
order and remain independent of future mutations. Sequences begin at 1 and keep
increasing across `removeAll()`. Clear releases retained text and resets drops,
without discarding slot storage. Drop counts saturate at UInt64.max; sequence
UInt64.max is emitted once, then later appends are rejected and counted as drops
to avoid wrap, duplicate sequence values, or arithmetic traps.

The caller owns thread confinement on one serial executor. Sendable allows
transfer of these values; it does not make shared mutation concurrent-safe.
The log is explicitly NOT concurrent-safe and is NOT for an audio callback:
event strings, snapshots, and array copy-on-write can allocate. The statistics
function itself allocates nothing; its pointer must remain valid and unmodified
throughout the call. No raw audio is stored or logged by these primitives.
Free-form text is not redacted: callers must provide fixed, non-sensitive codes
and summaries, never raw samples, recordings, device identifiers, network
identifiers/addresses, email addresses, credentials, or keys.

## Pipeline flow

`PipelineHealth.evaluate` is pure and reads no clocks. Supply counters from the
same run, elapsed seconds since its start, and ages of its last input callback
and processed frame. A processed frame is an observed processing event, not proof
of a valid scientific measurement. The states describe observed flow, without
inferring a hardware cause.

- A stopped run is idle, regardless of counters or times.
- No input callbacks means waitingForInput during startup grace, then inputStalled.
- Once input exists, stale input takes precedence over all processing states.
- Fresh input with no processed frames means waitingForProcessing during grace,
  then processingStalled. Grace is measured from run start, not first input.
- With both counters positive, stale processing means processingStalled;
  otherwise the state is healthy. Healthy describes flow, not signal quality.

Grace is active only while elapsed < grace; at exactly grace an absent stage is
stalled. Recency is stale only when age > threshold, so equality remains fresh.
Defaults are 2 seconds for both settings; finite zero is allowed. Negative or
nonfinite elapsed becomes 0. Negative or nonfinite grace/threshold uses its
2-second default. Nil, negative, or nonfinite recency uses sanitized elapsed time
as a conservative since-start fallback. This can report a stall when timing is
unavailable after the threshold; it does not prove actual hardware cessation.
Explicit stale recency can override startup grace once its stage has been seen.
Contradictory counters (processing without input) follow the no-input rule.

## Validation and session status

Status: bounded implementation complete; 20 XCTest methods authored, none run.
This document is the on-disk status report for the coordinator. Source and test
math/state contracts received an independent read-only review, with no evident
blocker found. Git diffs were inspected; only the three assigned new paths were
changed. No existing files were edited and no commit or publication was made.

The package declares Swift tools 6.0 and Swift language mode 6, and uses XCTest.
Windows PATH did not expose swift/swiftc; Ubuntu WSL did not expose a runnable
swift command. The actual attempt to run `swift test --filter DiagnosticsTests`
from the repository root via Ubuntu WSL stopped at `sh: 1: swift: Permission denied`
(launcher exit 1), before compilation or test discovery. Thus tests are NOT RUN,
with no PASS claim. Full debug/release tests were not attempted after that failure.
Swift 6 compilation, XCTest type checking, and runtime behavior remain unverified;
source review cannot establish compiler acceptance. No iOS SDK/device validation
has occurred, and the reported device symptom remains unknown.

Run from the repository root with an installed Swift 6 toolchain:

```sh
swift test --filter DiagnosticsTests
swift test
swift test -c release
```

The targeted suite covers finite-only numerical results, silence, signed zero,
nonzero samples, nonfinite and empty inputs, JSON safety, text bounds, bounded
ring overwrite/order/drop/clear behavior, and deterministic pipeline transitions.
UInt64 counter exhaustion is guarded in source; public-API tests do not attempt
an impractical UInt64.max appends. Compiler and runtime acceptance remain pending
until the commands above run in a suitable environment.

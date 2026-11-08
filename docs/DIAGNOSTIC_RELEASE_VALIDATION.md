# Diagnostic candidate 0.2.1 (3): evidence record

## Scope and starting evidence

The owner reports installing and testing 0.2.0 (2), then reports that the app
does not yet provide useful behavior. No physical-device diagnostic dump was
provided. The requested `debugging.txt` was read in full on WD; it is a design
brief for operational diagnostics, not a device trace.

This change supplies evidence at the microphone, DSP and renderer boundaries,
preserves operational failures, exposes a user-controlled aggregate JSON report,
and makes the full audio spectrum visible independently of phase validity.
It does not establish a physical root cause or introduce camera, AR, LiDAR, RF
capture, external probes or inter-device synchronization.

## Source and work sessions

- Starting main: `4be8724f244cd2e478f5d6877f798986fcaa2ae9`.
- Initial candidate: `ca4442415728cbf4f3e1721b8b1e5015a0cebc57`.
- Independent-review corrections: `d5425d10c686575a8ad95021b9bd5120a3db5765`.
- Latest native-verified G0 source: `722ee840ae8f72d01cec0a3016fa8f52320726c4`.
- Review branch: [PR #3](https://github.com/timelabs-npo/Rhea-RF-Spanner/pull/3).
- Project tracking: [issue #2](https://github.com/timelabs-npo/Rhea-RF-Spanner/issues/2).

A bounded Codex Full Access implementation session on WD created portable
statistics, health-state evaluation, a bounded log, tests and documentation. It
exited 0 after 433.57 seconds. A separate read-only Codex review of the exact
initial candidate exited 0 after 214.67 seconds. Session IDs and complete outputs
are retained on WD; their existence is not treated as proof of compilation.

All three WD Codex sessions have completed. The separate G1 Listen implementation
session `01a1b8d8-4802-7141-b421-899b250ca717` exited 0 after 674.7667 seconds at
`2026-11-08T02:00:18Z` (05:00:18 Europe/Moscow). Its work was imported into an
isolated G1 integration tree and received independent review corrections. G1
targets **0.2.2 (4)**; its native validation remains pending and is separate from
the G0 evidence below.

The Windows/WSL attempt to run Swift stopped with `swift: Permission denied`
before compilation. No Swift, Simulator, Metal-runtime or device test pass is
attributed to WD. Native execution uses the existing Mac CI workflow.

## First actual native run

[Run 42435212237](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42435212237)
tested `ca4442415728cbf4f3e1721b8b1e5015a0cebc57` with Xcode 26.3.

| Check | Observed result |
| --- | --- |
| Core Release compilation | Passed |
| Core XCTest suite | 61 tests, 0 failures |
| iOS Simulator Debug compilation | Passed |
| Unsigned iOS device Release compilation | Passed |
| Simulator-hosted application suite | 13 tests, 0 failures |
| Native app launch/capture | Idle, DEMO Field, DEMO Waterfall, DEMO Diagnostics captured |

The hosted suite included four diagnostic integration/self-test tests, seven
renderer tests, and two existing session lifecycle tests. The code-path checks
exercise synthetic data and hosted software; they do not exercise a physical
microphone or speaker.

Artifact ID: `13599587524`; SHA-256:
`b1c09cc6534f6a1afef93599540d734b103029d756e050f6454cff75dfbbbe1a`.
The artifact contains compiler/test logs, the four PNGs, capture manifest and
the Xcode result bundle. GitHub retention is seven days. A copy was downloaded
to WD before review.

The Diagnostics and Waterfall PNGs were visually inspected. The former showed
DEMO, healthy processing, 244 processed/spectrum frames, zero microphone
callbacks, and finite synthetic input levels. The latter displayed the actual
synthetic carrier spectrum, but input-status/level lines were truncated in the
narrow status card. Those lines were moved into a separate full-width strip.

## Independent findings and corrections

1. Retained events used a clock tied to the most recent acquisition. A separate
   diagnostics-session elapsed origin now preserves order across stops and
   restarts; the UI and privacy text name both interval meanings correctly.
2. Character counts alone did not bound retained Unicode bytes. Text now has
   explicit UTF-8 caps applied before grapheme processing, with pathological
   combining-mark and partial-scalar regressions.
3. GPU completion accounting used the main-actor handling time. The callback
   now captures its completion time before the actor hop. Expired, out-of-order
   and invalid timing cannot create false recent completion activity. Absolute
   clock values remain private.
4. The first native compile warned about a mutable test clock captured by a
   sendable closure. An explicit main-actor reference fixture replaces that
   captured variable without changing production code or test count.
5. Actual capture exposed the truncated main-screen input readout. The layout
   correction was visually confirmed in the next native Waterfall capture.

## Second native run and visual confirmation

[Run 42436184984](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42436184984)
**succeeded** for `722ee840ae8f72d01cec0a3016fa8f52320726c4`.
The actual logs record **63 core tests and 16 Simulator-hosted tests, with zero
failures**. Core Release, iOS Simulator Debug, and unsigned iOS device Release
builds passed. All four native PNG captures succeeded. The coordinator visually
inspected the Waterfall PNG and confirmed that the full-width input readout is
now legible.

Artifact ID: `13598909772`; SHA-256:
`8f035b1ed24a7ec3e8f01c4d87480d89b0f0cd5251c07bf3ef245be4253a3838`.
A copy was retained on WD. These results validate the named software candidate,
not microphone/speaker behavior on a physical device.

## Subsequent review findings

A new Copilot review identified four follow-ups after that successful run:

- Selectable JSON permits a copy path outside the explicit Copy action's
  locality and expiration settings.
- The first callback-rate window needs a consistent startup counter baseline.
- Troubleshooting information is hidden after acquisition stops.
- Microphone-watchdog integration needs targeted regression coverage.

The corrections now disable JSON selection, retain the troubleshooting shortcut
after a stall, and baseline the first rate window against the callbacks already
observed during startup. Five model regressions cover that baseline, absent
input, late-input processing grace, healthy real ring/DSP flow, and processing
that stops while input callbacks continue. A supplied clock and recording audio
adapter exercise the production model's watchdog/stop path without opening
hardware; production permission and explicit-start rules are unchanged.

The amended source requires its own exact-candidate native CI run before merge
or upload; the successful `722ee840` run does not validate these later changes.

## Final candidate and delivery

The latest verified source is `722ee840ae8f72d01cec0a3016fa8f52320726c4`.
The subsequent review corrections remain the release gate. Record their final
source SHA, actual CI results, inspected captures and run URL before merging or
dispatching distribution; do not substitute an earlier commit's pass.

No 0.2.1 (3) upload has been dispatched at this checkpoint. A read-only
App Store Connect check at `2026-11-08T01:43:07Z` found only 0.2.0 (2), processed
as VALID. It confirmed the existing internal tester group and existing API
credential access without creating a new key or a cleartext key file.

Physical microphone/tone behavior, interruptions/routes, acoustic sensitivity,
calibration and the original user-reported defect remain unverified. The
smallest next device experiment is a short explicit LIVE run followed by Stop
and Copy Diagnostic Dump, comparing input callbacks/samples, processing,
spectrum, renderer completions, timing validity and stop reason.

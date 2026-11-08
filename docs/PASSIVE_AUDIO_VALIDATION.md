# Passive audio candidate 0.2.2 (4): evidence record

## Current checkpoint

Final G1 source `222caea29b040063658cad2288b2e02726d02c73` passed native
validation, 68 core tests, 34 hosted tests and 10 separate Python recognition
tests. All four captures passed readiness and were visually inspected. PR #4
merged into main at `dff7c9f7fa99e1df07d8844f7546427119eb1a9e`; all 133
tracked blob hashes and file modes match the tested source. The single
TestFlight run for **0.2.2 (4)** succeeded: signing, Apple validation and upload
passed. App Store Connect confirmed build **0.2.2 (4)** as VALID and the upload
COMPLETE at `2026-11-08T03:51:37Z`. Tester access is blocked and physical G1 is
unobserved.
The failed attempts below remain part of the record.

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

- G0 diagnostic foundation: PR #3, final source
  `d4903b847e610761a4d9c7f94ee58e889a4d6d31`, merged into main at `3f7716`.
- G1 review: [PR #4](https://github.com/timelabs-npo/Rhea-RF-Spanner/pull/4).
  The first native-verified source is
  `f8d1eed0aaf3f2d8e195bdd2424f183d0b472c03`; later amendments require their
  own exact-source validation.
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

## First G1 native run

[Run 42438775739](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42438775739)
**succeeded** for source `f8d1eed0aaf3f2d8e195bdd2424f183d0b472c03`.
The retrieved logs record **68 core tests and 33 Simulator-hosted tests, with
zero failures**. The hosted suites comprise 10 DiagnosticsIntegration,
10 ObservatoryRenderer, 2 ObservatorySession, 4 PassiveAcquisition and
7 PassivePresentation tests. Core Release, Simulator Debug and unsigned device
Release builds passed. A hosted-test headermap warning was nonfatal.

Artifact ID: `13600767219`; name:
`rhea-rf-spanner-build-463462c20603b10e498edd5389832a8d0eb9fd86`; SHA-256:
`9b5fff5e4564eedafda88abc0fc7c721829b5719eca8558e6798a5ee2470573b`.
Its name identifies the PR merge SHA; the reviewed source head for this run is
the `f8d1eed0` commit above. The reported artifact expiry is **2026-11-15**.

Four native PNGs were generated. Visual inspection found the idle PNG black
except for the status bar. The DEMO Diagnostics PNG showed healthy processing,
approximately −23 dBFS RMS, peak 0.1034, zero microphone callbacks and the app
tone gate disabled. These are synthetic-mode observations. The idle image does
not verify a working idle screen; a cold-launch capture race versus an app
startup defect remains unresolved. That finding prompted the capture-readiness
work recorded below.

A subsequent Copilot review identified missing timing flags in the diagnostic
report. That correction and capture-readiness work are not covered by the
successful `f8d1eed0` run. Those amendments needed their own native evidence
before merge or distribution. No 0.2.2 (4) upload had been dispatched at that
checkpoint.

The amendment forwards both observed timing flags through Tone diagnostics and
adds a ring-to-analysis-to-JSON regression distinguishing unavailable timestamps
from an internal sample gap. Native capture now keeps idle as the first launch
and uses Apple's Vision text recognition on actual screenshots. Multiple
source/view-specific labels must appear within 45 seconds of launch; status-bar
pixels and PNG byte size cannot pass this gate. Each attempt retains elapsed
time, recognized labels and missing labels, plus the first and latest image.
The helper is compiled before launching the app. This detects delayed or absent
UI; it does not establish a cause for the earlier blank capture or a device
startup-performance result. Native helper compilation and the new captures were
pending at that amendment; the subsequent run is recorded below.

## Visible-content run and layout finding

[Run 42440335553](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42440335553)
tested amendment `3633e980c0c42e9a00259593c96a7341514d664f`. It passed
68 core tests, Core Release, Simulator Debug, unsigned device Release and
native Vision-helper compilation. The overall run **failed at the capture
gate**; hosted tests did not execute after that failure.

The first idle attempt was not ready. The next actual idle PNG, captured
11.034 seconds after launch began, contained the app; recognition completed at
14.146 seconds. These timings include CI/screenshot/OCR work and are not a
physical-device launch benchmark. Visual inspection found the Listen screen's
controls and consent content pushing the primary Start action below the screen.
The layout therefore requires correction, despite its successful label check.

The DEMO Field capture showed synthetic processing and a visible Stop action,
but the gate required `SYNTHETIC FIELD`, a caption deliberately hidden while
the controls were open. It failed after 45 seconds. The next amendment must
correct the layout and check actual visible source/presentation evidence,
including the idle primary action. It must not accept either a blank screen
or a hidden primary action merely because launch succeeded.

Failure artifact: `13600519872`, SHA-256
`f42f59d88abfd69ece833aee859aff24d8d62a87dae0e1d3766e34f59f6b7386`.
The first/final PNGs, recognized labels and timings remain in its manifest.

The following layout amendment moves Start/Stop into a bottom safe-area dock
outside the scrollable content, keeps the Listen action centered, and allows
long controls, consent and status text to scroll. Field uses an immersive layout
only when its content fits. The scientific presentation caption follows the
input readout and remains visible while controls are open. The capture gate now
requires a standalone `START LISTENING` label for idle and `STOP` for DEMO.
Per-line recognition prevents unrelated source and selector text from combining
into a false caption match. The two attempts below tested that layout amendment;
neither earlier run validates it.

## Layout candidate: two attempts with distinct failure evidence

[Run 42441531458](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42441531458)
tested public source `d371a6df323ee502c5a724d62f50ae070c813c85`.
Both attempts passed **68 core tests**, Core Release, Simulator Debug and
unsigned device Release compilation. Both failed before the hosted test suite
could execute. The successful earlier hosted suite at `f8d1eed0` is retained
as historical evidence, not attributed to this source.

### Attempt 1: launch command timeout before screenshots

Job `128611599094` timed out in `simctl launch` after **45 seconds**, before
any screenshot was captured. Cleanup also timed out after **10 seconds**.
The original launch/cleanup cause remains unresolved; there is no screenshot
from this attempt establishing whether the app's UI appeared.

Artifact `13601584618`, SHA-256
`2661f98ad61896412d069a6a497eb653b2110a880f8b6da249d424b3a0066269`,
was archived on WD under `ci-42441531458-attempt1`.

### Attempt 2: visible idle UI, wrapped action missed by OCR

Job `128613161631` launched and produced screenshots. From the recorded OCR
check at **7.052 seconds** onward, the only missing required label was
`START LISTENING`: the actual button label wrapped onto two lines, which the
single-line action matcher did not accept. The capture gate still failed at
**45 seconds**, so hosted tests **did not run**.

The coordinator visually inspected the final `01-idle.png`. The app UI was
present and the primary Start action was fully visible in the bottom dock.
The screen showed **LIVE Listen**, **MIC OFF**, acquisition not started and a
hatched spectrum. This is an observed idle Simulator layout, not live
microphone evidence or a complete acceptance of every screen. The recorded
times include CI, screenshot and OCR work; they are not device startup or
processing-performance measurements.

Artifact `13602585968`, SHA-256
`f6a03890b7129071e40315c9281a5fd0aafcaac1fd80ca211d2473cb26df04d8`,
was preserved on WD under `ci-42441531458-attempt2`.
Both attempts' artifacts were retained under distinct IDs despite sharing an
artifact name. The IDs and separate archive directories preserve their identity.

### Capture-tooling correction

The subsequent amendment changed capture tooling, artifact naming and focused
Python tests. It added strict bounding-box-aware recognition of a wrapped action
label, bounded failure evidence and names that distinguish run attempts.
Unrelated words, a hidden action and a blank screen still cannot satisfy the
gate. Its exact-source execution follows; the earlier core/build successes and
one inspected idle PNG were not substituted for that run.

## Final native run, visual acceptance and merge

[Run 42443019975](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42443019975),
attempt **1**, job **128616065718**, **succeeded** for public source
`222caea29b040063658cad2288b2e02726d02c73`.

| Check | Actual result |
| --- | --- |
| Core suite | 68 tests, 0 failures |
| Simulator-hosted suite | 34 tests, 0 failures: 11 DiagnosticsIntegration, 10 renderer, 2 session, 4 PassiveAcquisition and 7 PassivePresentation |
| Capture-recognition tests | 10 Python tests passed; counted separately from Swift tests |
| Core Release | Passed |
| Simulator Debug / unsigned device Release | Both passed |
| Native Swift Vision helper | Compilation passed |
| Four required captures | Complete manifest; each passed on its first screenshot-recognition attempt; all four PNGs visually inspected by the coordinator |

The inspected images and recorded timings were:

| Capture | Observed content | Readiness elapsed (s) | Launch-command return (s) |
| --- | --- | ---: | ---: |
| Idle | Fully visible **Start listening**; LIVE Listen; MIC OFF; acquisition not started; hatched missing spectrum | 11.101 | 1.289 |
| DEMO Field | Visible **SYNTHETIC FIELD** caption and Stop action; synthetic RMS approximately −23 dBFS, peak 0.1052 FS | 13.867 | 1.143 |
| DEMO Waterfall | Actual synthetic sample spectrum with frequency/time axes and visible Stop action | 14.763 | 1.550 |
| DEMO Diagnostics | Healthy running DEMO; app tone gate No; microphone callbacks 0; RMS approximately −23 dBFS, peak 0.1057 FS | 18.081 | 1.018 |

Readiness includes CI, screenshot and OCR work. Launch-command return is a
different event; neither column measures physical-device startup or acoustic
processing latency. The successful sequence verifies this candidate's tested
Simulator UI and fixtures. It does not establish the original cause of the
earlier launch timeout or physical microphone operation.

Artifact ID: `13602418489`; name:
`rhea-rf-spanner-build-68044aaac4877d4d5d56c099068a2d94b06c65e8-attempt-1`;
SHA-256:
`a4cd2be370597dd6d7eea37b271bf427861bdbed12ff441c49bed71ab1d0a5ca`.
The artifact name uses the PR merge SHA; tested source head is `222caea2` above.
Reported expiry is **2026-11-15**. The actual download and hash were verified
on WD at `C:\Users\wheel\RheaWork\ci-42443019975`.

Separate CodeQL checks for Python and GitHub Actions succeeded. PR #4 merged
into main at `dff7c9f7fa99e1df07d8844f7546427119eb1a9e`. The coordinator
verified all **133 tracked blob hashes and modes** against tested source
`222caea29b040063658cad2288b2e02726d02c73`. The G2 spatial-context draft is
separate and is not part of this G1 release.

## Distribution checkpoint

The **0.2.2 (4)** TestFlight workflow was dispatched **once** as
[run 42443912311](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42443912311)
and **succeeded**. Validation job **128618729126** and signing/upload job
**128618751852** both succeeded. Local signature/profile checks and Apple
validation passed; the upload was accepted.

The release manifest identifies source
`222caea29b040063658cad2288b2e02726d02c73`, workflow commit
`dff7c9f7fa99e1df07d8844f7546427119eb1a9e`, version **0.2.2**, build **4**,
**Xcode 26.3 (Build 17C529)** and **SDK 26.2**. Actual payload hashes were
independently checked against the manifest:

| Payload | SHA-256 |
| --- | --- |
| Signed IPA | `c709915d998af085143af44fbf8b5500eecce549e70ae875d97d0f3820984327` |
| Archive ZIP | `51de36baed11c115797e2a284c414ddb84864202a71ecae2a38418b127060068` |

Distribution artifact ID: `13602429233`; name:
`rhea-testflight-222caea29b040063658cad2288b2e02726d02c73-build-4`;
SHA-256:
`d230f9626b1e0e87f8fce8aed2e0be513f40c3a36190747e03e142c6ded46662`.
Reported expiry is **2026-11-11**. The artifact was downloaded and its hash
verified on WD at `C:\Users\wheel\RheaWork\release-0.2.2-4`.

A direct App Store Connect observation at `2026-11-08T03:48:16Z`
(06:48:16 Europe/Moscow) found upload
`4f5ba9b4-32e9-4189-9658-62cec90fb8ff`, version **0.2.2**, build **4**, in
**PROCESSING**, with `errors: []` and `warnings: []`. It had not yet appeared in
the builds list at that observation.

The next direct protected read-only App Store Connect observation, at
`2026-11-08T03:51:37Z` (06:51:37 Europe/Moscow), confirmed:

| Apple record | Observed value |
| --- | --- |
| Build ID | `4f5ba9b4-32e9-4189-9658-62cec90fb8ff` |
| Build number | `4` |
| Pre-release version ID | `3fade264-4944-4c1d-acf1-c56b85e0a865` |
| Pre-release version / platform | `0.2.2` / `IOS` |
| Build processing state | `VALID` |
| Upload ID / state | `4f5ba9b4-32e9-4189-9658-62cec90fb8ff` / `COMPLETE` |
| Upload messages | `errors: []`, `warnings: []`, `infos: []` |

This confirms upload and Apple processing for **0.2.2 (4)**. It does not
establish tester availability, physical-device acceptance or App Store review
approval. Do not duplicate the completed upload.

Tester-group assignment remains blocked. Automatic approval review rejected
the access grant because the upload authorization did not explicitly cover the
recipient access scope. Do not retry assignment without explicit authorization
for that access. No physical G1 installation or measurement has been observed.

## Software validation gates

| Boundary | Required evidence | Current status |
| --- | --- | --- |
| Portable analysis | Known digital input, levels, FFT scale/peak, variable callback partitions, gaps/drops, invalid time and nonfinite input; no tone result in Listen | 68 core tests passed at `222caea2` |
| Capture adapter | Synthetic PCM through the production CaptureContext, ring and consumer; captured-duration cap independent of source callbacks | Hosted fixtures passed at `222caea2`; physical capture unobserved |
| Model lifecycle | Explicit Listen start without output consent, real ring/DSP delivery, no phase/Replay, captured duration and retained stop evidence | Hosted fixtures passed at `222caea2`; physical lifecycle unobserved |
| Renderer | Uploaded texture values, display-only parameters, missing intervals, rewound/current-missing frames and recovery | Hosted regressions passed at `222caea2`; four idle/DEMO captures inspected |
| Audio graph | Input-only policy and source guards; no source node, output-node access or speaker override on Listen branch | Source review and policy fixtures passed; actual AVAudioEngine startup/cleanup instrumentation and physical graph behavior remain unexecuted |
| Native build | Core Release, Simulator Debug and unsigned device Release | Passed at `222caea2` |
| Visible content and hosted suite | Source/presentation/action readiness, visual inspection and hosted tests | All four capture gates passed and PNGs were inspected; 34 hosted tests passed; 10 separate Python recognition tests passed |
| Distribution | Reviewed main ancestor, signed archive/export and Apple validation/upload/processing | G1 merged with 133 matching tracked blobs/modes; single run 42443912311 succeeded; signature/profile and Apple validation passed, actual IPA/archive hashes verified. Apple build VALID / upload COMPLETE at 2026-11-08T03:51:37Z, with empty errors/warnings/infos |
| Tester access and device acceptance | Authorized group association, installation and a physical diagnostic trace | Access assignment blocked pending explicit authorization; physical G1 unobserved |

Keep each source SHA, test count, run/artifact identity and inspected capture
together. A prior pass does not validate a later amendment. A digital fixture
does not establish a working physical microphone, acoustic sensitivity or
calibration.

## Smallest phone experiment

After authorized tester access and installation, open **LIVE → Listen**, grant
microphone permission if requested, then explicitly
start. Observe input callbacks, accepted samples, RMS/peak, spectrum frames and
GPU completions. Compare quiet and ordinary audible sound without interpreting
dBFS as dB SPL. Stop and inspect the retained report. If a route/format/startup
failure occurs, preserve that report rather than repeatedly restarting without
evidence. Confirm interruption/background stopping and a fresh explicit start.

AR, camera, LiDAR, external radio probes and inter-phone synchronization remain
future gates in the [project roadmap](project/ROADMAP.md).

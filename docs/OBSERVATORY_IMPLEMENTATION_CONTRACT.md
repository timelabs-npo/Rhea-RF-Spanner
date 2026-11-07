# Observatory V2 implementation contract

This work is scoped only to `timelabs-npo/Rhea-RF-Spanner`, based on
`7e9cd8ecc38601555be7419a114cb4ab46bafc7d`. It is unrelated to Rhea v2.

## Agreed slice

- Native Swift 6 / iOS 18+ app, professional camera-inspired overlays.
- LIVE microphone, silent deterministic DEMO, in-memory REPLAY.
- Carrier grid: 18,000 through 22,000 Hz inclusive, step 500, actual 48 kHz input.
- Integer carrier phase addressing modulo 96; no claim of zero floating-point error.
- Frequency changes start a new acquisition/reference epoch. No phase continuity claim across different carriers.
- Display gain and persistence do not enter acquisition or simulation parameters.
- Spectrum waterfall is computed from samples, with frequency and time axes. A synthetic spatial field is explicitly labelled DEMO; LIVE rings remain abstract phase graphics.
- Pose and LiDAR are unavailable in this slice; never substitute origin coordinates or a fake distance.
- 64 bytes is the explicit versioned wire encoding, not Swift struct stride.
- Replay has 2,048 slice records; optional spectra are separate bounded companion data. Original measurement/simulation provenance is retained on replay.

## Shared APIs (root owns ObservatoryTypes.swift, SpatioTemporalSlice.swift, ReplayTape.swift)

`ObservationSource: UInt8, Sendable` cases `.microphone`, `.simulated`.
`ObservatoryMode: String, CaseIterable, Sendable` cases `.live`, `.demo`, `.replay`.
`ObservatoryPresentation: String, CaseIterable, Sendable` cases `.field`, `.waterfall`.
`DisplayParameters: Sendable, Equatable` fields `gainDB: Float = 0`, `persistence: Float = 0.65`, `palette: ObservatoryPalette = .aurora`.
`ObservatoryPalette` cases `.aurora`, `.thermal`, `.monochrome`.
`CarrierGrid.frequencies: [Int]`, `.isSupported(_ frequency: Int) -> Bool`.
`SimulationParameters: Sendable, Equatable` fields `amplitude: Double = 0.1`, `snrDB: Double = 30`, `displacementMeters: Double = 0.001`, `motionFrequencyHz: Double = 0.25`, `seed: UInt64 = 0x52484541`.

Core worker owns `SpectrumFrame: Sendable` with `sampleTimestamp: UInt64`, `frequenciesHz: [Float]`, `magnitudesDBFS: [Float]` and public initializer.
Core worker exposes `PhaseSensingEngine.latestSpectrum: SpectrumFrame?`, populated for each finite, validly timed analysis frame; unavailable for nonfinite data, missing capture clocks, or an intra-frame gap.
Core worker adds `SyntheticSignalGenerator(configuration: RadarConfiguration, parameters: SimulationParameters = .init())` and `generate(into: UnsafeMutablePointer<Float>, count: Int, startSampleTime: UInt64)`; single-consumer use only. No UI access, hardware or audio session.

`SpatioTemporalSlice` fields: `sampleTimestamp: UInt64`, `unwrappedPhase: Float?`, `normalizedAmplitude: Float`, `coherenceSNR: Float`, `carrierFrequencyHz: Float`, `sensorPosition: SIMD3<Float>?`, `sensorForward: SIMD3<Float>?`, `lidarDepthMeters: Float?`, `qualityScore: Float`, `epoch: UInt32`, `source: ObservationSource`, `validity: PhaseValidity`, `didRebaseline: Bool`, `discontinuityDetected: Bool`. Computed `isPhaseCoherent`. Factory `init(frame: PhaseTelemetryFrame, source: ObservationSource, carrierFrequencyHz: Int, epoch: UInt32)`.
`encoded() -> Data`, `init(encoded: Data) throws`, `encodedByteCount == 64`. Missing spatial data uses presence flags, never measured zero. Quality score is a labelled heuristic, not a confidence probability.

`ReplayTape(capacity: Int = 2048)` reference type; main-actor/serial owner only. `count: Int`, `capacity: Int`, `append(_ slice: SpatioTemporalSlice, spectrum: SpectrumFrame? = nil)`, `slice(at index: Int) -> SpatioTemporalSlice?`, `spectrum(at index: Int) -> SpectrumFrame?`, `removeAll()`, `encodedFrames() -> Data`. Logical indices oldest-first; overwrite oldest when full.

Renderer worker owns `ObservatoryCanvas: UIViewRepresentable` inputs `slice: SpatioTemporalSlice?`, `spectrum: SpectrumFrame?`, `history: [SpectrumFrame]`, `display: DisplayParameters`, `presentation: ObservatoryPresentation`, `active: Bool`, `reduceMotion: Bool`.

## File ownership during parallel work

- Core: PhaseSensingEngine.swift, SineOscillator.swift if needed, new SpectrumAnalyzer.swift/SyntheticSignalGenerator.swift, core numeric tests. Preserve existing weighted least-squares correctness and loss gates.
- UI/session: ExperimentModel.swift, ExperimentView.swift, AudioTransceiver.swift, PrivacyMethodView.swift if needed. No renderer/core edits. Expose all controls with truthful semantics.
- Renderer: MetalPhaseRenderer.swift, PhaseShaders.metal. No model/core edits.
- Root: types/codec/replay, Xcode project generation, CI, documentation, integration and verification.

The reference screenshots show a visual style only. No assertion is made about Final Cut Camera internals or that false colors measure temperature.

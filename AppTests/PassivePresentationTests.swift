import Foundation
import MetalKit
import RheaRFCore
import XCTest
@testable import RheaRFSpanner

/// App-hosted digital fixtures and silent DEMO lifecycle checks. No test in
/// this class requests microphone permission or creates a live audio session.
@MainActor
final class PassivePresentationTests: XCTestCase {
    private let hop = UInt64(RadarConfiguration.standard.frameSize)

    private func inputFrame(
        engine: PhaseSensingEngine, ring: SPSCFloatRingBuffer,
        at timestamp: UInt64, timestampIsValid: Bool = true, amplitude: Double = 0.25
    ) throws -> AudioAnalysisFrame {
        let samples = (0..<2_048).map {
            Float(amplitude * sin(2 * .pi * Double(40 * $0) / 2_048))
        }
        samples.withUnsafeBufferPointer {
            XCTAssertTrue(ring.write(
                from: $0.baseAddress!, count: $0.count, startSampleTime: timestamp,
                timestampIsValid: timestampIsValid
            ))
        }
        return try XCTUnwrap(engine.processNextAnalysisFrame())
    }

    private func show(
        _ frame: AudioAnalysisFrame, history: [SpectrumFrame],
        renderer: MetalPhaseRenderer, view: MTKView,
        display: DisplayParameters = DisplayParameters(), active: Bool = true
    ) {
        // A synthetic fixture is explicitly labelled synthetic even though it
        // exercises the same no-tone result path as passive capture.
        renderer.update(
            view: view, slice: nil, spectrum: frame.spectrum, history: history,
            display: display, presentation: .waterfall, active: active,
            reduceMotion: true,
            audioIdentity: AudioFrameIdentity(
                sampleTimestamp: frame.sampleTimestamp, runID: 1,
                source: .simulated, acquisitionKind: frame.acquisitionKind
            )
        )
    }

    func testPassiveCoreFrameReachesWaterfallWithoutSliceAndDisplayChangesPreserveDBFS() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring, acquisitionKind: .listen)
        let frame = try inputFrame(engine: engine, ring: ring, at: 0)
        XCTAssertNil(frame.tone)
        let spectrum = try XCTUnwrap(frame.spectrum)
        let view = MTKView(frame: .zero)
        let renderer = try MetalPhaseRenderer(view: view)
        show(frame, history: [spectrum], renderer: renderer, view: view)
        let original = renderer.copyWaterfallPixels()
        XCTAssertEqual(original.height, 1)
        XCTAssertTrue(original.pixels.allSatisfy { $0.y == 1 })
        XCTAssertEqual(try XCTUnwrap(original.pixels.map(\.x).max()), -12.0412, accuracy: 0.0001)
        XCTAssertEqual(view.accessibilityLabel, "Spectrum waterfall, 0 to 24 kilohertz")
        XCTAssertTrue(try XCTUnwrap(view.accessibilityValue).contains("Synthetic"))
        XCTAssertFalse(try XCTUnwrap(view.accessibilityValue).contains("Microphone data"))

        let display = DisplayParameters(
            gainDB: 24, persistence: 0.9, palette: .thermal, spectrumBand: .fullBand
        )
        show(frame, history: [spectrum], renderer: renderer, view: view, display: display, active: false)
        XCTAssertEqual(renderer.copyWaterfallPixels().pixels, original.pixels)
        XCTAssertEqual(frame.spectrum, spectrum)
        XCTAssertEqual(try XCTUnwrap(frame.inputStatistics.rms), 0.25 / sqrt(2), accuracy: 1e-8)
        XCTAssertNil(frame.tone)
        XCTAssertTrue(try XCTUnwrap(view.accessibilityValue).contains("Frozen"))
    }

    func testPassiveGapAndUntimedCurrentFrameStayMissingInUploadedTexture() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring, acquisitionKind: .listen)
        let first = try inputFrame(engine: engine, ring: ring, at: 0)
        let afterGap = try inputFrame(engine: engine, ring: ring, at: 2 * hop)
        let firstSpectrum = try XCTUnwrap(first.spectrum)
        let afterGapSpectrum = try XCTUnwrap(afterGap.spectrum)
        XCTAssertTrue(afterGap.timing.hasGapBeforeWindow)
        let view = MTKView(frame: .zero)
        let renderer = try MetalPhaseRenderer(view: view)
        let history = [firstSpectrum, afterGapSpectrum]
        show(afterGap, history: history, renderer: renderer, view: view)
        let gap = renderer.copyWaterfallPixels()
        XCTAssertEqual(gap.height, 3)
        XCTAssertEqual(gap.pixels.first?.y, 1)
        XCTAssertTrue(gap.pixels[gap.width..<2 * gap.width].allSatisfy { $0.y == 0 })
        XCTAssertEqual(gap.pixels.last?.y, 1)

        let untimed = try inputFrame(engine: engine, ring: ring, at: 3 * hop, timestampIsValid: false)
        XCTAssertFalse(untimed.timing.timestampsAreValid)
        XCTAssertNil(untimed.spectrum)
        XCTAssertNil(untimed.tone)
        show(untimed, history: history, renderer: renderer, view: view)
        let missingCurrent = renderer.copyWaterfallPixels()
        XCTAssertEqual(missingCurrent.height, 4)
        XCTAssertTrue(missingCurrent.pixels.prefix(missingCurrent.width).allSatisfy { $0.y == 0 })
        XCTAssertEqual(missingCurrent.pixels[missingCurrent.width].y, 1)

        let recovered = try inputFrame(engine: engine, ring: ring, at: 4 * hop)
        let recoveredSpectrum = try XCTUnwrap(recovered.spectrum)
        show(recovered, history: history + [recoveredSpectrum], renderer: renderer, view: view)
        let recoveredImage = renderer.copyWaterfallPixels()
        XCTAssertEqual(recoveredImage.height, 5)
        XCTAssertEqual(recoveredImage.pixels.first?.y, 1)
        XCTAssertTrue(recoveredImage.pixels[recoveredImage.width..<2 * recoveredImage.width].allSatisfy { $0.y == 0 })
        XCTAssertEqual(recoveredImage.pixels.last?.y, 1)
    }

    func testPassiveDiagnosticsContainAggregateInputAndNoFictitiousTone() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring, acquisitionKind: .listen)
        let frame = try inputFrame(engine: engine, ring: ring, at: 0)
        let counters = SessionDiagnosticCounters()
        counters.recordProcessedAnalysisFrame(frame)
        let snapshot = counters.snapshot(ring: ring, renderedSamples: 0, capturedSamples: hop)
        let dsp = try XCTUnwrap(snapshot.latestDSP)
        XCTAssertEqual(dsp.acquisitionKind, "listen")
        XCTAssertEqual(dsp.toneAnalysis, "not_requested")
        XCTAssertEqual(dsp.validity, "not_requested")
        XCTAssertNil(dsp.carrierAmplitude)
        XCTAssertNil(dsp.toneResidualDB)
        XCTAssertNil(dsp.relativePhaseRadians)
        XCTAssertEqual(dsp.timestampsAreValid, true)
        XCTAssertEqual(dsp.spectrumPeakHz, 937.5)
        XCTAssertEqual(try XCTUnwrap(dsp.spectrumPeakDBFS), -12.0412, accuracy: 0.0001)
        XCTAssertEqual(snapshot.processedFrames, 1)
        XCTAssertEqual(snapshot.spectrumFrames, 1)
        XCTAssertEqual(snapshot.sourceCallbacks, 0)
        XCTAssertEqual(snapshot.renderedSamples, 0)
        XCTAssertEqual(snapshot.capturedSamples, hop)
        XCTAssertEqual(snapshot.validPhaseFrames, 0)
        XCTAssertEqual(snapshot.lowSignalFrames, 0)
        XCTAssertEqual(snapshot.lowQualityFrames, 0)
        XCTAssertNotNil(snapshot.latestInput?.rms)

        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        for forbidden in ["rawSamples", "frequenciesHz", "magnitudesDBFS", "carrierAmplitude", "relativePhaseRadians"] {
            XCTAssertFalse(json.contains("\"" + forbidden + "\""))
        }
        let audio = AudioSessionDiagnosticSnapshot(configuration: .standard, acquisitionKind: .listen)
        XCTAssertEqual(audio.acquisitionKind, "listen")
        XCTAssertFalse(audio.transmitConfigured)
    }

    func testUntimedFractionalHopDoesNotBorrowHistoryForNewestWaterfallRow() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring, acquisitionKind: .listen)
        let first = try inputFrame(engine: engine, ring: ring, at: 0)
        let firstSpectrum = try XCTUnwrap(first.spectrum)
        let view = MTKView(frame: .zero)
        let renderer = try MetalPhaseRenderer(view: view)
        show(first, history: [firstSpectrum], renderer: renderer, view: view)

        // The capture index increases, so this is not a model-history reset.
        // The older spectrum is close enough for nearest-row selection, but
        // cannot stand in for the explicitly untimed current observation.
        let untimed = try inputFrame(
            engine: engine, ring: ring, at: 512, timestampIsValid: false
        )
        XCTAssertEqual(untimed.sampleTimestamp, 512)
        XCTAssertFalse(untimed.timing.timestampsAreValid)
        XCTAssertNil(untimed.spectrum)
        show(untimed, history: [firstSpectrum], renderer: renderer, view: view)
        let missing = renderer.copyWaterfallPixels()
        XCTAssertEqual(missing.height, 2)
        XCTAssertTrue(missing.pixels.prefix(missing.width).allSatisfy { $0.y == 0 })
        let older = missing.pixels.suffix(missing.width)
        XCTAssertTrue(older.allSatisfy { $0.y == 1 })
        XCTAssertEqual(try XCTUnwrap(older.map(\.x).max()), -12.0412, accuracy: 0.0001)
        show(untimed, history: [firstSpectrum], renderer: renderer, view: view, active: false)
        XCTAssertEqual(renderer.copyWaterfallPixels().pixels, missing.pixels)

        // A known Tone slice with absent spectrum uses the same missing-row
        // rule. Its presence must not cause old data to look newly measured.
        let toneRing = SPSCFloatRingBuffer()
        let toneEngine = PhaseSensingEngine(ringBuffer: toneRing, acquisitionKind: .tone)
        let toneFirst = try inputFrame(engine: toneEngine, ring: toneRing, at: 0)
        let toneMissing = try inputFrame(
            engine: toneEngine, ring: toneRing, at: 512, timestampIsValid: false
        )
        let slice = SpatioTemporalSlice(
            frame: try XCTUnwrap(toneMissing.tone), source: .simulated,
            carrierFrequencyHz: 20_000, epoch: 1
        )
        XCTAssertNil(toneMissing.spectrum)
        renderer.update(
            view: view, slice: slice, spectrum: nil,
            history: [try XCTUnwrap(toneFirst.spectrum)], display: DisplayParameters(),
            presentation: .waterfall, active: false, reduceMotion: true
        )
        let tonePixels = renderer.copyWaterfallPixels()
        XCTAssertEqual(tonePixels.height, 2)
        XCTAssertTrue(tonePixels.pixels.prefix(tonePixels.width).allSatisfy { $0.y == 0 })
        XCTAssertTrue(tonePixels.pixels.suffix(tonePixels.width).allSatisfy { $0.y == 1 })
    }

    func testPassiveClockRewindDoesNotResurrectAMissingCurrentSpectrum() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring, acquisitionKind: .listen)
        let first = try inputFrame(engine: engine, ring: ring, at: 0)
        let second = try inputFrame(engine: engine, ring: ring, at: hop)
        let third = try inputFrame(engine: engine, ring: ring, at: 2 * hop)
        let oldHistory = try [first, second, third].map { try XCTUnwrap($0.spectrum) }
        let view = MTKView(frame: .zero)
        let renderer = try MetalPhaseRenderer(view: view)
        show(third, history: oldHistory, renderer: renderer, view: view)
        XCTAssertEqual(renderer.copyWaterfallPixels().height, 3)

        let rewound = try inputFrame(
            engine: engine, ring: ring, at: hop, timestampIsValid: false
        )
        XCTAssertTrue(rewound.timing.hasGapBeforeWindow)
        XCTAssertNil(rewound.spectrum)
        XCTAssertNil(rewound.tone)
        // Even if stale history contains a previously valid observation at
        // this exact index, an explicitly missing current frame wins.
        show(rewound, history: oldHistory, renderer: renderer, view: view)
        let missing = renderer.copyWaterfallPixels()
        XCTAssertTrue(missing.pixels.prefix(missing.width).allSatisfy { $0.y == 0 })

        // The model clears its display history at a non-increasing capture
        // index. Rendering that boundary must also discard the old texture.
        show(rewound, history: [], renderer: renderer, view: view)
        let cleared = renderer.copyWaterfallPixels()
        XCTAssertEqual(cleared.height, 1)
        XCTAssertTrue(cleared.pixels.allSatisfy { $0.y == 0 })
        show(rewound, history: [], renderer: renderer, view: view, active: false)
        XCTAssertEqual(renderer.copyWaterfallPixels().pixels, cleared.pixels)

        let recovered = try inputFrame(engine: engine, ring: ring, at: 2 * hop, amplitude: 0.125)
        let recoveredSpectrum = try XCTUnwrap(recovered.spectrum)
        show(recovered, history: [recoveredSpectrum], renderer: renderer, view: view)
        let fresh = renderer.copyWaterfallPixels()
        XCTAssertEqual(fresh.height, 1)
        XCTAssertTrue(fresh.pixels.allSatisfy { $0.y == 1 })
        XCTAssertEqual(try XCTUnwrap(fresh.pixels.map(\.x).max()), -18.0618, accuracy: 0.0001)
        XCTAssertNil(recovered.tone)
    }

    func testListenIsOrdinaryIdleEntryAndSelectionsNeverStartSensors() {
        let model = ExperimentModel(arguments: [])
        model.setAppActive(true)
        defer { model.stopExperiment() }
        XCTAssertEqual(model.mode, .live)
        XCTAssertEqual(model.acquisitionKind, .listen)
        XCTAssertEqual(model.presentation, .waterfall)
        XCTAssertEqual(model.displayParameters.spectrumBand, .fullBand)
        XCTAssertFalse(model.phaseControlsAvailable)
        XCTAssertFalse(model.consentGiven)

        model.displayParameters.gainDB = 18
        model.displayParameters.palette = .thermal
        model.displayParameters.persistence = 0.9
        model.displayParameters.spectrumBand = .carrier
        model.setCarrierFrequency(20_500)
        XCTAssertEqual(model.acquisitionKind, .listen)
        XCTAssertEqual(model.carrierFrequencyHz, 20_000)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.replayCount, 0)

        model.selectAcquisitionKind(.tone)
        XCTAssertTrue(model.phaseControlsAvailable)
        XCTAssertFalse(model.consentGiven)
        XCTAssertEqual(model.state, .idle)
        model.consentGiven = true
        model.selectAcquisitionKind(.listen)
        XCTAssertFalse(model.consentGiven)
        XCTAssertEqual(model.presentation, .waterfall)
        XCTAssertEqual(model.displayParameters.spectrumBand, .fullBand)
        model.resetPhaseReference()
        model.refreshDiagnostics() // Inspecting diagnostics must not acquire.
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.microphoneIsActive)
        XCTAssertNil(model.latestSlice)
        XCTAssertNil(model.latestFrame)
        XCTAssertNil(model.latestAudioIdentity)
        XCTAssertEqual(model.diagnosticSnapshot.session.acquisitionKind, "listen")
        XCTAssertFalse(model.diagnosticSnapshot.session.transmitEnabled)
        XCTAssertNil(model.diagnosticSnapshot.session.carrierHz)
        XCTAssertNil(model.diagnosticSnapshot.session.referenceEpoch)
        XCTAssertNil(model.diagnosticSnapshot.session.runID)
        XCTAssertEqual(model.diagnosticSnapshot.pipeline.inputCallbacks, 0)
        XCTAssertEqual(model.diagnosticSnapshot.pipeline.sourceCallbacks, 0)
    }

    func testChangingAcquisitionSelectionEndsSilentRunAndRequiresAnotherStart() async throws {
        let model = ExperimentModel(arguments: [])
        defer { model.stopExperiment() }
        model.setAppActive(true)
        model.selectAcquisitionKind(.tone)
        model.selectMode(.demo)
        model.startExperiment()
        for _ in 0..<160 {
            if model.replayCount >= 2 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(model.isRunning)
        XCTAssertGreaterThanOrEqual(model.replayCount, 2)
        XCTAssertEqual(model.latestSlice?.source, .simulated)
        model.selectAcquisitionKind(.listen)
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.microphoneIsActive)
        for _ in 0..<160 {
            if !model.isFinishingProcessing { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(model.isFinishingProcessing)
        let stoppedCount = model.replayCount
        model.setAppActive(false)
        model.setAppActive(true)
        model.refreshDiagnostics()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.replayCount, stoppedCount)
        XCTAssertNil(model.latestFrame)
        XCTAssertNil(model.latestSlice)
        XCTAssertNil(model.latestAudioIdentity)
        XCTAssertFalse(model.diagnosticSnapshot.session.transmitEnabled)
        XCTAssertEqual(model.diagnosticSnapshot.session.captureSource, "simulated")
        XCTAssertEqual(model.diagnosticSnapshot.session.acquisitionKind, "tone",
                       "Retained DEMO diagnostics preserve the completed run's immutable intent")
    }
}

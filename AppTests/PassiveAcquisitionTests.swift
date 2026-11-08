import AVFAudio
import Foundation
import RheaRFCore
import Synchronization
import XCTest
@testable import RheaRFSpanner

/// Deterministic graph decisions and input-tap fixtures, never live hardware.
final class PassiveAcquisitionTests: XCTestCase {
    private final class AnalysisProbe: Sendable {
        let value = Mutex<(frame: AudioAnalysisFrame?, stopped: Bool)>((nil, false))
    }

    func testListenGraphRequiresOnlyBuiltInInputAndNeverSelectsTransmission() {
        let listen = AudioGraphPlan(acquisitionKind: .listen)
        XCTAssertEqual(listen.category, .record)
        XCTAssertEqual(listen.mode, .measurement)
        XCTAssertTrue(listen.options.isEmpty)
        XCTAssertFalse(listen.transmitEnabled,
                       "Production guards both speaker override and tone construction with this decision")
        XCTAssertTrue(listen.acceptsActiveRoute(inputPortTypes: [.builtInMic], outputPortTypes: []))
        XCTAssertTrue(listen.acceptsActiveRoute(inputPortTypes: [.builtInMic], outputPortTypes: [.bluetoothA2DP]))
        XCTAssertFalse(listen.acceptsActiveRoute(inputPortTypes: [], outputPortTypes: [.builtInSpeaker]))
        XCTAssertFalse(listen.acceptsActiveRoute(inputPortTypes: [.usbAudio], outputPortTypes: []))

        let tone = AudioGraphPlan(acquisitionKind: .tone)
        XCTAssertEqual(tone.category, .playAndRecord)
        XCTAssertEqual(tone.mode, .measurement)
        XCTAssertEqual(tone.options, [.defaultToSpeaker])
        XCTAssertTrue(tone.transmitEnabled)
        XCTAssertTrue(tone.acceptsActiveRoute(inputPortTypes: [.builtInMic], outputPortTypes: [.builtInSpeaker]))
        XCTAssertFalse(tone.acceptsActiveRoute(inputPortTypes: [.builtInMic], outputPortTypes: []))
        XCTAssertFalse(tone.acceptsActiveRoute(inputPortTypes: [.builtInMic], outputPortTypes: [.bluetoothA2DP]))
    }

    func testCapturedProgressCountsDroppedVariableBuffersWithoutAnyOutputProgress() throws {
        let control = ExperimentControl()
        let counters = SessionDiagnosticCounters()
        let ring = SPSCFloatRingBuffer(capacity: 8)
        let capture = CaptureContext(ring: ring, control: control, diagnostics: counters,
                                     configuration: .standard, maximumSamples: 16)
        control.audioEnabled.store(true, ordering: .releasing)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                channels: 1, interleaved: false))
        func deliver(_ length: AVAudioFrameCount, at sample: AVAudioFramePosition) throws {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length))
            buffer.frameLength = length
            try XCTUnwrap(buffer.floatChannelData)[0].update(repeating: 0.25, count: Int(length))
            capture.receive(buffer, at: AVAudioTime(sampleTime: sample, atRate: 48_000))
        }

        try deliver(3, at: 500)
        try deliver(5, at: 503)
        try deliver(7, at: 508) // Full ring: accepted input is still acquired time.
        XCTAssertEqual(control.capturedSamples.load(ordering: .acquiring), 15)
        XCTAssertFalse(control.cancelled.load(ordering: .acquiring))
        try deliver(4, at: 515) // Only the remaining one sample is offered at the cap.
        XCTAssertEqual(control.capturedSamples.load(ordering: .acquiring), 16)
        XCTAssertEqual(control.syntheticSamples.load(ordering: .acquiring), 0)
        XCTAssertEqual(control.renderedSamples.load(ordering: .acquiring), 0)
        XCTAssertEqual(control.stopReason, .timeLimit)
        let snapshot = counters.snapshot(
            ring: ring, renderedSamples: 0,
            capturedSamples: control.capturedSamples.load(ordering: .acquiring)
        )
        XCTAssertEqual(snapshot.inputCallbacks, 4)
        XCTAssertEqual(snapshot.acceptedInputCallbacks, 4)
        XCTAssertEqual(snapshot.offeredSamples, 16)
        XCTAssertEqual(snapshot.enqueuedSamples, 8)
        XCTAssertEqual(snapshot.droppedWriteSamples, 8)
        XCTAssertEqual(snapshot.droppedWriteBlocks, 2)
        XCTAssertEqual(snapshot.sourceCallbacks, 0)
        XCTAssertEqual(snapshot.capturedSamples, 16)
        XCTAssertEqual(snapshot.renderedSamples, 0)
        XCTAssertEqual(snapshot.inputFramesMin, 3)
        XCTAssertEqual(snapshot.inputFramesMax, 7)
        XCTAssertEqual(snapshot.lastCaptureSampleIndex, 15)
    }

    func testStoppedCaptureDoesNotAdvanceAnyProducer() throws {
        let control = ExperimentControl()
        let counters = SessionDiagnosticCounters()
        let ring = SPSCFloatRingBuffer(capacity: 8)
        let capture = CaptureContext(ring: ring, control: control, diagnostics: counters,
                                     configuration: .standard, maximumSamples: 16)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        capture.receive(buffer, at: AVAudioTime(sampleTime: 0, atRate: 48_000))
        XCTAssertEqual(control.capturedSamples.load(ordering: .acquiring), 0)
        control.audioEnabled.store(true, ordering: .releasing)
        control.requestStop(.user)
        capture.receive(buffer, at: AVAudioTime(sampleTime: 4, atRate: 48_000))
        XCTAssertEqual(control.capturedSamples.load(ordering: .acquiring), 0)
        XCTAssertEqual(ring.availableToRead, 0)
        XCTAssertEqual(counters.ignoredInputCallbacks.load(ordering: .relaxed), 2)
        XCTAssertEqual(control.stopReason, .user)
    }

    func testSyntheticPCMInputReachesPassiveConsumerWithoutRendering() async throws {
        // Synthetic PCM goes through the actual capture adapter, ring and serial
        // consumer. No AVAudioEngine or physical microphone is started here.
        let processing = SignalProcessingSession(maximumSamples: 2_048, acquisitionKind: .listen)
        defer { processing.control.requestStop(.user) }
        let capture = CaptureContext(
            ring: processing.ring, control: processing.control, diagnostics: processing.diagnostics,
            configuration: processing.configuration, maximumSamples: processing.maximumSamples
        )
        let probe = AnalysisProbe()
        processing.startAnalysis(onFrame: { frame in
            probe.value.withLock { $0.frame = frame }
        }, onStopped: { _ in
            probe.value.withLock { $0.stopped = true }
        })
        processing.control.audioEnabled.store(true, ordering: .releasing)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                channels: 1, interleaved: false))
        var sampleOffset = 0
        for count in [127, 641, 1_280] {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for index in 0..<count {
                samples[index] = Float(0.25 * sin(2 * .pi * 40 * Double(sampleOffset + index) / 2_048))
            }
            capture.receive(buffer, at: AVAudioTime(sampleTime: AVAudioFramePosition(10_000 + sampleOffset),
                                                   atRate: 48_000))
            sampleOffset += count
        }
        for _ in 0..<160 {
            if probe.value.withLock({ $0.stopped }) { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let observed = probe.value.withLock { $0 }
        XCTAssertTrue(observed.stopped, "The captured sample cap must finish without source callbacks")
        let frame = try XCTUnwrap(observed.frame)
        XCTAssertEqual(frame.acquisitionKind, .listen)
        XCTAssertNil(frame.tone)
        XCTAssertEqual(frame.sampleTimestamp, 0)
        XCTAssertFalse(frame.timing.discontinuityDetected)
        XCTAssertEqual(try XCTUnwrap(frame.inputStatistics.rms), 0.25 / sqrt(2), accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(frame.inputStatistics.peak), 0.25, accuracy: 0.000_001)
        let spectrum = try XCTUnwrap(frame.spectrum)
        XCTAssertEqual(spectrum.frequenciesHz[40], 937.5, accuracy: 0.001)
        XCTAssertEqual(spectrum.magnitudesDBFS[40], -12.0412, accuracy: 0.001)
        XCTAssertEqual(processing.control.capturedSamples.load(ordering: .acquiring), 2_048)
        XCTAssertEqual(processing.control.syntheticSamples.load(ordering: .acquiring), 0,
                       "Injected PCM is not the DEMO generator")
        XCTAssertEqual(processing.control.renderedSamples.load(ordering: .acquiring), 0)
        XCTAssertEqual(processing.control.stopReason, .timeLimit)
        let pipeline = processing.diagnostics.snapshot(ring: processing.ring, renderedSamples: 0,
                                                      capturedSamples: 2_048)
        XCTAssertEqual(pipeline.processedFrames, 1)
        XCTAssertEqual(pipeline.spectrumFrames, 1)
        XCTAssertEqual(pipeline.sourceCallbacks, 0)
        XCTAssertEqual(pipeline.validPhaseFrames, 0)
        XCTAssertEqual(pipeline.lowSignalFrames, 0)
        XCTAssertEqual(pipeline.latestDSP?.toneAnalysis, "not_requested")
    }
}

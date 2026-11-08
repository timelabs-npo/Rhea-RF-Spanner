import Foundation
import RheaRFCore
import Synchronization
import XCTest
@testable import RheaRFSpanner

/// Real DEMO/DSP checks and model lifecycle fixtures. The LIVE fixtures replace
/// permission/audio hardware only; no test opens a microphone or speaker.
@MainActor
final class DiagnosticsIntegrationTests: XCTestCase {
    @MainActor
    private final class RecordingAudioSession: ExperimentAudioSession {
        let processing: SignalProcessingSession
        let startupCallbacks: Int
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private var snapshot: AudioSessionDiagnosticSnapshot
        private var nextSample: UInt64 = 0

        init(processing: SignalProcessingSession, startupCallbacks: Int) {
            self.processing = processing
            self.startupCallbacks = startupCallbacks
            snapshot = AudioSessionDiagnosticSnapshot(configuration: processing.configuration)
        }

        func start() throws {
            startCount += 1
            // Like the real adapter, startup can invoke the tap before its
            // audioEnabled gate opens. These remain lifetime evidence only.
            for _ in 0..<startupCallbacks {
                processing.diagnostics.recordInputCallback(frameCount: processing.configuration.frameSize)
                processing.diagnostics.ignoredInputCallbacks.wrappingAdd(1, ordering: .relaxed)
            }
            processing.control.audioEnabled.store(true, ordering: .releasing)
            snapshot.stage = "running"
            snapshot.engineIsRunning = true
            snapshot.activationSucceeded = true
        }

        func stop() {
            stopCount += 1
            processing.control.audioEnabled.store(false, ordering: .releasing)
            snapshot.stage = "stopped"
            snapshot.engineIsRunning = false
            snapshot.deactivationSucceeded = true
        }

        func diagnosticSnapshot() -> AudioSessionDiagnosticSnapshot { snapshot }

        /// Fault injection: input progress remains observable while no new
        /// analysis window reaches the consumer. This is not hardware evidence.
        func observeInputWithoutAnalysis() {
            let count = processing.configuration.frameSize
            processing.diagnostics.recordInputCallback(frameCount: count)
            processing.diagnostics.offeredSamples.wrappingAdd(UInt64(count), ordering: .relaxed)
            processing.diagnostics.acceptedInputCallbacks.wrappingAdd(1, ordering: .releasing)
        }

        /// Actual synthetic PCM flows through the production ring and worker.
        /// Constant input has a spectrum/level but no valid 20 kHz tone estimate.
        func deliverPCMFrame() {
            let count = processing.configuration.frameSize
            let samples = [Float](repeating: 0.25, count: count)
            processing.diagnostics.recordInputCallback(frameCount: count)
            processing.diagnostics.offeredSamples.wrappingAdd(UInt64(count), ordering: .relaxed)
            let enqueued = samples.withUnsafeBufferPointer {
                processing.ring.write(from: $0.baseAddress!, count: count, startSampleTime: nextSample)
            }
            XCTAssertTrue(enqueued)
            if enqueued {
                processing.diagnostics.enqueuedSamples.wrappingAdd(UInt64(count), ordering: .relaxed)
            }
            processing.diagnostics.acceptedInputCallbacks.wrappingAdd(1, ordering: .releasing)
            nextSample += UInt64(count)
        }
    }

    @MainActor
    private final class RuntimeFixture {
        var now: TimeInterval = 100
        var startupCallbacks = 0
        private(set) var audioSessions: [RecordingAudioSession] = []

        var runtime: ExperimentRuntime {
            ExperimentRuntime(
                clock: { self.now }, liveIsSupported: true,
                recordPermission: { .granted },
                requestRecordPermission: {
                    XCTFail("Granted fixture permission must not request system permission")
                    return false
                },
                makeAudio: { processing in
                    let audio = RecordingAudioSession(processing: processing, startupCallbacks: self.startupCallbacks)
                    self.audioSessions.append(audio)
                    return audio
                }
            )
        }
    }

    private func startLiveFixture(_ fixture: RuntimeFixture) throws -> (ExperimentModel, RecordingAudioSession) {
        let model = ExperimentModel(arguments: [], runtime: fixture.runtime)
        model.setAppActive(true)
        model.startExperiment()
        XCTAssertTrue(fixture.audioSessions.isEmpty, "The fixture must not bypass explicit LIVE consent")
        model.consentGiven = true
        model.startExperiment()
        let audio = try XCTUnwrap(fixture.audioSessions.first)
        XCTAssertEqual(model.state, .running)
        XCTAssertEqual(audio.startCount, 1)
        return (model, audio)
    }

    private func eventually(_ condition: @MainActor () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<160 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Diagnostic state did not arrive within four seconds", file: file, line: line)
    }

    private func startedDemo() async throws -> ExperimentModel {
        let model = ExperimentModel(arguments: [])
        model.setAppActive(true)
        model.selectMode(.demo)
        model.startExperiment()
        try await eventually { model.replayCount >= 4 }
        model.refreshDiagnostics()
        return model
    }

    func testDemoReportsObservedProcessingWithoutClaimingMicrophoneCapture() async throws {
        let model = try await startedDemo()
        defer { model.stopExperiment() }
        let snapshot = model.diagnosticSnapshot
        XCTAssertNil(snapshot.audio)
        XCTAssertEqual(snapshot.pipeline.inputCallbacks, 0)
        XCTAssertGreaterThanOrEqual(snapshot.pipeline.syntheticBlocks, 4)
        XCTAssertGreaterThanOrEqual(snapshot.pipeline.processedFrames, 4)
        XCTAssertGreaterThan(snapshot.pipeline.spectrumFrames, 0)
        XCTAssertEqual(snapshot.pipeline.health, "healthy")
        let input = try XCTUnwrap(snapshot.pipeline.latestInput)
        XCTAssertEqual(input.nonFiniteSampleCount, 0)
        XCTAssertGreaterThan(try XCTUnwrap(input.rms), 0)
        XCTAssertGreaterThan(try XCTUnwrap(input.peak), 0)
        XCTAssertFalse(model.microphoneIsActive)
    }

    func testUserStopRetainsTheEvidenceOfTheCompletedRun() async throws {
        let model = try await startedDemo()
        let frames = model.diagnosticSnapshot.pipeline.processedFrames
        model.stopExperiment()
        try await eventually { !model.isFinishingProcessing }
        model.refreshDiagnostics()
        let snapshot = model.diagnosticSnapshot
        XCTAssertEqual(snapshot.session.state, "idle")
        XCTAssertNotNil(snapshot.session.stopReason)
        XCTAssertGreaterThanOrEqual(snapshot.pipeline.processedFrames, frames)
        XCTAssertNotNil(snapshot.pipeline.latestInput)
        XCTAssertFalse(snapshot.events.isEmpty)
        let beforeRestart = try XCTUnwrap(snapshot.events.last?.elapsedSeconds)
        model.startExperiment()
        try await eventually { model.replayCount >= 4 && model.isRunning }
        model.refreshDiagnostics()
        let events = model.diagnosticSnapshot.events
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(events.last?.elapsedSeconds), beforeRestart)
        XCTAssertTrue(zip(events, events.dropFirst()).allSatisfy {
            $0.0.elapsedSeconds <= $0.1.elapsedSeconds
        }, "Retained event time must not restart or freeze at a prior run's stop")
        model.stopExperiment()
    }

    func testReportEncodesActualObservationsWithoutRawContentOrAbsoluteClocks() async throws {
        let model = try await startedDemo()
        defer { model.stopExperiment() }
        let renderer = RendererDiagnostics()
        let fixture = DiagnosticSelfTest.run()
        let report = ObservatoryDiagnosticReport(session: model.diagnosticSnapshot,
                                                renderer: renderer.snapshot(), selfTest: fixture)
        let json = try report.jsonString()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let snapshot = try XCTUnwrap(object["session"] as? [String: Any])
        let pipeline = try XCTUnwrap(snapshot["pipeline"] as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(pipeline["processedFrames"] as? Int), 0)
        XCTAssertNotNil(pipeline["latestInput"])
        XCTAssertNil(pipeline["processedFramesPerSecond"])
        XCTAssertNil(pipeline["observedInputCallbacksPerSecond"])
        let gpu = try XCTUnwrap(object["renderer"] as? [String: Any])
        XCTAssertNil(gpu["measuredCompletedFramesPerSecond"])
        XCTAssertNotNil(gpu["frameRateWindowSeconds"])
        let forbidden = Set(["systemUptime", "hostTime", "machTicks", "bootTime", "rawSamples",
                             "frequenciesHz", "magnitudesDBFS", "routeUID", "deviceIdentifier", "ssid"])
        func inspect(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                XCTAssertTrue(forbidden.isDisjoint(with: dictionary.keys))
                for child in dictionary.values { inspect(child) }
            } else if let array = value as? [Any] {
                for child in array { inspect(child) }
            } else if let number = value as? NSNumber {
                XCTAssertTrue(number.doubleValue.isFinite)
            }
        }
        inspect(object)
        XCTAssertTrue(fixture.passed)
    }

    func testSilentSelfTestMeasuresTheKnownPhaseStepAndSpectrum() throws {
        let result = DiagnosticSelfTest.run()
        XCTAssertEqual(result.processedFrames, 2)
        XCTAssertEqual(result.carrierHz, 20_500)
        XCTAssertTrue(result.passed)
        let phase = try XCTUnwrap(result.checks.first { $0.name == "Relative phase step" })
        XCTAssertEqual(try XCTUnwrap(phase.observed), 0.5, accuracy: 0.000_01)
        let frequency = try XCTUnwrap(result.checks.first { $0.name == "FFT peak frequency" })
        XCTAssertEqual(try XCTUnwrap(frequency.observed), 20_500, accuracy: 11.71875)
        XCTAssertNoThrow(try JSONEncoder().encode(result))
    }

    func testInitialRateWindowExcludesCallbacksThatArrivedDuringAudioStartup() throws {
        let fixture = RuntimeFixture()
        fixture.startupCallbacks = 7
        let (model, audio) = try startLiveFixture(fixture)
        defer { model.stopExperiment() }
        fixture.now = 100.5
        audio.observeInputWithoutAnalysis()
        audio.observeInputWithoutAnalysis()
        model.refreshDiagnostics()
        let pipeline = model.diagnosticSnapshot.pipeline
        XCTAssertEqual(pipeline.inputCallbacks, 9, "Lifetime count must retain startup callbacks")
        XCTAssertEqual(pipeline.ignoredInputCallbacks, 7)
        XCTAssertEqual(pipeline.acceptedInputCallbacks, 2)
        XCTAssertEqual(pipeline.inputCallbacksInWindow, 2)
        XCTAssertEqual(try XCTUnwrap(pipeline.samplingWindowElapsedSeconds), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(pipeline.observedInputCallbacksPerSecond), 4, accuracy: 1e-9)
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(audio.stopCount, 0)
    }

    func testMissingLiveInputStopsAtDeadlineAndRetainsOneStopReportWithoutRestarting() async throws {
        let fixture = RuntimeFixture()
        let (model, audio) = try startLiveFixture(fixture)
        defer { model.stopExperiment() }
        let runID = try XCTUnwrap(model.diagnosticSnapshot.session.runID)
        fixture.now = 101.99
        XCTAssertTrue(model.monitorAcquisition())
        XCTAssertEqual(model.diagnosticSnapshot.pipeline.health, "waitingForInput")

        fixture.now = 102
        model.refreshDiagnostics()
        XCTAssertEqual(model.diagnosticSnapshot.pipeline.health, "inputStalled")
        XCTAssertTrue(model.isRunning, "Inspecting/copying diagnostics must not stop acquisition")
        XCTAssertEqual(audio.stopCount, 0)
        XCTAssertFalse(model.monitorAcquisition())
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertFalse(audio.processing.control.audioEnabled.load(ordering: .acquiring))
        XCTAssertTrue(audio.processing.control.cancelled.load(ordering: .acquiring))
        XCTAssertEqual(model.diagnosticSnapshot.session.stopReason, "input_stalled")
        XCTAssertEqual(model.diagnosticSnapshot.audio?.engineIsRunning, false)
        try await eventually { !model.isFinishingProcessing }

        fixture.now = 105
        model.setAppActive(false)
        model.setAppActive(true)
        model.refreshDiagnostics()
        XCTAssertFalse(model.monitorAcquisition())
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(fixture.audioSessions.count, 1)
        XCTAssertEqual(audio.startCount, 1)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(model.diagnosticSnapshot.session.runID, runID)
        XCTAssertEqual(model.diagnosticSnapshot.session.elapsedSeconds, 2, accuracy: 1e-9)
        XCTAssertEqual(model.diagnosticSnapshot.session.stopReason, "input_stalled")
        XCTAssertEqual(model.diagnosticSnapshot.events.filter { $0.code == "input_stalled" }.count, 1)
    }

    func testLateFirstInputReceivesItsOwnDSPGraceThenStopsWithFreshInputButNoFrames() async throws {
        let fixture = RuntimeFixture()
        let (model, audio) = try startLiveFixture(fixture)
        defer { model.stopExperiment() }
        for time in [101.9, 102.1, 103.89] {
            fixture.now = time
            audio.observeInputWithoutAnalysis()
            XCTAssertTrue(model.monitorAcquisition())
            XCTAssertEqual(model.diagnosticSnapshot.pipeline.health, "waitingForProcessing")
            XCTAssertEqual(audio.stopCount, 0)
        }
        fixture.now = 103.91
        audio.observeInputWithoutAnalysis()
        model.refreshDiagnostics()
        XCTAssertEqual(model.diagnosticSnapshot.pipeline.health, "processingStalled")
        XCTAssertEqual(model.diagnosticSnapshot.pipeline.secondsSinceInput, 0)
        XCTAssertFalse(model.monitorAcquisition())
        try await eventually { !model.isFinishingProcessing }
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(audio.processing.control.stopReason, .processingStalled)
        XCTAssertEqual(model.diagnosticSnapshot.session.stopReason, "processing_stalled")
        XCTAssertEqual(model.diagnosticSnapshot.pipeline.acceptedInputCallbacks, 4)
        XCTAssertEqual(model.diagnosticSnapshot.pipeline.processedFrames, 0)
        XCTAssertNil(model.diagnosticSnapshot.pipeline.latestInput)
        XCTAssertEqual(model.diagnosticSnapshot.events.filter { $0.code == "processing_stalled" }.count, 1)
    }

    func testHealthyLiveFixtureUsesRealDSPWithoutRequiringAValidCarrierAndRetainsUserStop() async throws {
        let fixture = RuntimeFixture()
        let (model, audio) = try startLiveFixture(fixture)
        defer { model.stopExperiment() }
        for (index, time) in [100.25, 101.75, 103.25].enumerated() {
            fixture.now = time
            audio.deliverPCMFrame()
            try await eventually { model.replayCount >= index + 1 }
            XCTAssertTrue(model.monitorAcquisition())
            XCTAssertEqual(model.diagnosticSnapshot.pipeline.health, "healthy")
            XCTAssertEqual(audio.stopCount, 0)
        }
        let beforeStop = model.diagnosticSnapshot
        XCTAssertEqual(beforeStop.pipeline.processedFrames, 3)
        XCTAssertEqual(beforeStop.pipeline.spectrumFrames, 3)
        XCTAssertEqual(beforeStop.pipeline.validPhaseFrames, 0)
        XCTAssertEqual(try XCTUnwrap(beforeStop.pipeline.latestInput?.rms), 0.25, accuracy: 1e-9)
        model.stopExperiment()
        try await eventually { !model.isFinishingProcessing }
        fixture.now = 110
        model.refreshDiagnostics()
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(model.diagnosticSnapshot.session.stopReason, "user")
        XCTAssertEqual(model.diagnosticSnapshot.pipeline.processedFrames, 3)
        XCTAssertEqual(try XCTUnwrap(model.diagnosticSnapshot.pipeline.latestInput?.rms), 0.25, accuracy: 1e-9)
        XCTAssertEqual(model.diagnosticSnapshot.session.elapsedSeconds, 3.25, accuracy: 1e-9)
    }

    func testPreviouslyHealthyDSPStopsWhenOnlyInputProgressContinues() async throws {
        let fixture = RuntimeFixture()
        let (model, audio) = try startLiveFixture(fixture)
        defer { model.stopExperiment() }
        fixture.now = 100.25
        audio.deliverPCMFrame()
        try await eventually { model.replayCount == 1 }
        XCTAssertTrue(model.monitorAcquisition())
        XCTAssertEqual(model.diagnosticSnapshot.pipeline.health, "healthy")
        fixture.now = 101.5
        audio.observeInputWithoutAnalysis()
        XCTAssertTrue(model.monitorAcquisition())
        fixture.now = 102.26
        audio.observeInputWithoutAnalysis()
        model.refreshDiagnostics()
        XCTAssertEqual(model.diagnosticSnapshot.pipeline.health, "processingStalled")
        XCTAssertFalse(model.monitorAcquisition())
        try await eventually { !model.isFinishingProcessing }
        XCTAssertEqual(model.diagnosticSnapshot.session.stopReason, "processing_stalled")
        XCTAssertEqual(model.diagnosticSnapshot.pipeline.inputCallbacks, 3)
        XCTAssertEqual(model.diagnosticSnapshot.pipeline.processedFrames, 1)
        XCTAssertNotNil(model.diagnosticSnapshot.pipeline.latestInput)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertFalse(audio.processing.control.audioEnabled.load(ordering: .acquiring))
    }
}

import Foundation
import RheaRFCore
import XCTest
@testable import RheaRFSpanner

/// Real app-hosted DEMO checks; no microphone permission or output is used.
@MainActor
final class DiagnosticsIntegrationTests: XCTestCase {
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
}

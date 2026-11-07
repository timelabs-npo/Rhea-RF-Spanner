import XCTest
@testable import RheaRFSpanner

/// Simulator-hosted integration checks. They exercise silent DEMO and main-actor
/// lifecycle transitions, never microphone permission or live speaker output.
@MainActor
final class ObservatorySessionTests: XCTestCase {
    private func eventually(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for _ in 0..<160 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Expected session state was not reached within 4 seconds", file: file, line: line)
    }

    func testDemoRetunesAndReplaysWithoutChangingOriginalSource() async throws {
        let model = ExperimentModel(arguments: [])
        defer { model.stopExperiment() }
        model.setAppActive(true)
        XCTAssertFalse(model.isRunning)
        model.selectMode(.demo)
        XCTAssertTrue(model.canStart)
        model.startExperiment()
        try await eventually { model.replayCount >= 4 }
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(model.microphoneIsActive)
        XCTAssertEqual(model.latestSlice?.source, .simulated)
        let firstEpoch = try XCTUnwrap(model.latestSlice?.epoch)

        model.setCarrierFrequency(20_500)
        try await eventually {
            model.isRunning && model.latestSlice?.carrierFrequencyHz == 20_500
        }
        XCTAssertNotEqual(model.latestSlice?.epoch, firstEpoch)
        XCTAssertEqual(model.latestSlice?.source, .simulated)

        // Selecting Replay during retirement must wait for posted frames and
        // reconcile the final tape before playback or scrubbing can proceed.
        model.selectMode(.replay)
        try await eventually { !model.isFinishingProcessing }
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.microphoneIsActive)
        model.selectReplayFrame(0)
        XCTAssertEqual(model.latestSlice?.source, .simulated)
        XCTAssertEqual(model.latestSlice?.carrierFrequencyHz, 20_000)
        model.selectReplayFrame(model.replayCount - 1)
        XCTAssertEqual(model.latestSlice?.carrierFrequencyHz, 20_500)
        XCTAssertEqual(model.latestSlice?.source, .simulated)
        model.toggleReplay()
        XCTAssertTrue(model.isReplaying)
        model.stopExperiment()
        XCTAssertFalse(model.isReplaying)
    }

    func testDisplaySettingsDoNotResetAcquisitionAndBackgroundDoesNotResume() async throws {
        let model = ExperimentModel(arguments: [])
        defer { model.stopExperiment() }
        model.setAppActive(true)
        model.selectMode(.demo)
        model.startExperiment()
        try await eventually { model.replayCount >= 3 }
        let epoch = try XCTUnwrap(model.latestSlice?.epoch)
        let timestamp = try XCTUnwrap(model.latestSlice?.sampleTimestamp)
        model.displayParameters.gainDB = 18
        model.displayParameters.persistence = 0.9
        model.displayParameters.palette = .thermal
        model.presentation = .waterfall
        try await eventually { (model.latestSlice?.sampleTimestamp ?? 0) > timestamp }
        XCTAssertEqual(model.latestSlice?.epoch, epoch)
        XCTAssertEqual(model.latestSlice?.carrierFrequencyHz, 20_000)
        XCTAssertFalse(model.microphoneIsActive)

        model.setAppActive(false)
        try await eventually { !model.isFinishingProcessing }
        XCTAssertFalse(model.isRunning)
        let frozenTimestamp = model.latestSlice?.sampleTimestamp
        model.setAppActive(true)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.latestSlice?.sampleTimestamp, frozenTimestamp)
        model.selectMode(.replay)
        model.clearReplay()
        XCTAssertEqual(model.replayCount, 0)
        XCTAssertNil(model.latestSlice)
    }
}

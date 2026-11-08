import Foundation
import XCTest
@testable import RheaRFCore

private func statistics(_ samples: [Float]) -> SignalBlockStatistics {
    samples.withUnsafeBufferPointer { SignalBlockStatistics.measure($0) }
}

final class DiagnosticsTests: XCTestCase {
    func testSilenceIncludesBothSignedZeros() {
        let result = statistics([0, -Float.zero, 0, -Float.zero])
        XCTAssertEqual(result.sampleCount, 4)
        XCTAssertEqual(result.finiteSampleCount, 4)
        XCTAssertEqual(result.zeroSampleCount, 4)
        XCTAssertEqual(result.nonFiniteSampleCount, 0)
        XCTAssertEqual(result.clippedSampleCount, 0)
        XCTAssertEqual(result.minimum, 0)
        XCTAssertEqual(result.maximum, 0)
        XCTAssertEqual(result.mean, 0)
        XCTAssertEqual(result.rms, 0)
        XCTAssertEqual(result.peak, 0)
    }

    func testSignedSamplesHaveIndependentAmplitudeAndEnergyResults() throws {
        let result = statistics([-0.75, 0.25, 0.5, 1.5, -1])
        XCTAssertEqual(result.sampleCount, 5)
        XCTAssertEqual(result.finiteSampleCount, 5)
        XCTAssertEqual(result.zeroSampleCount, 0)
        XCTAssertEqual(result.nonFiniteSampleCount, 0)
        XCTAssertEqual(result.clippedSampleCount, 2)
        XCTAssertEqual(result.minimum, -1)
        XCTAssertEqual(result.maximum, 1.5)
        XCTAssertEqual(try XCTUnwrap(result.mean), 0.1, accuracy: 1e-15)
        // Hand-computed energy: (9/16 + 1/16 + 1/4 + 9/4 + 1) / 5 = 33/40.
        XCTAssertEqual(try XCTUnwrap(result.rms), sqrt(33.0 / 40), accuracy: 1e-15)
        XCTAssertEqual(result.peak, 1.5)
    }

    func testMixedNonfiniteSamplesDoNotAffectFiniteMetricsOrDenominators() throws {
        let result = statistics([.nan, .infinity, -.infinity, -0.5, 0, 0.25, 1])
        XCTAssertEqual(result.sampleCount, 7)
        XCTAssertEqual(result.finiteSampleCount, 4)
        XCTAssertEqual(result.nonFiniteSampleCount, 3)
        XCTAssertEqual(result.zeroSampleCount, 1)
        XCTAssertEqual(result.clippedSampleCount, 1)
        XCTAssertEqual(result.minimum, -0.5)
        XCTAssertEqual(result.maximum, 1)
        XCTAssertEqual(result.mean, 0.1875)
        XCTAssertEqual(try XCTUnwrap(result.rms), sqrt(21.0 / 64), accuracy: 1e-15)
        XCTAssertEqual(result.peak, 1)
    }

    func testEmptyAndAllNonfiniteBlocksHaveUnavailableMetrics() {
        let empty = SignalBlockStatistics.measure(UnsafeBufferPointer<Float>(start: nil, count: 0))
        XCTAssertEqual(empty.sampleCount, 0)
        for result in [empty, statistics([.nan, .infinity, -.infinity])] {
            XCTAssertEqual(result.finiteSampleCount, 0)
            XCTAssertEqual(result.nonFiniteSampleCount, result.sampleCount)
            XCTAssertEqual(result.zeroSampleCount, 0)
            XCTAssertEqual(result.clippedSampleCount, 0)
            XCTAssertNil(result.minimum)
            XCTAssertNil(result.maximum)
            XCTAssertNil(result.mean)
            XCTAssertNil(result.rms)
            XCTAssertNil(result.peak)
        }
    }

    func testFloatExtremesDoNotOverflowAndSubnormalsAreNotZeros() throws {
        let largest = Float.greatestFiniteMagnitude
        let large = statistics([largest, -largest])
        XCTAssertEqual(large.minimum, -Double(largest))
        XCTAssertEqual(large.maximum, Double(largest))
        XCTAssertEqual(large.mean, 0)
        XCTAssertEqual(large.rms, Double(largest))
        XCTAssertEqual(large.peak, Double(largest))
        XCTAssertEqual(large.clippedSampleCount, 2)
        XCTAssertTrue(try XCTUnwrap(large.rms).isFinite)

        let smallest = Float.leastNonzeroMagnitude
        let tiny = statistics([smallest, -smallest])
        XCTAssertEqual(tiny.zeroSampleCount, 0)
        XCTAssertEqual(tiny.mean, 0)
        XCTAssertEqual(tiny.rms, Double(smallest))
        XCTAssertEqual(tiny.peak, Double(smallest))
    }

    func testClippingBoundaryIsInclusiveForBothSigns() {
        let boundary = Float(0.999)
        let result = statistics([
            boundary.nextDown, boundary, -boundary, -(boundary.nextDown), 1, -1
        ])
        XCTAssertEqual(result.finiteSampleCount, 6)
        XCTAssertEqual(result.clippedSampleCount, 4)
    }

    func testMeasuredStatisticsEncodeAsOrdinaryJSONAndRoundTrip() throws {
        let fixtures: [[Float]] = [
            [], [0, -0.25, 1], [.nan, .infinity, -.infinity],
            [.nan, 0.5, -.infinity], [.greatestFiniteMagnitude, -.greatestFiniteMagnitude]
        ]
        for samples in fixtures {
            let result = statistics(samples)
            let encoded = try JSONEncoder().encode(result)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(
                try JSONSerialization.jsonObject(with: encoded)
            ))
            XCTAssertEqual(try JSONDecoder().decode(SignalBlockStatistics.self, from: encoded), result)
        }
    }

    func testEventSanitizesTimesAndBoundsUnicodeCharacters() throws {
        for invalidTime in [-1.0, .nan, .infinity, -.infinity] {
            let event = DiagnosticEvent(
                sequence: .max, elapsedSeconds: invalidTime,
                category: String(repeating: "e\u{301}", count: 80),
                code: String(repeating: "🧪", count: 80),
                message: String(repeating: "🙂", count: 600)
            )
            XCTAssertEqual(event.elapsedSeconds, 0)
            XCTAssertEqual(event.category, String(repeating: "e\u{301}", count: 64))
            XCTAssertEqual(event.code.count, 64)
            XCTAssertEqual(event.message.count, 512)
            let encoded = try JSONEncoder().encode(event)
            XCTAssertEqual(try JSONDecoder().decode(DiagnosticEvent.self, from: encoded), event)
        }
        let valid = DiagnosticEvent(
            sequence: 7, elapsedSeconds: 1.25, category: "input", code: "block", message: "Observed block"
        )
        XCTAssertEqual(valid.elapsedSeconds, 1.25)
        XCTAssertEqual(valid.category, "input")
        XCTAssertEqual(valid.code, "block")
        XCTAssertEqual(valid.message, "Observed block")
    }

    func testDecodingCannotBypassEventBoundsOrTimeSanitation() throws {
        let category = String(repeating: "c", count: 80)
        let code = String(repeating: "d", count: 80)
        let message = String(repeating: "m", count: 600)
        let times: [Any] = [-3.0, "NaN", "Infinity", "-Infinity"]
        for time in times {
            let encoded = try JSONSerialization.data(withJSONObject: [
                "sequence": 9, "elapsedSeconds": time,
                "category": category, "code": code, "message": message
            ])
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
            )
            let event = try decoder.decode(DiagnosticEvent.self, from: encoded)
            XCTAssertEqual(event.elapsedSeconds, 0)
            XCTAssertEqual(event.category.count, 64)
            XCTAssertEqual(event.code.count, 64)
            XCTAssertEqual(event.message.count, 512)
            XCTAssertNoThrow(try JSONEncoder().encode(event))
        }
    }

    func testRingOverwritesOldestAcrossRepeatedWrapsAndCountsDrops() throws {
        var log = BoundedDiagnosticLog(capacity: 3)
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertEqual(log.droppedEventCount, 0)
        for index in 1...11 {
            log.append(
                elapsedSeconds: Double(11 - index), category: "flow", code: "observed",
                message: "Event \(index)"
            )
        }
        XCTAssertEqual(log.events.map(\.sequence), [9, 10, 11])
        XCTAssertEqual(log.events.map(\.elapsedSeconds), [2, 1, 0])
        XCTAssertEqual(log.events.map(\.message), ["Event 9", "Event 10", "Event 11"])
        XCTAssertEqual(log.droppedEventCount, 8)
        let encoded = try JSONEncoder().encode(log.events)
        XCTAssertEqual(try JSONDecoder().decode([DiagnosticEvent].self, from: encoded), log.events)
    }

    func testSnapshotAndCopiedLogRemainIndependentOfOverwriteAndClear() {
        var log = BoundedDiagnosticLog(capacity: 2)
        log.append(elapsedSeconds: 0, category: "run", code: "start", message: "Started")
        log.append(elapsedSeconds: 1, category: "flow", code: "input", message: "Input observed")
        let snapshot = log.events
        var copiedLog = log
        log.append(elapsedSeconds: 2, category: "flow", code: "frame", message: "Frame observed")
        XCTAssertEqual(snapshot.map(\.sequence), [1, 2])
        XCTAssertEqual(copiedLog.events, snapshot)
        XCTAssertEqual(log.events.map(\.sequence), [2, 3])
        log.removeAll()
        log.removeAll()
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertEqual(log.droppedEventCount, 0)
        XCTAssertEqual(copiedLog.events, snapshot)
        log.append(elapsedSeconds: 0, category: "run", code: "restart", message: "Restarted")
        XCTAssertEqual(log.events.map(\.sequence), [4])
        copiedLog.append(elapsedSeconds: 2, category: "run", code: "stop", message: "Stopped")
        XCTAssertEqual(copiedLog.events.map(\.sequence), [2, 3])
        XCTAssertEqual(snapshot.map(\.sequence), [1, 2])
    }

    func testDefaultAndExtremeCapacitiesStayBoundedWithoutIndexTraps() {
        var defaultLog = BoundedDiagnosticLog()
        for _ in 0..<129 {
            defaultLog.append(elapsedSeconds: 0, category: "flow", code: "tick", message: "Observed")
        }
        XCTAssertEqual(defaultLog.events.count, 128)
        XCTAssertEqual(defaultLog.events.first?.sequence, 2)
        XCTAssertEqual(defaultLog.droppedEventCount, 1)

        for capacity in [Int.min, -1, 0, 1] {
            var log = BoundedDiagnosticLog(capacity: capacity)
            for _ in 0..<2 {
                log.append(elapsedSeconds: 0, category: "flow", code: "tick", message: "Observed")
            }
            XCTAssertEqual(log.events.map(\.sequence), [2])
            XCTAssertEqual(log.droppedEventCount, 1)
        }
        var maximumLog = BoundedDiagnosticLog(capacity: .max)
        for _ in 0..<4_100 {
            maximumLog.append(elapsedSeconds: 0, category: "flow", code: "tick", message: "Observed")
        }
        XCTAssertEqual(maximumLog.events.count, 4_096)
        XCTAssertEqual(maximumLog.events.first?.sequence, 5)
        XCTAssertEqual(maximumLog.events.last?.sequence, 4_100)
        XCTAssertEqual(maximumLog.droppedEventCount, 4)
    }

    func testStoppedRunIsIdleEvenWithStaleOrInvalidTelemetry() {
        XCTAssertEqual(PipelineHealth.evaluate(
            isRunning: false, elapsedSeconds: .infinity, inputCallbacks: .max, processedFrames: .max,
            secondsSinceInput: .nan, secondsSinceProcessing: 100
        ), .idle)
    }

    func testMissingInputTransitionsAtStartupGraceBoundary() {
        let cases: [(Double, PipelineHealth)] = [
            (0, .waitingForInput), (1.999, .waitingForInput), (2, .inputStalled), (10, .inputStalled)
        ]
        for (elapsed, expected) in cases {
            XCTAssertEqual(PipelineHealth.evaluate(
                isRunning: true, elapsedSeconds: elapsed, inputCallbacks: 0, processedFrames: 0,
                secondsSinceInput: nil, secondsSinceProcessing: nil
            ), expected)
        }
        // Inconsistent downstream counters do not establish observed input.
        XCTAssertEqual(PipelineHealth.evaluate(
            isRunning: true, elapsedSeconds: 3, inputCallbacks: 0, processedFrames: 8,
            secondsSinceInput: 0, secondsSinceProcessing: 0
        ), .inputStalled)
    }

    func testInputWithoutProcessingWaitsThenStallsAtGraceBoundary() {
        let cases: [(Double, PipelineHealth)] = [
            (1, .waitingForProcessing), (2, .processingStalled), (10, .processingStalled)
        ]
        for (elapsed, expected) in cases {
            XCTAssertEqual(PipelineHealth.evaluate(
                isRunning: true, elapsedSeconds: elapsed, inputCallbacks: 1, processedFrames: 0,
                secondsSinceInput: 0.1, secondsSinceProcessing: nil
            ), expected)
        }
    }

    func testHealthyFlowAndStrictStalenessWithUpstreamPrecedence() {
        let cases: [(Double, Double, PipelineHealth)] = [
            (0, 0, .healthy), (2, 2, .healthy), (2.001, 0, .inputStalled),
            (0, 2.001, .processingStalled), (3, 3, .inputStalled)
        ]
        for (inputAge, processingAge, expected) in cases {
            XCTAssertEqual(PipelineHealth.evaluate(
                isRunning: true, elapsedSeconds: 10, inputCallbacks: .max, processedFrames: .max,
                secondsSinceInput: inputAge, secondsSinceProcessing: processingAge
            ), expected)
        }
        // Once input is observed, explicit stale input can override startup grace.
        XCTAssertEqual(PipelineHealth.evaluate(
            isRunning: true, elapsedSeconds: 1, inputCallbacks: 1, processedFrames: 0,
            secondsSinceInput: 0.6, secondsSinceProcessing: nil,
            startupGraceSeconds: 2, stallThresholdSeconds: 0.5
        ), .inputStalled)
    }

    func testCustomAndZeroTimeThresholdsHaveExplicitBoundaries() {
        XCTAssertEqual(PipelineHealth.evaluate(
            isRunning: true, elapsedSeconds: 3, inputCallbacks: 0, processedFrames: 0,
            secondsSinceInput: nil, secondsSinceProcessing: nil, startupGraceSeconds: 4
        ), .waitingForInput)
        XCTAssertEqual(PipelineHealth.evaluate(
            isRunning: true, elapsedSeconds: 0, inputCallbacks: 0, processedFrames: 0,
            secondsSinceInput: nil, secondsSinceProcessing: nil, startupGraceSeconds: 0
        ), .inputStalled)
        let cases: [(Double, PipelineHealth)] = [(0, .healthy), (0.001, .processingStalled)]
        for (age, expected) in cases {
            XCTAssertEqual(PipelineHealth.evaluate(
                isRunning: true, elapsedSeconds: 5, inputCallbacks: 1, processedFrames: 1,
                secondsSinceInput: 0, secondsSinceProcessing: age,
                startupGraceSeconds: 0, stallThresholdSeconds: 0
            ), expected)
        }
    }

    func testInvalidElapsedAndConfigurationTimesUseDocumentedDefaults() {
        for invalid in [-1.0, .nan, .infinity, -.infinity] {
            XCTAssertEqual(PipelineHealth.evaluate(
                isRunning: true, elapsedSeconds: invalid, inputCallbacks: 0, processedFrames: 0,
                secondsSinceInput: nil, secondsSinceProcessing: nil
            ), .waitingForInput)
            XCTAssertEqual(PipelineHealth.evaluate(
                isRunning: true, elapsedSeconds: 1, inputCallbacks: 0, processedFrames: 0,
                secondsSinceInput: nil, secondsSinceProcessing: nil, startupGraceSeconds: invalid
            ), .waitingForInput)
            XCTAssertEqual(PipelineHealth.evaluate(
                isRunning: true, elapsedSeconds: 2, inputCallbacks: 0, processedFrames: 0,
                secondsSinceInput: nil, secondsSinceProcessing: nil, startupGraceSeconds: invalid
            ), .inputStalled)
            XCTAssertEqual(PipelineHealth.evaluate(
                isRunning: true, elapsedSeconds: 10, inputCallbacks: 1, processedFrames: 1,
                secondsSinceInput: 2, secondsSinceProcessing: 2, stallThresholdSeconds: invalid
            ), .healthy)
            XCTAssertEqual(PipelineHealth.evaluate(
                isRunning: true, elapsedSeconds: 10, inputCallbacks: 1, processedFrames: 1,
                secondsSinceInput: 0, secondsSinceProcessing: 2.001, stallThresholdSeconds: invalid
            ), .processingStalled)
        }
    }

    func testMissingOrInvalidRecencyFallsBackToElapsedWithoutClaimingFreshness() {
        let unavailableAges: [Double?] = [nil, -1, .nan, .infinity, -.infinity]
        for age in unavailableAges {
            XCTAssertEqual(PipelineHealth.evaluate(
                isRunning: true, elapsedSeconds: 1, inputCallbacks: 1, processedFrames: 1,
                secondsSinceInput: age, secondsSinceProcessing: age
            ), .healthy)
            XCTAssertEqual(PipelineHealth.evaluate(
                isRunning: true, elapsedSeconds: 3, inputCallbacks: 1, processedFrames: 1,
                secondsSinceInput: age, secondsSinceProcessing: 0
            ), .inputStalled)
            XCTAssertEqual(PipelineHealth.evaluate(
                isRunning: true, elapsedSeconds: 3, inputCallbacks: 1, processedFrames: 1,
                secondsSinceInput: 0, secondsSinceProcessing: age
            ), .processingStalled)
        }
    }

    func testAllHealthStatesHaveStableJSONRawValues() throws {
        let states: [PipelineHealth] = [
            .idle, .waitingForInput, .inputStalled, .waitingForProcessing, .processingStalled, .healthy
        ]
        let encoded = try JSONEncoder().encode(states)
        XCTAssertEqual(try JSONDecoder().decode([PipelineHealth].self, from: encoded), states)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: encoded) as? [String], [
            "idle", "waitingForInput", "inputStalled", "waitingForProcessing", "processingStalled", "healthy"
        ])
    }
}

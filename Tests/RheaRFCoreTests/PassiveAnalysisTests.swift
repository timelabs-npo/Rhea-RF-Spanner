import Foundation
import XCTest
@testable import RheaRFCore

/// These are deterministic digital input fixtures, never microphone evidence.
final class PassiveAnalysisTests: XCTestCase {
    private func write(
        _ samples: [Float], to ring: SPSCFloatRingBuffer, at time: UInt64,
        timestampIsValid: Bool = true
    ) -> Bool {
        samples.withUnsafeBufferPointer {
            ring.write(
                from: $0.baseAddress!, count: $0.count, startSampleTime: time,
                timestampIsValid: timestampIsValid
            )
        }
    }

    private func audibleFixture() -> [Float] {
        (0..<2_048).map { Float(0.25 * sin(2 * .pi * Double(40 * $0) / 2_048)) }
    }

    func testListenDeliversAudibleSpectrumAndActualLevelsAcrossVariableInputBlocks() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring, acquisitionKind: .listen)
        let samples = audibleFixture()
        var offset = 0
        // Callback boundaries do not need to coincide with analysis windows.
        for count in [128, 17, 511] {
            XCTAssertTrue(write(Array(samples[offset..<offset + count]), to: ring, at: 123 + UInt64(offset)))
            offset += count
            XCTAssertNil(engine.processNextAnalysisFrame())
            XCTAssertEqual(ring.availableToRead, offset)
        }
        XCTAssertTrue(write(Array(samples[offset...]), to: ring, at: 123 + UInt64(offset)))

        let frame = try XCTUnwrap(engine.processNextAnalysisFrame())
        XCTAssertEqual(engine.acquisitionKind, .listen)
        XCTAssertEqual(frame.acquisitionKind, .listen)
        XCTAssertFalse(frame.acquisitionKind.transmitEnabled)
        XCTAssertNil(frame.tone)
        XCTAssertEqual(frame.sampleTimestamp, 123)
        XCTAssertTrue(frame.timing.timestampsAreValid)
        XCTAssertTrue(frame.timing.samplesAreContiguous)
        XCTAssertFalse(frame.timing.discontinuityDetected)
        XCTAssertEqual(frame.inputStatistics.sampleCount, 2_048)
        XCTAssertEqual(frame.inputStatistics.nonFiniteSampleCount, 0)
        XCTAssertEqual(try XCTUnwrap(frame.inputStatistics.rms), 0.25 / sqrt(2), accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(frame.inputStatistics.peak), 0.25, accuracy: 1e-8)
        XCTAssertEqual(20 * log10(try XCTUnwrap(frame.inputStatistics.rms)), -15.0515, accuracy: 0.0001)
        let spectrum = try XCTUnwrap(frame.spectrum)
        XCTAssertEqual(spectrum.sampleTimestamp, frame.sampleTimestamp)
        XCTAssertEqual(spectrum.frequenciesHz[40], 937.5)
        XCTAssertEqual(spectrum.magnitudesDBFS[40], -12.0412, accuracy: 0.0001)
        let strongest = try XCTUnwrap(spectrum.magnitudesDBFS.indices.max {
            spectrum.magnitudesDBFS[$0] < spectrum.magnitudesDBFS[$1]
        })
        XCTAssertEqual(strongest, 40)
        XCTAssertEqual(ring.availableToRead, 0)
        XCTAssertNil(engine.processNextAnalysisFrame())
        XCTAssertEqual(engine.latestSpectrum, spectrum)
    }

    func testListenSeparatesUnavailableTimestampsInternalGapsAndRecovery() throws {
        let configuration = RadarConfiguration(frameSize: 32, ringBufferCapacity: 64)
        let ring = SPSCFloatRingBuffer(capacity: 64)
        let engine = PhaseSensingEngine(
            ringBuffer: ring, configuration: configuration, acquisitionKind: .listen
        )
        XCTAssertTrue(write([Float](repeating: 0.25, count: 32), to: ring, at: 0, timestampIsValid: false))
        let untimed = try XCTUnwrap(engine.processNextAnalysisFrame())
        XCTAssertFalse(untimed.timing.timestampsAreValid)
        XCTAssertTrue(untimed.timing.samplesAreContiguous)
        XCTAssertTrue(untimed.timing.discontinuityDetected)
        XCTAssertEqual(untimed.inputStatistics.rms, 0.25)
        XCTAssertNil(untimed.spectrum)
        XCTAssertNil(untimed.tone)

        XCTAssertTrue(write([Float](repeating: 0.25, count: 16), to: ring, at: 32))
        XCTAssertTrue(write([Float](repeating: 0.25, count: 16), to: ring, at: 64))
        let internalGap = try XCTUnwrap(engine.processNextAnalysisFrame())
        XCTAssertTrue(internalGap.timing.timestampsAreValid)
        XCTAssertFalse(internalGap.timing.samplesAreContiguous)
        XCTAssertFalse(internalGap.timing.hasGapBeforeWindow)
        XCTAssertTrue(internalGap.timing.discontinuityDetected)
        XCTAssertEqual(internalGap.inputStatistics.rms, 0.25)
        XCTAssertNil(internalGap.spectrum)
        XCTAssertNil(internalGap.tone)

        // The missing interval is retained in the capture index. No zeros or
        // old spectrum are inserted to fill it; a whole new window is usable.
        XCTAssertTrue(write([Float](repeating: 0.25, count: 32), to: ring, at: 96))
        let recovered = try XCTUnwrap(engine.processNextAnalysisFrame())
        XCTAssertTrue(recovered.timing.samplesAreContiguous)
        XCTAssertTrue(recovered.timing.hasGapBeforeWindow)
        XCTAssertTrue(recovered.timing.discontinuityDetected)
        XCTAssertEqual(try XCTUnwrap(recovered.spectrum).sampleTimestamp, 96)
        XCTAssertNil(recovered.tone)

        XCTAssertTrue(write([Float](repeating: 0.25, count: 32), to: ring, at: 128))
        let continuous = try XCTUnwrap(engine.processNextAnalysisFrame())
        XCTAssertFalse(continuous.timing.discontinuityDetected)
        XCTAssertEqual(try XCTUnwrap(continuous.spectrum).sampleTimestamp, 128)
    }

    func testListenRetainsDropCountsWithoutRetimingAlreadyQueuedWindows() throws {
        let configuration = RadarConfiguration(frameSize: 32, ringBufferCapacity: 64)
        let ring = SPSCFloatRingBuffer(capacity: 64)
        let engine = PhaseSensingEngine(
            ringBuffer: ring, configuration: configuration, acquisitionKind: .listen
        )
        XCTAssertTrue(write([Float](repeating: 0.25, count: 64), to: ring, at: 0))
        XCTAssertFalse(write([Float](repeating: 0.5, count: 24), to: ring, at: 64))
        for expectedTime in [UInt64(0), 32] {
            let queued = try XCTUnwrap(engine.processNextAnalysisFrame())
            XCTAssertEqual(queued.sampleTimestamp, expectedTime)
            XCTAssertFalse(queued.timing.discontinuityDetected)
            XCTAssertEqual(queued.inputStatistics.rms, 0.25)
            XCTAssertEqual(queued.droppedWriteBlocks, 1)
            XCTAssertEqual(queued.droppedWriteSamples, 24)
            XCTAssertNotNil(queued.spectrum)
            XCTAssertNil(queued.tone)
        }
        XCTAssertTrue(write([Float](repeating: 0.125, count: 32), to: ring, at: 88))
        let afterDrop = try XCTUnwrap(engine.processNextAnalysisFrame())
        XCTAssertEqual(afterDrop.sampleTimestamp, 88)
        XCTAssertTrue(afterDrop.timing.hasGapBeforeWindow)
        XCTAssertEqual(try XCTUnwrap(afterDrop.spectrum).sampleTimestamp, 88)
        XCTAssertEqual(afterDrop.inputStatistics.rms, 0.125)
        XCTAssertNil(afterDrop.tone)
    }

    func testListenKeepsNonfiniteEvidenceDistinctFromSilenceAndRecovers() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring, acquisitionKind: .listen)
        var invalid = audibleFixture()
        invalid[19] = .nan
        invalid[21] = .infinity
        XCTAssertTrue(write(invalid, to: ring, at: 0))
        let rejected = try XCTUnwrap(engine.processNextAnalysisFrame())
        XCTAssertEqual(rejected.inputStatistics.nonFiniteSampleCount, 2)
        XCTAssertEqual(rejected.inputStatistics.finiteSampleCount, 2_046)
        XCTAssertNotNil(rejected.inputStatistics.rms)
        XCTAssertNil(rejected.spectrum)
        XCTAssertNil(rejected.tone)
        XCTAssertNil(engine.latestSpectrum)

        XCTAssertTrue(write([Float](repeating: .nan, count: 2_048), to: ring, at: 2_048))
        let entirelyInvalid = try XCTUnwrap(engine.processNextAnalysisFrame())
        XCTAssertEqual(entirelyInvalid.inputStatistics.nonFiniteSampleCount, 2_048)
        XCTAssertNil(entirelyInvalid.inputStatistics.rms)
        XCTAssertNil(entirelyInvalid.inputStatistics.peak)
        XCTAssertNil(entirelyInvalid.spectrum)
        XCTAssertNil(entirelyInvalid.tone)

        XCTAssertTrue(write([Float](repeating: 0, count: 2_048), to: ring, at: 4_096))
        let silence = try XCTUnwrap(engine.processNextAnalysisFrame())
        XCTAssertEqual(silence.inputStatistics.zeroSampleCount, 2_048)
        XCTAssertEqual(silence.inputStatistics.nonFiniteSampleCount, 0)
        XCTAssertEqual(silence.inputStatistics.rms, 0)
        XCTAssertEqual(silence.inputStatistics.peak, 0)
        XCTAssertTrue(try XCTUnwrap(silence.spectrum).magnitudesDBFS.allSatisfy { $0 == -160 })
        XCTAssertNil(silence.tone)

        XCTAssertTrue(write(audibleFixture(), to: ring, at: 6_144))
        let recovered = try XCTUnwrap(engine.processNextAnalysisFrame())
        XCTAssertEqual(try XCTUnwrap(recovered.spectrum).sampleTimestamp, 6_144)
        XCTAssertEqual(try XCTUnwrap(recovered.inputStatistics.rms), 0.25 / sqrt(2), accuracy: 1e-8)
        XCTAssertNil(recovered.tone)
    }

    func testCommonActiveResultPreservesToneFailureAndBroadAudioIndependently() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring)
        XCTAssertTrue(write(audibleFixture(), to: ring, at: 0))
        let frame = try XCTUnwrap(engine.processNextAnalysisFrame())
        XCTAssertEqual(frame.acquisitionKind, .tone)
        XCTAssertTrue(frame.acquisitionKind.transmitEnabled)
        XCTAssertNotEqual(try XCTUnwrap(frame.tone).validity, .valid)
        XCTAssertNil(frame.tone?.relativePhaseRadians)
        XCTAssertEqual(try XCTUnwrap(frame.spectrum).frequenciesHz[40], 937.5)
        XCTAssertEqual(try XCTUnwrap(frame.inputStatistics.rms), 0.25 / sqrt(2), accuracy: 1e-8)
        XCTAssertEqual(ring.availableToRead, 0)
    }
}

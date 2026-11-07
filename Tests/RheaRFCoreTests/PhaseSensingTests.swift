import Foundation
import XCTest
@testable import RheaRFCore

private func tone(
    count: Int, start: UInt64, phase: Double, amplitude: Double = 0.2,
    noiseAmplitude: Double = 0
) -> [Float] {
    (0..<count).map { index in
        let sample = (Int(start % 48_000) + index) % 48_000
        let toneAngle = 2 * Double.pi * Double((sample * 20_000) % 48_000) / 48_000
        let otherAngle = 2 * Double.pi * Double((sample * 1_000) % 48_000) / 48_000
        return Float(amplitude * cos(toneAngle + phase) + noiseAmplitude * cos(otherAngle))
    }
}

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

final class PhaseSensingTests: XCTestCase {
    func testKnownPhaseChangesRemainCorrectAcrossNonintegerCycleFrames() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring)
        let phases = [2.9, 3.2, 3.5, 6.0]
        let expected = [0.0, 0.3, 0.6, 3.1]
        for index in phases.indices {
            let start = UInt64(index * 2_048)
            XCTAssertTrue(write(tone(count: 2_048, start: start, phase: phases[index]), to: ring, at: start))
            let frame = try XCTUnwrap(engine.processNextFrame())
            XCTAssertEqual(frame.validity, .valid)
            XCTAssertEqual(try XCTUnwrap(frame.relativePhaseRadians), expected[index], accuracy: 1e-7)
            XCTAssertEqual(frame.carrierAmplitude, 0.2, accuracy: 1e-7)
            XCTAssertGreaterThan(frame.qualityDB, 60)
            XCTAssertEqual(frame.didRebaseline, index == 0)
            XCTAssertEqual(frame.calibrationID, 1)
            let expectedMeters = -expected[index] * 343.0 / (4 * .pi * 20_000)
            XCTAssertEqual(
                try XCTUnwrap(frame.equivalentMonostaticDisplacementMeters),
                expectedMeters, accuracy: 1e-9
            )
        }
    }

    func testLargeCaptureTimestampDoesNotLoseCarrierPhasePrecision() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring)
        let origin: UInt64 = (1 << 60) + 7
        for index in 0..<3 {
            let start = origin + UInt64(index * 2_048)
            let phase = 0.7 + Double(index) * 0.2
            XCTAssertTrue(write(tone(count: 2_048, start: start, phase: phase), to: ring, at: start))
            let frame = try XCTUnwrap(engine.processNextFrame())
            XCTAssertEqual(frame.validity, .valid)
            XCTAssertEqual(try XCTUnwrap(frame.relativePhaseRadians), Double(index) * 0.2, accuracy: 1e-7)
        }
    }

    func testSilenceInvalidatesPhaseAndNextToneStartsANewReference() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring)
        XCTAssertTrue(write(tone(count: 2_048, start: 0, phase: 0.2), to: ring, at: 0))
        XCTAssertEqual(try XCTUnwrap(engine.processNextFrame()).calibrationID, 1)
        XCTAssertTrue(write([Float](repeating: 0, count: 2_048), to: ring, at: 2_048))
        let silence = try XCTUnwrap(engine.processNextFrame())
        XCTAssertEqual(silence.validity, .lowSignal)
        XCTAssertFalse(silence.isPhaseCoherent)
        XCTAssertNil(silence.relativePhaseRadians)
        XCTAssertNil(silence.equivalentMonostaticDisplacementMeters)
        XCTAssertTrue(silence.qualityDB.isFinite)
        XCTAssertTrue(write(tone(count: 2_048, start: 4_096, phase: 2.6), to: ring, at: 4_096))
        let recovered = try XCTUnwrap(engine.processNextFrame())
        XCTAssertEqual(recovered.validity, .valid)
        XCTAssertTrue(recovered.didRebaseline)
        XCTAssertEqual(recovered.calibrationID, 2)
        XCTAssertEqual(recovered.relativePhaseRadians, 0)
    }

    func testStrongOffFrequencyEnergyFailsQualityGate() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring)
        XCTAssertTrue(write(
            tone(count: 2_048, start: 0, phase: 0, amplitude: 0.01, noiseAmplitude: 0.5),
            to: ring, at: 0
        ))
        let frame = try XCTUnwrap(engine.processNextFrame())
        XCTAssertEqual(frame.validity, .lowQuality)
        XCTAssertLessThan(frame.qualityDB, 0)
        XCTAssertNil(frame.relativePhaseRadians)
        XCTAssertEqual(frame.calibrationID, 0)
    }

    func testTinyPureToneCannotAcquireLockDespiteHighQualityRatio() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring)
        XCTAssertTrue(write(tone(count: 2_048, start: 0, phase: 0, amplitude: 1e-7), to: ring, at: 0))
        let frame = try XCTUnwrap(engine.processNextFrame())
        XCTAssertEqual(frame.validity, .lowSignal)
        XCTAssertNil(frame.relativePhaseRadians)
    }

    func testNonFiniteSampleDoesNotPoisonLaterFrames() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring)
        var invalid = tone(count: 2_048, start: 0, phase: 0)
        invalid[1_000] = .nan
        XCTAssertTrue(write(invalid, to: ring, at: 0))
        let rejected = try XCTUnwrap(engine.processNextFrame())
        XCTAssertEqual(rejected.validity, .nonFiniteInput)
        XCTAssertNil(rejected.relativePhaseRadians)
        XCTAssertTrue(write(tone(count: 2_048, start: 2_048, phase: 0.6), to: ring, at: 2_048))
        let recovered = try XCTUnwrap(engine.processNextFrame())
        XCTAssertEqual(recovered.validity, .valid)
        XCTAssertEqual(recovered.relativePhaseRadians, 0)
        XCTAssertTrue(recovered.didRebaseline)
    }

    func testOverflowInvalidatesAtTheActualCaptureGapAndNeverBridgesIt() throws {
        let configuration = RadarConfiguration(frameSize: 32, ringBufferCapacity: 64)
        let ring = SPSCFloatRingBuffer(capacity: 64)
        let engine = PhaseSensingEngine(ringBuffer: ring, configuration: configuration)
        XCTAssertTrue(write(tone(count: 64, start: 0, phase: 0.2), to: ring, at: 0))
        XCTAssertFalse(write(tone(count: 32, start: 64, phase: 0.3), to: ring, at: 64))
        // A later producer overrun does not retroactively invalidate old queued data.
        XCTAssertEqual(try XCTUnwrap(engine.processNextFrame()).validity, .valid)
        XCTAssertEqual(try XCTUnwrap(engine.processNextFrame()).validity, .valid)
        XCTAssertTrue(write(tone(count: 32, start: 96, phase: 0.4), to: ring, at: 96))
        let gap = try XCTUnwrap(engine.processNextFrame())
        XCTAssertEqual(gap.validity, .inputDiscontinuity)
        XCTAssertTrue(gap.discontinuityDetected)
        XCTAssertNil(gap.relativePhaseRadians)
        XCTAssertEqual(gap.droppedWriteBlocks, 1)
        XCTAssertEqual(gap.droppedWriteSamples, 32)
        XCTAssertTrue(write(tone(count: 32, start: 128, phase: 2.2), to: ring, at: 128))
        let recovered = try XCTUnwrap(engine.processNextFrame())
        XCTAssertEqual(recovered.validity, .valid)
        XCTAssertTrue(recovered.didRebaseline)
        XCTAssertEqual(recovered.relativePhaseRadians, 0)
        XCTAssertEqual(recovered.calibrationID, 2)
    }

    func testGapInsideAnalysisFrameIsRejected() throws {
        let configuration = RadarConfiguration(frameSize: 32, ringBufferCapacity: 64)
        let ring = SPSCFloatRingBuffer(capacity: 64)
        let engine = PhaseSensingEngine(ringBuffer: ring, configuration: configuration)
        XCTAssertTrue(write(tone(count: 16, start: 0, phase: 0.2), to: ring, at: 0))
        XCTAssertTrue(write(tone(count: 16, start: 32, phase: 0.2), to: ring, at: 32))
        let frame = try XCTUnwrap(engine.processNextFrame())
        XCTAssertEqual(frame.validity, .inputDiscontinuity)
        XCTAssertNil(frame.relativePhaseRadians)
    }

    func testUnavailableHardwareTimestampCannotEstablishBaseline() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring)
        XCTAssertTrue(write(
            tone(count: 2_048, start: 0, phase: 0), to: ring, at: 0,
            timestampIsValid: false
        ))
        let frame = try XCTUnwrap(engine.processNextFrame())
        XCTAssertEqual(frame.validity, .inputDiscontinuity)
        XCTAssertEqual(frame.calibrationID, 0)
        XCTAssertNil(frame.relativePhaseRadians)
    }

    func testExplicitCalibrationResetDoesNotMutateTheCaptureQueue() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring)
        XCTAssertTrue(write(tone(count: 2_048, start: 0, phase: 0.1), to: ring, at: 0))
        _ = try XCTUnwrap(engine.processNextFrame())
        XCTAssertTrue(write(tone(count: 2_048, start: 2_048, phase: 0.9), to: ring, at: 2_048))
        engine.resetCalibration()
        XCTAssertEqual(ring.availableToRead, 2_048)
        let frame = try XCTUnwrap(engine.processNextFrame())
        XCTAssertEqual(frame.validity, .valid)
        XCTAssertEqual(frame.relativePhaseRadians, 0)
        XCTAssertEqual(frame.calibrationID, 2)
    }
}

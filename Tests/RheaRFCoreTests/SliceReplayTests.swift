import Foundation
import XCTest
@testable import RheaRFCore

private func record(
    time: UInt64 = 0, source: ObservationSource = .simulated, phase: Float? = 0,
    validity: PhaseValidity = .valid, epoch: UInt32 = 1,
    position: SIMD3<Float>? = nil, direction: SIMD3<Float>? = nil, depth: Float? = nil
) -> SpatioTemporalSlice {
    SpatioTemporalSlice(
        sampleTimestamp: time, unwrappedPhase: phase, normalizedAmplitude: 0.1,
        coherenceSNR: 30, carrierFrequencyHz: 20_500, sensorPosition: position,
        sensorForward: direction, lidarDepthMeters: depth,
        qualityScore: phase == nil ? 0 : 1, epoch: epoch, source: source,
        validity: validity, didRebaseline: time == 0,
        discontinuityDetected: validity == .inputDiscontinuity
    )
}

final class SliceReplayTests: XCTestCase {
    func testFiniteDoubleAmplitudeOverflowCannotCrashReplayEncoding() throws {
        let frame = PhaseTelemetryFrame(
            sampleTimestamp: 0, relativePhaseRadians: 0,
            equivalentMonostaticDisplacementMeters: 0, qualityDB: 30,
            carrierAmplitude: Double(Float.greatestFiniteMagnitude) * 1.3,
            validity: .valid, discontinuityDetected: false, didRebaseline: true,
            calibrationID: 1, droppedWriteBlocks: 0, droppedWriteSamples: 0
        )
        let slice = SpatioTemporalSlice(frame: frame, source: .simulated, carrierFrequencyHz: 20_000, epoch: 1)
        XCTAssertEqual(slice.validity, .nonFiniteInput)
        XCTAssertNil(slice.unwrappedPhase)
        XCTAssertTrue(slice.normalizedAmplitude.isFinite)
        let tape = ReplayTape()
        tape.append(slice)
        XCTAssertEqual(try XCTUnwrap(tape.slice(at: 0)), slice)
    }

    func testWireRecordHas64BytesAndIndependentLittleEndianOffsets() throws {
        let original = record(time: 0x0102_0304_0506_0708, epoch: 0xA1B2_C3D4)
        let data = original.encoded()
        XCTAssertEqual(data.count, 64)
        XCTAssertEqual(Array(data[0..<8]), [8, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual(Array(data[56..<60]), [0xD4, 0xC3, 0xB2, 0xA1])
        XCTAssertEqual(data[63], 1, "Wire version is a byte, independent of host endianness")
        XCTAssertEqual(data[60] & 8, 8, "Simulation origin survives serialization")
        XCTAssertEqual(try SpatioTemporalSlice(encoded: data), original)
    }

    func testMissingSpatialValuesAndMeasuredOriginRemainDistinct() throws {
        let missing = try SpatioTemporalSlice(encoded: record().encoded())
        XCTAssertNil(missing.sensorPosition)
        XCTAssertNil(missing.sensorForward)
        XCTAssertNil(missing.lidarDepthMeters)
        let located = record(position: .zero, direction: SIMD3(0, 0, -1), depth: 2.5)
        XCTAssertEqual(try SpatioTemporalSlice(encoded: located.encoded()), located)
        XCTAssertNotEqual(located.encoded(), missing.encoded())
    }

    func testInvalidPhaseIsUnavailableAndNotAZeroMeasurement() throws {
        for validity in [PhaseValidity.lowSignal, .lowQuality, .inputDiscontinuity, .nonFiniteInput] {
            let original = record(phase: nil, validity: validity)
            let decoded = try SpatioTemporalSlice(encoded: original.encoded())
            XCTAssertNil(decoded.unwrappedPhase)
            XCTAssertFalse(decoded.isPhaseCoherent)
            XCTAssertEqual(decoded, original)
        }
    }

    func testDecoderRejectsVersionReservedFlagsAndNonfinitePayload() {
        var data = record().encoded()
        data[63] = 2
        XCTAssertThrowsError(try SpatioTemporalSlice(encoded: data)) {
            XCTAssertEqual($0 as? SliceDecodingError, .unsupportedVersion(2))
        }
        data = record().encoded()
        data[61] |= 4
        XCTAssertThrowsError(try SpatioTemporalSlice(encoded: data)) {
            XCTAssertEqual($0 as? SliceDecodingError, .reservedFlags)
        }
        data = record().encoded()
        data.replaceSubrange(12..<16, with: [0, 0, 0xC0, 0x7F]) // Float32 quiet NaN.
        XCTAssertThrowsError(try SpatioTemporalSlice(encoded: data))
        data = record().encoded()
        data[61] &= 0xFD // Valid record cannot declare its phase absent.
        XCTAssertThrowsError(try SpatioTemporalSlice(encoded: data))
        XCTAssertThrowsError(try SpatioTemporalSlice(encoded: Data(repeating: 0, count: 63)))
    }

    func testTapeWrapsChronologicallyAndRetainsSourceAndSpectrum() throws {
        let tape = ReplayTape(capacity: 3)
        for time in 0..<5 {
            tape.append(
                record(time: UInt64(time), source: time % 2 == 0 ? .microphone : .simulated),
                spectrum: SpectrumFrame(
                    sampleTimestamp: UInt64(time), frequenciesHz: [20_500], magnitudesDBFS: [-20]
                )
            )
        }
        XCTAssertEqual(tape.count, 3)
        XCTAssertEqual(tape.encodedFrames().count, 3 * 64)
        for index in 0..<3 {
            let item = try XCTUnwrap(tape.slice(at: index))
            XCTAssertEqual(item.sampleTimestamp, UInt64(index + 2))
            XCTAssertEqual(item.source, index % 2 == 0 ? .microphone : .simulated)
            XCTAssertEqual(tape.spectrum(at: index)?.sampleTimestamp, item.sampleTimestamp)
            let bytes = tape.encodedFrames().subdata(in: (index * 64)..<((index + 1) * 64))
            XCTAssertEqual(try SpatioTemporalSlice(encoded: bytes), item)
        }
        XCTAssertNil(tape.slice(at: -1))
        XCTAssertNil(tape.slice(at: 3))
        tape.removeAll()
        XCTAssertEqual(tape.count, 0)
        XCTAssertNil(tape.spectrum(at: 0))
        XCTAssertTrue(tape.encodedFrames().isEmpty)
        tape.append(record(time: 9))
        XCTAssertEqual(tape.slice(at: 0)?.sampleTimestamp, 9)
    }

    func testDefaultTapeKeepsExactly2048WireRecords() {
        let tape = ReplayTape()
        for index in 0..<2_051 { tape.append(record(time: UInt64(index))) }
        XCTAssertEqual(tape.capacity, 2_048)
        XCTAssertEqual(tape.count, 2_048)
        XCTAssertEqual(tape.encodedFrames().count, 131_072)
        XCTAssertEqual(tape.slice(at: 0)?.sampleTimestamp, 3)
        XCTAssertEqual(tape.slice(at: 2_047)?.sampleTimestamp, 2_050)
    }

    func testEveryGridFrequencyUsesBoundedIntegerAddressingAtLargeTimestamps() {
        let clocks: [UInt64] = [0, 95, 96, 2_048, (1 << 60) + 7, UInt64.max - 96]
        for frequency in CarrierGrid.frequencies {
            let reference = CarrierReference(configuration: RadarConfiguration(carrierFrequencyHz: frequency))
            XCTAssertEqual(reference.period, 96)
            for clock in clocks {
                let index = CarrierGrid.phaseIndex(sampleTimestamp: clock, frequencyHz: frequency)
                XCTAssertTrue((0..<96).contains(index))
                XCTAssertEqual(index, CarrierGrid.phaseIndex(sampleTimestamp: clock + 96, frequencyHz: frequency))
                let angle = 2 * Double.pi * Double(index) / 96
                XCTAssertEqual(reference.cosine[reference.index(for: clock)], cos(angle), accuracy: 1e-14)
                XCTAssertEqual(reference.negativeSine[reference.index(for: clock)], -sin(angle), accuracy: 1e-14)
            }
        }
        XCTAssertFalse(CarrierGrid.isSupported(20_499))
        XCTAssertFalse(CarrierGrid.isSupported(22_500))
    }
}

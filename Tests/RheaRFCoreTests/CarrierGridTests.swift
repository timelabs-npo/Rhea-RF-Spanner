import Foundation
import XCTest
@testable import RheaRFCore

final class CarrierGridTests: XCTestCase {
    func testEveryGridCarrierUsesTheSameBoundedModulo96AddressSpace() {
        let timestamps: [UInt64] = [0, 1, 95, 96, 97, (1 << 60) + 7, UInt64.max - 2_048]
        XCTAssertEqual(CarrierGrid.frequencies, [18_000, 18_500, 19_000, 19_500, 20_000, 20_500, 21_000, 21_500, 22_000])
        for frequency in CarrierGrid.frequencies {
            let reference = CarrierReference(configuration: RadarConfiguration(carrierFrequencyHz: frequency))
            XCTAssertEqual(reference.period, 96)
            for time in timestamps {
                let index = CarrierGrid.phaseIndex(sampleTimestamp: time, frequencyHz: frequency)
                XCTAssertTrue((0..<96).contains(index))
                let independentAngle = 2 * Double.pi
                    * Double((time % 48_000 * UInt64(frequency)) % 48_000) / 48_000
                XCTAssertEqual(cos(2 * .pi * Double(index) / 96), cos(independentAngle), accuracy: 2e-14)
                XCTAssertEqual(reference.cosine[reference.index(for: time)], cos(independentAngle), accuracy: 2e-14)
                XCTAssertEqual(reference.negativeSine[reference.index(for: time)], -sin(independentAngle), accuracy: 2e-14)
            }
        }
    }

    func testAllGridCarriersRetainPhaseAndAmplitudeAtLargeCaptureTimestamps() throws {
        let origin: UInt64 = (1 << 60) + 7
        for frequency in CarrierGrid.frequencies {
            let configuration = RadarConfiguration(carrierFrequencyHz: frequency)
            let ring = SPSCFloatRingBuffer()
            let engine = PhaseSensingEngine(ringBuffer: ring, configuration: configuration)
            for frameIndex in 0..<3 {
                let timestamp = origin + UInt64(frameIndex * 2_048)
                let phase = 2.9 + Double(frameIndex) * 0.3
                let samples = (0..<2_048).map { index -> Float in
                    let time = timestamp + UInt64(index)
                    let angle = 2 * Double.pi
                        * Double((time % 48_000 * UInt64(frequency)) % 48_000) / 48_000
                    return Float(0.2 * cos(angle + phase))
                }
                samples.withUnsafeBufferPointer {
                    XCTAssertTrue(ring.write(from: $0.baseAddress!, count: $0.count, startSampleTime: timestamp))
                }
                let frame = try XCTUnwrap(engine.processNextFrame())
                XCTAssertEqual(frame.validity, .valid)
                XCTAssertEqual(try XCTUnwrap(frame.relativePhaseRadians), Double(frameIndex) * 0.3, accuracy: 1e-7)
                XCTAssertEqual(frame.carrierAmplitude, 0.2, accuracy: 1e-7)
                XCTAssertGreaterThan(frame.qualityDB, 60)
                XCTAssertEqual(frame.didRebaseline, frameIndex == 0)
                XCTAssertEqual(engine.latestSpectrum?.sampleTimestamp, timestamp)
            }
        }
    }

    func testKnownOrthogonalToneAndResidualEnergyRatio() throws {
        let configuration = RadarConfiguration(frameSize: 96, ringBufferCapacity: 128)
        let ring = SPSCFloatRingBuffer(capacity: 128)
        let engine = PhaseSensingEngine(ringBuffer: ring, configuration: configuration)
        let samples = (0..<96).map { index -> Float in
            let carrier = 2 * Double.pi * Double(index * 40 % 96) / 96
            let residual = 2 * Double.pi * Double(index * 2 % 96) / 96
            return Float(0.2 * cos(carrier + 0.7) + 0.05 * cos(residual))
        }
        samples.withUnsafeBufferPointer {
            XCTAssertTrue(ring.write(from: $0.baseAddress!, count: $0.count, startSampleTime: 0))
        }
        let frame = try XCTUnwrap(engine.processNextFrame())
        XCTAssertEqual(frame.validity, .valid)
        XCTAssertEqual(frame.carrierAmplitude, 0.2, accuracy: 1e-7)
        XCTAssertEqual(frame.qualityDB, 20 * log10(0.2 / 0.05), accuracy: 1e-5)
    }
}

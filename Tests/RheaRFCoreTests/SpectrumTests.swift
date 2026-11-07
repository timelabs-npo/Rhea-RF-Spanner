import Foundation
import XCTest
@testable import RheaRFCore

private func spectrum(
    _ samples: [Float], analyzer: SpectrumAnalyzer = .init(), timestamp: UInt64 = 0
) throws -> SpectrumFrame {
    try samples.withUnsafeBufferPointer {
        try XCTUnwrap(analyzer.analyze(samples: $0, sampleTimestamp: timestamp))
    }
}

final class SpectrumTests: XCTestCase {
    func testBinCenteredToneUsesHannCoherentGainAndDBFSAmplitude() throws {
        let count = 2_048
        let bin = 832 // 19,500 Hz at 48 kHz.
        for amplitude in [1.0, 0.25] {
            let samples = (0..<count).map {
                Float(amplitude * sin(2 * .pi * Double(bin * $0) / Double(count)))
            }
            let frame = try spectrum(samples, timestamp: 12_345)
            let expectedDBFS = Float(20 * log10(amplitude))
            XCTAssertEqual(frame.sampleTimestamp, 12_345)
            XCTAssertEqual(frame.frequenciesHz.count, 1_025)
            XCTAssertEqual(frame.frequenciesHz[bin], 19_500)
            XCTAssertEqual(frame.frequenciesHz[1], 23.4375)
            XCTAssertEqual(frame.frequenciesHz.last, 24_000)
            XCTAssertEqual(frame.magnitudesDBFS[bin], expectedDBFS, accuracy: 2e-5)
            XCTAssertEqual(frame.magnitudesDBFS[bin - 1], expectedDBFS - 6.0206, accuracy: 2e-5)
            XCTAssertEqual(frame.magnitudesDBFS[bin + 1], expectedDBFS - 6.0206, accuracy: 2e-5)
            XCTAssertLessThan(frame.magnitudesDBFS[bin + 10], -120)
        }
    }

    func testDCAndNyquistAreNotDoubled() throws {
        let dc = try spectrum([Float](repeating: 0.5, count: 2_048))
        XCTAssertEqual(dc.magnitudesDBFS[0], Float(20 * log10(0.5)), accuracy: 2e-5)
        let nyquist = try spectrum((0..<2_048).map { $0.isMultiple(of: 2) ? 0.25 : -0.25 })
        XCTAssertEqual(nyquist.magnitudesDBFS[1_024], Float(20 * log10(0.25)), accuracy: 2e-5)
    }

    func testFFTMatchesIndependentDirectDFTForMixedAndOffBinSignals() throws {
        let count = 2_048
        let samples = (0..<count).map { index -> Float in
            let t = Double(index) / Double(count)
            let carrier = 0.6 * cos(2 * Double.pi * 832 * t + 0.3)
            let offBin = 0.12 * sin(2 * Double.pi * 100.25 * t)
            let periodic = 0.01 * Double((index * 17) % 23 - 11)
            return Float(carrier + offBin + periodic)
        }
        let frame = try spectrum(samples)
        for bin in [0, 1, 99, 100, 101, 102, 512, 831, 832, 833, 901, 1_024] {
            var real = 0.0
            var imaginary = 0.0
            var weightSum = 0.0
            for index in samples.indices {
                let weight = 0.5 * (1 - cos(2 * .pi * Double(index) / Double(count)))
                let angle = 2 * Double.pi * Double(bin * index) / Double(count)
                real += Double(samples[index]) * weight * cos(angle)
                imaginary -= Double(samples[index]) * weight * sin(angle)
                weightSum += weight
            }
            let scale = bin == 0 || bin == count / 2 ? 1.0 : 2.0
            let expected = max(-160, 20 * log10(scale * hypot(real, imaginary) / weightSum))
            XCTAssertEqual(Double(frame.magnitudesDBFS[bin]), expected, accuracy: 0.001)
        }
    }

    func testSilenceIsFiniteAndInvalidInputDoesNotPoisonFollowingTransforms() throws {
        let analyzer = SpectrumAnalyzer()
        let silence = [Float](repeating: 0, count: 2_048)
        let frame = try spectrum(silence, analyzer: analyzer)
        XCTAssertTrue(frame.magnitudesDBFS.allSatisfy { $0 == analyzer.floorDBFS })
        var invalid = silence
        invalid[1_000] = .nan
        invalid.withUnsafeBufferPointer {
            XCTAssertNil(analyzer.analyze(samples: $0, sampleTimestamp: 2_048))
        }
        let recovered = try spectrum([Float](repeating: 0.5, count: 2_048), analyzer: analyzer, timestamp: 4_096)
        XCTAssertEqual(recovered.sampleTimestamp, 4_096)
        XCTAssertEqual(recovered.magnitudesDBFS[0], Float(20 * log10(0.5)), accuracy: 2e-5)
    }

    func testEnginePublishesSampleSpectrumEvenWhenToneIsBelowLossGate() throws {
        let ring = SPSCFloatRingBuffer()
        let engine = PhaseSensingEngine(ringBuffer: ring)
        let silence = [Float](repeating: 0, count: 2_048)
        silence.withUnsafeBufferPointer {
            XCTAssertTrue(ring.write(from: $0.baseAddress!, count: $0.count, startSampleTime: 123))
        }
        XCTAssertEqual(try XCTUnwrap(engine.processNextFrame()).validity, .lowSignal)
        let frame = try XCTUnwrap(engine.latestSpectrum)
        XCTAssertEqual(frame.sampleTimestamp, 123)
        XCTAssertEqual(frame.magnitudesDBFS.count, 1_025)
        XCTAssertTrue(frame.magnitudesDBFS.allSatisfy { $0 == -160 })
        XCTAssertNil(engine.processNextFrame())
        XCTAssertEqual(engine.latestSpectrum, frame)
        var invalid = silence
        invalid[5] = .infinity
        invalid.withUnsafeBufferPointer {
            XCTAssertTrue(ring.write(from: $0.baseAddress!, count: $0.count, startSampleTime: 2_171))
        }
        XCTAssertEqual(try XCTUnwrap(engine.processNextFrame()).validity, .nonFiniteInput)
        XCTAssertNil(engine.latestSpectrum)
    }

    func testEngineOmitsSpectraForInvalidTimestampsAndIntraFrameCaptureGaps() throws {
        let configuration = RadarConfiguration(frameSize: 32, ringBufferCapacity: 64)
        let ring = SPSCFloatRingBuffer(capacity: 64)
        let engine = PhaseSensingEngine(ringBuffer: ring, configuration: configuration)
        let samples = [Float](repeating: 0.25, count: 32)
        samples.withUnsafeBufferPointer {
            XCTAssertTrue(ring.write(
                from: $0.baseAddress!, count: 32, startSampleTime: 0,
                timestampIsValid: false
            ))
        }
        XCTAssertEqual(try XCTUnwrap(engine.processNextFrame()).validity, .inputDiscontinuity)
        XCTAssertNil(engine.latestSpectrum)

        samples.withUnsafeBufferPointer {
            XCTAssertTrue(ring.write(from: $0.baseAddress!, count: 16, startSampleTime: 32))
            XCTAssertTrue(ring.write(from: $0.baseAddress!, count: 16, startSampleTime: 64))
        }
        XCTAssertEqual(try XCTUnwrap(engine.processNextFrame()).validity, .inputDiscontinuity)
        XCTAssertNil(engine.latestSpectrum)

        // A wholly contiguous frame after a gap has a usable spectrum even
        // though phase continuity from the preceding frame cannot be claimed.
        samples.withUnsafeBufferPointer {
            XCTAssertTrue(ring.write(from: $0.baseAddress!, count: 32, startSampleTime: 96))
        }
        XCTAssertEqual(try XCTUnwrap(engine.processNextFrame()).validity, .inputDiscontinuity)
        XCTAssertEqual(try XCTUnwrap(engine.latestSpectrum).sampleTimestamp, 96)
    }
}

import Foundation
import XCTest
@testable import RheaRFCore

private func generateSamples(
    _ generator: SyntheticSignalGenerator, count: Int, start: UInt64
) -> [Float] {
    var result = [Float](repeating: 0, count: count)
    result.withUnsafeMutableBufferPointer {
        generator.generate(into: $0.baseAddress!, count: $0.count, startSampleTime: start)
    }
    return result
}

final class SyntheticSignalTests: XCTestCase {
    func testSameSeedAndTimelineAreIndependentOfCallbackLengths() {
        let configuration = RadarConfiguration(carrierFrequencyHz: 18_500)
        let parameters = SimulationParameters(
            amplitude: 0.2, snrDB: 15, displacementMeters: 0.003,
            motionFrequencyHz: 0.37, seed: 123_456
        )
        let continuous = SyntheticSignalGenerator(configuration: configuration, parameters: parameters)
        let fragmented = SyntheticSignalGenerator(configuration: configuration, parameters: parameters)
        let lengths = [1, 7, 2_048, 4_097, 0, 32, 513]
        let total = lengths.reduce(0, +)
        let origin: UInt64 = (1 << 60) + 7
        let expected = generateSamples(continuous, count: total, start: origin)
        var actual = [Float](repeating: 0, count: total)
        actual.withUnsafeMutableBufferPointer { buffer in
            var offset = 0
            for count in lengths {
                fragmented.generate(
                    into: buffer.baseAddress!.advanced(by: offset), count: count,
                    startSampleTime: origin + UInt64(offset)
                )
                offset += count
            }
        }
        XCTAssertEqual(actual, expected)
        XCTAssertTrue(actual.allSatisfy(\.isFinite))
    }

    func testSeedChangesNoiseAndSeekingUsesTheRequestedSampleClock() {
        let firstParameters = SimulationParameters(seed: 1)
        let secondParameters = SimulationParameters(seed: 2)
        let first = SyntheticSignalGenerator(configuration: .standard, parameters: firstParameters)
        let second = SyntheticSignalGenerator(configuration: .standard, parameters: secondParameters)
        XCTAssertNotEqual(
            generateSamples(first, count: 512, start: 0),
            generateSamples(second, count: 512, start: 0)
        )
        let origin: UInt64 = (1 << 59) + 123
        let fresh = SyntheticSignalGenerator(configuration: .standard, parameters: firstParameters)
        XCTAssertEqual(
            generateSamples(first, count: 1_024, start: origin),
            generateSamples(fresh, count: 1_024, start: origin)
        )
    }

    func testDisplacementPhaseIsAppliedAtEverySampleWithCorrectSign() {
        let parameters = SimulationParameters(
            amplitude: 0.3, snrDB: 120, displacementMeters: 0.002,
            motionFrequencyHz: 3.75, seed: 77
        )
        let generator = SyntheticSignalGenerator(configuration: .standard, parameters: parameters)
        let origin: UInt64 = 45_123
        let samples = generateSamples(generator, count: 2_048, start: origin)
        var squaredError = 0.0
        for index in samples.indices {
            let time = origin + UInt64(index)
            let carrier = 2 * Double.pi * Double((time % 48_000 * 20_000) % 48_000) / 48_000
            let displacement = parameters.displacementMeters
                * sin(2 * .pi * parameters.motionFrequencyHz * Double(time) / 48_000)
            let lag = 4 * Double.pi * 20_000 * displacement / 343
            let expected = parameters.amplitude * cos(carrier - lag)
            let error = Double(samples[index]) - expected
            squaredError += error * error
        }
        // The remaining error is the deliberately retained 120 dB noise and
        // Float sample quantization, far below a frozen-per-block phase error.
        XCTAssertLessThan(sqrt(squaredError / Double(samples.count)), 3e-7)
    }

    func testDefaultMotionRemainsAccurateBeyondDoubleExactIntegerClockRange() {
        let parameters = SimulationParameters(amplitude: 0.2, snrDB: 120)
        let generator = SyntheticSignalGenerator(configuration: .standard, parameters: parameters)
        let origin: UInt64 = (1 << 60) + 7
        let samples = generateSamples(generator, count: 2_048, start: origin)
        for index in samples.indices {
            let time = origin + UInt64(index)
            let carrier = 2 * Double.pi * Double((time % 48_000 * 20_000) % 48_000) / 48_000
            // The default 0.25 Hz motion repeats every 192,000 samples.
            let motion = 2 * Double.pi * Double(time % 192_000) / 192_000
            let lag = 4 * Double.pi * 20_000 * 0.001 * sin(motion) / 343
            XCTAssertEqual(Double(samples[index]), 0.2 * cos(carrier - lag), accuracy: 1e-6)
        }
    }

    func testRequestedSNRUsesSignalAndNoiseRMSWithoutClipping() {
        let amplitude = 0.4
        for requestedSNR in [-6.0, 12, 36] {
            let parameters = SimulationParameters(
                amplitude: amplitude, snrDB: requestedSNR,
                displacementMeters: 0, motionFrequencyHz: 0, seed: 0x1234_5678
            )
            let generator = SyntheticSignalGenerator(configuration: .standard, parameters: parameters)
            let samples = generateSamples(generator, count: 120_000, start: 0)
            var signalEnergy = 0.0
            var noiseEnergy = 0.0
            var noiseSum = 0.0
            for index in samples.indices {
                let carrier = 2 * Double.pi * Double((index * 20_000) % 48_000) / 48_000
                let signal = amplitude * cos(carrier)
                let noise = Double(samples[index]) - signal
                signalEnergy += signal * signal
                noiseEnergy += noise * noise
                noiseSum += noise
            }
            let measuredSNR = 10 * log10(signalEnergy / noiseEnergy)
            XCTAssertEqual(measuredSNR, requestedSNR, accuracy: 0.1)
            let expectedNoiseRMS = amplitude / sqrt(2) * pow(10, -requestedSNR / 20)
            XCTAssertLessThan(abs(noiseSum / Double(samples.count)), expectedNoiseRMS * 0.01)
            if requestedSNR < 0 {
                XCTAssertGreaterThan(samples.map(abs).max()!, 1)
            }
        }
    }

    func testGenerationMayEndAtMaximumTimestampWithoutCrossingIt() {
        let parameters = SimulationParameters(
            amplitude: 0.2, snrDB: 120, displacementMeters: 0, motionFrequencyHz: 0
        )
        let generator = SyntheticSignalGenerator(configuration: .standard, parameters: parameters)
        let origin = UInt64.max - 31
        let samples = generateSamples(generator, count: 32, start: origin)
        for index in samples.indices {
            let time = origin + UInt64(index)
            let carrier = 2 * Double.pi * Double((time % 48_000 * 20_000) % 48_000) / 48_000
            XCTAssertEqual(Double(samples[index]), 0.2 * cos(carrier), accuracy: 1e-6)
        }
    }
}

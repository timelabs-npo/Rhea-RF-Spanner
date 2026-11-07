import Foundation
import XCTest
@testable import RheaRFCore

final class OscillatorTests: XCTestCase {
    func testArbitraryRenderLengthsProduceTheSameContinuousSignal() {
        let lengths = [1, 7, 2_048, 4_097, 0, 32, 513]
        let total = lengths.reduce(0, +)
        let continuous = SineOscillator(amplitude: 0.02)
        let fragmented = SineOscillator(amplitude: 0.02)
        var expected = [Float](repeating: 0, count: total)
        expected.withUnsafeMutableBufferPointer {
            continuous.render(into: $0.baseAddress!, count: $0.count)
        }
        var actual = [Float](repeating: 0, count: total)
        actual.withUnsafeMutableBufferPointer { buffer in
            var offset = 0
            for count in lengths {
                fragmented.render(into: buffer.baseAddress!.advanced(by: offset), count: count)
                offset += count
            }
        }
        XCTAssertEqual(actual, expected)
        XCTAssertLessThanOrEqual(actual.map(abs).max()!, 0.02)
        // Independent analytic check spans the old 2,048-sample callback boundary.
        for index in [0, 1, 11, 12, 2_047, 2_048, 2_049, total - 1] {
            let angle = 2 * Double.pi * Double((index * 20_000) % 48_000) / 48_000
            XCTAssertEqual(Double(actual[index]), 0.02 * sin(angle), accuracy: 2e-9)
        }
    }

    func testStandardCarrierRepeatsAfterTwelveSamples() {
        let oscillator = SineOscillator(amplitude: 0.1)
        let samples = (0..<48).map { _ in oscillator.nextSample() }
        for index in 12..<samples.count {
            XCTAssertEqual(samples[index], samples[index - 12])
        }
        XCTAssertNotEqual(samples[1], samples[2])
    }
}

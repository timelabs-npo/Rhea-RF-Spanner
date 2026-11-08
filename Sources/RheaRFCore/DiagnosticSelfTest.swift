import Foundation

public struct DiagnosticSelfTestCheck: Sendable, Codable, Equatable {
    public let name: String
    public let unit: String
    public let expected: Double
    public let observed: Double?
    public let absoluteTolerance: Double
    public let passed: Bool

    init(name: String, unit: String, expected: Double, observed: Double?, tolerance: Double) {
        self.name = name
        self.unit = unit
        self.expected = expected
        self.observed = observed.flatMap { $0.isFinite ? $0 : nil }
        absoluteTolerance = tolerance
        passed = self.observed.map { abs($0 - expected) <= tolerance } ?? false
    }
}

public struct DiagnosticSelfTestResult: Sendable, Codable, Equatable {
    public let fixtureVersion: Int
    public let sampleRateHz: Int
    public let carrierHz: Int
    public let frameSize: Int
    public let processedFrames: Int
    public let checks: [DiagnosticSelfTestCheck]
    public let passed: Bool
}

/// A short, silent software check that can run on the device without permission.
/// The analytical input is independent of the engine's oscillator lookup table.
/// This checks the sample queue, phase estimator, FFT and JSON-ready result.
/// Microphone, speaker, Metal, camera and external hardware are NOT exercised.
public enum DiagnosticSelfTest {
    public static func run() -> DiagnosticSelfTestResult {
        let configuration = RadarConfiguration(carrierFrequencyHz: 20_500)
        let ring = SPSCFloatRingBuffer(capacity: configuration.ringBufferCapacity)
        let engine = PhaseSensingEngine(ringBuffer: ring, configuration: configuration)
        let amplitude = 0.2
        let expectedPhaseChange = 0.5
        var frame: PhaseTelemetryFrame?
        var processed = 0
        for block in 0..<2 {
            let start = block * configuration.frameSize
            let phase = block == 0 ? 0 : expectedPhaseChange
            let samples = (0..<configuration.frameSize).map { index in
                Float(amplitude * cos(2 * .pi * 20_500 * Double(start + index)
                    / configuration.sampleRate + phase))
            }
            let wrote = samples.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return false }
                return ring.write(from: base, count: buffer.count, startSampleTime: UInt64(start))
            }
            if wrote, let result = engine.processNextFrame() {
                frame = result
                processed += 1
            }
        }
        let spectrum = engine.latestSpectrum
        let peakIndex = spectrum?.magnitudesDBFS.indices.max { lhs, rhs in
            (spectrum?.magnitudesDBFS[lhs] ?? -.infinity)
                < (spectrum?.magnitudesDBFS[rhs] ?? -.infinity)
        }
        let peakHz = peakIndex.flatMap { index in spectrum.map { Double($0.frequenciesHz[index]) } }
        let checks: [DiagnosticSelfTestCheck] = [
            .init(name: "Queue → estimator frames", unit: "frames", expected: 2,
                  observed: Double(processed), tolerance: 0),
            .init(name: "Relative phase step", unit: "rad", expected: expectedPhaseChange,
                  observed: frame?.relativePhaseRadians, tolerance: 0.000_01),
            .init(name: "Fitted carrier amplitude", unit: "digital full scale", expected: amplitude,
                  observed: frame?.carrierAmplitude, tolerance: 0.000_001),
            .init(name: "FFT peak frequency", unit: "Hz", expected: 20_500,
                  observed: peakHz, tolerance: configuration.sampleRate / Double(configuration.frameSize) / 2),
        ]
        return DiagnosticSelfTestResult(
            fixtureVersion: 1, sampleRateHz: configuration.sampleRateHz,
            carrierHz: 20_500, frameSize: configuration.frameSize,
            processedFrames: processed, checks: checks, passed: checks.allSatisfy(\.passed)
        )
    }
}

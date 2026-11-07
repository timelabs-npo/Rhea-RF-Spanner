import Foundation

/// The origin of samples is retained when their results are replayed.
public enum ObservationSource: UInt8, Sendable, CaseIterable {
    case microphone = 0
    case simulated = 1

    public var displayName: String { self == .microphone ? "LIVE MIC" : "DEMO" }
}

public enum ObservatoryMode: String, Sendable, CaseIterable {
    case live, demo, replay

    public var displayName: String { rawValue.uppercased() }
}

public enum ObservatoryPresentation: String, Sendable, CaseIterable {
    case field, waterfall

    public var displayName: String { self == .field ? "Phase field" : "Waterfall" }
}

/// False-color display choices; none imply a temperature measurement.
public enum ObservatoryPalette: String, Sendable, CaseIterable {
    case aurora, thermal, monochrome

    public var displayName: String {
        switch self {
        case .aurora: "Aurora"
        case .thermal: "Warm spectrum"
        case .monochrome: "Monochrome"
        }
    }
}

/// Renderer-only settings. Acquisition and the simulator never read this type.
public struct DisplayParameters: Sendable, Equatable {
    public var gainDB: Float
    public var persistence: Float
    public var palette: ObservatoryPalette

    public init(
        gainDB: Float = 0, persistence: Float = 0.65,
        palette: ObservatoryPalette = .aurora
    ) {
        self.gainDB = gainDB
        self.persistence = persistence
        self.palette = palette
    }
}

public enum CarrierGrid {
    public static let sampleRateHz = 48_000
    public static let stepHz = 500
    public static let phaseModulus = 96
    public static let frequencies = Array(stride(from: 18_000, through: 22_000, by: stepHz))

    public static func isSupported(_ frequency: Int) -> Bool {
        (18_000...22_000).contains(frequency) && frequency % stepHz == 0
    }

    /// Exact integer addressing, including sample clocks beyond 2^53.
    /// The subsequently looked-up floating-point sine/cosine is approximate.
    public static func phaseIndex(sampleTimestamp: UInt64, frequencyHz: Int) -> Int {
        precondition(isSupported(frequencyHz))
        let reduced = sampleTimestamp % UInt64(phaseModulus)
        return Int((reduced * UInt64(frequencyHz / stepHz)) % UInt64(phaseModulus))
    }
}

/// A synthetic moving reflector; these values are not acquisition settings.
/// SNR refers to expected full-band sample power before windowing/fitting.
public struct SimulationParameters: Sendable, Equatable {
    public var amplitude: Double
    public var snrDB: Double
    public var displacementMeters: Double
    public var motionFrequencyHz: Double
    public var seed: UInt64

    public init(
        amplitude: Double = 0.1, snrDB: Double = 30,
        displacementMeters: Double = 0.001, motionFrequencyHz: Double = 0.25,
        seed: UInt64 = 0x5248_4541
    ) {
        precondition(amplitude.isFinite && amplitude > 0 && amplitude <= 1)
        precondition(snrDB.isFinite && (-120...120).contains(snrDB))
        precondition(displacementMeters.isFinite && displacementMeters >= 0)
        precondition(motionFrequencyHz.isFinite && motionFrequencyHz >= 0)
        self.amplitude = amplitude
        self.snrDB = snrDB
        self.displacementMeters = displacementMeters
        self.motionFrequencyHz = motionFrequencyHz
        self.seed = seed
    }
}

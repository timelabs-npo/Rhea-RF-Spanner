import Foundation

/// Parameters for a single-tone acoustic experiment, not a radio transmitter.
/// Only `.standard` is the intended iOS hardware configuration for this release.
public struct RadarConfiguration: Sendable, Equatable {
    public static let standard = RadarConfiguration()

    public let sampleRateHz: Int
    public let carrierFrequencyHz: Int
    public let frameSize: Int
    public let ringBufferCapacity: Int
    public let speedOfSoundMetersPerSecond: Double
    public let minimumCarrierAmplitude: Double
    public let minimumQualityDB: Double

    public var sampleRate: Double { Double(sampleRateHz) }
    public var carrierFrequency: Double { Double(carrierFrequencyHz) }

    /// Configuration is a programmer-supplied contract, not untrusted input.
    /// Integer-Hz frequencies permit an exactly repeating carrier reference.
    public init(
        sampleRateHz: Int = 48_000,
        carrierFrequencyHz: Int = 20_000,
        frameSize: Int = 2_048,
        ringBufferCapacity: Int = 65_536,
        speedOfSoundMetersPerSecond: Double = 343.0,
        minimumCarrierAmplitude: Double = 0.000_01,
        minimumQualityDB: Double = 3.0
    ) {
        precondition((8_000...384_000).contains(sampleRateHz))
        precondition(carrierFrequencyHz > 0 && carrierFrequencyHz * 2 < sampleRateHz)
        precondition(frameSize >= 16 && frameSize <= ringBufferCapacity)
        precondition(
            ringBufferCapacity > 0 && ringBufferCapacity <= 1_048_576
                && (ringBufferCapacity & (ringBufferCapacity - 1)) == 0
        )
        precondition(speedOfSoundMetersPerSecond.isFinite && speedOfSoundMetersPerSecond > 0)
        precondition(minimumCarrierAmplitude.isFinite && minimumCarrierAmplitude > 0)
        precondition(minimumQualityDB.isFinite)
        self.sampleRateHz = sampleRateHz
        self.carrierFrequencyHz = carrierFrequencyHz
        self.frameSize = frameSize
        self.ringBufferCapacity = ringBufferCapacity
        self.speedOfSoundMetersPerSecond = speedOfSoundMetersPerSecond
        self.minimumCarrierAmplitude = minimumCarrierAmplitude
        self.minimumQualityDB = minimumQualityDB
    }
}

public enum PhaseValidity: String, Sendable {
    case valid
    case lowSignal
    case lowQuality
    case inputDiscontinuity
    case nonFiniteInput

    public var displayName: String {
        switch self {
        case .valid: "Tone estimate available"
        case .lowSignal: "Insufficient tone amplitude"
        case .lowQuality: "Insufficient tone-to-residual ratio"
        case .inputDiscontinuity: "Capture timeline interrupted"
        case .nonFiniteInput: "Invalid audio samples"
        }
    }
}

public struct PhaseTelemetryFrame: Sendable {
    /// Capture sample clock supplied by the audio producer, not ring position.
    public let sampleTimestamp: UInt64
    /// Unwrapped change from this calibration epoch's first valid frame.
    /// `nil` means unavailable; invalid measurements are never displayed as zero.
    public let relativePhaseRadians: Double?
    /// Conditional model conversion, not a range measurement. Positive means
    /// increasing reflector range for a single monostatic reflected path.
    public let equivalentMonostaticDisplacementMeters: Double?
    /// Hann-weighted fitted-tone / residual energy, limited to [-120, 120] dB.
    /// This is not calibrated acoustic SNR or proof of physical phase coherence.
    public let qualityDB: Double
    public let carrierAmplitude: Double
    public let validity: PhaseValidity
    public let discontinuityDetected: Bool
    public let didRebaseline: Bool
    public let calibrationID: UInt64
    public let droppedWriteBlocks: UInt64
    public let droppedWriteSamples: UInt64

    /// Compatibility name for the local signal-validity gate. This is not a
    /// statement that a particular reflector or propagation path was identified.
    public var isPhaseCoherent: Bool { validity == .valid }

    public init(
        sampleTimestamp: UInt64,
        relativePhaseRadians: Double?,
        equivalentMonostaticDisplacementMeters: Double?,
        qualityDB: Double,
        carrierAmplitude: Double,
        validity: PhaseValidity,
        discontinuityDetected: Bool,
        didRebaseline: Bool,
        calibrationID: UInt64,
        droppedWriteBlocks: UInt64,
        droppedWriteSamples: UInt64
    ) {
        self.sampleTimestamp = sampleTimestamp
        self.relativePhaseRadians = relativePhaseRadians
        self.equivalentMonostaticDisplacementMeters = equivalentMonostaticDisplacementMeters
        self.qualityDB = qualityDB
        self.carrierAmplitude = carrierAmplitude
        self.validity = validity
        self.discontinuityDetected = discontinuityDetected
        self.didRebaseline = didRebaseline
        self.calibrationID = calibrationID
        self.droppedWriteBlocks = droppedWriteBlocks
        self.droppedWriteSamples = droppedWriteSamples
    }
}

/// An integer sample-rate / frequency ratio has a finite sampled carrier cycle.
/// Reducing the sample clock before conversion to Double avoids loss of phase
/// precision when capture timestamps exceed Double's exact integer range.
struct CarrierReference: Sendable {
    let cosine: [Double]
    let negativeSine: [Double]

    var period: Int { cosine.count }

    init(configuration: RadarConfiguration) {
        var a = configuration.sampleRateHz
        var b = configuration.carrierFrequencyHz
        while b != 0 {
            (a, b) = (b, a % b)
        }
        let period = configuration.sampleRateHz / a
        let step = configuration.carrierFrequencyHz / a
        var cosine: [Double] = []
        var negativeSine: [Double] = []
        cosine.reserveCapacity(period)
        negativeSine.reserveCapacity(period)
        for sample in 0..<period {
            let angle = 2.0 * Double.pi * Double((sample * step) % period) / Double(period)
            cosine.append(cos(angle))
            negativeSine.append(-sin(angle))
        }
        self.cosine = cosine
        self.negativeSine = negativeSine
    }

    func index(for sampleTime: UInt64) -> Int {
        Int(sampleTime % UInt64(period))
    }
}

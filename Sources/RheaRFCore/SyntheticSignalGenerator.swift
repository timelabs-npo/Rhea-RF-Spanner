import Foundation

/// Silent, deterministic sample source for a single simulated reflected path.
///
/// `amplitude` is the carrier's peak amplitude. Independent, zero-mean Gaussian
/// noise has RMS `amplitude / sqrt(2) * pow(10, -snrDB / 20)`. Consequently SNR
/// describes the expected signal/noise power ratio; finite windows fluctuate.
/// Samples are not clipped, since clipping would change the requested ratio.
///
/// SAFETY CONTRACT for `@unchecked Sendable`: construct before use, then hand
/// ownership to one serial simulation context. Calls must not overlap. This
/// object does not access a UI, an audio session, or any output device.
public final class SyntheticSignalGenerator: @unchecked Sendable {
    public let configuration: RadarConfiguration
    public let parameters: SimulationParameters

    private let reference: CarrierReference
    private let motionPhaseStep: Double
    private let maximumPhaseShift: Double
    private let noiseRMS: Double
    private var expectedSampleTime: UInt64?
    private var motionPhaseUnits = 0.0

    public init(
        configuration: RadarConfiguration,
        parameters: SimulationParameters = .init()
    ) {
        precondition(parameters.amplitude.isFinite && parameters.amplitude >= 0)
        precondition(parameters.snrDB.isFinite)
        precondition(parameters.displacementMeters.isFinite && parameters.displacementMeters >= 0)
        precondition(parameters.motionFrequencyHz.isFinite && parameters.motionFrequencyHz >= 0)
        let phaseShift = 4 * Double.pi * configuration.carrierFrequency
            * parameters.displacementMeters / configuration.speedOfSoundMetersPerSecond
        let noiseRMS = parameters.amplitude == 0 ? 0
            : parameters.amplitude / sqrt(2) * pow(10, -parameters.snrDB / 20)
        precondition(phaseShift.isFinite)
        // Box-Muller with our open 52-bit uniforms stays below nine sigma.
        precondition(noiseRMS.isFinite && parameters.amplitude + 9 * noiseRMS <= Double(Float.greatestFiniteMagnitude))
        self.configuration = configuration
        self.parameters = parameters
        self.reference = CarrierReference(configuration: configuration)
        self.motionPhaseStep = parameters.motionFrequencyHz
            .truncatingRemainder(dividingBy: configuration.sampleRate)
        self.maximumPhaseShift = phaseShift
        self.noiseRMS = noiseRMS
    }

    /// Advances motion on every sample, retaining its bounded phase across
    /// contiguous calls. Noise is keyed by seed and capture sample index, so it
    /// is reproducible regardless of callback length or skipped intervals.
    /// A requested range must not cross UInt64.max. After the capture clock
    /// wraps, begin a new acquisition run with a new generator instance.
    public func generate(
        into destination: UnsafeMutablePointer<Float>,
        count: Int,
        startSampleTime: UInt64
    ) {
        precondition(count >= 0)
        guard count > 0 else { return }
        precondition(
            UInt64(count - 1) <= UInt64.max - startSampleTime,
            "Generation cannot cross UInt64.max; start a new run after clock wrap."
        )
        if expectedSampleTime != startSampleTime {
            motionPhaseUnits = Self.modularProduct(
                motionPhaseStep, startSampleTime, modulus: configuration.sampleRate
            )
        }
        var carrierIndex = reference.index(for: startSampleTime)
        var sampleTime = startSampleTime
        for index in 0..<count {
            // An increasing monostatic path length produces a negative phase
            // shift. Every trigonometric argument is bounded independently of
            // the capture clock; carrier indexing uses integer modulo only.
            let motionAngle = 2 * Double.pi * (motionPhaseUnits / configuration.sampleRate)
            let displacementPhase = (-maximumPhaseShift * sin(motionAngle))
                .truncatingRemainder(dividingBy: 2 * .pi)
            let signal = parameters.amplitude * (
                reference.cosine[carrierIndex] * cos(displacementPhase)
                    + reference.negativeSine[carrierIndex] * sin(displacementPhase)
            )
            let noise = noiseRMS == 0 ? 0 : noiseRMS * gaussian(at: sampleTime)
            destination[index] = Float(signal + noise)

            carrierIndex += 1
            if carrierIndex == reference.period { carrierIndex = 0 }
            motionPhaseUnits += motionPhaseStep
            if motionPhaseUnits >= configuration.sampleRate {
                motionPhaseUnits -= configuration.sampleRate
            }
            sampleTime &+= 1
        }
        expectedSampleTime = sampleTime
    }

    /// Bounded multiplication before division by the sample rate avoids adding
    /// an initial frequency/sample-rate rounding error over a huge clock. Binary
    /// fractions such as the default 0.25 Hz avoid the initial 1/192000 rounding
    /// error. General floating-point frequencies and trigonometry incur roundoff.
    private static func modularProduct(_ value: Double, _ integer: UInt64, modulus: Double) -> Double {
        var multiplier = integer
        var addend = value
        var result = 0.0
        while multiplier != 0 {
            if multiplier & 1 != 0 {
                result += addend
                if result >= modulus { result -= modulus }
            }
            addend += addend
            if addend >= modulus { addend -= modulus }
            multiplier >>= 1
        }
        return result
    }

    /// Timestamp-addressed SplitMix64 outputs, transformed with Box-Muller.
    /// Using all 64 clock bits avoids repeating noise at carrier-cycle boundaries.
    private func gaussian(at sampleTime: UInt64) -> Double {
        let counter = parameters.seed &+ sampleTime &* 0x9E37_79B9_7F4A_7C15
        let first = Self.mix(counter &+ 0x9E37_79B9_7F4A_7C15)
        let second = Self.mix(counter &+ 0xD1B5_4A32_D192_ED03)
        let denominator = 4_503_599_627_370_496.0 // 2^52
        let u1 = (Double(first >> 12) + 0.5) / denominator
        let u2 = (Double(second >> 12) + 0.5) / denominator
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    private static func mix(_ input: UInt64) -> UInt64 {
        var value = input
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

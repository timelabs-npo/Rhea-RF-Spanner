/// Continuous sampled sine generator with a bounded phase state. The standard
/// 20 kHz / 48 kHz signal repeats every 12 samples, not every 2,048 samples.
///
/// SAFETY CONTRACT for `@unchecked Sendable`: construct before rendering, then
/// hand ownership to exactly one serial audio render context. Do not call these
/// methods concurrently. Amplitude and the cycle table are immutable.
public final class SineOscillator: @unchecked Sendable {
    public let amplitude: Float
    private let cycle: [Float]
    private var cycleIndex = 0

    public init(configuration: RadarConfiguration = .standard, amplitude: Float = 0.02) {
        precondition(amplitude.isFinite && amplitude >= 0 && amplitude <= 1)
        self.amplitude = amplitude
        let reference = CarrierReference(configuration: configuration)
        self.cycle = reference.negativeSine.map { Float(-$0) * amplitude }
    }

    @inline(__always)
    public func nextSample() -> Float {
        let value = cycle[cycleIndex]
        cycleIndex += 1
        if cycleIndex == cycle.count { cycleIndex = 0 }
        return value
    }

    /// Accepts any nonnegative callback length; no fixed-size table is overread.
    public func render(into destination: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        for index in 0..<count {
            destination[index] = nextSample()
        }
    }
}

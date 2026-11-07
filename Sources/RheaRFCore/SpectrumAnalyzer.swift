import Foundation

/// One-sided, Hann-windowed amplitude spectrum. A full-scale bin-centered sine
/// is 0 dBFS. DC and Nyquist use their single-sided endpoint normalization.
public struct SpectrumFrame: Sendable, Equatable {
    /// Capture index of the first sample included in this transform.
    public let sampleTimestamp: UInt64
    public let frequenciesHz: [Float]
    public let magnitudesDBFS: [Float]

    public init(
        sampleTimestamp: UInt64,
        frequenciesHz: [Float],
        magnitudesDBFS: [Float]
    ) {
        precondition(frequenciesHz.count == magnitudesDBFS.count)
        self.sampleTimestamp = sampleTimestamp
        self.frequenciesHz = frequenciesHz
        self.magnitudesDBFS = magnitudesDBFS
    }
}

/// Portable radix-two FFT, independent of UI state and platform DSP frameworks.
/// The app uses 2,048 samples at 48 kHz: 1,025 bins spaced 23.4375 Hz apart.
/// Hann coherent-gain correction yields amplitude dBFS, not a power spectral
/// density. Off-bin tones exhibit the Hann window's normal scalloping loss.
///
/// SAFETY CONTRACT for `@unchecked Sendable`: the mutable transform workspace
/// belongs to one serial DSP consumer. Never call `analyze` concurrently.
public final class SpectrumAnalyzer: @unchecked Sendable {
    public let sampleRateHz: Int
    public let fftSize: Int
    public let floorDBFS: Float = -160

    private let frequencies: [Float]
    private let bitReversed: [Int]
    private let twiddleReal: [Double]
    private let twiddleImaginary: [Double]
    private var real: [Double]
    private var imaginary: [Double]
    private var window: [Double] = []
    private var windowSum = 0.0

    public init(sampleRateHz: Int = 48_000, fftSize: Int = 2_048) {
        precondition(sampleRateHz > 0)
        precondition(fftSize >= 16 && fftSize <= 65_536 && fftSize & (fftSize - 1) == 0)
        self.sampleRateHz = sampleRateHz
        self.fftSize = fftSize
        self.frequencies = (0...fftSize / 2).map {
            Float(Double($0) * Double(sampleRateHz) / Double(fftSize))
        }
        let bits = fftSize.trailingZeroBitCount
        self.bitReversed = (0..<fftSize).map { index in
            var input = index
            var output = 0
            for _ in 0..<bits {
                output = (output << 1) | (input & 1)
                input >>= 1
            }
            return output
        }
        self.twiddleReal = (0..<fftSize / 2).map {
            cos(-2 * .pi * Double($0) / Double(fftSize))
        }
        self.twiddleImaginary = (0..<fftSize / 2).map {
            sin(-2 * .pi * Double($0) / Double(fftSize))
        }
        self.real = [Double](repeating: 0, count: fftSize)
        self.imaginary = [Double](repeating: 0, count: fftSize)
        prepareWindow(count: fftSize)
    }

    /// Analyzes the latest `fftSize` input samples. Short inputs use a Hann
    /// window over their observed length, then zero padding; padding adds bins,
    /// not physical resolving power. Empty or nonfinite inputs return nil.
    public func analyze(
        samples: UnsafeBufferPointer<Float>,
        sampleTimestamp: UInt64
    ) -> SpectrumFrame? {
        guard !samples.isEmpty else { return nil }
        let count = min(samples.count, fftSize)
        let offset = samples.count - count
        for index in 0..<samples.count where !samples[index].isFinite {
            return nil
        }
        if window.count != count { prepareWindow(count: count) }
        for index in 0..<fftSize {
            let destination = bitReversed[index]
            real[destination] = index < count ? Double(samples[offset + index]) * window[index] : 0
            imaginary[destination] = 0
        }

        var blockSize = 2
        while blockSize <= fftSize {
            let halfSize = blockSize / 2
            let twiddleStride = fftSize / blockSize
            for base in stride(from: 0, to: fftSize, by: blockSize) {
                for index in 0..<halfSize {
                    let even = base + index
                    let odd = even + halfSize
                    let twiddle = index * twiddleStride
                    let productReal = twiddleReal[twiddle] * real[odd]
                        - twiddleImaginary[twiddle] * imaginary[odd]
                    let productImaginary = twiddleReal[twiddle] * imaginary[odd]
                        + twiddleImaginary[twiddle] * real[odd]
                    let evenReal = real[even]
                    let evenImaginary = imaginary[even]
                    real[even] = evenReal + productReal
                    imaginary[even] = evenImaginary + productImaginary
                    real[odd] = evenReal - productReal
                    imaginary[odd] = evenImaginary - productImaginary
                }
            }
            blockSize <<= 1
        }

        var magnitudes = [Float](repeating: floorDBFS, count: fftSize / 2 + 1)
        for bin in magnitudes.indices {
            let endpointScale = bin == 0 || bin == fftSize / 2 ? 1.0 : 2.0
            let amplitude = endpointScale * hypot(real[bin], imaginary[bin]) / windowSum
            if amplitude > 0 {
                magnitudes[bin] = max(floorDBFS, Float(20 * log10(amplitude)))
            }
        }
        return SpectrumFrame(
            sampleTimestamp: sampleTimestamp &+ UInt64(offset),
            frequenciesHz: frequencies,
            magnitudesDBFS: magnitudes
        )
    }

    private func prepareWindow(count: Int) {
        // A one-sample input cannot form a Hann window; retain that observed
        // sample with unity weight rather than divide by a zero window sum.
        window = count == 1 ? [1] : (0..<count).map {
            0.5 * (1 - cos(2 * .pi * Double($0) / Double(count)))
        }
        windowSum = window.reduce(0, +)
    }
}

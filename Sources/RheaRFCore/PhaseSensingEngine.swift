import Foundation

/// Single-consumer Hann-weighted least-squares tone estimator.
///
/// SAFETY CONTRACT for `@unchecked Sendable`: after construction, all calls to
/// `processNextFrame` and `resetCalibration` belong to one serial DSP context.
/// No UI or audio producer may mutate this object. The queue it consumes has its
/// own documented SPSC synchronization. The input workspace is allocated once.
public final class PhaseSensingEngine: @unchecked Sendable {
    public let configuration: RadarConfiguration
    private let ringBuffer: SPSCFloatRingBuffer
    private let input: UnsafeMutablePointer<Float>
    private let reference: CarrierReference
    private let weights: [Double]
    private let localCosine: [Double]
    private let localNegativeSine: [Double]
    private let gramCC: Double
    private let gramSS: Double
    private let gramCS: Double
    private let gramDeterminant: Double
    private let metersPerRadian: Double

    private var expectedSampleTime: UInt64?
    private var previousWrappedPhase: Double?
    private var accumulatedRelativePhase = 0.0
    private var calibrationID: UInt64 = 0

    public init(
        ringBuffer: SPSCFloatRingBuffer,
        configuration: RadarConfiguration = .standard
    ) {
        precondition(configuration.frameSize <= ringBuffer.capacity)
        self.ringBuffer = ringBuffer
        self.configuration = configuration
        self.input = .allocate(capacity: configuration.frameSize)
        self.input.initialize(repeating: 0, count: configuration.frameSize)
        let reference = CarrierReference(configuration: configuration)
        self.reference = reference

        var weights: [Double] = []
        var cosine: [Double] = []
        var negativeSine: [Double] = []
        weights.reserveCapacity(configuration.frameSize)
        cosine.reserveCapacity(configuration.frameSize)
        negativeSine.reserveCapacity(configuration.frameSize)
        var cc = 0.0
        var ss = 0.0
        var cs = 0.0
        for index in 0..<configuration.frameSize {
            let weight = 0.5 * (1.0 - cos(2.0 * .pi * Double(index) / Double(configuration.frameSize)))
            let c = reference.cosine[index % reference.period]
            let s = reference.negativeSine[index % reference.period]
            weights.append(weight)
            cosine.append(c)
            negativeSine.append(s)
            cc = cc.addingProduct(weight * c, c)
            ss = ss.addingProduct(weight * s, s)
            cs = cs.addingProduct(weight * c, s)
        }
        let determinant = cc * ss - cs * cs
        precondition(determinant.isFinite && determinant > 0, "Degenerate tone reference.")
        self.weights = weights
        self.localCosine = cosine
        self.localNegativeSine = negativeSine
        self.gramCC = cc
        self.gramSS = ss
        self.gramCS = cs
        self.gramDeterminant = determinant
        self.metersPerRadian = configuration.speedOfSoundMetersPerSecond
            / (4.0 * .pi * configuration.carrierFrequency)
    }

    deinit {
        input.deinitialize(count: configuration.frameSize)
        input.deallocate()
    }

    public func processNextFrame() -> PhaseTelemetryFrame? {
        guard let read = ringBuffer.read(into: input, count: configuration.frameSize) else {
            return nil
        }
        let discontinuity = !read.samplesAreContiguous || !read.timestampsAreValid
            || (expectedSampleTime != nil && expectedSampleTime != read.startSampleTime)
        expectedSampleTime = read.nextSampleTime

        var correlationC = 0.0
        var correlationS = 0.0
        var totalEnergy = 0.0
        for index in 0..<configuration.frameSize {
            let sample = Double(input[index])
            guard sample.isFinite else {
                invalidatePhase()
                return telemetry(
                    read: read, qualityDB: -120, amplitude: 0,
                    validity: .nonFiniteInput, discontinuity: discontinuity
                )
            }
            let weightedSample = weights[index] * sample
            correlationC = correlationC.addingProduct(weightedSample, localCosine[index])
            correlationS = correlationS.addingProduct(weightedSample, localNegativeSine[index])
            totalEnergy = totalEnergy.addingProduct(weightedSample, sample)
        }

        // Solve the actual 2x2 weighted Gram system. The sampled sine/cosine
        // columns are not assumed to be perfectly orthogonal inside the window.
        let localI = (gramSS * correlationC - gramCS * correlationS) / gramDeterminant
        let localQ = (gramCC * correlationS - gramCS * correlationC) / gramDeterminant
        let amplitude = hypot(localI, localQ)
        let projectedEnergy = max(0, localI * correlationC + localQ * correlationS)
        let residualEnergy = max(0, totalEnergy - projectedEnergy)
        let qualityDB: Double
        if totalEnergy <= 1e-30 || projectedEnergy <= 0 {
            qualityDB = -120
        } else {
            let denominator = max(residualEnergy, totalEnergy * 1e-12)
            qualityDB = min(120, max(-120, 10.0 * log10(projectedEnergy / denominator)))
        }

        let validity: PhaseValidity
        if discontinuity {
            validity = .inputDiscontinuity
        } else if amplitude < configuration.minimumCarrierAmplitude {
            validity = .lowSignal
        } else if qualityDB < configuration.minimumQualityDB {
            validity = .lowQuality
        } else {
            validity = .valid
        }
        guard validity == .valid else {
            invalidatePhase()
            return telemetry(
                read: read, qualityDB: qualityDB, amplitude: amplitude,
                validity: validity, discontinuity: discontinuity
            )
        }

        // Remove the first sample's known carrier phase using bounded integer
        // arithmetic. Only the capture-time modulo one carrier cycle is needed.
        let startIndex = reference.index(for: read.startSampleTime)
        let rotationC = reference.cosine[startIndex]
        let rotationS = reference.negativeSine[startIndex]
        let globalI = localI * rotationC - localQ * rotationS
        let globalQ = localI * rotationS + localQ * rotationC
        let wrappedPhase = atan2(globalQ, globalI)
        let didRebaseline: Bool
        if let previousWrappedPhase {
            let difference = wrappedPhase - previousWrappedPhase
            accumulatedRelativePhase += atan2(sin(difference), cos(difference))
            didRebaseline = false
        } else {
            accumulatedRelativePhase = 0
            calibrationID &+= 1
            didRebaseline = true
        }
        previousWrappedPhase = wrappedPhase
        return telemetry(
            read: read, qualityDB: qualityDB, amplitude: amplitude,
            validity: .valid, discontinuity: false, didRebaseline: didRebaseline,
            relativePhase: accumulatedRelativePhase
        )
    }

    /// Must execute on the same serial DSP context as `processNextFrame`.
    /// It requests a new reference on the next valid frame and preserves timeline
    /// checking. It does not reset or mutate the producer's queue.
    public func resetCalibration() {
        invalidatePhase()
    }

    private func invalidatePhase() {
        previousWrappedPhase = nil
        accumulatedRelativePhase = 0
    }

    private func telemetry(
        read: SampleRead,
        qualityDB: Double,
        amplitude: Double,
        validity: PhaseValidity,
        discontinuity: Bool,
        didRebaseline: Bool = false,
        relativePhase: Double? = nil
    ) -> PhaseTelemetryFrame {
        PhaseTelemetryFrame(
            sampleTimestamp: read.startSampleTime,
            relativePhaseRadians: relativePhase,
            equivalentMonostaticDisplacementMeters: relativePhase.map { -$0 * metersPerRadian },
            qualityDB: qualityDB,
            carrierAmplitude: amplitude,
            validity: validity,
            discontinuityDetected: discontinuity,
            didRebaseline: didRebaseline,
            calibrationID: calibrationID,
            droppedWriteBlocks: ringBuffer.droppedWriteBlocks,
            droppedWriteSamples: ringBuffer.droppedWriteSamples
        )
    }
}

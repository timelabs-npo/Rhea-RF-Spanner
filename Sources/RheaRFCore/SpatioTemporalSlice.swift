import Foundation

public enum SliceDecodingError: Error, Equatable, Sendable {
    case wrongLength(Int)
    case unsupportedVersion(UInt8)
    case reservedFlags
    case unknownValidity
    case invalidValue
    case inconsistentPhaseValidity
}

/// A semantic record with an explicit 64-byte little-endian wire representation.
/// Swift's in-memory layout (including SIMD3 padding) is deliberately irrelevant.
/// A missing pose/depth is nil, not a measured origin/zero-distance value.
public struct SpatioTemporalSlice: Sendable, Equatable {
    public static let encodedByteCount = 64
    public static let wireVersion: UInt8 = 1

    public let sampleTimestamp: UInt64
    public let unwrappedPhase: Float?
    public let normalizedAmplitude: Float
    /// Compatibility name: fitted-tone / residual ratio, not calibrated SNR.
    public let coherenceSNR: Float
    public let carrierFrequencyHz: Float
    public let sensorPosition: SIMD3<Float>?
    public let sensorForward: SIMD3<Float>?
    public let lidarDepthMeters: Float?
    /// A display heuristic in [0, 1], not a probability or measurement accuracy.
    public let qualityScore: Float
    public let epoch: UInt32
    public let source: ObservationSource
    public let validity: PhaseValidity
    public let didRebaseline: Bool
    public let discontinuityDetected: Bool

    public var isPhaseCoherent: Bool { validity == .valid && unwrappedPhase != nil }

    public init(
        sampleTimestamp: UInt64, unwrappedPhase: Float?, normalizedAmplitude: Float,
        coherenceSNR: Float, carrierFrequencyHz: Float,
        sensorPosition: SIMD3<Float>? = nil, sensorForward: SIMD3<Float>? = nil,
        lidarDepthMeters: Float? = nil, qualityScore: Float, epoch: UInt32,
        source: ObservationSource, validity: PhaseValidity,
        didRebaseline: Bool = false, discontinuityDetected: Bool = false
    ) {
        self.sampleTimestamp = sampleTimestamp
        self.unwrappedPhase = unwrappedPhase
        self.normalizedAmplitude = normalizedAmplitude
        self.coherenceSNR = coherenceSNR
        self.carrierFrequencyHz = carrierFrequencyHz
        self.sensorPosition = sensorPosition
        self.sensorForward = sensorForward
        self.lidarDepthMeters = lidarDepthMeters
        self.qualityScore = qualityScore
        self.epoch = epoch
        self.source = source
        self.validity = validity
        self.didRebaseline = didRebaseline
        self.discontinuityDetected = discontinuityDetected
    }

    public init(
        frame: PhaseTelemetryFrame, source: ObservationSource,
        carrierFrequencyHz: Int, epoch: UInt32
    ) {
        precondition(CarrierGrid.isSupported(carrierFrequencyHz))
        let phase = frame.relativePhaseRadians.map(Float.init)
        let amplitude = Float(frame.carrierAmplitude)
        let quality = Float(frame.qualityDB)
        let representable = (phase?.isFinite ?? true) && amplitude.isFinite
            && amplitude >= 0 && quality.isFinite
            && (frame.validity != .valid || phase != nil)
        let validity: PhaseValidity = representable ? frame.validity : .nonFiniteInput
        // Invalid wire records use unavailable phase and neutral finite payloads,
        // never silently saturated measurements or infinity that traps recording.
        self.init(
            sampleTimestamp: frame.sampleTimestamp,
            unwrappedPhase: validity == .valid ? phase : nil,
            normalizedAmplitude: representable ? amplitude : 0,
            coherenceSNR: representable ? quality : -120,
            carrierFrequencyHz: Float(carrierFrequencyHz),
            qualityScore: validity == .valid ? min(1, max(0, (quality - 3) / 20)) : 0,
            epoch: epoch, source: source, validity: validity,
            didRebaseline: frame.didRebaseline,
            discontinuityDetected: frame.discontinuityDetected
        )
    }

    /// Programmer-supplied values must satisfy the documented wire contract.
    /// Untrusted bytes must enter through the throwing decoder instead.
    public func encoded() -> Data {
        do { try validate() } catch { preconditionFailure("Invalid slice: \(error)") }
        var bytes = [UInt8](repeating: 0, count: Self.encodedByteCount)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            for i in 0..<MemoryLayout<T>.size {
                bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8))
            }
        }
        func putFloat(_ value: Float, at offset: Int) { put(value.bitPattern, at: offset) }
        put(sampleTimestamp, at: 0)
        putFloat(unwrappedPhase ?? 0, at: 8)
        putFloat(normalizedAmplitude, at: 12)
        putFloat(coherenceSNR, at: 16)
        putFloat(carrierFrequencyHz, at: 20)
        for component in 0..<3 {
            putFloat(sensorPosition?[component] ?? 0, at: 24 + component * 4)
            putFloat(sensorForward?[component] ?? 0, at: 36 + component * 4)
        }
        putFloat(lidarDepthMeters ?? 0, at: 48)
        putFloat(qualityScore, at: 52)
        put(epoch, at: 56)
        var flags = UInt32(Self.wireVersion) << 24 | validity.wireCode
        if source == .simulated { flags |= 1 << 3 }
        if didRebaseline { flags |= 1 << 4 }
        if discontinuityDetected { flags |= 1 << 5 }
        if sensorPosition != nil { flags |= 1 << 6 }
        if sensorForward != nil { flags |= 1 << 7 }
        if lidarDepthMeters != nil { flags |= 1 << 8 }
        if unwrappedPhase != nil { flags |= 1 << 9 }
        put(flags, at: 60)
        return Data(bytes)
    }

    public init(encoded data: Data) throws {
        guard data.count == Self.encodedByteCount else {
            throw SliceDecodingError.wrongLength(data.count)
        }
        // Copy exactly 64 bytes; no alignment assumptions and no unsafe loads.
        let bytes = Array(data)
        func get<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
            var result: T = 0
            for i in 0..<MemoryLayout<T>.size { result |= T(bytes[offset + i]) << (i * 8) }
            return result
        }
        func getFloat(at offset: Int) -> Float { Float(bitPattern: get(UInt32.self, at: offset)) }
        let flags = get(UInt32.self, at: 60)
        let version = UInt8(truncatingIfNeeded: flags >> 24)
        guard version == Self.wireVersion else { throw SliceDecodingError.unsupportedVersion(version) }
        guard flags & 0x00FF_FC00 == 0 else { throw SliceDecodingError.reservedFlags }
        guard let validity = PhaseValidity(wireCode: flags & 7) else {
            throw SliceDecodingError.unknownValidity
        }
        func present(_ bit: Int) -> Bool { flags & (1 << bit) != 0 }
        func vector(at offset: Int) -> SIMD3<Float> {
            SIMD3(getFloat(at: offset), getFloat(at: offset + 4), getFloat(at: offset + 8))
        }
        self.init(
            sampleTimestamp: get(UInt64.self, at: 0),
            unwrappedPhase: present(9) ? getFloat(at: 8) : nil,
            normalizedAmplitude: getFloat(at: 12), coherenceSNR: getFloat(at: 16),
            carrierFrequencyHz: getFloat(at: 20),
            sensorPosition: present(6) ? vector(at: 24) : nil,
            sensorForward: present(7) ? vector(at: 36) : nil,
            lidarDepthMeters: present(8) ? getFloat(at: 48) : nil,
            qualityScore: getFloat(at: 52), epoch: get(UInt32.self, at: 56),
            source: present(3) ? .simulated : .microphone, validity: validity,
            didRebaseline: present(4), discontinuityDetected: present(5)
        )
        try validate()
        // The v1 encoding is canonical: absent scalar/vector payloads are zero.
        if (!present(9) && get(UInt32.self, at: 8) != 0)
            || (!present(6) && (24..<36).contains { bytes[$0] != 0 })
            || (!present(7) && (36..<48).contains { bytes[$0] != 0 })
            || (!present(8) && get(UInt32.self, at: 48) != 0) {
            throw SliceDecodingError.invalidValue
        }
    }

    private func validate() throws {
        let frequency = Double(carrierFrequencyHz)
        guard normalizedAmplitude.isFinite && normalizedAmplitude >= 0,
              coherenceSNR.isFinite,
              qualityScore.isFinite && (0...1).contains(qualityScore),
              frequency.isFinite && (18_000...22_000).contains(frequency),
              frequency.truncatingRemainder(dividingBy: 500) == 0,
              unwrappedPhase?.isFinite ?? true else { throw SliceDecodingError.invalidValue }
        for vector in [sensorPosition, sensorForward].compactMap({ $0 }) {
            guard vector.x.isFinite && vector.y.isFinite && vector.z.isFinite else {
                throw SliceDecodingError.invalidValue
            }
        }
        if let direction = sensorForward, direction == .zero { throw SliceDecodingError.invalidValue }
        if let depth = lidarDepthMeters, !depth.isFinite || depth <= 0 { throw SliceDecodingError.invalidValue }
        guard (validity == .valid) == (unwrappedPhase != nil) else {
            throw SliceDecodingError.inconsistentPhaseValidity
        }
    }
}

private extension PhaseValidity {
    var wireCode: UInt32 {
        switch self {
        case .valid: 0
        case .lowSignal: 1
        case .lowQuality: 2
        case .inputDiscontinuity: 3
        case .nonFiniteInput: 4
        }
    }

    init?(wireCode: UInt32) {
        switch wireCode {
        case 0: self = .valid
        case 1: self = .lowSignal
        case 2: self = .lowQuality
        case 3: self = .inputDiscontinuity
        case 4: self = .nonFiniteInput
        default: return nil
        }
    }
}

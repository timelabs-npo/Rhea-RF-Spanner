import Foundation

/// Bounded telemetry storage. Own it on one serial executor (the app uses MainActor).
/// It deliberately does not claim Sendable or provide audio-callback-safe methods.
/// Spectra are optional companion records; they are not squeezed into 64 bytes.
public final class ReplayTape {
    public let capacity: Int
    public private(set) var count = 0
    private var nextWriteIndex = 0
    private var records: Data
    private var spectra: [SpectrumFrame?]

    public init(capacity: Int = 2_048) {
        precondition((1...2_048).contains(capacity))
        self.capacity = capacity
        records = Data(repeating: 0, count: capacity * SpatioTemporalSlice.encodedByteCount)
        spectra = [SpectrumFrame?](repeating: nil, count: capacity)
    }

    public func append(_ slice: SpatioTemporalSlice, spectrum: SpectrumFrame? = nil) {
        let offset = nextWriteIndex * SpatioTemporalSlice.encodedByteCount
        records.replaceSubrange(offset..<(offset + SpatioTemporalSlice.encodedByteCount), with: slice.encoded())
        spectra[nextWriteIndex] = spectrum
        nextWriteIndex = (nextWriteIndex + 1) % capacity
        count = min(capacity, count + 1)
    }

    /// Logical indices are chronological: zero is the oldest retained record.
    public func slice(at index: Int) -> SpatioTemporalSlice? {
        guard let physicalIndex = physicalIndex(for: index) else { return nil }
        let offset = physicalIndex * SpatioTemporalSlice.encodedByteCount
        return try? SpatioTemporalSlice(encoded: records.subdata(in: offset..<(offset + SpatioTemporalSlice.encodedByteCount)))
    }

    public func spectrum(at index: Int) -> SpectrumFrame? {
        guard let physicalIndex = physicalIndex(for: index) else { return nil }
        return spectra[physicalIndex]
    }

    public func removeAll() {
        count = 0
        nextWriteIndex = 0
        records.resetBytes(in: records.startIndex..<records.endIndex)
        spectra = [SpectrumFrame?](repeating: nil, count: capacity)
    }

    /// Concatenated v1 records only, in chronological order. No raw audio.
    public func encodedFrames() -> Data {
        var result = Data()
        result.reserveCapacity(count * SpatioTemporalSlice.encodedByteCount)
        for index in 0..<count {
            let offset = physicalIndex(for: index)! * SpatioTemporalSlice.encodedByteCount
            result.append(records.subdata(in: offset..<(offset + SpatioTemporalSlice.encodedByteCount)))
        }
        return result
    }

    private func physicalIndex(for logicalIndex: Int) -> Int? {
        guard logicalIndex >= 0 && logicalIndex < count else { return nil }
        let oldest = count == capacity ? nextWriteIndex : 0
        return (oldest + logicalIndex) % capacity
    }
}

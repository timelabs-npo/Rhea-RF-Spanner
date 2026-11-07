import Synchronization

/// A read describes the actual capture timeline, including gaps inside a block.
public struct SampleRead: Sendable {
    public let startSampleTime: UInt64
    public let nextSampleTime: UInt64
    public let samplesAreContiguous: Bool
    public let timestampsAreValid: Bool
}

/// Bounded single-producer / single-consumer queue. No allocation or locks occur
/// in `write` or `read`. Entire input blocks are rejected when space is exhausted.
///
/// SAFETY CONTRACT for `@unchecked Sendable`:
/// - Exactly one serial context calls `write`; exactly one calls `read`.
/// - The producer release-publishes initialized slots. The consumer acquire-loads
///   that cursor before accessing them, then release-publishes freed slots.
/// - The producer acquire-loads the read cursor before reusing storage.
/// - Callers own their passed buffers for the duration of each call.
/// - The object must remain alive until both contexts have stopped. There is
///   deliberately no reset operation: each audio session gets a fresh queue.
///
/// Per-sample timestamps prevent dropped capture blocks from being compressed
/// into a falsely contiguous oscillator timeline. No Swift object-layout or
/// cache-line padding guarantee is assumed.
public final class SPSCFloatRingBuffer: @unchecked Sendable {
    private struct StoredSample {
        var sampleTime: UInt64
        var value: Float
        var timestampIsValid: Bool
    }

    public let capacity: Int
    private let mask: UInt64
    private let storage: UnsafeMutablePointer<StoredSample>
    private let writeCursor = Atomic<UInt64>(0)
    private let readCursor = Atomic<UInt64>(0)
    private let rejectedBlocks = Atomic<UInt64>(0)
    private let rejectedSamples = Atomic<UInt64>(0)

    public init(capacity: Int = 65_536) {
        precondition(
            capacity > 0 && capacity <= 1_048_576 && (capacity & (capacity - 1)) == 0,
            "Ring capacity must be a power of two, at most 1,048,576 samples."
        )
        self.capacity = capacity
        self.mask = UInt64(capacity - 1)
        self.storage = .allocate(capacity: capacity)
        self.storage.initialize(
            repeating: StoredSample(sampleTime: 0, value: 0, timestampIsValid: false),
            count: capacity
        )
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// `startSampleTime` is the first sample's capture time, even following a
    /// rejected write. It must not be a count of successfully enqueued samples.
    /// When the hardware timestamp is unavailable, pass `timestampIsValid: false`;
    /// an invented timestamp must not establish a phase baseline.
    @discardableResult
    public func write(
        from source: UnsafePointer<Float>,
        count: Int,
        startSampleTime: UInt64,
        timestampIsValid: Bool = true
    ) -> Bool {
        guard count > 0 else { return count == 0 }
        let currentWrite = writeCursor.load(ordering: .relaxed)
        let currentRead = readCursor.load(ordering: .acquiring)
        let occupied = currentWrite &- currentRead
        guard count <= capacity, occupied <= UInt64(capacity),
              UInt64(count) <= UInt64(capacity) - occupied else {
            rejectedBlocks.wrappingAdd(1, ordering: .relaxed)
            rejectedSamples.wrappingAdd(UInt64(count), ordering: .relaxed)
            return false
        }

        for index in 0..<count {
            let slot = Int((currentWrite &+ UInt64(index)) & mask)
            storage[slot] = StoredSample(
                sampleTime: startSampleTime &+ UInt64(index),
                value: source[index],
                timestampIsValid: timestampIsValid
            )
        }
        writeCursor.store(currentWrite &+ UInt64(count), ordering: .releasing)
        return true
    }

    /// Returns nil without consuming samples if a complete read is unavailable.
    /// Such an empty poll is normal flow control, not a "dropped read frame".
    public func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> SampleRead? {
        guard count > 0 && count <= capacity else { return nil }
        let currentRead = readCursor.load(ordering: .relaxed)
        let currentWrite = writeCursor.load(ordering: .acquiring)
        guard currentWrite &- currentRead >= UInt64(count) else { return nil }

        let first = storage[Int(currentRead & mask)]
        var expectedTime = first.sampleTime
        var contiguous = true
        var timestampsValid = true
        for index in 0..<count {
            let sample = storage[Int((currentRead &+ UInt64(index)) & mask)]
            destination[index] = sample.value
            contiguous = contiguous && sample.sampleTime == expectedTime
            timestampsValid = timestampsValid && sample.timestampIsValid
            expectedTime = sample.sampleTime &+ 1
        }
        readCursor.store(currentRead &+ UInt64(count), ordering: .releasing)
        return SampleRead(
            startSampleTime: first.sampleTime,
            nextSampleTime: expectedTime,
            samplesAreContiguous: contiguous,
            timestampsAreValid: timestampsValid
        )
    }

    /// A bounded instantaneous estimate. Only the consumer should use this for
    /// flow control; `read` still performs its own authoritative availability check.
    public var availableToRead: Int {
        let read = readCursor.load(ordering: .acquiring)
        let write = writeCursor.load(ordering: .acquiring)
        return Int(min(UInt64(capacity), write &- read))
    }

    public var droppedWriteBlocks: UInt64 { rejectedBlocks.load(ordering: .relaxed) }
    public var droppedWriteSamples: UInt64 { rejectedSamples.load(ordering: .relaxed) }
}

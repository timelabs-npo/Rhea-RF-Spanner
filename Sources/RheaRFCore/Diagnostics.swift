/// Aggregate digital sample amplitudes, in full-scale units rather than SPL.
/// No input samples or buffer references are retained.
public struct SignalBlockStatistics: Sendable, Codable, Equatable {
    public let sampleCount: Int
    public let finiteSampleCount: Int
    public let zeroSampleCount: Int
    public let nonFiniteSampleCount: Int
    public let clippedSampleCount: Int
    public let minimum: Double?
    public let maximum: Double?
    public let mean: Double?
    public let rms: Double?
    public let peak: Double?

    /// One allocation-free pass over caller-owned memory. All amplitude metrics
    /// and zero/clip counts exclude NaN and infinity. Both signed zeros count.
    public static func measure(_ samples: UnsafeBufferPointer<Float>) -> SignalBlockStatistics {
        var finiteCount = 0
        var zeroCount = 0
        var nonFiniteCount = 0
        var clippedCount = 0
        var minimum = Double.infinity
        var maximum = -Double.infinity
        var sum = 0.0
        var sumOfSquares = 0.0
        var peak = 0.0

        for sample in samples {
            guard sample.isFinite else {
                nonFiniteCount += 1
                continue
            }
            let value = Double(sample)
            let magnitude = abs(value)
            finiteCount += 1
            if sample == 0 { zeroCount += 1 }
            if magnitude >= 0.999 { clippedCount += 1 }
            minimum = Swift.min(minimum, value)
            maximum = Swift.max(maximum, value)
            peak = Swift.max(peak, magnitude)
            sum += value
            sumOfSquares += value * value
        }

        // Even Int.max finite Float values and their squares fit in Double
        // accumulation; conversion occurs before multiplication.
        let hasFiniteSamples = finiteCount > 0
        return SignalBlockStatistics(
            sampleCount: samples.count,
            finiteSampleCount: finiteCount,
            zeroSampleCount: zeroCount,
            nonFiniteSampleCount: nonFiniteCount,
            clippedSampleCount: clippedCount,
            minimum: hasFiniteSamples ? minimum : nil,
            maximum: hasFiniteSamples ? maximum : nil,
            mean: hasFiniteSamples ? sum / Double(finiteCount) : nil,
            rms: hasFiniteSamples ? (sumOfSquares / Double(finiteCount)).squareRoot() : nil,
            peak: hasFiniteSamples ? peak : nil
        )
    }
}

/// Bounded diagnostic text. Callers must supply non-sensitive summaries only;
/// truncation is not privacy redaction. Sequence defines order, not elapsed time.
public struct DiagnosticEvent: Sendable, Codable, Equatable {
    public let sequence: UInt64
    public let elapsedSeconds: Double
    public let category: String
    public let code: String
    public let message: String

    public init(
        sequence: UInt64,
        elapsedSeconds: Double,
        category: String,
        code: String,
        message: String
    ) {
        self.sequence = sequence
        self.elapsedSeconds = elapsedSeconds.isFinite && elapsedSeconds >= 0 ? elapsedSeconds : 0
        self.category = String(category.prefix(64))
        self.code = String(code.prefix(64))
        self.message = String(message.prefix(512))
    }

    private enum CodingKeys: String, CodingKey {
        case sequence, elapsedSeconds, category, code, message
    }

    /// Decoded events obey the same time and text bounds as locally made ones.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sequence: try values.decode(UInt64.self, forKey: .sequence),
            elapsedSeconds: try values.decode(Double.self, forKey: .elapsedSeconds),
            category: try values.decode(String.self, forKey: .category),
            code: try values.decode(String.self, forKey: .code),
            message: try values.decode(String.self, forKey: .message)
        )
    }
}

/// A value-owned ring of diagnostic events. Own each mutable instance on one
/// serial executor: Sendable permits value transfer, not concurrent mutation.
/// This is NOT concurrent-safe and MUST NOT be used from an audio callback.
/// Strings, copy-on-write storage, and chronological snapshots can allocate.
public struct BoundedDiagnosticLog: Sendable {
    private var storage: [DiagnosticEvent?]
    private var nextWriteIndex = 0
    private var count = 0
    private var lastSequence: UInt64 = 0
    public private(set) var droppedEventCount: UInt64 = 0

    /// Clamp to 1...4096 slots, including negative and extreme Int values.
    /// Slots are preallocated; appending never grows the ring's slot count.
    public init(capacity: Int = 128) {
        storage = [DiagnosticEvent?](repeating: nil, count: min(max(capacity, 1), 4_096))
    }

    /// Oldest-to-newest append order, independent of supplied timestamps.
    public var events: [DiagnosticEvent] {
        var snapshot: [DiagnosticEvent] = []
        snapshot.reserveCapacity(count)
        var index = count == storage.count ? nextWriteIndex : 0
        for _ in 0..<count {
            if let event = storage[index] { snapshot.append(event) }
            index = index == storage.count - 1 ? 0 : index + 1
        }
        return snapshot
    }

    public mutating func append(
        elapsedSeconds: Double,
        category: String,
        code: String,
        message: String
    ) {
        // Never reuse or wrap a sequence. After emitting UInt64.max, reject
        // subsequent events and saturate the drop counter rather than trap.
        guard lastSequence < UInt64.max else {
            recordDrop()
            return
        }
        lastSequence += 1
        storage[nextWriteIndex] = DiagnosticEvent(
            sequence: lastSequence,
            elapsedSeconds: elapsedSeconds,
            category: category,
            code: code,
            message: message
        )
        nextWriteIndex = nextWriteIndex == storage.count - 1 ? 0 : nextWriteIndex + 1
        if count == storage.count {
            recordDrop()
        } else {
            count += 1
        }
    }

    /// Release retained text and reset drops, keeping storage and the lifetime
    /// sequence. A cleared log cannot issue an old sequence again.
    public mutating func removeAll() {
        for index in storage.indices { storage[index] = nil }
        nextWriteIndex = 0
        count = 0
        droppedEventCount = 0
    }

    private mutating func recordDrop() {
        if droppedEventCount < UInt64.max { droppedEventCount += 1 }
    }
}

/// Observed pipeline flow only; no state diagnoses a hardware failure or cause.
public enum PipelineHealth: String, Sendable, Codable {
    case idle
    case waitingForInput
    case inputStalled
    case waitingForProcessing
    case processingStalled
    case healthy

    /// Caller supplies per-run counters and monotonic durations in seconds.
    /// No clock is read. Invalid elapsed becomes 0; invalid configuration
    /// durations use 2 seconds. Missing/invalid ages use elapsed run time,
    /// conservatively withholding a freshness claim after the stall threshold.
    public static func evaluate(
        isRunning: Bool,
        elapsedSeconds: Double,
        inputCallbacks: UInt64,
        processedFrames: UInt64,
        secondsSinceInput: Double?,
        secondsSinceProcessing: Double?,
        startupGraceSeconds: Double = 2,
        stallThresholdSeconds: Double = 2
    ) -> PipelineHealth {
        guard isRunning else { return .idle }
        let elapsed = validDuration(elapsedSeconds) ?? 0
        let grace = validDuration(startupGraceSeconds) ?? 2
        let threshold = validDuration(stallThresholdSeconds) ?? 2
        let isStarting = elapsed < grace

        guard inputCallbacks > 0 else {
            return isStarting ? .waitingForInput : .inputStalled
        }
        // Upstream staleness takes precedence even if processing is also stale
        // or has not started. Equality with the threshold remains fresh.
        let inputAge = validDuration(secondsSinceInput) ?? elapsed
        if inputAge > threshold { return .inputStalled }
        guard processedFrames > 0 else {
            return isStarting ? .waitingForProcessing : .processingStalled
        }
        let processingAge = validDuration(secondsSinceProcessing) ?? elapsed
        if processingAge > threshold { return .processingStalled }
        return .healthy
    }

    private static func validDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

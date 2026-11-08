/// Pure reduction of exactly one 3 x 3 image-center patch. The buffer adapter
/// must establish matching dimensions, supported formats, strides, and locks
/// before constructing these nine transient values.
public enum SpatialDepthReducer {
    public static func reduce(samples: [SpatialDepthSample]) -> SpatialDepthSummary {
        guard samples.count == 9 else { return .unavailable(.invalidPatchSize) }
        var accepted: [Float] = []
        accepted.reserveCapacity(9)
        var lowestConfidence = SpatialDepthConfidence.high
        for sample in samples {
            guard sample.depthMeters.isFinite, sample.depthMeters > 0,
                  let confidence = sample.confidence, confidence != .low else { continue }
            accepted.append(sample.depthMeters)
            if confidence == .medium { lowestConfidence = .medium }
        }
        guard accepted.count >= 5 else { return .unavailable(.insufficientAcceptedSamples) }
        accepted.sort()
        let center = accepted.count / 2
        // Sorted positive values make this bounded difference safe at Float
        // maxima while preserving equal positive subnormals (halving each
        // operand before addition could incorrectly turn those into zero).
        let median = accepted.count.isMultiple(of: 2)
            ? accepted[center - 1] + (accepted[center] - accepted[center - 1]) / 2
            : accepted[center]
        guard let measurement = SpatialDepthMeasurement(
            medianMeters: median, acceptedSampleCount: accepted.count,
            confidence: lowestConfidence
        ) else { return .unavailable(.insufficientAcceptedSamples) }
        return .available(measurement)
    }
}

/// Small deterministic G2a policy. One serialized non-audio owner must call all
/// mutating methods, including tick; Sendable permits transferring ownership,
/// not simultaneous unsynchronized mutation. Feed every frame before coalescing
/// published snapshots so a tracking-loss callback cannot be hidden by a later
/// normal callback. The adapter owns permission, capability, and session work.
public struct SpatialContextPolicy: Sendable {
    public static let firstFrameTimeoutSeconds: Double = 3
    public static let subsequentFrameTimeoutSeconds: Double = 2
    public static let normalFramesRequiredForRecovery = 3

    private var lifecycle: SpatialContextLifecycle = .off
    private var runID: SpatialRunID?
    private var highestRunID: SpatialRunID?
    private var startedAt: Double?
    private var lastObservedTime: Double?
    private var lastFrameArrival: Double?
    private var firstARTimestamp: Double?
    private var highestARTimestamp: Double?
    private var highestFrameSequence: UInt64?
    private var epochCounter: UInt64 = 0
    private var activeEpoch: UInt64?
    private var recoveryCount = 0
    private var frame: SpatialFrameSnapshot?
    private var tracking: SpatialTrackingState = .unavailable
    private var poseUnavailableReason: SpatialPoseUnavailableReason? = .stopped
    private var associationStatus: SpatialAssociationStatus = .notRequested
    private var frameCount: UInt64 = 0
    private var usablePoseFrameCount: UInt64 = 0
    private var validDepthFrameCount: UInt64 = 0

    public init() {}

    public var snapshot: SpatialContextSnapshot {
        SpatialContextSnapshot(
            lifecycle: lifecycle, runID: runID, coordinateEpoch: activeEpoch,
            frame: frame, tracking: tracking, poseUnavailableReason: poseUnavailableReason,
            associationStatus: associationStatus, frameCount: frameCount,
            usablePoseFrameCount: usablePoseFrameCount, validDepthFrameCount: validDepthFrameCount
        )
    }

    public var isRunning: Bool {
        switch lifecycle {
        case .starting, .cameraActive: true
        case .off, .stopped: false
        }
    }

    /// Authorization is an adapter prerequisite. Beginning this pure policy
    /// does not request permission or start any sensor. Repeated starts while
    /// active, reused IDs, and invalid clock values leave state unchanged.
    @discardableResult
    public mutating func begin(runID newRunID: SpatialRunID, at time: Double) -> Bool {
        guard !isRunning, time.isFinite,
              highestRunID.map({ newRunID > $0 }) ?? true else { return false }
        lifecycle = .starting
        runID = newRunID
        highestRunID = newRunID
        startedAt = time
        lastObservedTime = time
        lastFrameArrival = nil
        firstARTimestamp = nil
        highestARTimestamp = nil
        highestFrameSequence = nil
        epochCounter = 0
        activeEpoch = nil
        recoveryCount = 0
        frame = nil
        tracking = .unavailable
        poseUnavailableReason = .awaitingFrames
        associationStatus = .trackingUnavailable
        frameCount = 0
        usablePoseFrameCount = 0
        validDepthFrameCount = 0
        return true
    }

    /// Returns false for a retired run, a repeated/out-of-order sequence, or a
    /// frame at/after its watchdog deadline. Rejected identities cannot refresh
    /// the watchdog, close a new run, or overwrite its current snapshot.
    @discardableResult
    public mutating func receive(_ input: SpatialFrameInput, at time: Double) -> Bool {
        guard isRunning, input.runID == runID,
              highestFrameSequence.map({ input.frameSequence > $0 }) ?? true else { return false }
        guard tick(at: time) == nil, isRunning, let start = startedAt else { return false }

        highestFrameSequence = input.frameSequence
        lastFrameArrival = time
        lifecycle = .cameraActive
        frameCount = Self.incremented(frameCount)
        tracking = input.tracking
        if case .available = input.depth { validDepthFrameCount = Self.incremented(validDepthFrameCount) }

        let rawTimeIsValid = input.arTimestampSeconds.isFinite && input.arTimestampSeconds >= 0
        if firstARTimestamp == nil, rawTimeIsValid { firstARTimestamp = input.arTimestampSeconds }
        let captureIsIncreasing = rawTimeIsValid
            && (highestARTimestamp.map({ input.arTimestampSeconds > $0 }) ?? true)
        let captureElapsed: Double?
        if rawTimeIsValid, let origin = firstARTimestamp {
            let elapsed = input.arTimestampSeconds - origin
            captureElapsed = elapsed.isFinite && elapsed >= 0 ? elapsed : nil
        } else {
            captureElapsed = nil
        }
        if rawTimeIsValid,
           highestARTimestamp.map({ input.arTimestampSeconds > $0 }) ?? true {
            highestARTimestamp = input.arTimestampSeconds
        }

        var acceptedTransform: SpatialMatrix4x4?
        if !captureIsIncreasing || captureElapsed == nil {
            closeEpoch(reason: .timingInvalid, association: .timingUnavailable)
        } else if input.tracking != .normal {
            closeEpoch(reason: .trackingUnavailable, association: .trackingUnavailable)
        } else if input.worldFromCamera == nil {
            closeEpoch(reason: .missingTransform, association: .trackingUnavailable)
        } else if input.worldFromCamera?.isFinite != true {
            closeEpoch(reason: .invalidTransform, association: .trackingUnavailable)
        } else {
            if activeEpoch == nil {
                recoveryCount += 1
                if recoveryCount == Self.normalFramesRequiredForRecovery {
                    guard epochCounter < UInt64.max else {
                        stop(reason: .identifierExhausted)
                        return false
                    }
                    epochCounter += 1
                    activeEpoch = epochCounter
                }
            }
            if activeEpoch != nil {
                acceptedTransform = input.worldFromCamera
                poseUnavailableReason = nil
                associationStatus = .clockMappingUnavailable
                usablePoseFrameCount = Self.incremented(usablePoseFrameCount)
            } else {
                poseUnavailableReason = .recoveringTracking
                associationStatus = .trackingUnavailable
            }
        }

        frame = SpatialFrameSnapshot(
            frameSequence: input.frameSequence, arCaptureElapsedSeconds: captureElapsed,
            receivedElapsedSeconds: time - start, worldFromCamera: acceptedTransform,
            depth: input.depth
        )
        return true
    }

    /// Tracking notifications are not captured frames. Loss closes the current
    /// epoch immediately, including when no subsequent frame arrives. A normal
    /// notification cannot restore a pose or advance the frame recovery streak.
    /// Neither kind changes frame counters, capture/receipt timestamps, or the
    /// frame-arrival watchdog deadline.
    @discardableResult
    public mutating func receiveTrackingState(
        _ newTracking: SpatialTrackingState, runID eventRunID: SpatialRunID, at time: Double
    ) -> Bool {
        guard isRunning, eventRunID == runID else { return false }
        guard tick(at: time) == nil, isRunning else { return false }

        tracking = newTracking
        if newTracking != .normal {
            closeEpoch(reason: .trackingUnavailable, association: .trackingUnavailable)
            if let previous = frame {
                frame = SpatialFrameSnapshot(
                    frameSequence: previous.frameSequence,
                    arCaptureElapsedSeconds: previous.arCaptureElapsedSeconds,
                    receivedElapsedSeconds: previous.receivedElapsedSeconds,
                    worldFromCamera: nil, depth: previous.depth
                )
            }
        } else if poseUnavailableReason == .trackingUnavailable {
            // Tracking quality can recover before a usable frame arrives.
            // Describe that wait without counting the notification as a frame
            // or replacing an unrelated capture-clock/transform fault.
            poseUnavailableReason = frame == nil ? .awaitingFrames : .recoveringTracking
        }
        return true
    }

    /// Deadlines are inclusive (>=), based on frame arrival rather than normal
    /// tracking. Invalid/regressing app clocks abort the run; AR capture-clock
    /// faults instead close its coordinate epoch and permit debounced recovery.
    /// The owner must act on a returned stop reason to end the combined run.
    @discardableResult
    public mutating func tick(at time: Double) -> SpatialStopReason? {
        guard isRunning, let start = startedAt else { return nil }
        guard time.isFinite, time >= start,
              lastObservedTime.map({ time >= $0 }) ?? true,
              (time - start).isFinite else {
            stop(reason: .timingInvalid)
            return .timingInvalid
        }
        lastObservedTime = time
        let reason: SpatialStopReason?
        if let lastFrameArrival {
            reason = time - lastFrameArrival >= Self.subsequentFrameTimeoutSeconds ? .frameTimeout : nil
        } else {
            reason = time - start >= Self.firstFrameTimeoutSeconds ? .firstFrameTimeout : nil
        }
        if let reason { stop(reason: reason) }
        return reason
    }

    /// Stops are idempotent: the first terminal reason is preserved. Teardown
    /// itself belongs to the app coordinator and must not occur inline in an
    /// AR delegate callback. No automatic restart or epoch reuse is possible.
    public mutating func stop(reason: SpatialStopReason) {
        guard isRunning else { return }
        lifecycle = .stopped(reason)
        frame = nil
        tracking = .unavailable
        let isStale = reason == .firstFrameTimeout || reason == .frameTimeout
        closeEpoch(reason: isStale ? .stale : .stopped, association: isStale ? .stale : .notRequested)
        startedAt = nil
        lastObservedTime = nil
        lastFrameArrival = nil
        firstARTimestamp = nil
        highestARTimestamp = nil
        highestFrameSequence = nil
    }

    private mutating func closeEpoch(
        reason: SpatialPoseUnavailableReason, association: SpatialAssociationStatus
    ) {
        activeEpoch = nil
        recoveryCount = 0
        poseUnavailableReason = reason
        associationStatus = association
    }

    private static func incremented(_ count: UInt64) -> UInt64 {
        count == UInt64.max ? count : count + 1
    }
}

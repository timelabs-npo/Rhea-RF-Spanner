/// App-local identifiers, never device identities or clock anchors. A policy
/// instance requires strictly increasing run IDs for successive explicit starts.
public typealias SpatialRunID = UInt64

/// Column-major AR world-from-camera convention; this is a local pose estimate,
/// not a calibrated microphone position. No Apple framework or codec is used.
public struct SpatialMatrix4x4: Sendable, Equatable {
    public let column0: SIMD4<Float>
    public let column1: SIMD4<Float>
    public let column2: SIMD4<Float>
    public let column3: SIMD4<Float>

    public init(
        column0: SIMD4<Float>, column1: SIMD4<Float>,
        column2: SIMD4<Float>, column3: SIMD4<Float>
    ) {
        self.column0 = column0
        self.column1 = column1
        self.column2 = column2
        self.column3 = column3
    }

    public static let identity = SpatialMatrix4x4(
        column0: SIMD4(1, 0, 0, 0), column1: SIMD4(0, 1, 0, 0),
        column2: SIMD4(0, 0, 1, 0), column3: SIMD4(0, 0, 0, 1)
    )

    public var isFinite: Bool {
        for column in [column0, column1, column2, column3] {
            for component in 0..<4 where !column[component].isFinite { return false }
        }
        return true
    }
}

public enum SpatialTrackingLimitation: String, Sendable, Equatable {
    case initializing, excessiveMotion, insufficientFeatures, relocalizing, unknown
}

public enum SpatialTrackingState: Sendable, Equatable {
    case unavailable
    case limited(SpatialTrackingLimitation)
    case normal
}

/// Categorical AR confidence, never a probability or metric error estimate.
public enum SpatialDepthConfidence: UInt8, Sendable, Equatable {
    case low = 0, medium = 1, high = 2
}

public enum SpatialDepthUnavailableReason: String, Sendable, Equatable {
    case notRequested, unsupported, missingDepth, missingConfidence
    case unsupportedDepthFormat, unsupportedConfidenceFormat
    case invalidDimensions, invalidStride, lockFailed, missingBaseAddress
    case invalidPatchSize, insufficientAcceptedSamples
}

/// Only a bounded scalar reduction survives the frame callback. Confidence is
/// the lowest accepted category, rather than an invented numerical average.
public struct SpatialDepthMeasurement: Sendable, Equatable {
    public let medianMeters: Float
    public let acceptedSampleCount: Int
    public let confidence: SpatialDepthConfidence

    public init?(
        medianMeters: Float, acceptedSampleCount: Int,
        confidence: SpatialDepthConfidence
    ) {
        guard medianMeters.isFinite, medianMeters > 0,
              (5...9).contains(acceptedSampleCount), confidence != .low else { return nil }
        self.medianMeters = medianMeters
        self.acceptedSampleCount = acceptedSampleCount
        self.confidence = confidence
    }
}

public enum SpatialDepthSummary: Sendable, Equatable {
    case unavailable(SpatialDepthUnavailableReason)
    case available(SpatialDepthMeasurement)
}

/// A transient pure reducer input, never a stored image or depth buffer.
public struct SpatialDepthSample: Sendable, Equatable {
    public let depthMeters: Float
    /// Nil includes an unknown category; it is never promoted to high confidence.
    public let confidence: SpatialDepthConfidence?

    public init(depthMeters: Float, confidence: SpatialDepthConfidence?) {
        self.depthMeters = depthMeters
        self.confidence = confidence
    }
}

/// G2a has no successful capture-association case. Matching numerical relative
/// timestamps cannot change this: an AR/audio clock mapping is not established.
public enum SpatialAssociationStatus: String, Sendable, Equatable {
    case notRequested, clockMappingUnavailable, trackingUnavailable, timingUnavailable, stale
}

public enum SpatialStopReason: String, Sendable, Equatable {
    case user, inactive, audioStopped, deadline, sessionFailure, interruption
    case firstFrameTimeout, frameTimeout, timingInvalid, identifierExhausted
}

public enum SpatialContextLifecycle: Sendable, Equatable {
    case off
    case starting
    case cameraActive
    case stopped(SpatialStopReason)
}

public enum SpatialPoseUnavailableReason: String, Sendable, Equatable {
    case awaitingFrames, recoveringTracking, trackingUnavailable
    case missingTransform, invalidTransform, timingInvalid, sequenceNotIncreasing, stale, stopped
}

/// Transient frame metadata for the serialized policy owner. Absolute AR time
/// is accepted only to derive a private run-relative interval; it is never
/// copied into published snapshots, diagnostics, Replay, or a report codec.
public struct SpatialFrameInput: Sendable, Equatable {
    public let runID: SpatialRunID
    public let frameSequence: UInt64
    public let arTimestampSeconds: Double
    public let worldFromCamera: SpatialMatrix4x4?
    public let tracking: SpatialTrackingState
    public let depth: SpatialDepthSummary

    public init(
        runID: SpatialRunID, frameSequence: UInt64, arTimestampSeconds: Double,
        worldFromCamera: SpatialMatrix4x4?, tracking: SpatialTrackingState,
        depth: SpatialDepthSummary = .unavailable(.notRequested)
    ) {
        self.runID = runID
        self.frameSequence = frameSequence
        self.arTimestampSeconds = arTimestampSeconds
        self.worldFromCamera = worldFromCamera
        self.tracking = tracking
        self.depth = depth
    }
}

public struct SpatialFrameSnapshot: Sendable, Equatable {
    public let frameSequence: UInt64
    /// AR capture clock relative to the first valid AR timestamp in this run.
    public let arCaptureElapsedSeconds: Double?
    /// Arrival on the injected app monotonic clock, relative to explicit start.
    /// This is scheduling evidence, not capture time or an audio clock mapping.
    public let receivedElapsedSeconds: Double
    /// Present only after tracking recovery in the current logical epoch.
    public let worldFromCamera: SpatialMatrix4x4?
    public let depth: SpatialDepthSummary
}

/// Immutable current state only: there is no history and no automatic encoding.
/// A closed epoch has no current pose; stopped/stale states have no frame.
public struct SpatialContextSnapshot: Sendable, Equatable {
    public let lifecycle: SpatialContextLifecycle
    public let runID: SpatialRunID?
    public let coordinateEpoch: UInt64?
    public let frame: SpatialFrameSnapshot?
    public let tracking: SpatialTrackingState
    public let poseUnavailableReason: SpatialPoseUnavailableReason?
    public let associationStatus: SpatialAssociationStatus
    public let frameCount: UInt64
    public let usablePoseFrameCount: UInt64
    public let validDepthFrameCount: UInt64
}

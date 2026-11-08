import XCTest
@testable import RheaRFCore

/// Deterministic scalar policy fixtures. No camera, microphone, Apple clock
/// mapping, physical tracking quality, or native session lifecycle is claimed.
final class SpatialContextPolicyTests: XCTestCase {
    private func input(
        run: UInt64 = 1, sequence: UInt64, timestamp: Double,
        tracking: SpatialTrackingState = .normal,
        matrix: SpatialMatrix4x4? = .identity,
        depth: SpatialDepthSummary = .unavailable(.notRequested)
    ) -> SpatialFrameInput {
        SpatialFrameInput(
            runID: run, frameSequence: sequence, arTimestampSeconds: timestamp,
            worldFromCamera: matrix, tracking: tracking, depth: depth
        )
    }

    private func recoveredPolicy() -> SpatialContextPolicy {
        var policy = SpatialContextPolicy()
        XCTAssertTrue(policy.begin(runID: 1, at: 10))
        for sequence in UInt64(1)...3 {
            XCTAssertTrue(policy.receive(
                input(sequence: sequence, timestamp: 100 + Double(sequence)),
                at: 10 + Double(sequence) / 10
            ))
        }
        XCTAssertEqual(policy.snapshot.coordinateEpoch, 1)
        return policy
    }

    func testConstructionInspectionAndExplicitStopHaveNoStartSideEffect() {
        var policy = SpatialContextPolicy()
        XCTAssertEqual(policy.snapshot.lifecycle, .off)
        XCTAssertFalse(policy.isRunning)
        XCTAssertNil(policy.snapshot.runID)
        XCTAssertNil(policy.tick(at: 100))
        policy.stop(reason: .user)
        XCTAssertEqual(policy.snapshot.lifecycle, .off)
        XCTAssertFalse(policy.receive(input(sequence: 1, timestamp: 100), at: 100))
        XCTAssertTrue(policy.begin(runID: 1, at: 100))
        XCTAssertEqual(policy.snapshot.lifecycle, .starting)
        XCTAssertNil(policy.snapshot.frame)
        XCTAssertEqual(policy.snapshot.poseUnavailableReason, .awaitingFrames)
        XCTAssertFalse(policy.begin(runID: 2, at: 100))
        policy.stop(reason: .user)
        policy.stop(reason: .sessionFailure)
        XCTAssertEqual(policy.snapshot.lifecycle, .stopped(.user))
        XCTAssertNil(policy.snapshot.frame)
        XCTAssertNil(policy.snapshot.coordinateEpoch)
    }

    func testFirstFrameDeadlineIsExactlyThreeSecondsAndCannotBeRescuedAtBoundary() {
        var policy = SpatialContextPolicy()
        XCTAssertTrue(policy.begin(runID: 1, at: 0))
        XCTAssertNil(policy.tick(at: Double(3).nextDown))
        XCTAssertFalse(policy.receive(input(sequence: 1, timestamp: 100), at: 3))
        XCTAssertEqual(policy.snapshot.lifecycle, .stopped(.firstFrameTimeout))
        XCTAssertEqual(policy.snapshot.associationStatus, .stale)
        XCTAssertEqual(policy.snapshot.frameCount, 0)
        XCTAssertNil(policy.snapshot.frame)

        var exactTick = SpatialContextPolicy()
        XCTAssertTrue(exactTick.begin(runID: 1, at: 0))
        XCTAssertEqual(exactTick.tick(at: 3), .firstFrameTimeout)
    }

    func testNoFrameDeadlineUsesArrivalEvenWhileTrackingIsLimited() {
        var policy = SpatialContextPolicy()
        XCTAssertTrue(policy.begin(runID: 1, at: 0))
        XCTAssertTrue(policy.receive(input(
            sequence: 1, timestamp: 100, tracking: .limited(.initializing)
        ), at: 1))
        XCTAssertEqual(policy.snapshot.lifecycle, .cameraActive)
        XCTAssertNil(policy.tick(at: Double(3).nextDown))
        XCTAssertEqual(policy.tick(at: 3), .frameTimeout)
        XCTAssertEqual(policy.snapshot.poseUnavailableReason, .stale)
        XCTAssertNil(policy.snapshot.frame)
        XCTAssertNil(policy.snapshot.coordinateEpoch)
    }

    func testLateRunAndRepeatedSequenceDoNotRefreshOrMutateCurrentRun() {
        var policy = recoveredPolicy()
        policy.stop(reason: .user)
        XCTAssertFalse(policy.begin(runID: 1, at: 20))
        XCTAssertTrue(policy.begin(runID: 2, at: 20))
        let beforeOldRun = policy.snapshot
        XCTAssertFalse(policy.receive(input(run: 1, sequence: 100, timestamp: .nan), at: .nan))
        XCTAssertEqual(policy.snapshot, beforeOldRun)
        XCTAssertTrue(policy.receive(input(run: 2, sequence: 1, timestamp: 200), at: 21))
        let beforeRepeatedSequence = policy.snapshot
        XCTAssertFalse(policy.receive(input(run: 2, sequence: 1, timestamp: 201), at: 22.9))
        XCTAssertEqual(policy.snapshot, beforeRepeatedSequence)
        XCTAssertEqual(policy.tick(at: 23), .frameTimeout)
        let stopped = policy.snapshot
        XCTAssertFalse(policy.receive(input(run: 2, sequence: 2, timestamp: 202), at: 23.1))
        XCTAssertEqual(policy.snapshot, stopped)
    }

    func testInitialAndRecoveredEpochRequireThreeConsecutiveNormalFrames() {
        var policy = SpatialContextPolicy()
        XCTAssertTrue(policy.begin(runID: 1, at: 0))
        for sequence in UInt64(1)...2 {
            XCTAssertTrue(policy.receive(input(sequence: sequence, timestamp: Double(sequence)), at: Double(sequence) / 10))
            XCTAssertNil(policy.snapshot.coordinateEpoch)
            XCTAssertNil(policy.snapshot.frame?.worldFromCamera)
        }
        XCTAssertTrue(policy.receive(input(sequence: 3, timestamp: 3), at: 0.3))
        XCTAssertEqual(policy.snapshot.coordinateEpoch, 1)
        XCTAssertEqual(policy.snapshot.frame?.worldFromCamera, .identity)
        XCTAssertTrue(policy.receive(input(sequence: 4, timestamp: 4, tracking: .limited(.excessiveMotion)), at: 0.4))
        XCTAssertNil(policy.snapshot.coordinateEpoch)
        XCTAssertNil(policy.snapshot.frame?.worldFromCamera)
        XCTAssertEqual(policy.snapshot.tracking, .limited(.excessiveMotion))
        XCTAssertEqual(policy.snapshot.associationStatus, .trackingUnavailable)
        XCTAssertTrue(policy.receive(input(sequence: 5, timestamp: 5), at: 0.5))
        XCTAssertTrue(policy.receive(input(sequence: 6, timestamp: 6), at: 0.6))
        XCTAssertNil(policy.snapshot.coordinateEpoch)
        // A second loss resets the entire recovery streak.
        XCTAssertTrue(policy.receive(input(sequence: 7, timestamp: 7, tracking: .unavailable), at: 0.7))
        for sequence in UInt64(8)...9 {
            XCTAssertTrue(policy.receive(input(sequence: sequence, timestamp: Double(sequence)), at: Double(sequence) / 10))
            XCTAssertNil(policy.snapshot.coordinateEpoch)
        }
        XCTAssertTrue(policy.receive(input(sequence: 10, timestamp: 10), at: 1))
        XCTAssertEqual(policy.snapshot.coordinateEpoch, 2)
        XCTAssertEqual(policy.snapshot.usablePoseFrameCount, 2)
    }

    func testNonfiniteAndMissingTransformsCloseEpochAndCannotPublishPose() {
        let invalid = SpatialMatrix4x4(
            column0: SIMD4(.nan, 0, 0, 0), column1: SIMD4(0, 1, 0, 0),
            column2: SIMD4(0, 0, 1, 0), column3: SIMD4(0, 0, 0, 1)
        )
        for (matrix, reason) in [
            (Optional(invalid), SpatialPoseUnavailableReason.invalidTransform),
            (Optional<SpatialMatrix4x4>.none, SpatialPoseUnavailableReason.missingTransform)
        ] {
            var policy = recoveredPolicy()
            XCTAssertTrue(policy.receive(input(sequence: 4, timestamp: 104, matrix: matrix), at: 10.4))
            XCTAssertNil(policy.snapshot.coordinateEpoch)
            XCTAssertNil(policy.snapshot.frame?.worldFromCamera)
            XCTAssertEqual(policy.snapshot.poseUnavailableReason, reason)
            XCTAssertTrue(policy.receiveTrackingState(.normal, runID: 1, at: 10.4))
            XCTAssertEqual(policy.snapshot.poseUnavailableReason, reason)
            for sequence in UInt64(5)...6 {
                XCTAssertTrue(policy.receive(input(sequence: sequence, timestamp: 100 + Double(sequence)), at: 10 + Double(sequence) / 10))
                XCTAssertNil(policy.snapshot.coordinateEpoch)
            }
            XCTAssertTrue(policy.receive(input(sequence: 7, timestamp: 107), at: 10.7))
            XCTAssertEqual(policy.snapshot.coordinateEpoch, 2)
        }
        XCTAssertTrue(SpatialMatrix4x4.identity.isFinite)
        XCTAssertFalse(invalid.isFinite)
    }

    func testTrackingLossNotificationClosesPoseWithoutRefreshingFrameEvidenceOrDeadline() throws {
        var policy = SpatialContextPolicy()
        XCTAssertTrue(policy.begin(runID: 1, at: 0))
        let depth = SpatialDepthReducer.reduce(samples: [SpatialDepthSample](
            repeating: SpatialDepthSample(depthMeters: 2, confidence: .high), count: 9
        ))
        for sequence in UInt64(1)...3 {
            XCTAssertTrue(policy.receive(
                input(sequence: sequence, timestamp: 100 + Double(sequence), depth: depth),
                at: Double(sequence - 1) / 4
            ))
        }
        let original = policy.snapshot
        let originalFrame = try XCTUnwrap(original.frame)
        XCTAssertEqual(original.coordinateEpoch, 1)

        XCTAssertTrue(policy.receiveTrackingState(.limited(.insufficientFeatures), runID: 1, at: 0.75))
        XCTAssertNil(policy.snapshot.coordinateEpoch)
        XCTAssertNil(policy.snapshot.frame?.worldFromCamera)
        XCTAssertEqual(policy.snapshot.tracking, .limited(.insufficientFeatures))
        XCTAssertEqual(policy.snapshot.poseUnavailableReason, .trackingUnavailable)
        XCTAssertEqual(policy.snapshot.associationStatus, .trackingUnavailable)
        XCTAssertEqual(policy.snapshot.frame?.frameSequence, originalFrame.frameSequence)
        XCTAssertEqual(policy.snapshot.frame?.arCaptureElapsedSeconds, originalFrame.arCaptureElapsedSeconds)
        XCTAssertEqual(policy.snapshot.frame?.receivedElapsedSeconds, originalFrame.receivedElapsedSeconds)
        XCTAssertEqual(policy.snapshot.frame?.depth, depth)
        XCTAssertEqual(policy.snapshot.frameCount, original.frameCount)
        XCTAssertEqual(policy.snapshot.usablePoseFrameCount, original.usablePoseFrameCount)
        XCTAssertEqual(policy.snapshot.validDepthFrameCount, original.validDepthFrameCount)

        // Normal notifications alone cannot make the retained frame a new pose
        // or keep it fresh; the deadline remains last real arrival (0.5) + 2.
        XCTAssertTrue(policy.receiveTrackingState(.normal, runID: 1, at: 1))
        XCTAssertTrue(policy.receiveTrackingState(.normal, runID: 1, at: 2.25))
        XCTAssertEqual(policy.snapshot.poseUnavailableReason, .recoveringTracking)
        XCTAssertNil(policy.snapshot.coordinateEpoch)
        XCTAssertNil(policy.snapshot.frame?.worldFromCamera)
        XCTAssertEqual(policy.snapshot.frameCount, 3)
        XCTAssertNil(policy.tick(at: Double(2.5).nextDown))
        XCTAssertEqual(policy.tick(at: 2.5), .frameTimeout)
        XCTAssertNil(policy.snapshot.frame)
    }

    func testNormalTrackingNotificationsCannotReplaceRecoveryFrames() {
        var policy = recoveredPolicy()
        XCTAssertTrue(policy.receiveTrackingState(.unavailable, runID: 1, at: 10.4))
        XCTAssertTrue(policy.receiveTrackingState(.normal, runID: 1, at: 10.5))
        XCTAssertEqual(policy.snapshot.poseUnavailableReason, .recoveringTracking)
        XCTAssertNil(policy.snapshot.coordinateEpoch)
        XCTAssertNil(policy.snapshot.frame?.worldFromCamera)

        XCTAssertTrue(policy.receive(input(sequence: 4, timestamp: 104), at: 10.6))
        XCTAssertTrue(policy.receive(input(sequence: 5, timestamp: 105), at: 10.7))
        XCTAssertTrue(policy.receiveTrackingState(.normal, runID: 1, at: 10.8))
        XCTAssertNil(policy.snapshot.coordinateEpoch, "A notification is not a third recovery frame")
        XCTAssertNil(policy.snapshot.frame?.worldFromCamera)
        XCTAssertEqual(policy.snapshot.frameCount, 5)
        XCTAssertEqual(policy.snapshot.usablePoseFrameCount, 1)

        XCTAssertTrue(policy.receive(input(sequence: 6, timestamp: 106), at: 10.9))
        XCTAssertEqual(policy.snapshot.coordinateEpoch, 2)
        XCTAssertEqual(policy.snapshot.frame?.worldFromCamera, .identity)
        XCTAssertEqual(policy.snapshot.frameCount, 6)
        XCTAssertEqual(policy.snapshot.usablePoseFrameCount, 2)
        XCTAssertEqual(policy.snapshot.associationStatus, .clockMappingUnavailable)
    }

    func testTrackingNotificationsCannotDelayFirstFrameOrMutateRetiredRuns() {
        var policy = SpatialContextPolicy()
        XCTAssertTrue(policy.begin(runID: 1, at: 0))
        XCTAssertTrue(policy.receiveTrackingState(.normal, runID: 1, at: 1))
        XCTAssertEqual(policy.snapshot.poseUnavailableReason, .awaitingFrames)
        XCTAssertTrue(policy.receiveTrackingState(.limited(.initializing), runID: 1, at: 2))
        XCTAssertTrue(policy.receiveTrackingState(.normal, runID: 1, at: Double(3).nextDown))
        XCTAssertEqual(policy.snapshot.poseUnavailableReason, .awaitingFrames)
        XCTAssertEqual(policy.snapshot.lifecycle, .starting)
        XCTAssertEqual(policy.snapshot.frameCount, 0)
        XCTAssertNil(policy.snapshot.frame)
        XCTAssertFalse(policy.receiveTrackingState(.normal, runID: 1, at: 3))
        XCTAssertEqual(policy.snapshot.lifecycle, .stopped(.firstFrameTimeout))
        let stopped = policy.snapshot
        XCTAssertFalse(policy.receiveTrackingState(.unavailable, runID: 1, at: .nan))
        XCTAssertEqual(policy.snapshot, stopped)

        XCTAssertTrue(policy.begin(runID: 2, at: 4))
        let newRun = policy.snapshot
        XCTAssertFalse(policy.receiveTrackingState(.limited(.relocalizing), runID: 1, at: .nan))
        XCTAssertEqual(policy.snapshot, newRun, "A retired event must not poison the new run's clock")
    }

    func testARCaptureClockFaultsCloseEpochAndRequireIncreasingRecovery() {
        for faultyTimestamp in [Double.nan, .infinity, -.infinity, -1, 103, 102] {
            var policy = recoveredPolicy()
            XCTAssertTrue(policy.receive(input(sequence: 4, timestamp: faultyTimestamp), at: 10.4))
            XCTAssertNil(policy.snapshot.coordinateEpoch)
            XCTAssertNil(policy.snapshot.frame?.worldFromCamera)
            XCTAssertEqual(policy.snapshot.poseUnavailableReason, .timingInvalid)
            XCTAssertEqual(policy.snapshot.associationStatus, .timingUnavailable)
            XCTAssertTrue(policy.isRunning)
            XCTAssertTrue(policy.receiveTrackingState(.normal, runID: 1, at: 10.4))
            XCTAssertEqual(policy.snapshot.poseUnavailableReason, .timingInvalid)
            for sequence in UInt64(5)...6 {
                XCTAssertTrue(policy.receive(input(sequence: sequence, timestamp: 100 + Double(sequence)), at: 10 + Double(sequence) / 10))
                XCTAssertNil(policy.snapshot.coordinateEpoch)
            }
            XCTAssertTrue(policy.receive(input(sequence: 7, timestamp: 107), at: 10.7))
            XCTAssertEqual(policy.snapshot.coordinateEpoch, 2)
        }
    }

    func testInvalidFirstCaptureTimeDoesNotCreateAnAROrigin() {
        var policy = SpatialContextPolicy()
        XCTAssertTrue(policy.begin(runID: 1, at: 0))
        XCTAssertTrue(policy.receive(input(sequence: 1, timestamp: .nan), at: 0.1))
        XCTAssertNil(policy.snapshot.frame?.arCaptureElapsedSeconds)
        XCTAssertTrue(policy.receive(input(sequence: 2, timestamp: 1_000), at: 0.2))
        XCTAssertEqual(policy.snapshot.frame?.arCaptureElapsedSeconds, 0)
        XCTAssertNil(policy.snapshot.coordinateEpoch)
    }

    func testRelativeCaptureAndReceiptClocksRemainDistinctAndUnassociated() throws {
        var policy = SpatialContextPolicy()
        XCTAssertTrue(policy.begin(runID: 1, at: 100))
        for sequence in UInt64(1)...3 {
            XCTAssertTrue(policy.receive(input(sequence: sequence, timestamp: 8_000 + Double(sequence)), at: 100 + Double(sequence) / 2))
        }
        let frame = try XCTUnwrap(policy.snapshot.frame)
        XCTAssertEqual(frame.arCaptureElapsedSeconds, 2)
        XCTAssertEqual(frame.receivedElapsedSeconds, 1.5)
        XCTAssertEqual(policy.snapshot.associationStatus, .clockMappingUnavailable)
        // Equal relative numbers are equally insufficient clock evidence.
        XCTAssertTrue(policy.receive(input(sequence: 4, timestamp: 8_004), at: 103))
        XCTAssertEqual(policy.snapshot.frame?.arCaptureElapsedSeconds, 3)
        XCTAssertEqual(policy.snapshot.frame?.receivedElapsedSeconds, 3)
        XCTAssertEqual(policy.snapshot.associationStatus, .clockMappingUnavailable)
    }

    func testReceiptClockInvalidityEndsRunAndClearsCurrentData() {
        for faultyTime in [Double.nan, .infinity, -.infinity, 10.2] {
            var policy = recoveredPolicy()
            XCTAssertEqual(policy.tick(at: faultyTime), .timingInvalid)
            XCTAssertFalse(policy.isRunning)
            XCTAssertNil(policy.snapshot.frame)
            XCTAssertNil(policy.snapshot.coordinateEpoch)
        }
        var policy = SpatialContextPolicy()
        XCTAssertFalse(policy.begin(runID: 1, at: .nan))
        XCTAssertEqual(policy.snapshot.lifecycle, .off)
    }

    func testMissingDepthReplacesPreviousMeasurementWithoutClosingPoseEpoch() throws {
        let depth = SpatialDepthReducer.reduce(samples: (1...9).map {
            SpatialDepthSample(depthMeters: Float($0), confidence: .high)
        })
        var policy = recoveredPolicy()
        XCTAssertTrue(policy.receive(input(sequence: 4, timestamp: 104, depth: depth), at: 10.4))
        XCTAssertEqual(policy.snapshot.frame?.depth, depth)
        XCTAssertEqual(policy.snapshot.validDepthFrameCount, 1)
        XCTAssertTrue(policy.receive(input(sequence: 5, timestamp: 105, depth: .unavailable(.missingDepth)), at: 10.5))
        XCTAssertEqual(policy.snapshot.frame?.depth, .unavailable(.missingDepth))
        XCTAssertEqual(policy.snapshot.coordinateEpoch, 1)
        XCTAssertEqual(policy.snapshot.validDepthFrameCount, 1)
        XCTAssertEqual(policy.snapshot.frameCount, 5)
        XCTAssertEqual(try XCTUnwrap(policy.snapshot.frame).frameSequence, 5)
    }

    func testDepthMedianUsesAtLeastFiveFinitePositiveMediumOrHighSamples() throws {
        let samples = [
            SpatialDepthSample(depthMeters: 7, confidence: .high),
            SpatialDepthSample(depthMeters: 1, confidence: .medium),
            SpatialDepthSample(depthMeters: 5, confidence: .high),
            SpatialDepthSample(depthMeters: 3, confidence: .high),
            SpatialDepthSample(depthMeters: 9, confidence: .high),
            SpatialDepthSample(depthMeters: .nan, confidence: .high),
            SpatialDepthSample(depthMeters: .infinity, confidence: .high),
            SpatialDepthSample(depthMeters: 0, confidence: .high),
            SpatialDepthSample(depthMeters: -1, confidence: .high)
        ]
        guard case .available(let measurement) = SpatialDepthReducer.reduce(samples: samples) else {
            return XCTFail("Five valid pixels should produce a scalar median")
        }
        XCTAssertEqual(measurement.medianMeters, 5)
        XCTAssertEqual(measurement.acceptedSampleCount, 5)
        XCTAssertEqual(measurement.confidence, .medium)

        let insufficient = Array(samples.prefix(4)) + [SpatialDepthSample](
            repeating: SpatialDepthSample(depthMeters: 2, confidence: .low), count: 5
        )
        XCTAssertEqual(SpatialDepthReducer.reduce(samples: insufficient), .unavailable(.insufficientAcceptedSamples))
        XCTAssertEqual(SpatialDepthReducer.reduce(samples: [SpatialDepthSample](
            repeating: SpatialDepthSample(depthMeters: 2, confidence: nil), count: 9
        )), .unavailable(.insufficientAcceptedSamples))
    }

    func testDepthEvenMedianBoundsAndRecovery() {
        let six = (1...6).map { SpatialDepthSample(depthMeters: Float($0), confidence: .high) }
            + [SpatialDepthSample](repeating: SpatialDepthSample(depthMeters: 100, confidence: .low), count: 3)
        guard case .available(let even) = SpatialDepthReducer.reduce(samples: six) else {
            return XCTFail("Six accepted pixels should have an even median")
        }
        XCTAssertEqual(even.medianMeters, 3.5)
        XCTAssertEqual(even.acceptedSampleCount, 6)
        XCTAssertEqual(even.confidence, .high)
        for count in [0, 8, 10, 1_000] {
            XCTAssertEqual(SpatialDepthReducer.reduce(samples: [SpatialDepthSample](
                repeating: SpatialDepthSample(depthMeters: 2, confidence: .high), count: count
            )), .unavailable(.invalidPatchSize))
        }
        let maxima = [SpatialDepthSample](
            repeating: SpatialDepthSample(depthMeters: .greatestFiniteMagnitude, confidence: .high), count: 6
        ) + [SpatialDepthSample](repeating: SpatialDepthSample(depthMeters: 0, confidence: .high), count: 3)
        guard case .available(let maximum) = SpatialDepthReducer.reduce(samples: maxima) else {
            return XCTFail("Finite maximum depths must not overflow the even median")
        }
        XCTAssertTrue(maximum.medianMeters.isFinite)
        XCTAssertEqual(maximum.medianMeters, .greatestFiniteMagnitude)
        let minima = [SpatialDepthSample](
            repeating: SpatialDepthSample(depthMeters: .leastNonzeroMagnitude, confidence: .high), count: 6
        ) + [SpatialDepthSample](repeating: SpatialDepthSample(depthMeters: 0, confidence: .high), count: 3)
        guard case .available(let minimum) = SpatialDepthReducer.reduce(samples: minima) else {
            return XCTFail("Finite positive subnormal pixels must not average to zero")
        }
        XCTAssertEqual(minimum.medianMeters, .leastNonzeroMagnitude)
        XCTAssertNil(SpatialDepthMeasurement(medianMeters: .nan, acceptedSampleCount: 9, confidence: .high))
        XCTAssertNil(SpatialDepthMeasurement(medianMeters: 1, acceptedSampleCount: 4, confidence: .high))
        XCTAssertNil(SpatialDepthMeasurement(medianMeters: 1, acceptedSampleCount: 9, confidence: .low))
        XCTAssertEqual(SpatialDepthReducer.reduce(samples: six), .available(even))
    }

    func testLongRunRetainsOnlyLatestFrameAndFreshRunResetsCounters() {
        var policy = SpatialContextPolicy()
        XCTAssertTrue(policy.begin(runID: 1, at: 0))
        for sequence in UInt64(1)...1_000 {
            XCTAssertTrue(policy.receive(input(sequence: sequence, timestamp: Double(sequence)), at: Double(sequence) / 1_000))
        }
        XCTAssertEqual(policy.snapshot.frame?.frameSequence, 1_000)
        XCTAssertEqual(policy.snapshot.frameCount, 1_000)
        XCTAssertEqual(policy.snapshot.usablePoseFrameCount, 998)
        XCTAssertEqual(policy.snapshot.coordinateEpoch, 1)
        policy.stop(reason: .deadline)
        XCTAssertNil(policy.snapshot.frame)
        XCTAssertTrue(policy.begin(runID: 2, at: 2))
        XCTAssertEqual(policy.snapshot.frameCount, 0)
        XCTAssertEqual(policy.snapshot.usablePoseFrameCount, 0)
        XCTAssertNil(policy.snapshot.frame)
        XCTAssertNil(policy.snapshot.coordinateEpoch)
    }
}

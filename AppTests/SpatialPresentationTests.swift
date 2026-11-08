import RheaRFCore
import XCTest
@testable import RheaRFSpanner

/// Presentation of deterministic policy snapshots only. No camera session,
/// physical tracking accuracy, or audio/pose clock association is exercised.
final class SpatialPresentationTests: XCTestCase {
    private func input(
        sequence: UInt64, timestamp: Double,
        tracking: SpatialTrackingState = .normal,
        matrix: SpatialMatrix4x4? = .identity
    ) -> SpatialFrameInput {
        SpatialFrameInput(
            runID: 1, frameSequence: sequence, arTimestampSeconds: timestamp,
            worldFromCamera: matrix, tracking: tracking
        )
    }

    func testNormalTrackingDoesNotHideInvalidTimingOrTransformReasons() {
        let invalidMatrix = SpatialMatrix4x4(
            column0: SIMD4(.nan, 0, 0, 0), column1: SIMD4(0, 1, 0, 0),
            column2: SIMD4(0, 0, 1, 0), column3: SIMD4(0, 0, 0, 1)
        )
        let faults: [(Double, SpatialMatrix4x4?, SpatialPoseUnavailableReason, String)] = [
            (.nan, .identity, .timingInvalid, "AR capture timing invalid"),
            (104, nil, .missingTransform, "camera transform missing"),
            (104, invalidMatrix, .invalidTransform, "camera transform invalid"),
        ]
        for (timestamp, matrix, reason, detail) in faults {
            var policy = SpatialContextPolicy()
            XCTAssertTrue(policy.begin(runID: 1, at: 0))
            for sequence in UInt64(1)...3 {
                XCTAssertTrue(policy.receive(
                    input(sequence: sequence, timestamp: 100 + Double(sequence)),
                    at: Double(sequence) / 10
                ))
            }
            XCTAssertNotNil(policy.snapshot.coordinateEpoch)
            XCTAssertTrue(policy.receive(
                input(sequence: 4, timestamp: timestamp, matrix: matrix), at: 0.4
            ))
            XCTAssertEqual(policy.snapshot.poseUnavailableReason, reason)
            XCTAssertNil(policy.snapshot.frame?.worldFromCamera)
            let status = SpatialContextStatusPresentation(snapshot: policy.snapshot)
            XCTAssertEqual(status.trackingStatus, "AR tracking normal")
            XCTAssertEqual(status.poseStatus, "Local pose unavailable · " + detail)
            XCTAssertFalse(status.poseStatus.contains("consecutive"))
        }
    }

    func testRecoveryAndTrackingLossRemainDistinctFromAcceptedPose() {
        var policy = SpatialContextPolicy()
        XCTAssertTrue(policy.begin(runID: 1, at: 0))
        var status = SpatialContextStatusPresentation(snapshot: policy.snapshot)
        XCTAssertEqual(status.trackingStatus, "AR tracking unavailable")
        XCTAssertEqual(status.poseStatus, "Local pose unavailable · waiting for AR frames")

        for sequence in UInt64(1)...2 {
            XCTAssertTrue(policy.receive(
                input(sequence: sequence, timestamp: Double(sequence)), at: Double(sequence) / 10
            ))
            status = SpatialContextStatusPresentation(snapshot: policy.snapshot)
            XCTAssertEqual(status.trackingStatus, "AR tracking normal")
            XCTAssertEqual(status.poseStatus, "Local pose unavailable · recovery requires 3 consecutive usable frames")
        }
        XCTAssertTrue(policy.receive(input(sequence: 3, timestamp: 3), at: 0.3))
        status = SpatialContextStatusPresentation(snapshot: policy.snapshot)
        XCTAssertEqual(status.trackingStatus, "AR tracking normal")
        XCTAssertEqual(status.poseStatus, "Local pose accepted · local session estimate")

        XCTAssertTrue(policy.receive(input(
            sequence: 4, timestamp: 4, tracking: .limited(.insufficientFeatures)
        ), at: 0.4))
        status = SpatialContextStatusPresentation(snapshot: policy.snapshot)
        XCTAssertEqual(status.trackingStatus, "AR tracking limited · insufficient features")
        XCTAssertEqual(status.poseStatus, "Local pose unavailable · AR tracking is not normal")

        XCTAssertTrue(policy.receive(input(sequence: 5, timestamp: 5), at: 0.5))
        status = SpatialContextStatusPresentation(snapshot: policy.snapshot)
        XCTAssertEqual(status.trackingStatus, "AR tracking normal")
        XCTAssertEqual(status.poseStatus, "Local pose unavailable · recovery requires 3 consecutive usable frames")
        XCTAssertEqual(policy.tick(at: 2.5), .frameTimeout)
        status = SpatialContextStatusPresentation(snapshot: policy.snapshot)
        XCTAssertEqual(status.trackingStatus, "AR tracking unavailable")
        XCTAssertEqual(status.poseStatus, "Local pose unavailable · frame arrival timed out")
    }

    func testCaptureClockLabelUsesFirstValidTimestampAfterInvalidFirstFrame() throws {
        var policy = SpatialContextPolicy()
        XCTAssertTrue(policy.begin(runID: 1, at: 0))
        XCTAssertTrue(policy.receive(input(sequence: 1, timestamp: .nan), at: 0.1))
        XCTAssertNil(SpatialContextStatusPresentation(snapshot: policy.snapshot).arCaptureClockStatus)

        XCTAssertTrue(policy.receive(input(sequence: 2, timestamp: 8_000), at: 0.2))
        XCTAssertEqual(policy.snapshot.frame?.arCaptureElapsedSeconds, 0)
        let status = SpatialContextStatusPresentation(snapshot: policy.snapshot)
        let clock = try XCTUnwrap(status.arCaptureClockStatus)
        XCTAssertTrue(clock.hasSuffix(" s from first valid AR timestamp"))
        XCTAssertNil(policy.snapshot.coordinateEpoch)
        XCTAssertTrue(status.poseStatus.contains("recovery"))
    }
}

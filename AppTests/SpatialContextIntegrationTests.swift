import ARKit
import CoreVideo
import Foundation
import RealityKit
import RheaRFCore
import Synchronization
import UIKit
import XCTest
@testable import RheaRFSpanner

private final class SpatialFixtureClock: Sendable {
    private let value = Mutex<Double>(100)

    var now: Double {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// Adapter/ownership fixtures only. The fake sessions never open a camera or
/// microphone; pixel buffers contain synthetic center-patch values only.
@MainActor
final class SpatialContextIntegrationTests: XCTestCase {
    private enum FixtureError: Error { case startFailed }

    @MainActor
    private final class RecordingSession: SpatialContextSession {
        var previewView: ARView? { nil }
        var throwsOnStart = false
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var depthRequests: [Bool] = []
        private(set) var handoffs: [SpatialContextHandoff] = []

        func start(handoff: SpatialContextHandoff, depthEnabled: Bool) throws {
            startCount += 1
            depthRequests.append(depthEnabled)
            handoffs.append(handoff)
            if throwsOnStart { throw FixtureError.startFailed }
        }

        func stop() { stopCount += 1 }
    }

    @MainActor
    private final class RuntimeFixture {
        private let clock = SpatialFixtureClock()
        var now: Double {
            get { clock.now }
            set { clock.now = newValue }
        }
        var capability = SpatialCapabilities(worldTracking: true, sceneDepth: true)
        var permission: SpatialCameraPermission = .authorized
        var permissionDecision = true
        var suspendPermission = false
        var throwsOnStart = false
        private(set) var permissionRequests = 0
        private(set) var sessions: [RecordingSession] = []
        var pendingPermission: CheckedContinuation<Bool, Never>?

        var runtime: SpatialContextRuntime {
            let clock = self.clock
            return SpatialContextRuntime(
                clock: { clock.now },
                capabilities: { self.capability },
                permission: { self.permission },
                requestPermission: {
                    self.permissionRequests += 1
                    let granted: Bool
                    if self.suspendPermission {
                        granted = await withCheckedContinuation { self.pendingPermission = $0 }
                    } else {
                        granted = self.permissionDecision
                    }
                    self.permission = granted ? .authorized : .denied
                    return granted
                },
                makeSession: {
                    let session = RecordingSession()
                    session.throwsOnStart = self.throwsOnStart
                    self.sessions.append(session)
                    return session
                }
            )
        }
    }

    private func controller(_ fixture: RuntimeFixture) -> SpatialContextController {
        SpatialContextController(runtime: fixture.runtime, automaticUpdates: false)
    }

    private func started(
        _ fixture: RuntimeFixture, depthRequested: Bool = false
    ) async throws -> (SpatialContextController, RecordingSession, SpatialContextHandoff) {
        let subject = controller(fixture)
        subject.setForegroundActive(true)
        let preparation = await subject.prepareForExplicitStart()
        XCTAssertEqual(preparation, .ready)
        XCTAssertTrue(subject.startAuthorized(depthRequested: depthRequested))
        let session = try XCTUnwrap(fixture.sessions.last)
        let handoff = try XCTUnwrap(session.handoffs.last)
        return (subject, session, handoff)
    }

    private func frame(
        _ handoff: SpatialContextHandoff, sequence: UInt64 = 1,
        arTime: Double = 1_000,
        tracking: SpatialTrackingState = .normal,
        depth: SpatialDepthSummary = .unavailable(.notRequested)
    ) -> SpatialFrameInput {
        SpatialFrameInput(
            runID: handoff.runID, frameSequence: sequence,
            arTimestampSeconds: arTime, worldFromCamera: .identity,
            tracking: tracking, depth: depth
        )
    }

    func testConstructionInspectionAndManualPreviewDoNotStartSession() {
        let fixture = RuntimeFixture()
        let subject = controller(fixture)
        XCTAssertEqual(subject.snapshot.lifecycle, .off)
        XCTAssertFalse(subject.isSessionRunning)
        XCTAssertNil(subject.previewView)
        _ = subject.cameraPermission
        _ = subject.capabilities
        _ = subject.availability
        subject.monitor()
        _ = SpatialContextView(controller: subject)
        _ = SpatialContextPreview(controller: subject).makeCoordinator()

        let preview = SpatialContextPreview.makeARView()
        XCTAssertFalse(preview.automaticallyConfigureSession)
        XCTAssertTrue(fixture.sessions.isEmpty)
        XCTAssertEqual(fixture.permissionRequests, 0)
    }

    func testAuthorizedPreparationIsIdleAndPermitIsConsumedByExplicitStart() async throws {
        let fixture = RuntimeFixture()
        let subject = controller(fixture)
        subject.setForegroundActive(true)
        XCTAssertFalse(subject.startAuthorized())
        let preparation = await subject.prepareForExplicitStart()
        XCTAssertEqual(preparation, .ready)
        XCTAssertFalse(subject.isSessionRunning)
        XCTAssertTrue(fixture.sessions.isEmpty)
        XCTAssertTrue(subject.startAuthorized())
        defer { subject.stop() }
        XCTAssertEqual(fixture.sessions.count, 1)
        XCTAssertEqual(fixture.sessions.first?.startCount, 1)
        XCTAssertFalse(subject.startAuthorized())
        XCTAssertEqual(fixture.permissionRequests, 0)
    }

    func testFirstPermissionGrantReturnsIdleUntilAnotherExplicitStart() async {
        let fixture = RuntimeFixture()
        fixture.permission = .notDetermined
        let subject = controller(fixture)
        subject.setForegroundActive(true)
        let firstPreparation = await subject.prepareForExplicitStart()
        XCTAssertEqual(firstPreparation, .permissionResolved)
        XCTAssertEqual(subject.cameraPermission, .authorized)
        XCTAssertFalse(subject.startAuthorized())
        XCTAssertFalse(subject.isSessionRunning)
        XCTAssertTrue(fixture.sessions.isEmpty)
        XCTAssertEqual(fixture.permissionRequests, 1)

        let secondPreparation = await subject.prepareForExplicitStart()
        XCTAssertEqual(secondPreparation, .ready)
        XCTAssertTrue(fixture.sessions.isEmpty)
        XCTAssertTrue(subject.startAuthorized())
        subject.stop()
    }

    func testUnavailablePermissionsAndHardwareNeverCreateSession() async {
        for permission in [SpatialCameraPermission.denied, .restricted, .unavailable] {
            let fixture = RuntimeFixture()
            fixture.permission = permission
            let subject = controller(fixture)
            subject.setForegroundActive(true)
            let preparation = await subject.prepareForExplicitStart()
            XCTAssertEqual(preparation, .unavailable)
            XCTAssertFalse(subject.startAuthorized())
            XCTAssertTrue(fixture.sessions.isEmpty)
            XCTAssertEqual(fixture.permissionRequests, 0)
        }
        let fixture = RuntimeFixture()
        fixture.capability = SpatialCapabilities(worldTracking: false, sceneDepth: false)
        let subject = controller(fixture)
        subject.setForegroundActive(true)
        let preparation = await subject.prepareForExplicitStart()
        XCTAssertEqual(preparation, .unavailable)
        XCTAssertEqual(subject.availability, .unsupported)
        XCTAssertFalse(subject.startAuthorized())
        XCTAssertTrue(fixture.sessions.isEmpty)
    }

    func testBackgroundWhilePermissionIsPendingInvalidatesStartIntent() async throws {
        let fixture = RuntimeFixture()
        fixture.permission = .notDetermined
        fixture.suspendPermission = true
        let subject = controller(fixture)
        subject.setForegroundActive(true)
        let preparation = Task { await subject.prepareForExplicitStart() }
        for _ in 0..<64 where fixture.pendingPermission == nil { await Task.yield() }
        let permission = try XCTUnwrap(fixture.pendingPermission)
        subject.setForegroundActive(false)
        permission.resume(returning: true)
        let result = await preparation.value
        XCTAssertEqual(result, .cancelled)
        subject.setForegroundActive(true)
        XCTAssertFalse(subject.startAuthorized())
        XCTAssertTrue(fixture.sessions.isEmpty)
    }

    func testCancellingPermissionPreparationLeavesNextExplicitPreparationAvailable() async throws {
        let fixture = RuntimeFixture()
        fixture.permission = .notDetermined
        fixture.suspendPermission = true
        let subject = controller(fixture)
        subject.setForegroundActive(true)
        let preparation = Task { await subject.prepareForExplicitStart() }
        for _ in 0..<64 where fixture.pendingPermission == nil { await Task.yield() }
        let permission = try XCTUnwrap(fixture.pendingPermission)

        // Cancel the task alone: no stop, foreground, or generation change is
        // available to clear the request state on this path.
        preparation.cancel()
        permission.resume(returning: true)
        let result = await preparation.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(subject.availability, .off)
        XCTAssertFalse(subject.startAuthorized())
        XCTAssertTrue(fixture.sessions.isEmpty)

        let nextPreparation = await subject.prepareForExplicitStart()
        XCTAssertEqual(nextPreparation, .ready)
        XCTAssertEqual(fixture.permissionRequests, 1)
        XCTAssertTrue(fixture.sessions.isEmpty)
        XCTAssertTrue(subject.startAuthorized())
        subject.stop()
    }

    func testPermissionRevocationBetweenPreparationAndStartRejectsCombinedStart() async {
        let fixture = RuntimeFixture()
        let subject = controller(fixture)
        subject.setForegroundActive(true)
        let preparation = await subject.prepareForExplicitStart()
        XCTAssertEqual(preparation, .ready)
        fixture.permission = .denied
        XCTAssertFalse(subject.startAuthorized())
        XCTAssertTrue(fixture.sessions.isEmpty)
        XCTAssertFalse(subject.isSessionRunning)
    }

    func testUnsupportedDepthDoesNotPreventPoseOnlyContext() async throws {
        let fixture = RuntimeFixture()
        fixture.capability = SpatialCapabilities(worldTracking: true, sceneDepth: false)
        let (subject, session, handoff) = try await started(fixture, depthRequested: true)
        defer { subject.stop() }
        XCTAssertTrue(subject.isSessionRunning)
        XCTAssertEqual(session.depthRequests, [false])
        handoff.receive(frame(handoff), at: fixture.now)
        subject.monitor()
        XCTAssertEqual(subject.snapshot.frame?.depth, .unavailable(.unsupported))
    }

    func testExplicitStopIsIdempotentAndRetiredCallbacksCannotAffectNextRun() async throws {
        let fixture = RuntimeFixture()
        let (subject, firstSession, retired) = try await started(fixture)
        retired.receive(frame(retired), at: fixture.now)
        subject.monitor()
        XCTAssertEqual(subject.snapshot.frameCount, 1)
        subject.stop(reason: .audioStopped)
        subject.stop(reason: .audioStopped)
        XCTAssertEqual(firstSession.stopCount, 1)
        XCTAssertEqual(subject.snapshot.lifecycle, .stopped(.audioStopped))

        fixture.now += 1
        let preparation = await subject.prepareForExplicitStart()
        XCTAssertEqual(preparation, .ready)
        XCTAssertTrue(subject.startAuthorized())
        defer { subject.stop() }
        let secondSession = try XCTUnwrap(fixture.sessions.last)
        let current = try XCTUnwrap(secondSession.handoffs.last)
        XCTAssertNotEqual(current.runID, retired.runID)
        retired.receive(frame(retired, sequence: 2, arTime: 1_001), at: fixture.now)
        retired.receiveTrackingState(.limited(.relocalizing), at: fixture.now)
        retired.receiveTrackingState(.normal, at: fixture.now)
        retired.fail(reason: .sessionFailure)
        subject.monitor()
        XCTAssertTrue(subject.isSessionRunning)
        XCTAssertEqual(subject.snapshot.runID, current.runID)
        XCTAssertEqual(subject.snapshot.frameCount, 0)
        current.receive(frame(current, arTime: 2_000), at: fixture.now)
        subject.monitor()
        XCTAssertEqual(subject.snapshot.frameCount, 1)
        XCTAssertEqual(secondSession.stopCount, 0)
    }

    func testInterruptionHandoffDefersTeardownUntilCoordinatorMonitor() async throws {
        let fixture = RuntimeFixture()
        let (subject, session, handoff) = try await started(fixture)
        var stopRequests: [SpatialStopReason] = []
        subject.onStopRequired = { stopRequests.append($0) }
        handoff.fail(reason: .interruption)
        XCTAssertEqual(session.stopCount, 0, "Delegate handoff must not tear down AR inline")
        XCTAssertTrue(subject.isSessionRunning)
        subject.monitor()
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertFalse(subject.isSessionRunning)
        XCTAssertEqual(subject.snapshot.lifecycle, .stopped(.interruption))
        XCTAssertEqual(stopRequests, [.interruption])
        subject.monitor()
        subject.setForegroundActive(true)
        XCTAssertEqual(session.startCount, 1)
        XCTAssertEqual(stopRequests, [.interruption])
    }

    func testForegroundLossEndsRunAndForegroundReturnDoesNotRestart() async throws {
        let fixture = RuntimeFixture()
        let (subject, session, _) = try await started(fixture)
        var stopRequests: [SpatialStopReason] = []
        subject.onStopRequired = { stopRequests.append($0) }
        subject.setForegroundActive(false)
        XCTAssertFalse(subject.isSessionRunning)
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertEqual(subject.snapshot.lifecycle, .stopped(.inactive))
        XCTAssertEqual(stopRequests, [.inactive])
        subject.setForegroundActive(true)
        subject.monitor()
        XCTAssertFalse(subject.startAuthorized())
        XCTAssertEqual(session.startCount, 1)
    }

    func testPreviewDismantleStopsOnceWithoutCreatingAnotherSession() async throws {
        let fixture = RuntimeFixture()
        let (subject, session, _) = try await started(fixture)
        var stopRequests: [SpatialStopReason] = []
        subject.onStopRequired = { stopRequests.append($0) }
        let preview = SpatialContextPreview(controller: subject)
        let coordinator = preview.makeCoordinator()
        let host = UIView(frame: .zero)
        SpatialContextPreview.dismantleUIView(host, coordinator: coordinator)
        SpatialContextPreview.dismantleUIView(host, coordinator: coordinator)
        XCTAssertFalse(subject.isSessionRunning)
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertEqual(stopRequests, [.user])
        XCTAssertEqual(fixture.sessions.count, 1)
    }

    func testRetiredPreviewDismantleCannotStopNewSpatialRun() async throws {
        let fixture = RuntimeFixture()
        let (subject, firstSession, firstHandoff) = try await started(fixture)
        let retiredCoordinator = SpatialContextPreview(controller: subject).makeCoordinator()
        XCTAssertEqual(retiredCoordinator.displayedRunID, firstHandoff.runID)
        subject.stop()

        fixture.now += 1
        let preparation = await subject.prepareForExplicitStart()
        XCTAssertEqual(preparation, .ready)
        XCTAssertTrue(subject.startAuthorized())
        defer { subject.stop() }
        let currentSession = try XCTUnwrap(fixture.sessions.last)
        let currentHandoff = try XCTUnwrap(currentSession.handoffs.last)
        XCTAssertNotEqual(currentHandoff.runID, firstHandoff.runID)
        var stopRequests: [SpatialStopReason] = []
        subject.onStopRequired = { stopRequests.append($0) }

        SpatialContextPreview.dismantleUIView(UIView(frame: .zero), coordinator: retiredCoordinator)
        subject.monitor()
        XCTAssertTrue(subject.isSessionRunning)
        XCTAssertEqual(subject.snapshot.runID, currentHandoff.runID)
        XCTAssertEqual(firstSession.stopCount, 1)
        XCTAssertEqual(currentSession.stopCount, 0)
        XCTAssertTrue(stopRequests.isEmpty)
    }

    func testFirstFrameTimeoutUsesExactThreeSecondBoundary() async throws {
        let fixture = RuntimeFixture()
        let (subject, session, _) = try await started(fixture)
        var stopRequests: [SpatialStopReason] = []
        subject.onStopRequired = { stopRequests.append($0) }
        fixture.now = 102.999
        subject.monitor()
        XCTAssertTrue(subject.isSessionRunning)
        fixture.now = 103
        subject.monitor()
        XCTAssertFalse(subject.isSessionRunning)
        XCTAssertEqual(subject.snapshot.lifecycle, .stopped(.firstFrameTimeout))
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertEqual(stopRequests, [.firstFrameTimeout])
    }

    func testDeliveredFramesUseExactTwoSecondNoFrameBoundary() async throws {
        let fixture = RuntimeFixture()
        let (subject, session, handoff) = try await started(fixture)
        fixture.now = 101
        handoff.receive(frame(handoff), at: fixture.now)
        subject.monitor()
        XCTAssertEqual(subject.snapshot.lifecycle, .cameraActive)
        fixture.now = 102.999
        subject.monitor()
        XCTAssertTrue(subject.isSessionRunning)
        fixture.now = 103
        subject.monitor()
        XCTAssertFalse(subject.isSessionRunning)
        XCTAssertEqual(subject.snapshot.lifecycle, .stopped(.frameTimeout))
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertNil(subject.snapshot.frame)
    }

    func testThrowingSessionStartRetiresSessionAndDoesNotRetryAutomatically() async {
        let fixture = RuntimeFixture()
        fixture.throwsOnStart = true
        let subject = controller(fixture)
        subject.setForegroundActive(true)
        let preparation = await subject.prepareForExplicitStart()
        XCTAssertEqual(preparation, .ready)
        XCTAssertFalse(subject.startAuthorized())
        XCTAssertEqual(fixture.sessions.first?.startCount, 1)
        XCTAssertEqual(fixture.sessions.first?.stopCount, 1)
        XCTAssertFalse(subject.isSessionRunning)
        XCTAssertEqual(subject.snapshot.lifecycle, .stopped(.sessionFailure))
        subject.monitor()
        XCTAssertFalse(subject.startAuthorized())
        XCTAssertEqual(fixture.sessions.count, 1)
    }

    func testHandoffCoalescesCurrentValueWhileCountingOverwrites() {
        let handoff = SpatialContextHandoff(runID: 1, at: 100)
        for sequence in UInt64(1)...512 {
            let interval = Double(sequence) / 60
            handoff.receive(frame(handoff, sequence: sequence, arTime: 1_000 + interval),
                            at: 100 + interval)
        }
        let delivery = handoff.drain(at: 100 + 512.0 / 60)
        XCTAssertEqual(delivery.snapshot.frameCount, 512)
        XCTAssertEqual(delivery.snapshot.frame?.frameSequence, 512)
        XCTAssertEqual(delivery.overwrittenSnapshotCount, 511)
        XCTAssertNil(delivery.stopReason)
        XCTAssertEqual(delivery.snapshot.associationStatus, .clockMappingUnavailable)
        let unchanged = handoff.drain(at: 100 + 512.0 / 60)
        XCTAssertEqual(unchanged.snapshot, delivery.snapshot)
        XCTAssertEqual(unchanged.overwrittenSnapshotCount, 511)
    }

    func testFrameAtWatchdogBoundaryLatchesTerminalReasonBeforeMainDrain() {
        let firstFrame = SpatialContextHandoff(runID: 1, at: 100)
        firstFrame.receive(frame(firstFrame), at: 103)
        let firstTimeout = firstFrame.drain(at: 103)
        XCTAssertEqual(firstTimeout.stopReason, .firstFrameTimeout)
        XCTAssertEqual(firstTimeout.snapshot.lifecycle, .stopped(.firstFrameTimeout))
        XCTAssertEqual(firstTimeout.snapshot.frameCount, 0)
        firstFrame.receive(frame(firstFrame, sequence: 2, arTime: 1_001), at: 103.1)
        XCTAssertEqual(firstFrame.drain(at: 103.1).stopReason, .firstFrameTimeout)

        let nextFrame = SpatialContextHandoff(runID: 2, at: 100)
        nextFrame.receive(frame(nextFrame), at: 101)
        nextFrame.receive(frame(nextFrame, sequence: 2, arTime: 1_001), at: 103)
        let nextTimeout = nextFrame.drain(at: 103)
        XCTAssertEqual(nextTimeout.stopReason, .frameTimeout)
        XCTAssertEqual(nextTimeout.snapshot.lifecycle, .stopped(.frameTimeout))
        XCTAssertEqual(nextTimeout.snapshot.frameCount, 1)
        XCTAssertNil(nextTimeout.snapshot.frame)
    }

    func testCoalescingCannotHideTrackingLossOrShortenRecovery() {
        let handoff = SpatialContextHandoff(runID: 1, at: 100)
        for sequence in UInt64(1)...3 {
            handoff.receive(frame(handoff, sequence: sequence, arTime: Double(sequence)),
                            at: 100 + Double(sequence) / 10)
        }
        XCTAssertEqual(handoff.drain(at: 100.3).snapshot.coordinateEpoch, 1)
        handoff.receive(frame(handoff, sequence: 4, arTime: 4,
                              tracking: .limited(.insufficientFeatures)), at: 100.4)
        handoff.receive(frame(handoff, sequence: 5, arTime: 5), at: 100.5)
        handoff.receive(frame(handoff, sequence: 6, arTime: 6), at: 100.6)
        let recovering = handoff.drain(at: 100.6).snapshot
        XCTAssertNil(recovering.coordinateEpoch)
        XCTAssertNil(recovering.frame?.worldFromCamera)
        XCTAssertEqual(recovering.associationStatus, .trackingUnavailable)
        handoff.receive(frame(handoff, sequence: 7, arTime: 7), at: 100.7)
        let recovered = handoff.drain(at: 100.7).snapshot
        XCTAssertEqual(recovered.coordinateEpoch, 2)
        XCTAssertEqual(recovered.frame?.worldFromCamera, .identity)
        XCTAssertEqual(recovered.associationStatus, .clockMappingUnavailable)
    }

    func testTrackingNotificationLossSurvivesCoalescingAndKeepsTheLastFrameDeadline() async throws {
        let fixture = RuntimeFixture()
        let clock = fixture.runtime.clock
        let (subject, session, handoff) = try await started(fixture)
        defer { subject.stop() }
        var stopRequests: [SpatialStopReason] = []
        subject.onStopRequired = { stopRequests.append($0) }
        for sequence in UInt64(1)...3 {
            fixture.now = 100 + Double(sequence - 1) / 4
            handoff.receive(frame(handoff, sequence: sequence, arTime: 1_000 + Double(sequence)),
                            at: fixture.now)
        }
        subject.monitor()
        let lastFrame = try XCTUnwrap(subject.snapshot.frame)
        XCTAssertEqual(subject.snapshot.coordinateEpoch, 1)
        XCTAssertNotNil(lastFrame.worldFromCamera)

        // Both observer events occur before the main consumer drains. Reporting
        // normal again cannot erase the intervening loss or manufacture a frame.
        fixture.now = 100.75
        handoff.receiveTrackingState(.limited(.insufficientFeatures), clock: clock)
        fixture.now = 101
        handoff.receiveTrackingState(.normal, clock: clock)
        subject.monitor()
        XCTAssertEqual(subject.snapshot.tracking, .normal)
        XCTAssertEqual(subject.snapshot.poseUnavailableReason, .recoveringTracking)
        XCTAssertNil(subject.snapshot.coordinateEpoch)
        XCTAssertNil(subject.snapshot.frame?.worldFromCamera)
        XCTAssertEqual(subject.snapshot.frame?.frameSequence, lastFrame.frameSequence)
        XCTAssertEqual(subject.snapshot.frame?.receivedElapsedSeconds, lastFrame.receivedElapsedSeconds)
        XCTAssertEqual(subject.snapshot.frameCount, 3)
        XCTAssertEqual(subject.snapshot.usablePoseFrameCount, 1)
        XCTAssertEqual(try XCTUnwrap(subject.arrivalAgeSeconds), 0.5, accuracy: 1e-12)
        XCTAssertEqual(session.stopCount, 0)

        fixture.now = Double(102.5).nextDown
        handoff.receiveTrackingState(.normal, clock: clock)
        subject.monitor()
        XCTAssertTrue(subject.isSessionRunning)
        fixture.now = 102.5
        subject.monitor()
        XCTAssertFalse(subject.isSessionRunning)
        XCTAssertEqual(subject.snapshot.lifecycle, .stopped(.frameTimeout))
        XCTAssertNil(subject.snapshot.frame)
        XCTAssertEqual(subject.snapshot.frameCount, 3)
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertEqual(stopRequests, [.frameTimeout])

        handoff.receiveTrackingState(.normal, clock: clock)
        subject.monitor()
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertEqual(stopRequests, [.frameTimeout])
    }

    func testMissingDepthClearsCurrentMeasurementAndNextFrameCanRecover() async throws {
        let fixture = RuntimeFixture()
        let (subject, _, handoff) = try await started(fixture, depthRequested: true)
        defer { subject.stop() }
        let measured = try XCTUnwrap(SpatialDepthMeasurement(
            medianMeters: 2, acceptedSampleCount: 9, confidence: .medium
        ))
        handoff.receive(frame(handoff, depth: .available(measured)), at: fixture.now)
        subject.monitor()
        XCTAssertEqual(subject.snapshot.frame?.depth, .available(measured))
        fixture.now += 0.1
        handoff.receive(frame(handoff, sequence: 2, arTime: 1_000.1,
                              depth: .unavailable(.missingDepth)), at: fixture.now)
        subject.monitor()
        XCTAssertEqual(subject.snapshot.frame?.depth, .unavailable(.missingDepth))
        fixture.now += 0.1
        handoff.receive(frame(handoff, sequence: 3, arTime: 1_000.2,
                              depth: .available(measured)), at: fixture.now)
        subject.monitor()
        XCTAssertEqual(subject.snapshot.frame?.depth, .available(measured))
        XCTAssertEqual(subject.snapshot.associationStatus, .clockMappingUnavailable)
    }

    // All buffers below live only within the synchronous body. Their external
    // storage stays valid through every lock/read/unlock; no release callback or
    // Swift concurrency crossing is needed for this synthetic fixture.
    private func withPixelBuffer<T>(
        width: Int = 5, height: Int = 5, format: OSType,
        bytesPerRow: Int, populate: (UnsafeMutableRawPointer) -> Void,
        body: (CVPixelBuffer) throws -> T
    ) throws -> T {
        let byteCount = bytesPerRow * height
        let storage = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0xFF, count: byteCount)
        populate(storage)
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault, width, height, format, storage, bytesPerRow,
            nil, nil, nil, &buffer
        )
        XCTAssertEqual(result, kCVReturnSuccess)
        let created = try XCTUnwrap(buffer)
        XCTAssertEqual(CVPixelBufferGetBytesPerRow(created), bytesPerRow)
        return try body(created)
    }

    private func withDepthBuffer<T>(
        _ patch: [Float] = Array(repeating: 2, count: 9),
        body: (CVPixelBuffer) throws -> T
    ) throws -> T {
        XCTAssertEqual(patch.count, 9)
        return try withPixelBuffer(
            format: kCVPixelFormatType_DepthFloat32, bytesPerRow: 40,
            populate: { storage in
                for y in 0..<5 {
                    for x in 0..<5 {
                        // Values outside the exact center patch must not enter
                        // the summary. Padding stays nonfinite 0xFF bytes.
                        let value = (1...3).contains(x) && (1...3).contains(y)
                            ? patch[(y - 1) * 3 + x - 1] : Float(1_000)
                        storage.storeBytes(of: value, toByteOffset: y * 40 + x * 4, as: Float.self)
                    }
                }
            }, body: body
        )
    }

    private func withConfidenceBuffer<T>(
        _ patch: [UInt8] = Array(repeating: UInt8(ARConfidenceLevel.high.rawValue), count: 9),
        body: (CVPixelBuffer) throws -> T
    ) throws -> T {
        XCTAssertEqual(patch.count, 9)
        return try withPixelBuffer(
            format: kCVPixelFormatType_OneComponent8, bytesPerRow: 12,
            populate: { storage in
                for y in 0..<5 {
                    for x in 0..<5 {
                        let value = (1...3).contains(x) && (1...3).contains(y)
                            ? patch[(y - 1) * 3 + x - 1] : UInt8(ARConfidenceLevel.low.rawValue)
                        storage.storeBytes(of: value, toByteOffset: y * 12 + x, as: UInt8.self)
                    }
                }
            }, body: body
        )
    }

    func testDepthUsesImageCenterMedianAndCategoricalConfidenceAcrossPaddedRows() throws {
        try withDepthBuffer([9, 1, 7, 3, 5, 2, 8, 6, 4]) { depth in
            try withConfidenceBuffer([2, 2, 2, 2, 1, 2, 2, 2, 2]) { confidence in
                let result = SpatialDepthPatch.reduce(depthMap: depth, confidenceMap: confidence)
                guard case .available(let measurement) = result else {
                    return XCTFail("Expected a finite image-center median, got \(result)")
                }
                XCTAssertEqual(measurement.medianMeters, 5)
                XCTAssertEqual(measurement.acceptedSampleCount, 9)
                XCTAssertEqual(measurement.confidence, .medium)
            }
        }
    }

    func testMissingDepthAndMissingConfidenceHaveExplicitUnavailableReasons() throws {
        XCTAssertEqual(SpatialDepthPatch.reduce(depthMap: nil, confidenceMap: nil),
                       .unavailable(.missingDepth))
        try withDepthBuffer { depth in
            XCTAssertEqual(SpatialDepthPatch.reduce(depthMap: depth, confidenceMap: nil),
                           .unavailable(.missingConfidence))
        }
    }

    func testWrongDepthAndConfidenceFormatsAreRejectedBeforeReading() throws {
        try withConfidenceBuffer { wrongDepth in
            XCTAssertEqual(SpatialDepthPatch.reduce(depthMap: wrongDepth, confidenceMap: wrongDepth),
                           .unavailable(.unsupportedDepthFormat))
        }
        try withDepthBuffer { depth in
            XCTAssertEqual(SpatialDepthPatch.reduce(depthMap: depth, confidenceMap: depth),
                           .unavailable(.unsupportedConfidenceFormat))
        }
    }

    func testMismatchedAndTooSmallDepthDimensionsAreUnavailable() throws {
        try withDepthBuffer { depth in
            try withPixelBuffer(width: 3, height: 3, format: kCVPixelFormatType_OneComponent8,
                                bytesPerRow: 8, populate: { _ in }) { confidence in
                XCTAssertEqual(SpatialDepthPatch.reduce(depthMap: depth, confidenceMap: confidence),
                               .unavailable(.invalidDimensions))
            }
        }
        try withPixelBuffer(width: 2, height: 2, format: kCVPixelFormatType_DepthFloat32,
                            bytesPerRow: 16, populate: { _ in }) { depth in
            try withPixelBuffer(width: 2, height: 2, format: kCVPixelFormatType_OneComponent8,
                                bytesPerRow: 8, populate: { _ in }) { confidence in
                XCTAssertEqual(SpatialDepthPatch.reduce(depthMap: depth, confidenceMap: confidence),
                               .unavailable(.invalidDimensions))
            }
        }
    }

    func testDepthRejectsNonfiniteNonpositiveLowAndUnknownConfidencePixels() throws {
        let depths: [Float] = [.nan, .infinity, 0, -1, 1, 2, 3, 4, 5]
        try withDepthBuffer(depths) { depth in
            try withConfidenceBuffer { confidence in
                let result = SpatialDepthPatch.reduce(depthMap: depth, confidenceMap: confidence)
                guard case .available(let measurement) = result else {
                    return XCTFail("Five finite positive values must remain available")
                }
                XCTAssertEqual(measurement.acceptedSampleCount, 5)
                XCTAssertEqual(measurement.medianMeters, 3)
            }
        }
        try withDepthBuffer { depth in
            try withConfidenceBuffer([0, 255, 0, 0, 0, 2, 2, 2, 2]) { confidence in
                XCTAssertEqual(SpatialDepthPatch.reduce(depthMap: depth, confidenceMap: confidence),
                               .unavailable(.insufficientAcceptedSamples))
            }
            try withConfidenceBuffer([0, 255, 0, 0, 1, 2, 2, 2, 2]) { confidence in
                let result = SpatialDepthPatch.reduce(depthMap: depth, confidenceMap: confidence)
                guard case .available(let measurement) = result else {
                    return XCTFail("Five accepted categorical-confidence pixels must recover")
                }
                XCTAssertEqual(measurement.acceptedSampleCount, 5)
                XCTAssertEqual(measurement.confidence, .medium)
            }
        }
    }
}

import ARKit
import AVFoundation
import Combine
import CoreVideo
import Foundation
import RealityKit
import RheaRFCore
import Synchronization

enum SpatialCameraPermission: Equatable {
    case authorized, denied, restricted, notDetermined, unavailable
}

struct SpatialCapabilities: Equatable {
    let worldTracking: Bool
    let sceneDepth: Bool
}

enum SpatialCameraAvailability: Equatable {
    case off, requestingPermission, ready, needsExplicitStart
    case unsupported, denied, restricted, unavailable, active
}

enum SpatialPreparationResult: Equatable {
    case ready, permissionResolved, unavailable, cancelled
}

/// Explicit allowlist; NSError userInfo and localized descriptions never cross
/// the delegate boundary. This type is not automatically report-encoded.
struct SpatialSanitizedFailure: Sendable, Equatable {
    let domain: String
    let code: Int

    init(domain: String, code: Int) {
        let allowed = ["com.apple.arkit.error", NSCocoaErrorDomain, NSOSStatusErrorDomain]
        self.domain = allowed.contains(domain) ? domain : "other"
        self.code = code
    }
}

struct SpatialContextDelivery: Sendable {
    let snapshot: SpatialContextSnapshot
    let overwrittenSnapshotCount: UInt64
    let stopReason: SpatialStopReason?
    let failure: SpatialSanitizedFailure?
}

/// One serialized policy owner and one pending latest-value slot, no history.
/// Every callback applies tracking policy BEFORE UI coalescing. No audio code
/// reads or locks this object. Only scalar/SIMD values enter its mutex.
final class SpatialContextHandoff: Sendable {
    let runID: SpatialRunID
    private let disabledDepthReason: SpatialDepthUnavailableReason

    private struct State: Sendable {
        var policy = SpatialContextPolicy()
        var pending = false
        var overwritten: UInt64 = 0
        var terminal: SpatialStopReason?
        var failure: SpatialSanitizedFailure?
        var retired = false

        mutating func receive(_ input: SpatialFrameInput, at time: Double) {
            guard !retired, terminal == nil else { return }
            let previous = policy.snapshot
            _ = policy.receive(input, at: time)
            if case .stopped(let reason) = policy.snapshot.lifecycle { terminal = reason }
            guard policy.snapshot != previous else { return }
            if pending, overwritten < .max { overwritten += 1 }
            pending = true
        }

        mutating func receiveTrackingState(
            _ tracking: SpatialTrackingState, runID: SpatialRunID, at time: Double
        ) {
            guard !retired, terminal == nil else { return }
            let previous = policy.snapshot
            _ = policy.receiveTrackingState(tracking, runID: runID, at: time)
            if case .stopped(let reason) = policy.snapshot.lifecycle { terminal = reason }
            guard policy.snapshot != previous else { return }
            if pending, overwritten < .max { overwritten += 1 }
            pending = true
        }

        func delivery() -> SpatialContextDelivery {
            SpatialContextDelivery(snapshot: policy.snapshot,
                                   overwrittenSnapshotCount: overwritten,
                                   stopReason: terminal, failure: failure)
        }
    }

    private let state: Mutex<State>

    init(runID: SpatialRunID, at time: Double,
         disabledDepthReason: SpatialDepthUnavailableReason = .notRequested) {
        self.runID = runID
        self.disabledDepthReason = disabledDepthReason
        var initial = State()
        if !initial.policy.begin(runID: runID, at: time) {
            initial.terminal = .timingInvalid
            initial.policy.stop(reason: .timingInvalid)
        }
        state = Mutex(initial)
    }

    func receive(_ input: SpatialFrameInput, at time: Double) {
        guard input.runID == runID else { return }
        let input = adjustedDepth(input)
        state.withLock { value in
            value.receive(input, at: time)
        }
    }

    /// Production receipts are sampled UNDER the same lock as watchdog ticks.
    /// Otherwise a main tick can overtake an in-flight callback's earlier clock
    /// sample and falsely look like monotonic-clock regression. This timestamp
    /// means metadata handoff receipt after reduction, never sensor capture.
    func receive(_ input: SpatialFrameInput, clock: @Sendable () -> Double) {
        guard input.runID == runID else { return }
        let input = adjustedDepth(input)
        state.withLock { value in value.receive(input, at: clock()) }
    }

    func receiveTrackingState(_ tracking: SpatialTrackingState, at time: Double) {
        state.withLock { value in
            value.receiveTrackingState(tracking, runID: runID, at: time)
        }
    }

    /// Only the scalar state leaves the AR observer callback. As for frames,
    /// sample its receipt clock inside the lock shared with watchdog ticks.
    func receiveTrackingState(_ tracking: SpatialTrackingState, clock: @Sendable () -> Double) {
        state.withLock { value in
            value.receiveTrackingState(tracking, runID: runID, at: clock())
        }
    }

    private func adjustedDepth(_ input: SpatialFrameInput) -> SpatialFrameInput {
        guard input.depth == .unavailable(.notRequested), disabledDepthReason != .notRequested else { return input }
        return SpatialFrameInput(runID: input.runID, frameSequence: input.frameSequence,
                                 arTimestampSeconds: input.arTimestampSeconds,
                                 worldFromCamera: input.worldFromCamera, tracking: input.tracking,
                                 depth: .unavailable(disabledDepthReason))
    }

    func fail(reason: SpatialStopReason, failure: SpatialSanitizedFailure? = nil) {
        state.withLock { value in
            guard !value.retired, value.terminal == nil else { return }
            value.terminal = reason
            value.failure = failure
            value.policy.stop(reason: reason)
            value.pending = true
        }
    }

    func drain(at time: Double) -> SpatialContextDelivery {
        state.withLock { value in
            if !value.retired, value.terminal == nil,
               let reason = value.policy.tick(at: time) {
                value.terminal = reason
            }
            let result = value.delivery()
            value.pending = false
            return result
        }
    }

    /// As with production frame receipt, serialize the clock sample itself.
    func drain(clock: @Sendable () -> Double) -> SpatialContextDelivery {
        state.withLock { value in
            if !value.retired, value.terminal == nil,
               let reason = value.policy.tick(at: clock()) {
                value.terminal = reason
            }
            let result = value.delivery()
            value.pending = false
            return result
        }
    }

    @discardableResult
    func retire(reason: SpatialStopReason) -> SpatialContextDelivery {
        state.withLock { value in
            if !value.retired {
                value.retired = true // reject callbacks before session.pause()
                value.terminal = value.terminal ?? reason
                value.policy.stop(reason: value.terminal ?? reason)
                value.pending = false
            }
            return value.delivery()
        }
    }
}

/// Narrow adapter: the coordinator owns audio and the combined run. A session
/// and its preview are never reused for another spatial run.
@MainActor
protocol SpatialContextSession: AnyObject {
    var previewView: ARView? { get }
    func start(handoff: SpatialContextHandoff, depthEnabled: Bool) throws
    func stop()
}

@MainActor
struct SpatialContextRuntime {
    let clock: @Sendable () -> Double
    let capabilities: @MainActor () -> SpatialCapabilities
    let permission: @MainActor () -> SpatialCameraPermission
    let requestPermission: @MainActor () async -> Bool
    let makeSession: @MainActor () -> any SpatialContextSession

    static var system: Self {
        Self(
            clock: { ProcessInfo.processInfo.systemUptime },
            capabilities: {
                #if targetEnvironment(simulator)
                SpatialCapabilities(worldTracking: false, sceneDepth: false)
                #else
                SpatialCapabilities(
                    worldTracking: ARWorldTrackingConfiguration.isSupported,
                    sceneDepth: ARWorldTrackingConfiguration.isSupported
                        && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
                )
                #endif
            },
            permission: {
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized: .authorized
                case .denied: .denied
                case .restricted: .restricted
                case .notDetermined: .notDetermined
                @unknown default: .unavailable
                }
            },
            requestPermission: { await AVCaptureDevice.requestAccess(for: .video) },
            makeSession: { SpatialARSession() }
        )
    }
}

/// All UI, permission and session lifecycle calls belong to the main actor.
/// Only the checked-Sendable handoff crosses to the serial delegate queue.
/// The parent MUST call stop on every combined teardown and owner removal.
@MainActor
final class SpatialContextController: ObservableObject {
    @Published private(set) var snapshot = SpatialContextPolicy().snapshot
    @Published private(set) var availability: SpatialCameraAvailability = .off
    @Published private(set) var cameraPermission: SpatialCameraPermission = .notDetermined
    @Published private(set) var capabilities = SpatialCapabilities(worldTracking: false, sceneDepth: false)
    @Published private(set) var previewView: ARView?
    @Published private(set) var overwrittenSnapshotCount: UInt64 = 0
    @Published private(set) var sanitizedFailure: SpatialSanitizedFailure?
    @Published private(set) var arrivalAgeSeconds: Double?

    /// Camera termination is delivered once on main, outside delegate callbacks.
    /// Coordinator should stop its combined Listen run here; no audio API lives
    /// in this controller. Plain coordinator-initiated stop does not recurse.
    var onStopRequired: (@MainActor (SpatialStopReason) -> Void)?

    private let runtime: SpatialContextRuntime
    private let automaticUpdates: Bool
    private var foregroundActive = false
    private var readyPermit = false
    private var permissionGeneration: UInt64 = 0
    private var nextRunID: UInt64 = 0
    private var session: (any SpatialContextSession)?
    private var handoff: SpatialContextHandoff?
    private var monitorTask: Task<Void, Never>?
    private var startedAt: Double?

    var isSessionRunning: Bool { session != nil }

    init(runtime: SpatialContextRuntime? = nil, automaticUpdates: Bool = true) {
        self.runtime = runtime ?? .system
        self.automaticUpdates = automaticUpdates
        // Construction does not even request permission or construct an ARView.
    }

    /// Call ONLY from the coordinator's explicit Start action, before starting
    /// either sensor. A first permission completion always returns to idle;
    /// another explicit Start must prepare again before startAuthorized succeeds.
    func prepareForExplicitStart() async -> SpatialPreparationResult {
        guard foregroundActive, session == nil, availability != .requestingPermission else { return .unavailable }
        readyPermit = false
        capabilities = runtime.capabilities()
        guard capabilities.worldTracking else {
            availability = .unsupported
            return .unavailable
        }
        cameraPermission = runtime.permission()
        switch cameraPermission {
        case .authorized:
            readyPermit = true
            availability = .ready
            return .ready
        case .denied:
            availability = .denied
        case .restricted:
            availability = .restricted
        case .unavailable:
            availability = .unavailable
        case .notDetermined:
            guard permissionGeneration < .max else { return .unavailable }
            permissionGeneration += 1
            let generation = permissionGeneration
            availability = .requestingPermission
            let granted = await runtime.requestPermission()
            guard generation == permissionGeneration else { return .cancelled }
            guard !Task.isCancelled else {
                availability = .off
                return .cancelled
            }
            // Neither a granted answer nor returning from Settings starts AR.
            cameraPermission = runtime.permission()
            availability = granted ? .needsExplicitStart : permissionAvailability(cameraPermission)
            return .permissionResolved
        }
        return .unavailable
    }

    /// Coordinator calls after BOTH permissions/capabilities are ready and its
    /// Listen audio start succeeded. This is an explicit action, never a view,
    /// permission completion, Settings return, inspection, or resume callback.
    @discardableResult
    func startAuthorized(depthRequested: Bool = false) -> Bool {
        guard readyPermit, foregroundActive, session == nil else { return false }
        readyPermit = false // one-shot, including failed attempts
        capabilities = runtime.capabilities()
        cameraPermission = runtime.permission()
        guard capabilities.worldTracking, cameraPermission == .authorized else {
            availability = capabilities.worldTracking ? permissionAvailability(cameraPermission) : .unsupported
            return false
        }
        guard nextRunID < .max else {
            availability = .unavailable
            onStopRequired?(.identifierExhausted)
            return false
        }
        nextRunID += 1
        // Native factory prepares a manual, still-paused preview. Exclude that
        // construction cost from the authorized session's first-frame budget.
        let newSession = runtime.makeSession()
        let time = runtime.clock()
        guard time.isFinite, time >= 0 else {
            newSession.stop()
            availability = .unavailable
            onStopRequired?(.timingInvalid)
            return false
        }
        let newHandoff = SpatialContextHandoff(
            runID: nextRunID, at: time,
            disabledDepthReason: depthRequested && !capabilities.sceneDepth ? .unsupported : .notRequested
        )
        handoff = newHandoff
        session = newSession
        startedAt = time
        overwrittenSnapshotCount = 0
        sanitizedFailure = nil
        arrivalAgeSeconds = nil
        availability = .active
        snapshot = newHandoff.drain(at: time).snapshot
        do {
            try newSession.start(handoff: newHandoff, depthEnabled: depthRequested && capabilities.sceneDepth)
            previewView = newSession.previewView
            if automaticUpdates { startMonitor() }
            return true
        } catch {
            let nsError = error as NSError
            newHandoff.fail(reason: .sessionFailure,
                            failure: SpatialSanitizedFailure(domain: nsError.domain, code: nsError.code))
            monitor()
            return false
        }
    }

    func setForegroundActive(_ active: Bool) {
        foregroundActive = active
        if !active {
            readyPermit = false
            cancelPermissionPreparation()
            if session != nil { terminateAndNotify(.inactive) }
            else { availability = .off }
        }
    }

    /// Polls metadata/watchdogs only. The single 10 Hz task bounds pending UI
    /// work independently of camera frame rate. Tests drive the identical path.
    func monitor() {
        guard let handoff else { return }
        let delivery = handoff.drain(clock: runtime.clock)
        publish(delivery)
        let now = runtime.clock()
        if let frame = snapshot.frame, let startedAt,
           now.isFinite, now >= startedAt + frame.receivedElapsedSeconds {
            arrivalAgeSeconds = now - startedAt - frame.receivedElapsedSeconds
        } else {
            arrivalAgeSeconds = nil
        }
        if let reason = delivery.stopReason { terminateAndNotify(reason) }
    }

    func stop(reason: SpatialStopReason = .user) {
        readyPermit = false
        cancelPermissionPreparation()
        monitorTask?.cancel()
        monitorTask = nil
        // Retire mailbox before pause/detach. Already executing old callbacks
        // can finish reducing their own frame but cannot republish anything.
        if let handoff { publish(handoff.retire(reason: reason)) }
        handoff = nil
        let retiringSession = session
        session = nil
        retiringSession?.stop()
        previewView = nil
        arrivalAgeSeconds = nil
        startedAt = nil
        availability = .off
    }

    /// UIViewRepresentable teardown is a stop safety net, never a start hook.
    func previewDetached(for runID: SpatialRunID?) {
        if let runID, snapshot.runID == runID, session != nil { terminateAndNotify(.user) }
    }

    private func terminateAndNotify(_ reason: SpatialStopReason) {
        guard session != nil else { return }
        stop(reason: reason)
        onStopRequired?(reason)
    }

    private func publish(_ delivery: SpatialContextDelivery) {
        snapshot = delivery.snapshot
        overwrittenSnapshotCount = delivery.overwrittenSnapshotCount
        sanitizedFailure = delivery.failure
    }

    private func cancelPermissionPreparation() {
        if permissionGeneration < .max { permissionGeneration += 1 }
        if availability == .requestingPermission { availability = .off }
    }

    private func permissionAvailability(_ permission: SpatialCameraPermission) -> SpatialCameraAvailability {
        switch permission {
        case .authorized: .needsExplicitStart
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined, .unavailable: .unavailable
        }
    }

    private func startMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
                guard let self, self.session != nil else { return }
                self.monitor()
            }
        }
    }
}

/// This NSObject is deliberately NOT main-actor isolated or unchecked Sendable.
/// ARKit invokes its callbacks on the dedicated serial queue. The only mutable
/// field, sequence, belongs exclusively to that queue for this one session.
private final class SpatialARDelegate: NSObject, ARSessionDelegate {
    private let handoff: SpatialContextHandoff
    private let depthEnabled: Bool
    private var sequence: UInt64 = 0

    init(handoff: SpatialContextHandoff, depthEnabled: Bool) {
        self.handoff = handoff
        self.depthEnabled = depthEnabled
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard sequence < .max else { handoff.fail(reason: .identifierExhausted); return }
        sequence += 1
        let transform = frame.camera.transform
        let matrix = SpatialMatrix4x4(column0: transform.columns.0, column1: transform.columns.1,
                                     column2: transform.columns.2, column3: transform.columns.3)
        let tracking = Self.trackingState(frame.camera.trackingState)
        let depth: SpatialDepthSummary
        if depthEnabled {
            // Current unsmoothed sceneDepth only. All map reads finish before
            // this callback returns; no ARFrame/CVPixelBuffer enters handoff.
            if let data = frame.sceneDepth {
                depth = SpatialDepthPatch.reduce(depthMap: data.depthMap, confidenceMap: data.confidenceMap)
            } else {
                depth = .unavailable(.missingDepth)
            }
        } else {
            depth = .unavailable(.notRequested)
        }
        handoff.receive(SpatialFrameInput(runID: handoff.runID, frameSequence: sequence,
                                         arTimestampSeconds: frame.timestamp,
                                         worldFromCamera: matrix, tracking: tracking, depth: depth),
                        clock: { ProcessInfo.processInfo.systemUptime })
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        // A separate loss notification must invalidate the old pose even if
        // ARKit does not subsequently deliver another captured frame.
        handoff.receiveTrackingState(Self.trackingState(camera.trackingState),
                                     clock: { ProcessInfo.processInfo.systemUptime })
    }

    private static func trackingState(_ state: ARCamera.TrackingState) -> SpatialTrackingState {
        switch state {
        case .normal: return .normal
        case .notAvailable: return .unavailable
        case .limited(let reason):
            switch reason {
            case .initializing: return .limited(.initializing)
            case .excessiveMotion: return .limited(.excessiveMotion)
            case .insufficientFeatures: return .limited(.insufficientFeatures)
            case .relocalizing: return .limited(.relocalizing)
            @unknown default: return .limited(.unknown)
            }
        @unknown default: return .unavailable
        }
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        let nsError = error as NSError
        handoff.fail(reason: .sessionFailure,
                     failure: SpatialSanitizedFailure(domain: nsError.domain, code: nsError.code))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        // No pause/teardown inline: main polling abandons the combined run.
        // We intentionally do not depend on interruption-ended or auto-resume.
        handoff.fail(reason: .interruption)
    }
}

@MainActor
private final class SpatialARSession: SpatialContextSession {
    private(set) var previewView: ARView?
    private var delegate: SpatialARDelegate?
    private var started = false
    private let queue = DispatchQueue(label: "org.timelabs.RheaRFSpanner.spatial", qos: .userInitiated)

    init() {
        let view = SpatialContextPreview.makeARView()
        view.session = ARSession() // fresh session, still not running
        previewView = view
    }

    func start(handoff: SpatialContextHandoff, depthEnabled: Bool) throws {
        precondition(!started && previewView != nil, "An AR adapter is single-run")
        guard let view = previewView else { return }
        started = true
        let session = view.session
        let delegate = SpatialARDelegate(handoff: handoff, depthEnabled: depthEnabled)
        self.delegate = delegate // ARSession.delegate is weak
        session.delegateQueue = queue
        session.delegate = delegate
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.providesAudioData = false
        configuration.planeDetection = []
        configuration.sceneReconstruction = []
        configuration.userFaceTrackingEnabled = false
        configuration.isAutoFocusEnabled = true
        configuration.environmentTexturing = .none
        configuration.frameSemantics = depthEnabled ? [.sceneDepth] : []
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        previewView?.session.delegate = nil
        previewView?.session.pause()
        previewView = nil
        delegate = nil
    }
}

/// Synchronous callback-local adapter for intentionally supported nonplanar
/// DepthFloat32 / OneComponent8 maps. Loads honor each independent row stride.
enum SpatialDepthPatch {
    static func reduce(depthMap: CVPixelBuffer?, confidenceMap: CVPixelBuffer?) -> SpatialDepthSummary {
        guard let depthMap else { return .unavailable(.missingDepth) }
        guard let confidenceMap else { return .unavailable(.missingConfidence) }
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
              !CVPixelBufferIsPlanar(depthMap) else { return .unavailable(.unsupportedDepthFormat) }
        guard CVPixelBufferGetPixelFormatType(confidenceMap) == kCVPixelFormatType_OneComponent8,
              !CVPixelBufferIsPlanar(confidenceMap) else { return .unavailable(.unsupportedConfidenceFormat) }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width >= 3, height >= 3,
              width == CVPixelBufferGetWidth(confidenceMap),
              height == CVPixelBufferGetHeight(confidenceMap) else { return .unavailable(.invalidDimensions) }
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceStride = CVPixelBufferGetBytesPerRow(confidenceMap)
        let depthRow = width.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        let depthSize = depthStride.multipliedReportingOverflow(by: height)
        let confidenceSize = confidenceStride.multipliedReportingOverflow(by: height)
        guard !depthRow.overflow, !depthSize.overflow, !confidenceSize.overflow,
              depthStride >= depthRow.partialValue, confidenceStride >= width,
              depthSize.partialValue <= CVPixelBufferGetDataSize(depthMap),
              confidenceSize.partialValue <= CVPixelBufferGetDataSize(confidenceMap)
        else { return .unavailable(.invalidStride) }
        guard CVPixelBufferLockBaseAddress(depthMap, .readOnly) == kCVReturnSuccess else {
            return .unavailable(.lockFailed)
        }
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) == kCVReturnSuccess else {
            return .unavailable(.lockFailed)
        }
        defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        guard let depths = CVPixelBufferGetBaseAddress(depthMap),
              let confidence = CVPixelBufferGetBaseAddress(confidenceMap) else {
            return .unavailable(.missingBaseAddress)
        }
        var samples: [SpatialDepthSample] = []
        samples.reserveCapacity(9)
        // For even dimensions, integer division selects the higher center
        // pixel. This is IMAGE center; no screen/ray registration is claimed.
        for y in (height / 2 - 1)...(height / 2 + 1) {
            for x in (width / 2 - 1)...(width / 2 + 1) {
                let meters = depths.loadUnaligned(fromByteOffset: y * depthStride + x * MemoryLayout<Float>.size,
                                                 as: Float.self)
                let category = confidence.load(fromByteOffset: y * confidenceStride + x, as: UInt8.self)
                samples.append(SpatialDepthSample(depthMeters: meters,
                                                   confidence: SpatialDepthConfidence(rawValue: category)))
            }
        }
        return SpatialDepthReducer.reduce(samples: samples)
    }
}

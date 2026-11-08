import Foundation

/// An export-safe view of renderer activity. It contains counts and elapsed
/// intervals, never an absolute system clock, sample arrays, or device IDs.
struct RendererDiagnosticSnapshot: Sendable, Codable, Equatable {
    var setupStatus = "not_initialized"
    var errorStage: String?
    var errorDomain: String?
    var errorCode: Int?
    var drawRequests: UInt64 = 0
    var submittedFrames: UInt64 = 0
    var completedFrames: UInt64 = 0
    var failedFrames: UInt64 = 0
    var noDrawableCount: UInt64 = 0
    var commandAllocationFailures: UInt64 = 0
    var encoderAllocationFailures: UInt64 = 0
    var inFlightSkips: UInt64 = 0
    var textureAllocationFailures: UInt64 = 0
    var lastError: String?
    var completedFramesInWindow: UInt64 = 0
    var frameRateWindowSeconds: Double = 0
    var lastSubmittedSampleTimestamp: UInt64?
    /// Whether the current waterfall texture contains any available spectrum.
    var hasSpectrum = false

    /// Successful GPU completion callbacks per elapsed observation interval.
    /// This is not a display refresh or physical screen-presentation rate.
    /// A computed property is deliberately omitted from synthesized Codable.
    var measuredCompletedFramesPerSecond: Double {
        guard frameRateWindowSeconds.isFinite, frameRateWindowSeconds > 0 else { return 0 }
        let rate = Double(completedFramesInWindow) / frameRateWindowSeconds
        return rate.isFinite ? rate : 0
    }
}

/// Static diagnoses avoid copying NSError descriptions, shader text, paths,
/// or driver logs into the user-exported report.
enum RendererDiagnosticFailure: Int {
    case deviceUnavailable = 1
    case commandQueueUnavailable
    case shaderLibraryUnavailable
    case shaderFunctionUnavailable
    case pipelineUnavailable
    case initialTextureUnavailable
    case drawableUnavailable
    case commandBufferUnavailable
    case renderEncoderUnavailable
    case textureAllocationFailed
    case gpuExecutionFailed

    var stage: String {
        switch self {
        case .deviceUnavailable: "setup.device"
        case .commandQueueUnavailable: "setup.command_queue"
        case .shaderLibraryUnavailable: "setup.shader_library"
        case .shaderFunctionUnavailable: "setup.shader_function"
        case .pipelineUnavailable: "setup.pipeline"
        case .initialTextureUnavailable: "setup.texture"
        case .drawableUnavailable: "draw.drawable"
        case .commandBufferUnavailable: "draw.command_buffer"
        case .renderEncoderUnavailable: "draw.render_encoder"
        case .textureAllocationFailed: "spectrum.texture"
        case .gpuExecutionFailed: "draw.gpu_completion"
        }
    }

    var message: String {
        switch self {
        case .deviceUnavailable: "A Metal device is unavailable."
        case .commandQueueUnavailable: "A Metal command queue could not be created."
        case .shaderLibraryUnavailable: "The bundled Metal shader library is unavailable."
        case .shaderFunctionUnavailable: "A required bundled Metal shader function is missing."
        case .pipelineUnavailable: "The Metal render pipeline could not be created."
        case .initialTextureUnavailable: "The initial spectrum texture could not be allocated."
        case .drawableUnavailable: "No drawable was available; the view may be hidden or resizing."
        case .commandBufferUnavailable: "A Metal command buffer could not be allocated."
        case .renderEncoderUnavailable: "A Metal render encoder could not be allocated."
        case .textureAllocationFailed: "A replacement spectrum texture could not be allocated."
        case .gpuExecutionFailed: "A submitted GPU command buffer did not complete successfully."
        }
    }
}

/// Main-actor owned and intentionally not ObservableObject: recording a GPU
/// completion must not publish a SwiftUI update that requests another frame.
/// The diagnostic panel may take a value snapshot at its own bounded cadence.
@MainActor
final class RendererDiagnostics {
    private static let bucketSeconds: Double = 0.125
    private static let bucketCount = 16
    private let clock: @MainActor () -> TimeInterval
    private let origin: TimeInterval
    private var lastElapsed: TimeInterval = 0
    private var bucketEpochs = Array(repeating: Int64(-1), count: RendererDiagnostics.bucketCount)
    private var bucketCompletions = Array(repeating: UInt64(0), count: RendererDiagnostics.bucketCount)
    private var state = RendererDiagnosticSnapshot()

    init(clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        let now = clock()
        origin = now.isFinite && now >= 0 ? now : 0
    }

    func snapshot() -> RendererDiagnosticSnapshot {
        let elapsed = elapsedNow()
        let currentEpoch = bucketEpoch(for: elapsed)
        let oldestEpoch = max(0, currentEpoch - Int64(Self.bucketCount - 1))
        var count: UInt64 = 0
        for index in bucketEpochs.indices
        where bucketEpochs[index] >= oldestEpoch && bucketEpochs[index] <= currentEpoch {
            count = Self.saturatingSum(count, bucketCompletions[index])
        }
        // A full window spans 1.875–2.0 seconds according to its current bucket.
        // The initial partial bucket uses at least 125 ms, avoiding an unbounded
        // first-frame rate. No absolute uptime enters the returned value.
        let windowStart = Double(oldestEpoch) * Self.bucketSeconds
        var result = state
        result.completedFramesInWindow = count
        result.frameRateWindowSeconds = max(Self.bucketSeconds, elapsed - windowStart)
        return result
    }

    func recordSetupStarted() { state.setupStatus = "initializing" }
    func recordSetupSucceeded() { state.setupStatus = "ready" }

    func recordSetupFailure(_ failure: RendererDiagnosticFailure, error: Error? = nil) {
        state.setupStatus = "failed"
        if failure == .initialTextureUnavailable {
            Self.increment(&state.textureAllocationFailures)
        }
        let systemError = error as NSError?
        recordFailure(failure, domain: systemError?.domain, code: systemError?.code)
    }

    func recordDrawRequest() { Self.increment(&state.drawRequests) }
    func recordInFlightSkip() { Self.increment(&state.inFlightSkips) }

    func recordNoDrawable() {
        Self.increment(&state.noDrawableCount)
        recordFailure(.drawableUnavailable)
    }

    func recordCommandAllocationFailure() {
        Self.increment(&state.commandAllocationFailures)
        recordFailure(.commandBufferUnavailable)
    }

    func recordEncoderAllocationFailure() {
        Self.increment(&state.encoderAllocationFailures)
        recordFailure(.renderEncoderUnavailable)
    }

    func recordTextureAllocationFailure() {
        Self.increment(&state.textureAllocationFailures)
        state.hasSpectrum = false
        recordFailure(.textureAllocationFailed)
    }

    func recordSpectrumAvailability(_ available: Bool) { state.hasSpectrum = available }

    func recordSubmittedFrame(sampleTimestamp: UInt64?) {
        Self.increment(&state.submittedFrames)
        state.lastSubmittedSampleTimestamp = sampleTimestamp
    }

    /// Called on the main actor after inspecting the actual command buffer's
    /// terminal status. Primitive error metadata alone crosses the actor hop.
    func recordCompletion(succeeded: Bool, errorDomain: String? = nil, errorCode: Int? = nil) {
        guard succeeded else {
            Self.increment(&state.failedFrames)
            recordFailure(.gpuExecutionFailed, domain: errorDomain, code: errorCode)
            return
        }
        Self.increment(&state.completedFrames)
        let epoch = bucketEpoch(for: elapsedNow())
        let slot = Int(epoch % Int64(Self.bucketCount))
        if bucketEpochs[slot] != epoch {
            bucketEpochs[slot] = epoch
            bucketCompletions[slot] = 0
        }
        Self.increment(&bucketCompletions[slot])
    }

    private func recordFailure(
        _ failure: RendererDiagnosticFailure, domain: String? = nil, code: Int? = nil
    ) {
        state.errorStage = failure.stage
        state.errorDomain = domain.map(Self.allowedErrorDomain) ?? "RheaRenderer"
        state.errorCode = code ?? failure.rawValue
        state.lastError = failure.message
    }

    private static func allowedErrorDomain(_ domain: String) -> String {
        switch domain {
        case "MTLCommandBufferErrorDomain", "MTLRenderPipelineErrorDomain", "MTLLibraryErrorDomain",
             "MTLCompilerErrorDomain", "NSCocoaErrorDomain", "NSPOSIXErrorDomain", "NSOSStatusErrorDomain":
            domain
        default:
            // Unknown NSError domains may be supplied by external code. Keep
            // the numeric code, but never export a free-form private string.
            "OtherSystemError"
        }
    }

    private func elapsedNow() -> TimeInterval {
        let now = clock()
        let elapsed = now - origin
        guard now.isFinite, elapsed.isFinite, elapsed >= 0 else { return lastElapsed }
        lastElapsed = max(lastElapsed, elapsed)
        return lastElapsed
    }

    private func bucketEpoch(for elapsed: TimeInterval) -> Int64 {
        // The upper bound also makes a fault-injected extreme clock harmless.
        Int64(min(floor(elapsed / Self.bucketSeconds), Double(Int64.max / 2)))
    }

    private static func increment(_ count: inout UInt64) {
        if count < .max { count += 1 }
    }

    private static func saturatingSum(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }
}

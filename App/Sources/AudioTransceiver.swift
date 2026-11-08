import AVFAudio
import Foundation
import RheaRFCore
import Synchronization

/// All reasons end the current session. None schedules an automatic restart.
enum ExperimentStopReason: Int, Sendable {
    case user = 1
    case inactive
    case timeLimit
    case interruption
    case routeChanged
    case mediaServicesLost
    case mediaServicesReset
    case engineConfigurationChanged
    case renderTimelineChanged
    case unsupportedBuffer
    case startFailed
    case retuned
    case inputStalled
    case processingStalled

    var message: String {
        switch self {
        case .user: "Experiment stopped. The microphone and tone are off."
        case .inactive: "Experiment stopped when the app became inactive. Tap Record to begin a new session."
        case .timeLimit: "The 60-second experiment has ended. The microphone and tone are off."
        case .interruption: "Audio was interrupted. The experiment stopped. Open Diagnostics for the session report."
        case .routeChanged: "The audio route changed. The experiment stopped. Open Diagnostics for the route report."
        case .mediaServicesLost: "The audio service became unavailable. The experiment stopped. Open Diagnostics for the session report."
        case .mediaServicesReset: "The audio service restarted. Open Diagnostics for the session report, then tap Record when ready."
        case .engineConfigurationChanged: "The audio format changed. The experiment stopped. Open Diagnostics for the format report."
        case .renderTimelineChanged: "Playback sample timing became unavailable or discontinuous. The experiment stopped. Open Diagnostics for the timing report."
        case .unsupportedBuffer: "An unsupported audio buffer was received. The experiment stopped. Open Diagnostics for the format report."
        case .startFailed: "The audio experiment could not start. Open Diagnostics for the startup report."
        case .retuned: "Carrier changed. A new acquisition and phase reference have started."
        case .inputStalled: "No live microphone buffers arrived for 2 seconds. The experiment stopped. Open Diagnostics for the audio route and callback report."
        case .processingStalled: "Microphone data arrived, but signal processing stalled for 2 seconds. The experiment stopped. Open Diagnostics for the pipeline report."
        }
    }

    var diagnosticCode: String {
        switch self {
        case .user: "user"
        case .inactive: "inactive"
        case .timeLimit: "time_limit"
        case .interruption: "interruption"
        case .routeChanged: "route_changed"
        case .mediaServicesLost: "media_services_lost"
        case .mediaServicesReset: "media_services_reset"
        case .engineConfigurationChanged: "engine_configuration_changed"
        case .renderTimelineChanged: "render_timeline_changed"
        case .unsupportedBuffer: "unsupported_buffer"
        case .startFailed: "start_failed"
        case .retuned: "retuned"
        case .inputStalled: "input_stalled"
        case .processingStalled: "processing_stalled"
        }
    }
}

/// Cross-thread state contains atomics only. Audio callbacks never access UI state.
final class ExperimentControl: Sendable {
    static let maximumDurationSeconds: UInt64 = 60
    static let transmitAmplitude: Float = 0.02

    let cancelled = Atomic<Bool>(false)
    let audioEnabled = Atomic<Bool>(false)
    let resetRequested = Atomic<Bool>(false)
    /// Supported microphone samples offered to the ring, including dropped blocks.
    let capturedSamples = Atomic<UInt64>(0)
    /// DEMO's generated samples; no microphone capture or transmission is implied.
    let syntheticSamples = Atomic<UInt64>(0)
    /// Samples actually rendered by the active tone source only.
    let renderedSamples = Atomic<UInt64>(0)
    private let stopReasonCode = Atomic<Int>(0)

    func requestStop(_ reason: ExperimentStopReason) {
        _ = stopReasonCode.compareExchange(
            expected: 0, desired: reason.rawValue, ordering: .acquiringAndReleasing
        )
        cancelled.store(true, ordering: .releasing)
    }

    var stopReason: ExperimentStopReason {
        ExperimentStopReason(rawValue: stopReasonCode.load(ordering: .acquiring)) ?? .user
    }
}

/// Mutable fields belong exclusively to the source node's serial render callback.
/// The only cross-thread fields are `control` atomics. A context is never reused.
private final class ToneRenderContext: @unchecked Sendable {
    private let control: ExperimentControl
    private let diagnostics: SessionDiagnosticCounters
    private let oscillator: SineOscillator
    private let maximumSamples: UInt64
    private let rampSamples: UInt64
    private var rendered: UInt64 = 0
    private var nextRenderSampleTime: Double?

    init(
        control: ExperimentControl, diagnostics: SessionDiagnosticCounters,
        configuration: RadarConfiguration, maximumSamples: UInt64
    ) {
        self.control = control
        self.diagnostics = diagnostics
        oscillator = SineOscillator(
            configuration: configuration, amplitude: ExperimentControl.transmitAmplitude
        )
        self.maximumSamples = maximumSamples
        rampSamples = UInt64(configuration.sampleRateHz / 100) // 10 ms at each end.
    }

    func render(
        isSilence: UnsafeMutablePointer<ObjCBool>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        diagnostics.sourceCallbacks.wrappingAdd(1, ordering: .relaxed)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        isSilence.pointee = true
        // The source was configured as one noninterleaved Float32 channel.
        guard buffers.count == 1,
              buffers[0].mNumberChannels == 1,
              let raw = buffers[0].mData,
              Int(buffers[0].mDataByteSize) >= Int(frameCount) * MemoryLayout<Float>.stride
        else {
            silence(buffers)
            control.requestStop(.unsupportedBuffer)
            return noErr
        }

        let destination = raw.assumingMemoryBound(to: Float.self)
        let count = Int(frameCount)
        guard !control.cancelled.load(ordering: .acquiring),
              control.audioEnabled.load(ordering: .acquiring), rendered < maximumSamples else {
            destination.update(repeating: 0, count: count)
            return noErr
        }
        guard count > 0 else { return noErr }
        let sampleTime = timestamp.pointee.mSampleTime
        guard timestamp.pointee.mFlags.contains(.sampleTimeValid), sampleTime.isFinite,
              abs(sampleTime) <= 4_503_599_627_370_496,
              sampleTime.rounded(.towardZero) == sampleTime,
              nextRenderSampleTime == nil || sampleTime == nextRenderSampleTime
        else {
            destination.update(repeating: 0, count: count)
            diagnostics.sourceTimelineErrorCount.wrappingAdd(1, ordering: .relaxed)
            control.requestStop(.renderTimelineChanged)
            return noErr
        }
        nextRenderSampleTime = sampleTime + Double(count)

        let audibleCount = min(count, Int(maximumSamples - rendered))
        for index in 0..<audibleCount {
            let position = rendered + UInt64(index)
            let rise = min(1.0, Float(position) / Float(rampSamples))
            let fall = min(1.0, Float(maximumSamples - position - 1) / Float(rampSamples))
            destination[index] = oscillator.nextSample() * min(rise, fall)
        }
        if audibleCount < count {
            destination.advanced(by: audibleCount).update(repeating: 0, count: count - audibleCount)
        }
        // A notification may have cancelled this session while the block rendered.
        if control.cancelled.load(ordering: .acquiring) {
            destination.update(repeating: 0, count: count)
            return noErr
        }
        rendered += UInt64(audibleCount)
        control.renderedSamples.store(rendered, ordering: .releasing)
        isSilence.pointee = ObjCBool(audibleCount == 0)
        if rendered >= maximumSamples { control.requestStop(.timeLimit) }
        return noErr
    }

    private func silence(_ buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }
}

/// Mutable clock fields belong only to the input tap. The ring has one producer.
/// Absolute hardware time is normalized without converting it to floating point.
final class CaptureContext: @unchecked Sendable {
    private let ring: SPSCFloatRingBuffer
    private let control: ExperimentControl
    private let diagnostics: SessionDiagnosticCounters
    private let expectedSampleRate: Double
    private let maximumSamples: UInt64
    private var origin: UInt64?
    private var fallbackNextSample: UInt64 = 0
    private var capturedSamples: UInt64 = 0

    init(
        ring: SPSCFloatRingBuffer, control: ExperimentControl, diagnostics: SessionDiagnosticCounters,
        configuration: RadarConfiguration, maximumSamples: UInt64
    ) {
        self.ring = ring
        self.control = control
        self.diagnostics = diagnostics
        expectedSampleRate = configuration.sampleRate
        self.maximumSamples = maximumSamples
    }

    func receive(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        diagnostics.recordInputCallback(frameCount: Int(buffer.frameLength))
        guard !control.cancelled.load(ordering: .acquiring),
              control.audioEnabled.load(ordering: .acquiring) else {
            diagnostics.ignoredInputCallbacks.wrappingAdd(1, ordering: .relaxed)
            return
        }
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              buffer.format.channelCount > 0,
              abs(buffer.format.sampleRate - expectedSampleRate) < 0.01,
              let channels = buffer.floatChannelData
        else {
            control.requestStop(.unsupportedBuffer)
            return
        }
        guard capturedSamples < maximumSamples else {
            control.requestStop(.timeLimit)
            return
        }
        guard buffer.frameLength > 0 else { return }
        let count = min(Int(buffer.frameLength), Int(maximumSamples - capturedSamples))

        let timestampIsValid = time.isSampleTimeValid && abs(time.sampleRate - expectedSampleRate) < 0.01
        let firstSample: UInt64
        if timestampIsValid {
            let hardwareSample = UInt64(bitPattern: time.sampleTime)
            if origin == nil { origin = hardwareSample &- fallbackNextSample }
            firstSample = hardwareSample &- (origin ?? hardwareSample)
        } else {
            firstSample = fallbackNextSample
        }
        if capturedSamples > 0, firstSample != fallbackNextSample {
            diagnostics.timestampGapCount.wrappingAdd(1, ordering: .relaxed)
        }
        if !timestampIsValid { diagnostics.invalidTimestampCount.wrappingAdd(1, ordering: .relaxed) }
        diagnostics.lastCaptureSampleIndex.store(firstSample, ordering: .relaxed)
        diagnostics.sampleTimestampValid.store(timestampIsValid, ordering: .relaxed)
        diagnostics.hostTimestampValid.store(time.isHostTimeValid, ordering: .relaxed)
        diagnostics.offeredSamples.wrappingAdd(UInt64(count), ordering: .relaxed)
        // Advance even when the ring drops this block. A loss cannot silently
        // become a contiguous capture timeline on a later successful write.
        fallbackNextSample = firstSample &+ UInt64(count)
        let enqueued = ring.write(
            from: channels[0], count: count,
            startSampleTime: firstSample, timestampIsValid: timestampIsValid
        )
        if enqueued { diagnostics.enqueuedSamples.wrappingAdd(UInt64(count), ordering: .relaxed) }
        diagnostics.acceptedInputCallbacks.wrappingAdd(1, ordering: .releasing)
        capturedSamples += UInt64(count)
        control.capturedSamples.store(capturedSamples, ordering: .releasing)
        if capturedSamples >= maximumSamples { control.requestStop(.timeLimit) }
    }
}

/// A new instance owns a new ring and DSP engine for every user-started session.
/// `engine` is only accessed from `queue`; cancellation never resets live memory.
final class SignalProcessingSession: @unchecked Sendable {
    let control = ExperimentControl()
    let diagnostics = SessionDiagnosticCounters()
    let ring: SPSCFloatRingBuffer
    let configuration: RadarConfiguration
    let acquisitionKind: AcquisitionKind
    let maximumSamples: UInt64
    private let engine: PhaseSensingEngine
    private let queue = DispatchQueue(label: "org.timelabs.RheaRFSpanner.dsp", qos: .userInitiated)
    private let started = Atomic<Bool>(false)

    init(
        configuration: RadarConfiguration = .standard,
        maximumSamples: UInt64? = nil,
        acquisitionKind: AcquisitionKind = .tone
    ) {
        self.configuration = configuration
        self.acquisitionKind = acquisitionKind
        let fullDuration = UInt64(configuration.sampleRateHz) * ExperimentControl.maximumDurationSeconds
        self.maximumSamples = min(maximumSamples ?? fullDuration, fullDuration)
        ring = SPSCFloatRingBuffer(capacity: configuration.ringBufferCapacity)
        engine = PhaseSensingEngine(
            ringBuffer: ring, configuration: configuration, acquisitionKind: acquisitionKind
        )
    }

    /// Called exactly once. A nil simulation uses the microphone's ring producer.
    /// A simulation creates only a deterministic sample generator on this queue;
    /// it never creates AVAudioEngine, accesses AVAudioSession, or requests permission.
    /// Every complete DSP frame is delivered. Display throttling must never affect
    /// recording, the simulation parameters, or the acquisition clock.
    func start(
        simulation: SimulationParameters? = nil,
        onFrame: @escaping @Sendable (PhaseTelemetryFrame, SpectrumFrame?) -> Void,
        onStopped: @escaping @Sendable (ExperimentStopReason) -> Void
    ) {
        precondition(acquisitionKind == .tone, "The tone callback requires a tone acquisition.")
        startAnalysis(simulation: simulation, onFrame: { frame in
            if let tone = frame.tone { onFrame(tone, frame.spectrum) }
        }, onStopped: onStopped)
    }

    /// Both branches consume the ring exactly once. Listen delivers broad input
    /// evidence with no requested tone estimate and never invents a phase frame.
    func startAnalysis(
        simulation: SimulationParameters? = nil,
        onFrame: @escaping @Sendable (AudioAnalysisFrame) -> Void,
        onStopped: @escaping @Sendable (ExperimentStopReason) -> Void
    ) {
        precondition(simulation == nil || acquisitionKind == .tone,
                     "DEMO retains the active-tone synthetic and Replay contract.")
        precondition(!started.exchange(true, ordering: .acquiringAndReleasing), "A processing session starts only once.")
        queue.async { [self] in
            if let simulation {
                runSimulation(parameters: simulation, onFrame: onFrame)
            } else {
                runCapture(onFrame: onFrame)
            }
            onStopped(control.stopReason)
        }
    }

    private func runCapture(onFrame: @Sendable (AudioAnalysisFrame) -> Void) {
        while !control.cancelled.load(ordering: .acquiring) {
            applyReferenceRequest()
            if let frame = engine.processNextAnalysisFrame() {
                recordDiagnosticFrame(frame)
                onFrame(frame)
            } else {
                // A dedicated consumer queue, never an audio callback.
                Thread.sleep(forTimeInterval: 0.003)
            }
        }
        if control.stopReason == .timeLimit {
            // Preserve complete frames already captured at the scheduled limit.
            // This is bounded by ring capacity and cannot restart acquisition.
            while let frame = engine.processNextAnalysisFrame() {
                recordDiagnosticFrame(frame)
                onFrame(frame)
            }
        }
    }

    private func runSimulation(
        parameters: SimulationParameters,
        onFrame: @Sendable (AudioAnalysisFrame) -> Void
    ) {
        let generator = SyntheticSignalGenerator(configuration: configuration, parameters: parameters)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: configuration.frameSize)
        buffer.initialize(repeating: 0, count: configuration.frameSize)
        defer {
            buffer.deinitialize(count: configuration.frameSize)
            buffer.deallocate()
        }
        let wallOrigin = ProcessInfo.processInfo.systemUptime
        var sampleTime: UInt64 = 0
        while sampleTime < maximumSamples, !control.cancelled.load(ordering: .acquiring) {
            let due = wallOrigin + Double(sampleTime) / configuration.sampleRate
            let remaining = due - ProcessInfo.processInfo.systemUptime
            if remaining > 0 {
                // Short sleeps keep stop/reference requests responsive. Sample
                // values depend only on the synthetic sample clock and seed.
                Thread.sleep(forTimeInterval: min(remaining, 0.01))
                continue
            }
            applyReferenceRequest()
            let count = min(configuration.frameSize, Int(maximumSamples - sampleTime))
            generator.generate(into: buffer, count: count, startSampleTime: sampleTime)
            guard !control.cancelled.load(ordering: .acquiring) else { break }
            _ = ring.write(from: buffer, count: count, startSampleTime: sampleTime)
            diagnostics.syntheticSamples.wrappingAdd(UInt64(count), ordering: .relaxed)
            diagnostics.syntheticBlocks.wrappingAdd(1, ordering: .releasing)
            sampleTime &+= UInt64(count)
            control.syntheticSamples.store(sampleTime, ordering: .releasing)
            while let frame = engine.processNextAnalysisFrame() {
                recordDiagnosticFrame(frame)
                onFrame(frame)
            }
        }
        if sampleTime >= maximumSamples { control.requestStop(.timeLimit) }
    }

    private func applyReferenceRequest() {
        if control.resetRequested.exchange(false, ordering: .acquiringAndReleasing) {
            if acquisitionKind == .tone { engine.resetCalibration() }
        }
    }

    private func recordDiagnosticFrame(_ frame: AudioAnalysisFrame) {
        diagnostics.recordProcessedAnalysisFrame(frame)
    }
}

/// The production graph branches use this immutable policy. A passive graph
/// requires input only; contextual output ports never grant or block capture.
struct AudioGraphPlan: Sendable {
    let acquisitionKind: AcquisitionKind

    var transmitEnabled: Bool { acquisitionKind.transmitEnabled }
    var category: AVAudioSession.Category { transmitEnabled ? .playAndRecord : .record }
    var mode: AVAudioSession.Mode { .measurement }
    var options: AVAudioSession.CategoryOptions { transmitEnabled ? [.defaultToSpeaker] : [] }

    func acceptsActiveRoute(
        inputPortTypes: [AVAudioSession.Port], outputPortTypes: [AVAudioSession.Port]
    ) -> Bool {
        guard !inputPortTypes.isEmpty,
              inputPortTypes.allSatisfy({ $0 == .builtInMic }) else { return false }
        return !transmitEnabled || (!outputPortTypes.isEmpty
            && outputPortTypes.allSatisfy({ $0 == .builtInSpeaker }))
    }
}

enum AudioStartError: LocalizedError {
    case physicalDeviceRequired
    case unsupportedRoute
    case unsupportedInputRoute
    case noBuiltInMicrophone
    case inputHardwareUnavailable
    case unsupportedInputFormat(inputRate: Double, hardwareRate: Double, sessionRate: Double)
    case unsupportedFormat(inputRate: Double, outputRate: Double)
    case noAudioFormat
    case startupInterrupted(ExperimentStopReason)

    var errorDescription: String? {
        switch self {
        case .physicalDeviceRequired:
            "Live microphone acquisition requires a physical iPhone or iPad with its built-in microphone."
        case .unsupportedRoute:
            "Use the built-in speaker and microphone. Disconnect headphones, USB audio, Bluetooth audio, and AirPlay before starting."
        case .unsupportedInputRoute:
            "Listening requires the built-in microphone. The activated input route is unsupported; open Diagnostics for the observed route."
        case .noBuiltInMicrophone:
            "A built-in microphone is not available."
        case .inputHardwareUnavailable:
            "The microphone input hardware is not enabled. Open Diagnostics for the observed input route."
        case let .unsupportedInputFormat(inputRate, hardwareRate, sessionRate):
            "Listening requires 48 kHz noninterleaved Float32 input. The current tap is \(inputRate) Hz, input hardware is \(hardwareRate) Hz, and audio session is \(sessionRate) Hz."
        case let .unsupportedFormat(inputRate, outputRate):
            "This experiment requires a 48 kHz audio route. The current input is \(inputRate) Hz and output is \(outputRate) Hz."
        case .noAudioFormat:
            "A supported Float32 audio format could not be created."
        case let .startupInterrupted(reason):
            reason.message
        }
    }
}

/// AVAudioEngine lifecycle is main-actor-only; callback contexts own realtime state.
@MainActor
final class AudioTransceiver {
    private let processing: SignalProcessingSession
    private let graph: AudioGraphPlan
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var tapInstalled = false
    private var sessionActivated = false
    private var notificationTokens: [NSObjectProtocol] = []
    private var diagnosticState: AudioSessionDiagnosticSnapshot

    init(processing: SignalProcessingSession) {
        self.processing = processing
        graph = AudioGraphPlan(acquisitionKind: processing.acquisitionKind)
        diagnosticState = AudioSessionDiagnosticSnapshot(
            configuration: processing.configuration, acquisitionKind: processing.acquisitionKind
        )
    }

    func diagnosticSnapshot() -> AudioSessionDiagnosticSnapshot {
        // Preserve the last active/error route after deactivation. Querying it
        // afterwards would replace the evidence with the restored idle route.
        if sessionActivated { captureAudioConfiguration(session: AVAudioSession.sharedInstance()) }
        diagnosticState.engineIsRunning = engine.isRunning
        return diagnosticState
    }

    func start() throws {
        #if targetEnvironment(simulator)
        diagnosticState.lastError = SessionDiagnosticError(stage: "validate_runtime", error: AudioStartError.physicalDeviceRequired)
        throw AudioStartError.physicalDeviceRequired
        #else
        let session = AVAudioSession.sharedInstance()
        let configuration = processing.configuration
        do {
            diagnosticState.stage = "validate_initial_route"
            captureAudioConfiguration(session: session)
            // Do not silently redirect an existing external audio route.
            if graph.transmitEnabled {
                guard session.currentRoute.outputs.allSatisfy({
                    $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
                }) else { throw AudioStartError.unsupportedRoute }
            }
            diagnosticState.stage = "configure_category"
            try session.setCategory(graph.category, mode: graph.mode, options: graph.options)
            diagnosticState.stage = "request_sample_rate"
            try session.setPreferredSampleRate(configuration.sampleRate)
            diagnosticState.stage = "request_io_duration"
            try session.setPreferredIOBufferDuration(Double(configuration.frameSize) / configuration.sampleRate)
            diagnosticState.stage = "activate_session"
            try session.setActive(true)
            sessionActivated = true
            diagnosticState.activationSucceeded = true

            diagnosticState.stage = "select_builtin_microphone"
            guard let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
                throw AudioStartError.noBuiltInMicrophone
            }
            try session.setPreferredInput(microphone)
            if graph.transmitEnabled {
                diagnosticState.stage = "select_builtin_speaker"
                try session.overrideOutputAudioPort(.speaker)
            }
            let input = engine.inputNode
            diagnosticState.stage = "validate_active_format"
            let (inputFormat, outputFormat) = try checkedFormats(session: session)

            let capture = CaptureContext(
                ring: processing.ring, control: processing.control,
                diagnostics: processing.diagnostics,
                configuration: configuration, maximumSamples: processing.maximumSamples
            )
            diagnosticState.stage = "install_input_tap"
            input.installTap(
                onBus: 0, bufferSize: AVAudioFrameCount(configuration.frameSize),
                format: inputFormat, block: Self.makeTapBlock(context: capture)
            )
            tapInstalled = true

            if graph.transmitEnabled {
                guard let mono = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: configuration.sampleRate,
                    channels: 1, interleaved: false
                ), let outputFormat else { throw AudioStartError.noAudioFormat }
                let tone = ToneRenderContext(
                    control: processing.control, diagnostics: processing.diagnostics, configuration: configuration,
                    maximumSamples: processing.maximumSamples
                )
                diagnosticState.stage = "connect_source"
                let source = Self.makeSourceNode(format: mono, context: tone)
                sourceNode = source
                engine.attach(source)
                let mixer = engine.mainMixerNode
                mixer.outputVolume = 1.0
                engine.connect(source, to: mixer, format: mono)
                engine.connect(mixer, to: engine.outputNode, format: outputFormat)
                // The microphone is not routed to the output mixer.
            }
            // Listen has only the recording tap. In particular it never creates
            // a tone context/oscillator/source node or accesses an output node.
            diagnosticState.stage = "prepare_engine"
            engine.prepare()
            // Arm observers before startup. Both callbacks remain silent/ignored
            // until the actual running route has passed the checks below.
            installStopObservers(session: session)
            diagnosticState.stage = "validate_prestart_format"
            _ = try checkedFormats(session: session)
            guard !processing.control.cancelled.load(ordering: .acquiring) else {
                throw AudioStartError.startupInterrupted(processing.control.stopReason)
            }
            diagnosticState.stage = "start_engine"
            try engine.start()
            diagnosticState.stage = "validate_running_format"
            _ = try checkedFormats(session: session)
            guard !processing.control.cancelled.load(ordering: .acquiring) else {
                throw AudioStartError.startupInterrupted(processing.control.stopReason)
            }
            processing.control.audioEnabled.store(true, ordering: .releasing)
            diagnosticState.stage = "running"
            diagnosticState.engineIsRunning = engine.isRunning
        } catch {
            diagnosticState.lastError = SessionDiagnosticError(stage: diagnosticState.stage, error: error)
            processing.control.requestStop(.startFailed)
            stop()
            throw error
        }
        #endif
    }

    private func checkedFormats(session: AVAudioSession) throws -> (AVAudioFormat, AVAudioFormat?) {
        captureAudioConfiguration(session: session)
        guard graph.acceptsActiveRoute(
            inputPortTypes: session.currentRoute.inputs.map(\.portType),
            outputPortTypes: session.currentRoute.outputs.map(\.portType)
        ) else {
            throw graph.transmitEnabled ? AudioStartError.unsupportedRoute : AudioStartError.unsupportedInputRoute
        }
        let input = engine.inputNode
        // Apple's enabled-input check uses the node's hardware-side input
        // format. The output format below is the format supplied to the tap.
        let hardwareFormat = input.inputFormat(forBus: 0)
        diagnosticState.inputHardwareSampleRateHz = finiteDiagnosticValue(hardwareFormat.sampleRate)
        diagnosticState.inputHardwareChannels = Int(hardwareFormat.channelCount)
        if !graph.transmitEnabled,
           !(hardwareFormat.sampleRate > 0 && hardwareFormat.channelCount > 0) {
            throw AudioStartError.inputHardwareUnavailable
        }
        let inputFormat = input.outputFormat(forBus: 0)
        diagnosticState.inputSampleRateHz = finiteDiagnosticValue(inputFormat.sampleRate)
        diagnosticState.inputChannels = Int(inputFormat.channelCount)
        let rate = processing.configuration.sampleRate
        guard abs(session.sampleRate - rate) < 0.01,
              graph.transmitEnabled || abs(hardwareFormat.sampleRate - rate) < 0.01,
              abs(inputFormat.sampleRate - rate) < 0.01,
              inputFormat.channelCount > 0,
              inputFormat.commonFormat == .pcmFormatFloat32,
              !inputFormat.isInterleaved
        else {
            if !graph.transmitEnabled {
                throw AudioStartError.unsupportedInputFormat(
                    inputRate: inputFormat.sampleRate, hardwareRate: hardwareFormat.sampleRate,
                    sessionRate: session.sampleRate
                )
            }
            let outputRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
            throw AudioStartError.unsupportedFormat(inputRate: inputFormat.sampleRate, outputRate: outputRate)
        }
        guard graph.transmitEnabled else { return (inputFormat, nil) }
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        diagnosticState.outputSampleRateHz = finiteDiagnosticValue(outputFormat.sampleRate)
        diagnosticState.outputChannels = Int(outputFormat.channelCount)
        guard abs(outputFormat.sampleRate - rate) < 0.01, outputFormat.channelCount > 0 else {
            throw AudioStartError.unsupportedFormat(inputRate: inputFormat.sampleRate, outputRate: outputFormat.sampleRate)
        }
        return (inputFormat, outputFormat)
    }

    private func captureAudioConfiguration(session: AVAudioSession) {
        diagnosticState.category = session.category.rawValue
        diagnosticState.mode = session.mode.rawValue
        diagnosticState.inputPortTypes = session.currentRoute.inputs.map { $0.portType.rawValue }.sorted()
        diagnosticState.outputPortTypes = session.currentRoute.outputs.map { $0.portType.rawValue }.sorted()
        diagnosticState.actualSampleRateHz = finiteDiagnosticValue(session.sampleRate)
        diagnosticState.actualIOBufferDurationSeconds = finiteDiagnosticValue(session.ioBufferDuration)
        diagnosticState.outputVolume = finiteDiagnosticValue(Double(session.outputVolume))
    }

    func stop() {
        if sessionActivated { captureAudioConfiguration(session: AVAudioSession.sharedInstance()) }
        processing.control.audioEnabled.store(false, ordering: .releasing)
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens.removeAll()
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if let source = sourceNode {
            engine.disconnectNodeOutput(source)
            engine.detach(source)
            sourceNode = nil
        }
        if sessionActivated {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
                diagnosticState.deactivationSucceeded = true
            } catch {
                diagnosticState.deactivationSucceeded = false
                diagnosticState.cleanupError = SessionDiagnosticError(stage: "deactivate_session", error: error)
            }
            sessionActivated = false
        }
        diagnosticState.stage = "stopped"
        diagnosticState.engineIsRunning = engine.isRunning
        // No ring reset: any in-flight callback/consumer retains its own context.
    }

    private func installStopObservers(session: AVAudioSession) {
        let events: [(Notification.Name, ExperimentStopReason)] = [
            (AVAudioSession.interruptionNotification, .interruption),
            (AVAudioSession.routeChangeNotification, .routeChanged),
            (AVAudioSession.mediaServicesWereLostNotification, .mediaServicesLost),
            (AVAudioSession.mediaServicesWereResetNotification, .mediaServicesReset)
        ]
        for (name, reason) in events {
            notificationTokens.append(NotificationCenter.default.addObserver(
                forName: name, object: session, queue: nil,
                using: Self.makeStopObserver(
                    control: processing.control, diagnostics: processing.diagnostics, reason: reason
                )
            ))
        }
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil,
            using: Self.makeStopObserver(
                control: processing.control, diagnostics: processing.diagnostics, reason: .engineConfigurationChanged
            )
        ))
    }

    // Explicitly nonisolated factories prevent Objective-C callback blocks from
    // inheriting MainActor isolation from the engine's main-actor lifecycle owner.
    nonisolated private static func makeSourceNode(format: AVAudioFormat, context: ToneRenderContext) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { isSilence, timestamp, frameCount, list in
            context.render(isSilence: isSilence, timestamp: timestamp, frameCount: frameCount, audioBufferList: list)
        }
    }

    nonisolated private static func makeTapBlock(context: CaptureContext) -> AVAudioNodeTapBlock {
        { buffer, time in context.receive(buffer, at: time) }
    }

    nonisolated private static func makeStopObserver(
        control: ExperimentControl, diagnostics: SessionDiagnosticCounters, reason: ExperimentStopReason
    ) -> @Sendable (Notification) -> Void {
        { notification in
            if reason == .routeChanged {
                diagnostics.routeChangeNotificationCount.wrappingAdd(1, ordering: .relaxed)
                if let code = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt {
                    diagnostics.lastRouteChangeReason.store(UInt64(code) &+ 1, ordering: .relaxed)
                }
            } else if reason == .interruption,
                      let code = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt {
                diagnostics.lastInterruptionType.store(UInt64(code) &+ 1, ordering: .relaxed)
            }
            // Do not tear down AVAudioEngine from its internal notification queue.
            // The worker observes this flag and asks the main actor to stop it.
            control.requestStop(reason)
        }
    }
}

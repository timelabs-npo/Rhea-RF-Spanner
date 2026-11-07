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

    var message: String {
        switch self {
        case .user: "Experiment stopped. The microphone and tone are off."
        case .inactive: "Experiment stopped when the app became inactive. Tap Start experiment to begin a new session."
        case .timeLimit: "The 60-second experiment has ended. The microphone and tone are off."
        case .interruption: "Audio was interrupted. The experiment has stopped."
        case .routeChanged: "The audio route changed. The experiment has stopped."
        case .mediaServicesLost: "The audio service became unavailable. The experiment has stopped."
        case .mediaServicesReset: "The audio service restarted. Start a new experiment when ready."
        case .engineConfigurationChanged: "The audio format changed. The experiment has stopped."
        case .renderTimelineChanged: "Playback sample timing became unavailable or discontinuous. The experiment has stopped."
        case .unsupportedBuffer: "An unsupported audio buffer was received. The experiment has stopped."
        case .startFailed: "The audio experiment could not start."
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
    private let oscillator: SineOscillator
    private let maximumSamples: UInt64
    private let rampSamples: UInt64
    private var rendered: UInt64 = 0
    private var nextRenderSampleTime: Double?

    init(control: ExperimentControl, configuration: RadarConfiguration) {
        self.control = control
        oscillator = SineOscillator(
            configuration: configuration, amplitude: ExperimentControl.transmitAmplitude
        )
        maximumSamples = UInt64(configuration.sampleRateHz) * ExperimentControl.maximumDurationSeconds
        rampSamples = UInt64(configuration.sampleRateHz / 100) // 10 ms at each end.
    }

    func render(
        isSilence: UnsafeMutablePointer<ObjCBool>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
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
private final class CaptureContext: @unchecked Sendable {
    private let ring: SPSCFloatRingBuffer
    private let control: ExperimentControl
    private let expectedSampleRate: Double
    private let maximumSamples: UInt64
    private var origin: UInt64?
    private var fallbackNextSample: UInt64 = 0
    private var capturedSamples: UInt64 = 0

    init(ring: SPSCFloatRingBuffer, control: ExperimentControl, configuration: RadarConfiguration) {
        self.ring = ring
        self.control = control
        expectedSampleRate = configuration.sampleRate
        maximumSamples = UInt64(configuration.sampleRateHz) * ExperimentControl.maximumDurationSeconds
    }

    func receive(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard !control.cancelled.load(ordering: .acquiring),
              control.audioEnabled.load(ordering: .acquiring) else { return }
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
        // Advance even when the ring drops this block. A loss cannot silently
        // become a contiguous capture timeline on a later successful write.
        fallbackNextSample = firstSample &+ UInt64(count)
        _ = ring.write(
            from: channels[0], count: count,
            startSampleTime: firstSample, timestampIsValid: timestampIsValid
        )
        capturedSamples += UInt64(count)
        if capturedSamples >= maximumSamples { control.requestStop(.timeLimit) }
    }
}

/// A new instance owns a new ring and DSP engine for every user-started session.
/// `engine` is only accessed from `queue`; cancellation never resets live memory.
final class SignalProcessingSession: @unchecked Sendable {
    let control = ExperimentControl()
    let ring: SPSCFloatRingBuffer
    let configuration: RadarConfiguration
    private let engine: PhaseSensingEngine
    private let queue = DispatchQueue(label: "org.timelabs.RheaRFSpanner.dsp", qos: .userInitiated)

    init(configuration: RadarConfiguration = .standard) {
        self.configuration = configuration
        ring = SPSCFloatRingBuffer(capacity: configuration.ringBufferCapacity)
        engine = PhaseSensingEngine(ringBuffer: ring, configuration: configuration)
    }

    /// Called exactly once by the main-actor owner after successful audio startup.
    func start(
        onFrame: @escaping @Sendable (PhaseTelemetryFrame) -> Void,
        onStopped: @escaping @Sendable (ExperimentStopReason) -> Void
    ) {
        queue.async { [self] in
            var publicationCounter: UInt64 = 0
            while !control.cancelled.load(ordering: .acquiring) {
                if control.resetRequested.exchange(false, ordering: .acquiringAndReleasing) {
                    engine.resetCalibration()
                }
                if let frame = engine.processNextFrame() {
                    publicationCounter &+= 1
                    if publicationCounter % 4 == 0 || frame.didRebaseline || !frame.isPhaseCoherent {
                        onFrame(frame)
                    }
                } else {
                    // This is a dedicated consumer queue, never an audio callback.
                    Thread.sleep(forTimeInterval: 0.003)
                }
            }
            onStopped(control.stopReason)
        }
    }
}

enum AudioStartError: LocalizedError {
    case physicalDeviceRequired
    case unsupportedRoute
    case noBuiltInMicrophone
    case unsupportedFormat(inputRate: Double, outputRate: Double)
    case noAudioFormat
    case startupInterrupted(ExperimentStopReason)

    var errorDescription: String? {
        switch self {
        case .physicalDeviceRequired:
            "Live acoustic experiments require a physical iPhone or iPad with its built-in speaker and microphone."
        case .unsupportedRoute:
            "Use the built-in speaker and microphone. Disconnect headphones, USB audio, Bluetooth audio, and AirPlay before starting."
        case .noBuiltInMicrophone:
            "A built-in microphone is not available."
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
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var tapInstalled = false
    private var sessionActivated = false
    private var notificationTokens: [NSObjectProtocol] = []

    init(processing: SignalProcessingSession) { self.processing = processing }

    func start() throws {
        #if targetEnvironment(simulator)
        throw AudioStartError.physicalDeviceRequired
        #else
        let session = AVAudioSession.sharedInstance()
        let configuration = processing.configuration
        do {
            // Do not silently redirect an existing external audio route.
            guard session.currentRoute.outputs.allSatisfy({
                $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
            }) else { throw AudioStartError.unsupportedRoute }
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setPreferredSampleRate(configuration.sampleRate)
            try session.setPreferredIOBufferDuration(Double(configuration.frameSize) / configuration.sampleRate)
            try session.setActive(true)
            sessionActivated = true

            guard let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
                throw AudioStartError.noBuiltInMicrophone
            }
            try session.setPreferredInput(microphone)
            try session.overrideOutputAudioPort(.speaker)
            let input = engine.inputNode
            let output = engine.outputNode
            let (inputFormat, outputFormat) = try checkedFormats(session: session)
            guard let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: configuration.sampleRate,
                channels: 1, interleaved: false
            ) else { throw AudioStartError.noAudioFormat }

            let capture = CaptureContext(ring: processing.ring, control: processing.control, configuration: configuration)
            input.installTap(
                onBus: 0, bufferSize: AVAudioFrameCount(configuration.frameSize),
                format: inputFormat, block: Self.makeTapBlock(context: capture)
            )
            tapInstalled = true

            let tone = ToneRenderContext(control: processing.control, configuration: configuration)
            let source = Self.makeSourceNode(format: mono, context: tone)
            sourceNode = source
            engine.attach(source)
            let mixer = engine.mainMixerNode
            mixer.outputVolume = 1.0
            engine.connect(source, to: mixer, format: mono)
            engine.connect(mixer, to: output, format: outputFormat)
            // The microphone is not routed to the output mixer.
            engine.prepare()
            // Arm observers before startup. Both callbacks remain silent/ignored
            // until the actual running route has passed the checks below.
            installStopObservers(session: session)
            _ = try checkedFormats(session: session)
            guard !processing.control.cancelled.load(ordering: .acquiring) else {
                throw AudioStartError.startupInterrupted(processing.control.stopReason)
            }
            try engine.start()
            _ = try checkedFormats(session: session)
            guard !processing.control.cancelled.load(ordering: .acquiring) else {
                throw AudioStartError.startupInterrupted(processing.control.stopReason)
            }
            processing.control.audioEnabled.store(true, ordering: .releasing)
        } catch {
            processing.control.requestStop(.startFailed)
            stop()
            throw error
        }
        #endif
    }

    private func checkedFormats(session: AVAudioSession) throws -> (AVAudioFormat, AVAudioFormat) {
        guard !session.currentRoute.inputs.isEmpty,
              !session.currentRoute.outputs.isEmpty,
              session.currentRoute.inputs.allSatisfy({ $0.portType == .builtInMic }),
              session.currentRoute.outputs.allSatisfy({ $0.portType == .builtInSpeaker })
        else { throw AudioStartError.unsupportedRoute }
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let rate = processing.configuration.sampleRate
        guard abs(session.sampleRate - rate) < 0.01,
              abs(inputFormat.sampleRate - rate) < 0.01,
              abs(outputFormat.sampleRate - rate) < 0.01,
              inputFormat.channelCount > 0,
              outputFormat.channelCount > 0,
              inputFormat.commonFormat == .pcmFormatFloat32,
              !inputFormat.isInterleaved
        else {
            throw AudioStartError.unsupportedFormat(inputRate: inputFormat.sampleRate, outputRate: outputFormat.sampleRate)
        }
        return (inputFormat, outputFormat)
    }

    func stop() {
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
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            sessionActivated = false
        }
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
                using: Self.makeStopObserver(control: processing.control, reason: reason)
            ))
        }
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil,
            using: Self.makeStopObserver(control: processing.control, reason: .engineConfigurationChanged)
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
        control: ExperimentControl, reason: ExperimentStopReason
    ) -> @Sendable (Notification) -> Void {
        { _ in
            // Do not tear down AVAudioEngine from its internal notification queue.
            // The worker observes this flag and asks the main actor to stop it.
            control.requestStop(reason)
        }
    }
}

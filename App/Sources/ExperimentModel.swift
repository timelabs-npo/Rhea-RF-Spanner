import AVFAudio
import Foundation
import RheaRFCore
import SwiftUI
import Synchronization
import UIKit

enum ExperimentMicrophonePermission { case granted, denied, undetermined, unavailable }

/// The model owns lifecycle decisions; the concrete adapter owns AVAudioEngine.
/// Tests can record those decisions without opening a microphone or speaker.
@MainActor
protocol ExperimentAudioSession: AnyObject {
    func start() throws
    func stop()
    func diagnosticSnapshot() -> AudioSessionDiagnosticSnapshot
}

extension AudioTransceiver: ExperimentAudioSession {}

@MainActor
struct ExperimentRuntime {
    let clock: @MainActor () -> TimeInterval
    let liveIsSupported: Bool
    let recordPermission: @MainActor () -> ExperimentMicrophonePermission
    let requestRecordPermission: @MainActor () async -> Bool
    let makeAudio: @MainActor (SignalProcessingSession) -> any ExperimentAudioSession

    /// Production always uses these defaults; launch arguments and UI cannot
    /// override dependencies.
    static var system: Self {
        #if targetEnvironment(simulator)
        let liveIsSupported = false
        #else
        let liveIsSupported = true
        #endif
        return Self(
            clock: { ProcessInfo.processInfo.systemUptime },
            liveIsSupported: liveIsSupported,
            recordPermission: {
                switch AVAudioApplication.shared.recordPermission {
                case .granted: .granted
                case .denied: .denied
                case .undetermined: .undetermined
                @unknown default: .unavailable
                }
            },
            requestRecordPermission: { await AVAudioApplication.requestRecordPermission() },
            makeAudio: { AudioTransceiver(processing: $0) }
        )
    }
}

@MainActor
final class ExperimentModel: ObservableObject {
    enum State: Equatable { case idle, requestingPermission, preparing, running }

    @Published private(set) var state: State = .idle
    @Published var consentGiven = false
    @Published private(set) var mode: ObservatoryMode = .live
    @Published private(set) var acquisitionKind: AcquisitionKind = .listen
    @Published var presentation: ObservatoryPresentation = .waterfall
    @Published var displayParameters = DisplayParameters()
    @Published private(set) var carrierFrequencyHz = 20_000
    @Published private(set) var latestFrame: PhaseTelemetryFrame?
    @Published private(set) var latestSlice: SpatioTemporalSlice?
    @Published private(set) var latestSpectrum: SpectrumFrame?
    @Published private(set) var latestAudioIdentity: AudioFrameIdentity?
    /// Oldest first. Rendering history is deliberately separate from the tape.
    @Published private(set) var spectrumHistory: [SpectrumFrame] = []
    @Published private(set) var replayCount = 0
    @Published private(set) var replayIndex = 0
    @Published private(set) var isReplaying = false
    @Published private(set) var isFinishingProcessing = false
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var message = "Microphone analysis · no generated tone. Tap Start listening."
    @Published private(set) var referenceMessage = "Tone analysis not requested."
    @Published private(set) var microphoneDenied = false
    @Published private(set) var diagnosticSnapshot: SessionDiagnosticSnapshot

    /// Acquisition parameters never contain display gain, palette, or persistence.
    let simulationParameters = SimulationParameters()
    let replayCapacity = 2_048
    let spectrumHistoryCapacity = 256

    private struct ActiveRun {
        let id: UInt64
        let source: ObservationSource
        let processing: SignalProcessingSession
        let audio: (any ExperimentAudioSession)?
        let samplesBeforeRun: UInt64
    }

    /// Kept until the DSP's ordered completion callback arrives, so complete
    /// frames already dispatched when Stop is tapped still reach the tape.
    private struct RecordingContext {
        let source: ObservationSource
        let acquisitionKind: AcquisitionKind
        let carrierFrequencyHz: Int
        var epoch: UInt32
        var hasReference = false
    }

    private struct PendingRetune {
        let previousRun: ActiveRun
        let recordingID: UInt64
    }

    private let tape = ReplayTape(capacity: 2_048)
    private var activeRun: ActiveRun?
    private var pendingRetune: PendingRetune?
    private var recordingContexts: [UInt64: RecordingContext] = [:]
    private var nextRunID: UInt64 = 0
    private var nextEpoch: UInt32 = 0
    private var recordingID: UInt64 = 0
    private var appIsActive = false
    private var pendingLaunchDemo = false
    private var permissionTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var replayTask: Task<Void, Never>?
    private let runtime: ExperimentRuntime
    private var acquisitionStartedAt: TimeInterval?
    private let diagnosticIdentity: AppDiagnosticIdentity
    private let diagnosticLogStartedAt: TimeInterval
    private var diagnosticLog = SessionDiagnosticLog()
    private var diagnosticSequence: UInt64 = 0
    private var diagnosticProcessing: SignalProcessingSession?
    private var diagnosticAudio: (any ExperimentAudioSession)?
    private var diagnosticSource: ObservationSource?
    private var diagnosticRunID: UInt64?
    private var diagnosticReferenceEpoch: UInt32?
    private var diagnosticRunStartedAt: TimeInterval?
    private var diagnosticMonitoringStartedAt: TimeInterval?
    private var diagnosticRunEndedAt: TimeInterval?
    private var diagnosticStopReason: ExperimentStopReason?
    private var firstObservedInputAt: TimeInterval?
    private var lastObservedInputAt: TimeInterval?
    private var lastObservedProcessingAt: TimeInterval?
    private var lastObservedInputCount: UInt64 = 0
    private var lastObservedProcessingCount: UInt64 = 0
    private var diagnosticWindowStartedAt: TimeInterval?
    private var diagnosticWindowInputCount: UInt64 = 0
    private var diagnosticWindowProcessedCount: UInt64 = 0
    private var lastWindowElapsedSeconds: Double?
    private var lastWindowInputCallbacks: UInt64 = 0
    private var lastWindowProcessedFrames: UInt64 = 0
    private var recordedFirstInput = false
    private var recordedFirstProcessedFrame = false

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        runtime: ExperimentRuntime? = nil
    ) {
        let runtime = runtime ?? .system
        self.runtime = runtime
        diagnosticLogStartedAt = runtime.clock()
        let identity = AppDiagnosticIdentity.current()
        diagnosticIdentity = identity
        diagnosticSnapshot = SessionDiagnosticSnapshot(
            schemaVersion: 1, snapshotSequence: 0, app: identity,
            session: SessionDiagnosticState(
                state: "idle", mode: "live", captureSource: nil, appIsActive: false, runID: nil,
                referenceEpoch: nil, carrierHz: nil, elapsedSeconds: 0, stopReason: nil, acquisitionKind: "listen", transmitEnabled: false
            ),
            audio: nil, pipeline: PipelineDiagnosticSnapshot(), events: [], droppedEventCount: 0
        )
        // Visual capture may launch a silent DEMO. No launch argument can start
        // LIVE or bypass consent, the permission flow, or the Record action.
        if arguments.contains("--observatory-demo") {
            mode = .demo
            presentation = .field
            pendingLaunchDemo = true
            message = "Silent deterministic DEMO. No microphone or speaker is used."
        } else if !liveIsSupported {
            message = "LIVE requires a physical device. Choose DEMO for a silent simulation."
        }
        if arguments.contains("--observatory-waterfall") { presentation = .waterfall }
        recordDiagnosticEvent(category: "session", code: "initialized", message: "Session diagnostics initialized. No sensors have been started.")
        refreshDiagnostics()
    }

    var liveIsSupported: Bool { runtime.liveIsSupported }

    var isRunning: Bool { state == .running }
    var isVisualizing: Bool { isRunning || isReplaying }
    var microphoneIsActive: Bool { isRunning && activeRun?.source == .microphone }
    var isListening: Bool { mode == .live && acquisitionKind == .listen }
    var phaseControlsAvailable: Bool { !isListening }
    var canStart: Bool {
        guard state == .idle, appIsActive, !isFinishingProcessing else { return false }
        switch mode {
        case .live: return (isListening || consentGiven) && liveIsSupported
        case .demo: return true
        case .replay: return replayCount > 0 && !isReplaying
        }
    }
    var timeRemainingSeconds: Int { max(0, 60 - Int(elapsedSeconds)) }
    var canClearReplay: Bool {
        replayCount > 0 && state == .idle && !isFinishingProcessing && !isReplaying
    }
    var displayedCarrierFrequencyHz: Int {
        if mode == .replay, let latestSlice { return Int(latestSlice.carrierFrequencyHz.rounded()) }
        return carrierFrequencyHz
    }
    var phaseDerivedDisplacementMillimeters: Double? {
        guard let slice = latestSlice, slice.isPhaseCoherent,
              let phase = slice.unwrappedPhase, phase.isFinite,
              slice.carrierFrequencyHz.isFinite, slice.carrierFrequencyHz > 0 else { return nil }
        return -Double(phase) * 343.0 / (4.0 * .pi * Double(slice.carrierFrequencyHz)) * 1_000
    }
    var replaySourceName: String {
        switch latestSlice?.source {
        case .microphone: return "LIVE capture"
        case .simulated: return "DEMO capture"
        case nil: return "No capture"
        }
    }

    var measuredAcquisitionText: String {
        let pipeline = diagnosticSnapshot.pipeline
        guard isRunning else { return "Capture stopped" }
        let rate = pipeline.processedFramesPerSecond.map { String(format: "%.1f DSP/s", $0) } ?? "DSP rate pending"
        if diagnosticSource == .simulated { return "SIM · \(rate)" }
        let sampleRate = diagnosticSnapshot.audio?.inputSampleRateHz
            .map { String(format: "%.1f kHz", $0 / 1_000) } ?? "Rate unavailable"
        return "\(sampleRate) · \(rate)"
    }

    var inputStatusText: String {
        let pipeline = diagnosticSnapshot.pipeline
        guard let diagnosticSource else { return "Acquisition has not started" }
        if diagnosticSource == .simulated {
            return pipeline.syntheticBlocks > 0 ? "Synthetic samples received" : "Waiting for synthetic samples"
        }
        if diagnosticStopReason == .inputStalled { return "Stopped: no microphone buffers" }
        if diagnosticStopReason == .processingStalled { return "Stopped: DSP stopped producing frames" }
        if pipeline.acceptedInputCallbacks == 0 {
            return isRunning ? "Waiting for microphone buffers" : "No microphone samples received"
        }
        if let input = pipeline.latestInput {
            if input.nonFiniteSampleCount > 0 { return "Input contains non-finite samples" }
            if input.sampleCount > 0, input.zeroSampleCount == input.sampleCount { return "Microphone buffers are silent" }
        }
        if pipeline.sampleTimestampValid == false { return "Samples received · timing unavailable" }
        return "Microphone samples received"
    }

    var inputLevelText: String {
        guard let input = diagnosticSnapshot.pipeline.latestInput else { return "Input level pending" }
        if input.nonFiniteSampleCount > 0 { return "Input level unavailable · nonfinite samples" }
        guard let rms = input.rms, let peak = input.peak else { return "Input level unavailable" }
        if rms == 0 { return "RMS silence · peak 0 FS" }
        let dbfs = 20 * log10(rms)
        guard dbfs.isFinite else { return "Input level unavailable" }
        return String(format: "RMS %.1f dBFS · peak %.4f FS", dbfs, peak)
    }

    /// Selection is intent for the next explicit Start. It never starts audio.
    func selectAcquisitionKind(_ selection: AcquisitionKind) {
        guard selection != acquisitionKind else { return }
        stopExperiment()
        acquisitionKind = selection
        consentGiven = false
        clearDisplayedFrames()
        elapsedSeconds = 0
        if selection == .listen {
            presentation = .waterfall
            displayParameters.spectrumBand = .fullBand
        }
        message = selection == .listen
            ? "Microphone analysis · no generated tone. Tap Start listening."
            : "Tone experiment uses the microphone and speaker. Agree below, then tap Record."
        recordDiagnosticEvent(category: "session", code: "acquisition_selected", message: "Selected \(selection.rawValue); a new Start action is required.")
        refreshDiagnostics()
    }

    func setAppActive(_ active: Bool) {
        let changed = appIsActive != active
        appIsActive = active
        if changed {
            recordDiagnosticEvent(
                category: "lifecycle", code: active ? "became_active" : "became_inactive",
                message: active ? "The app became active." : "The app became inactive."
            )
        }
        if !active {
            if activeRun != nil || pendingRetune != nil || isReplaying { stopExperiment(reason: .inactive) }
            // A permission dialog can make the scene inactive. Its response only
            // returns to idle; it never starts or resumes an acoustic experiment.
        } else if pendingLaunchDemo {
            pendingLaunchDemo = false
            guard mode == .demo, state == .idle else { return }
            beginAcquisition(source: .simulated)
        }
        refreshDiagnostics()
    }

    func selectMode(_ selection: ObservatoryMode) {
        guard selection != mode else { return }
        pendingLaunchDemo = false
        stopExperiment()
        mode = selection
        recordDiagnosticEvent(category: "session", code: "mode_selected", message: "Selected \(selection.rawValue) mode.")
        microphoneDenied = false
        if selection == .replay {
            if tape.count > 0 {
                displayReplayFrame(at: tape.count - 1)
                message = "Replay contains Tone experiment and DEMO captures only. Listen is not saved to Replay; microphone and speaker are off."
            } else {
                clearDisplayedFrames()
                message = "Record Tone experiment or DEMO frames for Replay. Listen history is display-only."
            }
        } else {
            clearDisplayedFrames()
            elapsedSeconds = 0
            if isListening { presentation = .waterfall }
            message = selection == .demo
                ? "Silent deterministic DEMO. Tap Record to generate synthetic samples."
                : liveIsSupported
                    ? (isListening ? "Microphone analysis · no generated tone. Tap Start listening." : "Tone experiment uses the microphone and speaker. Agree below, then tap Record.")
                    : "LIVE requires a physical device. DEMO is available in the simulator."
        }
        refreshDiagnostics()
    }

    func startExperiment() {
        guard canStart else { return }
        switch mode {
        case .demo:
            beginAcquisition(source: .simulated)
        case .replay:
            playReplay()
        case .live:
            // This guard precedes even reading microphone permission on Simulator.
            guard liveIsSupported else {
                message = AudioStartError.physicalDeviceRequired.localizedDescription
                return
            }
            switch runtime.recordPermission() {
            case .granted:
                microphoneDenied = false
                beginAcquisition(source: .microphone)
            case .denied:
                microphoneDenied = true
                message = "Microphone permission is denied. You can change it in iOS Settings."
                recordDiagnosticEvent(category: "permission", code: "microphone_denied", message: "Microphone permission is denied.")
                refreshDiagnostics()
            case .undetermined:
                state = .requestingPermission
                message = "Waiting for microphone permission. LIVE has not started."
                recordDiagnosticEvent(category: "permission", code: "microphone_requested", message: "Requested microphone permission; acquisition has not started.")
                refreshDiagnostics()
                permissionTask = Task { [weak self] in
                    guard let permissionProvider = self?.runtime.requestRecordPermission else { return }
                    let granted = await permissionProvider()
                    guard !Task.isCancelled, let self else { return }
                    state = .idle
                    microphoneDenied = !granted
                    message = granted
                        ? (isListening ? "Microphone permission granted. Tap Start listening when ready." : "Microphone permission granted. Tap Record when you are ready for the tone.")
                        : "Microphone permission was not granted. The microphone and speaker remain off."
                    permissionTask = nil
                    recordDiagnosticEvent(
                        category: "permission", code: granted ? "microphone_granted" : "microphone_denied",
                        message: granted ? "Microphone permission granted; a new Record action is required." : "Microphone permission was not granted."
                    )
                    refreshDiagnostics()
                }
            case .unavailable:
                message = "Microphone permission is unavailable on this system."
                recordDiagnosticEvent(category: "permission", code: "microphone_unknown", message: "Microphone permission state is unknown.")
                refreshDiagnostics()
            }
        }
    }

    private func beginAcquisition(source: ObservationSource) {
        guard appIsActive, activeRun == nil, recordingContexts.isEmpty,
              source == .simulated || ((isListening || consentGiven) && liveIsSupported) else { return }
        pauseReplay()
        recordingID &+= 1
        elapsedSeconds = 0
        clearDisplayedFrames()
        acquisitionStartedAt = runtime.clock()
        beginRun(source: source, samplesBeforeRun: 0)
        if isRunning { startDurationTask(recording: recordingID) }
    }

    private func beginRun(source: ObservationSource, samplesBeforeRun: UInt64) {
        let configuration = RadarConfiguration(carrierFrequencyHz: carrierFrequencyHz)
        let maximum = UInt64(configuration.sampleRateHz) * ExperimentControl.maximumDurationSeconds
        guard appIsActive, activeRun == nil, samplesBeforeRun < maximum else {
            stopExperiment(reason: .timeLimit)
            return
        }
        state = .preparing
        latestFrame = nil
        latestSlice = nil
        latestSpectrum = nil
        latestAudioIdentity = nil
        spectrumHistory.removeAll(keepingCapacity: true)
        referenceMessage = isListening ? "Tone analysis not requested." : "New acquisition epoch. Waiting for a valid tone estimate."
        message = source == .simulated ? "Preparing synthetic samples." : "Preparing the built-in audio route."
        nextRunID &+= 1
        let runID = nextRunID
        let processing = SignalProcessingSession(
            configuration: configuration, maximumSamples: maximum - samplesBeforeRun,
            acquisitionKind: source == .simulated ? .tone : acquisitionKind
        )
        // DEMO never constructs the audio transceiver or its AVAudioEngine.
        let audio = source == .microphone ? runtime.makeAudio(processing) : nil
        recordingContexts[runID] = RecordingContext(
            source: source, acquisitionKind: processing.acquisitionKind,
            carrierFrequencyHz: carrierFrequencyHz, epoch: processing.acquisitionKind == .tone ? allocateEpoch() : 0
        )
        activeRun = ActiveRun(
            id: runID, source: source, processing: processing,
            audio: audio, samplesBeforeRun: samplesBeforeRun
        )
        prepareDiagnosticRun(processing: processing, audio: audio, source: source, runID: runID)
        do {
            try audio?.start()
            guard !processing.control.cancelled.load(ordering: .acquiring) else {
                let reason = processing.control.stopReason
                recordingContexts.removeValue(forKey: runID)
                stopExperiment(reason: reason)
                return
            }
            state = .running
            let readyAt = runtime.clock()
            diagnosticMonitoringStartedAt = readyAt
            diagnosticWindowStartedAt = readyAt
            // Audio startup can already have delivered ignored tap callbacks.
            // Keep them in lifetime evidence, but exclude them from the new
            // observation interval's callback rate.
            diagnosticWindowInputCount = processing.diagnostics.inputCallbacks.load(ordering: .acquiring)
            diagnosticWindowProcessedCount = processing.diagnostics.processedFrames.load(ordering: .acquiring)
            message = source == .simulated
                ? "Recording synthetic DEMO frames. The microphone and speaker are off."
                : "LIVE started. Waiting for microphone samples. Open Diagnostics to inspect the pipeline."
            recordDiagnosticEvent(
                category: "session", code: "run_started",
                message: source == .simulated ? "Synthetic sample generation started." : "Audio engine started; waiting for input and DSP evidence."
            )
            processing.startAnalysis(
                simulation: source == .simulated ? simulationParameters : nil,
                onFrame: { [weak self] frame in
                    // DispatchQueue's FIFO preserves frame order and keeps the
                    // completion callback behind all frames from this worker.
                    DispatchQueue.main.async { [weak self] in
                        self?.receive(frame, for: runID)
                    }
                },
                onStopped: { [weak self] reason in
                    DispatchQueue.main.async { [weak self] in
                        self?.processingFinished(for: runID, reason: reason)
                    }
                }
            )
            refreshDiagnostics()
        } catch {
            processing.control.requestStop(.startFailed)
            audio?.stop()
            activeRun = nil
            recordingContexts.removeValue(forKey: runID)
            durationTask?.cancel()
            durationTask = nil
            acquisitionStartedAt = nil
            state = .idle
            diagnosticStopReason = processing.control.stopReason
            diagnosticRunEndedAt = runtime.clock()
            recordDiagnosticEvent(
                category: "error", code: "start_failed",
                message: "Acquisition could not start. The audio snapshot contains the failed stage and error identifiers."
            )
            message = error.localizedDescription + " Open Diagnostics for the startup report."
            refreshDiagnostics()
        }
    }

    /// Retuning ends the old producer before constructing an immutable new DSP
    /// configuration. Pending old frames retain their original carrier/epoch.
    /// The original 60-second sample budget and wall deadline survive retuning.
    func setCarrierFrequency(_ frequency: Int) {
        guard CarrierGrid.isSupported(frequency), frequency != carrierFrequencyHz,
              mode != .replay, !isListening else { return }
        let previousRun = activeRun
        let wasRunning = isRunning
        if let previousRun, wasRunning {
            // Completion is queued behind every old frame. The replacement
            // producer starts only after that callback, so tape epochs cannot
            // interleave even if a DSP frame was still computing at Stop.
            pendingRetune = PendingRetune(previousRun: previousRun, recordingID: recordingID)
            endActiveRun(reason: .retuned)
            state = .preparing
        }
        carrierFrequencyHz = frequency
        recordDiagnosticEvent(category: "acquisition", code: "carrier_selected", message: "Carrier set to \(frequency) Hz; a new reference is required.")
        clearDisplayedFrames()
        referenceMessage = "Carrier changed. The next valid frame establishes a new phase reference."
        if pendingRetune != nil {
            message = "Changing to \(carrierText). Finishing the previous acquisition epoch."
        } else {
            message = "Carrier set to \(carrierText). The next recording starts a new phase reference."
        }
        refreshDiagnostics()
    }

    func stepCarrier(by steps: Int) {
        guard let index = CarrierGrid.frequencies.firstIndex(of: carrierFrequencyHz) else { return }
        let next = min(CarrierGrid.frequencies.count - 1, max(0, index + steps))
        setCarrierFrequency(CarrierGrid.frequencies[next])
    }

    private var carrierText: String {
        (Double(carrierFrequencyHz) / 1_000).formatted(.number.precision(.fractionLength(1))) + " kHz"
    }

    private func allocateEpoch() -> UInt32 {
        nextEpoch &+= 1
        if nextEpoch == 0 { nextEpoch = 1 }
        return nextEpoch
    }

    private func receive(_ analysis: AudioAnalysisFrame, for runID: UInt64) {
        guard var context = recordingContexts[runID],
              context.acquisitionKind == analysis.acquisitionKind else { return }
        let matchingSpectrum = analysis.spectrum?.sampleTimestamp == analysis.sampleTimestamp
            ? analysis.spectrum : nil
        var slice: SpatioTemporalSlice?
        if context.acquisitionKind == .tone, let frame = analysis.tone {
            if frame.didRebaseline {
                if context.hasReference { context.epoch = allocateEpoch() }
                context.hasReference = true
            }
            recordingContexts[runID] = context
            if diagnosticRunID == runID { diagnosticReferenceEpoch = context.epoch }
            let toneSlice = SpatioTemporalSlice(
                frame: frame, source: context.source,
                carrierFrequencyHz: context.carrierFrequencyHz, epoch: context.epoch
            )
            slice = toneSlice
            // The 64-byte v1 tape is exclusively active/DEMO telemetry.
            tape.append(toneSlice, spectrum: matchingSpectrum)
            replayCount = tape.count
            if mode != .replay { replayIndex = max(0, tape.count - 1) }
        }

        guard let run = activeRun, run.id == runID, isRunning else { return }
        // A restarted/repeated capture clock must not make spectra from the
        // previous timeline available at the same numeric sample indices. This
        // also applies when the new observation has no usable spectrum.
        let previousTimestamp: UInt64?
        if context.acquisitionKind == .listen {
            previousTimestamp = latestAudioIdentity?.runID == runID
                ? latestAudioIdentity?.sampleTimestamp : nil
        } else {
            // beginRun clears the last slice before this run receives frames.
            previousTimestamp = latestSlice?.sampleTimestamp
        }
        if let previousTimestamp, analysis.sampleTimestamp <= previousTimestamp {
            if !spectrumHistory.isEmpty {
                recordDiagnosticEvent(
                    category: "pipeline", code: "capture_clock_restarted",
                    message: "Capture sample indices stopped increasing. The previous Waterfall history was cleared."
                )
            }
            spectrumHistory.removeAll(keepingCapacity: true)
        }
        latestFrame = analysis.tone
        latestSlice = slice
        latestAudioIdentity = context.acquisitionKind == .listen ? AudioFrameIdentity(
            sampleTimestamp: analysis.sampleTimestamp, runID: runID,
            source: context.source, acquisitionKind: context.acquisitionKind
        ) : nil
        latestSpectrum = matchingSpectrum
        if let matchingSpectrum {
            spectrumHistory.append(matchingSpectrum)
            if spectrumHistory.count > spectrumHistoryCapacity {
                spectrumHistory.removeFirst(spectrumHistory.count - spectrumHistoryCapacity)
            }
        }
        updateElapsed(for: run)
        if context.acquisitionKind == .listen {
            referenceMessage = "Tone analysis not requested. Listen is not saved to Replay."
        } else if let frame = analysis.tone {
            if frame.didRebaseline {
                referenceMessage = "Reference epoch \(context.epoch). A valid frame has established a new zero."
            } else if !frame.isPhaseCoherent {
                referenceMessage = "Phase is unavailable. Recovery will establish a new reference."
            }
        }
    }

    private func processingFinished(for runID: UInt64, reason: ExperimentStopReason) {
        recordingContexts.removeValue(forKey: runID)
        isFinishingProcessing = activeRun == nil && !recordingContexts.isEmpty
        if let pending = pendingRetune, pending.previousRun.id == runID {
            pendingRetune = nil
            guard reason == .retuned, appIsActive, state == .preparing,
                  pending.recordingID == recordingID else {
                stopExperiment(reason: reason)
                return
            }
            let previous = pending.previousRun
            let consumed = previous.samplesBeforeRun
                + (previous.source == .simulated
                    ? previous.processing.control.syntheticSamples.load(ordering: .acquiring)
                    : previous.processing.control.renderedSamples.load(ordering: .acquiring))
            beginRun(source: previous.source, samplesBeforeRun: consumed)
        } else if activeRun?.id == runID {
            stopExperiment(reason: reason)
        }
        if recordingContexts.isEmpty, mode == .replay, !isReplaying, tape.count > 0 {
            // A bounded tape may have overwritten its oldest slot while the
            // retiring worker delivered final frames. Re-anchor only once the
            // worker is finished, then permit scrubbing stable logical indices.
            displayReplayFrame(at: tape.count - 1)
        }
        refreshDiagnostics()
    }

    private func acquiredSamples(for run: ActiveRun) -> UInt64 {
        if run.source == .simulated {
            return run.processing.control.syntheticSamples.load(ordering: .acquiring)
        }
        if run.processing.acquisitionKind == .listen {
            return run.processing.control.capturedSamples.load(ordering: .acquiring)
        }
        return run.processing.control.renderedSamples.load(ordering: .acquiring)
    }

    private func updateElapsed(for run: ActiveRun) {
        let current = acquiredSamples(for: run)
        elapsedSeconds = min(60, Double(run.samplesBeforeRun + current) / run.processing.configuration.sampleRate)
    }

    private func startDurationTask(recording: UInt64) {
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            // Independent of the realtime sample cap. This also ends a stalled
            // engine and is never restarted by a carrier change.
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
                guard let self, recordingID == recording,
                      activeRun != nil || pendingRetune != nil else { return }
                if !monitorAcquisition() { return }
            }
        }
    }

    /// One production watchdog/deadline tick. The task invokes this at 4 Hz;
    /// deterministic tests invoke the same lifecycle path with a supplied clock.
    /// Diagnostic inspection/copy continues to call refreshDiagnostics only.
    @discardableResult
    func monitorAcquisition() -> Bool {
        guard let run = activeRun ?? pendingRetune?.previousRun else { return false }
        updateElapsed(for: run)
        refreshDiagnostics()
        if stopStalledLivePipelineIfNeeded() { return false }
        if let startedAt = acquisitionStartedAt, runtime.clock() - startedAt >= 60 {
            stopExperiment(reason: .timeLimit)
            return false
        }
        return true
    }

    func resetPhaseReference() {
        guard let run = activeRun, isRunning, run.processing.acquisitionKind == .tone else { return }
        run.processing.control.resetRequested.store(true, ordering: .releasing)
        recordDiagnosticEvent(category: "acquisition", code: "reference_reset_requested", message: "The user requested a new phase reference.")
        referenceMessage = "Reference reset requested. Waiting for the next valid tone estimate."
    }

    @discardableResult
    private func endActiveRun(reason: ExperimentStopReason) -> UInt64 {
        guard let run = activeRun else { return 0 }
        activeRun = nil
        isFinishingProcessing = recordingContexts[run.id] != nil
        run.processing.control.requestStop(reason)
        run.audio?.stop()
        diagnosticStopReason = run.processing.control.stopReason
        diagnosticRunEndedAt = runtime.clock()
        recordDiagnosticEvent(
            category: "session", code: diagnosticStopReason?.diagnosticCode ?? reason.diagnosticCode,
            message: "Acquisition stopped. Microphone and tone have been disabled."
        )
        updateElapsed(for: run)
        return run.samplesBeforeRun + acquiredSamples(for: run)
    }

    func stopExperiment(reason: ExperimentStopReason = .user) {
        permissionTask?.cancel()
        permissionTask = nil
        durationTask?.cancel()
        durationTask = nil
        acquisitionStartedAt = nil
        let source = activeRun?.source ?? pendingRetune?.previousRun.source
        pendingRetune = nil
        endActiveRun(reason: reason)
        pauseReplay()
        state = .idle
        if mode == .replay {
            message = reason == .inactive ? "Replay paused when the app became inactive." : "Replay paused. The microphone and speaker are off."
        } else if source == .simulated {
            switch reason {
            case .timeLimit: message = "The 60-second DEMO ended. Synthetic frames are available in Replay."
            case .inactive: message = "DEMO stopped when the app became inactive. Tap Record to begin a new run."
            default: message = "DEMO stopped. Synthetic frames remain in memory; the microphone and speaker stayed off."
            }
        } else if isListening {
            switch reason {
            case .user: message = "Listening stopped. Microphone off. Passive history is stopped data; Replay contains Tone/DEMO only."
            case .inactive: message = "Listening stopped when the app became inactive. Tap Start listening for a new run."
            case .timeLimit: message = "The 60-second Listen run ended. Microphone off; stopped Waterfall retained."
            case .mediaServicesReset: message = "The audio service restarted. Listening stopped. Open Diagnostics, then tap Start listening when ready."
            default: message = reason.message + " Listening requires a new Start action."
            }
        } else {
            message = reason.message
        }
        // Keep the last measured/simulated frame visible, frozen and labelled.
        referenceMessage = isListening ? "Tone analysis not requested." : "A new recording will establish a new phase reference."
        refreshDiagnostics()
    }

    func selectReplayFrame(_ index: Int) {
        guard mode == .replay, !isFinishingProcessing else { return }
        pauseReplay()
        displayReplayFrame(at: index)
    }

    func toggleReplay() {
        guard mode == .replay else { return }
        if isReplaying { pauseReplay() } else { playReplay() }
    }

    private func playReplay() {
        guard mode == .replay, state == .idle, appIsActive, tape.count > 0,
              activeRun == nil, !isReplaying, !isFinishingProcessing else { return }
        if replayIndex >= tape.count - 1 { displayReplayFrame(at: 0) }
        isReplaying = true
        message = "Playing stored \(replaySourceName) frames. The microphone and speaker are off."
        replayTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, isReplaying, mode == .replay, appIsActive else { return }
                guard replayIndex + 1 < tape.count else {
                    isReplaying = false
                    replayTask = nil
                    message = "End of replay. The original capture source is retained on every frame."
                    return
                }
                let delay = replayDelay(after: replayIndex)
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled, isReplaying, mode == .replay else { return }
                displayReplayFrame(at: replayIndex + 1)
            }
        }
    }

    private func pauseReplay() {
        replayTask?.cancel()
        replayTask = nil
        isReplaying = false
    }

    private func replayDelay(after index: Int) -> Double {
        let regularHop = 2_048.0 / 48_000.0
        guard let current = tape.slice(at: index), let next = tape.slice(at: index + 1),
              current.epoch == next.epoch, current.source == next.source,
              next.sampleTimestamp > current.sampleTimestamp else { return regularHop }
        let delay = Double(next.sampleTimestamp - current.sampleTimestamp) / 48_000
        // Keep invalid hardware-timestamp jumps from scheduling an unbounded
        // wait. The recorded discontinuity and its invalid phase remain visible.
        return min(2, max(regularHop, delay))
    }

    private func displayReplayFrame(at requestedIndex: Int) {
        guard tape.count > 0 else { return }
        let index = min(max(0, requestedIndex), tape.count - 1)
        guard let slice = tape.slice(at: index) else { return }
        replayIndex = index
        latestAudioIdentity = nil
        latestFrame = nil // The wire record does not invent unavailable telemetry.
        latestSlice = slice
        latestSpectrum = tape.spectrum(at: index)
        elapsedSeconds = Double(slice.sampleTimestamp) / 48_000
        var history: [SpectrumFrame] = []
        let lower = max(0, index - spectrumHistoryCapacity + 1)
        for position in lower...index {
            guard let previous = tape.slice(at: position),
                  previous.epoch == slice.epoch, previous.source == slice.source,
                  previous.carrierFrequencyHz == slice.carrierFrequencyHz,
                  let spectrum = tape.spectrum(at: position) else { continue }
            history.append(spectrum)
        }
        spectrumHistory = history
        referenceMessage = "Stored reference epoch \(slice.epoch) · \(replaySourceName). No phase reference is changed during replay."
    }

    private func clearDisplayedFrames() {
        latestAudioIdentity = nil
        latestFrame = nil
        latestSlice = nil
        latestSpectrum = nil
        spectrumHistory.removeAll(keepingCapacity: true)
    }

    func clearReplay() {
        guard canClearReplay else { return }
        tape.removeAll()
        replayCount = 0
        replayIndex = 0
        clearDisplayedFrames()
        elapsedSeconds = 0
        message = "Replay cleared. Record LIVE or DEMO frames to create a new tape."
        referenceMessage = "The next valid tone estimate will establish a new reference."
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func prepareDiagnosticRun(
        processing: SignalProcessingSession, audio: (any ExperimentAudioSession)?,
        source: ObservationSource, runID: UInt64
    ) {
        diagnosticProcessing = processing
        diagnosticAudio = audio
        diagnosticSource = source
        diagnosticRunID = runID
        diagnosticReferenceEpoch = processing.acquisitionKind == .tone ? recordingContexts[runID]?.epoch : nil
        diagnosticRunStartedAt = runtime.clock()
        diagnosticMonitoringStartedAt = nil
        diagnosticRunEndedAt = nil
        diagnosticStopReason = nil
        firstObservedInputAt = nil
        lastObservedInputAt = nil
        lastObservedProcessingAt = nil
        lastObservedInputCount = 0
        lastObservedProcessingCount = 0
        diagnosticWindowStartedAt = nil
        diagnosticWindowInputCount = 0
        diagnosticWindowProcessedCount = 0
        lastWindowElapsedSeconds = nil
        lastWindowInputCallbacks = 0
        lastWindowProcessedFrames = 0
        recordedFirstInput = false
        recordedFirstProcessedFrame = false
        recordDiagnosticEvent(category: "session", code: "run_preparing", message: "Preparing acquisition run \(runID).")
        refreshDiagnostics()
    }

    /// Samples counters on the main actor. This function never starts, stops,
    /// or restarts acquisition, including when invoked by Copy diagnostics.
    func refreshDiagnostics() {
        let now = runtime.clock()
        let observedAt = diagnosticRunEndedAt ?? now
        var pipeline = diagnosticProcessing.map { processing in
            processing.diagnostics.snapshot(
                ring: processing.ring,
                renderedSamples: processing.control.renderedSamples.load(ordering: .acquiring),
                capturedSamples: processing.control.capturedSamples.load(ordering: .acquiring)
            )
        } ?? PipelineDiagnosticSnapshot()
        let inputProgress = diagnosticSource == .simulated
            ? pipeline.syntheticBlocks : pipeline.acceptedInputCallbacks
        if inputProgress > lastObservedInputCount {
            if firstObservedInputAt == nil { firstObservedInputAt = observedAt }
            lastObservedInputAt = observedAt
            lastObservedInputCount = inputProgress
            if !recordedFirstInput {
                recordedFirstInput = true
                recordDiagnosticEvent(
                    category: "pipeline", code: "first_input",
                    message: diagnosticSource == .simulated
                        ? "The synthetic producer supplied sample blocks."
                        : "The microphone tap supplied supported sample buffers."
                )
                if isRunning, diagnosticSource == .microphone {
                    message = "Microphone samples are arriving. Input level and spectrum are independent of phase quality."
                }
            }
        }
        if pipeline.processedFrames > lastObservedProcessingCount {
            lastObservedProcessingAt = observedAt
            lastObservedProcessingCount = pipeline.processedFrames
            if !recordedFirstProcessedFrame {
                recordedFirstProcessedFrame = true
                recordDiagnosticEvent(
                    category: "pipeline", code: "first_processed_frame",
                    message: diagnosticProcessing?.acquisitionKind == .listen
                        ? "The DSP consumer produced passive input analysis; tone analysis was not requested."
                        : "The DSP consumer produced a frame. Phase validity is reported separately."
                )
            }
        }
        pipeline.secondsSinceInput = lastObservedInputAt.map { max(0, observedAt - $0) }
        pipeline.secondsSinceProcessing = lastObservedProcessingAt.map { max(0, observedAt - $0) }

        if let windowStart = diagnosticWindowStartedAt {
            let windowElapsed = max(0, observedAt - windowStart)
            if windowElapsed >= 0.5 {
                lastWindowElapsedSeconds = windowElapsed
                // Count callbacks observed since this window's baseline,
                // including ignored callbacks inside that interval. DEMO reports synthetic counts
                // separately and never impersonates a microphone callback.
                lastWindowInputCallbacks = pipeline.inputCallbacks &- diagnosticWindowInputCount
                lastWindowProcessedFrames = pipeline.processedFrames &- diagnosticWindowProcessedCount
                diagnosticWindowStartedAt = observedAt
                diagnosticWindowInputCount = pipeline.inputCallbacks
                diagnosticWindowProcessedCount = pipeline.processedFrames
            }
        }
        pipeline.samplingWindowElapsedSeconds = lastWindowElapsedSeconds
        pipeline.inputCallbacksInWindow = lastWindowInputCallbacks
        pipeline.processedFramesInWindow = lastWindowProcessedFrames

        let monitoringElapsed = diagnosticMonitoringStartedAt.map { max(0, observedAt - $0) } ?? 0
        let observingActiveRun = isRunning && activeRun?.id == diagnosticRunID
        var health = PipelineHealth.evaluate(
            isRunning: observingActiveRun,
            elapsedSeconds: monitoringElapsed,
            inputCallbacks: inputProgress,
            processedFrames: pipeline.processedFrames,
            secondsSinceInput: pipeline.secondsSinceInput,
            secondsSinceProcessing: pipeline.secondsSinceProcessing
        )
        // A late first input block starts the initial DSP grace interval. Do
        // not call a consumer stalled before it has had two seconds of input.
        if health == .processingStalled, pipeline.processedFrames == 0,
           let firstInput = firstObservedInputAt, observedAt - firstInput < 2 {
            health = .waitingForProcessing
        }
        pipeline.health = health.rawValue
        let stateName: String
        switch state {
        case .idle: stateName = "idle"
        case .requestingPermission: stateName = "requesting_permission"
        case .preparing: stateName = "preparing"
        case .running: stateName = "running"
        }
        let sourceName: String?
        switch diagnosticSource {
        case .microphone: sourceName = "microphone"
        case .simulated: sourceName = "simulated"
        case nil: sourceName = nil
        }
        let toneEnabled: Bool
        if let run = activeRun, run.id == diagnosticRunID, isRunning,
           run.source == .microphone, run.processing.acquisitionKind == .tone {
            // Report the current app output gate, not the completed run's
            // configured graph. A cancelled or stopped tone is never enabled.
            toneEnabled = run.processing.control.audioEnabled.load(ordering: .acquiring)
                && !run.processing.control.cancelled.load(ordering: .acquiring)
        } else {
            toneEnabled = false
        }
        diagnosticSequence &+= 1
        diagnosticSnapshot = SessionDiagnosticSnapshot(
            schemaVersion: 1, snapshotSequence: diagnosticSequence, app: diagnosticIdentity,
            session: SessionDiagnosticState(
                state: stateName, mode: mode.rawValue, captureSource: sourceName,
                appIsActive: appIsActive, runID: diagnosticRunID,
                referenceEpoch: diagnosticReferenceEpoch,
                carrierHz: diagnosticProcessing?.acquisitionKind == .tone
                    ? diagnosticProcessing?.configuration.carrierFrequencyHz : nil,
                elapsedSeconds: diagnosticRunStartedAt.map { max(0, observedAt - $0) } ?? 0,
                stopReason: diagnosticStopReason?.diagnosticCode,
                acquisitionKind: diagnosticProcessing?.acquisitionKind.rawValue ?? (mode == .live ? acquisitionKind.rawValue : nil),
                transmitEnabled: toneEnabled
            ),
            audio: diagnosticAudio?.diagnosticSnapshot(), pipeline: pipeline,
            events: diagnosticLog.events, droppedEventCount: diagnosticLog.droppedEventCount
        )
    }

    /// The wall-clock monitor owns stopping. Diagnostic exports remain read-only.
    private func stopStalledLivePipelineIfNeeded() -> Bool {
        guard isRunning, let run = activeRun, run.source == .microphone,
              !run.processing.control.cancelled.load(ordering: .acquiring) else { return false }
        switch diagnosticSnapshot.pipeline.health {
        case PipelineHealth.inputStalled.rawValue:
            stopExperiment(reason: .inputStalled)
            return true
        case PipelineHealth.processingStalled.rawValue:
            stopExperiment(reason: .processingStalled)
            return true
        default:
            return false
        }
    }

    private func recordDiagnosticEvent(category: String, code: String, message: String) {
        // Events share one app-session origin, including idle intervals and
        // new runs. Only elapsed time from this app event enters the export.
        let elapsed = max(0, runtime.clock() - diagnosticLogStartedAt)
        diagnosticLog.append(elapsedSeconds: elapsed, category: category, code: code, message: message)
    }
}

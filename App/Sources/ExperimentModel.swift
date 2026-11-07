import AVFAudio
import Foundation
import RheaRFCore
import SwiftUI
import Synchronization
import UIKit

@MainActor
final class ExperimentModel: ObservableObject {
    enum State: Equatable { case idle, requestingPermission, preparing, running }

    @Published private(set) var state: State = .idle
    @Published var consentGiven = false
    @Published private(set) var latestFrame: PhaseTelemetryFrame?
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var message = "Read the experiment notes, then agree and tap Start experiment."
    @Published private(set) var referenceMessage = "A reference is set when the first valid tone estimate arrives."
    @Published private(set) var microphoneDenied = false

    private struct ActiveRun {
        let id: UInt64
        let processing: SignalProcessingSession
        let audio: AudioTransceiver
    }

    private var activeRun: ActiveRun?
    private var nextRunID: UInt64 = 0
    private var appIsActive = false
    private var permissionTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?

    var isRunning: Bool { state == .running }
    var canStart: Bool { state == .idle && consentGiven && appIsActive }
    var timeRemainingSeconds: Int { max(0, 60 - Int(elapsedSeconds)) }

    func setAppActive(_ active: Bool) {
        appIsActive = active
        if !active, activeRun != nil { stopExperiment(reason: .inactive) }
        // Permission dialogs can make the scene inactive. A permission response
        // only returns to idle; it never starts or resumes an experiment.
    }

    func startExperiment() {
        guard canStart else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            microphoneDenied = false
            beginAudio()
        case .denied:
            microphoneDenied = true
            message = "Microphone permission is denied. You can change it in iOS Settings."
        case .undetermined:
            state = .requestingPermission
            message = "Waiting for microphone permission. The experiment has not started."
            permissionTask = Task { [weak self] in
                let granted = await AVAudioApplication.requestRecordPermission()
                guard !Task.isCancelled, let self else { return }
                state = .idle
                microphoneDenied = !granted
                message = granted
                    ? "Microphone permission granted. Tap Start experiment when you are ready for the tone."
                    : "Microphone permission was not granted. The microphone and tone remain off."
                permissionTask = nil
            }
        @unknown default:
            message = "Microphone permission is unavailable on this system."
        }
    }

    private func beginAudio() {
        guard appIsActive, consentGiven, activeRun == nil else { return }
        state = .preparing
        message = "Preparing the built-in audio route."
        latestFrame = nil
        elapsedSeconds = 0
        referenceMessage = "Waiting for a valid tone estimate."
        nextRunID &+= 1
        let runID = nextRunID
        let processing = SignalProcessingSession()
        let audio = AudioTransceiver(processing: processing)
        activeRun = ActiveRun(id: runID, processing: processing, audio: audio)
        do {
            try audio.start()
            if processing.control.cancelled.load(ordering: .acquiring) {
                stopExperiment(reason: processing.control.stopReason)
                return
            }
            state = .running
            message = "The microphone and 20 kHz acoustic tone are active. Tap Stop experiment at any time."
            processing.start(
                onFrame: { [weak self] frame in
                    Task { @MainActor [weak self] in self?.receive(frame, for: runID) }
                },
                onStopped: { [weak self] reason in
                    Task { @MainActor [weak self] in
                        guard let self, activeRun?.id == runID else { return }
                        stopExperiment(reason: reason)
                    }
                }
            )
            startDurationTask(for: runID)
        } catch {
            processing.control.requestStop(.startFailed)
            audio.stop()
            activeRun = nil
            state = .idle
            message = error.localizedDescription
        }
    }

    private func receive(_ frame: PhaseTelemetryFrame, for runID: UInt64) {
        guard let run = activeRun, run.id == runID, isRunning,
              !run.processing.control.cancelled.load(ordering: .acquiring)
        else { return }
        latestFrame = frame
        elapsedSeconds = Double(run.processing.control.renderedSamples.load(ordering: .acquiring))
            / run.processing.configuration.sampleRate
        if frame.didRebaseline {
            referenceMessage = "Phase reference \(frame.calibrationID). A new reference is used after signal loss or a capture gap."
        } else if !frame.isPhaseCoherent {
            referenceMessage = "No valid phase estimate. A new reference will be set when the signal recovers."
        }
    }

    private func startDurationTask(for runID: UInt64) {
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            // Realtime rendering independently caps output at 60 * 48,000 samples.
            // This task updates the UI and also closes an engine that stalls.
            for _ in 0..<60 {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
                guard let self, let run = activeRun, run.id == runID else { return }
                elapsedSeconds = Double(run.processing.control.renderedSamples.load(ordering: .acquiring))
                    / run.processing.configuration.sampleRate
            }
            guard let self, activeRun?.id == runID else { return }
            stopExperiment(reason: .timeLimit)
        }
    }

    func resetPhaseReference() {
        guard let run = activeRun, isRunning else { return }
        run.processing.control.resetRequested.store(true, ordering: .releasing)
        referenceMessage = "Phase reference reset requested. Waiting for a valid tone estimate."
    }

    func stopExperiment(reason: ExperimentStopReason = .user) {
        permissionTask?.cancel()
        permissionTask = nil
        durationTask?.cancel()
        durationTask = nil
        if let run = activeRun {
            activeRun = nil
            run.processing.control.requestStop(reason)
            run.audio.stop()
        }
        state = .idle
        latestFrame = nil
        elapsedSeconds = 0
        referenceMessage = "A new experiment will establish a new phase reference."
        message = reason.message
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

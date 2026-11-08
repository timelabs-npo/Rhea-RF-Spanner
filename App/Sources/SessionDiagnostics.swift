import Foundation
import RheaRFCore
import Synchronization
import UIKit

/// Diagnostics contain aggregate values only. They do not retain microphone
/// samples, spectra, device identifiers, route names, or absolute clock ticks.
struct SessionDiagnosticSnapshot: Codable, Sendable {
    let schemaVersion: Int
    let snapshotSequence: UInt64
    let app: AppDiagnosticIdentity
    let session: SessionDiagnosticState
    let audio: AudioSessionDiagnosticSnapshot?
    let pipeline: PipelineDiagnosticSnapshot
    let events: [SessionDiagnosticEvent]
    let droppedEventCount: UInt64
}

struct AppDiagnosticIdentity: Codable, Sendable {
    let version: String
    let build: String
    let deviceModel: String
    let systemName: String
    let systemVersion: String
    let runtime: String

    @MainActor
    static func current() -> Self {
        #if targetEnvironment(simulator)
        let runtime = "simulator"
        #else
        let runtime = "device"
        #endif
        return Self(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            deviceModel: UIDevice.current.model,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            runtime: runtime
        )
    }
}

struct SessionDiagnosticState: Codable, Sendable {
    let state: String
    let mode: String
    /// Source of the retained counters, even after the UI switches to Replay.
    let captureSource: String?
    let appIsActive: Bool
    let runID: UInt64?
    let referenceEpoch: UInt32?
    let carrierHz: Int?
    /// Duration relative to this acquisition run, never system uptime.
    let elapsedSeconds: Double
    let stopReason: String?
    /// Describes the retained run, including after a UI mode change.
    var acquisitionKind: String? = nil
    /// Current app tone gate. False after stopping, even for a retained tone run.
    var transmitEnabled = false
}

struct SessionDiagnosticError: Codable, Sendable {
    let stage: String
    let domain: String
    let code: Int

    init(stage: String, error: any Error) {
        self.stage = stage
        let value = error as NSError
        // Error userInfo/localized text may contain paths or private values.
        // Keep only a bounded identifier and the numeric error code.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        self.domain = String(String.UnicodeScalarView(value.domain.unicodeScalars.filter {
            allowed.contains($0)
        }.prefix(120)))
        self.code = value.code
    }
}

struct AudioSessionDiagnosticSnapshot: Codable, Sendable {
    let acquisitionKind: String
    /// Immutable graph intent; this may remain true after a tone run has stopped.
    let transmitConfigured: Bool
    var stage = "not_started"
    var activationSucceeded = false
    var deactivationSucceeded: Bool?
    var engineIsRunning = false
    var category: String?
    var mode: String?
    var inputPortTypes: [String] = []
    var outputPortTypes: [String] = []
    let requestedSampleRateHz: Double
    let requestedIOBufferDurationSeconds: Double
    let requestedTapBufferFrames: Int
    var actualSampleRateHz: Double?
    var inputSampleRateHz: Double?
    var inputHardwareSampleRateHz: Double?
    var inputHardwareChannels: Int?
    var outputSampleRateHz: Double?
    var inputChannels: Int?
    var outputChannels: Int?
    var actualIOBufferDurationSeconds: Double?
    var outputVolume: Double?
    var lastError: SessionDiagnosticError?
    var cleanupError: SessionDiagnosticError?

    init(configuration: RadarConfiguration, acquisitionKind: AcquisitionKind = .tone) {
        self.acquisitionKind = acquisitionKind.rawValue
        transmitConfigured = acquisitionKind.transmitEnabled
        requestedSampleRateHz = configuration.sampleRate
        requestedIOBufferDurationSeconds = Double(configuration.frameSize) / configuration.sampleRate
        requestedTapBufferFrames = configuration.frameSize
    }
}

struct SessionInputStatistics: Codable, Sendable {
    let sampleCount: Int
    let finiteSampleCount: Int
    let zeroSampleCount: Int
    let nonFiniteSampleCount: Int
    let clippedSampleCount: Int
    let minimum: Double?
    let maximum: Double?
    let mean: Double?
    let rms: Double?
    let peak: Double?

    init(_ statistics: SignalBlockStatistics) {
        sampleCount = statistics.sampleCount
        finiteSampleCount = statistics.finiteSampleCount
        zeroSampleCount = statistics.zeroSampleCount
        nonFiniteSampleCount = statistics.nonFiniteSampleCount
        clippedSampleCount = statistics.clippedSampleCount
        minimum = finiteDiagnosticValue(statistics.minimum)
        maximum = finiteDiagnosticValue(statistics.maximum)
        mean = finiteDiagnosticValue(statistics.mean)
        rms = finiteDiagnosticValue(statistics.rms)
        peak = finiteDiagnosticValue(statistics.peak)
    }
}

struct SessionDSPDiagnostic: Codable, Sendable {
    /// Index in the acquisition run, normalized by the capture adapter.
    let sampleIndex: UInt64
    let validity: String
    let carrierAmplitude: Double?
    let toneResidualDB: Double?
    let relativePhaseRadians: Double?
    let spectrumBinCount: Int
    let spectrumPeakHz: Double?
    let spectrumPeakDBFS: Double?
    var acquisitionKind: String? = nil
    var toneAnalysis = "requested"
    var timestampsAreValid: Bool? = nil
    var samplesAreContiguous: Bool? = nil
}

struct PipelineDiagnosticSnapshot: Codable, Sendable {
    var inputCallbacks: UInt64 = 0
    var ignoredInputCallbacks: UInt64 = 0
    var acceptedInputCallbacks: UInt64 = 0
    var offeredSamples: UInt64 = 0
    var enqueuedSamples: UInt64 = 0
    var syntheticBlocks: UInt64 = 0
    var syntheticSamples: UInt64 = 0
    var sourceCallbacks: UInt64 = 0
    var renderedSamples: UInt64 = 0
    var capturedSamples: UInt64 = 0
    var processedFrames: UInt64 = 0
    var spectrumFrames: UInt64 = 0
    var validPhaseFrames: UInt64 = 0
    var lowSignalFrames: UInt64 = 0
    var lowQualityFrames: UInt64 = 0
    var discontinuousFrames: UInt64 = 0
    var nonFiniteFrames: UInt64 = 0
    var inputFramesMin: Int?
    var inputFramesMax: Int?
    var inputFramesLast: Int?
    var lastCaptureSampleIndex: UInt64?
    var sampleTimestampValid: Bool?
    var hostTimestampValid: Bool?
    var timestampGapCount: UInt64 = 0
    var invalidTimestampCount: UInt64 = 0
    var sourceTimelineErrorCount: UInt64 = 0
    var routeChangeNotificationCount: UInt64 = 0
    var lastRouteChangeReason: UInt64?
    var lastInterruptionType: UInt64?
    var ringAvailableSamples: Int = 0
    var droppedWriteBlocks: UInt64 = 0
    var droppedWriteSamples: UInt64 = 0
    /// These are app-observed event intervals, not exported system clock values.
    var secondsSinceInput: Double?
    var secondsSinceProcessing: Double?
    var samplingWindowElapsedSeconds: Double?
    var inputCallbacksInWindow: UInt64 = 0
    var processedFramesInWindow: UInt64 = 0
    var health = "idle"
    var latestInput: SessionInputStatistics?
    var latestDSP: SessionDSPDiagnostic?

    /// HUD rates are computed from event counts and an elapsed interval. Only
    /// those counts and interval are encoded; no boot-derived clock is exported.
    var observedInputCallbacksPerSecond: Double? {
        guard let seconds = samplingWindowElapsedSeconds, seconds.isFinite, seconds > 0 else { return nil }
        return finiteDiagnosticValue(Double(inputCallbacksInWindow) / seconds)
    }

    var processedFramesPerSecond: Double? {
        guard let seconds = samplingWindowElapsedSeconds, seconds.isFinite, seconds > 0 else { return nil }
        return finiteDiagnosticValue(Double(processedFramesInWindow) / seconds)
    }
}

typealias SessionDiagnosticEvent = DiagnosticEvent

/// Main-actor-owned event history. Callback counters never append strings here.
struct SessionDiagnosticLog {
    private var storage = BoundedDiagnosticLog(capacity: 128)
    var events: [SessionDiagnosticEvent] { storage.events }
    var droppedEventCount: UInt64 { storage.droppedEventCount }

    mutating func append(elapsedSeconds: Double, category: String, code: String, message: String) {
        storage.append(elapsedSeconds: elapsedSeconds, category: category, code: code, message: message)
    }
}

/// Callback fields are atomics. The mutex is used only by the DSP consumer and
/// the main-actor monitor, never by the input tap or source render callback.
final class SessionDiagnosticCounters: Sendable {
    let inputCallbacks = Atomic<UInt64>(0)
    let ignoredInputCallbacks = Atomic<UInt64>(0)
    let acceptedInputCallbacks = Atomic<UInt64>(0)
    let offeredSamples = Atomic<UInt64>(0)
    let enqueuedSamples = Atomic<UInt64>(0)
    let syntheticBlocks = Atomic<UInt64>(0)
    let syntheticSamples = Atomic<UInt64>(0)
    let sourceCallbacks = Atomic<UInt64>(0)
    let processedFrames = Atomic<UInt64>(0)
    let spectrumFrames = Atomic<UInt64>(0)
    let validPhaseFrames = Atomic<UInt64>(0)
    let lowSignalFrames = Atomic<UInt64>(0)
    let lowQualityFrames = Atomic<UInt64>(0)
    let discontinuousFrames = Atomic<UInt64>(0)
    let nonFiniteFrames = Atomic<UInt64>(0)
    let inputFramesMin = Atomic<Int>(0)
    let inputFramesMax = Atomic<Int>(0)
    let inputFramesLast = Atomic<Int>(0)
    let lastCaptureSampleIndex = Atomic<UInt64>(0)
    let sampleTimestampValid = Atomic<Bool>(false)
    let hostTimestampValid = Atomic<Bool>(false)
    let timestampGapCount = Atomic<UInt64>(0)
    let invalidTimestampCount = Atomic<UInt64>(0)
    let sourceTimelineErrorCount = Atomic<UInt64>(0)
    let routeChangeNotificationCount = Atomic<UInt64>(0)
    /// Store rawValue + 1; zero represents no observed notification.
    let lastRouteChangeReason = Atomic<UInt64>(0)
    let lastInterruptionType = Atomic<UInt64>(0)

    private struct LatestDSP: Sendable {
        let input: SessionInputStatistics?
        let output: SessionDSPDiagnostic
    }
    private let latestDSP = Mutex<LatestDSP?>(nil)

    /// Called on the one input producer. Min/max updates have a single writer.
    func recordInputCallback(frameCount: Int) {
        let isFirstCallback = inputCallbacks.load(ordering: .relaxed) == 0
        inputFramesLast.store(frameCount, ordering: .relaxed)
        let minimum = inputFramesMin.load(ordering: .relaxed)
        if isFirstCallback || frameCount < minimum { inputFramesMin.store(frameCount, ordering: .relaxed) }
        let maximum = inputFramesMax.load(ordering: .relaxed)
        if frameCount > maximum { inputFramesMax.store(frameCount, ordering: .relaxed) }
        inputCallbacks.wrappingAdd(1, ordering: .releasing)
    }

    /// Called only on the serial DSP consumer after it has produced a frame.
    func recordProcessedFrame(
        _ frame: PhaseTelemetryFrame,
        statistics: SignalBlockStatistics?, spectrum: SpectrumFrame?,
        timing: AudioAnalysisTiming
    ) {
        var peakLevel: Double?
        var peakFrequency: Double?
        if let spectrum {
            for (frequency, level) in zip(spectrum.frequenciesHz, spectrum.magnitudesDBFS)
                where frequency.isFinite && level.isFinite && level > -160 {
                if peakLevel == nil || Double(level) > (peakLevel ?? -.infinity) {
                    peakLevel = Double(level)
                    peakFrequency = Double(frequency)
                }
            }
            spectrumFrames.wrappingAdd(1, ordering: .relaxed)
        }
        let aggregate = LatestDSP(
            input: statistics.map(SessionInputStatistics.init),
            output: SessionDSPDiagnostic(
                sampleIndex: frame.sampleTimestamp, validity: frame.validity.rawValue,
                carrierAmplitude: finiteDiagnosticValue(frame.carrierAmplitude),
                toneResidualDB: finiteDiagnosticValue(frame.qualityDB),
                relativePhaseRadians: finiteDiagnosticValue(frame.relativePhaseRadians),
                spectrumBinCount: spectrum?.magnitudesDBFS.count ?? 0,
                spectrumPeakHz: peakFrequency, spectrumPeakDBFS: peakLevel,
                acquisitionKind: "tone",
                timestampsAreValid: timing.timestampsAreValid,
                samplesAreContiguous: timing.samplesAreContiguous
            )
        )
        latestDSP.withLock { $0 = aggregate }
        switch frame.validity {
        case .valid: validPhaseFrames.wrappingAdd(1, ordering: .relaxed)
        case .lowSignal: lowSignalFrames.wrappingAdd(1, ordering: .relaxed)
        case .lowQuality: lowQualityFrames.wrappingAdd(1, ordering: .relaxed)
        case .inputDiscontinuity: discontinuousFrames.wrappingAdd(1, ordering: .relaxed)
        case .nonFiniteInput: nonFiniteFrames.wrappingAdd(1, ordering: .relaxed)
        }
        processedFrames.wrappingAdd(1, ordering: .releasing)
    }

    /// Common consumer evidence. Listen deliberately has no phase validity or
    /// carrier estimate; timing/nonfinite evidence remains independently useful.
    func recordProcessedAnalysisFrame(_ frame: AudioAnalysisFrame) {
        if let tone = frame.tone {
            // A tone validity result alone cannot distinguish unavailable
            // timestamps from a discontinuity inside the consumed window.
            recordProcessedFrame(
                tone, statistics: frame.inputStatistics, spectrum: frame.spectrum,
                timing: frame.timing
            )
            return
        }
        var peakLevel: Double?
        var peakFrequency: Double?
        if let spectrum = frame.spectrum {
            for (frequency, level) in zip(spectrum.frequenciesHz, spectrum.magnitudesDBFS)
                where frequency.isFinite && level.isFinite && level > -160 {
                if peakLevel == nil || Double(level) > (peakLevel ?? -.infinity) {
                    peakLevel = Double(level)
                    peakFrequency = Double(frequency)
                }
            }
            spectrumFrames.wrappingAdd(1, ordering: .relaxed)
        }
        let aggregate = LatestDSP(
            input: SessionInputStatistics(frame.inputStatistics),
            output: SessionDSPDiagnostic(
                sampleIndex: frame.sampleTimestamp, validity: "not_requested",
                carrierAmplitude: nil, toneResidualDB: nil, relativePhaseRadians: nil,
                spectrumBinCount: frame.spectrum?.magnitudesDBFS.count ?? 0,
                spectrumPeakHz: peakFrequency, spectrumPeakDBFS: peakLevel,
                acquisitionKind: frame.acquisitionKind.rawValue, toneAnalysis: "not_requested",
                timestampsAreValid: frame.timing.timestampsAreValid,
                samplesAreContiguous: frame.timing.samplesAreContiguous
            )
        )
        latestDSP.withLock { $0 = aggregate }
        if frame.timing.discontinuityDetected { discontinuousFrames.wrappingAdd(1, ordering: .relaxed) }
        if frame.inputStatistics.nonFiniteSampleCount > 0 { nonFiniteFrames.wrappingAdd(1, ordering: .relaxed) }
        processedFrames.wrappingAdd(1, ordering: .releasing)
    }

    func snapshot(
        ring: SPSCFloatRingBuffer, renderedSamples: UInt64, capturedSamples: UInt64 = 0
    ) -> PipelineDiagnosticSnapshot {
        var result = PipelineDiagnosticSnapshot()
        result.inputCallbacks = inputCallbacks.load(ordering: .acquiring)
        result.ignoredInputCallbacks = ignoredInputCallbacks.load(ordering: .relaxed)
        result.acceptedInputCallbacks = acceptedInputCallbacks.load(ordering: .acquiring)
        result.offeredSamples = offeredSamples.load(ordering: .relaxed)
        result.enqueuedSamples = enqueuedSamples.load(ordering: .relaxed)
        result.syntheticBlocks = syntheticBlocks.load(ordering: .acquiring)
        result.syntheticSamples = syntheticSamples.load(ordering: .relaxed)
        result.sourceCallbacks = sourceCallbacks.load(ordering: .relaxed)
        result.renderedSamples = renderedSamples
        result.capturedSamples = capturedSamples
        result.processedFrames = processedFrames.load(ordering: .acquiring)
        result.spectrumFrames = spectrumFrames.load(ordering: .relaxed)
        result.validPhaseFrames = validPhaseFrames.load(ordering: .relaxed)
        result.lowSignalFrames = lowSignalFrames.load(ordering: .relaxed)
        result.lowQualityFrames = lowQualityFrames.load(ordering: .relaxed)
        result.discontinuousFrames = discontinuousFrames.load(ordering: .relaxed)
        result.nonFiniteFrames = nonFiniteFrames.load(ordering: .relaxed)
        if result.inputCallbacks > 0 {
            result.inputFramesMin = inputFramesMin.load(ordering: .relaxed)
            result.inputFramesMax = inputFramesMax.load(ordering: .relaxed)
            result.inputFramesLast = inputFramesLast.load(ordering: .relaxed)
        }
        if result.acceptedInputCallbacks > 0 {
            result.lastCaptureSampleIndex = lastCaptureSampleIndex.load(ordering: .relaxed)
            result.sampleTimestampValid = sampleTimestampValid.load(ordering: .relaxed)
            result.hostTimestampValid = hostTimestampValid.load(ordering: .relaxed)
        }
        result.timestampGapCount = timestampGapCount.load(ordering: .relaxed)
        result.invalidTimestampCount = invalidTimestampCount.load(ordering: .relaxed)
        result.sourceTimelineErrorCount = sourceTimelineErrorCount.load(ordering: .relaxed)
        result.routeChangeNotificationCount = routeChangeNotificationCount.load(ordering: .relaxed)
        let routeReason = lastRouteChangeReason.load(ordering: .relaxed)
        result.lastRouteChangeReason = routeReason == 0 ? nil : routeReason - 1
        let interruption = lastInterruptionType.load(ordering: .relaxed)
        result.lastInterruptionType = interruption == 0 ? nil : interruption - 1
        result.ringAvailableSamples = ring.availableToRead
        result.droppedWriteBlocks = ring.droppedWriteBlocks
        result.droppedWriteSamples = ring.droppedWriteSamples
        latestDSP.withLock { latest in
            result.latestInput = latest?.input
            result.latestDSP = latest?.output
        }
        return result
    }
}

func finiteDiagnosticValue(_ value: Double?) -> Double? {
    guard let value, value.isFinite else { return nil }
    return value
}

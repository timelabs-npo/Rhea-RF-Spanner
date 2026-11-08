/// The acquisition intent is fixed when a run is created. Listening requests
/// broad input analysis without requesting a transmitted tone or a tone fit.
public enum AcquisitionKind: String, Sendable, Codable, CaseIterable, Hashable {
    case listen
    case tone

    public var transmitEnabled: Bool { self == .tone }
}

/// Independent timing evidence for one consumed input window. An internally
/// contiguous window after a gap can have a spectrum at its actual capture
/// index, while still reporting the discontinuity from the preceding window.
public struct AudioAnalysisTiming: Sendable, Equatable {
    public let timestampsAreValid: Bool
    public let samplesAreContiguous: Bool
    public let hasGapBeforeWindow: Bool

    public var discontinuityDetected: Bool {
        !timestampsAreValid || !samplesAreContiguous || hasGapBeforeWindow
    }

    public init(
        timestampsAreValid: Bool,
        samplesAreContiguous: Bool,
        hasGapBeforeWindow: Bool
    ) {
        self.timestampsAreValid = timestampsAreValid
        self.samplesAreContiguous = samplesAreContiguous
        self.hasGapBeforeWindow = hasGapBeforeWindow
    }
}

/// A single read of the input ring produces levels, timing evidence, and an
/// optional spectrum independently of tone fitting. In Listen, `tone` is nil
/// because tone analysis was not requested, rather than because a fit failed.
/// No carrier configuration, displacement, or synthetic phase is needed to
/// identify a passive observation.
public struct AudioAnalysisFrame: Sendable {
    public let acquisitionKind: AcquisitionKind
    /// First input sample's run-relative capture index, not delivery time.
    /// Inspect `timing.timestampsAreValid` before treating it as hardware time.
    public let sampleTimestamp: UInt64
    public let timing: AudioAnalysisTiming
    /// Finite-subset aggregate metrics remain available if input contains
    /// nonfinite values; the counts retain that distinction. No samples remain.
    public let inputStatistics: SignalBlockStatistics
    /// Absent for nonfinite input, invalid timestamps, or an internal gap.
    public let spectrum: SpectrumFrame?
    public let tone: PhaseTelemetryFrame?
    public let droppedWriteBlocks: UInt64
    public let droppedWriteSamples: UInt64

    public init(
        acquisitionKind: AcquisitionKind,
        sampleTimestamp: UInt64,
        timing: AudioAnalysisTiming,
        inputStatistics: SignalBlockStatistics,
        spectrum: SpectrumFrame?,
        tone: PhaseTelemetryFrame?,
        droppedWriteBlocks: UInt64,
        droppedWriteSamples: UInt64
    ) {
        precondition(acquisitionKind == .tone || tone == nil)
        self.acquisitionKind = acquisitionKind
        self.sampleTimestamp = sampleTimestamp
        self.timing = timing
        self.inputStatistics = inputStatistics
        self.spectrum = spectrum
        self.tone = tone
        self.droppedWriteBlocks = droppedWriteBlocks
        self.droppedWriteSamples = droppedWriteSamples
    }
}

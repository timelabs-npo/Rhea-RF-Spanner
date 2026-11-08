import Foundation
import RheaRFCore
import SwiftUI
import UIKit

/// Explicit, user-initiated export of aggregate observations. No audio samples,
/// images, route names, network addresses, device identifiers or absolute boot
/// timestamps are included. Session and renderer exporters own finite values.
struct ObservatoryDiagnosticReport: Encodable {
    let schemaVersion = 1
    let session: SessionDiagnosticSnapshot
    let renderer: RendererDiagnosticSnapshot
    let selfTest: DiagnosticSelfTestResult?

    init(session: SessionDiagnosticSnapshot, renderer: RendererDiagnosticSnapshot,
         selfTest: DiagnosticSelfTestResult? = nil) {
        self.session = session
        self.renderer = renderer
        self.selfTest = selfTest
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DiagnosticExportError.invalidText
        }
        return text
    }
}

private enum DiagnosticExportError: LocalizedError {
    case invalidText
    var errorDescription: String? { "The diagnostic report could not be encoded as text." }
}

@MainActor
struct DiagnosticsView: View {
    @ObservedObject var model: ExperimentModel
    let renderer: RendererDiagnostics
    @Environment(\.dismiss) private var dismiss
    @State private var rendererSnapshot: RendererDiagnosticSnapshot?
    @State private var exportMessage: String?
    @State private var showJSON = false
    @State private var reportText = ""
    @State private var selfTestResult: DiagnosticSelfTestResult?
    @State private var selfTestRunning = false

    private var session: SessionDiagnosticSnapshot { model.diagnosticSnapshot }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Pipeline diagnostics", systemImage: "waveform.path.ecg.rectangle")
                            .font(.title3.weight(.semibold))
                        Text("Observed input, processing and drawing. A running session alone does not confirm that samples are arriving.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(model.inputStatusText + " · " + model.inputLevelText)
                            .font(.callout.monospacedDigit())
                    }
                    .padding(.vertical, 4)
                    Button(action: copyReport) {
                        Label("Copy Diagnostic Dump", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("copyDiagnosticDumpButton")
                    Button(action: previewReport) {
                        Label("Inspect JSON report", systemImage: "curlybraces")
                    }
                    if let exportMessage {
                        Text(exportMessage).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("diagnosticExportStatus")
                    }
                } footer: {
                    Text("Aggregate levels and operational events only. No raw audio, photos, location, account or network identifiers. Nothing is uploaded automatically.")
                }

                Section("Acquisition → processing") {
                    row("Mode / state", session.session.mode + " / " + session.session.state)
                    row("Flow", session.pipeline.health)
                    row("Input callbacks", session.pipeline.inputCallbacks.formatted())
                    row("Last buffer", session.pipeline.inputFramesLast.map { "\($0) samples" } ?? "Unavailable")
                    row("Processed frames", session.pipeline.processedFrames.formatted())
                    row("Spectra", session.pipeline.spectrumFrames.formatted())
                    row("Valid phase frames", session.pipeline.validPhaseFrames.formatted())
                    row("DSP rate", rate(session.pipeline.processedFramesPerSecond) + " frames/s")
                    row("Ring occupancy", "\(session.pipeline.ringAvailableSamples) samples")
                    row("Dropped samples", session.pipeline.droppedWriteSamples.formatted())
                    if let input = session.pipeline.latestInput {
                        row("Input RMS", number(input.rms))
                        row("Input peak", number(input.peak))
                        row("Zero / total", "\(input.zeroSampleCount) / \(input.sampleCount)")
                        row("Nonfinite / clipped", "\(input.nonFiniteSampleCount) / \(input.clippedSampleCount)")
                    }
                }

                if let gpu = rendererSnapshot {
                    Section("Metal rendering") {
                        row("Setup", gpu.setupStatus)
                        row("Submitted / completed", "\(gpu.submittedFrames) / \(gpu.completedFrames)")
                        row("GPU completion rate", rate(gpu.measuredCompletedFramesPerSecond) + " frames/s")
                        row("Failed frames", gpu.failedFrames.formatted())
                        row("Drawable unavailable", gpu.noDrawableCount.formatted())
                        row("In-flight skips", gpu.inFlightSkips.formatted())
                        row("Spectrum available", gpu.hasSpectrum ? "Yes" : "No")
                        if let error = gpu.lastError { Text(error).foregroundStyle(.orange) }
                    }
                }

                Section {
                    Button {
                        selfTestRunning = true
                        Task {
                            let result = await Task.detached(priority: .userInitiated) {
                                DiagnosticSelfTest.run()
                            }.value
                            selfTestResult = result
                            selfTestRunning = false
                        }
                    } label: {
                        Label(selfTestRunning ? "Running core self-test…" : "Run silent core self-test",
                              systemImage: "checkmark.seal")
                    }
                    .disabled(selfTestRunning)
                    .accessibilityIdentifier("runCoreSelfTestButton")
                    if let result = selfTestResult {
                        Label(result.passed ? "Software fixture passed" : "Software fixture failed",
                              systemImage: result.passed ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(result.passed ? Color.green : Color.orange)
                        ForEach(Array(result.checks.enumerated()), id: \.offset) { _, check in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(check.name).font(.caption.weight(.semibold))
                                Text("Expected \(number(check.expected)); observed \(number(check.observed)) \(check.unit); tolerance \(number(check.absoluteTolerance)).")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Deterministic software check")
                } footer: {
                    Text("Two analytical signal blocks test the queue, phase fit and FFT without changing your current acquisition. This does not test the microphone, speaker, GPU or external sensors.")
                }

                Section("Recent events") {
                    if session.events.isEmpty {
                        Text("No lifecycle or error events yet.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(session.events.suffix(12).enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(event.category) · \(event.code)")
                                .font(.caption.weight(.semibold).monospaced())
                            Text(event.message).font(.caption)
                            Text("+" + rate(event.elapsedSeconds) + " s since diagnostics started")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    if session.droppedEventCount > 0 {
                        Text("\(session.droppedEventCount) older events were overwritten in the bounded log.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Read the result") {
                    Text("If input is arriving but phase is unavailable, inspect Full audio Waterfall. Speech and other sound can be present without a coherent 18–22 kHz carrier.")
                    Text("DEMO uses the same processing and display path with synthetic samples. It can isolate software faults without microphone permission or speaker output.")
                    Text("Rates measure actual processed or completed frames over a recent interval. They are not the screen refresh rate. Digital levels are not calibrated sound pressure.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                while !Task.isCancelled {
                    model.refreshDiagnostics()
                    rendererSnapshot = renderer.snapshot()
                    do { try await Task.sleep(nanoseconds: 500_000_000) }
                    catch { return }
                }
            }
            .sheet(isPresented: $showJSON) {
                NavigationStack {
                    ScrollView {
                        Text(reportText)
                            .font(.caption.monospaced())
                            .textSelection(.disabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("Diagnostic JSON")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showJSON = false } } }
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return value.formatted(.number.precision(.significantDigits(4)))
    }

    private func rate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    private func makeReport() throws -> String {
        model.refreshDiagnostics()
        return try ObservatoryDiagnosticReport(session: model.diagnosticSnapshot, renderer: renderer.snapshot(),
                                               selfTest: selfTestResult).jsonString()
    }

    private func previewReport() {
        do {
            reportText = try makeReport()
            showJSON = true
            exportMessage = nil
        } catch {
            exportMessage = "Could not prepare a valid JSON report. " + error.localizedDescription
        }
    }

    private func copyReport() {
        do {
            let text = try makeReport()
            UIPasteboard.general.setItems(
                [["public.utf8-plain-text": text]],
                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(3_600)]
            )
            exportMessage = "Diagnostic JSON copied. Paste it into your bug report. The local clipboard copy expires in one hour."
        } catch {
            exportMessage = "Copy failed: " + error.localizedDescription
        }
    }
}

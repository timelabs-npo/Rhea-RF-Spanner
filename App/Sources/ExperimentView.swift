import RheaRFCore
import SwiftUI

@MainActor
struct ExperimentView: View {
    @ObservedObject var model: ExperimentModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPrivacy = false

    private let accent = Color(red: 0.18, green: 0.88, blue: 0.82)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                activityBanner
                controls
                visualization
                measurements
                notes
                Button {
                    if model.state != .idle { model.stopExperiment() }
                    showPrivacy = true
                } label: {
                    Label("Privacy & method", systemImage: "info.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("privacyMethodButton")
            }
            .padding(20)
            .frame(maxWidth: 650)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.025, green: 0.04, blue: 0.06).ignoresSafeArea())
        .tint(accent)
        .sheet(isPresented: $showPrivacy) { PrivacyMethodView() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("RHEA / EXPERIMENT 01")
                .font(.caption.monospaced().weight(.semibold))
                .tracking(2)
                .foregroundStyle(accent)
            Text("Rhea RF Spanner").font(.largeTitle.bold())
            Text("Acoustic phase experiment")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var activityBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                model.isRunning ? "MICROPHONE + 20 kHz TONE ACTIVE" : "IDLE — MICROPHONE OFF",
                systemImage: model.isRunning ? "mic.fill" : "mic.slash"
            )
            .font(.caption.weight(.bold))
            .foregroundStyle(model.isRunning ? Color.orange : accent)
            .accessibilityIdentifier("activityIndicator")
            Text(model.message).font(.callout).foregroundStyle(.secondary)
            if model.microphoneDenied {
                Button("Open microphone settings") { model.openSettings() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.isRunning {
                Toggle("I agree to a 20 kHz speaker tone and live microphone analysis.", isOn: $model.consentGiven)
                    .font(.callout)
                    .disabled(model.state != .idle)
                    .accessibilityIdentifier("experimentConsentToggle")
            }
            if model.isRunning {
                Button(role: .destructive) { model.stopExperiment() } label: {
                    Label("Stop experiment", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityIdentifier("stopExperimentButton")
            } else {
                Button { model.startExperiment() } label: {
                    Label(
                        model.state == .requestingPermission ? "Waiting for permission" : "Start experiment",
                        systemImage: "play.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
                .accessibilityIdentifier("startExperimentButton")
            }
            Text("Built-in speaker + microphone · 20 kHz tone · 60 s maximum")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var visualization: some View {
        VStack(alignment: .leading, spacing: 9) {
            PhaseCanvas(
                phase: model.latestFrame?.relativePhaseRadians,
                valid: model.latestFrame?.isPhaseCoherent ?? false,
                active: model.isRunning, reduceMotion: reduceMotion
            )
            .frame(height: 210)
            Text("Abstract phase visualization")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var measurements: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("LIVE ESTIMATES").font(.caption.weight(.bold)).tracking(1.5)
                Spacer()
                Text(model.isRunning ? "\(model.timeRemainingSeconds) s remaining" : "No active session")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            metric("Relative phase", value: formatted(model.latestFrame?.relativePhaseRadians, unit: "rad", places: 3))
            metric("Phase-derived displacement (model)", value: formatted(
                model.latestFrame?.equivalentMonostaticDisplacementMeters.map { $0 * 1_000 }, unit: "mm", places: 2
            ))
            metric("Tone / residual estimate", value: formatted(model.latestFrame?.qualityDB, unit: "dB", places: 1))
            metric("Signal quality gate", value: model.latestFrame?.validity.displayName ?? "No estimate")
            metric("Dropped blocks", value: model.latestFrame.map { String($0.droppedWriteBlocks) } ?? "—")
            Text(model.referenceMessage).font(.caption).foregroundStyle(.secondary)
            Button("Reset phase reference") { model.resetPhaseReference() }
                .buttonStyle(.bordered)
                .disabled(!model.isRunning)
                .accessibilityIdentifier("resetPhaseReferenceButton")
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What this measures").font(.headline)
            Text("The app analyzes acoustic phase. It does not measure radio-frequency signals. The displacement is a conditional phase model, not a measured distance to an object.")
            Text("Use only where everyone nearby agrees. Keep the speaker away from ears, begin with low device volume, and stop if uncomfortable. The tone is not guaranteed to be inaudible.")
            Text("Audio remains in memory. No recordings, uploads, accounts, or background operation.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit()).foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }

    private func formatted(_ value: Double?, unit: String, places: Int) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(places))) + " " + unit
    }
}

import Foundation
import RheaRFCore
import SwiftUI

@MainActor
struct ExperimentView: View {
    @ObservedObject var model: ExperimentModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showPrivacy = false
    @State private var showDiagnostics = ProcessInfo.processInfo.arguments.contains("--observatory-diagnostics")
    @State private var rendererDiagnostics = RendererDiagnostics()
    @State private var showControls = true
    @State private var showReadout = true
    @State private var adjustment: Adjustment = .carrier

    private enum Adjustment: String, CaseIterable {
        case carrier, display, readout
    }

    private let accent = Color(red: 1, green: 0.81, blue: 0.18)
    private let subdued = Color(white: 0.65)

    var body: some View {
        GeometryReader { geometry in
            let needsScroll = dynamicTypeSize >= .xxLarge || geometry.size.height < 600 || geometry.size.width < 340
            Group {
                if needsScroll {
                    ScrollView {
                        VStack(spacing: 16) {
                            topChrome
                            viewport(overlayControls: false)
                                .frame(height: dynamicTypeSize.isAccessibilitySize ? 600 : dynamicTypeSize >= .xxLarge ? 430 : 340)
                            if showControls { controlPanel }
                            consentPanel
                            transport
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 10) {
                        topChrome.padding(.horizontal, 14)
                        viewport(overlayControls: model.presentation == .field)
                            .frame(maxHeight: .infinity)
                            .padding(.horizontal, 8)
                        if showControls && model.presentation == .waterfall {
                            controlPanel.padding(.horizontal, 12)
                        }
                        consentPanel.padding(.horizontal, 16)
                        transport.padding(.horizontal, 20)
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .tint(accent)
        .sheet(isPresented: $showPrivacy) { PrivacyMethodView() }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(model: model, renderer: rendererDiagnostics)
        }
    }

    private var topChrome: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RHEA")
                        .font(.headline.weight(.bold))
                        .tracking(3.5)
                    Text("ACOUSTIC OBSERVATORY")
                        .font(.caption2.monospaced())
                        .tracking(0.8)
                        .foregroundStyle(subdued)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 4)
                Label(model.microphoneIsActive ? "MIC SESSION" : "MIC OFF",
                      systemImage: model.microphoneIsActive ? "mic.fill" : "mic.slash")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(model.microphoneIsActive ? Color.orange : subdued)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(white: 0.12), in: Capsule())
                    .accessibilityIdentifier("activityIndicator")
                Button { showDiagnostics = true } label: {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.title3)
                        .frame(width: 40, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel("Open diagnostics")
                .accessibilityIdentifier("openDiagnosticsButton")
                observatoryMenu
            }
            HStack(spacing: 4) {
                ForEach(ObservatoryMode.allCases, id: \.rawValue) { mode in
                    Button {
                        model.selectMode(mode)
                    } label: {
                        Text(mode.displayName)
                            .font(.caption.weight(.bold))
                            .tracking(1.5)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundStyle(model.mode == mode ? Color.black : subdued)
                            .background {
                                if model.mode == mode {
                                    RoundedRectangle(cornerRadius: 10).fill(accent)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.displayName + " mode")
                    .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                    .accessibilityIdentifier("mode_" + mode.rawValue)
                }
            }
            .padding(4)
            .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var observatoryMenu: some View {
        Menu {
            Section("Monitoring") {
                Button { showDiagnostics = true } label: {
                    Label("Diagnostics & copy report", systemImage: "doc.text.magnifyingglass")
                }
                Toggle("Phase readout", isOn: $showReadout)
                Picker("Spectrum range", selection: $model.displayParameters.spectrumBand) {
                    ForEach(SpectrumDisplayBand.allCases, id: \.rawValue) { band in
                        Text(band.displayName).tag(band)
                    }
                }
                Picker("False-color palette", selection: $model.displayParameters.palette) {
                    ForEach(ObservatoryPalette.allCases, id: \.rawValue) { palette in
                        Text(palette.displayName).tag(palette)
                    }
                }
            }
            Section {
                Button {
                    if model.state != .idle || model.isReplaying { model.stopExperiment() }
                    showPrivacy = true
                } label: {
                    Label("Privacy & method", systemImage: "info.circle")
                }
                .accessibilityIdentifier("privacyMethodButton")
                Button(role: .destructive) { model.clearReplay() } label: {
                    Label("Clear replay", systemImage: "trash")
                }
                .disabled(!model.canClearReplay)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color(white: 0.12), in: Circle())
        }
        .accessibilityLabel("Observatory menu")
    }

    private func viewport(overlayControls: Bool) -> some View {
        VStack(spacing: 0) {
            if model.presentation == .waterfall { frequencyAxis }
            HStack(spacing: 0) {
                if model.presentation == .waterfall { timeAxis }
                ZStack {
                    ObservatoryCanvas(
                        slice: model.latestSlice,
                        spectrum: model.latestSpectrum,
                        history: model.spectrumHistory,
                        display: model.displayParameters,
                        presentation: model.presentation,
                        active: model.isVisualizing,
                        reduceMotion: reduceMotion,
                        diagnostics: rendererDiagnostics
                    )
                    .accessibilityIdentifier("observatoryCanvas")
                    VStack(spacing: 12) {
                        viewportHeader
                        Spacer(minLength: 8)
                        if !(overlayControls && showControls) { fieldCaption }
                        if overlayControls && showControls { controlPanel }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color(white: 0.055))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.09), lineWidth: 1)
        }
    }

    private var viewportHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if dynamicTypeSize >= .xxLarge {
                VStack(alignment: .leading, spacing: 12) {
                    viewportStatus
                    if showReadout { phaseReadout }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    if showReadout { phaseReadout }
                    Spacer(minLength: 0)
                    viewportStatus
                }
            }
            if let slice = model.latestSlice, !slice.isPhaseCoherent {
                Label(slice.validity.displayName, systemImage: "waveform.slash")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .modifier(InstrumentSurface(cornerRadius: 12))
            }
        }
    }

    private var viewportStatus: some View {
        VStack(alignment: .trailing, spacing: 8) {
            presentationSelector
            Text(sourceCaption)
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(accent)
                .multilineTextAlignment(.trailing)
            Text(model.isRunning ? "● REC  " + clockText : model.isReplaying ? "PLAYBACK" : "STANDBY")
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(model.isRunning ? Color(red: 1, green: 0.4, blue: 0.3) : .white)
            Text(model.measuredAcquisitionText)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.65))
            Text(model.inputStatusText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(model.microphoneIsActive ? Color.orange : subdued)
            Text(model.inputLevelText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(10)
        .modifier(InstrumentSurface(cornerRadius: 15))
    }

    private var phaseReadout: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("RELATIVE PHASE")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.7))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(phaseText)
                    .font(.title.monospacedDigit().weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.identity)
                Text("rad").font(.caption).foregroundStyle(subdued)
            }
            Text(qualityText + " dB")
                .font(.subheadline.monospacedDigit())
            Text("Tone / residual")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(12)
        .modifier(InstrumentSurface(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Relative phase \(phaseText) radians. Tone to residual estimate \(qualityText) decibels.")
    }

    private var presentationSelector: some View {
        HStack(spacing: 3) {
            presentationButton(.field, title: "FIELD")
            presentationButton(.waterfall, title: "WATERFALL")
        }
        .padding(3)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func presentationButton(_ presentation: ObservatoryPresentation, title: String) -> some View {
        Button { model.presentation = presentation } label: {
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(model.presentation == presentation ? Color.black : .white)
                .padding(.horizontal, 7)
                .frame(minHeight: 34)
                .background {
                    if model.presentation == presentation {
                        RoundedRectangle(cornerRadius: 6).fill(accent)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(presentation.displayName)
        .accessibilityAddTraits(model.presentation == presentation ? .isSelected : [])
        .accessibilityIdentifier("presentation_" + presentation.rawValue)
    }

    private var frequencyAxis: some View {
        HStack(spacing: 0) {
            Text("kHz").frame(width: 44)
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    ForEach(model.displayParameters.spectrumBand.axisTicksKHz, id: \.self) { value in
                        let band = model.displayParameters.spectrumBand
                        let x = geometry.size.width * CGFloat(Float(value * 1_000) - band.lowerHz)
                            / CGFloat(band.upperHz - band.lowerHz)
                        Text(String(value))
                            .frame(width: 28)
                            .position(x: min(max(14, x), max(14, geometry.size.width - 14)), y: 10)
                        Rectangle().fill(subdued.opacity(0.5))
                            .frame(width: 1, height: 5)
                            .position(x: x, y: 23)
                    }
                }
            }
            .frame(height: 26)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(subdued)
        .padding(.vertical, 4)
        .accessibilityLabel("Frequency axis, " + model.displayParameters.spectrumBand.displayName)
    }

    private var timeAxis: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("0 s")
            Spacer(minLength: 4)
            Text("AGE")
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .accessibilityHidden(true)
            Spacer(minLength: 4)
            Text(historyAgeText + " s")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(subdued)
        .padding(.vertical, 10)
        .frame(width: 44)
        .accessibilityLabel("Time axis, newest at top; \(historyAgeText) seconds of history")
    }

    private var fieldCaption: some View {
        VStack(spacing: 4) {
            Text(model.presentation == .waterfall ? "SAMPLE SPECTRUM · dBFS" : sourceIsSimulated ? "SYNTHETIC FIELD" : "ABSTRACT PHASE FIELD")
                .font(.caption2.weight(.bold))
                .tracking(1.2)
            Text(model.presentation == .waterfall ? "Newest at top · missing intervals are hatched" : "No spatial map or measured depth")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(InstrumentSurface(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var controlPanel: some View {
        VStack(spacing: 8) {
            Capsule().fill(.white.opacity(0.35)).frame(width: 34, height: 4)
                .accessibilityHidden(true)
            HStack {
                Label(panelTitle, systemImage: adjustment == .carrier ? "waveform" : adjustment == .display ? "slider.horizontal.3" : "chart.xyaxis.line")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(subdued)
                Spacer()
                if adjustment == .display { paletteMenu }
                Button { setControlsVisible(false) } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.09), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide instrument controls")
            }
            switch adjustment {
            case .carrier:
                if model.mode == .replay { replayPanel } else { carrierPanel }
            case .display:
                displayPanel
            case .readout:
                detailedReadout
            }
            HStack(spacing: 0) {
                adjustmentButton(.carrier, title: model.mode == .replay ? "Timeline" : "Carrier")
                adjustmentButton(.display, title: "Display")
                adjustmentButton(.readout, title: "Readout")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .modifier(InstrumentSurface(cornerRadius: 24))
    }

    private var carrierPanel: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center) {
                Button { model.stepCarrier(by: -1) } label: {
                    Image(systemName: "minus").frame(width: 44, height: 44)
                }
                .disabled(model.carrierFrequencyHz <= 18_000)
                .accessibilityLabel("Decrease carrier by 500 hertz")
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(carrierText)
                        .font(.largeTitle.monospacedDigit().weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Text("kHz").font(.callout)
                }
                .foregroundStyle(accent)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Carrier frequency")
                .accessibilityValue(carrierText + " kilohertz")
                .accessibilityAdjustableAction { direction in
                    if direction == .increment { model.stepCarrier(by: 1) }
                    if direction == .decrement { model.stepCarrier(by: -1) }
                }
                Spacer(minLength: 4)
                Button { model.stepCarrier(by: 1) } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                }
                .disabled(model.carrierFrequencyHz >= 22_000)
                .accessibilityLabel("Increase carrier by 500 hertz")
            }
            .buttonStyle(.plain)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(CarrierGrid.frequencies, id: \.self) { frequency in
                    VStack(spacing: 4) {
                        Rectangle()
                            .fill(frequency == model.carrierFrequencyHz ? accent : .white.opacity(0.38))
                            .frame(width: frequency == model.carrierFrequencyHz ? 2 : 1, height: frequency % 1_000 == 0 ? 16 : 10)
                        Text(frequency % 1_000 == 0 ? String(frequency / 1_000) : " ")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(subdued)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            Text("500 Hz steps · retuning establishes a new phase reference")
                .font(.caption2)
                .foregroundStyle(subdued)
                .multilineTextAlignment(.center)
        }
        .accessibilityIdentifier("carrierControls")
    }

    private var displayPanel: some View {
        VStack(spacing: 10) {
            Picker("Spectrum range", selection: $model.displayParameters.spectrumBand) {
                ForEach(SpectrumDisplayBand.allCases, id: \.rawValue) { band in
                    Text(band.displayName).tag(band)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("spectrumRangePicker")
            VStack(spacing: 0) {
                HStack {
                    Text("Display gain")
                    Spacer()
                    Text(signed(model.displayParameters.gainDB, places: 0) + " dB").foregroundStyle(accent)
                }
                Slider(value: $model.displayParameters.gainDB, in: -24...36, step: 1)
                    .accessibilityLabel("Display gain")
                    .accessibilityValue(signed(model.displayParameters.gainDB, places: 0) + " decibels")
            }
            VStack(spacing: 0) {
                HStack {
                    Text("Persistence")
                    Spacer()
                    Text(Int((model.displayParameters.persistence * 100).rounded()).formatted() + "%").foregroundStyle(accent)
                }
                Slider(value: $model.displayParameters.persistence, in: 0...1, step: 0.05)
                    .accessibilityLabel("Display persistence")
                    .accessibilityValue(Int((model.displayParameters.persistence * 100).rounded()).formatted() + " percent")
            }
            Text("Display only · recorded levels and simulation settings are unchanged")
                .font(.caption2)
                .foregroundStyle(subdued)
        }
        .font(.caption.monospacedDigit())
    }

    private var paletteMenu: some View {
        Menu {
            Picker("False-color palette", selection: $model.displayParameters.palette) {
                ForEach(ObservatoryPalette.allCases, id: \.rawValue) { palette in
                    Text(palette.displayName).tag(palette)
                }
            }
        } label: {
            Label(model.displayParameters.palette.displayName, systemImage: "circle.lefthalf.filled")
                .font(.caption)
        }
        .accessibilityLabel("False-color palette")
    }

    private var detailedReadout: some View {
        VStack(alignment: .leading, spacing: 8) {
            readoutRow("Phase-derived model", value: model.phaseDerivedDisplacementMillimeters.map { number($0, places: 2) + " mm" } ?? "Unavailable")
            readoutRow("Tone / residual", value: qualityText + " dB")
            readoutRow("Carrier amplitude", value: amplitudeText)
            readoutRow("Pose / depth", value: "Unavailable")
            Text(model.referenceMessage)
                .font(.caption2)
                .foregroundStyle(subdued)
            Text("\(model.replayCount.formatted()) / \(model.replayCapacity.formatted()) frames stored")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(subdued)
        }
    }

    private func readoutRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(subdued)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private var replayPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Text(model.replaySourceName).font(.headline).foregroundStyle(accent)
                Spacer()
                Text("\(model.replayCount == 0 ? 0 : model.replayIndex + 1) / \(model.replayCount)")
                    .font(.caption.monospacedDigit())
            }
            Slider(
                value: Binding(get: { Double(model.replayIndex) }, set: { model.selectReplayFrame(Int($0.rounded())) }),
                in: 0...Double(max(1, model.replayCount - 1)), step: 1
            )
            .disabled(model.replayCount < 2 || model.isFinishingProcessing)
            .accessibilityLabel("Replay frame")
            .accessibilityValue("\(model.replayIndex + 1) of \(model.replayCount)")
            HStack {
                Button { model.selectReplayFrame(model.replayIndex - 1) } label: {
                    Image(systemName: "backward.frame").frame(width: 44, height: 36)
                }
                .disabled(model.replayIndex == 0 || model.isFinishingProcessing)
                .accessibilityLabel("Previous replay frame")
                Spacer()
                Text("\(number(Double(model.displayedCarrierFrequencyHz) / 1_000, places: 1)) kHz · original source retained")
                    .font(.caption2).foregroundStyle(subdued)
                Spacer()
                Button { model.selectReplayFrame(model.replayIndex + 1) } label: {
                    Image(systemName: "forward.frame").frame(width: 44, height: 36)
                }
                .disabled(model.replayIndex + 1 >= model.replayCount || model.isFinishingProcessing)
                .accessibilityLabel("Next replay frame")
            }
            .buttonStyle(.plain)
        }
    }

    private func adjustmentButton(_ selection: Adjustment, title: String) -> some View {
        Button { adjustment = selection } label: {
            VStack(spacing: 5) {
                Text(title).font(.caption.weight(adjustment == selection ? .semibold : .regular))
                Capsule().fill(adjustment == selection ? accent : .clear).frame(width: 15, height: 3)
            }
            .foregroundStyle(adjustment == selection ? .white : subdued)
            .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(adjustment == selection ? .isSelected : [])
    }

    @ViewBuilder
    private var consentPanel: some View {
        if model.mode == .live && !model.isRunning {
            VStack(alignment: .leading, spacing: 7) {
                if model.liveIsSupported {
                    Toggle("I agree to a speaker tone and live microphone analysis.", isOn: $model.consentGiven)
                        .font(.caption)
                        .disabled(model.state != .idle)
                        .accessibilityIdentifier("experimentConsentToggle")
                    Text("18–22 kHz · built-in audio only · keep away from ears · 60 s max")
                        .font(.caption2)
                        .foregroundStyle(subdued)
                } else {
                    Label("LIVE requires a physical iPhone or iPad. DEMO is silent.", systemImage: "iphone")
                        .font(.caption)
                        .foregroundStyle(subdued)
                }
                if model.microphoneDenied {
                    Button("Open microphone settings") { model.openSettings() }
                        .font(.caption)
                }
            }
        }
    }

    private var transport: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                Button { setControlsVisible(!showControls) } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title3)
                            .frame(width: 48, height: 48)
                            .background(showControls ? accent.opacity(0.2) : Color(white: 0.12), in: Circle())
                        Text("Adjust").font(.caption2)
                    }
                    .foregroundStyle(showControls ? accent : .white)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showControls ? "Hide instrument controls" : "Show instrument controls")
                VStack(spacing: 5) {
                    Button(action: transportAction) {
                        ZStack {
                            Circle().stroke(.white.opacity(0.7), lineWidth: 2).frame(width: 74, height: 74)
                            Circle().fill(model.mode == .replay ? accent : Color(red: 0.94, green: 0.18, blue: 0.12))
                                .frame(width: 64, height: 64)
                            if model.mode == .replay {
                                Image(systemName: model.isReplaying ? "pause.fill" : "play.fill")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.black)
                            } else if model.isRunning || model.state == .preparing {
                                RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 25, height: 25)
                            } else if model.state == .requestingPermission {
                                ProgressView().tint(.white)
                            }
                        }
                        .opacity(transportEnabled ? 1 : 0.4)
                    }
                    .buttonStyle(.plain)
                    .disabled(!transportEnabled)
                    .accessibilityLabel(transportTitle)
                    .accessibilityIdentifier(model.isRunning ? "stopExperimentButton" : "startExperimentButton")
                    Text(transportTitle.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                }
                .frame(maxWidth: .infinity)
                Button { model.resetPhaseReference() } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "scope")
                            .font(.title3)
                            .frame(width: 48, height: 48)
                            .background(Color(white: 0.12), in: Circle())
                        Text("Reference").font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(!model.isRunning)
                .accessibilityLabel("Set a new phase reference")
                .accessibilityIdentifier("resetPhaseReferenceButton")
            }
            Text(model.message)
                .font(.caption2)
                .foregroundStyle(subdued)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if model.diagnosticSnapshot.pipeline.health == "inputStalled"
                || model.diagnosticSnapshot.pipeline.health == "processingStalled" {
                Button("Inspect pipeline diagnostics") { showDiagnostics = true }
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private func transportAction() {
        if model.mode == .replay { model.toggleReplay() }
        else if model.state != .idle { model.stopExperiment() }
        else { model.startExperiment() }
    }

    private var transportEnabled: Bool {
        model.canStart || model.isRunning || model.isReplaying || model.state == .requestingPermission || model.state == .preparing
    }
    private var transportTitle: String {
        if model.mode == .replay { return model.isReplaying ? "Pause" : "Play replay" }
        if model.state == .requestingPermission { return "Cancel" }
        return model.isRunning || model.state == .preparing ? "Stop" : "Record"
    }
    private var panelTitle: String {
        switch adjustment {
        case .carrier: return model.mode == .replay ? "Replay timeline" : "Acoustic carrier"
        case .display: return "Display adjustments"
        case .readout: return "Signal readout"
        }
    }
    private var sourceIsSimulated: Bool {
        model.latestSlice?.source == .simulated || (model.latestSlice == nil && model.mode == .demo)
    }
    private var sourceCaption: String {
        if model.mode == .replay {
            if model.latestSlice == nil { return "REPLAY · NO CAPTURE" }
            if model.presentation == .field {
                return sourceIsSimulated ? "REPLAY · DEMO SYNTHETIC" : "REPLAY · LIVE ABSTRACT"
            }
            return "REPLAY · " + model.replaySourceName.uppercased()
        }
        if sourceIsSimulated { return "DEMO · SYNTHETIC" }
        return model.presentation == .field ? "LIVE · ABSTRACT" : "LIVE · ACOUSTIC"
    }
    private var phaseText: String {
        guard let slice = model.latestSlice, slice.isPhaseCoherent, let phase = slice.unwrappedPhase else { return "—" }
        return signed(phase, places: 2)
    }
    private var qualityText: String {
        guard let slice = model.latestSlice, slice.validity != .nonFiniteInput else { return "—" }
        return number(Double(slice.coherenceSNR), places: 1)
    }
    private var amplitudeText: String {
        guard let slice = model.latestSlice, slice.validity != .nonFiniteInput else { return "Unavailable" }
        return number(Double(slice.normalizedAmplitude), places: 5)
    }
    private var carrierText: String { number(Double(model.displayedCarrierFrequencyHz) / 1_000, places: 1) }
    private var clockText: String {
        let seconds = Int(max(0, model.elapsedSeconds))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    private var historyAgeText: String {
        guard let oldest = model.spectrumHistory.first?.sampleTimestamp,
              let newest = model.latestSlice?.sampleTimestamp ?? model.latestSpectrum?.sampleTimestamp,
              newest >= oldest else { return "—" }
        return number(Double(newest - oldest) / 48_000, places: 1)
    }

    private func setControlsVisible(_ visible: Bool) {
        if reduceMotion { showControls = visible }
        else { withAnimation(.easeInOut(duration: 0.18)) { showControls = visible } }
    }
    private func number(_ value: Double, places: Int) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(places)))
    }
    private func signed(_ value: Float, places: Int) -> String {
        guard value.isFinite else { return "—" }
        return (value >= 0 ? "+" : "") + number(Double(value), places: places)
    }
}

private struct InstrumentSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: cornerRadius).fill(Color(white: 0.13))
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial)
                        .overlay { RoundedRectangle(cornerRadius: cornerRadius).fill(.black.opacity(0.2)) }
                }
            }
            .overlay { RoundedRectangle(cornerRadius: cornerRadius).stroke(.white.opacity(0.10), lineWidth: 0.7) }
    }
}

import Dispatch
import Foundation
import Metal
import MetalKit
import RheaRFCore
import SwiftUI
import UIKit

private enum MetalSetupError: Error {
    case unavailable
    case shaderUnavailable
    case textureUnavailable
}

/// Only immutable samples cross from acquisition to this main-actor renderer.
/// There is no render clock: every image is a function of captured/replayed data
/// and display controls. Pausing acquisition therefore freezes the image.
@MainActor
final class MetalPhaseRenderer: NSObject, MTKViewDelegate {
    private static let spectrumWidth = 512
    private static let maximumHistory = 256
    private static let lowerFrequency: Float = 18_000
    private static let upperFrequency: Float = 22_000

    /// Six float4 values: 96 bytes, each aligned to 16 bytes in Swift and MSL.
    /// Do not replace these fields with SIMD3 or Swift Bool values.
    private struct Uniforms {
        var signal: SIMD4<Float> = .zero
        var geometry: SIMD4<Float> = .zero
        var display: SIMD4<Float> = .zero
        var previousPhases: SIMD4<Float> = .zero
        var previousAmplitudes: SIMD4<Float> = .zero
        var mode: SIMD4<Float> = .zero
    }

    private struct FieldSample {
        let phase: Float
        let amplitude: Float
    }

    private struct HistoryIdentity: Equatable {
        // Capture timestamps may repeat after an interruption. A timestamp is
        // an axis coordinate, not a unique identity for a spectral record.
        let frames: [SpectrumFrame]
        let end: UInt64?
    }

    private struct CachedSpectrumRow {
        let frame: SpectrumFrame
        let pixels: [SIMD2<Float>]
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let inFlightFrames = DispatchSemaphore(value: 3)
    private weak var canvas: MTKView?
    private var redrawPending = false
    private var spectrumTexture: MTLTexture
    private var uniforms = Uniforms()
    private var fieldSamples: [FieldSample] = []
    private var lastTimestamp: UInt64?
    private var lastEpoch: UInt32?
    private var lastSource: UInt8?
    private var historyIdentity: HistoryIdentity?
    private var spectrumRows: [UInt64: CachedSpectrumRow] = [:]
    private var spectrumAvailable = false

    init(view: MTKView) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else { throw MetalSetupError.unavailable }
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "phaseVertexMain"),
              let fragmentFunction = library.makeFunction(name: "phaseFragmentMain")
        else { throw MetalSetupError.shaderUnavailable }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.device = device
        self.commandQueue = commandQueue
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg32Float, width: Self.spectrumWidth, height: 1, mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: textureDescriptor)
        else { throw MetalSetupError.textureUnavailable }
        spectrumTexture = texture
        super.init()
        canvas = view
        assert(MemoryLayout<Uniforms>.stride == 96)
        upload(Array(repeating: SIMD2<Float>(-160, 0), count: Self.spectrumWidth), height: 1)

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.016, green: 0.023, blue: 0.031, alpha: 1)
        view.framebufferOnly = true
        // Draw on data/UI changes, never on an independent animation timeline.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        view.isAccessibilityElement = true
    }

    func update(
        view: MTKView,
        slice: SpatioTemporalSlice?,
        spectrum: SpectrumFrame?,
        history: [SpectrumFrame],
        display: DisplayParameters,
        presentation: ObservatoryPresentation,
        active: Bool,
        reduceMotion: Bool
    ) {
        let newTimestamp = slice?.sampleTimestamp
        let contextChanged = slice?.epoch != lastEpoch || slice?.source.rawValue != lastSource
        let rewound = newTimestamp.map { timestamp in
            lastTimestamp.map { timestamp < $0 } ?? false
        } ?? false
        let newSample = newTimestamp != lastTimestamp || contextChanged
        if contextChanged || rewound {
            spectrumRows.removeAll(keepingCapacity: true)
            historyIdentity = nil
            fieldSamples.removeAll(keepingCapacity: true)
        }
        if newSample, slice?.didRebaseline == true || slice?.discontinuityDetected == true {
            fieldSamples.removeAll(keepingCapacity: true)
        }

        let phase = slice?.unwrappedPhase
        let phaseValid = slice?.isPhaseCoherent == true && phase?.isFinite == true
        let wrappedPhase = phaseValid
            ? (phase ?? 0).truncatingRemainder(dividingBy: 2 * .pi) : 0
        let rawAmplitude = slice?.normalizedAmplitude ?? 0
        let amplitude = rawAmplitude.isFinite ? min(max(rawAmplitude, 0), 1) : 0
        if phaseValid {
            if newSample || fieldSamples.isEmpty {
                fieldSamples.insert(FieldSample(phase: wrappedPhase, amplitude: amplitude), at: 0)
                if fieldSamples.count > 5 { fieldSamples.removeLast(fieldSamples.count - 5) }
            }
        } else {
            // Never carry a convincing-looking phase trail across an invalid frame.
            fieldSamples.removeAll(keepingCapacity: true)
        }
        lastTimestamp = newTimestamp
        lastEpoch = slice?.epoch
        lastSource = slice?.source.rawValue

        let gain = display.gainDB.isFinite ? min(max(display.gainDB, -60), 60) : 0
        let persistence = display.persistence.isFinite ? min(max(display.persistence, 0), 1) : 0
        let palette: Float = switch display.palette {
        case .aurora: 0
        case .thermal: 1
        case .monochrome: 2
        }
        uniforms.signal = SIMD4(wrappedPhase, phaseValid ? 1 : 0, amplitude,
                                slice?.source == .simulated ? 1 : 0)
        uniforms.display = SIMD4(gain, persistence, palette, active ? 1 : 0)
        uniforms.geometry.w = reduceMotion ? 1 : 0
        uniforms.previousPhases = .zero
        uniforms.previousAmplitudes = .zero
        for (index, sample) in fieldSamples.dropFirst().prefix(4).enumerated() {
            uniforms.previousPhases[index] = sample.phase
            uniforms.previousAmplitudes[index] = sample.amplitude
        }
        uniforms.mode.x = presentation == .waterfall ? 1 : 0
        if presentation == .waterfall {
            prepareWaterfall(history: history, spectrum: spectrum, endTimestamp: newTimestamp)
        }
        updateAccessibility(view: view, slice: slice, presentation: presentation,
                            phaseValid: phaseValid, active: active, reduceMotion: reduceMotion)
        view.setNeedsDisplay()
    }

    /// History is oldest-first. Texture row zero is newest. The vertical scale
    /// follows sample timestamps, so dropped capture intervals remain missing.
    private func prepareWaterfall(
        history: [SpectrumFrame], spectrum: SpectrumFrame?, endTimestamp: UInt64?
    ) {
        var byTimestamp: [UInt64: SpectrumFrame] = [:]
        for frame in history.suffix(Self.maximumHistory) {
            byTimestamp[frame.sampleTimestamp] = frame
        }
        // The explicit current spectrum takes precedence even when its sample
        // timestamp is identical to a different record already in history.
        if let spectrum { byTimestamp[spectrum.sampleTimestamp] = spectrum }
        let end = endTimestamp ?? spectrum?.sampleTimestamp ?? history.last?.sampleTimestamp
        var frames = byTimestamp.values.sorted { $0.sampleTimestamp < $1.sampleTimestamp }
        if let end { frames.removeAll { $0.sampleTimestamp > end } }
        frames = Array(frames.suffix(Self.maximumHistory))
        let identity = HistoryIdentity(frames: frames, end: end)
        guard identity != historyIdentity else { return }

        let retainedTimestamps = Set(frames.map(\.sampleTimestamp))
        spectrumRows = spectrumRows.filter { retainedTimestamps.contains($0.key) }
        for frame in frames where spectrumRows[frame.sampleTimestamp]?.frame != frame {
            spectrumRows[frame.sampleTimestamp] = CachedSpectrumRow(frame: frame, pixels: resample(frame))
        }

        guard let oldest = frames.first?.sampleTimestamp, let end, end >= oldest else {
            if upload(Array(repeating: SIMD2<Float>(-160, 0), count: Self.spectrumWidth), height: 1) {
                uniforms.mode.y = 1
                uniforms.mode.z = 0
                spectrumAvailable = false
                historyIdentity = identity
            }
            return
        }
        let span = Double(end - oldest)
        // Observatory acquisition uses nonoverlapping standard-size frames.
        let hop = Double(RadarConfiguration.standard.frameSize)
        let height = max(1, Int(min(Double(Self.maximumHistory), ceil(span / hop) + 1)))
        let rowStep = height > 1 ? span / Double(height - 1) : 0
        let tolerance = max(hop * 0.55, rowStep * 0.5)
        // The image positions each analysis frame at its timestamp. Its time
        // cell extends half a hop on either side. Preserve uncovered intervals
        // before nearest-row selection: otherwise downsampling can select valid
        // neighbours on both sides of a missing frame and erase the gap.
        let ages = frames.reversed().map { Double(end - $0.sampleTimestamp) }
        var missingIntervals: [Range<Double>] = []
        if let newestAge = ages.first, newestAge > hop * 0.5 {
            missingIntervals.append(0..<(newestAge - hop * 0.5))
        }
        for index in 1..<ages.count {
            let lower = ages[index - 1] + hop * 0.5
            let upper = ages[index] - hop * 0.5
            if lower < upper { missingIntervals.append(lower..<upper) }
        }
        var pixels = Array(repeating: SIMD2<Float>(-160, 0), count: Self.spectrumWidth * height)
        var sourceIndex = frames.count - 1
        var missingIndex = 0
        var hasValidPixels = false
        for row in 0..<height {
            let targetAge = rowStep * Double(row)
            let intervalStart = max(0, targetAge - rowStep * 0.5)
            let intervalEnd = min(span, targetAge + rowStep * 0.5)
            while missingIndex < missingIntervals.count,
                  missingIntervals[missingIndex].upperBound <= intervalStart {
                missingIndex += 1
            }
            // A compressed row containing any missing interval is explicitly
            // unavailable, rather than visually claiming continuous capture.
            if missingIndex < missingIntervals.count,
               missingIntervals[missingIndex].lowerBound < intervalEnd {
                continue
            }
            while sourceIndex > 0 {
                let here = Double(end - frames[sourceIndex].sampleTimestamp)
                let previous = Double(end - frames[sourceIndex - 1].sampleTimestamp)
                if abs(previous - targetAge) >= abs(here - targetAge) { break }
                sourceIndex -= 1
            }
            let age = Double(end - frames[sourceIndex].sampleTimestamp)
            guard abs(age - targetAge) <= tolerance,
                  let sourceRow = spectrumRows[frames[sourceIndex].sampleTimestamp]?.pixels
            else { continue }
            let offset = row * Self.spectrumWidth
            for column in 0..<Self.spectrumWidth {
                pixels[offset + column] = sourceRow[column]
                hasValidPixels = hasValidPixels || sourceRow[column].y > 0
            }
        }
        if upload(pixels, height: height) {
            uniforms.mode.y = Float(height)
            uniforms.mode.z = Float(frames.count)
            spectrumAvailable = hasValidPixels
            historyIdentity = identity
        }
    }

    /// Copies the actual immutable upload for renderer regression checks. This
    /// performs no GPU wait: the shared texture is only ever read after upload.
    func copyWaterfallPixels() -> (width: Int, height: Int, pixels: [SIMD2<Float>]) {
        let width = spectrumTexture.width
        let height = spectrumTexture.height
        var pixels = Array(repeating: SIMD2<Float>.zero, count: width * height)
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let address = buffer.baseAddress else { return }
            spectrumTexture.getBytes(
                address, bytesPerRow: width * MemoryLayout<SIMD2<Float>>.stride,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
            )
        }
        return (width, height, pixels)
    }

    /// Nearest measured FFT bins, not an illustrated or synthesized spectrum.
    /// Channel R holds original dBFS; G explicitly marks available data.
    private func resample(_ frame: SpectrumFrame) -> [SIMD2<Float>] {
        var row = Array(repeating: SIMD2<Float>(-160, 0), count: Self.spectrumWidth)
        let frequencies = frame.frequenciesHz
        let levels = frame.magnitudesDBFS
        guard frequencies.count == levels.count, frequencies.count >= 2,
              let first = frequencies.first, let last = frequencies.last,
              first.isFinite, last.isFinite, first < last
        else { return row }
        for index in 1..<frequencies.count {
            guard frequencies[index].isFinite, frequencies[index] > frequencies[index - 1]
            else { return row }
        }
        var lower = 0
        for column in 0..<Self.spectrumWidth {
            let frequency = Self.lowerFrequency + (Self.upperFrequency - Self.lowerFrequency)
                * Float(column) / Float(Self.spectrumWidth - 1)
            guard frequency >= first, frequency <= last else { continue }
            while lower + 1 < frequencies.count, frequencies[lower + 1] <= frequency {
                lower += 1
            }
            let upper = min(lower + 1, frequencies.count - 1)
            let nearest = frequency - frequencies[lower] <= frequencies[upper] - frequency
                ? lower : upper
            let level = levels[nearest]
            if level.isFinite {
                row[column] = SIMD2(level, 1)
            } else if level == -.infinity {
                // A mathematically silent bin is valid, unlike NaN/missing data.
                row[column] = SIMD2(-160, 1)
            }
        }
        return row
    }

    @discardableResult
    private func upload(_ pixels: [SIMD2<Float>], height: Int) -> Bool {
        // Never replace bytes in a texture that an earlier command buffer may
        // still be sampling. Submitted buffers retain their immutable texture;
        // the nonblocking in-flight limit bounds outstanding GPU resources.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg32Float, width: Self.spectrumWidth, height: height, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let replacement = device.makeTexture(descriptor: descriptor) else {
            uniforms.mode.z = 0
            spectrumAvailable = false
            return false
        }
        pixels.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            replacement.replace(
                region: MTLRegionMake2D(0, 0, Self.spectrumWidth, height), mipmapLevel: 0,
                withBytes: baseAddress, bytesPerRow: Self.spectrumWidth * MemoryLayout<SIMD2<Float>>.stride
            )
        }
        spectrumTexture = replacement
        return true
    }

    private func updateAccessibility(
        view: MTKView, slice: SpatioTemporalSlice?, presentation: ObservatoryPresentation,
        phaseValid: Bool, active: Bool, reduceMotion: Bool
    ) {
        let source: String
        if let slice {
            source = slice.source == .simulated ? "Simulated data" : "Microphone data"
        } else {
            source = "No samples"
        }
        let status = active ? "Updating from samples" : "Frozen"
        if presentation == .waterfall {
            view.accessibilityLabel = "Spectrum waterfall, 18 to 22 kilohertz"
            view.accessibilityValue = "\(source). \(status). Newest at top, oldest at bottom. "
                + (spectrumAvailable ? "Measured bins in dBFS. Missing intervals are hatched."
                    : "No spectrum available; hatched display.")
        } else {
            view.accessibilityLabel = slice?.source == .simulated
                ? "Synthetic demonstration field" : "Abstract single-probe phase display"
            view.accessibilityValue = "\(source). \(status). "
                + (phaseValid ? "Phase estimate available." : "Phase unavailable; hatched display.")
                + (reduceMotion ? " Reduced motion." : "")
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        guard inFlightFrames.wait(timeout: .now()) == .success else {
            redrawPending = true
            return
        }
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            inFlightFrames.signal()
            return
        }
        redrawPending = false
        let semaphore = inFlightFrames
        commandBuffer.addCompletedHandler { [weak self] _ in
            semaphore.signal()
            Task { @MainActor [weak self] in
                guard let self, self.redrawPending else { return }
                self.redrawPending = false
                self.canvas?.setNeedsDisplay()
            }
        }
        let width = max(Float(view.drawableSize.width), 1)
        let height = max(Float(view.drawableSize.height), 1)
        uniforms.geometry.x = width / height
        uniforms.geometry.y = width
        uniforms.geometry.z = height
        var frameUniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&frameUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(spectrumTexture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

@MainActor
final class ObservatoryCanvasView: UIView {
    private let metalView = MTKView(frame: .zero)
    private var renderer: MetalPhaseRenderer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = UIColor(red: 0.016, green: 0.023, blue: 0.031, alpha: 1)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        do { renderer = try MetalPhaseRenderer(view: metalView) }
        catch {
            metalView.isHidden = true
            let label = UILabel()
            label.text = "Visualization unavailable on this device.\nSignal summaries and controls remain available."
            label.textColor = UIColor(white: 0.75, alpha: 1)
            label.font = .preferredFont(forTextStyle: .callout)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) { nil }

    func update(
        slice: SpatioTemporalSlice?, spectrum: SpectrumFrame?, history: [SpectrumFrame],
        display: DisplayParameters, presentation: ObservatoryPresentation,
        active: Bool, reduceMotion: Bool
    ) {
        renderer?.update(view: metalView, slice: slice, spectrum: spectrum, history: history,
                         display: display, presentation: presentation, active: active, reduceMotion: reduceMotion)
    }
}

@MainActor
struct ObservatoryCanvas: UIViewRepresentable {
    let slice: SpatioTemporalSlice?
    let spectrum: SpectrumFrame?
    /// Oldest-first, matching ReplayTape's logical ordering.
    let history: [SpectrumFrame]
    let display: DisplayParameters
    let presentation: ObservatoryPresentation
    let active: Bool
    let reduceMotion: Bool

    func makeUIView(context: Context) -> ObservatoryCanvasView { ObservatoryCanvasView(frame: .zero) }

    func updateUIView(_ view: ObservatoryCanvasView, context: Context) {
        view.update(slice: slice, spectrum: spectrum, history: history, display: display,
                    presentation: presentation, active: active, reduceMotion: reduceMotion)
    }
}

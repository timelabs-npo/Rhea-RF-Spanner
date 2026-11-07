import Metal
import MetalKit
import SwiftUI
import UIKit

private enum MetalSetupError: Error {
    case unavailable
    case shaderUnavailable
}

/// UI and MTKViewDelegate calls are main-actor-only. DSP sends immutable telemetry
/// through ExperimentModel; the renderer never shares mutable state with audio.
@MainActor
final class MetalPhaseRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var phaseRadians: Float = 0
    private var valid = false
    private var active = false
    private var animate = false
    private var animationFrame: UInt64 = 0

    /// Two float4 values have identical 16-byte alignment in Swift and Metal.
    private struct Uniforms {
        var signal: SIMD4<Float>
        var geometry: SIMD4<Float>
    }

    init(view: MTKView) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else { throw MetalSetupError.unavailable }
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "phaseVertexMain"),
              let fragment = library.makeFunction(name: "phaseFragmentMain")
        else { throw MetalSetupError.shaderUnavailable }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.commandQueue = commandQueue
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.025, green: 0.04, blue: 0.06, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 30
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Abstract phase visualization"
    }

    func update(view: MTKView, phase: Double?, valid: Bool, active: Bool, reduceMotion: Bool) {
        if active != self.active { animationFrame = 0 }
        // Rendering does not need an unbounded unwrapped phase. Limit conversion
        // to Float without altering the numeric measurement shown in the UI.
        let wrapped = (phase ?? 0).truncatingRemainder(dividingBy: 2 * Double.pi)
        phaseRadians = wrapped.isFinite ? Float(wrapped) : 0
        self.valid = valid
        self.active = active
        animate = active && !reduceMotion
        view.isPaused = !animate
        view.enableSetNeedsDisplay = !animate
        view.accessibilityValue = active
            ? (valid ? "Experiment active, tone estimate available" : "Experiment active, signal quality gate not passed")
            : "Idle, microphone off"
        if !animate { view.setNeedsDisplay() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }
        if animate { animationFrame &+= 1 }
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        // A draw-frame clock drives this abstract animation. It is not a sensor
        // timestamp and is not presented as elapsed experiment time.
        let animationTime = Float(animationFrame % 1_800) / 30
        var uniforms = Uniforms(
            signal: SIMD4(phaseRadians, valid ? 1 : 0, active ? 1 : 0, animationTime),
            geometry: SIMD4(aspect, 0, 0, 0)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

@MainActor
final class PhaseCanvasView: UIView {
    private let metalView = MTKView(frame: .zero)
    private var renderer: MetalPhaseRenderer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = 20
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
            label.text = "Visualization unavailable on this device.\nNumeric phase estimates remain available during a supported experiment."
            label.textColor = .secondaryLabel
            label.font = .preferredFont(forTextStyle: .callout)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) { nil }

    func update(phase: Double?, valid: Bool, active: Bool, reduceMotion: Bool) {
        renderer?.update(view: metalView, phase: phase, valid: valid, active: active, reduceMotion: reduceMotion)
    }
}

@MainActor
struct PhaseCanvas: UIViewRepresentable {
    let phase: Double?
    let valid: Bool
    let active: Bool
    let reduceMotion: Bool

    func makeUIView(context: Context) -> PhaseCanvasView { PhaseCanvasView(frame: .zero) }

    func updateUIView(_ view: PhaseCanvasView, context: Context) {
        view.update(phase: phase, valid: valid, active: active, reduceMotion: reduceMotion)
    }
}

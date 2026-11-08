import RealityKit
import RheaRFCore
import SwiftUI
import UIKit

/// Text derived from the accepted policy snapshot. AR tracking quality alone
/// does not establish usable timing, a valid transform, or an accepted pose.
struct SpatialContextStatusPresentation {
    let trackingStatus: String
    let poseStatus: String
    let arCaptureClockStatus: String?

    init(snapshot: SpatialContextSnapshot) {
        switch snapshot.tracking {
        case .normal:
            trackingStatus = "AR tracking normal"
        case .unavailable:
            trackingStatus = "AR tracking unavailable"
        case .limited(let reason):
            let label: String
            switch reason {
            case .initializing: label = "initializing"
            case .excessiveMotion: label = "excessive motion"
            case .insufficientFeatures: label = "insufficient features"
            case .relocalizing: label = "relocalizing"
            case .unknown: label = "unknown reason"
            }
            trackingStatus = "AR tracking limited · " + label
        }

        if let reason = snapshot.poseUnavailableReason {
            let detail: String
            switch reason {
            case .awaitingFrames: detail = "waiting for AR frames"
            case .recoveringTracking:
                detail = "recovery requires \(SpatialContextPolicy.normalFramesRequiredForRecovery) consecutive usable frames"
            case .trackingUnavailable: detail = "AR tracking is not normal"
            case .missingTransform: detail = "camera transform missing"
            case .invalidTransform: detail = "camera transform invalid"
            case .timingInvalid: detail = "AR capture timing invalid"
            case .sequenceNotIncreasing: detail = "frame sequence did not advance"
            case .stale: detail = "frame arrival timed out"
            case .stopped: detail = "context is off"
            }
            poseStatus = "Local pose unavailable · " + detail
        } else if snapshot.tracking == .normal, snapshot.coordinateEpoch != nil,
                  snapshot.frame?.worldFromCamera != nil {
            poseStatus = "Local pose accepted · local session estimate"
        } else {
            poseStatus = "Local pose unavailable"
        }

        if let elapsed = snapshot.frame?.arCaptureElapsedSeconds, elapsed.isFinite, elapsed >= 0 {
            let seconds = elapsed.formatted(.number.precision(.fractionLength(2)))
            arCaptureClockStatus = "AR capture clock · \(seconds) s from first valid AR timestamp"
        } else {
            arCaptureClockStatus = nil
        }
    }
}

/// Presentation only. The coordinator places this beside existing LIVE Listen
/// readouts and owns all Start/Stop controls. No view callback starts a sensor.
@MainActor
struct SpatialContextView: View {
    @ObservedObject var controller: SpatialContextController

    var body: some View {
        let status = SpatialContextStatusPresentation(snapshot: controller.snapshot)
        VStack(alignment: .leading, spacing: 8) {
            Text(cameraStatus).font(.headline)
                .accessibilityIdentifier("spatialCameraStatus")
            SpatialContextPreview(controller: controller)
                .frame(minHeight: 180, idealHeight: 240)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Live camera context preview")
            Text(status.trackingStatus)
                .accessibilityIdentifier("spatialTrackingStatus")
            Text(status.poseStatus)
                .accessibilityIdentifier("spatialPoseStatus")
            if let epoch = controller.snapshot.coordinateEpoch {
                Text("Local coordinate epoch \(epoch)")
            } else {
                Text("Coordinate epoch unavailable")
            }
            if let matrix = controller.snapshot.frame?.worldFromCamera {
                let position = matrix.column3
                Text("Estimated camera position · local session meters")
                Text("x \(number(Double(position.x))) · y \(number(Double(position.y))) · z \(number(Double(position.z)))")
                    .monospacedDigit()
            } else {
                Text("Estimated camera position unavailable")
            }
            Text("Image-center scene depth · meters from camera plane")
            Text(depthStatus).accessibilityIdentifier("spatialDepthStatus")
            if let captureClock = status.arCaptureClockStatus {
                Text(captureClock)
            }
            if let age = controller.arrivalAgeSeconds {
                Text("Frame arrival age · \(number(age)) s (app scheduling clock)")
            }
            Text("Audio/pose timing not associated")
                .fontWeight(.semibold)
                .accessibilityIdentifier("spatialAssociationUnavailable")
            Text("Live context only. The app does not save or upload images, depth maps, feature points, or world maps. Camera position and depth do not locate sound or RF sources.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private var cameraStatus: String {
        switch controller.availability {
        case .requestingPermission: return "Context off · waiting for camera permission"
        case .ready: return "Context off · ready for explicit combined start"
        case .needsExplicitStart: return "Context off · tap Start again when ready"
        case .unsupported: return "Context off · camera tracking unsupported"
        case .denied: return "Context off · camera permission denied"
        case .restricted: return "Context off · camera permission restricted"
        case .unavailable: return "Context off · camera unavailable"
        case .off: return "Context off"
        case .active:
            switch controller.snapshot.lifecycle {
            case .starting: return "Starting"
            case .cameraActive: return "Camera active"
            case .off, .stopped: return "Context off"
            }
        }
    }

    private var depthStatus: String {
        guard let frame = controller.snapshot.frame else { return "Depth unavailable" }
        switch frame.depth {
        case .unavailable(let reason):
            switch reason {
            case .notRequested: return "Depth unavailable · not selected"
            case .unsupported: return "Depth unavailable · unsupported on this device"
            case .missingConfidence: return "Depth unavailable · confidence map missing"
            case .insufficientAcceptedSamples: return "Depth unavailable · fewer than five accepted pixels"
            case .missingDepth: return "Depth unavailable · current frame has no depth"
            case .unsupportedDepthFormat, .unsupportedConfidenceFormat:
                return "Depth unavailable · unsupported camera depth format"
            case .invalidDimensions, .invalidStride, .lockFailed, .missingBaseAddress, .invalidPatchSize:
                return "Depth unavailable · image-center patch could not be read"
            }
        case .available(let measurement):
            let category = measurement.confidence == .high ? "high" : "medium"
            return "\(number(Double(measurement.medianMeters))) m · \(measurement.acceptedSampleCount)/9 pixels · minimum \(category) categorical confidence"
        }
    }

    private func number(_ value: Double) -> String {
        guard value.isFinite else { return "Unavailable" }
        return value.formatted(.number.precision(.fractionLength(2)))
    }
}

/// The host can be constructed and inspected while entirely camera-free. Its
/// only update operation attaches the preview already owned by an explicit run.
@MainActor
struct SpatialContextPreview: UIViewRepresentable {
    let controller: SpatialContextController

    @MainActor
    final class Coordinator {
        weak var controller: SpatialContextController?
        var displayedRunID: SpatialRunID?
        init(controller: SpatialContextController) {
            self.controller = controller
            displayedRunID = controller.isSessionRunning ? controller.snapshot.runID : nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }

    func updateUIView(_ host: UIView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.displayedRunID = controller.isSessionRunning ? controller.snapshot.runID : nil
        let preview = controller.previewView
        for subview in host.subviews where subview !== preview { subview.removeFromSuperview() }
        guard let preview, preview.superview !== host else { return }
        preview.removeFromSuperview()
        preview.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            preview.topAnchor.constraint(equalTo: host.topAnchor),
            preview.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    static func dismantleUIView(_ host: UIView, coordinator: Coordinator) {
        coordinator.controller?.previewDetached(for: coordinator.displayedRunID)
        host.subviews.forEach { $0.removeFromSuperview() }
    }

    /// Shared by the native adapter and hosted construction fixture. RealityKit
    /// renders the feed, but ONLY the adapter's explicit session.run starts AR.
    static func makeARView() -> ARView {
        ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    }
}

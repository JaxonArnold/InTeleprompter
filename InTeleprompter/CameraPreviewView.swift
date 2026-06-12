import SwiftUI
import AVFoundation

/// Live camera preview backed by AVCaptureVideoPreviewLayer, kept upright in
/// every interface orientation via the device's rotation coordinator.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.coordinateRotation(for: device, layer: uiView.videoPreviewLayer)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }

    final class Coordinator {
        private var device: AVCaptureDevice?
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?

        /// (Re)binds the rotation coordinator whenever the active camera
        /// changes (initial configuration, camera flips).
        func coordinateRotation(for device: AVCaptureDevice?, layer: AVCaptureVideoPreviewLayer) {
            guard device !== self.device else { return }
            self.device = device
            observation = nil
            rotationCoordinator = nil
            guard let device else { return }

            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
            rotationCoordinator = coordinator
            observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                              options: [.initial, .new]) { [weak layer] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async {
                    guard let connection = layer?.connection,
                          connection.isVideoRotationAngleSupported(angle) else { return }
                    connection.videoRotationAngle = angle
                }
            }
        }
    }
}

import AVFoundation
import SwiftUI
import UIKit

struct PreviewInteractionPoint {
    let devicePoint: CGPoint
    let viewPoint: CGPoint
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: ((PreviewInteractionPoint) -> Void)?
    var onLongPress: ((PreviewInteractionPoint) -> Void)?
    var onRotationAngleChange: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onLongPress: onLongPress, onRotationAngleChange: onRotationAngleChange)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        view.isUserInteractionEnabled = true
        view.onRotationAngleChange = context.coordinator.onRotationAngleChange
        context.coordinator.previewView = view

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        let longPressGesture = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.45
        tapGesture.require(toFail: longPressGesture)

        view.addGestureRecognizer(tapGesture)
        view.addGestureRecognizer(longPressGesture)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }

        context.coordinator.onTap = onTap
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onRotationAngleChange = onRotationAngleChange
        context.coordinator.previewView = uiView
        uiView.onRotationAngleChange = context.coordinator.onRotationAngleChange
        uiView.syncOrientation()
    }

    final class Coordinator: NSObject {
        weak var previewView: PreviewView?
        var onTap: ((PreviewInteractionPoint) -> Void)?
        var onLongPress: ((PreviewInteractionPoint) -> Void)?
        var onRotationAngleChange: ((CGFloat) -> Void)?

        init(
            onTap: ((PreviewInteractionPoint) -> Void)?,
            onLongPress: ((PreviewInteractionPoint) -> Void)?,
            onRotationAngleChange: ((CGFloat) -> Void)?
        ) {
            self.onTap = onTap
            self.onLongPress = onLongPress
            self.onRotationAngleChange = onRotationAngleChange
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,
                  let previewView else { return }

            let layerPoint = gesture.location(in: previewView)
            let devicePoint = previewView.previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            let viewPoint = normalizedViewPoint(from: layerPoint, in: previewView.bounds.size)
            onTap?(PreviewInteractionPoint(devicePoint: devicePoint, viewPoint: viewPoint))
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let previewView else { return }

            let layerPoint = gesture.location(in: previewView)
            let devicePoint = previewView.previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            let viewPoint = normalizedViewPoint(from: layerPoint, in: previewView.bounds.size)
            onLongPress?(PreviewInteractionPoint(devicePoint: devicePoint, viewPoint: viewPoint))
        }

        private func normalizedViewPoint(from point: CGPoint, in size: CGSize) -> CGPoint {
            guard size.width > 0, size.height > 0 else {
                return CGPoint(x: 0.5, y: 0.5)
            }

            return CGPoint(
                x: min(max(point.x / size.width, 0), 1),
                y: min(max(point.y / size.height, 0), 1)
            )
        }
    }
}

final class PreviewView: UIView {
    var onRotationAngleChange: ((CGFloat) -> Void)?
    private var lastPublishedRotationAngle: CGFloat?

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Expected AVCaptureVideoPreviewLayer")
        }
        return layer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncOrientation()
    }

    func syncOrientation() {
        guard let connection = previewLayer.connection else {
            return
        }

        let angle = currentRotationAngle()
        guard connection.isVideoRotationAngleSupported(angle) else {
            return
        }

        if abs(connection.videoRotationAngle - angle) > 0.5 {
            connection.videoRotationAngle = angle
        }

        if lastPublishedRotationAngle != angle {
            lastPublishedRotationAngle = angle
            onRotationAngleChange?(angle)
        }
    }

    private func currentRotationAngle() -> CGFloat {
        if let interfaceOrientation = window?.windowScene?.interfaceOrientation {
            return interfaceOrientation.captureRotationAngle
        }

        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return UIInterfaceOrientation.landscapeRight.captureRotationAngle
        case .landscapeRight:
            return UIInterfaceOrientation.landscapeLeft.captureRotationAngle
        case .portraitUpsideDown:
            return UIInterfaceOrientation.portraitUpsideDown.captureRotationAngle
        default:
            return UIInterfaceOrientation.portrait.captureRotationAngle
        }
    }
}

private extension UIInterfaceOrientation {
    var captureRotationAngle: CGFloat {
        switch self {
        case .portrait:
            return 90
        case .portraitUpsideDown:
            return 270
        case .landscapeLeft:
            return 180
        case .landscapeRight:
            return 0
        default:
            return 90
        }
    }
}

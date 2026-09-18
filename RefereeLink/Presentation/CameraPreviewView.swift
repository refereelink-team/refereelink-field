import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession?

    func makeUIView(context: Context) -> PreviewContainerView {
        PreviewContainerView(session: session)
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.setSession(session)
    }
}

final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    init(session: AVCaptureSession?) {
        super.init(frame: .zero)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        setSession(session)
        accessibilityIdentifier = "camera.preview"
        isAccessibilityElement = true
        accessibilityLabel = "Camera preview"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }

    func setSession(_ session: AVCaptureSession?) {
        previewLayer.session = session
    }
}

struct CameraPlaceholderView: View {
    let cameraState: CameraCaptureState

    var body: some View {
        Label(title, systemImage: "camera.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.72), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("camera.placeholder")
    }

    private var title: String {
        switch cameraState {
        case .idle:
            return "相机尚未启动"
        case .requestingPermission:
            return "正在请求相机权限"
        case .ready:
            return "相机已准备"
        case .running:
            return "模拟器 Mock 相机"
        case .denied:
            return "相机权限被拒绝"
        case .failed:
            return "相机不可用"
        }
    }
}

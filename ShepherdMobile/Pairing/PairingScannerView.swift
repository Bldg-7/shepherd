import AVFoundation
import SwiftUI
import UIKit

/// The camera, reading QR codes inside the app (SHPHRD-77, "악성 QR"): a
/// pairing code is only ever read here, never by the system's Camera app
/// or a link. Asks for the camera the first time, and says how to turn it
/// back on when it was turned down.
struct PairingScannerView: View {
    /// Why the last code wasn't taken.
    let notice: String?
    let onCode: (String) -> Void
    @State private var access = CameraAccess.current
    @Environment(\.openURL) private var openURL

    enum CameraAccess {
        case undetermined
        case allowed
        case denied
        case unavailable

        static var current: CameraAccess {
            guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .allowed
            case .notDetermined: return .undetermined
            default: return .denied
            }
        }
    }

    var body: some View {
        switch access {
        case .allowed:
            QRCameraView(onCode: onCode)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) { instructions }
        case .undetermined:
            ProgressView()
                .task {
                    let granted = await AVCaptureDevice.requestAccess(for: .video)
                    access = granted ? .allowed : .denied
                }
        case .denied:
            ContentUnavailableView {
                Label("Camera Access Is Off", systemImage: "camera")
            } description: {
                Text("To scan the QR code the Mac shows, allow hrdrhrdrhrdr to use the camera in Settings.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        case .unavailable:
            ContentUnavailableView {
                Label("No Camera", systemImage: "camera")
            } description: {
                Text("This device has no camera to scan the Mac's QR code with.")
            }
        }
    }

    private var instructions: some View {
        VStack(spacing: 8) {
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
            }
            Text("On the Mac, open hrdrhrdrhrdr's Settings, then iPhone and iPad, Add Device…, and Show QR Code. Point the camera at the code.")
                .font(.footnote)
        }
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(16)
    }
}

/// An `AVCaptureSession` with a metadata output for QR codes, shown full
/// size.
private struct QRCameraView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRCameraController {
        let controller = QRCameraController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: QRCameraController, context: Context) {
        controller.onCode = onCode
    }
}

private final class QRCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: (String) -> Void = { _ in }
    private let session = AVCaptureSession()
    /// `startRunning` and `stopRunning` block, so they run here.
    private let sessionQueue = DispatchQueue(label: "QRCamera")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotation: AVCaptureDevice.RotationCoordinator?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
        rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        if let rotation, let connection = previewLayer?.connection,
           connection.isVideoRotationAngleSupported(rotation.videoRotationAngleForHorizonLevelPreview) {
            connection.videoRotationAngle = rotation.videoRotationAngleForHorizonLevelPreview
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        nonisolated(unsafe) let session = session
        sessionQueue.async { session.startRunning() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        nonisolated(unsafe) let session = session
        sessionQueue.async { session.stopRunning() }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let codes = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        // The delegate's queue is the main queue.
        MainActor.assumeIsolated {
            for code in codes { onCode(code) }
        }
    }
}

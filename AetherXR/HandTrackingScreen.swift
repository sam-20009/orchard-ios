import SwiftUI
import AVFoundation
import Vision
import UIKit
import ImageIO

struct HandTrackingScreen: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack(alignment: .topTrailing) {
            HandCameraRepresentable().ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 35))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.7))
            }.padding(22)
        }
        .background(.black)
        .statusBarHidden()
    }
}

private struct HandCameraRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> HandCameraController { HandCameraController() }
    func updateUIViewController(_ controller: HandCameraController, context: Context) {}
}

private final class HandCameraController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let preview = AVCaptureVideoPreviewLayer()
    private let dots = CAShapeLayer()
    private let worker = DispatchQueue(label: "AetherXR.Vision.Hands", qos: .userInitiated)
    private var lastFrame: CFTimeInterval = 0
    private let indicator = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        preview.videoGravity = .resizeAspectFill
        preview.session = session
        view.layer.addSublayer(preview)
        dots.fillColor = UIColor.systemPurple.cgColor
        dots.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor
        dots.lineWidth = 1
        view.layer.addSublayer(dots)
        indicator.text = "Solicitando acesso à câmera…"
        indicator.textColor = .white
        indicator.font = .systemFont(ofSize: 13, weight: .semibold)
        indicator.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        indicator.textAlignment = .center
        indicator.layer.cornerRadius = 12
        indicator.clipsToBounds = true
        view.addSubview(indicator)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async { if allowed { self?.configure() } else { self?.indicator.text = "Permissão da câmera negada" } }
            }
        default: indicator.text = "Ative a câmera nos Ajustes do iPhone"
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = view.bounds
        dots.frame = view.bounds
        indicator.frame = CGRect(x: 16, y: view.safeAreaInsets.top + 20,
                                 width: max(180, view.bounds.width - 90), height: 36)
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            indicator.text = "Câmera traseira indisponível"
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard session.canAddInput(input) else { session.commitConfiguration(); return }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: worker)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        worker.async { [weak self] in self?.session.startRunning() }
        indicator.text = "Procurando mãos…"
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrame > 0.07 else { return }
        lastFrame = now
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .right)
        guard (try? handler.perform([request])) != nil else { return }
        let observations = request.results ?? []
        let points = observations.flatMap { observation -> [CGPoint] in
            guard let map = try? observation.recognizedPoints(.all) else { return [] }
            return map.values.filter { $0.confidence > 0.4 }
                .map { CGPoint(x: $0.location.x, y: 1 - $0.location.y) }
        }
        DispatchQueue.main.async { [weak self] in self?.render(points, handCount: observations.count) }
    }

    private func render(_ points: [CGPoint], handCount: Int) {
        let path = UIBezierPath()
        for p in points {
            let x = p.x * view.bounds.width
            let y = p.y * view.bounds.height
            path.append(UIBezierPath(ovalIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)))
        }
        dots.path = path.cgPath
        indicator.text = "Mãos reconhecidas: \(handCount) • Pontos: \(points.count)"
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        worker.async { [weak self] in self?.session.stopRunning() }
    }
}

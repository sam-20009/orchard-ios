import SwiftUI
import CoreMotion
import SceneKit
import simd
import UIKit
import AVFoundation
import Vision
import ImageIO

@MainActor
final class HeadTracker: ObservableObject {
    @Published var orientation = SCNQuaternion(0, 0, 0, 1)
    @Published var status = "Aguardando sensores"
    private let manager = CMMotionManager()
    private var neutral: simd_quatd?
    private var smoothed: simd_quatd?
    var sensitivity: Double = 1.0

    func start() {
        guard manager.isDeviceMotionAvailable else { status = "Giroscópio indisponível"; return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] data, error in
            guard let self = self, let attitude = data?.attitude else { return }
            if let error = error { self.status = error.localizedDescription; return }
            let q = attitude.quaternion
            let current = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
            if self.neutral == nil { self.neutral = current }
            guard let neutral = self.neutral else { return }
            // Camera looks toward -Z. The phone is landscape in the headset.
            let basis = simd_quatd(angle: -.pi / 2, axis: simd_double3(0, 0, 1))
            let relative = basis * simd_inverse(current) * neutral * simd_inverse(basis)
            let amount = min(1.0, max(0.5, self.sensitivity))
            let target = simd_slerp(simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), relative, amount)
            let scaled = simd_slerp(self.smoothed ?? target, target, 0.28)
            self.smoothed = scaled
            self.orientation = SCNQuaternion(Float(scaled.imag.x), Float(scaled.imag.y),
                                             Float(scaled.imag.z), Float(scaled.real))
            self.status = "Giroscópio ativo"
        }
    }
    func recenter() { neutral = nil; smoothed = nil }
    func stop() { manager.stopDeviceMotionUpdates() }
}

struct StereoExperience: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tracker = HeadTracker()
    @StateObject private var hands = VRHandTracker()
    let ipd: Double
    let motionEnabled: Bool
    let sensitivity: Double
    let vignette: Bool
    let stereo: Bool
    let showGrid: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                HStack(spacing: 0) {
                    ZStack {
                        XRSceneView(eyeOffset: stereo ? -Float(ipd / 2000) : 0,
                                    rotation: motionEnabled ? tracker.orientation : SCNQuaternion(0,0,0,1), showGrid: showGrid)
                        HandSkeletonOverlay(hands: hands.points)
                    }
                    if stereo {
                        ZStack {
                            XRSceneView(eyeOffset: Float(ipd / 2000), rotation: motionEnabled ? tracker.orientation : SCNQuaternion(0,0,0,1), showGrid: showGrid)
                            HandSkeletonOverlay(hands: hands.points)
                        }
                    }
                }
                if stereo { Rectangle().fill(.black).frame(width: 4) }
                if vignette {
                    HStack(spacing: 0) {
                        RadialGradient(colors: [.clear, .clear, .black.opacity(0.7)], center: .center, startRadius: 20, endRadius: 240)
                        if stereo {
                            RadialGradient(colors: [.clear, .clear, .black.opacity(0.7)], center: .center, startRadius: 20, endRadius: 240)
                        }
                    }.allowsHitTesting(false)
                }
                HStack {
                    Button { dismiss() } label: {
                        Label("Sair", systemImage: "xmark").font(.caption.bold()).padding(12)
                            .background(.black.opacity(0.60), in: Capsule())
                    }
                    Spacer()
                    Text("\(tracker.status) • Mãos: \(hands.points.count)").font(.caption2).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button { tracker.recenter() } label: {
                        Image(systemName: "scope").padding(12)
                            .background(.black.opacity(0.60), in: Circle())
                    }
                }.foregroundStyle(.white).padding(.horizontal, 18).padding(.top, 14)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .statusBarHidden(true).persistentSystemOverlays(.hidden)
        .onAppear { tracker.sensitivity = sensitivity; if motionEnabled { tracker.start() }; hands.start(); requestOrientation(.landscape) }
        .onDisappear { tracker.stop(); hands.stop(); requestOrientation(.portrait) }
    }

    private func requestOrientation(_ allowed: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: allowed)) { _ in }
    }
}

struct XRSceneView: UIViewRepresentable {
    let eyeOffset: Float
    let rotation: SCNQuaternion
    let showGrid: Bool

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.scene = Self.makeWorld(showGrid: showGrid)
        view.rendersContinuously = true
        view.antialiasingMode = .multisampling2X
        let camera = SCNCamera()
        camera.fieldOfView = 92
        camera.zNear = 0.02
        let node = SCNNode()
        node.name = "camera"
        node.camera = camera
        node.position = SCNVector3(eyeOffset, 1.6, 0)
        view.scene?.rootNode.addChildNode(node)
        view.pointOfView = node
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard let node = view.pointOfView else { return }
        node.orientation = rotation
        node.position.x = eyeOffset
    }

    private static func makeWorld(showGrid: Bool) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.035, green: 0.018, blue: 0.10, alpha: 1)
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 850
        let light = SCNNode(); light.light = ambient; scene.rootNode.addChildNode(light)
        let floor = SCNFloor()
        floor.reflectivity = 0.08
        floor.firstMaterial?.diffuse.contents = UIColor(red: 0.07, green: 0.05, blue: 0.16, alpha: 1)
        let ground = SCNNode(geometry: floor)
        ground.position.y = 0
        scene.rootNode.addChildNode(ground)
        let portal = SCNTorus(ringRadius: 1.2, pipeRadius: 0.033)
        portal.firstMaterial?.diffuse.contents = UIColor(red: 0.57, green: 0.29, blue: 1.0, alpha: 1)
        portal.firstMaterial?.emission.contents = UIColor.systemPurple
        let ring = SCNNode(geometry: portal)
        ring.position = SCNVector3(0, 1.7, -3.2)
        scene.rootNode.addChildNode(ring)
        for i in 0..<32 {
            let star = SCNSphere(radius: CGFloat(0.01 + (Double(i % 3) * 0.003)))
            star.firstMaterial?.emission.contents = UIColor.white
            let item = SCNNode(geometry: star)
            item.position = SCNVector3(Float((i * 37) % 16 - 8), Float((i * 29) % 7 + 1), Float(-((i * 13) % 13 + 4)))
            scene.rootNode.addChildNode(item)
        }
        if showGrid {
            for p in -8...8 {
                let z = Float(p)
                let lineX = SCNBox(width: 16, height: 0.006, length: 0.009, chamferRadius: 0)
                lineX.firstMaterial?.diffuse.contents = UIColor.purple.withAlphaComponent(0.25)
                let x = SCNNode(geometry: lineX)
                x.position = SCNVector3(0, 0.012, z)
                scene.rootNode.addChildNode(x)
                let lineZ = SCNBox(width: 0.009, height: 0.006, length: 16, chamferRadius: 0)
                lineZ.firstMaterial?.diffuse.contents = UIColor.purple.withAlphaComponent(0.25)
                let zz = SCNNode(geometry: lineZ)
                zz.position = SCNVector3(z, 0.012, 0)
                scene.rootNode.addChildNode(zz)
            }
        }
        return scene
    }
}

// Experimental 2D landmarks replicated in both stereo views.
// They are not 3D hands and are not input for external games.
struct HandSkeletonOverlay: View {
    let hands: [[CGPoint]]
    var body: some View {
        Canvas { context, size in
            for points in hands {
                for point in points {
                    let center = CGPoint(x: (1 - point.x) * size.width, y: point.y * size.height)
                    context.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(.purple))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

@MainActor
final class VRHandTracker: NSObject, ObservableObject {
    @Published private(set) var points: [[CGPoint]] = []
    private let session = AVCaptureSession()
    private let worker = DispatchQueue(label: "AetherXR.VR.Hands", qos: .userInitiated)
    private var configured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in if granted { self?.configureAndStart() } }
            }
        default: points = []
        }
    }
    private func configureAndStart() {
        if !configured {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            session.sessionPreset = .vga640x480
            guard session.canAddInput(input) else { session.commitConfiguration(); return }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: worker)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            configured = true
        }
        let camera = session
        worker.async { if !camera.isRunning { camera.startRunning() } }
    }
    func stop() {
        let camera = session
        worker.async { if camera.isRunning { camera.stopRunning() } }
        points = []
    }
}

extension VRHandTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .right)
        guard (try? handler.perform([request])) != nil else { return }
        let found = (request.results ?? []).compactMap { hand -> [CGPoint]? in
            guard let landmarks = try? hand.recognizedPoints(.all) else { return nil }
            return landmarks.values.filter { $0.confidence > 0.45 }
                .map { CGPoint(x: $0.location.x, y: 1 - $0.location.y) }
        }
        Task { @MainActor [weak self] in self?.points = found }
    }
}

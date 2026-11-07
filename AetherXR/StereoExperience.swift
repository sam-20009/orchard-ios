import SwiftUI
import CoreMotion
import SceneKit
import simd
import UIKit

@MainActor
final class HeadTracker: ObservableObject {
    @Published var orientation = SCNQuaternion(0, 0, 0, 1)
    @Published var status = "Aguardando sensores"
    private let manager = CMMotionManager()
    private var neutral: simd_quatd?
    var sensitivity: Double = 1.0

    func start() {
        guard manager.isDeviceMotionAvailable else { status = "Giroscópio indisponível"; return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, error in
            guard let self = self, let attitude = data?.attitude else { return }
            if let error = error { self.status = error.localizedDescription; return }
            let q = attitude.quaternion
            let current = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
            if self.neutral == nil { self.neutral = current }
            guard let neutral = self.neutral else { return }
            let relative = simd_inverse(neutral) * current
            let scaled = simd_slerp(simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), relative, self.sensitivity)
            // Mapeamento experimental; orientação e ergonomia devem ser validadas no iPhone real.
            self.orientation = SCNQuaternion(Float(scaled.imag.x), Float(scaled.imag.y),
                                             Float(scaled.imag.z), Float(scaled.real))
            self.status = "Giroscópio ativo"
        }
    }
    func recenter() { neutral = nil }
    func stop() { manager.stopDeviceMotionUpdates() }
}

struct StereoExperience: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tracker = HeadTracker()
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
                    XRSceneView(eyeOffset: stereo ? -Float(ipd / 2000) : 0,
                                rotation: motionEnabled ? tracker.orientation : SCNQuaternion(0,0,0,1), showGrid: showGrid)
                    if stereo {
                        XRSceneView(eyeOffset: Float(ipd / 2000), rotation: motionEnabled ? tracker.orientation : SCNQuaternion(0,0,0,1), showGrid: showGrid)
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
                    Text(tracker.status).font(.caption2).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button { tracker.recenter() } label: {
                        Image(systemName: "scope").padding(12)
                            .background(.black.opacity(0.60), in: Circle())
                    }
                }.foregroundStyle(.white).padding(.horizontal, 18).padding(.top, 14)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .statusBarHidden(true).persistentSystemOverlays(.hidden)
        .onAppear { tracker.sensitivity = sensitivity; if motionEnabled { tracker.start() }; requestOrientation(.landscape) }
        .onDisappear { tracker.stop(); requestOrientation(.portrait) }
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

// SPDX-License-Identifier: GPL-2.0-or-later
import ARKit
import GameController
import SceneKit
import SwiftUI
import UIKit
import simd
import Vision

/// Runs beside Husk's Android runtime. This scene does not consume Android frames.
struct VRBoxLabTab: View {
    @State private var showing = false
    @ObservedObject private var runner = QemuRunner.shared
    @AppStorage("vrbox.ipdMM") private var ipd = 63.0

    var body: some View {
        NavigationView {
            Form {
                Section("Visor") {
                    Slider(value: $ipd, in: 55...72, step: 1) {
                        Text("Distância entre os olhos")
                    }
                    Text("Distância entre os olhos · \(Int(ipd)) mm")
                    Button("Abrir bancada no VR Box") { showing = true }
                        .disabled(!ARWorldTrackingConfiguration.isSupported || runner.isRunning)
                    if runner.isRunning { Text("Encerre o Android antes de abrir a bancada.") }
                }
                Section("Controles da bancada") {
                    Text("Faça pinça no centro para mover o painel ou no canto verde para mudar seu tamanho.")
                    Text("No controle: Y alterna o modo, A segura, X troca entre mover e redimensionar, B recentraliza e Menu fecha.")
                }
                Section("Compatibilidade") {
                    Text("A câmera traseira precisa ficar livre. A bancada tem imagem para os dois olhos e usa a câmera para rastrear cabeça e mão. Os apps Android continuam na biblioteca do Husk.")
                }
            }
            .navigationTitle("VR Box")
        }
        .navigationViewStyle(.stack)
        .fullScreenCover(isPresented: $showing) {
            VRBoxSurface(ipd: Float(ipd / 1000)) { showing = false }
                .ignoresSafeArea()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

private struct VRBoxSurface: UIViewControllerRepresentable {
    let ipd: Float
    let close: () -> Void

    func makeUIViewController(context: Context) -> VRBoxController {
        VRBoxController(ipd: ipd, close: close)
    }

    func updateUIViewController(_ controller: VRBoxController, context: Context) {}
}

private final class VRBoxController: UIViewController {
    private let ipd: Float
    private let close: () -> Void
    private let tracking = VRBoxTracking()

    private let scene = SCNScene()
    private let head = SCNNode()
    private let menuSpace = SCNNode()
    private let panel = SCNNode(geometry: SCNPlane(width: 0.40, height: 0.22))
    private let cursor = SCNNode(geometry: SCNSphere(radius: 0.005))
    private let panelDepth: Float = -0.62
    private var displayLink: CADisplayLink?
    private var active = false
    private var hasHeadPose = false
    private var needsCenter = true
    private var lastHand = -Double.infinity

    private enum Mode { case hand, controller }
    private enum Handle { case move, resize }
    private var mode = Mode.hand
    private var controllerHandle = Handle.move
    private var gamepadButtons = [false, false, false, false]
    private var gamepadNeedsRelease = true

    private struct Hold {
        let handle: Handle
        let start: SIMD2<Float>
        let origin: SIMD2<Float>
        let size: Float
    }
    private var hold: Hold?
    private var panelSize: Float = 1
    private var pinchActive = false
    private var pinchArmed = false
    private var aim: SIMD2<Float>?
    private var controllerAim = SIMD2<Float>.zero

    init(ipd: Float, close: @escaping () -> Void) {
        self.ipd = ipd
        self.close = close
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(ipd:close:)") }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscapeRight }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scene.background.contents = UIColor(red: 0.025, green: 0.038, blue: 0.077, alpha: 1)
        scene.rootNode.addChildNode(head)
        scene.rootNode.addChildNode(menuSpace)
        menuSpace.addChildNode(panel)
        menuSpace.addChildNode(cursor)
        panel.simdPosition.z = panelDepth
        panel.geometry?.firstMaterial?.lightingModel = .constant
        cursor.geometry?.firstMaterial?.lightingModel = .constant
        cursor.geometry?.firstMaterial?.diffuse.contents = UIColor.systemMint
        cursor.isHidden = true

        // Fixed reference markers let the wearer see the effect of head movement.
        for column in -2...2 {
            for row in -1...1 {
                let dot = SCNNode(geometry: SCNSphere(radius: 0.009))
                dot.geometry?.firstMaterial?.lightingModel = .constant
                dot.geometry?.firstMaterial?.diffuse.contents = UIColor.systemIndigo
                dot.position = SCNVector3(Float(column) * 0.22, Float(row) * 0.22, -1.6)
                menuSpace.addChildNode(dot)
            }
        }

        let eyes = UIStackView(arrangedSubviews: [-1.0 as Float, 1.0].map(makeEye))
        eyes.distribution = .fillEqually
        eyes.spacing = 2
        eyes.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(eyes)
        NSLayoutConstraint.activate([
            eyes.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            eyes.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            eyes.topAnchor.constraint(equalTo: view.topAnchor),
            eyes.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let buttons = UIStackView(arrangedSubviews: [
            button("Mãos / controle", #selector(toggleMode)),
            button("Centralizar", #selector(recenter)),
            button("Sair", #selector(leave)),
        ])
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            buttons.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])

        updateTexture()
        tracking.onPose = { [weak self] pose in self?.applyHead(pose) }
        tracking.onHand = { [weak self] sample in self?.applyHand(sample) }
        tracking.onFailure = { [weak self] error in
            guard let self = self, self.active else { return }
            let dialog = UIAlertController(title: "Rastreamento indisponível", message: error.localizedDescription, preferredStyle: .alert)
            dialog.addAction(UIAlertAction(title: "Voltar", style: .default) { _ in self.close() })
            self.present(dialog, animated: true)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        active = true
        HuskOrientation.set(.landscapeRight)
        tracking.start()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewWillDisappear(_ animated: Bool) {
        active = false
        displayLink?.invalidate()
        displayLink = nil
        tracking.pause()
        HuskOrientation.set(HuskOrientation.standard)
        super.viewWillDisappear(animated)
    }

    private func makeEye(_ sign: Float) -> SCNView {
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 51
        camera.camera?.zNear = 0.025
        camera.camera?.zFar = 12
        camera.position.x = sign * ipd / 2
        head.addChildNode(camera)
        let eye = SCNView(frame: .zero, options: nil)
        eye.scene = scene
        eye.pointOfView = camera
        eye.preferredFramesPerSecond = 60
        eye.isPlaying = true
        return eye
    }

    private func button(_ title: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func leave() { close() }

    @objc private func recenter() {
        needsCenter = true
        resetInput()
    }

    @objc private func toggleMode() {
        mode = mode == .hand ? .controller : .hand
        tracking.setHandEnabled(mode == .hand)
        resetInput()
        updateTexture()
    }

    private func resetInput() {
        hold = nil
        aim = nil
        pinchActive = false
        pinchArmed = false
        gamepadNeedsRelease = true
        cursor.isHidden = true
    }

    private func updateTexture() {
        let size = CGSize(width: 640, height: 352)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.058, green: 0.090, blue: 0.164, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemIndigo.setStroke()
            let border = UIBezierPath(roundedRect: CGRect(x: 8, y: 8, width: 624, height: 336), cornerRadius: 26)
            border.lineWidth = 5
            border.stroke()

            func draw(_ text: String, x: CGFloat, y: CGFloat, font: CGFloat, color: UIColor = .white) {
                (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                    .font: UIFont.systemFont(ofSize: font, weight: .semibold), .foregroundColor: color,
                ])
            }
            draw("SAMUEL  /  VR BOX", x: 35, y: 30, font: 27, color: .systemMint)
            draw(mode == .hand ? "Mãos" : "Controle Bluetooth", x: 35, y: 82, font: 51)
            draw("CENTRO · MOVER", x: 35, y: 184, font: 28)
            draw("BANCADA XR", x: 35, y: 278, font: 26, color: .lightGray)
            UIColor.systemMint.setFill()
            UIBezierPath(roundedRect: CGRect(x: 527, y: 245, width: 89, height: 85), cornerRadius: 15).fill()
            draw("↘", x: 551, y: 255, font: 50, color: .black)
        }
        panel.geometry?.firstMaterial?.diffuse.contents = image
    }

    private func applyHead(_ pose: simd_float4x4) {
        guard active else { return }
        head.simdTransform = pose
        hasHeadPose = true
        guard needsCenter else { return }
        menuSpace.simdTransform = pose
        panel.simdPosition = SIMD3<Float>(0, 0, panelDepth)
        controllerAim = .zero
        needsCenter = false
    }

    private func applyHand(_ sample: VRBoxHandSample?) {
        guard active, hasHeadPose, mode == .hand else { return }
        guard let sample = sample else { return }
        let inverse = simd_inverse(menuSpace.simdWorldTransform)
        let origin = inverse * sample.origin
        let ray = inverse * sample.ray
        guard ray.z < -0.05 else { return }
        let distance = (panelDepth - origin.z) / ray.z
        guard distance > 0, distance < 3 else { return }
        lastHand = ProcessInfo.processInfo.systemUptime
        let point = SIMD2<Float>(origin.x + distance * ray.x, origin.y + distance * ray.y)
        let filtered = aim.map { $0 + (point - $0) * 0.55 } ?? point
        let pressing = sample.gap < (pinchActive ? 0.40 : 0.27)
        updatePointer(filtered, pressing: pressing, forceHandle: nil)
    }

    @objc private func tick() {
        guard active else { return }
        if mode == .hand, ProcessInfo.processInfo.systemUptime - lastHand > 0.30 {
            resetInput()
        }
        guard let pad = GCController.controllers().compactMap({ $0.extendedGamepad }).first else {
            if mode == .controller { resetInput() }
            gamepadButtons = [false, false, false, false]
            return
        }
        let buttons = [pad.buttonY.isPressed, pad.buttonX.isPressed, pad.buttonB.isPressed, pad.buttonMenu.isPressed]
        let rising = zip(buttons, gamepadButtons).map { $0.0 && !$0.1 }
        gamepadButtons = buttons
        if rising[0] { toggleMode() }
        if rising[1], hold == nil {
            controllerHandle = controllerHandle == .move ? .resize : .move
        }
        if rising[2] { recenter() }
        if rising[3] { leave(); return }
        guard mode == .controller, hasHeadPose else { return }
        let pressing = pad.buttonA.isPressed
        if !pressing { gamepadNeedsRelease = false }
        let stick = SIMD2<Float>(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value)
        if simd_length(stick) > 0.13 {
            controllerAim += stick * 0.012
            controllerAim = SIMD2<Float>(clamp(controllerAim.x, -0.62, 0.62), clamp(controllerAim.y, -0.37, 0.37))
        }
        updatePointer(controllerAim, pressing: pressing && !gamepadNeedsRelease, forceHandle: controllerHandle)
    }

    private func updatePointer(_ point: SIMD2<Float>, pressing: Bool, forceHandle: Handle?) {
        aim = point
        cursor.simdPosition = SIMD3<Float>(point.x, point.y, panelDepth + 0.01)
        cursor.isHidden = false
        let center = SIMD2<Float>(panel.simdPosition.x, panel.simdPosition.y)
        let delta = point - center
        if pressing, !pinchActive, pinchArmed {
            let corner = SIMD2<Float>(0.16, -0.083) * panelSize
            let overCorner = simd_distance(delta, corner) < 0.052 * panelSize
            let overPanel = abs(delta.x) < 0.20 * panelSize && abs(delta.y) < 0.11 * panelSize
            if let handle = forceHandle ?? (overCorner ? .resize : (overPanel ? .move : nil)) {
                hold = Hold(handle: handle, start: point, origin: center, size: panelSize)
            }
        }
        pinchActive = pressing
        if !pressing {
            pinchArmed = true
            hold = nil
        }
        guard let hold = hold else { return }
        let travel = point - hold.start
        switch hold.handle {
        case .move:
            let target = hold.origin + travel
            panel.simdPosition = SIMD3<Float>(clamp(target.x, -0.39, 0.39), clamp(target.y, -0.23, 0.23), panelDepth)
        case .resize:
            panelSize = clamp(hold.size + (travel.x - travel.y) * 3.1, 0.65, 1.65)
            panel.simdScale = SIMD3<Float>(repeating: panelSize)
        }
    }

    private func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
        min(max(value, lower), upper)
    }
}


private struct VRBoxHandSample {
    let origin: SIMD4<Float>
    let ray: SIMD4<Float>
    let gap: Float
}

private final class VRBoxTracking: NSObject, ARSessionDelegate {
    private let tracking = ARSession()
    private let frameQueue = DispatchQueue(label: "vrbox.frames", qos: .userInteractive)
    private let visionQueue = DispatchQueue(label: "vrbox.hand", qos: .userInitiated)
    private let handRequest = VNDetectHumanHandPoseRequest()
    // These fields are read and written only on frameQueue.
    private var lastHandRequest = -Double.infinity
    private var handRequestRunning = false
    private var handEnabled = true

    var onPose: ((simd_float4x4) -> Void)?
    var onHand: ((VRBoxHandSample?) -> Void)?
    var onFailure: ((Error) -> Void)?

    override init() {
        super.init()
        tracking.delegate = self
        tracking.delegateQueue = frameQueue
        handRequest.maximumHandCount = 1
    }

    func setHandEnabled(_ enabled: Bool) {
        frameQueue.async { self.handEnabled = enabled }
    }

    func start() {
        let configuration = ARWorldTrackingConfiguration()
        if let format = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: {
            $0.framesPerSecond == 30 && $0.imageResolution.width <= 1920
        }) {
            configuration.videoFormat = format
        }
        tracking.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() { tracking.pause() }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let displayPose = simd_inverse(frame.camera.viewMatrix(for: .landscapeRight))
        DispatchQueue.main.async { [weak self] in self?.onPose?(displayPose) }

        guard handEnabled, !handRequestRunning, frame.timestamp - lastHandRequest >= 1.0 / 12 else { return }
        lastHandRequest = frame.timestamp
        handRequestRunning = true
        let image = frame.capturedImage
        let intrinsics = frame.camera.intrinsics
        let rawPose = frame.camera.transform
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            let sample = self.readHand(image, intrinsics: intrinsics, pose: rawPose)
            self.frameQueue.async { self.handRequestRunning = false }
            DispatchQueue.main.async { [weak self] in self?.onHand?(sample) }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }

    private func readHand(_ image: CVPixelBuffer, intrinsics: simd_float3x3, pose: simd_float4x4) -> VRBoxHandSample? {
        do {
            try VNImageRequestHandler(cvPixelBuffer: image, orientation: .up, options: [:]).perform([handRequest])
            guard let hand = handRequest.results?.first else { return nil }
            let index = try hand.recognizedPoint(.indexTip)
            let thumb = try hand.recognizedPoint(.thumbTip)
            let knuckle = try hand.recognizedPoint(.indexMCP)
            let wrist = try hand.recognizedPoint(.wrist)
            guard [index, thumb, knuckle, wrist].allSatisfy({ $0.confidence >= 0.45 }) else { return nil }
            let width = Float(CVPixelBufferGetWidth(image))
            let height = Float(CVPixelBufferGetHeight(image))
            func pixels(_ point: VNRecognizedPoint) -> SIMD2<Float> {
                SIMD2<Float>(Float(point.location.x) * width, (1 - Float(point.location.y)) * height)
            }
            let palm = simd_distance(pixels(wrist), pixels(knuckle))
            guard palm > 10 else { return nil }
            let tips = (pixels(index) + pixels(thumb)) * 0.5
            let direction = SIMD4<Float>((tips.x - intrinsics.columns.2.x) / intrinsics.columns.0.x,
                -(tips.y - intrinsics.columns.2.y) / intrinsics.columns.1.y, -1, 0)
            return VRBoxHandSample(origin: pose.columns.3, ray: pose * direction,
                gap: simd_distance(pixels(index), pixels(thumb)) / palm)
        } catch {
            return nil
        }
    }

}

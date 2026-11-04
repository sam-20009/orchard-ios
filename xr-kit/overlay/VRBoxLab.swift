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
    @State private var goToLibrary = false
    @ObservedObject private var runner = QemuRunner.shared
    @AppStorage("vrbox.ipdMM") private var ipd = 63.0
    @AppStorage("vrbox.distance") private var distance = 0.72
    @AppStorage("vrbox.largeText") private var largeText = false
    @AppStorage("vrbox.highContrast") private var highContrast = false
    @AppStorage("vrbox.lightMode") private var lightMode = true
    @AppStorage("vrbox.seated") private var seated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationView {
            Form {
                Section("Visor") {
                    Button("Abrir menu no VR Box") { showing = true }
                        .disabled(UIDevice.current.userInterfaceIdiom != .phone
                            || !ARWorldTrackingConfiguration.isSupported || runner.isRunning)
                    if runner.isRunning { Text("Encerre o Android antes de abrir o visor.") }
                    Slider(value: $ipd, in: 55...72, step: 1) { Text("Distância entre os olhos") }
                    Text("Distância entre os olhos · \(Int(ipd)) mm")
                    Slider(value: $distance, in: 0.55...1.0, step: 0.05) { Text("Distância do painel") }
                    Text("Distância do painel · \(Int((distance * 100).rounded())) cm")
                }
                Section("Conforto e desempenho") {
                    Toggle("Posição sentada", isOn: $seated)
                    Toggle("Texto maior", isOn: $largeText)
                    Toggle("Contraste alto", isOn: $highContrast)
                    Toggle("Modo leve · 30 fps", isOn: $lightMode)
                }
                Section("Como controlar") {
                    Text("Agarre o painel com uma pinça no fundo ou use o canto verde para redimensionar. Para ativar um botão, solte a pinça sobre ele.")
                    Text("No controle, Y alterna o modo, A confirma ou segura, X muda a ação, B recentraliza e Menu fecha.")
                }
                Section("Câmera e biblioteca") {
                    Text("Deixe a câmera traseira livre. O rastreamento é local e usa a câmera apenas com o visor aberto.")
                    Button("Abrir biblioteca Android") { Router.shared.tab = .library }
                }
            }
            .navigationTitle("VR Box")
        }
        .navigationViewStyle(.stack)
        .fullScreenCover(isPresented: $showing, onDismiss: {
            if goToLibrary {
                goToLibrary = false
                Router.shared.tab = .library
            }
        }) {
            VRBoxSurface(options: VRBoxOptions(
                ipd: Float(ipd / 1000), distance: Float(distance), large: largeText,
                contrast: highContrast, light: lightMode || ProcessInfo.processInfo.isLowPowerModeEnabled,
                seated: seated, reduceMotion: reduceMotion
            )) { openLibrary in
                goToLibrary = openLibrary
                showing = false
            }
            .ignoresSafeArea()
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
        }
    }
}

private struct VRBoxOptions {
    let ipd: Float
    let distance: Float
    let large: Bool
    let contrast: Bool
    let light: Bool
    let seated: Bool
    let reduceMotion: Bool
}

private struct VRBoxSurface: UIViewControllerRepresentable {
    let options: VRBoxOptions
    let close: (Bool) -> Void

    func makeUIViewController(context: Context) -> VRBoxController {
        VRBoxController(options: options, close: close)
    }

    func updateUIViewController(_ controller: VRBoxController, context: Context) {}
}

private final class VRBoxController: UIViewController {
    private let options: VRBoxOptions
    private let close: (Bool) -> Void
    private let tracking: VRBoxTracking

    private let scene = SCNScene()
    private let head = SCNNode()
    private let menuSpace = SCNNode()
    private let panel = SCNNode(geometry: SCNPlane(width: CGFloat(VRBoxMenu.width), height: CGFloat(VRBoxMenu.height)))
    private let cursor = SCNNode(geometry: SCNSphere(radius: 0.005))
    private var panelDepth: Float { -options.distance }
    private var displayLink: CADisplayLink?
    private var active = false
    private var hasHeadPose = false
    private var needsCenter = true
    private var lastHand = -Double.infinity
    private var quality = VRBoxTrackingQuality.initializing
    private var help = false
    private var focus: VRBoxMenuTarget?
    private var pressedAction: VRBoxMenuAction?
    private var hasGamepad = false
    private var hasHand = false
    private var undoLayout: (center: SIMD2<Float>, scale: Float)?

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
        var moved = false
    }
    private var hold: Hold?
    private var panelSize: Float = 1
    private var pinchActive = false
    private var pinchArmed = false
    private var aim: SIMD2<Float>?
    private var controllerAim = SIMD2<Float>.zero

    init(options: VRBoxOptions, close: @escaping (Bool) -> Void) {
        self.options = options
        self.close = close
        self.tracking = VRBoxTracking(handInterval: options.light ? 0.1 : 1.0 / 12)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(options:close:)") }

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
        if !options.reduceMotion { addReferenceGrid() }

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
        tracking.onPose = { [weak self] pose, quality in self?.applyHead(pose, quality: quality) }
        tracking.onHand = { [weak self] sample in self?.applyHand(sample) }
        tracking.onQuality = { [weak self] quality in self?.updateQuality(quality) }
        tracking.onFailure = { [weak self] error in
            guard let self = self, self.active else { return }
            let dialog = UIAlertController(title: "Rastreamento indisponível", message: error.localizedDescription, preferredStyle: .alert)
            dialog.addAction(UIAlertAction(title: "Voltar", style: .default) { _ in self.close(false) })
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

    private func addReferenceGrid() {
        for column in -2...2 {
            for row in -1...1 {
                let dot = SCNNode(geometry: SCNSphere(radius: 0.009))
                dot.geometry?.firstMaterial?.lightingModel = .constant
                dot.geometry?.firstMaterial?.diffuse.contents = UIColor.systemIndigo
                dot.position = SCNVector3(Float(column) * 0.22, Float(row) * 0.22, -1.6)
                menuSpace.addChildNode(dot)
            }
        }
    }

    private func makeEye(_ sign: Float) -> SCNView {
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 51
        camera.camera?.zNear = 0.025
        camera.camera?.zFar = 12
        camera.position.x = sign * options.ipd / 2
        head.addChildNode(camera)
        let eye = SCNView(frame: .zero, options: nil)
        eye.scene = scene
        eye.pointOfView = camera
        eye.preferredFramesPerSecond = options.light ? 30 : 60
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

    @objc private func leave() { close(false) }

    @objc private func recenter() {
        needsCenter = true
        resetInput()
    }

    @objc private func toggleMode() {
        mode = mode == .hand ? .controller : .hand
        hasHand = false
        tracking.setHandEnabled(mode == .hand)
        resetInput()
        updateTexture()
    }

    private func resetInput() {
        let redraw = focus != nil || pinchActive
        hold = nil
        aim = nil
        focus = nil
        pressedAction = nil
        pinchActive = false
        pinchArmed = false
        gamepadNeedsRelease = true
        cursor.isHidden = true
        if redraw { updateTexture() }
    }

    private func updateTexture() {
        let status: String
        if quality == .normal && mode == .controller && !hasGamepad {
            status = "Conecte um controle Bluetooth"
        } else if quality == .normal && mode == .hand && !hasHand {
            status = "Mostre uma mão à câmera"
        } else {
            status = quality.rawValue
        }
        let hint: String
        if help {
            hint = mode == .hand ? "Pinça no fundo move · pinça no canto ajusta" : "A confirma ou segura · B centraliza"
        } else {
            hint = mode == .hand ? "Aponte, faça pinça e solte para selecionar" :
                (controllerHandle == .move ? "Analógico move o foco · A segura · X ajusta" : "A segura · analógico ajusta · X volta")
        }
        panel.geometry?.firstMaterial?.diffuse.contents = VRBoxMenu.image(
            mode: mode == .hand ? "Controles com a mão" : "Controle Bluetooth",
            status: status, hint: hint, focus: focus, pressed: pinchActive,
            help: help, canUndo: undoLayout != nil, large: options.large, contrast: options.contrast
        )
    }

    private func updateQuality(_ next: VRBoxTrackingQuality) {
        guard active, quality != next else { return }
        quality = next
        if next != .normal {
            hasHand = false
            resetInput()
        }
        updateTexture()
    }

    private func applyHead(_ pose: simd_float4x4, quality: VRBoxTrackingQuality) {
        guard active else { return }
        updateQuality(quality)
        guard quality == .normal else { return }
        head.simdTransform = pose
        hasHeadPose = true
        guard needsCenter else { return }
        menuSpace.simdTransform = pose
        let y: Float = options.seated ? -0.045 : 0
        panel.simdPosition = SIMD3<Float>(0, y, panelDepth)
        controllerAim = SIMD2<Float>(0, y)
        needsCenter = false
    }

    private func perform(_ action: VRBoxMenuAction) {
        switch action {
        case .mode:
            toggleMode()
        case .center:
            recenter()
        case .undo:
            guard let previous = undoLayout else { return }
            panelSize = previous.scale
            panel.simdScale = SIMD3<Float>(repeating: panelSize)
            panel.simdPosition = SIMD3<Float>(previous.center.x, previous.center.y, panelDepth)
            undoLayout = nil
        case .help:
            help.toggle()
        case .library:
            close(true)
        case .exit:
            close(false)
        }
        updateTexture()
    }

    private func applyHand(_ sample: VRBoxHandSample?) {
        guard active, hasHeadPose, quality == .normal, mode == .hand else { return }
        guard let sample = sample else { return }
        let inverse = simd_inverse(menuSpace.simdWorldTransform)
        let origin = inverse * sample.origin
        let ray = inverse * sample.ray
        guard ray.z < -0.05 else { return }
        let distance = (panelDepth - origin.z) / ray.z
        guard distance > 0, distance < 3 else { return }
        lastHand = ProcessInfo.processInfo.systemUptime
        if !hasHand {
            hasHand = true
            updateTexture()
        }
        let point = SIMD2<Float>(origin.x + distance * ray.x, origin.y + distance * ray.y)
        let filtered = aim.map { $0 + (point - $0) * 0.55 } ?? point
        let pressing = sample.gap < (pinchActive ? 0.40 : 0.27)
        updatePointer(filtered, pressing: pressing, forceHandle: nil)
    }

    @objc private func tick() {
        guard active else { return }
        if mode == .hand, hasHand, ProcessInfo.processInfo.systemUptime - lastHand > 0.30 {
            hasHand = false
            resetInput()
            updateTexture()
        }
        let pad = GCController.controllers().compactMap { $0.extendedGamepad }.first
        if hasGamepad != (pad != nil) {
            hasGamepad = pad != nil
            updateTexture()
        }
        guard let pad = pad else {
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
            updateTexture()
        }
        if rising[2] { recenter() }
        if rising[3] { leave(); return }
        guard mode == .controller, hasHeadPose, quality == .normal else { return }
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
        let target = VRBoxMenu.target(offset: point - center, scale: panelSize, undo: undoLayout != nil)
        let needsRedraw = target != focus || pressing != pinchActive
        focus = target

        if pressing, !pinchActive, pinchArmed {
            switch target {
            case .some(.action(let action)):
                pressedAction = action
            case .some(.corner):
                hold = Hold(handle: .resize, start: point, origin: center, size: panelSize)
            case .some(.grip), .none:
                if let handle = forceHandle ?? (target == .grip ? .move : nil) {
                    hold = Hold(handle: handle, start: point, origin: center, size: panelSize)
                }
            }
        }
        pinchActive = pressing
        if !pressing {
            pinchArmed = true
            hold = nil
            let action = pressedAction
            pressedAction = nil
            if let action = action, target == .action(action) {
                perform(action)
                return
            }
        }
        if needsRedraw { updateTexture() }
        guard let hold = hold else { return }
        let travel = point - hold.start
        if !hold.moved {
            guard simd_length(travel) >= 0.006 else { return }
            self.hold?.moved = true
            undoLayout = (hold.origin, hold.size)
            updateTexture()
        }
        let newCenter: SIMD2<Float>
        switch hold.handle {
        case .move:
            newCenter = hold.origin + travel
        case .resize:
            let diagonal = SIMD2<Float>(VRBoxMenu.width, -VRBoxMenu.height)
            let growth = simd_dot(travel, diagonal) / simd_length_squared(diagonal)
            panelSize = clamp(hold.size + growth, 0.65, 1.65)
            panel.simdScale = SIMD3<Float>(repeating: panelSize)
            // Keep the opposite (top-left) corner anchored while resizing.
            newCenter = hold.origin + SIMD2<Float>(VRBoxMenu.width / 2, -VRBoxMenu.height / 2)
                * (panelSize - hold.size)
        }
        panel.simdPosition = SIMD3<Float>(
            clamp(newCenter.x, -0.39, 0.39), clamp(newCenter.y, -0.23, 0.23), panelDepth
        )
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
    private let handInterval: Double
    // These fields are read and written only on frameQueue.
    private var lastHandRequest = -Double.infinity
    private var handRequestRunning = false
    private var handEnabled = true

    var onPose: ((simd_float4x4, VRBoxTrackingQuality) -> Void)?
    var onQuality: ((VRBoxTrackingQuality) -> Void)?
    var onHand: ((VRBoxHandSample?) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(handInterval: Double) {
        self.handInterval = handInterval
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
        let quality: VRBoxTrackingQuality
        switch frame.camera.trackingState {
        case .normal: quality = .normal
        case .notAvailable: quality = .unavailable
        case .limited(.initializing): quality = .initializing
        case .limited(.excessiveMotion): quality = .motion
        case .limited(.insufficientFeatures): quality = .features
        case .limited(.relocalizing): quality = .recovering
        case .limited: quality = .recovering
        @unknown default: quality = .unavailable
        }
        DispatchQueue.main.async { [weak self] in self?.onPose?(displayPose, quality) }

        guard quality == .normal, handEnabled, !handRequestRunning, frame.timestamp - lastHandRequest >= handInterval else { return }
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

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in self?.onQuality?(.recovering) }
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

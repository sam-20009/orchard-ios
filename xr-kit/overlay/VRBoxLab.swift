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
    @AppStorage("vrbox.cameraOnEntry") private var cameraOnEntry = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Samuel VR Box", systemImage: "visionpro")
                            .font(.title2.bold())
                        Text("Visor experimental para iPhone")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Image(systemName: runner.isRunning ? "circle.fill" : "circle.dotted")
                                .foregroundStyle(runner.isRunning ? Color.green : Color.orange)
                            Text(runner.isRunning ? "Android em execução" : "Android não iniciado")
                                .font(.caption.weight(.semibold))
                        }
                        Text("A bancada VR usa ARKit e funciona separadamente do Android. Roblox VR ainda requer um runtime OpenXR compatível.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
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
                    Text("Mantenha a mão aberta diante da câmera por um instante ou aperte RB para esconder ou mostrar o painel.")
                    Text("No controle, Y alterna o modo, A confirma ou segura, X muda a ação, B recentraliza, LB alterna a câmera e Menu fecha.")
                }
                Section("Câmera e biblioteca") {
                    Toggle("Mostrar ambiente ao abrir o visor", isOn: $cameraOnEntry)
                    Text("Deixe a câmera traseira livre. A imagem é exibida nos dois olhos e fica no iPhone. Experimente com o visor enquanto estiver parado.")
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
                seated: seated, reduceMotion: reduceMotion, cameraOnEntry: cameraOnEntry
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
    let cameraOnEntry: Bool
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
    private let virtualBackground = UIColor(red: 0.025, green: 0.038, blue: 0.077, alpha: 1)
    private weak var firstEye: SCNView?
    private var showCamera = false
    private var wantsEnvironmentOnly = false
    private var palmToggle = VRBoxPalmToggle()
    private weak var toolbar: UIStackView?
    private let revealButton = UIButton(type: .custom)
    private var cameraEpoch = 0
    private var cameraViewport: CGSize?
    private var lastCameraFrame: Double?
    private let head = SCNNode()
    private let menuSpace = SCNNode()
    private let referenceSpace = SCNNode()
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
    private var gamepadButtons: [Bool]?
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
        self.tracking = VRBoxTracking(handInterval: options.light ? 0.1 : 1.0 / 12,
            previewInterval: options.light ? 1.0 / 16 : 1.0 / 31,
            previewResolution: options.light ? 640 : 800)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(options:close:)") }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscapeRight }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scene.background.contents = virtualBackground
        scene.background.minificationFilter = .linear
        scene.background.magnificationFilter = .linear
        scene.rootNode.addChildNode(head)
        head.addChildNode(menuSpace)
        scene.rootNode.addChildNode(referenceSpace)
        menuSpace.addChildNode(panel)
        menuSpace.addChildNode(cursor)
        panel.simdPosition.z = panelDepth
        panel.geometry?.firstMaterial?.lightingModel = .constant
        cursor.geometry?.firstMaterial?.lightingModel = .constant
        cursor.geometry?.firstMaterial?.diffuse.contents = UIColor.systemMint
        cursor.isHidden = true

        // Fixed reference markers let the wearer see the effect of head movement.
        if !options.reduceMotion { addReferenceGrid() }

        let leftEye = makeEye(-1)
        firstEye = leftEye
        let eyes = UIStackView(arrangedSubviews: [leftEye, makeEye(1)])
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
            button("Câmera", #selector(toggleCamera)),
            button("Ocultar painel", #selector(togglePanel)),
            button("Sair", #selector(leave)),
        ])
        toolbar = buttons
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            buttons.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])

        revealButton.isHidden = true
        revealButton.accessibilityLabel = "Mostrar painel"
        revealButton.addTarget(self, action: #selector(togglePanel), for: .touchUpInside)
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(revealButton)
        NSLayoutConstraint.activate([
            revealButton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            revealButton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            revealButton.topAnchor.constraint(equalTo: view.topAnchor),
            revealButton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        updateTexture()
        tracking.onPose = { [weak self] pose, quality in self?.applyHead(pose, quality: quality) }
        tracking.onHand = { [weak self] sample, time in self?.applyHand(sample, capturedAt: time) }
        tracking.onQuality = { [weak self] quality in self?.updateQuality(quality) }
        tracking.onPreview = { [weak self] image, epoch, capturedAt in
            self?.applyCameraFrame(image, epoch: epoch, capturedAt: capturedAt)
        }
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
        wantsEnvironmentOnly = false
        palmToggle = VRBoxPalmToggle()
        HuskOrientation.set(.landscapeRight)
        tracking.start()
        showCamera = options.cameraOnEntry
        updateCameraViewport()
        updatePanelPresentation()
        updateTexture()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewWillDisappear(_ animated: Bool) {
        active = false
        updateCameraViewport()
        displayLink?.invalidate()
        displayLink = nil
        tracking.pause()
        HuskOrientation.set(HuskOrientation.standard)
        super.viewWillDisappear(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateCameraViewport()
    }

    private func addReferenceGrid() {
        for column in -2...2 {
            for row in -1...1 {
                let dot = SCNNode(geometry: SCNSphere(radius: 0.009))
                dot.geometry?.firstMaterial?.lightingModel = .constant
                dot.geometry?.firstMaterial?.diffuse.contents = UIColor.systemIndigo
                dot.position = SCNVector3(Float(column) * 0.22, Float(row) * 0.22, -1.6)
                referenceSpace.addChildNode(dot)
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

    @objc private func toggleCamera() {
        showCamera.toggle()
        if !showCamera { wantsEnvironmentOnly = false }
        updateCameraViewport()
        updatePanelPresentation()
        updateTexture()
    }

    @objc private func togglePanel() {
        wantsEnvironmentOnly.toggle()
        if wantsEnvironmentOnly && !showCamera {
            showCamera = true
            updateCameraViewport()
        }
        updatePanelPresentation()
        updateTexture()
    }

    private func updatePanelPresentation() {
        // Keep controls visible until a fresh camera frame is available.
        let hidden = wantsEnvironmentOnly && lastCameraFrame != nil
        if panel.isHidden != hidden {
            panel.isHidden = hidden
            toolbar?.isHidden = hidden
            revealButton.isHidden = !hidden
            resetInput()
        }
        referenceSpace.isHidden = showCamera
    }

    private func updateCameraViewport() {
        let eyeSize = firstEye?.bounds.size
        let size = active && showCamera && (eyeSize?.width ?? 0) >= 2 && (eyeSize?.height ?? 0) >= 2
            ? eyeSize : nil
        guard size != cameraViewport else { return }
        cameraViewport = size
        cameraEpoch += 1
        lastCameraFrame = nil
        scene.background.contents = virtualBackground
        tracking.setPreviewViewport(size, epoch: cameraEpoch)
        updatePanelPresentation()
    }

    private func applyCameraFrame(_ image: CGImage, epoch: Int, capturedAt: Double) {
        guard active, showCamera, epoch == cameraEpoch,
            ProcessInfo.processInfo.systemUptime - capturedAt < 0.30 else { return }
        let wasWaiting = lastCameraFrame == nil
        lastCameraFrame = capturedAt
        scene.background.contents = image
        if wasWaiting {
            updatePanelPresentation()
            updateTexture()
        }
    }

    @objc private func recenter() {
        needsCenter = true
        resetInput()
    }

    @objc private func toggleMode() {
        mode = mode == .hand ? .controller : .hand
        hasHand = false
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
            hint = "Palma aberta ou RB: ocultar / mostrar painel"
        } else {
            hint = mode == .hand ? "Aponte, faça pinça e solte para selecionar" :
                (controllerHandle == .move ? "Analógico move o foco · A segura · X ajusta" : "A segura · analógico ajusta · X volta")
        }
        panel.geometry?.firstMaterial?.diffuse.contents = VRBoxMenu.image(
            mode: mode == .hand ? "Controles com a mão" : "Controle Bluetooth",
            status: status, hint: hint, focus: focus, pressed: pinchActive,
            help: help, canUndo: undoLayout != nil, large: options.large, contrast: options.contrast,
            camera: showCamera ? (lastCameraFrame == nil ? "CÂMERA AGUARDANDO" : "CÂMERA AO VIVO") : nil,
            cameraLive: lastCameraFrame != nil
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
        referenceSpace.simdTransform = pose
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
        case .camera:
            toggleCamera()
        case .exit:
            close(false)
        }
        updateTexture()
    }

    private func applyHand(_ sample: VRBoxHandSample?, capturedAt: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard active, now - capturedAt < 0.25 else { return }
        if palmToggle.update(open: sample?.openPalm, at: capturedAt) {
            togglePanel()
            return
        }
        guard hasHeadPose, quality == .normal, mode == .hand, !panel.isHidden,
            let sample = sample else { return }
        // The ray was captured in the same head coordinate system as the panel.
        let origin = sample.origin
        let ray = sample.ray
        guard ray.z < -0.05 else { return }
        let distance = (panelDepth - origin.z) / ray.z
        guard distance > 0, distance < 3 else { return }
        lastHand = now
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
        if let capturedAt = lastCameraFrame, ProcessInfo.processInfo.systemUptime - capturedAt > 0.35 {
            lastCameraFrame = nil
            wantsEnvironmentOnly = false
            scene.background.contents = virtualBackground
            updatePanelPresentation()
            updateTexture()
        }
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
            gamepadButtons = nil
            return
        }
        let buttons = [pad.buttonY.isPressed, pad.buttonX.isPressed, pad.buttonB.isPressed,
            pad.buttonMenu.isPressed, pad.leftShoulder.isPressed, pad.rightShoulder.isPressed]
        let rising = zip(buttons, gamepadButtons ?? buttons).map { $0.0 && !$0.1 }
        gamepadButtons = buttons
        if rising[0] { toggleMode() }
        if rising[1], hold == nil {
            controllerHandle = controllerHandle == .move ? .resize : .move
            updateTexture()
        }
        if rising[2] { recenter() }
        if rising[3] { leave(); return }
        if rising[4] { toggleCamera() }
        if rising[5] { togglePanel(); return }
        guard mode == .controller, hasHeadPose, quality == .normal, !panel.isHidden else { return }
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
    let openPalm: Bool
}

private final class VRBoxTracking: NSObject, ARSessionDelegate {
    private let tracking = ARSession()
    private let frameQueue = DispatchQueue(label: "vrbox.frames", qos: .userInteractive)
    private let visionQueue = DispatchQueue(label: "vrbox.hand", qos: .userInitiated)
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let handInterval: Double
    private let previewInterval: Double
    private let previewResolution: CGFloat
    private let previewQueue = DispatchQueue(label: "vrbox.camera", qos: .userInitiated)
    private lazy var camera = VRBoxCamera() // Access only on previewQueue.
    // These fields are read and written only on frameQueue.
    private var lastHandRequest = -Double.infinity
    private var handRequestRunning = false
    private var previewViewport: CGSize?
    private var previewEpoch = 0
    private var previewBusy = false
    private var lastPreviewRequest = -Double.infinity

    var onPose: ((simd_float4x4, VRBoxTrackingQuality) -> Void)?
    var onQuality: ((VRBoxTrackingQuality) -> Void)?
    var onHand: ((VRBoxHandSample?, Double) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onPreview: ((CGImage, Int, Double) -> Void)?

    init(handInterval: Double, previewInterval: Double, previewResolution: CGFloat) {
        self.handInterval = handInterval
        self.previewInterval = previewInterval
        self.previewResolution = previewResolution
        super.init()
        tracking.delegate = self
        tracking.delegateQueue = frameQueue
        handRequest.maximumHandCount = 1
    }

    func setPreviewViewport(_ size: CGSize?, epoch: Int) {
        frameQueue.async {
            self.previewViewport = size
            self.previewEpoch = epoch
            self.lastPreviewRequest = -Double.infinity
        }
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
        let worldToHead = frame.camera.viewMatrix(for: .landscapeRight)
        let displayPose = simd_inverse(worldToHead)
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
        publishPreview(from: frame)

        guard !handRequestRunning, frame.timestamp - lastHandRequest >= handInterval else { return }
        lastHandRequest = frame.timestamp
        handRequestRunning = true
        let image = frame.capturedImage
        let intrinsics = frame.camera.intrinsics
        let cameraToHead = worldToHead * frame.camera.transform
        let capturedAt = ProcessInfo.processInfo.systemUptime
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            let sample = self.readHand(image, intrinsics: intrinsics, cameraToHead: cameraToHead)
            self.frameQueue.async { self.handRequestRunning = false }
            DispatchQueue.main.async { [weak self] in self?.onHand?(sample, capturedAt) }
        }
    }

    private func publishPreview(from frame: ARFrame) {
        guard let viewport = previewViewport, !previewBusy,
            frame.timestamp - lastPreviewRequest >= previewInterval else { return }
        previewBusy = true
        lastPreviewRequest = frame.timestamp
        let epoch = previewEpoch
        let capturedAt = ProcessInfo.processInfo.systemUptime
        let pixels = frame.capturedImage
        let transform = frame.displayTransform(for: .landscapeRight, viewportSize: viewport)
        previewQueue.async { [weak self] in
            guard let self = self else { return }
            let image = self.camera.image(from: pixels, displayTransform: transform,
                viewport: viewport, maxDimension: self.previewResolution)
            self.frameQueue.async {
                self.previewBusy = false
                guard let image = image, self.previewEpoch == epoch else { return }
                DispatchQueue.main.async { [weak self] in self?.onPreview?(image, epoch, capturedAt) }
            }
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in self?.onQuality?(.recovering) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }

    private func readHand(_ image: CVPixelBuffer, intrinsics: simd_float3x3,
        cameraToHead: simd_float4x4) -> VRBoxHandSample? {
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
            let gap = simd_distance(pixels(index), pixels(thumb)) / palm
            let fingerJoints: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
                (.indexTip, .indexPIP), (.middleTip, .middlePIP), (.ringTip, .ringPIP), (.littleTip, .littlePIP),
            ]
            let wristPoint = pixels(wrist)
            let openPalm = gap > 0.55 && fingerJoints.allSatisfy { pair in
                guard let tip = try? hand.recognizedPoint(pair.0), tip.confidence >= 0.50,
                    let pip = try? hand.recognizedPoint(pair.1), pip.confidence >= 0.50 else { return false }
                return simd_distance(pixels(tip), wristPoint) - simd_distance(pixels(pip), wristPoint) > 0.25 * palm
            }
            return VRBoxHandSample(origin: cameraToHead.columns.3, ray: cameraToHead * direction,
                gap: gap, openPalm: openPalm)
        } catch {
            return nil
        }
    }

}

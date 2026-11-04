// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit
import simd

enum VRBoxMenuAction: CaseIterable, Equatable {
    case mode, center, undo, help, library, camera, exit

    var frame: CGRect {
        switch self {
        case .mode: return CGRect(x: 34, y: 176, width: 174, height: 59)
        case .center: return CGRect(x: 224, y: 176, width: 185, height: 59)
        case .undo: return CGRect(x: 425, y: 176, width: 181, height: 59)
        case .help: return CGRect(x: 34, y: 249, width: 139, height: 59)
        case .library: return CGRect(x: 186, y: 249, width: 155, height: 59)
        case .camera: return CGRect(x: 354, y: 249, width: 135, height: 59)
        case .exit: return CGRect(x: 505, y: 19, width: 101, height: 36)
        }
    }

    func title(help: Bool) -> String {
        switch self {
        case .mode: return "Modo"
        case .center: return "Centralizar"
        case .undo: return "Desfazer"
        case .help: return help ? "Voltar" : "Ajuda"
        case .library: return "Biblioteca"
        case .camera: return "Câmera"
        case .exit: return "Sair"
        }
    }
}

enum VRBoxMenuTarget: Equatable {
    case action(VRBoxMenuAction)
    case grip
    case corner
}

enum VRBoxTrackingQuality: String {
    case initializing = "Preparando câmera"
    case normal = "Rastreamento ativo"
    case motion = "Mova a cabeça mais devagar"
    case features = "Olhe para uma área com detalhes"
    case recovering = "Recuperando posição"
    case unavailable = "Rastreamento indisponível"
}

@MainActor enum VRBoxMenu {
    static let width: Float = 0.40
    static let height: Float = 0.22
    static let size = CGSize(width: 640, height: 352)
    static let resizeFrame = CGRect(x: 502, y: 249, width: 104, height: 73)

    static func target(offset: SIMD2<Float>, scale: Float, undo: Bool) -> VRBoxMenuTarget? {
        let point = CGPoint(
            x: CGFloat(offset.x / (width * scale) + 0.5) * size.width,
            y: CGFloat(0.5 - offset.y / (height * scale)) * size.height
        )
        if let action = VRBoxMenuAction.allCases.first(where: { $0.frame.contains(point) }) {
            return action == .undo && !undo ? nil : .action(action)
        }
        if resizeFrame.contains(point) { return .corner }
        return CGRect(origin: .zero, size: size).contains(point) ? .grip : nil
    }

    static func image(mode: String, status: String, hint: String, focus: VRBoxMenuTarget?,
        pressed: Bool, help: Bool, canUndo: Bool, large: Bool, contrast: Bool,
        camera: String?, cameraLive: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let background = contrast ? UIColor.black : UIColor(red: 0.041, green: 0.063, blue: 0.123, alpha: 1)
        let tile = contrast ? UIColor(white: 0.16, alpha: 1) : UIColor(red: 0.126, green: 0.18, blue: 0.29, alpha: 1)
        let accent = UIColor(red: 0.44, green: 0.96, blue: 0.79, alpha: 1)
        let muted = UIColor(white: 0.80, alpha: 1)

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            func box(_ rect: CGRect, radius: CGFloat, fill: UIColor, outline: UIColor? = nil) {
                let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
                fill.setFill()
                path.fill()
                if let outline = outline {
                    outline.setStroke()
                    path.lineWidth = 3
                    path.stroke()
                }
            }

            func label(_ text: String, in rect: CGRect, size: CGFloat,
                color: UIColor = .white, weight: UIFont.Weight = .semibold, center: Bool = false) {
                let style = NSMutableParagraphStyle()
                style.alignment = center ? .center : .left
                style.lineBreakMode = .byTruncatingTail
                (text as NSString).draw(in: rect, withAttributes: [
                    .font: UIFont.systemFont(ofSize: size, weight: weight),
                    .foregroundColor: color,
                    .paragraphStyle: style,
                ])
            }

            box(CGRect(x: 10, y: 10, width: 620, height: 332), radius: 25, fill: background,
                outline: focus == .grip ? accent : tile)
            label("SAMUEL  /  VR BOX", in: CGRect(x: 34, y: 24, width: 220, height: 28),
                size: 20, color: accent, weight: .bold)
            if let camera = camera {
                label(camera, in: CGRect(x: 252, y: 25, width: 240, height: 26),
                    size: 16, color: cameraLive ? accent : UIColor.systemOrange, weight: .bold)
            }
            label(mode, in: CGRect(x: 34, y: 52, width: 572, height: 51), size: large ? 42 : 37)
            label(status, in: CGRect(x: 34, y: 110, width: 572, height: 28), size: large ? 24 : 21, color: muted)
            label(hint, in: CGRect(x: 34, y: 139, width: 572, height: 31), size: large ? 21 : 18, color: muted)
            for action in VRBoxMenuAction.allCases {
                let active = focus == .action(action)
                let disabled = action == .undo && !canUndo
                let rect = action.frame
                let outline = active || (action == .camera && camera != nil)
                box(rect, radius: 12, fill: active && pressed ? accent : tile, outline: outline ? accent : nil)
                let compact = action == .exit
                label(action.title(help: help), in: rect.insetBy(dx: 6, dy: compact ? 6 : 14),
                    size: compact ? 18 : (large ? 25 : 22),
                    color: active && pressed ? .black : (disabled ? muted.withAlphaComponent(0.60) : .white),
                    center: true)
            }
            let corner = focus == .corner
            box(resizeFrame, radius: 12, fill: corner && pressed ? accent : tile, outline: accent)
            label("↘", in: resizeFrame.insetBy(dx: 2, dy: 4), size: 29, color: corner && pressed ? .black : accent, center: true)
            label("Escala", in: resizeFrame.offsetBy(dx: 0, dy: 39), size: 17,
                color: corner && pressed ? .black : accent, center: true)
        }
    }
}

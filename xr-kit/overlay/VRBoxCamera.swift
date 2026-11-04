// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import CoreImage
import CoreVideo

/// Produces one cropped rear-camera preview for both eyes. The virtual panel
/// still has separate eye transforms, while the single camera image is mono.
final class VRBoxCamera {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func image(from pixels: CVPixelBuffer, displayTransform: CGAffineTransform,
        viewport: CGSize, maxDimension: CGFloat) -> CGImage? {
        let input = CIImage(cvPixelBuffer: pixels)
        let scale = maxDimension / max(viewport.width, viewport.height)
        let width = max(1, (viewport.width * scale).rounded())
        let height = max(1, (viewport.height * scale).rounded())

        // ARKit maps normalized top-left image points to normalized view
        // points. Core Image uses bottom-left pixel coordinates at both ends.
        let toNormalized = CGAffineTransform(a: 1 / input.extent.width, b: 0, c: 0,
            d: -1 / input.extent.height, tx: 0, ty: 1)
        let toPixels = CGAffineTransform(a: width, b: 0, c: 0, d: -height, tx: 0, ty: height)
        let transform = toNormalized.concatenating(displayTransform).concatenating(toPixels)
        let output = input.transformed(by: transform)
        return context.createCGImage(output, from: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

import CoreGraphics
import CoreImage
import Foundation

/// Flood fill by color similarity, measured as CIE Lab ΔE (CIE76). Callers pass the
/// downsampled analysis image (see ``SelectionRenderer/analysisMaxPixels``).
nonisolated enum MagicWand {
    /// ΔE at tolerance 1. Tolerance 0.15 (the default) accepts ΔE ≤ 15.
    static let maxDeltaE: Float = 100

    /// White where pixels match `seed` (pixel coordinates of `image`, top-left origin).
    static func mask(seed: CGPoint, tolerance: Double, contiguous: Bool, in image: CGImage) -> CIImage? {
        let lab = LabPixels(image)
        let x = Int(seed.x), y = Int(seed.y)
        guard x >= 0, y >= 0, x < lab.width, y < lab.height else { return nil }
        let reference = lab[y * lab.width + x]
        let limit = Float(tolerance) * maxDeltaE
        let limit2 = limit * limit
        let bytes: [UInt8]
        if contiguous {
            bytes = flood(from: [y * lab.width + x], width: lab.width, height: lab.height) { _, to in
                lab.distanceSquared(to, reference) <= limit2
            }
        } else {
            bytes = (0..<lab.count).map { lab.distanceSquared($0, reference) <= limit2 ? 255 : 0 }
        }
        return SelectionRenderer.maskImage(bytes, width: lab.width, height: lab.height)
    }

    /// Every pixel near `color` (sRGB), softly: fully selected within half the radius,
    /// fading out at the radius (`fuzziness` × ``maxDeltaE``).
    static func colorRange(_ color: RGBA, fuzziness: Double, in image: CGImage) -> CIImage? {
        let lab = LabPixels(image)
        let reference = LabPixels.lab(Float(color.red), Float(color.green), Float(color.blue))
        let radius = max(1, Float(fuzziness) * maxDeltaE)
        let inner = radius / 2
        let bytes: [UInt8] = (0..<lab.count).map { i in
            let d = lab.distanceSquared(i, reference).squareRoot()
            let t = min(1, max(0, (d - inner) / (radius - inner)))
            let v = 1 - t * t * (3 - 2 * t)  // smoothstep falloff
            return UInt8((v * 255).rounded())
        }
        return SelectionRenderer.maskImage(bytes, width: lab.width, height: lab.height)
    }

    /// 4-connected flood fill from `seeds` (pixel indices); `accept(from, to)` decides
    /// whether the fill steps from one pixel to its neighbor. Returns 255 where filled.
    static func flood(from seeds: [Int], width: Int, height: Int, accept: (Int, Int) -> Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        var stack: [Int] = []
        stack.reserveCapacity(4096)
        for seed in seeds where out[seed] == 0 {
            out[seed] = 255
            stack.append(seed)
        }
        func visit(_ i: Int, _ n: Int) {
            guard out[n] == 0, accept(i, n) else { return }
            out[n] = 255
            stack.append(n)
        }
        while let i = stack.popLast() {
            let x = i % width
            if x > 0 { visit(i, i - 1) }
            if x < width - 1 { visit(i, i + 1) }
            if i >= width { visit(i, i - width) }
            if i < out.count - width { visit(i, i + width) }
        }
        return out
    }
}

/// An image as CIE Lab (D65), three floats per pixel, row 0 at the top.
nonisolated struct LabPixels {
    let width: Int
    let height: Int
    private let values: [Float]

    var count: Int { width * height }

    init(_ image: CGImage) {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let linear = (0..<256).map { Self.linear(Float($0) / 255) }
        var values = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            let lab = Self.labLinear(linear[Int(rgba[i * 4])], linear[Int(rgba[i * 4 + 1])], linear[Int(rgba[i * 4 + 2])])
            values[i * 3] = lab.x
            values[i * 3 + 1] = lab.y
            values[i * 3 + 2] = lab.z
        }
        width = w
        height = h
        self.values = values
    }

    subscript(i: Int) -> SIMD3<Float> { SIMD3(values[i * 3], values[i * 3 + 1], values[i * 3 + 2]) }

    func distanceSquared(_ i: Int, _ lab: SIMD3<Float>) -> Float {
        let d = self[i] - lab
        return (d * d).sum()
    }

    func distanceSquared(_ i: Int, _ j: Int) -> Float { distanceSquared(i, self[j]) }

    /// sRGB components (0…1) to Lab.
    static func lab(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> { labLinear(linear(r), linear(g), linear(b)) }

    private static func linear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }

    private static func labLinear(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        let x = f((0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047)
        let y = f(0.2126 * r + 0.7152 * g + 0.0722 * b)
        let z = f((0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883)
        return SIMD3(116 * y - 16, 500 * (x - y), 200 * (y - z))
    }
}

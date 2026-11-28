import CoreGraphics
import CoreImage

/// Per-channel histograms from `CIAreaHistogram`, on the GPU.
nonisolated struct Histogram: Equatable, Sendable {
    static let bins = 256

    /// `bins` values each, normalized so the tallest bin of all four is 1. Empty = none.
    var red: [Float] = []
    var green: [Float] = []
    var blue: [Float] = []
    var luminance: [Float] = []

    /// Histograms of `image`'s sRGB-encoded values (what the eye and Photoshop see),
    /// counted on a copy no bigger than 512 px a side.
    static func compute(_ image: CIImage) -> Histogram {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return Histogram() }
        var input = image
        let scale = min(1, 512 / max(extent.width, extent.height))
        if scale < 1 { input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        input = input.matchedFromWorkingSpace(to: CGColorSpace(name: CGColorSpace.sRGB)!) ?? input
        let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let gray = input.applyingFilter("CIColorMatrix", parameters: ["inputRVector": luma, "inputGVector": luma, "inputBVector": luma])

        func counts(_ image: CIImage) -> [Float] {
            let histogram = image.applyingFilter(
                "CIAreaHistogram", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent), "inputCount": bins, kCIInputScaleKey: 1])
            var out = [Float](repeating: 0, count: bins * 4)
            RenderPipeline.context.render(
                histogram, toBitmap: &out, rowBytes: bins * 16, bounds: CGRect(x: 0, y: 0, width: bins, height: 1), format: .RGBAf,
                colorSpace: nil)
            return out
        }
        let rgb = counts(input)
        let l = counts(gray)
        var result = Histogram(
            red: stride(from: 0, to: rgb.count, by: 4).map { rgb[$0] },
            green: stride(from: 1, to: rgb.count, by: 4).map { rgb[$0] },
            blue: stride(from: 2, to: rgb.count, by: 4).map { rgb[$0] },
            luminance: stride(from: 0, to: l.count, by: 4).map { l[$0] })
        let peak = [result.red, result.green, result.blue, result.luminance].joined().max() ?? 0
        guard peak > 0 else { return result }
        for keyPath in [\Histogram.red, \.green, \.blue, \.luminance] {
            result[keyPath: keyPath] = result[keyPath: keyPath].map { $0 / peak }
        }
        return result
    }
}

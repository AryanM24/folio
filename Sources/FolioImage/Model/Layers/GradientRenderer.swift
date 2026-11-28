import CoreGraphics
import CoreImage
import Foundation

/// Solid and multi-stop gradient fills.
///
/// Gradient points are in layer space (y down). Renderers in this folder share one
/// convention for "layer space at `scale`": Core Image point (x, y) is layer point
/// (x / scale, −y / scale), so the compositor can place every kind of content with the
/// same transform.
nonisolated enum GradientRenderer {
    /// `fill` covering `extent` (Core Image coordinates at `scale`).
    static func image(_ fill: FillSpec, extent: CGRect, scale: Double) -> CIImage {
        switch fill {
        case .solid(let color):
            return CIImage(color: CIColor(cgColor: color.cgColor)).cropped(to: extent)
        case .gradient(let spec):
            return gradient(spec, scale: scale).cropped(to: extent)
        }
    }

    private static func gradient(_ spec: GradientSpec, scale: Double) -> CIImage {
        let stops = spec.stops.sorted { $0.location < $1.location }
        guard let first = stops.first, let last = stops.last else { return CIImage.empty() }
        let start = CIVector(x: spec.start.x * scale, y: -spec.start.y * scale)
        let end = CIVector(x: spec.end.x * scale, y: -spec.end.y * scale)
        let kind = Double(GradientSpec.Kind.allCases.firstIndex(of: spec.kind) ?? 0)
        if let kernel = Kernels.kernel(named: "folioGradient", in: source), let ramp = ramp(stops),
            let out = kernel.apply(
                extent: .infinite, roiCallback: { _, _ in ramp.extent }, arguments: [ramp, start, end, kind])
        {
            return out
        }
        return CIFilter(
            name: "CISmoothLinearGradient",
            parameters: [
                "inputPoint0": start, "inputPoint1": end,
                "inputColor0": CIColor(cgColor: first.color.cgColor), "inputColor1": CIColor(cgColor: last.color.cgColor),
            ])?.outputImage ?? CIImage.empty()
    }

    /// The stops baked into a 256 × 1 strip, interpolated in sRGB like Photoshop.
    private static func ramp(_ stops: [ColorStop]) -> CIImage? {
        var floats = [Float](repeating: 0, count: 256 * 4)
        for i in 0..<256 {
            let t = Double(i) / 255
            let upper = stops.firstIndex { $0.location >= t } ?? stops.count - 1
            let a = stops[max(0, upper - 1)], b = stops[upper]
            let f = b.location > a.location ? min(1, max(0, (t - a.location) / (b.location - a.location))) : 1
            let alpha = a.color.alpha + (b.color.alpha - a.color.alpha) * f
            let rgb = [
                a.color.red + (b.color.red - a.color.red) * f, a.color.green + (b.color.green - a.color.green) * f,
                a.color.blue + (b.color.blue - a.color.blue) * f,
            ]
            for c in 0..<3 { floats[i * 4 + c] = Float(rgb[c] * alpha) }
            floats[i * 4 + 3] = Float(alpha)
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let data = floats.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: 256 * 16, size: CGSize(width: 256, height: 1), format: .RGBAf, colorSpace: space)
    }

    // Kinds are numbered in `GradientSpec.Kind.allCases` order.
    static let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        using namespace coreimage;

        [[stitchable]] float4 folioGradient(coreimage::sampler ramp, float2 start, float2 end, float kind, destination dest) {
            float2 p = dest.coord() - start, d = end - start;
            float len = max(length(d), 1e-4);
            float2 u = d / len, q = float2(dot(p, u), u.x * p.y - u.y * p.x);
            int k = int(kind + 0.5);
            float t;
            if (k == 0) t = q.x / len;
            else if (k == 1) t = length(p) / len;
            else if (k == 2) t = fract(-atan2(q.y, q.x) / (2 * M_PI_F));
            else if (k == 3) t = (abs(q.x) + abs(q.y)) / len;
            else t = abs(q.x) / len;
            return ramp.sample(ramp.transform(float2(saturate(t) * 255 + 0.5, 0.5)));
        }
        """
}

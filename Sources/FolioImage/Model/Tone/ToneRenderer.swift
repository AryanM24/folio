import CoreGraphics
import CoreImage
import Foundation
import Synchronization

/// Renders a ``ToneSpec``: curves and levels through one 1D LUT per channel, HSL and
/// color balance through runtime kernels, the channel mixer through `CIColorMatrix`,
/// LUT files through `CIColorCube`.
///
/// White balance runs in Core Image's linear working space; everything after it runs on
/// sRGB-encoded values, so curves and levels feel like Photoshop's. If the kernels don't
/// compile, the stages that need them are skipped rather than failing the render.
nonisolated enum ToneRenderer {
    /// `image` with `tone` applied; `assets` holds LUT files.
    static func apply(_ tone: ToneSpec, to image: CIImage, assets: any AssetStore) -> CIImage {
        var out = image
        if let wb = tone.whiteBalance, wb != WhiteBalance() {
            out = out.applyingFilter(
                "CITemperatureAndTint",
                parameters: [
                    "inputNeutral": CIVector(x: wb.temperature, y: wb.tint),
                    "inputTargetNeutral": CIVector(x: 6500, y: 0),
                ])
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        out = out.matchedFromWorkingSpace(to: srgb) ?? out

        if let tables = curveTables(tone) { out = applyLUT1D(tables, to: out) }
        if tone.colorBalance != ColorBalance(), let kernel = colorKernel("folioToneColorBalance") {
            let b = tone.colorBalance
            func v(_ s: ColorShift) -> CIVector {
                CIVector(x: s.cyanRed * 0.003, y: s.magentaGreen * 0.003, z: s.yellowBlue * 0.003, w: 0)
            }
            out =
                kernel.apply(
                    extent: out.extent,
                    arguments: [out, v(b.shadows), v(b.midtones), v(b.highlights), b.preserveLuminosity ? 1 : 0]) ?? out
        }
        if tone.hsl.contains(where: { !$0.value.isNeutral }), let kernel = colorKernel("folioToneHSL") {
            let shifts = HueBand.allCases.map { tone.hsl[$0] ?? HSLShift() }
            func pair(_ value: (HSLShift) -> Double) -> [CIVector] {
                let v = shifts.map { CGFloat(value($0)) }
                return [CIVector(x: v[0], y: v[1], z: v[2], w: v[3]), CIVector(x: v[4], y: v[5], z: v[6], w: v[7])]
            }
            out = kernel.apply(extent: out.extent, arguments: [out] + pair(\.hue) + pair(\.saturation) + pair(\.luminance)) ?? out
        }
        if let mixer = tone.channelMixer {
            func v(_ row: ChannelMixer.Row) -> CIVector { CIVector(x: row.red, y: row.green, z: row.blue, w: 0) }
            let rows = mixer.monochrome ? [mixer.red, mixer.red, mixer.red] : [mixer.red, mixer.green, mixer.blue]
            out = out.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": v(rows[0]), "inputGVector": v(rows[1]), "inputBVector": v(rows[2]),
                    "inputBiasVector": CIVector(x: rows[0].constant, y: rows[1].constant, z: rows[2].constant, w: 0),
                ])
        }
        if let ref = tone.lut, let lut = cachedLUT(ref.asset, assets: assets) {
            out = applyLUTFile(lut, strength: ref.strength, to: out)
        }
        return out.matchedToWorkingSpace(from: srgb) ?? out
    }

    /// Compile the kernels ahead of the first render (about 0.3 s, once).
    @concurrent static func warmUp() async { _ = generalKernel("folioToneHSL") }

    // MARK: Curves and levels

    /// Levels then curves, per channel (the channel's own setting, then the composite
    /// RGB one), baked into `count` samples for red, green and blue. `nil` = identity.
    static func curveTables(_ tone: ToneSpec, count: Int = 1024) -> [[Float]]? {
        let levelsAreIdentity = ToneChannel.allCases.allSatisfy { tone.levels[$0] == LevelsChannel() }
        let curvesAreIdentity = ToneChannel.allCases.allSatisfy { tone.curves[$0].isEmpty }
        guard !levelsAreIdentity || !curvesAreIdentity else { return nil }
        let master = ToneCurve(tone.curves.rgb)
        return [ToneChannel.red, .green, .blue].map { channel in
            let curve = ToneCurve(tone.curves[channel])
            return (0..<count).map { i in
                var x = Double(i) / Double(count - 1)
                x = tone.levels.rgb.map(tone.levels[channel].map(x))
                return Float(master(curve(x)))
            }
        }
    }

    /// Look each channel up in its table (linear interpolation between samples).
    static func applyLUT1D(_ tables: [[Float]], to image: CIImage) -> CIImage {
        guard let kernel = generalKernel("folioToneLUT1D") else { return image }
        let n = tables[0].count
        var rgba = [Float](repeating: 1, count: n * 4)
        for i in 0..<n { for c in 0..<3 { rgba[i * 4 + c] = tables[c][i] } }
        let lut = CIImage(
            bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: n * 16, size: CGSize(width: n, height: 1), format: .RGBAf,
            colorSpace: nil)
        let lutExtent = lut.extent
        return kernel.apply(
            extent: image.extent, roiCallback: { index, rect in index == 0 ? rect : lutExtent }, arguments: [image, lut, Float(n)])
            ?? image
    }

    // MARK: LUT files

    private static let luts = Mutex<[AssetID: CubeLUT]>([:])

    private static func cachedLUT(_ id: AssetID, assets: any AssetStore) -> CubeLUT? {
        if let lut = luts.withLock({ $0[id] }) { return lut }
        guard let data = try? assets.data(id), let lut = try? CubeLUT(data: data) else { return nil }
        luts.withLock { $0[id] = lut }
        return lut
    }

    static func applyLUTFile(_ lut: CubeLUT, strength: Double, to image: CIImage) -> CIImage {
        var input = image
        if lut.domainMin != [0, 0, 0] || lut.domainMax != [1, 1, 1] {
            let scale = zip(lut.domainMin, lut.domainMax).map { 1 / ($1 - $0) }
            input = input.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: scale[0], y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: scale[1], z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: scale[2], w: 0),
                    "inputBiasVector": CIVector(
                        x: -lut.domainMin[0] * scale[0], y: -lut.domainMin[1] * scale[1], z: -lut.domainMin[2] * scale[2], w: 0),
                ])
        }
        let looked: CIImage
        if lut.dimension == 1 {
            let tables = (0..<3).map { c in stride(from: c, to: lut.values.count, by: 3).map { lut.values[$0] } }
            looked = applyLUT1D(tables, to: input)
        } else {
            var rgba = [Float](repeating: 1, count: lut.values.count / 3 * 4)
            for i in 0..<lut.values.count / 3 { for c in 0..<3 { rgba[i * 4 + c] = lut.values[i * 3 + c] } }
            looked = input.applyingFilter(
                "CIColorCube", parameters: ["inputCubeDimension": lut.size, "inputCubeData": rgba.withUnsafeBytes { Data($0) }])
        }
        let strength = min(1, max(0, strength))
        if strength >= 0.999 { return looked.cropped(to: image.extent) }
        return image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: looked, kCIInputTimeKey: strength])
    }

    // MARK: White balance eyedropper

    /// The white balance that makes the average of `rect` in `image` (working space,
    /// before tone) neutral, or `nil` when the sample is too dark to tell.
    static func whiteBalance(neutralizing image: CIImage, in rect: CGRect) -> WhiteBalance? {
        let sample = image.applyingFilter(
            "CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect.intersection(image.extent))])
        guard !sample.extent.isEmpty, !sample.extent.isInfinite else { return nil }
        let pixel = sample.cropped(to: CGRect(origin: sample.extent.origin, size: CGSize(width: 1, height: 1)))
        func color(_ wb: WhiteBalance) -> SIMD3<Float> {
            var px = [Float](repeating: 0, count: 4)
            let out = apply(ToneSpec(whiteBalance: wb), to: pixel, assets: InMemoryAssetStore())
            RenderPipeline.context.render(out, toBitmap: &px, rowBytes: 16, bounds: pixel.extent, format: .RGBAf, colorSpace: nil)
            return SIMD3(px[0], px[1], px[2])
        }
        let start = color(WhiteBalance())
        guard start.min() > 0.002 else { return nil }
        func error(_ wb: WhiteBalance) -> Float {
            let c = color(wb)
            guard c.min() > 0 else { return .infinity }
            let (r, g, b) = (log(c.x), log(c.y), log(c.z))
            return (r - g) * (r - g) + (b - g) * (b - g)
        }
        // Coordinate descent: temperature in mireds (perceptually even), then tint.
        var mired = 1e6 / 6500, tint = 0.0
        func golden(_ range: ClosedRange<Double>, _ f: (Double) -> Float) -> Double {
            var (a, b) = (range.lowerBound, range.upperBound)
            let k = (5.0.squareRoot() - 1) / 2
            for _ in 0..<24 {
                let (c, d) = (b - k * (b - a), a + k * (b - a))
                if f(c) < f(d) { b = d } else { a = c }
            }
            return (a + b) / 2
        }
        for _ in 0..<3 {
            mired = golden(20...500) { error(WhiteBalance(temperature: 1e6 / $0, tint: tint)) }
            tint = golden(-150...150) { error(WhiteBalance(temperature: 1e6 / mired, tint: $0)) }
        }
        return WhiteBalance(temperature: (1e6 / mired).rounded(), tint: tint.rounded())
    }

    // MARK: Kernels

    private static func generalKernel(_ name: String) -> CIKernel? { Kernels.kernel(named: name, in: sources[name] ?? "") }

    private static func colorKernel(_ name: String) -> CIColorKernel? { generalKernel(name) as? CIColorKernel }

    /// Each kernel compiles from its own source: kernels sharing one Metal library got
    /// each other's cached results when rendered concurrently.
    private static let sources: [String: String] = {
        let parts = source.components(separatedBy: "[[stitchable]]")
        return Dictionary(
            uniqueKeysWithValues: parts.dropFirst().map { body in
                let name = body.split(separator: "(")[0].split(separator: " ").last.map(String.init) ?? ""
                return (name, parts[0] + "[[stitchable]]" + body)
            })
    }()

    /// Colors arrive premultiplied; each kernel works on straight color and premultiplies back.
    static let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        [[stitchable]] float4 folioToneLUT1D(coreimage::sampler src, coreimage::sampler lut, float n) {
            float4 p = src.sample(src.coord());
            float a = p.a;
            if (a <= 0.0) return p;
            float3 x = clamp(p.rgb / a, 0.0, 1.0) * (n - 1.0) + 0.5;
            float r = lut.sample(lut.transform(float2(x.r, 0.5))).r;
            float g = lut.sample(lut.transform(float2(x.g, 0.5))).g;
            float b = lut.sample(lut.transform(float2(x.b, 0.5))).b;
            return float4(float3(r, g, b) * a, a);
        }

        [[stitchable]] float4 folioToneColorBalance(coreimage::sample_t s, float4 shadows, float4 mids, float4 highs, float preserve) {
            float a = s.a;
            if (a <= 0.0) return s;
            float3 c = s.rgb / a;
            float3 w = float3(0.2126, 0.7152, 0.0722);
            float l = clamp(dot(c, w), 0.0, 1.0);
            float ws = (1.0 - l) * (1.0 - l), wh = l * l, wm = 1.0 - ws - wh;
            float3 out = c + shadows.rgb * ws + mids.rgb * wm * 2.0 + highs.rgb * wh;
            if (preserve > 0.5) out += dot(c, w) - dot(out, w);
            return float4(out * a, a);
        }

        [[stitchable]] float4 folioToneHSL(coreimage::sample_t s, float4 h0, float4 h1, float4 s0, float4 s1, float4 l0, float4 l1) {
            float a = s.a;
            if (a <= 0.0) return s;
            float3 c = clamp(s.rgb / a, 0.0, 1.0);
            float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
            float chroma = mx - mn;
            if (chroma < 0.0001) return s;
            float hue;
            if (mx == c.r) hue = fmod((c.g - c.b) / chroma + 6.0, 6.0);
            else if (mx == c.g) hue = (c.b - c.r) / chroma + 2.0;
            else hue = (c.r - c.g) / chroma + 4.0;
            hue *= 60.0;
            float l = (mx + mn) * 0.5;
            float sat = chroma / max(0.0001, 1.0 - abs(2.0 * l - 1.0));

            // Band centers in degrees: red, orange, yellow, green, aqua, blue, purple, magenta.
            float centers[9] = {0.0, 30.0, 60.0, 120.0, 180.0, 240.0, 270.0, 300.0, 360.0};
            float dh[8] = {h0.x, h0.y, h0.z, h0.w, h1.x, h1.y, h1.z, h1.w};
            float ds[8] = {s0.x, s0.y, s0.z, s0.w, s1.x, s1.y, s1.z, s1.w};
            float dl[8] = {l0.x, l0.y, l0.z, l0.w, l1.x, l1.y, l1.z, l1.w};
            int i = 0;
            for (int k = 1; k < 8; k++) { if (hue >= centers[k]) i = k; }
            int j = (i + 1) % 8;
            float t = (hue - centers[i]) / (centers[i + 1] - centers[i]);
            t = 0.5 - 0.5 * cos(t * M_PI_F);  // cosine falloff: no hard band edges
            // Near-grays have no reliable hue, so they move less.
            float w = smoothstep(0.0, 0.15, chroma);
            hue = fmod(hue + mix(dh[i], dh[j], t) * 0.3 * w + 360.0, 360.0);
            sat = clamp(sat * (1.0 + mix(ds[i], ds[j], t) * 0.01 * w), 0.0, 1.0);
            float k = mix(dl[i], dl[j], t) * 0.005 * w;
            l = k >= 0.0 ? l + (1.0 - l) * k : l * (1.0 + k);

            float cc = (1.0 - abs(2.0 * l - 1.0)) * sat;
            float hp = hue / 60.0;
            float x = cc * (1.0 - abs(fmod(hp, 2.0) - 1.0));
            float3 rgb;
            if (hp < 1.0) rgb = float3(cc, x, 0.0);
            else if (hp < 2.0) rgb = float3(x, cc, 0.0);
            else if (hp < 3.0) rgb = float3(0.0, cc, x);
            else if (hp < 4.0) rgb = float3(0.0, x, cc);
            else if (hp < 5.0) rgb = float3(x, 0.0, cc);
            else rgb = float3(cc, 0.0, x);
            return float4((rgb + (l - cc * 0.5)) * a, a);
        }
        """
}

/// A monotone cubic (Fritsch–Carlson) through curve points: it never overshoots, so a
/// curve can't invert tones between two points. Flat outside the first and last point;
/// no points is the identity.
nonisolated struct ToneCurve: Sendable {
    private let xs: [Double]
    private let ys: [Double]
    private let tangents: [Double]

    init(_ points: [CGPoint]) {
        var xs: [Double] = [], ys: [Double] = []
        for p in points.sorted(by: { $0.x < $1.x }) {
            let (x, y) = (min(1, max(0, Double(p.x))), min(1, max(0, Double(p.y))))
            if let last = xs.last, x - last < 1e-6 { ys[ys.count - 1] = y } else { xs.append(x); ys.append(y) }
        }
        self.xs = xs
        self.ys = ys
        let n = xs.count
        guard n > 1 else {
            tangents = []
            return
        }
        var secants = [Double](repeating: 0, count: n - 1)
        for k in 0..<n - 1 {
            let dy: Double = ys[k + 1] - ys[k]
            secants[k] = dy / (xs[k + 1] - xs[k])
        }
        var m = [Double](repeating: 0, count: n)
        m[0] = secants[0]
        m[n - 1] = secants[n - 2]
        for k in 1..<n - 1 where secants[k - 1] * secants[k] > 0 { m[k] = (secants[k - 1] + secants[k]) / 2 }
        for k in 0..<n - 1 {
            if secants[k] == 0 {
                m[k] = 0
                m[k + 1] = 0
                continue
            }
            let (a, b) = (m[k] / secants[k], m[k + 1] / secants[k])
            let r = a * a + b * b
            if r > 9 {
                let t = 3 / r.squareRoot()
                m[k] = t * a * secants[k]
                m[k + 1] = t * b * secants[k]
            }
        }
        tangents = m
    }

    func callAsFunction(_ x: Double) -> Double {
        guard let first = xs.first, let last = xs.last else { return x }
        if xs.count == 1 || x <= first { return ys[0] }
        if x >= last { return ys[ys.count - 1] }
        var k = 0
        while k < xs.count - 2, x > xs[k + 1] { k += 1 }
        let h = xs[k + 1] - xs[k]
        let t = (x - xs[k]) / h
        let t2: Double = t * t, t3: Double = t2 * t
        let h00: Double = 2 * t3 - 3 * t2 + 1, h10: Double = t3 - 2 * t2 + t
        let h01: Double = 3 * t2 - 2 * t3, h11: Double = t3 - t2
        let y: Double = h00 * ys[k] + h10 * h * tangents[k] + h01 * ys[k + 1] + h11 * h * tangents[k + 1]
        return min(1, max(0, y))
    }
}

nonisolated extension LevelsChannel {
    /// Photoshop's levels: clip to the input range, bend by gamma (> 1 lightens), then
    /// fit into the output range.
    func map(_ x: Double) -> Double {
        let t = min(1, max(0, (x - inputBlack) / max(0.0001, inputWhite - inputBlack)))
        return outputBlack + (outputWhite - outputBlack) * pow(t, 1 / max(0.01, gamma))
    }
}

/// Non-optional views of the optional tone settings, for sliders and key paths.
nonisolated extension ToneSpec {
    subscript(band band: HueBand) -> HSLShift {
        get { hsl[band] ?? HSLShift() }
        set { hsl[band] = newValue }
    }

    var balance: WhiteBalance {
        get { whiteBalance ?? WhiteBalance() }
        set { whiteBalance = newValue }
    }

    var mixer: ChannelMixer {
        get { channelMixer ?? ChannelMixer() }
        set { channelMixer = newValue }
    }
}

import CoreImage

// Photoshop's blend modes, in Photoshop's maths: colors are blended gamma-encoded (sRGB),
// not in Core Image's linear working space, and opacity scales the layer's alpha. Core
// Image's built-in blend filters work in linear light and use the W3C soft light, so
// every mode goes through one runtime Metal kernel; the built-ins are only the fallback
// while (or if) the kernel can't compile.
nonisolated extension Layer.BlendMode {
    /// `top` blended onto `backdrop` with this mode at full opacity (opacity is applied
    /// afterwards with `CIMix`).
    func blend(_ top: CIImage, over backdrop: CIImage) -> CIImage {
        blend(top, over: backdrop, opacity: 1)
    }

    /// `top` blended onto `backdrop` and faded to `opacity`. The same as blending at full
    /// opacity and then mixing with the backdrop, in one pass.
    func blend(_ top: CIImage, over backdrop: CIImage, opacity: Double) -> CIImage {
        let opacity = min(1, max(0, opacity))
        guard opacity > 0 else { return backdrop }
        let extent = top.extent.union(backdrop.extent)
        if let kernel = BlendKernels.blend,
            let out = kernel.apply(extent: extent, arguments: [top, backdrop, Double(index), opacity])
        {
            return out
        }
        let blended = top.applyingFilter(fallbackFilter, parameters: [kCIInputBackgroundImageKey: backdrop])
        return BlendKernels.mix(backdrop, blended, amount: opacity)
    }

    /// The kernel's mode number.
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// The nearest built-in (linear light, so not Photoshop-exact).
    private var fallbackFilter: String {
        switch self {
        case .normal, .dissolve: "CISourceOverCompositing"
        case .darken, .darkerColor: "CIDarkenBlendMode"
        case .multiply: "CIMultiplyBlendMode"
        case .colorBurn: "CIColorBurnBlendMode"
        case .linearBurn: "CILinearBurnBlendMode"
        case .lighten, .lighterColor: "CILightenBlendMode"
        case .screen: "CIScreenBlendMode"
        case .colorDodge: "CIColorDodgeBlendMode"
        case .linearDodge: "CIAdditionCompositing"
        case .overlay: "CIOverlayBlendMode"
        case .softLight: "CISoftLightBlendMode"
        case .hardLight, .hardMix: "CIHardLightBlendMode"
        case .vividLight: "CIVividLightBlendMode"
        case .linearLight: "CILinearLightBlendMode"
        case .pinLight: "CIPinLightBlendMode"
        case .difference: "CIDifferenceBlendMode"
        case .exclusion: "CIExclusionBlendMode"
        case .subtract: "CISubtractBlendMode"
        case .divide: "CIDivideBlendMode"
        case .hue: "CIHueBlendMode"
        case .saturation: "CISaturationBlendMode"
        case .color: "CIColorBlendMode"
        case .luminosity: "CILuminosityBlendMode"
        }
    }
}

/// The compositor's runtime kernels: blend, gamma-space mix and luminosity range.
nonisolated enum BlendKernels {
    static var blend: CIColorKernel? { Kernels.kernel(named: "folioBlend", in: blendSource) as? CIColorKernel }
    static var mixKernel: CIColorKernel? { Kernels.kernel(named: "folioMix", in: mixSource) as? CIColorKernel }
    static var lumaKernel: CIColorKernel? { Kernels.kernel(named: "folioLumaRange", in: lumaSource) as? CIColorKernel }

    /// `from` faded toward `to` by `amount` × `mask` (white = all of `to`), gamma-encoded
    /// like Photoshop's opacity. Without a mask the whole image fades.
    static func mix(_ from: CIImage, _ to: CIImage, amount: Double, mask: CIImage? = nil) -> CIImage {
        let mask = mask ?? CIImage(color: .white)
        let extent = from.extent.union(to.extent)
        if let kernel = mixKernel, let out = kernel.apply(extent: extent, arguments: [from, to, mask, amount]) { return out }
        let faded = to.applyingFilter(
            "CIDissolveTransition", parameters: [kCIInputTargetImageKey: from, kCIInputTimeKey: 1 - amount])
        return faded.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: from, kCIInputMaskImageKey: mask])
    }

    /// White where `image`'s luminosity (gamma-encoded, 0…1) is within `low…high`.
    static func luminanceMask(_ image: CIImage, low: Double, high: Double) -> CIImage {
        if let kernel = lumaKernel, let out = kernel.apply(extent: image.extent, arguments: [image, low, high]) { return out }
        return image.applyingFilter("CIPhotoEffectMono")
    }

    // One kernel per source: several kernels compiled from one source have returned each
    // other's output during parallel renders. They share the helpers in `prelude`.
    private static let prelude = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        using namespace coreimage;

        inline float3 enc(float3 c) {
            float3 a = abs(c);
            return sign(c) * select(1.055 * pow(a, 1.0 / 2.4) - 0.055, a * 12.92, a <= 0.0031308);
        }
        inline float3 dec(float3 c) {
            float3 a = abs(c);
            return sign(c) * select(pow((a + 0.055) / 1.055, 2.4), a / 12.92, a <= 0.04045);
        }
        inline float3 unpremul(float4 p) { return p.a > 0 ? p.rgb / p.a : float3(0); }

        inline float lum(float3 c) { return dot(c, float3(0.3, 0.59, 0.11)); }
        inline float3 clipColor(float3 c) {
            float l = lum(c), n = min(c.r, min(c.g, c.b)), x = max(c.r, max(c.g, c.b));
            if (n < 0) c = l + (c - l) * l / (l - n);
            if (x > 1) c = l + (c - l) * (1 - l) / (x - l);
            return c;
        }
        inline float3 setLum(float3 c, float l) { return clipColor(c + (l - lum(c))); }
        inline float sat(float3 c) { return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)); }
        inline float3 setSat(float3 c, float s) {
            float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
            return mx > mn ? (c - mn) * s / (mx - mn) : float3(0);
        }

        """

    // Modes are numbered in `Layer.BlendMode.allCases` order. Separable and non-separable
    // formulas follow Photoshop (soft light uses √b, not the W3C variant).
    static let blendSource =
        prelude
            + """
            inline float burn(float b, float s) { return b >= 1 ? 1 : (s <= 0 ? 0 : 1 - min(1.0, (1 - b) / s)); }
            inline float dodge(float b, float s) { return b <= 0 ? 0 : (s >= 1 ? 1 : min(1.0, b / (1 - s))); }
            inline float hard(float b, float s) { return s <= 0.5 ? b * 2 * s : 1 - (1 - b) * (2 - 2 * s); }

            inline float separable(int m, float b, float s) {
                switch (m) {
                case 2: return min(b, s);
                case 3: return b * s;
                case 4: return burn(b, s);
                case 5: return b + s - 1;
                case 7: return max(b, s);
                case 8: return b + s - b * s;
                case 9: return dodge(b, s);
                case 10: return b + s;
                case 12: return hard(s, b);
                case 13: return s <= 0.5 ? b - (1 - 2 * s) * b * (1 - b) : b + (2 * s - 1) * (sqrt(b) - b);
                case 14: return hard(b, s);
                case 15: return s <= 0.5 ? burn(b, 2 * s) : dodge(b, 2 * s - 1);
                case 16: return b + 2 * s - 1;
                case 17: return s <= 0.5 ? min(b, 2 * s) : max(b, 2 * s - 1);
                case 18: return b + s >= 1 ? 1 : 0;
                case 19: return abs(b - s);
                case 20: return b + s - 2 * b * s;
                case 21: return b - s;
                case 22: return s <= 0 ? (b <= 0 ? 0 : 1) : b / s;
                default: return s;
                }
            }

            inline float3 blendColor(int m, float3 b, float3 s) {
                switch (m) {
                case 6: return lum(s) < lum(b) ? s : b;
                case 11: return lum(s) > lum(b) ? s : b;
                case 23: return setLum(setSat(s, sat(b)), lum(b));
                case 24: return setLum(setSat(b, sat(s)), lum(b));
                case 25: return setLum(s, lum(b));
                case 26: return setLum(b, lum(s));
                default: return saturate(float3(separable(m, b.r, s.r), separable(m, b.g, s.g), separable(m, b.b, s.b)));
                }
            }

            [[stitchable]] float4 folioBlend(sample_t s, sample_t d, float mode, float opacity, destination dest) {
                int m = int(mode + 0.5);
                float sa = s.a * opacity;
                if (m == 1) {
                    // Dissolve: each pixel is either the layer (fully opaque) or the backdrop.
                    float r = fract(sin(dot(floor(dest.coord()), float2(12.9898, 78.233))) * 43758.5453);
                    return r < sa ? float4(unpremul(s), 1) : d;
                }
                if (sa <= 0) return d;
                float da = d.a;
                float3 cs = enc(unpremul(s)), cb = enc(unpremul(d));
                float3 mixed = m == 0 ? cs : blendColor(m, saturate(cb), saturate(cs));
                float3 source = (1 - da) * cs + da * mixed;
                float oa = sa + da * (1 - sa);
                float3 co = (sa * source + (1 - sa) * da * cb) / oa;
                return float4(dec(co) * oa, oa);
            }
            """

    static let mixSource =
        prelude
            + """
            [[stitchable]] float4 folioMix(sample_t a, sample_t b, sample_t mask, float amount) {
                float t = clamp(amount * mask.r, 0.0, 1.0);
                float4 o = mix(float4(enc(unpremul(a)) * a.a, a.a), float4(enc(unpremul(b)) * b.a, b.a), t);
                return float4(dec(unpremul(o)) * o.a, o.a);
            }
            """

    static let lumaSource =
        prelude
            + """
            [[stitchable]] float4 folioLumaRange(sample_t s, float low, float high) {
                float l = lum(saturate(enc(unpremul(s))));
                float v = (l >= low && l <= high) ? 1.0 : 0.0;
                return float4(v, v, v, 1);
            }
            """
}

import CoreGraphics
import CoreImage
import Foundation
import UniformTypeIdentifiers

/// Turns an original plus an ``EditRecipe`` into pixels with Core Image.
///
/// One pure function serves both the live preview (proxy-sized input, GPU, a few
/// milliseconds) and saving (full-resolution input, same filters), so the preview is
/// an honest picture of the saved file.
///
/// Order matters and mirrors how photographers think:
/// RAW develop → cut-out → auto-enhance → adjustments → tone → filter → layer stack
/// (source pixels) → geometry (flip, turn, straighten, crop) → vignette (framed on the
/// final crop) → resize → markup (drawn on top, not tinted by filters) → flatten.
///
/// ``composite(_:recipe:assets:scale:cropped:final:flattenFor:)`` builds the Core Image
/// graph; ``rasterize(_:extent:format:colorSpace:)`` turns it into pixels. The canvas
/// and HDR saves can use the graph directly.
nonisolated enum RenderPipeline {
    /// One context for the whole app. Core Image contexts are thread-safe and expensive
    /// to create (they own Metal queues and caches), so they must be reused.
    static let context = CIContext(options: [.name: "Folio Image", .cacheIntermediates: true])

    // MARK: Rendering

    /// Render `recipe` applied to `source`.
    ///
    /// - Parameters:
    ///   - scale: Output pixels per source pixel (≤ 1). The proxy is used whenever it
    ///     has enough pixels, so previews never touch the full decode.
    ///   - cropped: `false` renders the whole straightened canvas (the crop tool's view).
    ///   - final: Full-quality output: applies resize with Lanczos, bakes markup and
    ///     flattens transparency for formats that can't store it.
    ///   - flattenFor: When given, transparency is composited over white if the
    ///     format can't store alpha.
    static func render(
        _ source: SourceImage,
        recipe: EditRecipe,
        assets: any AssetStore = InMemoryAssetStore(),
        scale: Double = 1,
        cropped: Bool = true,
        final: Bool = false,
        flattenFor type: UTType? = nil
    ) throws -> CGImage {
        let graph = try composite(
            source, recipe: recipe, assets: assets, scale: scale, cropped: cropped, final: final, flattenFor: type)
        let format: CIFormat = source.bitsPerComponent > 8 && final ? .RGBA16 : .RGBA8
        return try rasterize(graph.image, extent: graph.extent, format: format, colorSpace: source.colorSpace)
    }

    /// The Core Image graph for `recipe` applied to `source` (parameters as in
    /// ``render(_:recipe:assets:scale:cropped:final:flattenFor:)``), and the pixel-aligned
    /// rectangle to rasterize. Nothing is rendered yet.
    static func composite(
        _ source: SourceImage,
        recipe: EditRecipe,
        assets: any AssetStore = InMemoryAssetStore(),
        scale: Double = 1,
        cropped: Bool = true,
        final: Bool = false,
        flattenFor type: UTType? = nil
    ) throws -> (image: CIImage, extent: CGRect) {
        let geometry = ImageGeometry(sourceSize: source.pixelSize, recipe: recipe)
        let scale = min(1, max(0.001, scale))
        let input = try input(for: source, raw: geometry.recipe.raw, scale: scale)
        let mask = recipe.removeBackground ? try source.subjectMask() : nil
        var image = filtered(input, recipe: geometry.recipe, assets: assets, scale: scale, mask: mask)
        if !geometry.recipe.layers.isEmpty {
            image = LayerCompositor.composite(base: image, layers: geometry.recipe.layers, assets: assets, scale: scale)
        }
        image = transformed(image, geometry: geometry, scale: scale, cropped: cropped)

        var size = (cropped ? geometry.croppedSize : geometry.canvasSize)
        size = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        if final, cropped, geometry.recipe.resize != nil {
            let rs = geometry.resizeScale
            image = image.applyingFilter(
                "CILanczosScaleTransform",
                parameters: [
                    kCIInputScaleKey: rs.height,
                    kCIInputAspectRatioKey: rs.width / rs.height,
                ])
            size = CGSize(width: geometry.outputSize.width * scale, height: geometry.outputSize.height * scale)
        }
        let extent = CGRect(origin: .zero, size: CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded())))
        image = image.cropped(to: extent)

        if final, cropped, !geometry.recipe.markup.isEmpty {
            let transform = geometry.outputTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            if let overlay = MarkupDrawing.image(geometry.recipe.markup, size: extent.size, transform: transform) {
                image = CIImage(cgImage: overlay).composited(over: image)
            }
        }
        if let type, !ImageCodec.supportsAlpha(type) {
            image = image.composited(over: CIImage(color: .white).cropped(to: extent))
        }
        return (image, extent)
    }

    /// Render `extent` of `image` to a bitmap.
    static func rasterize(_ image: CIImage, extent: CGRect, format: CIFormat, colorSpace: CGColorSpace) throws -> CGImage {
        guard let cg = context.createCGImage(image, from: extent, format: format, colorSpace: colorSpace) else {
            throw RenderError()
        }
        return cg
    }

    struct RenderError: LocalizedError {
        var errorDescription: String? { "Folio couldn't render this image. It may be too large for this Mac's graphics memory." }
    }

    /// The oriented original at `scale`, from the proxy when it is big enough, or the
    /// RAW development when `raw` is set and the source supports it.
    static func input(for source: SourceImage, raw: RAWSettings? = nil, scale: Double) throws -> CIImage {
        if let raw, let developed = try source.developed(raw, scale: scale) { return developed }
        let useProxy = scale <= source.proxyScale + 0.0001
        let base = useProxy ? source.proxyImage : try source.fullImage()
        // Map the base's own pixel grid to exactly `pixelSize * scale`.
        let sx = source.pixelSize.width * scale / base.extent.width
        let sy = source.pixelSize.height * scale / base.extent.height
        if abs(sx - 1) < 0.0001, abs(sy - 1) < 0.0001 { return base }
        return base.transformed(by: CGAffineTransform(scaleX: sx, y: sy), highQualityDownsample: true)
    }

    // MARK: Stages

    /// Cut-out, auto-enhance, adjustments, tone and filter: everything that changes color.
    static func filtered(
        _ input: CIImage, recipe: EditRecipe, assets: any AssetStore = InMemoryAssetStore(), scale: Double, mask: CIImage?
    ) -> CIImage {
        var image = input
        if recipe.removeBackground, let mask { image = BackgroundRemoval.apply(mask: mask, to: image) }
        if let auto = recipe.autoEnhance { image = apply(auto, to: image) }
        image = adjusted(image, recipe.adjustments, scale: scale)
        if !recipe.tone.isIdentity { image = ToneRenderer.apply(recipe.tone, to: image, assets: assets) }
        if let preset = recipe.filter { image = apply(preset, strength: recipe.filterStrength, to: image) }
        return image
    }

    /// Flip, turn, straighten and (optionally) crop. Vignette is framed on the result.
    static func transformed(_ image: CIImage, geometry: ImageGeometry, scale: Double, cropped: Bool) -> CIImage {
        let recipe = geometry.recipe
        // Straightening samples outside the original near the corners; clamping repeats
        // edge pixels there instead of blending in transparent black.
        let base = recipe.straighten != 0 ? image.clampedToExtent() : image
        var out = base.transformed(by: geometry.ciTransform(scale: scale, cropped: cropped), highQualityDownsample: true)
        let size = cropped ? geometry.croppedSize : geometry.canvasSize
        let frame = CGRect(x: 0, y: 0, width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        out = out.cropped(to: frame)
        let vignette = recipe.adjustments[.vignette] / 100
        if vignette != 0 {
            out = out.applyingFilter(
                "CIVignetteEffect",
                parameters: [
                    kCIInputCenterKey: CIVector(x: frame.midX, y: frame.midY),
                    kCIInputRadiusKey: hypot(frame.width, frame.height) * 0.42,
                    kCIInputIntensityKey: vignette,
                    "inputFalloff": 0.6,
                ]
            ).cropped(to: frame)
        }
        return out
    }

    /// Map slider values (−100…100) to Core Image parameters.
    static func adjusted(_ input: CIImage, _ a: Adjustments, scale: Double) -> CIImage {
        guard !a.isNeutral else { return input }
        func n(_ adjustment: Adjustment) -> Double { a[adjustment] / 100 }
        var image = input
        if n(.exposure) != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: n(.exposure) * 2])
        }
        if n(.brightness) != 0 {
            // Gamma lifts or lowers midtones without clipping black and white.
            image = image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": pow(2, -n(.brightness) * 0.8)])
        }
        if n(.contrast) != 0 || n(.saturation) != 0 {
            image = image.applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputContrastKey: 1 + n(.contrast) * 0.5,
                    kCIInputSaturationKey: 1 + n(.saturation),
                    kCIInputBrightnessKey: 0,
                ])
        }
        let highlights = n(.highlights), shadows = n(.shadows)
        if shadows != 0 || highlights < 0 {
            image = image.applyingFilter(
                "CIHighlightShadowAdjust",
                parameters: [
                    "inputShadowAmount": shadows,
                    "inputHighlightAmount": 1 + min(0, highlights),
                    kCIInputRadiusKey: max(1, 10 * scale),
                ])
        }
        if highlights > 0 {
            // CIHighlightShadowAdjust can only darken highlights; brighten them with a curve.
            image = image.applyingFilter(
                "CIToneCurve",
                parameters: [
                    "inputPoint0": CIVector(x: 0, y: 0),
                    "inputPoint1": CIVector(x: 0.25, y: 0.25),
                    "inputPoint2": CIVector(x: 0.5, y: 0.5 + 0.04 * highlights),
                    "inputPoint3": CIVector(x: 0.75, y: 0.75 + 0.12 * highlights),
                    "inputPoint4": CIVector(x: 1, y: 1),
                ])
        }
        if n(.vibrance) != 0 {
            image = image.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: n(.vibrance)])
        }
        if n(.warmth) != 0 || n(.tint) != 0 {
            image = temperature(image, warmth: n(.warmth), tint: n(.tint))
        }
        if n(.noiseReduction) != 0 {
            image = image.applyingFilter(
                "CINoiseReduction", parameters: ["inputNoiseLevel": 0.06 * n(.noiseReduction), kCIInputSharpnessKey: 0.4])
        }
        if n(.sharpness) != 0 {
            image = image.applyingFilter(
                "CISharpenLuminance",
                parameters: [
                    kCIInputSharpnessKey: n(.sharpness) * 1.5,
                    kCIInputRadiusKey: max(0.5, 2.5 * scale),
                ])
        }
        return image
    }

    /// Warmth > 0 warms (more red/yellow); tint > 0 shifts toward magenta.
    static func temperature(_ image: CIImage, warmth: Double, tint: Double) -> CIImage {
        // Telling Core Image the scene's neutral is cooler than it is warms the result.
        image.applyingFilter(
            "CITemperatureAndTint",
            parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - warmth * 2500, y: tint * 60),
            ])
    }

    static func apply(_ preset: FilterPreset, strength: Double, to image: CIImage) -> CIImage {
        let looked: CIImage =
            switch preset {
            case .mono: image.applyingFilter("CIPhotoEffectMono")
            case .noir: image.applyingFilter("CIPhotoEffectNoir")
            case .tonal: image.applyingFilter("CIPhotoEffectTonal")
            case .chrome: image.applyingFilter("CIPhotoEffectChrome")
            case .fade: image.applyingFilter("CIPhotoEffectFade")
            case .instant: image.applyingFilter("CIPhotoEffectInstant")
            case .process: image.applyingFilter("CIPhotoEffectProcess")
            case .transfer: image.applyingFilter("CIPhotoEffectTransfer")
            case .silvertone:
                image.applyingFilter(
                    "CIColorMonochrome",
                    parameters: [
                        kCIInputColorKey: CIColor(red: 0.80, green: 0.82, blue: 0.86), kCIInputIntensityKey: 1,
                    ]
                ).applyingFilter(
                    "CIColorControls", parameters: [kCIInputContrastKey: 1.15, kCIInputSaturationKey: 0.25, kCIInputBrightnessKey: 0.02])
            case .vivid:
                image.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: 0.6])
                    .applyingFilter(
                        "CIColorControls", parameters: [kCIInputSaturationKey: 1.2, kCIInputContrastKey: 1.06, kCIInputBrightnessKey: 0])
            case .warm: temperature(image, warmth: 0.35, tint: 0.05)
            case .cool: temperature(image, warmth: -0.35, tint: 0)
            }
        let strength = min(1, max(0, strength))
        if strength >= 0.999 { return looked }
        return image.applyingFilter(
            "CIDissolveTransition",
            parameters: [
                kCIInputTargetImageKey: looked, kCIInputTimeKey: strength,
            ])
    }

    // MARK: Auto-enhance

    /// Freeze Core Image's suggested corrections for `image` as data (red-eye off:
    /// it needs face positions that wouldn't survive a crop).
    static func autoEnhance(for image: CIImage) -> [FilterSpec] {
        image.autoAdjustmentFilters(options: [.redEye: false]).map { filter in
            var spec = FilterSpec(name: filter.name)
            for key in filter.inputKeys where key != kCIInputImageKey {
                switch filter.value(forKey: key) {
                case let number as NSNumber: spec.numbers[key] = number.doubleValue
                case let vector as CIVector: spec.vectors[key] = (0..<vector.count).map { Double(vector.value(at: $0)) }
                default: break
                }
            }
            return spec
        }
    }

    static func apply(_ specs: [FilterSpec], to image: CIImage) -> CIImage {
        specs.reduce(image) { image, spec in
            guard let filter = CIFilter(name: spec.name) else { return image }
            for (key, value) in spec.numbers { filter.setValue(value, forKey: key) }
            for (key, value) in spec.vectors {
                filter.setValue(CIVector(values: value.map { CGFloat($0) }, count: value.count), forKey: key)
            }
            filter.setValue(image, forKey: kCIInputImageKey)
            return filter.outputImage ?? image
        }
    }
}

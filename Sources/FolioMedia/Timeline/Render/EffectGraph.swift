import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Synchronization

/// Per-frame results of an analysis pass (WP4) that the renderer reads but never computes.
/// Missing results render the unprocessed picture and show up in `TimelineRender.pending`.
nonisolated protocol FrameMasks: Sendable {
    /// A grayscale mask over the source frame (white keeps), any size: it's stretched to the frame.
    func mask(at sourceTime: Time) -> CIImage?
}

nonisolated protocol CameraPath: Sendable {
    /// The full-strength correction for the frame at `sourceTime`, in source pixels with
    /// Core Image's y-up origin (bottom-left).
    func correction(at sourceTime: Time) -> CGAffineTransform
}

/// Maps a clip's effect stack onto a Core Image chain, top to bottom. Sizes in the model
/// are fractions of the frame height, so effects look the same at any resolution.
nonisolated enum EffectGraph {
    struct Context {
        var offset: Time
        var time: Time
        var sourceTime: Time?
        var source: MediaSource?
        var scene: RenderScene
    }

    static func apply(_ effects: [Effect], to image: CIImage, _ context: Context) -> CIImage {
        effects.reduce(image) { image, effect in
            effect.isEnabled ? apply(effect.kind, to: image, context).cropped(to: image.extent) : image
        }
    }

    private static func apply(_ kind: EffectKind, to image: CIImage, _ context: Context) -> CIImage {
        let extent = image.extent
        switch kind {
        case .color(let a): return adjust(image, a)
        case .look(let look, let intensity):
            let styled =
                look == .sepia
                ? image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 1])
                : image.applyingFilter("CIPhotoEffect" + look.rawValue.prefix(1).uppercased() + look.rawValue.dropFirst())
            return mix(image, styled, intensity)
        case .lut(let reference):
            guard let lut = context.scene.luts[reference.path] else { return image }
            return mix(image, applyLUT(lut, to: image, colorSpace: context.scene.colorSpace.cgColorSpace), reference.intensity)
        case .vignette(let intensity, let radius):
            return image.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: intensity, kCIInputRadiusKey: radius])
        case .sharpen(let amount):
            return image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: amount])
        case .blur(let radius):
            return image.clampedToExtent().applyingGaussianBlur(sigma: radius * extent.height)
        case .grain(let amount): return grain(image, amount: amount, time: context.time)
        case .chromaKey(let key): return chromaKey(image, key)
        case .removeBackground(let subject):
            guard let source = context.source, let time = context.sourceTime,
                let mask = context.scene.masks[RenderScene.maskKey(source.id, subject)]?.mask(at: time)
            else { return image }
            let m = mask.extent
            let fitted = mask.transformed(
                by: CGAffineTransform(translationX: -m.minX, y: -m.minY)
                    .concatenating(CGAffineTransform(scaleX: extent.width / m.width, y: extent.height / m.height))
                    .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
            return image.applyingFilter(
                "CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: fitted])
        case .redact(let regions): return redact(image, regions, offset: context.offset)
        case .stabilize(let strength):
            guard let source = context.source, let time = context.sourceTime,
                let path = context.scene.cameraPaths[source.id]
            else { return image }
            return stabilize(image, path.correction(at: time), strength: strength)
        case .denoise(let strength):
            // Live fallback; the builder swaps in the analysis pass's temporal denoise when cached.
            return image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.02 * strength, kCIInputSharpnessKey: 0.4])
        }
    }

    /// The fixed order: exposure, white balance, highlights/shadows, contrast/saturation, vibrance.
    static func adjust(_ image: CIImage, _ a: ColorAdjustments) -> CIImage {
        var image = image
        if a.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
        if a.temperature != 6500 || a.tint != 0 {
            image = image.applyingFilter(
                "CITemperatureAndTint",
                parameters: ["inputNeutral": CIVector(x: a.temperature, y: a.tint), "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        if a.highlights != 1 || a.shadows != 0 {
            image = image.applyingFilter(
                "CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": a.highlights, "inputShadowAmount": a.shadows])
        }
        if a.contrast != 1 || a.saturation != 1 {
            image = image.applyingFilter(
                "CIColorControls", parameters: [kCIInputContrastKey: a.contrast, kCIInputSaturationKey: a.saturation])
        }
        if a.vibrance != 0 { image = image.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: a.vibrance]) }
        return image
    }

    /// `amount` of the way from `a` to `b`.
    static func mix(_ a: CIImage, _ b: CIImage, _ amount: Double) -> CIImage {
        if amount >= 1 { return b }
        if amount <= 0 { return a }
        return b.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: a, kCIInputTimeKey: 1 - amount])
    }

    static func applyLUT(_ lut: CubeLUT, to image: CIImage, colorSpace: CGColorSpace) -> CIImage {
        var input = image
        if !lut.hasUnitDomain {
            // Map DOMAIN_MIN…MAX onto the cube's 0…1.
            let s = (0..<3).map { 1 / (lut.domainMax[$0] - lut.domainMin[$0]) }
            input = input.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: s[0], y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s[1], z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: s[2], w: 0),
                    "inputBiasVector": CIVector(x: -lut.domainMin[0] * s[0], y: -lut.domainMin[1] * s[1], z: -lut.domainMin[2] * s[2], w: 0),
                ]
            ).applyingFilter("CIColorClamp")
        }
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = input
        cube.cubeDimension = Float(lut.size)
        cube.cubeData = lut.cube
        cube.colorSpace = colorSpace
        return cube.outputImage ?? image
    }

    private static func grain(_ image: CIImage, amount: Double, time: Time) -> CIImage {
        guard amount > 0, let noise = CIFilter.randomGenerator().outputImage else { return image }
        // A different patch of noise every frame.
        let frame = Int((time.seconds * 60).rounded())
        let shifted = noise.transformed(by: CGAffineTransform(translationX: CGFloat(frame * 97 % 1024), y: CGFloat(frame * 61 % 1024)))
        let gray = shifted.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 0, y: amount, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: amount, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0.5 * (1 - amount), y: 0.5 * (1 - amount), z: 0.5 * (1 - amount), w: 1),
            ]
        ).cropped(to: image.extent)
        return gray.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    }

    // MARK: Chroma key

    private static let keyCubes = Mutex<[String: Data]>([:])
    private static let keySize = 48

    /// Apple's colour-cube key: distance from the key colour in the chroma plane (luma
    /// ignored, so shadows on the screen still key) becomes alpha; spill is pulled down.
    private static func chromaKey(_ image: CIImage, _ key: ChromaKey) -> CIImage {
        let id = "\(key)"
        let data =
            keyCubes.withLock { $0[id] }
            ?? {
                let made = keyCube(key)
                keyCubes.withLock {
                    if $0.count > 16 { $0.removeAll() }
                    $0[id] = made
                }
                return made
            }()
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = image
        cube.cubeDimension = Float(keySize)
        cube.cubeData = data
        cube.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        return cube.outputImage ?? image
    }

    static func keyCube(_ key: ChromaKey) -> Data {
        func chroma(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double) {
            (-0.168736 * r - 0.331264 * g + 0.5 * b, 0.5 * r - 0.418688 * g - 0.081312 * b)
        }
        let n = keySize
        let k = chroma(key.color.red, key.color.green, key.color.blue)
        let channels = [key.color.red, key.color.green, key.color.blue]
        let dominant = channels.firstIndex(of: channels.max()!)!
        let lo = key.tolerance, hi = key.tolerance + max(0.001, key.softness)
        var values = [Float]()
        values.reserveCapacity(n * n * n * 4)
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    var c = [Double(ri), Double(gi), Double(bi)].map { $0 / Double(n - 1) }
                    let p = chroma(c[0], c[1], c[2])
                    // ×1.5 spreads the distance (at most ~0.7 in this plane) over 0…1.
                    let d = hypot(p.0 - k.0, p.1 - k.1) * 1.5
                    let alpha = min(1, max(0, (d - lo) / (hi - lo)))
                    let others = (0..<3).filter { $0 != dominant }.map { c[$0] }.reduce(0, +) / 2
                    if c[dominant] > others { c[dominant] = others + (c[dominant] - others) * (1 - key.spillSuppression) }
                    values += [Float(c[0] * alpha), Float(c[1] * alpha), Float(c[2] * alpha), Float(alpha)]
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: Regions

    private static func redact(_ image: CIImage, _ regions: [RedactRegion], offset: Time) -> CIImage {
        let extent = image.extent
        return regions.reduce(image) { image, region in
            let r = region.rect.value(at: offset)
            let rect = CGRect(
                x: extent.minX + r.x * extent.width, y: extent.minY + (1 - r.y - r.height) * extent.height,
                width: r.width * extent.width, height: r.height * extent.height
            ).intersection(extent)
            guard !rect.isEmpty else { return image }
            let patch: CIImage
            switch region.style {
            case .blur:
                patch = image.clampedToExtent().applyingGaussianBlur(sigma: max(2, region.amount * 0.05 * extent.height))
            case .pixelate:
                patch = image.clampedToExtent().applyingFilter(
                    "CIPixellate",
                    parameters: [
                        kCIInputScaleKey: max(2, region.amount * 0.08 * extent.height), kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY),
                    ])
            case .fill: patch = CIImage(color: region.fill.ciColor)
            }
            return patch.cropped(to: rect).composited(over: image)
        }
    }

    private static func stabilize(_ image: CIImage, _ full: CGAffineTransform, strength: Double) -> CIImage {
        let s = min(1, max(0, strength))
        let t = CGAffineTransform(
            a: 1 + (full.a - 1) * s, b: full.b * s, c: full.c * s, d: 1 + (full.d - 1) * s, tx: full.tx * s, ty: full.ty * s)
        // Zoom in a little so the moving edges stay outside the frame.
        let e = image.extent, zoom = 1 + 0.1 * s
        let around = CGAffineTransform(translationX: -e.midX, y: -e.midY).concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
            .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY))
        return image.clampedToExtent().transformed(by: t.concatenating(around)).cropped(to: e)
    }
}

nonisolated extension ColorSpace {
    var cgColorSpace: CGColorSpace {
        let name =
            switch self {
            case .rec709: CGColorSpace.itur_709
            case .displayP3: CGColorSpace.displayP3
            case .rec2020HLG: CGColorSpace.itur_2100_HLG
            case .rec2020PQ: CGColorSpace.itur_2100_PQ
            }
        return CGColorSpace(name: name) ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }
}

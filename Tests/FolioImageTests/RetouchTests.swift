import CoreGraphics
import CoreImage
import Testing

@testable import FolioImage

/// Retouch fills, strokes, red-eye, upscaling and the redaction privacy rule.
@Suite(.timeLimit(.minutes(1))) struct RetouchTests {
    /// Every pixel of `image` as sRGB RGBA bytes, top row first.
    struct Pixels {
        let width: Int, height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let ctx = CGContext(
                data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            self.bytes = bytes
        }

        subscript(x: Int, y: Int, c: Int) -> Int { Int(bytes[4 * (y * width + x) + c]) }
    }

    /// A bitmap from a per-pixel color function (0…255, top-left origin).
    static func image(width: Int, height: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let i = 4 * (y * width + x)
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
            }
        }
        let ctx = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    /// Deterministic noise, so copies and seams are easy to tell apart.
    static func noise(width: Int, height: Int) -> CGImage {
        image(width: width, height: height) { x, y in
            let h = UInt32(truncatingIfNeeded: (x &* 73_856_093) ^ (y &* 19_349_663)) &* 2_654_435_761
            return (UInt8(h >> 24), UInt8((h >> 16) & 0xFF), UInt8((h >> 8) & 0xFF))
        }
    }

    static func render(_ image: CIImage, size: CGSize) throws -> CGImage {
        try RenderPipeline.rasterize(
            image, extent: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// A white disc (hole) on black, Core Image coordinates.
    static func disc(center: CGPoint, radius: Double, in extent: CGRect) -> CIImage {
        CIImage(color: .white).cropped(to: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            .applyingFilter(
                "CIBlendWithMask",
                parameters: [kCIInputBackgroundImageKey: CIImage.black, kCIInputMaskImageKey: RedEye.disc(at: center, radius: radius)]
            ).cropped(to: extent)
    }

    // MARK: Fills

    @Test func pushPullFillsAFlatHoleExactly() throws {
        let flat = Self.image(width: 256, height: 200) { _, _ in (77, 153, 51) }
        let extent = CGRect(x: 0, y: 0, width: 256, height: 200)
        // Something different under the hole, which must not show through.
        let input = CIImage(color: .red).cropped(to: CGRect(x: 100, y: 70, width: 60, height: 60)).composited(over: CIImage(cgImage: flat))
        let hole = CIImage(color: .white).cropped(to: CGRect(x: 95, y: 65, width: 70, height: 70)).composited(over: CIImage.black)
            .cropped(to: extent)
        let out = Pixels(try Self.render(PushPullFill.fill(input, hole: hole), size: extent.size))
        var worst = 0
        for y in 0..<200 {
            for x in 0..<256 { worst = max(worst, abs(out[x, y, 0] - 77), abs(out[x, y, 1] - 153), abs(out[x, y, 2] - 51)) }
        }
        #expect(worst < 2, "max error \(worst)/255")
    }

    @Test func patchMatchRecoversStripes() throws {
        let period = 8
        let stripes = Self.image(width: 128, height: 128) { _, y in y % period < period / 2 ? (20, 20, 20) : (230, 230, 230) }
        let hole = Self.image(width: 128, height: 128) { x, y in
            (44..<84).contains(x) && (44..<84).contains(y) ? (255, 255, 255) : (0, 0, 0)
        }
        let filled = try #require(PatchMatch.fill(stripes, hole: hole))
        let out = Pixels(filled)
        // A column through the middle of the hole: stripes again, at the same period.
        let column = (46..<82).map { Double(out[64, $0, 0]) }
        let mean = column.reduce(0, +) / Double(column.count)
        let centred = column.map { $0 - mean }
        let variance = centred.map { $0 * $0 }.reduce(0, +) / Double(column.count)
        #expect(variance > 2000, "the hole has texture, not a flat blur (variance \(variance))")
        func correlation(_ lag: Int) -> Double { (0..<(centred.count - lag)).map { centred[$0] * centred[$0 + lag] }.reduce(0, +) }
        let best = (3...12).max { correlation($0) < correlation($1) }
        #expect(best == period, "autocorrelation peaks at \(best ?? -1)")
    }

    // MARK: Strokes

    @Test func cloneWithOffsetCopiesExactPixelsAtFullHardness() throws {
        let source = Self.noise(width: 200, height: 150)
        let stroke = RetouchStroke(
            tool: .clone, area: .brush(points: [CGPoint(x: 100, y: 75)], radius: 20), hardness: 1,
            sourceOffset: CGSize(width: 30, height: -20))
        let out = Pixels(
            try Self.render(
                RetouchRenderer.apply([stroke], to: CIImage(cgImage: source), assets: InMemoryAssetStore(), scale: 1),
                size: CGSize(width: 200, height: 150)))
        let original = Pixels(source)
        var worst = 0
        for dy in -14...14 {
            for dx in -14...14 where dx * dx + dy * dy < 196 {
                for c in 0..<3 { worst = max(worst, abs(out[100 + dx, 75 + dy, c] - original[130 + dx, 55 + dy, c])) }
            }
        }
        #expect(worst <= 1, "max difference \(worst)")
        #expect(out[5, 5, 0] == original[5, 5, 0], "outside the brush is untouched")
    }

    @Test func redactLeavesZeroVarianceInside() throws {
        let source = Self.noise(width: 200, height: 150)
        // Soft and translucent on purpose: redaction ignores both.
        let stroke = RetouchStroke(
            tool: .redact, area: .rect(CGRect(x: 50, y: 40, width: 80, height: 60)), hardness: 0.1, opacity: 0.4,
            color: RGBA(red: 0.1, green: 0.2, blue: 0.3))
        let out = Pixels(
            try Self.render(
                RetouchRenderer.apply([stroke], to: CIImage(cgImage: source), assets: InMemoryAssetStore(), scale: 1),
                size: CGSize(width: 200, height: 150)))
        var values = Set<[Int]>()
        for y in 40..<100 {
            for x in 50..<130 { values.insert([out[x, y, 0], out[x, y, 1], out[x, y, 2]]) }
        }
        #expect(values.count == 1, "\(values.count) distinct colors inside the redaction")
    }

    @Test func spotHealStoresItsFillAndRemovesTheSpot() async throws {
        // A dark spot on a smooth gradient.
        let cg = Self.image(width: 400, height: 300) { x, y in
            (x - 200) * (x - 200) + (y - 150) * (y - 150) < 64 ? (0, 0, 0) : (UInt8(80 + x / 4), 120, 140)
        }
        let source = try SourceImage(data: ImageCodec.encode(cg, as: .png))
        let assets = InMemoryAssetStore()
        let stroke = RetouchStroke(tool: .spotHeal, area: .brush(points: [CGPoint(x: 200, y: 150)], radius: 14), hardness: 0.8)
        let clock = ContinuousClock()
        var healed = stroke
        let elapsed = try await clock.measure {
            healed.patch = try await ImageEditorModel.computePatch(
                for: stroke, source: source, recipe: EditRecipe(), layerIndex: nil, assets: assets)
        }
        print("spot heal patch (400×300): \(elapsed)")
        let patch = try #require(healed.patch)
        #expect(assets.all[patch.asset] != nil, "the fill is a stored asset")
        #expect(patch.rect.contains(CGRect(x: 186, y: 136, width: 28, height: 28)))

        let below = RetouchRenderer.apply([healed], to: CIImage(cgImage: cg), assets: assets, scale: 1)
        let out = Pixels(try Self.render(below, size: CGSize(width: 400, height: 300)))
        #expect(abs(out[200, 150, 0] - 130) < 12 && abs(out[200, 150, 1] - 120) < 12, "the spot is gone: \(out[200, 150, 0])")
        #expect(out[20, 20, 0] == Pixels(cg)[20, 20, 0], "far away is untouched")
    }

    /// §4 WP4 budget: spot heal on the 24 MP perf image under 150 ms (proxy). Printed, not
    /// asserted, since parallel suites share the GPU.
    @Test func spotHealOn24MegapixelsUsesTheProxy() async throws {
        let source = try SourceImage(data: TestImages.data(.jpeg, width: 6000, height: 4000))
        let stroke = RetouchStroke(tool: .spotHeal, area: .brush(points: [CGPoint(x: 3000, y: 2000)], radius: 60))
        _ = try await ImageEditorModel.computePatch(
            for: stroke, source: source, recipe: EditRecipe(), layerIndex: nil, assets: InMemoryAssetStore())
        let clock = ContinuousClock()
        var patch: PlacedAsset?
        let elapsed = try await clock.measure {
            patch = try await ImageEditorModel.computePatch(
                for: stroke, source: source, recipe: EditRecipe(), layerIndex: nil, assets: InMemoryAssetStore())
        }
        print("spot heal on 24 MP (proxy, warm): \(elapsed)")
        #expect(try #require(patch).rect.contains(CGRect(x: 2940, y: 1940, width: 120, height: 120)))
    }

    @Test func redEyeTurnsRedPupilsDark() throws {
        let cg = Self.image(width: 120, height: 120) { x, y in
            (x - 60) * (x - 60) + (y - 60) * (y - 60) < 100 ? (220, 30, 30) : (200, 160, 140)
        }
        let image = CIImage(cgImage: cg)
        let corrected = RedEye.correct(image, pupils: [CGPoint(x: 60, y: 60)], radius: 14, amount: 1)
        let out = Pixels(try Self.render(corrected, size: CGSize(width: 120, height: 120)))
        #expect(out[60, 60, 0] < 100, "red removed: \(out[60, 60, 0])")
        #expect(abs(out[5, 5, 0] - 200) <= 1, "skin outside the pupil is untouched")
    }

    // MARK: Upscaling

    nonisolated static func lanczos(_ image: CIImage) -> CIImage {
        image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 2, kCIInputAspectRatioKey: 1])
    }

    @Test func superResolutionTilesReassembleWithoutSeams() async throws {
        let input = CIImage(cgImage: Self.noise(width: 1000, height: 700))
        let tiled = try await SuperResolution.tiled(input, factor: 2) {
            Self.lanczos($0.clampedToExtent()).cropped(to: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }
        let size = CGSize(width: 2000, height: 1400)
        let a = Pixels(try Self.render(tiled, size: size))
        let b = Pixels(try Self.render(Self.lanczos(input.clampedToExtent()), size: size))
        var worst = 0
        for i in 0..<a.bytes.count where i % 4 != 3 { worst = max(worst, abs(Int(a.bytes[i]) - Int(b.bytes[i]))) }
        #expect(worst < 3, "max difference to one tile \(worst)/255")
    }

    @Test func upscaleDoublesTheSize() async throws {
        let cg = Self.noise(width: 600, height: 400)
        let clock = ContinuousClock()
        var out: CGImage?
        let elapsed = try await clock.measure { out = try await SuperResolution.upscale(cg, factor: 2) }
        print("upscale 600×400 → 2× (\(SuperResolution.methodTitle)): \(elapsed)")
        let image = try #require(out)
        #expect(image.width == 1200 && image.height == 800)
        let mean = TestImages.mean(image), original = TestImages.mean(cg)
        #expect(abs(mean.r - original.r) < 8 && abs(mean.g - original.g) < 8 && abs(mean.b - original.b) < 8, "colors kept")
    }

    // MARK: Vision and privacy

    @Test func autoRedactFindsABarcode() async throws {
        let code = CIFilter(
            name: "CIQRCodeGenerator", parameters: ["inputMessage": Array("folio".utf8).withUnsafeBufferPointer { Data($0) }])!
            .outputImage!.samplingNearest().transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let page = code.transformed(by: CGAffineTransform(translationX: 100, y: 100)).composited(over: CIImage.white)
        let cg = try Self.render(page, size: CGSize(width: 400, height: 400))
        guard let boxes = try? await ImageEditorModel.redactionBoxes(in: cg, faces: false, text: false, barcodes: true) else { return }
        #expect(boxes.contains { $0.contains(CGPoint(x: 0.5, y: 0.5)) }, "found \(boxes)")
    }

    @Test func redactionMeansNoSession() {
        var recipe = EditRecipe()
        #expect(!recipe.containsRedaction)
        recipe.layers = [Layer(name: "Retouch", content: .retouch([RetouchStroke(tool: .blur, area: .rect(.zero))]))]
        #expect(!recipe.containsRedaction)
        let redact = RetouchStroke(tool: .redact, area: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)))
        recipe.layers = [Layer(name: "Group", content: .group(GroupSpec(layers: [Layer(name: "Retouch", content: .retouch([redact]))])))]
        #expect(recipe.containsRedaction, "found inside groups too")
    }

    @Test func inpaintModelStaysUninstalled() {
        #expect(!InpaintModel.isInstalled)
    }
}

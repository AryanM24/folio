import CoreGraphics
import CoreImage
import Testing

@testable import FolioImage

/// Curves, levels, HSL, color balance, mixer, white balance, LUT files, histogram and presets.
@Suite(.timeLimit(.minutes(1))) struct ToneTests {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private func render(_ tone: ToneSpec, _ image: CIImage, assets: any AssetStore = InMemoryAssetStore()) -> CGImage {
        let out = ToneRenderer.apply(tone, to: image, assets: assets)
        return RenderPipeline.context.createCGImage(out, from: image.extent, format: .RGBA8, colorSpace: Self.srgb)!
    }

    /// A flat sRGB color, 8×8 px.
    private func solid(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: Self.srgb)!).cropped(
            to: CGRect(x: 0, y: 0, width: 8, height: 8))
    }

    private func expectUnchanged(
        _ tone: ToneSpec, assets: any AssetStore = InMemoryAssetStore(), sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let original = TestImages.cgImage()
        let out = render(tone, CIImage(cgImage: original), assets: assets)
        for (x, y) in [(5, 5), (100, 200), (200, 150), (399, 299), (320, 40)] {
            let (a, b) = (TestImages.pixel(original, x: x, y: y), TestImages.pixel(out, x: x, y: y))
            #expect(
                abs(a.r - b.r) <= 1 && abs(a.g - b.g) <= 1 && abs(a.b - b.b) <= 1, "pixel \(x),\(y): \(a) → \(b)",
                sourceLocation: sourceLocation)
        }
    }

    private static func cube(
        size: Int, header: String = "", transform: (Double, Double, Double) -> (Double, Double, Double) = { ($0, $1, $2) }
    )
        -> Data
    {
        var lines = ["# made by a test", "TITLE \"Test\"", "LUT_3D_SIZE \(size)", header]
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let n = Double(size - 1)
                    let (x, y, z) = transform(Double(r) / n, Double(g) / n, Double(b) / n)
                    lines.append("\(x) \(y) \(z)")
                }
            }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    // MARK: Identity

    @Test func identityCurveLeavesPixelsUnchanged() {
        var tone = ToneSpec()
        tone.curves.red = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)]
        tone.curves.rgb = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        expectUnchanged(tone)
    }

    @Test func identityLevelsLeavePixelsUnchanged() {
        var tone = ToneSpec()
        tone.levels.green = LevelsChannel(inputBlack: 0, inputWhite: 1, gamma: 1, outputBlack: 0, outputWhite: 1)
        // A curve forces the LUT stage to run with these levels.
        tone.curves.blue = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        expectUnchanged(tone)
    }

    @Test func identityLUTLeavesPixelsUnchanged() throws {
        let store = InMemoryAssetStore()
        var tone = ToneSpec()
        tone.lut = LUTRef(asset: store.put(Self.cube(size: 17)), name: "Identity")
        expectUnchanged(tone, assets: store)
    }

    // MARK: Curves and levels

    @Test func curvePointMapsMidGray() {
        let curve = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.75), CGPoint(x: 1, y: 1)]
        #expect(abs(ToneCurve(curve)(0.5) - 0.75) < 0.0001)
        var tone = ToneSpec()
        tone.curves.rgb = curve
        let out = TestImages.pixel(render(tone, solid(0.5, 0.5, 0.5)), x: 4, y: 4)
        #expect(abs(out.r - 191) <= 2 && abs(out.g - 191) <= 2 && abs(out.b - 191) <= 2, "\(out)")
    }

    @Test func splineIsMonotonicWithoutOvershoot() {
        let points = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0.3, y: 0.05), CGPoint(x: 0.35, y: 0.9), CGPoint(x: 0.8, y: 0.92), CGPoint(x: 1, y: 1),
        ]
        let curve = ToneCurve(points)
        var previous = -1.0
        for i in 0...1000 {
            let x = Double(i) / 1000
            let y = curve(x)
            #expect(y >= previous - 1e-12, "falls at \(x)")
            previous = y
            // Between two points the value stays between their outputs.
            if let k = points.indices.last(where: { Double(points[$0].x) <= x }), k + 1 < points.count {
                #expect(y >= Double(points[k].y) - 1e-9 && y <= Double(points[k + 1].y) + 1e-9, "overshoots at \(x)")
            }
        }
        for p in points { #expect(abs(curve(Double(p.x)) - Double(p.y)) < 1e-9) }
    }

    @Test func levelsFollowPhotoshop() {
        let levels = LevelsChannel(inputBlack: 0.2, inputWhite: 0.8, gamma: 2, outputBlack: 0.1, outputWhite: 0.9)
        #expect(levels.map(0.1) == 0.1)
        #expect(levels.map(0.9) == 0.9)
        #expect(abs(levels.map(0.5) - (0.1 + 0.8 * 0.5.squareRoot())) < 1e-9, "gamma 2 lightens midtones")
    }

    // MARK: Color

    @Test func hslDesaturatesOnlyItsBand() {
        var tone = ToneSpec()
        tone.hsl[.red] = HSLShift(saturation: -100)
        let red = TestImages.pixel(render(tone, solid(0.9, 0.1, 0.1)), x: 4, y: 4)
        #expect(abs(red.r - red.g) <= 3 && abs(red.g - red.b) <= 3, "red turns gray: \(red)")
        let blue = TestImages.pixel(render(tone, solid(0.1, 0.2, 0.9)), x: 4, y: 4)
        #expect(blue.b > 200 && blue.r < 40, "blue is left alone: \(blue)")
    }

    @Test func colorBalanceWarmsHighlights() {
        var tone = ToneSpec()
        tone.colorBalance.highlights = ColorShift(cyanRed: 50, yellowBlue: -50)
        let out = TestImages.pixel(render(tone, solid(0.8, 0.8, 0.8)), x: 4, y: 4)
        #expect(out.r > out.g && out.g > out.b, "\(out)")
        let dark = TestImages.pixel(render(tone, solid(0.05, 0.05, 0.05)), x: 4, y: 4)
        #expect(abs(dark.r - dark.b) <= 3, "shadows barely move: \(dark)")
    }

    @Test func monochromeMixerMakesGray() {
        var tone = ToneSpec()
        tone.channelMixer = ChannelMixer(red: .init(red: 0.3, green: 0.6, blue: 0.1), monochrome: true)
        let out = TestImages.pixel(render(tone, solid(0.9, 0.2, 0.4)), x: 4, y: 4)
        #expect(out.r == out.g && out.g == out.b)
    }

    @Test func whiteBalanceEyedropperNeutralizesTheSample() throws {
        // A warm cast, as from tungsten light.
        let warm = solid(0.75, 0.6, 0.4)
        let wb = try #require(ToneRenderer.whiteBalance(neutralizing: warm, in: warm.extent))
        #expect(wb.temperature < 6500, "a warm sample means warm light: \(wb)")
        var tone = ToneSpec()
        tone.whiteBalance = wb
        let out = TestImages.pixel(render(tone, warm), x: 4, y: 4)
        #expect(abs(out.r - out.g) <= 3 && abs(out.g - out.b) <= 3, "\(out) with \(wb)")
    }

    // MARK: LUT files

    @Test func cubeParserReadsCommentsDomainAnd3D() throws {
        let lut = try CubeLUT(data: Self.cube(size: 2, header: "DOMAIN_MIN 0 0 0 # inline comment\nDOMAIN_MAX 1 2 1\n\n"))
        #expect(lut.title == "Test" && lut.dimension == 3 && lut.size == 2)
        #expect(lut.domainMax == [1, 2, 1])
        #expect(lut.values.count == 24)
        #expect(Array(lut.values[3..<6]) == [1, 0, 0], "red varies fastest")
    }

    @Test func cubeParserReads1D() throws {
        let text = "LUT_1D_SIZE 3\n# half brightness\n0 0 0\n0.25 0.25 0.25\n0.5 0.5 0.5\n"
        let lut = try CubeLUT(data: Data(text.utf8))
        #expect(lut.dimension == 1 && lut.size == 3 && lut.values.last == 0.5)
        var tone = ToneSpec()
        let store = InMemoryAssetStore()
        tone.lut = LUTRef(asset: store.put(Data(text.utf8)), name: "Half")
        let out = TestImages.pixel(render(tone, solid(1, 1, 1), assets: store), x: 4, y: 4)
        #expect(abs(out.r - 128) <= 2, "\(out)")
    }

    @Test func cubeParserRejectsWrongCount() {
        var text = String(decoding: Self.cube(size: 3), as: UTF8.self)
        text += "\n0.5 0.5 0.5\n"
        #expect(throws: (any Error).self) { try CubeLUT(data: Data(text.utf8)) }
        #expect(throws: (any Error).self) { try CubeLUT(data: Data("LUT_3D_SIZE 2\n0 0 0\n1 1\n".utf8)) }
        #expect(throws: (any Error).self) { try CubeLUT(data: Data("hello".utf8)) }
    }

    @Test func threeDLMatchesCube() throws {
        // 2³, blue fastest, 10-bit outputs.
        var lines = ["0 1023"]
        for r in 0..<2 { for g in 0..<2 { for b in 0..<2 { lines.append("\(r * 1023) \(g * 1023) \(b * 1023)") } } }
        let lut = try CubeLUT(data: Data(lines.joined(separator: "\n").utf8))
        #expect(lut == (try CubeLUT(data: Self.cube(size: 2))).with(title: nil))
    }

    @Test func lutStrengthMixes() throws {
        let store = InMemoryAssetStore()
        var tone = ToneSpec()
        tone.lut = LUTRef(asset: store.put(Self.cube(size: 9) { r, g, b in (1 - r, 1 - g, 1 - b) }), name: "Invert", strength: 1)
        #expect(TestImages.pixel(render(tone, solid(1, 1, 1), assets: store), x: 4, y: 4).r < 3)
        tone.lut?.strength = 0.5
        let half = TestImages.pixel(render(tone, solid(1, 1, 1), assets: store), x: 4, y: 4)
        #expect(half.r > 60 && half.r < 200, "\(half)")
    }

    // MARK: Histogram

    @Test func histogramOfSolidColorHasOneBinPerChannel() {
        let h = Histogram.compute(solid(0.3, 0.6, 0.9).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)))
        for channel in [h.red, h.green, h.blue, h.luminance] {
            #expect(channel.count == Histogram.bins)
            #expect(channel.filter { $0 > 0 }.count == 1)
        }
        #expect(h.red.firstIndex { $0 > 0 }.map { abs($0 - 76) <= 1 } == true)
        #expect([h.red, h.green, h.blue, h.luminance].joined().max() == 1)
    }

    // MARK: Presets

    @Test func presetsRoundTripAndApplyToAnotherSize() throws {
        let store = InMemoryAssetStore()
        var recipe = EditRecipe()
        recipe.adjustments[.exposure] = 20
        recipe.tone.curves.rgb = [CGPoint(x: 0, y: 0.1), CGPoint(x: 1, y: 0.9)]
        recipe.tone.whiteBalance = WhiteBalance(temperature: 4000, tint: 5)
        recipe.tone.lut = LUTRef(asset: store.put(Self.cube(size: 2)), name: "Identity", strength: 0.8)
        recipe.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let preset = try ImagePreset(name: "Look", recipe: recipe, store: store)
        let decoded = try JSONDecoder().decode(ImagePreset.self, from: JSONEncoder().encode(preset))
        #expect(decoded == preset)
        #expect(decoded.tone?.whiteBalance == nil, "white balance stays with the photo")

        let other = InMemoryAssetStore()
        let applied = try decoded.applied(to: EditRecipe(), store: other)
        #expect(applied.crop == EditRecipe.fullCrop, "geometry isn't part of a preset")
        #expect(
            applied.tone
                == {
                    var t = recipe.tone; t.whiteBalance = nil; return t
                }())
        #expect(applied.adjustments == recipe.adjustments)
        #expect((try? other.data(recipe.tone.lut!.asset)) != nil, "the LUT came along")

        for (w, h) in [(400, 300), (120, 260)] {
            let source = try SourceImage(data: TestImages.data(.png, width: w, height: h))
            let out = try RenderPipeline.render(source, recipe: applied, assets: other)
            #expect(out.width == w && out.height == h)
            #expect(TestImages.pixel(out, x: 2, y: 2).r < 245, "the lowered white point shows")
        }
    }

    @Test func builtInPresetsAllRender() throws {
        let source = try SourceImage(data: TestImages.data(.png))
        #expect(Set(ImagePreset.builtIn.map(\.id)).count == ImagePreset.builtIn.count)
        for preset in ImagePreset.builtIn {
            let recipe = try preset.applied(to: EditRecipe(), store: InMemoryAssetStore())
            #expect(!recipe.tone.isIdentity, "\(preset.name)")
            let out = try RenderPipeline.render(source, recipe: recipe)
            #expect(out.width == 400, "\(preset.name)")
        }
    }

    @Test func presetLibrarySavesLoadsAndDeletes() throws {
        let directory = URL.temporaryDirectory.appending(path: "folio-presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PresetLibrary(directory: directory)
        let preset = ImagePreset.builtIn[0]
        try library.save(preset)
        #expect(library.load() == [preset])
        try library.delete(preset)
        #expect(library.load().isEmpty)
    }

    // MARK: Speed

    @Test func everyStageRendersAProxyQuickly() throws {
        let store = InMemoryAssetStore()
        var tone = ImagePreset.builtIn[3].tone!
        tone.levels.rgb.gamma = 1.2
        tone.whiteBalance = WhiteBalance(temperature: 5000, tint: 4)
        tone.channelMixer = ChannelMixer(red: .init(red: 0.9, green: 0.1))
        tone.lut = LUTRef(asset: store.put(Self.cube(size: 33) { ($0 * 0.9, $1, $2 * 0.95) }), name: "Look", strength: 0.7)
        let proxy = CIImage(cgImage: TestImages.cgImage(width: 2048, height: 1365))
        _ = render(tone, proxy, assets: store)  // compile kernels, warm caches
        let clock = ContinuousClock()
        let frames = 5
        let elapsed = clock.measure { for _ in 0..<frames { _ = render(tone, proxy, assets: store) } }
        let perFrame = elapsed / frames
        print("Tone: every stage on a 2048×1365 proxy, \(perFrame) per frame")
        #expect(perFrame < .seconds(1), "a GPU path, not a CPU fallback")
    }
}

extension CubeLUT {
    fileprivate func with(title: String?) -> CubeLUT {
        var copy = self
        copy.title = title
        return copy
    }
}

import CoreGraphics
import CoreImage
import FolioKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import FolioImage

/// WP6 I/O: packages, sessions with assets and guides, the redaction privacy rule,
/// animations, SVG, RAW, HDR, layered PSD, export sizes, target file size and batch presets.
@Suite(.timeLimit(.minutes(1))) struct FormatTests {
    static func store() -> EditSessionStore {
        EditSessionStore(root: URL.temporaryDirectory.appending(path: "folio-wp6-sessions-\(UUID().uuidString)"))
    }

    static func folder() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "folio-wp6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func snapshot(
        _ source: SourceImage, _ recipe: EditRecipe, _ assets: InMemoryAssetStore = InMemoryAssetStore()
    )
        -> ImageDocument.Snapshot
    {
        ImageDocument.Snapshot(source: source, recipe: recipe, assets: assets, session: SessionKey(nil))
    }

    /// A solid-color image.
    static func solid(width: Int = 40, height: Int = 30, red: Double, alpha: Bool = false) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        ctx.setFillColor(CGColor(srgbRed: red, green: 0.2, blue: 1 - red, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    static func solidPNG(width: Int = 40, height: Int = 30, red: Double) -> Data {
        try! ImageCodec.encode(solid(width: width, height: height, red: red, alpha: true), as: .png)
    }

    /// The layer count field of a PSD (after the 26-byte header and three section lengths).
    static func layerCount(_ psd: Data) -> Int {
        Int(Int16(bitPattern: UInt16(psd[42]) << 8 | UInt16(psd[43])))
    }

    // MARK: Packages and sessions

    @Test func packageRoundTripKeepsOriginalRecipeAndAssets() throws {
        #expect(FolioImagePackage.typeIdentifier == UTType.folioImageDocument.identifier)
        let original = TestImages.data(.jpeg)
        let source = try SourceImage(data: original)
        let assets = InMemoryAssetStore()
        let used = assets.put(Self.solidPNG(red: 1))
        assets.put(Self.solidPNG(red: 0.5))
        var recipe = EditRecipe()
        recipe.layers = [Layer(name: "Pasted", content: .pixels(used))]
        recipe.guides = [Guide(axis: .vertical, position: 120)]
        let wrapper = try ImageDocument.package(for: Self.snapshot(source, recipe, assets)).fileWrapper()
        #expect(wrapper.fileWrappers?["preview.heic"]?.regularFileContents?.isEmpty == false)
        #expect(wrapper.fileWrappers?["original.jpeg"] != nil)
        let back = try FolioImagePackage(fileWrapper: wrapper)
        #expect(back.recipe == recipe)
        #expect(back.original == original, "byte-equal original")
        #expect(back.originalTypeIdentifier == UTType.jpeg.identifier)
        #expect(back.assets == [used: try assets.data(used)], "only referenced assets are saved")
        #expect(ImageDocument.writableContentTypes.contains(.folioImageDocument))
    }

    @Test func damagedPackageHasPlainError() {
        let empty = FileWrapper(directoryWithFileWrappers: [:])
        #expect(throws: FolioError.self) { try FolioImagePackage(fileWrapper: empty) }
    }

    @Test func sessionsKeepLayerAssets() throws {
        let store = Self.store()
        let source = try SourceImage(data: TestImages.data(.jpeg))
        let assets = InMemoryAssetStore()
        let used = assets.put(Self.solidPNG(red: 1))
        var recipe = EditRecipe()
        recipe.layers = [Layer(name: "Pasted", content: .pixels(used))]
        let output = try ImageSaver.data(for: source, recipe: recipe, assets: assets, as: .jpeg)
        ImageDocument.updateSession(snapshot: Self.snapshot(source, recipe, assets), output: output, store: store)
        let restored = try #require(store.restore(fileData: output))
        #expect(restored.recipe == recipe)
        #expect(restored.assets == [used: try assets.data(used)])
        store.prune(now: .now.addingTimeInterval(7200))
        #expect(store.restore(fileData: output)?.assets.count == 1, "prune keeps assets a live session uses")
    }

    @Test func guidesOnlyEditsPersist() throws {
        let store = Self.store()
        let original = TestImages.data(.png)
        let source = try SourceImage(data: original)
        var recipe = EditRecipe()
        recipe.guides = [Guide(axis: .horizontal, position: 40)]
        let output = try ImageSaver.data(for: source, recipe: recipe, as: .png)
        #expect(output == original, "guides never re-encode")
        ImageDocument.updateSession(snapshot: Self.snapshot(source, recipe), output: output, store: store)
        #expect(store.restore(fileData: output)?.recipe.guides == recipe.guides)
    }

    // MARK: Privacy

    @Test func redactedSaveKeepsNoOriginalPixelsOrRecipe() throws {
        let store = Self.store()
        let original = try ImageCodec.encode(RetouchTests.noise(width: 200, height: 150), as: .png)
        let source = try SourceImage(data: original)
        var recipe = EditRecipe()
        let redact = RetouchStroke(tool: .redact, area: .rect(CGRect(x: 50, y: 40, width: 80, height: 60)))
        recipe.layers = [Layer(name: "Retouch", content: .retouch([redact]))]
        #expect(recipe.containsRedaction)

        // A session from before the redaction must go too.
        var earlier = EditRecipe()
        earlier.adjustments[.contrast] = 10
        let snapshot = Self.snapshot(source, earlier)
        let first = try ImageSaver.data(for: source, recipe: earlier, as: .png)
        ImageDocument.updateSession(snapshot: snapshot, output: first, store: store)
        #expect(store.restore(fileData: first) != nil)

        let output = try ImageSaver.data(for: source, recipe: recipe, as: .png)
        let redacted = ImageDocument.Snapshot(source: source, recipe: recipe, assets: InMemoryAssetStore(), session: snapshot.session)
        ImageDocument.updateSession(snapshot: redacted, output: output, store: store)
        #expect(store.restore(fileData: output) == nil, "no session: it would hold the original")
        #expect(store.restore(fileData: first) == nil, "the earlier session is removed")

        // Flattened: the redacted area is one flat color in the file.
        let saved = TestImages.decode(output)
        var colors = Set<[Int]>()
        for y in stride(from: 45, to: 95, by: 7) {
            for x in stride(from: 55, to: 125, by: 7) {
                let p = TestImages.pixel(saved, x: x, y: y)
                colors.insert([p.r, p.g, p.b])
            }
        }
        #expect(colors.count == 1)

        // Packages and PSDs keep only the flattened render.
        let package = try ImageDocument.package(for: redacted)
        #expect(package.recipe == EditRecipe())
        #expect(package.original != original)
        #expect(package.assets.isEmpty)
        #expect(Self.layerCount(try PSDWriter.layeredPSD(source: source, recipe: recipe, assets: InMemoryAssetStore())) == 1)
    }

    // MARK: Animation

    static func animation(_ type: UTType) throws -> Data {
        let frames = [0.0, 0.5, 1.0].map { AnimatedImage.Frame(image: Self.solid(red: $0), delay: 0.2 + $0 / 5) }
        return try AnimatedImage(frames: frames, loopCount: 0).encoded(as: type)
    }

    @Test(arguments: [UTType.gif, .png, UTType("public.heics")!])
    func editedAnimationKeepsFramesAndDelays(_ type: UTType) throws {
        let source = try SourceImage(data: Self.animation(type))
        #expect(source.frameCount == 3)
        var recipe = EditRecipe()
        recipe.adjustments[.exposure] = 30
        let saved = try ImageSaver.data(for: source, recipe: recipe, as: type)
        let back = try AnimatedImage(data: saved)
        #expect(back.frames.count == 3)
        // HEICS keeps the last frame duration as the remainder of the track, so check the first two everywhere.
        let delays = back.frames.map { ($0.delay * 100).rounded() }
        #expect(type.identifier == "public.heics" ? delays.prefix(2) == [20, 30] : delays == [20, 30, 40], "\(delays)")
        #expect(try back.frameFiles().count == 3)
        let before = TestImages.mean(try AnimatedImage(data: source.data).frames[1].image)
        #expect(TestImages.mean(back.frames[1].image).g > before.g + 5, "the edit reached every frame")
    }

    @Test func gifConvertsToAPNG() throws {
        let source = try SourceImage(data: Self.animation(.gif))
        let apng = try ImageSaver.data(for: source, recipe: EditRecipe(), as: .png)
        #expect(try AnimatedImage(data: apng).frames.count == 3)
    }

    // MARK: SVG, RAW, HDR

    @Test func svgOpensAtRequestedSize() throws {
        let svg = Data(
            #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><rect width="100" height="50" fill="red"/></svg>"#.utf8)
        let source = try SourceImage(data: svg, svgLongEdge: 400)
        #expect(source.pixelSize == CGSize(width: 400, height: 200))
        #expect(source.type == .svg)
        let p = TestImages.pixel(source.proxy, x: 10, y: 10)
        #expect(p.r > 200 && p.g < 60)
        #expect(ImageDocument.readableContentTypes.contains(.svg))
        #expect(!ImageDocument.writableContentTypes.contains(.svg))
    }

    /// A minimal LinearRaw DNG (research E4): 16-bit RGB, identity color matrix.
    static func dng(width w: Int, height h: Int, value: UInt16) -> Data {
        var tags: [(tag: UInt16, type: UInt16, count: UInt32, bytes: [UInt8])] = []
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        func short(_ t: UInt16, _ v: [UInt16]) { tags.append((t, 3, UInt32(v.count), v.flatMap { le($0) })) }
        func long(_ t: UInt16, _ v: [UInt32]) { tags.append((t, 4, UInt32(v.count), v.flatMap { le($0) })) }
        func bytes(_ t: UInt16, _ v: [UInt8]) { tags.append((t, 1, UInt32(v.count), v)) }
        func ascii(_ t: UInt16, _ s: String) { tags.append((t, 2, UInt32(s.utf8.count + 1), Array(s.utf8) + [0])) }
        func srational(_ t: UInt16, _ v: [(Int32, Int32)]) { tags.append((t, 10, UInt32(v.count), v.flatMap { le($0.0) + le($0.1) })) }
        func rational(_ t: UInt16, _ v: [(UInt32, UInt32)]) { tags.append((t, 5, UInt32(v.count), v.flatMap { le($0.0) + le($0.1) })) }
        long(254, [0])
        long(256, [UInt32(w)])
        long(257, [UInt32(h)])
        short(258, [16, 16, 16])
        short(259, [1])
        short(262, [34892])
        ascii(271, "Folio")
        ascii(272, "Test")
        long(273, [0])
        short(277, [3])
        long(278, [UInt32(h)])
        long(279, [UInt32(w * h * 6)])
        short(284, [1])
        bytes(50706, [1, 4, 0, 0])
        bytes(50707, [1, 1, 0, 0])
        ascii(50708, "Folio Test")
        srational(50721, [(10000, 10000), (0, 1), (0, 1), (0, 1), (10000, 10000), (0, 1), (0, 1), (0, 1), (10000, 10000)])
        short(50778, [21])
        rational(50728, [(1, 1), (1, 1), (1, 1)])
        tags.sort { $0.tag < $1.tag }
        let ifdSize = 2 + tags.count * 12 + 4
        var entries: [UInt8] = []
        var extra: [UInt8] = []
        var stripEntry = 0
        for t in tags {
            entries += le(t.tag) + le(t.type) + le(t.count)
            if t.tag == 273 { stripEntry = entries.count }
            if t.bytes.count <= 4 {
                entries += t.bytes + [UInt8](repeating: 0, count: 4 - t.bytes.count)
            } else {
                entries += le(UInt32(8 + ifdSize + extra.count))
                extra += t.bytes
                if extra.count % 2 == 1 { extra.append(0) }
            }
        }
        entries.replaceSubrange(stripEntry..<stripEntry + 4, with: le(UInt32(8 + ifdSize + extra.count)))
        var out = Array("II".utf8) + le(UInt16(42)) + le(UInt32(8)) + le(UInt16(tags.count)) + entries + le(UInt32(0)) + extra
        let pixel = le(value)
        for _ in 0..<(w * h * 3) { out += pixel }
        return Data(out)
    }

    @Test func linearDNGDevelops() throws {
        let source = try SourceImage(data: Self.dng(width: 160, height: 120, value: 6000))
        #expect(source.type.conforms(to: .rawImage), "\(source.type.identifier)")
        let base = try #require(try source.developed(RAWSettings(), scale: 1))
        #expect(base.extent == CGRect(x: 0, y: 0, width: 160, height: 120))
        #expect(try source.developed(RAWSettings(), scale: 0.5)?.extent.size == CGSize(width: 80, height: 60))
        var recipe = EditRecipe()
        recipe.raw = RAWSettings()
        let normal = try RenderPipeline.render(source, recipe: recipe, final: true)
        recipe.raw?.exposure = 2
        let bright = try RenderPipeline.render(source, recipe: recipe, final: true)
        #expect(TestImages.mean(bright).g > TestImages.mean(normal).g + 5)
        #expect(try SourceImage(data: TestImages.data(.png)).developed(RAWSettings(), scale: 1) == nil, "not RAW")
    }

    static func gainMapHEIC() throws -> Data {
        let sdr = CIImage(cgImage: TestImages.cgImage())
        let hdr = sdr.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1.5])
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let data = RenderPipeline.context.heifRepresentation(of: sdr, format: .RGBA8, colorSpace: space, options: [.hdrImage: hdr])
        else { throw FolioError("This Mac couldn’t write the HDR fixture.") }
        return data
    }

    @Test func gainMapSurvivesEditsUnlessToneMapped() throws {
        let source = try SourceImage(data: Self.gainMapHEIC())
        #expect(source.hasGainMap)
        var recipe = EditRecipe()
        recipe.adjustments[.contrast] = 20
        let kept = try ImageSaver.data(for: source, recipe: recipe, as: .heic)
        #expect((CIImage(data: kept, options: [.expandToHDR: true])?.contentHeadroom ?? 1) > 1)
        #expect(try SourceImage(data: kept).hasGainMap)
        recipe.hdr = .toneMapToSDR
        #expect(try !SourceImage(data: ImageSaver.data(for: source, recipe: recipe, as: .heic)).hasGainMap)
    }

    @Test func pqStaysPQUnlessToneMapped() throws {
        let image = CIImage(cgImage: TestImages.cgImage())
        let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
        let cg = try RenderPipeline.rasterize(image, extent: image.extent, format: .RGBA16, colorSpace: pq)
        let source = try SourceImage(data: ImageCodec.encode(cg, as: .tiff))
        #expect(source.usesHDRTransfer)
        var recipe = EditRecipe()
        recipe.adjustments[.saturation] = 20
        let kept = TestImages.decode(try ImageSaver.data(for: source, recipe: recipe, as: .tiff))
        #expect(kept.colorSpace.map(CGColorSpaceUsesITUR_2100TF) == true)
        #expect(kept.bitsPerComponent == 16)
        recipe.hdr = .toneMapToSDR
        let sdr = TestImages.decode(try ImageSaver.data(for: source, recipe: recipe, as: .tiff))
        #expect(sdr.colorSpace.map(CGColorSpaceUsesITUR_2100TF) == false)
    }

    // MARK: PSD

    static func unpackBits(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < data.count {
            let n = Int(Int8(bitPattern: data[i]))
            i += 1
            if n >= 0 {
                out += data[i...(i + n)]
                i += n + 1
            } else if n != -128 {
                out += repeatElement(data[i], count: 1 - n)
                i += 1
            }
        }
        return out
    }

    @Test func packBitsRoundTrips() {
        let rows: [[UInt8]] = [
            [], [7], [1, 1], [1, 2, 3], [1, 2, 2, 3, 3, 3, 4], Array(repeating: 9, count: 300), (0..<300).map { UInt8($0 % 7) },
        ]
        for row in rows { #expect(Self.unpackBits(PSDWriter.packBits(row)) == row) }
        #expect(PSDWriter.packBits(Array(repeating: 0, count: 1000)).count <= 16, "runs compress")
    }

    @Test func layeredPSDHasLayersAndComposite() throws {
        let source = try SourceImage(data: TestImages.data(.png, width: 120, height: 80))
        let assets = InMemoryAssetStore()
        let red = assets.put(Self.solidPNG(width: 30, height: 20, red: 1))
        var box = Layer(name: "Red box", content: .pixels(red))
        box.opacity = 0.5
        box.blend = .multiply
        var hidden = Layer(name: "Hidden", content: .pixels(red))
        hidden.isVisible = false
        var recipe = EditRecipe()
        recipe.layers = [box, hidden]
        let psd = try PSDWriter.layeredPSD(source: source, recipe: recipe, assets: assets)
        #expect(psd.prefix(4) == Data("8BPS".utf8))
        #expect(Self.layerCount(psd) == 3, "background + two layers")
        let text = String(decoding: psd, as: UTF8.self)
        #expect(text.contains("Red box") && text.contains("Hidden") && text.contains("mul "))
        let composite = TestImages.decode(psd)
        #expect(composite.width == 120 && composite.height == 80)
        let flat = try RenderPipeline.render(source, recipe: recipe, assets: assets, final: true)
        let (a, b) = (TestImages.pixel(composite, x: 10, y: 10), TestImages.pixel(flat, x: 10, y: 10))
        #expect(abs(a.r - b.r) <= 2 && abs(a.b - b.b) <= 2, "the composite is the flattened render")

        // An adjustment layer has no PSD equivalent, so it merges with what is below it.
        var adjust = EditRecipe()
        adjust.layers = [box, Layer(name: "Levels", content: .adjustment(AdjustmentSpec.adjustments(Adjustments())))]
        #expect(Self.layerCount(try PSDWriter.layeredPSD(source: source, recipe: adjust, assets: assets)) == 1)
    }

    // MARK: Export and batch

    @Test func exportSizeModesAndMetadata() throws {
        let source = try SourceImage(data: TestImages.data(.jpeg, width: 400, height: 300, metadata: true))
        func export(_ options: ExportOptions) throws -> Data {
            try ImageSaver.export(source, recipe: EditRecipe(), assets: InMemoryAssetStore(), options: options)
        }
        #expect(TestImages.size(of: try export(ExportOptions(format: .png))) == CGSize(width: 400, height: 300))
        #expect(TestImages.size(of: try export(ExportOptions(format: .png, size: .longEdge(200)))) == CGSize(width: 200, height: 150))
        #expect(TestImages.size(of: try export(ExportOptions(format: .png, size: .percent(25)))) == CGSize(width: 100, height: 75))
        #expect(ImageCodec.hasPersonalMetadata(try export(ExportOptions(format: .jpeg))))
        #expect(!ImageCodec.hasPersonalMetadata(try export(ExportOptions(format: .jpeg, stripMetadata: true))))
        #expect(ExportFormat.available.contains(.psd) && ExportFormat.available.contains(.png))
        #expect(try export(ExportOptions(format: .psd)).prefix(4) == Data("8BPS".utf8))
    }

    @Test func targetFileSizeLandsJustUnderBudget() throws {
        let source = try SourceImage(data: ImageCodec.encode(RetouchTests.noise(width: 600, height: 400), as: .png))
        func export(_ options: ExportOptions) throws -> Data {
            try ImageSaver.export(source, recipe: EditRecipe(), assets: InMemoryAssetStore(), options: options)
        }
        let full = try export(ExportOptions(format: .jpeg, quality: 0.9))
        let budget = full.count * 6 / 10
        let fitted = try export(ExportOptions(format: .jpeg, quality: 0.9, size: .maxBytes(budget)))
        #expect(fitted.count <= budget)
        #expect(Double(fitted.count) >= Double(budget) * 0.95, "\(fitted.count) of \(budget) bytes")
        #expect(TestImages.size(of: fitted) == CGSize(width: 600, height: 400), "quality goes first, pixels stay")

        let png = try export(ExportOptions(format: .png))
        let small = try export(ExportOptions(format: .png, size: .maxBytes(png.count / 3)))
        #expect(small.count <= png.count / 3)
        #expect(TestImages.size(of: small).width < 600, "lossless formats shrink instead")
    }

    @Test func batchPresetOnFilesOfDifferentSizes() async throws {
        let dir = try Self.folder()
        var inputs: [URL] = []
        for (index, size) in [(400, 300), (300, 500), (1200, 800)].enumerated() {
            let url = dir.appending(path: "photo\(index).jpg")
            try TestImages.data(.jpeg, width: size.0, height: size.1).write(to: url)
            inputs.append(url)
        }
        let preset = ImagePreset.builtIn[0]
        let out = try await ImageToolOps.applyPreset(
            preset, options: ExportOptions(format: .png, size: .longEdge(250)), to: inputs, keepFormat: true)
        #expect(out.map(\.lastPathComponent) == inputs.indices.map { "photo\($0) (\(preset.name)).jpeg" })
        var sizes: [CGSize] = []
        for url in out { sizes.append(TestImages.size(of: try Data(contentsOf: url))) }
        #expect(sizes == [CGSize(width: 250, height: 188), CGSize(width: 150, height: 250), CGSize(width: 250, height: 167)])
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func exportToolStripsAndResizes() async throws {
        let dir = try Self.folder()
        let input = dir.appending(path: "trip.jpg")
        try TestImages.data(.jpeg, width: 400, height: 300, metadata: true).write(to: input)
        let out = try await ImageTools.export.run([input], ["format": "png", "maxSize": "100", "metadata": "strip"])
        let data = try Data(contentsOf: out[0])
        #expect(out[0].pathExtension == "png")
        #expect(TestImages.size(of: data) == CGSize(width: 100, height: 75))
        #expect(!ImageCodec.hasPersonalMetadata(data))
        try? FileManager.default.removeItem(at: dir)
    }
}

/// Upscale replaces the document base image as one undo step.
@MainActor @Suite(.timeLimit(.minutes(1))) struct BaseReplacementTests {
    @Test func replacingTheBaseIsOneUndoStep() throws {
        let model = ImageEditorModel(document: ImageDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let original = model.document.source
        var edited = EditRecipe()
        edited.adjustments[.contrast] = 30
        undo.beginUndoGrouping()
        model.commit("Contrast") { $0 = edited }
        undo.endUndoGrouping()
        let bigger = try SourceImage(data: TestImages.data(.png, width: 800, height: 600))
        undo.beginUndoGrouping()
        model.replaceBase(bigger, recipe: EditRecipe(), actionName: "Upscale 2×")
        undo.endUndoGrouping()
        #expect(model.document.source === bigger)
        #expect(model.document.recipe == EditRecipe(), "the edits are baked into the new base")
        undo.undo()
        #expect(model.document.source === original)
        #expect(model.document.recipe == edited)
        undo.redo()
        #expect(model.document.source === bigger)
    }

    @Test func upscaledSourceKeepsTheFormat() async throws {
        let source = try SourceImage(data: TestImages.data(.png, width: 100, height: 80))
        let up = try await ImageEditorModel.upscaledSource(source: source, recipe: EditRecipe(), assets: InMemoryAssetStore(), factor: 3)
        #expect(up.pixelSize == CGSize(width: 300, height: 240))
        #expect(up.type == .png)
    }
}

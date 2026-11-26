import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FolioImage
import FolioKit

@Suite struct CodecTests {
    @Test(arguments: [UTType.png, .jpeg, .heic, .tiff, .gif, .bmp])
    func encodeDecodeRoundTrip(_ type: UTType) throws {
        let data = try ImageCodec.encode(TestImages.cgImage(), as: type)
        let source = try SourceImage(data: data)
        #expect(source.pixelSize == CGSize(width: 400, height: 300))
        #expect(source.type.conforms(to: type))
    }

    @Test func savingKeepsOrDropsMetadata() {
        let original = TestImages.properties(of: TestImages.data(metadata: true, orientation: 6))
        let kept = ImageCodec.propertiesForSaving(original, strip: false)
        #expect(kept[kCGImagePropertyGPSDictionary as String] != nil)
        #expect(kept[kCGImagePropertyOrientation as String] as? UInt32 == 1, "rendering applied the rotation")
        #expect(kept[kCGImagePropertyPixelWidth as String] == nil)
        let stripped = ImageCodec.propertiesForSaving(original, strip: true)
        #expect(stripped[kCGImagePropertyGPSDictionary as String] == nil)
        #expect(stripped[kCGImagePropertyExifDictionary as String] == nil)
        #expect(stripped[kCGImagePropertyTIFFDictionary as String] == nil)
    }

    @Test(arguments: [UTType.jpeg, .png, .heic, .tiff])
    func strippingMetadataRemovesLocation(_ type: UTType) throws {
        let data = TestImages.data(type, metadata: true)
        #expect(ImageCodec.hasPersonalMetadata(data))
        let clean = try ImageCodec.strippingMetadata(data)
        #expect(!ImageCodec.hasPersonalMetadata(clean))
        #expect(TestImages.size(of: clean) == CGSize(width: 400, height: 300))
    }
}

@Suite struct SaverTests {
    @Test func unchangedImageSavesByteForByte() throws {
        let data = TestImages.data(.jpeg, metadata: true)
        let source = try SourceImage(data: data)
        #expect(try ImageSaver.data(for: source, recipe: EditRecipe(), as: .jpeg) == data)
    }

    @Test func editedImageKeepsMetadataInItsOwnFormat() throws {
        let source = try SourceImage(data: TestImages.data(.jpeg, metadata: true, orientation: 6))
        var r = EditRecipe()
        r.adjustments[.contrast] = 20
        let saved = try ImageSaver.data(for: source, recipe: r, as: .jpeg)
        let props = TestImages.properties(of: saved)
        #expect(ImageCodec.detectedType(of: saved, hint: nil) == .jpeg)
        #expect(props[kCGImagePropertyGPSDictionary as String] != nil)
        #expect((props[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1)
        #expect(TestImages.size(of: saved) == CGSize(width: 300, height: 400), "upright pixels")
    }

    @Test func removeMetadataOnSave() throws {
        let source = try SourceImage(data: TestImages.data(.jpeg, metadata: true))
        var r = EditRecipe()
        r.stripMetadata = true
        #expect(!ImageCodec.hasPersonalMetadata(try ImageSaver.data(for: source, recipe: r, as: .jpeg)))
        r.adjustments[.exposure] = 10
        #expect(!ImageCodec.hasPersonalMetadata(try ImageSaver.data(for: source, recipe: r, as: .jpeg)))
    }

    @Test func repeatedSavesDoNotCompound() throws {
        // Every save renders from the in-memory original, so the tenth save equals the first.
        let source = try SourceImage(data: TestImages.data(.jpeg))
        var r = EditRecipe()
        r.adjustments[.saturation] = 30
        let first = try ImageSaver.data(for: source, recipe: r, as: .jpeg)
        var last = first
        for _ in 0..<5 { last = try ImageSaver.data(for: source, recipe: r, as: .jpeg) }
        #expect(first == last)
    }

    @Test func cutOutsFlattenForJPEG() throws {
        let source = try SourceImage(data: TestImages.data(.png))
        let jpeg = try RenderPipeline.render(source, recipe: EditRecipe(), final: true, flattenFor: .jpeg)
        #expect(TestImages.pixel(jpeg, x: 5, y: 5).a == 255)
    }

    @Test func blankDocumentIsWhiteCanvas() throws {
        let source = try SourceImage(data: ImageDocument.blankPNG())
        #expect(source.pixelSize == CGSize(width: 1600, height: 1000))
        let p = TestImages.pixel(source.proxy, x: 10, y: 10)
        #expect(p.r == 255 && p.g == 255 && p.b == 255)
    }

    @Test func webPIsReadableButNotWritableBySave() {
        #expect(ImageDocument.readableContentTypes.contains(.webP))
        #expect(ImageDocument.writableContentTypes.allSatisfy(ImageCodec.canWrite))
    }
}

@Suite struct SessionStoreTests {
    private func store() -> EditSessionStore {
        EditSessionStore(root: URL.temporaryDirectory.appending(path: "folio-sessions-\(UUID().uuidString)"))
    }

    @Test func restoresOriginalAndRecipeForSavedBytes() throws {
        let store = store()
        let original = TestImages.data(.jpeg)
        var r = EditRecipe()
        r.filter = .chrome
        let output = try ImageSaver.data(for: try SourceImage(data: original), recipe: r, as: .jpeg)
        let key = try store.record(output: output, original: original, originalTypeIdentifier: UTType.jpeg.identifier, recipe: r)
        let restored = try #require(store.restore(fileData: output))
        #expect(restored.original == original)
        #expect(restored.recipe == r)
        #expect(restored.key == key)
        #expect(store.restore(fileData: original) == nil, "unknown bytes open as-is")
        store.remove(key: key)
        #expect(store.restore(fileData: output) == nil)
    }

    @Test func pruneDropsOldSessionsAndOrphans() throws {
        let store = store()
        let original = TestImages.data(.png)
        let output = TestImages.data(.jpeg)
        try store.record(output: output, original: original, originalTypeIdentifier: UTType.png.identifier, recipe: EditRecipe())
        store.prune(now: .now.addingTimeInterval(40 * 24 * 3600))
        #expect(store.restore(fileData: output) == nil)
        let leftovers = try FileManager.default.contentsOfDirectory(at: store.root.appending(path: "originals"), includingPropertiesForKeys: nil)
        #expect(leftovers.isEmpty)
    }
}

@Suite struct ToolTests {
    private func folder() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "folio-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func toolIDsAreNamespaced() {
        #expect(ImageTools.all.map(\.id) == ["image.convert", "image.resize", "image.removeBackground", "image.stripMetadata"])
    }

    @Test func convertWritesNextToInput() async throws {
        let dir = try folder()
        let input = dir.appending(path: "photo.png")
        try TestImages.data(.png).write(to: input)
        let out = try await ImageTools.convert.run([input], ["format": "jpeg", "quality": "0.8"])
        #expect(out.map(\.lastPathComponent) == ["photo.jpeg"])
        #expect(ImageCodec.detectedType(of: try Data(contentsOf: out[0]), hint: nil) == .jpeg)
        #expect(try Data(contentsOf: input) == TestImages.data(.png), "inputs are never modified")
    }

    @Test func resizeCapsLongEdge() throws {
        let (data, type) = try ImageToolOps.resize(TestImages.data(.jpeg, width: 1200, height: 800), maxEdge: 600, quality: 0.8)
        #expect(type == .jpeg)
        #expect(TestImages.size(of: data) == CGSize(width: 600, height: 400))
    }

    @Test func stripMetadataTool() async throws {
        let dir = try folder()
        let input = dir.appending(path: "trip.jpg")
        try TestImages.data(.jpeg, metadata: true).write(to: input)
        let out = try await ImageTools.stripMetadata.run([input], [:])
        #expect(out[0].lastPathComponent == "trip (no metadata).jpeg")
        #expect(!ImageCodec.hasPersonalMetadata(try Data(contentsOf: out[0])))
    }

    @Test func unreadableInputHasPlainError() async throws {
        let dir = try folder()
        let input = dir.appending(path: "broken.png")
        try Data("not an image".utf8).write(to: input)
        await #expect(throws: FolioError.self) { try await ImageTools.convert.run([input], [:]) }
    }
}

@Suite struct PerformanceTests {
    /// The budget is "well under a second" to first paint; opening = reading the bytes
    /// and decoding the screen proxy. The full decode happens after paint.
    /// Set `FOLIO_PERF_IMAGE=/path/photo.jpg` to time a real photo instead of the synthetic one.
    @Test func opening24MegapixelJPEGIsFast() throws {
        let path = ProcessInfo.processInfo.environment["FOLIO_PERF_IMAGE"]
        let clock = ContinuousClock()
        var data = Data()
        let read = try clock.measure {
            data = try path.map { try Data(contentsOf: URL(fileURLWithPath: $0)) } ?? TestImages.data(.jpeg, width: 6000, height: 4000)
        }
        var source: SourceImage?
        // What `ImageDocument.init(configuration:)` does: session lookup (hash) + proxy decode.
        let open = clock.measure {
            _ = EditSessionStore.shared.restore(fileData: data)
            source = try? SourceImage(data: data)
        }
        print("read \(data.count / 1_000_000) MB in \(path == nil ? .zero : read)")
        let opened = try #require(source)
        let preview = try clock.measure { _ = try RenderPipeline.render(opened, recipe: EditRecipe(), scale: opened.proxyScale) }
        var edited = EditRecipe()
        edited.adjustments[.exposure] = 20
        edited.filter = .vivid
        let slider = try clock.measure { _ = try RenderPipeline.render(opened, recipe: edited, scale: opened.proxyScale) }
        let fullDecode = clock.measure { opened.warmUp() }
        print("24 MP JPEG: open \(open), first preview \(preview), slider frame \(slider), background full decode \(fullDecode)")
        #expect(open < .milliseconds(500))
        #expect(open + preview < .milliseconds(900))
    }
}

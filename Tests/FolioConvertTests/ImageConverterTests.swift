import AppKit  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import CoreText
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import FolioConvert

/// Fixtures made at test time: no binary files in the repo.
enum Fixtures {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "folio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A photo-like image: smooth gradients plus deterministic noise, so codecs have real work.
    static func image(width: Int = 640, height: Int = 480, alpha: Bool = false, seed: UInt32 = 1) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var state = seed
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 1_664_525 &+ 1_013_904_223
                let noise = Int(state >> 27)
                let i = (y * width + x) * 4
                let a = alpha ? UInt8(128 + (x * 127) / width) : 255
                pixels[i] = UInt8(min(255, (x * 255) / width + noise))
                pixels[i + 1] = UInt8(min(255, (y * 255) / height + noise))
                pixels[i + 2] = UInt8(min(255, ((x + y) * 128) / (width + height) + 60 + noise))
                pixels[i + 3] = a
                if alpha {  // premultiply
                    for c in 0..<3 { pixels[i + c] = UInt8(Int(pixels[i + c]) * Int(a) / 255) }
                }
            }
        }
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue)!
        return context.makeImage()!
    }

    @discardableResult
    static func write(_ image: CGImage, as format: Format, to url: URL, quality: Double? = nil, properties: [CFString: Any] = [:]) -> URL {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, format.contentType.identifier as CFString, 1, nil)!
        var options = properties
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    static var gps: [CFString: Any] {
        [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 2.2945,
                kCGImagePropertyGPSLongitudeRef: "E",
            ]
        ]
    }

    static func draw(_ text: String, size: CGFloat, at point: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    /// A text PDF: one line per page, "Page N of the Folio test".
    static func textPDF(pages: Int, at url: URL) -> URL {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil)
            draw("Page \(page) of the Folio test", size: 24, at: CGPoint(x: 72, y: 700), in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// A photo PDF: each page one embedded high-quality JPEG plus a caption.
    static func photoPDF(pages: Int, width: Int = 1600, height: Int = 1200, at url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in 1...pages {
            let jpeg = write(
                image(width: width, height: height, seed: UInt32(page)), as: .jpeg, to: folder.appending(path: "p\(page).jpg"),
                quality: 0.95)
            let image = CGImage(
                jpegDataProviderSource: CGDataProvider(url: jpeg as CFURL)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
            context.beginPDFPage(nil)
            context.draw(image, in: box)
            draw("Photo \(page)", size: 40, at: CGPoint(x: 40, y: 40), in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    static func decode(_ url: URL) -> CGImage {
        CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as? [CFString: Any] ?? [:]
    }
}

@Suite("Images")
struct ImageConverterTests {
    @Test("Targets: lossless only where it's real, AVIF only when writable")
    func targets() {
        let fromJPEG = ImageConverter.targets(from: .jpeg)
        #expect(fromJPEG.first { $0.to == .png }?.losslessAvailable == true)
        #expect(fromJPEG.first { $0.to == .tiff }?.fidelity == .lossless)
        #expect(fromJPEG.first { $0.to == .heic }?.losslessAvailable == false)
        #expect(fromJPEG.first { $0.to == .heic }?.fidelity == .lossy)
        #expect(fromJPEG.first { $0.to == .gif }?.losslessAvailable == false)
        #expect(fromJPEG.first { $0.to == .pdf }?.losslessAvailable == true)
        #expect(ImageConverter.targets(from: .heic).first { $0.to == .pdf }?.losslessAvailable == false)
        #expect(fromJPEG.contains { $0.to == .avif } == ImageConverter.writable.contains(.avif))
        #expect(!fromJPEG.contains { $0.to == .webp })
        #expect(ImageConverter.targets(from: .webp).contains { $0.to == .png })
        #expect(ImageConverter.targets(from: .pdf).isEmpty)
    }

    @Test("PNG → TIFF → PNG is verified pixel-identical")
    func losslessRoundTrip() async throws {
        let dir = try Fixtures.folder()
        let png = Fixtures.write(Fixtures.image(alpha: true), as: .png, to: dir.appending(path: "a.png"))
        let toTIFF = await Engine.run(
            ConvertRequest(inputs: [png], target: .tiff, quality: .lossless, outputDirectory: dir.appending(path: "t")))
        let tiff = try #require(toTIFF.results.first)
        #expect(tiff.status == .ok, "\(String(describing: tiff.error))")
        #expect(tiff.fidelity == .lossless)
        #expect(tiff.verification?.passed == true)
        #expect(tiff.verification?.checks.contains("pixels identical") == true)

        let back = await Engine.run(
            ConvertRequest(
                inputs: [URL(fileURLWithPath: try #require(tiff.output))], target: .png, quality: .lossless,
                outputDirectory: dir.appending(path: "p")))
        let round = try #require(back.results.first)
        #expect(round.status == .ok)
        #expect(round.verification?.passed == true)
        let roundTripped = URL(fileURLWithPath: try #require(round.output))
        let diff = try #require(PixelDiff(Fixtures.decode(png), Fixtures.decode(roundTripped), wide: false))
        #expect(diff.identical)
    }

    @Test("JPEG and PNG → PDF are embedded losslessly, and verified")
    func imageToPDF() async throws {
        let dir = try Fixtures.folder()
        let jpeg = Fixtures.write(Fixtures.image(), as: .jpeg, to: dir.appending(path: "photo.jpg"), quality: 0.9)
        let png = Fixtures.write(Fixtures.image(alpha: true), as: .png, to: dir.appending(path: "art.png"))
        let report = await Engine.run(ConvertRequest(inputs: [jpeg, png], target: .pdf, quality: .lossless))
        for result in report.results {
            #expect(result.status == .ok, "\(String(describing: result.error))")
            #expect(result.fidelity == .lossless)
            #expect(result.verification?.passed == true, "\(String(describing: result.verification))")
        }
        // The JPEG bytes went in as they were: the PDF is barely bigger than the JPEG.
        let jpegResult = report.results[0]
        #expect(Double(try #require(jpegResult.bytesOut)) < Double(jpegResult.bytesIn) * 1.1)
    }

    @Test("EXIF-rotated JPEGs go into the PDF upright, still byte for byte", arguments: [3, 6, 8])
    func rotatedJPEGToPDF(orientation: Int) async throws {
        let dir = try Fixtures.folder()
        let jpeg = Fixtures.write(
            Fixtures.image(width: 300, height: 200), as: .jpeg, to: dir.appending(path: "turned.jpg"), quality: 0.9,
            properties: [kCGImagePropertyOrientation: orientation])
        let result = try #require(await Engine.run(ConvertRequest(inputs: [jpeg], target: .pdf, quality: .lossless)).results.first)
        #expect(result.status == .ok, "\(String(describing: result.error))")
        #expect(result.verification?.passed == true, "\(String(describing: result.verification))")
        #expect(result.details["width"] == (orientation == 3 ? 300 : 200))
    }

    @Test("Lossless HEIC is refused with the lossless alternatives")
    func losslessHEICRefused() async throws {
        let dir = try Fixtures.folder()
        let jpeg = Fixtures.write(Fixtures.image(), as: .jpeg, to: dir.appending(path: "a.jpg"))
        let result = try #require(await Engine.run(ConvertRequest(inputs: [jpeg], target: .heic, quality: .lossless)).results.first)
        #expect(result.error?.code == .losslessUnavailable)
        #expect(result.error?.alternatives?.contains { $0.to == .png } == true)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "a.heic").path))
    }

    @Test("Resizing at lossless is refused")
    func losslessResizeRefused() async throws {
        let dir = try Fixtures.folder()
        let png = Fixtures.write(Fixtures.image(), as: .png, to: dir.appending(path: "a.png"))
        let result = try #require(
            await Engine.run(ConvertRequest(inputs: [png], target: .tiff, quality: .lossless, maxDimension: 100)).results.first)
        #expect(result.error?.code == .losslessUnavailable)
    }

    @Test("Compressing an already compact JPEG keeps the original")
    func neverBigger() async throws {
        let dir = try Fixtures.folder()
        let jpeg = Fixtures.write(Fixtures.image(), as: .jpeg, to: dir.appending(path: "tiny.jpg"), quality: 0.2)
        let result = try #require(await Engine.run(ConvertRequest(inputs: [jpeg], target: nil)).results.first)
        #expect(result.status == .skipped)
        #expect(result.warnings.contains { $0.contains("Already compact") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["tiny.jpg"])
    }

    @Test("Stripping metadata removes GPS, losslessly for same-format copies")
    func stripGPS() async throws {
        let dir = try Fixtures.folder()
        let jpeg = Fixtures.write(Fixtures.image(), as: .jpeg, to: dir.appending(path: "trip.jpg"), quality: 0.9, properties: Fixtures.gps)
        #expect(Fixtures.properties(jpeg)[kCGImagePropertyGPSDictionary] != nil)
        let meta = await Engine.inspect(jpeg).meta
        #expect(meta["has_gps"] == true)

        let report = await Engine.run(
            ConvertRequest(
                inputs: [jpeg], target: .jpeg, quality: .lossless, stripMetadata: true, outputDirectory: dir.appending(path: "copy")))
        let copy = try #require(report.results.first)
        #expect(copy.status == .ok, "\(String(describing: copy.error))")
        #expect(copy.method == "copy")
        #expect(copy.verification?.passed == true)
        let out = URL(fileURLWithPath: try #require(copy.output))
        #expect(Fixtures.properties(out)[kCGImagePropertyGPSDictionary] == nil)
        #expect(try #require(PixelDiff(Fixtures.decode(jpeg), Fixtures.decode(out), wide: false)).identical)

        let heic = try #require(
            await Engine.run(ConvertRequest(inputs: [jpeg], target: .png, stripMetadata: true, outputDirectory: dir.appending(path: "png")))
                .results.first)
        #expect(Fixtures.properties(URL(fileURLWithPath: try #require(heic.output)))[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test("Balanced HEIC reports quality and the hardware encoder; small caps at 2048 px")
    func presets() async throws {
        let dir = try Fixtures.folder()
        let jpeg = Fixtures.write(Fixtures.image(width: 3000, height: 2000), as: .jpeg, to: dir.appending(path: "big.jpg"), quality: 0.95)
        let balanced = try #require(await Engine.run(ConvertRequest(inputs: [jpeg], target: .heic, verify: true)).results.first)
        #expect(balanced.status == .ok, "\(String(describing: balanced.error))")
        #expect(balanced.details["quality"] == 0.8)
        #expect(balanced.details["hardware"] == true)
        #expect(balanced.fidelity == .lossy)
        #expect(balanced.verification?.passed == true)
        #expect((balanced.verification?.metrics["psnr"] ?? 0) > 30)
        #expect(ImageConverter.resource(for: job(jpeg, .heic)) == .hardwareImage)

        let small = try #require(
            await Engine.run(ConvertRequest(inputs: [jpeg], target: .jpeg, quality: .small, outputDirectory: dir.appending(path: "s")))
                .results.first)
        #expect(small.status == .ok)
        #expect(small.details["width"] == 2048)
        #expect(small.details["height"] == 1365)
    }

    @Test("max_bytes searches quality, then downscales")
    func budget() async throws {
        let dir = try Fixtures.folder()
        let png = Fixtures.write(Fixtures.image(width: 1200, height: 900), as: .png, to: dir.appending(path: "a.png"))
        let fits = try #require(await Engine.run(ConvertRequest(inputs: [png], target: .jpeg, maxBytes: 60_000)).results.first)
        #expect(fits.status == .ok, "\(String(describing: fits.error))")
        #expect(try #require(fits.bytesOut) <= 60_000)

        let shrunk = try #require(
            await Engine.run(ConvertRequest(inputs: [png], target: .png, maxBytes: 40_000, outputDirectory: dir.appending(path: "p")))
                .results.first)
        #expect(shrunk.status == .ok, "\(String(describing: shrunk.error))")
        #expect(try #require(shrunk.bytesOut) <= 40_000)
        #expect(shrunk.fidelity == .lossy)
    }

    @Test("max_dimension downscales and verification compares against the resized source")
    func maxDimension() async throws {
        let dir = try Fixtures.folder()
        let png = Fixtures.write(Fixtures.image(width: 800, height: 400), as: .png, to: dir.appending(path: "a.png"))
        let result = try #require(
            await Engine.run(ConvertRequest(inputs: [png], target: .png, maxDimension: 200, verify: true)).results.first)
        #expect(result.status == .ok, "\(String(describing: result.error))")
        #expect(result.details["width"] == 200)
        #expect(result.details["height"] == 100)
        #expect(result.verification?.passed == true)
    }

    @Test("Inspect reports size, alpha, depth and frames")
    func inspect() async throws {
        let dir = try Fixtures.folder()
        let png = Fixtures.write(Fixtures.image(width: 64, height: 32, alpha: true), as: .png, to: dir.appending(path: "a.png"))
        let info = await Engine.inspect(png)
        #expect(info.meta["width"] == 64)
        #expect(info.meta["height"] == 32)
        #expect(info.meta["has_alpha"] == true)
        #expect(info.meta["has_gps"] == false)
        let gif = Fixtures.write(Fixtures.image(width: 32, height: 32), as: .gif, to: dir.appending(path: "a.gif"))
        #expect(await Engine.inspect(gif).meta["frames"] == 1)
    }

    @Test("Extract reads text out of an image with OCR")
    func ocr() async throws {
        let dir = try Fixtures.folder()
        let context = CGContext(
            data: nil, width: 1200, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 300))
        Fixtures.draw("Folio reads this", size: 96, at: CGPoint(x: 40, y: 100), in: context)
        let png = Fixtures.write(context.makeImage()!, as: .png, to: dir.appending(path: "words.png"))
        let text = try await Engine.extract(png)
        #expect(text.lowercased().contains("folio"))
    }

    func job(_ input: URL, _ target: Format) -> Job {
        Job(
            input: input, source: Format.detect(input)!, target: target, quality: .balanced, maxBytes: nil, maxDimension: nil,
            stripMetadata: false,
            verify: false, output: input, progress: { _ in })
    }
}

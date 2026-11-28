import AppKit  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import FolioConvert

/// The 0.3 image formats: icons, PSD, EXR, TGA, PBM, animations, SVG, EPS previews, Illustrator and RAW routing.
@Suite("Image formats", .timeLimit(.minutes(2)))
struct ImageFormatTests {
    /// Converts one file and returns its result, failing the test on anything but `ok`.
    func convert(
        _ input: URL, to target: Format, quality: Quality = .balanced, maxDimension: Int? = nil, verify: Bool? = nil
    ) async throws -> ConvertResult {
        let request = ConvertRequest(
            inputs: [input], target: target, quality: quality, maxDimension: maxDimension,
            outputDirectory: input.deletingLastPathComponent().appending(path: target.rawValue),
            verify: verify)
        let result = try #require(await Engine.run(request).results.first)
        #expect(result.status == .ok, "\(input.lastPathComponent) → \(target): \(String(describing: result.error))")
        return result
    }

    func frames(_ path: String?) -> Int {
        path.flatMap { CGImageSourceCreateWithURL(URL(fileURLWithPath: $0) as CFURL, nil) }.map(CGImageSourceGetCount) ?? 0
    }

    @Test("Targets: RAW, HDR, DDS, SVG and EPS are read-only; the new writers are offered")
    func targets() {
        let fromPNG = ImageConverter.targets(from: .png).map(\.to)
        for format in [Format.psd, .ico, .icns, .exr, .tga, .pbm, .apng] { #expect(fromPNG.contains(format), "\(format)") }
        for format in [Format.raw, .hdr, .dds, .svg, .eps, .webp, .jxl] { #expect(!fromPNG.contains(format), "\(format)") }
        #expect(fromPNG.contains(.heics) == ImageConverter.writable.contains(.heics))
        #expect(Format.detect(URL(fileURLWithPath: "/tmp/a.CR3")) == .raw)
        #expect(Format.detect(URL(fileURLWithPath: "/tmp/a.ppm")) == .pbm)
        #expect(ImageConverter.targets(from: .raw).contains { $0.to == .jpeg })
        #expect(ImageConverter.targets(from: .dds).contains { $0.to == .png })
        let svgPDF = ImageConverter.targets(from: .svg).first { $0.to == .pdf }
        #expect(svgPDF?.fidelity == .lossless)
        #expect(ImageConverter.targets(from: .svg).first { $0.to == .png }?.losslessAvailable == false)
        #expect(ImageConverter.targets(from: .gif).first { $0.to == .apng }?.drops.contains("animation") == false)
        #expect(ImageConverter.targets(from: .gif).first { $0.to == .jpeg }?.drops.contains("animation") == true)
        #expect(ImageConverter.targets(from: .exr).first { $0.to == .png }?.fidelity == .lossy)
        #expect(PDFConverter.targets(from: .ai).first { $0.to == .pdf }?.fidelity == .lossless)
        let listed = Set(Engine.formats().map(\.from))
        for format in [Format.raw, .psd, .ico, .icns, .exr, .hdr, .tga, .pbm, .apng, .heics, .svg, .eps, .dds, .ai] {
            #expect(listed.contains(format), "folio formats lists \(format)")
        }
    }

    @Test("Lossless into PSD, EXR, TGA, PBM, APNG, ICO and ICNS is verified pixel-identical, and each reads back")
    func losslessWriters() async throws {
        let dir = try Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = Fixtures.write(Fixtures.image(width: 64, height: 48), as: .png, to: dir.appending(path: "photo.png"))
        let square = Fixtures.write(Fixtures.image(width: 128, height: 128, alpha: true), as: .png, to: dir.appending(path: "icon.png"))
        for (input, target) in [
            (photo, Format.psd), (photo, .exr), (photo, .tga), (photo, .pbm), (photo, .apng), (square, .ico), (square, .icns),
        ] {
            let result = try await convert(input, to: target, quality: .lossless)
            #expect(result.fidelity == .lossless, "\(target)")
            #expect(result.verification?.passed == true, "\(target): \(String(describing: result.verification))")
            let written = try output(result)
            let back = try await convert(written, to: .png)
            #expect(Fixtures.decode(try output(back)).width == (input == photo ? 64 : 128), "\(target)")
        }
    }

    @Test("A favicon holds 256, 48, 32 and 16 px; an icns from 1024 px holds every size up to 1024")
    func iconSets() async throws {
        let dir = try Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = Fixtures.write(Fixtures.image(width: 1024, height: 1024), as: .png, to: dir.appending(path: "big.png"))
        let ico = try await convert(big, to: .ico)
        #expect(ico.fidelity == .lossy)
        let icoSource = try #require(CGImageSourceCreateWithURL(try output(ico) as CFURL, nil))
        let icoWidths = (0..<CGImageSourceGetCount(icoSource)).map { Fixtures.decodeWidth(icoSource, $0) }
        #expect(icoWidths.sorted() == [16, 32, 48, 256])
        let icns = try await convert(big, to: .icns)
        let icnsSource = try #require(CGImageSourceCreateWithURL(try output(icns) as CFURL, nil))
        let icnsWidths = Set((0..<CGImageSourceGetCount(icnsSource)).map { Fixtures.decodeWidth(icnsSource, $0) })
        #expect(icnsWidths.isSuperset(of: [16, 32, 64, 128, 256, 512, 1024]), "\(icnsWidths)")
        let odd = Fixtures.write(Fixtures.image(width: 100, height: 60), as: .png, to: dir.appending(path: "odd.png"))
        let refused = try #require(await Engine.run(ConvertRequest(inputs: [odd], target: .ico, quality: .lossless)).results.first)
        #expect(refused.error?.code == .losslessUnavailable)
    }

    @Test("GIF ↔ APNG ↔ HEICS keep every frame and its delay; a still target keeps the first with a warning")
    func animations() async throws {
        let dir = try Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gif = dir.appending(path: "spin.gif")
        let destination = try #require(CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 3, nil))
        CGImageDestinationSetProperties(
            destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for seed in 1...3 {
            CGImageDestinationAddImage(
                destination, Fixtures.image(width: 40, height: 30, seed: UInt32(seed)),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))

        let apng = try await convert(gif, to: .apng, verify: true)
        #expect(apng.details["frames"] == 3)
        #expect(apng.verification?.passed == true)
        let apngURL = try output(apng)
        #expect(apngURL.pathExtension == "apng")
        #expect(frames(apng.output) == 3)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(apngURL as CFURL, nil)!, 1, nil) as? [CFString: Any]
        let delay = (props?[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyAPNGDelayTime] as? Double
        #expect(abs((delay ?? 0) - 0.2) < 0.01)

        let back = try await convert(apngURL, to: .gif, maxDimension: 20)
        #expect(frames(back.output) == 3)
        #expect(Fixtures.decode(try output(back)).width == 20)
        if ImageConverter.writable.contains(.heics) {
            let heics = try await convert(gif, to: .heics)
            #expect(frames(heics.output) == 3)
            #expect(frames(try await convert(try output(heics), to: .gif).output) == 3)
        }
        let still = try await convert(gif, to: .png)
        #expect(frames(still.output) == 1)
        #expect(still.warnings.contains("Only the first frame was kept."))
    }

    static let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 200 100">
          <rect x="10" y="10" width="180" height="80" rx="12" fill="#2a7"/>
          <circle cx="100" cy="50" r="30" fill="#fc3"/>
        </svg>
        """

    @Test("SVG → PDF stays vector (no image XObject); SVG → PNG and JPEG render at max_dimension")
    func svg() async throws {
        let dir = try Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "badge.svg")
        try Data(Self.svg.utf8).write(to: url)
        let pdf = try await convert(url, to: .pdf, quality: .lossless)
        #expect(pdf.fidelity == .lossless)
        #expect(pdf.verification?.passed == true)
        let page = try #require(CGPDFDocument(try output(pdf) as CFURL)?.page(at: 1))
        #expect(page.getBoxRect(.mediaBox).size == CGSize(width: 200, height: 100))
        #expect(ImageConverter.isVector(page))

        let png = try await convert(url, to: .png, maxDimension: 300)
        #expect(png.method == "render")
        let image = Fixtures.decode(try output(png))
        #expect((image.width, image.height) == (300, 150))
        let jpeg = try await convert(url, to: .jpeg)
        #expect(Fixtures.decode(try output(jpeg)).width == ImageConverter.svgDefaultEdge)
        #expect(await Engine.inspect(url).meta["width"] == .double(200))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "png").path)
        #expect(leftovers == ["badge.png"])
    }

    /// A DOS EPS: the 30-byte binary header, a PostScript section, then a TIFF preview.
    static func eps(preview: Data?) -> Data {
        let postScript = Data("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 40 30\nshowpage\n".utf8)
        func le(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        let tiffStart = preview == nil ? 0 : 30 + postScript.count
        var header: [UInt8] = [0xC5, 0xD0, 0xD3, 0xC6] + le(30) + le(postScript.count) + le(0) + le(0)
        header += le(tiffStart) + le(preview?.count ?? 0) + [0xFF, 0xFF]
        return Data(header) + postScript + (preview ?? Data())
    }

    @Test("EPS converts from its TIFF preview; without one it fails with UNSUPPORTED_INPUT")
    func eps() async throws {
        let dir = try Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tiff = Fixtures.write(Fixtures.image(width: 40, height: 30), as: .tiff, to: dir.appending(path: "p.tiff"))
        let url = dir.appending(path: "art.eps")
        try Self.eps(preview: try Data(contentsOf: tiff)).write(to: url)
        let png = try await convert(url, to: .png)
        #expect(png.fidelity == .lossy)
        #expect(png.dropped.contains { $0.hasPrefix("vector artwork") })
        #expect(Fixtures.decode(try output(png)).width == 40)
        #expect(await Engine.inspect(url).meta["preview_width"] == 40)

        let bare = dir.appending(path: "bare.eps")
        try Self.eps(preview: nil).write(to: bare)
        let failed = try #require(await Engine.run(ConvertRequest(inputs: [bare], target: .png)).results.first)
        #expect(failed.error?.code == .unsupportedInput)
        #expect(failed.error?.message.contains("PostScript") == true)
    }

    @Test("A PDF-compatible .ai becomes a PDF (pages copied) or a PNG")
    func illustrator() async throws {
        let dir = try Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ai = Fixtures.textPDF(pages: 2, at: dir.appending(path: "logo.ai"))
        let pdf = try await convert(ai, to: .pdf)
        #expect(pdf.fidelity == .lossless)
        #expect(CGPDFDocument(try output(pdf) as CFURL)?.numberOfPages == 2)
        let png = try await convert(ai, to: .png)
        #expect(png.output != nil)
    }
}

extension Fixtures {
    static func decodeWidth(_ source: CGImageSource, _ index: Int) -> Int {
        (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int ?? 0
    }
}

/// The written file of a finished conversion.
func output(_ result: ConvertResult) throws -> URL {
    URL(fileURLWithPath: try #require(result.output))
}

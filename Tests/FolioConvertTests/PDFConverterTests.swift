import AppKit  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import PDFKit
import Testing

@testable import FolioConvert

@Suite("PDF")
struct PDFConverterTests {
    @Test("A multi-page PDF becomes a folder of page-001.png…")
    func pagesToFolder() async throws {
        let dir = try Fixtures.folder()
        let pdf = Fixtures.textPDF(pages: 3, at: dir.appending(path: "doc.pdf"))
        let result = try #require(await Engine.run(ConvertRequest(inputs: [pdf], target: .png, verify: true)).results.first)
        #expect(result.status == .ok, "\(String(describing: result.error))")
        let folder = try #require(result.output)
        #expect(folder.hasSuffix("/doc"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).sorted() == ["page-001.png", "page-002.png", "page-003.png"])
        #expect(result.details["dpi"] == 150)
        #expect(result.details["width"] == 1275)  // 8.5 in × 150 dpi
        #expect(result.verification?.passed == true)
    }

    @Test("A one-page PDF becomes one file, honouring max_dimension")
    func onePage() async throws {
        let dir = try Fixtures.folder()
        let pdf = Fixtures.textPDF(pages: 1, at: dir.appending(path: "one.pdf"))
        let result = try #require(await Engine.run(ConvertRequest(inputs: [pdf], target: .jpeg, maxDimension: 400)).results.first)
        #expect(result.status == .ok, "\(String(describing: result.error))")
        let image = Fixtures.decode(URL(fileURLWithPath: try #require(result.output)))
        #expect(image.height == 400)
        #expect(result.fidelity == .lossy)
    }

    @Test("Rotated pages render as the reader sees them")
    func rotatedPage() async throws {
        let dir = try Fixtures.folder()
        let document = try #require(PDFDocument(url: Fixtures.textPDF(pages: 1, at: dir.appending(path: "plain.pdf"))))
        document.page(at: 0)?.rotation = 90
        let url = dir.appending(path: "turned.pdf")
        document.write(to: url)
        let result = try #require(await Engine.run(ConvertRequest(inputs: [url], target: .png)).results.first)
        let image = Fixtures.decode(URL(fileURLWithPath: try #require(result.output)))
        #expect(image.width == 1650 && image.height == 1275)
        // The text line sat at the top of the page; turned clockwise it lands on the right.
        let pixels = PixelDiff.render(UInt8.self, image.width, image.height, false) {
            $0.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var ink = (left: 0, right: 0)
        for y in 0..<image.height {
            for x in 0..<image.width where pixels[(y * image.width + x) * 4] < 128 {
                if x < image.width / 2 { ink.left += 1 } else { ink.right += 1 }
            }
        }
        #expect(ink.right > 100)
        #expect(ink.left == 0)
    }

    @Test("Compressing a photo PDF makes it much smaller and keeps text and pages")
    func compressPhotos() async throws {
        let dir = try Fixtures.folder()
        let pdf = Fixtures.photoPDF(pages: 3, width: 3000, height: 2000, at: dir.appending(path: "photos.pdf"))
        let result = try #require(await Engine.run(ConvertRequest(inputs: [pdf], target: nil, verify: true)).results.first)
        #expect(result.status == .ok, "\(String(describing: result.error))")
        #expect(try #require(result.ratio) < 0.5, "ratio \(String(describing: result.ratio))")
        #expect(result.fidelity == .lossy)
        #expect(result.verification?.passed == true, "\(String(describing: result.verification))")
        let path = try #require(result.output)
        let out = try #require(PDFDocument(url: URL(fileURLWithPath: path)))
        #expect(out.pageCount == 3)
        #expect(out.page(at: 1)?.string?.contains("Photo 2") == true)
    }

    @Test("Compressing a text-only PDF keeps the original")
    func compressText() async throws {
        let dir = try Fixtures.folder()
        let pdf = Fixtures.textPDF(pages: 2, at: dir.appending(path: "text.pdf"))
        let result = try #require(await Engine.run(ConvertRequest(inputs: [pdf], target: .pdf)).results.first)
        #expect(result.status == .skipped)
    }

    @Test("Lossless rewrite is verified: pages, text and page-1 pixels")
    func losslessRewrite() async throws {
        let dir = try Fixtures.folder()
        let pdf = Fixtures.textPDF(pages: 2, at: dir.appending(path: "text.pdf"))
        let result = try #require(
            await Engine.run(ConvertRequest(inputs: [pdf], target: .pdf, quality: .lossless, outputDirectory: dir.appending(path: "out")))
                .results.first)
        #expect(result.status == .ok, "\(String(describing: result.error))")
        #expect(result.fidelity == .lossless)
        #expect(result.verification?.passed == true)
        #expect(result.verification?.checks.contains("page 1 pixels identical") == true)
    }

    @Test("Extract reads the text layer with page breaks and ranges")
    func extract() async throws {
        let dir = try Fixtures.folder()
        let pdf = Fixtures.textPDF(pages: 3, at: dir.appending(path: "doc.pdf"))
        let markdown = try await Engine.extract(pdf)
        #expect(markdown.contains("Page 1 of the Folio test"))
        #expect(markdown.components(separatedBy: "\n\n---\n\n").count == 3)
        let second = try await Engine.extract(pdf, as: .text, options: ExtractOptions(pages: 2...2))
        #expect(second.contains("Page 2"))
        #expect(!second.contains("Page 1"))
    }

    @Test("A scanned PDF (no text layer) is read with OCR")
    func extractScanned() async throws {
        let dir = try Fixtures.folder()
        let context = CGContext(
            data: nil, width: 1200, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 300))
        Fixtures.draw("Scanned words", size: 96, at: CGPoint(x: 40, y: 100), in: context)
        let png = Fixtures.write(context.makeImage()!, as: .png, to: dir.appending(path: "scan.png"))
        let made = try #require(await Engine.run(ConvertRequest(inputs: [png], target: .pdf)).results.first?.output)
        let text = try await Engine.extract(URL(fileURLWithPath: made))
        #expect(text.lowercased().contains("scanned"))
    }

    @Test("Text targets: txt, md, docx and rtf are content only")
    func textTargets() async throws {
        let dir = try Fixtures.folder()
        let pdf = Fixtures.textPDF(pages: 2, at: dir.appending(path: "doc.pdf"))
        for target in [Format.txt, .md, .docx, .rtf] {
            let result = try #require(await Engine.run(ConvertRequest(inputs: [pdf], target: target)).results.first)
            #expect(result.status == .ok, "\(target): \(String(describing: result.error))")
            #expect(result.fidelity == .contentOnly)
            let out = URL(fileURLWithPath: try #require(result.output))
            let text =
                target == .docx || target == .rtf
                ? try NSAttributedString(url: out, options: [:], documentAttributes: nil).string
                : try String(contentsOf: out, encoding: .utf8)
            #expect(text.contains("Page 2 of the Folio test"), "\(target)")
        }
    }

    @Test("Inspect reports pages, text layer, size and title")
    func inspect() async throws {
        let dir = try Fixtures.folder()
        let url = dir.appending(path: "titled.pdf")
        let document = try #require(PDFDocument(url: Fixtures.textPDF(pages: 2, at: dir.appending(path: "plain.pdf"))))
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Annual report"]
        document.write(to: url)
        let meta = await Engine.inspect(url).meta
        #expect(meta["pages"] == 2)
        #expect(meta["has_text_layer"] == true)
        #expect(meta["encrypted"] == false)
        #expect(meta["page_size"] == .array([.double(612), .double(792)]))
        #expect(meta["title"] == "Annual report")
    }

    @Test("Locked PDFs fail with ENCRYPTED")
    func locked() async throws {
        let dir = try Fixtures.folder()
        let url = dir.appending(path: "locked.pdf")
        let document = try #require(PDFDocument(url: Fixtures.textPDF(pages: 1, at: dir.appending(path: "plain.pdf"))))
        document.write(to: url, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"])
        let result = try #require(await Engine.run(ConvertRequest(inputs: [url], target: .png)).results.first)
        #expect(result.error?.code == .encrypted)
        await #expect(throws: ConvertError.self) { try await Engine.extract(url) }
    }

    @Test("Lossless is refused for JPEG pages and offered for PNG")
    func targets() {
        let targets = PDFConverter.targets(from: .pdf)
        #expect(targets.first { $0.to == .jpeg }?.losslessAvailable == false)
        #expect(targets.first { $0.to == .png }?.losslessAvailable == true)
        #expect(targets.first { $0.to == .md }?.fidelity == .contentOnly)
        #expect(targets.first { $0.to == .docx }?.drops.contains("page layout") == true)
    }
}

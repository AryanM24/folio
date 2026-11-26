import FolioKit
import PDFKit
import Testing
import UniformTypeIdentifiers

@testable import FolioPDF

/// Each tool writes new files next to its first input and never touches the inputs.
@Suite struct ToolTests {
    @Test func toolIDsAreNamespacedAndUnique() {
        let ids = PDFTools.all.map(\.id)
        #expect(ids.allSatisfy { $0.hasPrefix("pdf.") })
        #expect(Set(ids).count == ids.count)
        #expect(ids.count == 9)
    }

    @Test func combineKeepsOrder() throws {
        let folder = try Fixtures.temporaryFolder()
        let a = try Fixtures.write(Fixtures.document(pages: 2), to: folder, name: "a")
        let b = try Fixtures.write(Fixtures.document(pages: 1, extra: [0: "from b"]), to: folder, name: "b")
        let output = try PDFToolJobs.combine([a, b])
        #expect(output.lastPathComponent == "Combined.pdf")
        let combined = try PDFOperations.load(output)
        #expect(combined.pageCount == 3)
        #expect(combined.page(at: 2)?.string?.contains("from b") == true)
        // Running again never overwrites.
        #expect(try PDFToolJobs.combine([a, b]).lastPathComponent == "Combined 2.pdf")
    }

    @Test func splitMakesOneFilePerPage() throws {
        let folder = try Fixtures.temporaryFolder()
        let input = try Fixtures.write(Fixtures.document(pages: 3), to: folder, name: "report")
        let outputs = try PDFToolJobs.split(input)
        #expect(outputs.map(\.lastPathComponent) == ["report page 1.pdf", "report page 2.pdf", "report page 3.pdf"])
        #expect(try PDFOperations.load(outputs[1]).page(at: 0)?.string?.contains("Page 2") == true)
    }

    @Test func rotateWritesACopy() throws {
        let folder = try Fixtures.temporaryFolder()
        let input = try Fixtures.write(Fixtures.document(pages: 2), to: folder, name: "scan")
        let output = try PDFToolJobs.transform(input, suffix: "rotated") { PDFOperations.rotateAll($0, by: -90) }
        #expect(try PDFOperations.load(output).page(at: 1)?.rotation == 270)
        #expect(try PDFOperations.load(input).page(at: 1)?.rotation == 0)
    }

    @Test func toImagesRendersEveryPage() throws {
        let folder = try Fixtures.temporaryFolder()
        let input = try Fixtures.write(Fixtures.document(pages: 2), to: folder, name: "doc")
        let outputs = try PDFToolJobs.toImages(input, format: "png", dpi: 144)
        #expect(outputs.count == 2)
        let image = try #require(PageFactory.image(at: outputs[0]))
        #expect(image.width == 1224 && image.height == 1584)
    }

    @Test func imagesToPDFFitsPaper() throws {
        let folder = try Fixtures.temporaryFolder()
        let wide = try #require(Fixtures.image(width: 4000, height: 2000, color: CGColor(gray: 0.5, alpha: 1)))
        let url = folder.appending(path: "photo.png")
        try #require(Rasterizer.encode(wide, as: .png)).write(to: url)
        let output = try PDFToolJobs.imagesToPDF([url])
        let page = try #require(try PDFOperations.load(output).page(at: 0))
        let box = page.bounds(for: .mediaBox)
        #expect(box.width > box.height)  // landscape paper for a wide photo
        #expect(box.width < 900)
    }

    @Test func extractTextWritesPlainText() throws {
        let folder = try Fixtures.temporaryFolder()
        let input = try Fixtures.write(Fixtures.document(pages: 2, extra: [1: "needle"]), to: folder, name: "notes")
        let output = try PDFToolJobs.extractText(input)
        #expect(output.pathExtension == "txt")
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.contains("needle") && text.contains("Page 1"))
    }

    @Test func extractTextExplainsScans() throws {
        let folder = try Fixtures.temporaryFolder()
        let scan = PDFDocument()
        scan.insert(try #require(Fixtures.scannedPage(text: "pixels only")), at: 0)
        let input = try Fixtures.write(scan, to: folder, name: "scan")
        #expect(throws: FolioError.self) { try PDFToolJobs.extractText(input) }
    }

    @Test func compressProducesAValidPDF() throws {
        let folder = try Fixtures.temporaryFolder()
        let document = PDFDocument()
        let photo = try #require(Fixtures.noise(width: 1600, height: 1200))
        // 1600 px in a 3-inch box is ~530 dpi: well above screen resolution.
        document.insert(try #require(PageFactory.page(for: photo, fitting: CGRect(x: 0, y: 0, width: 288, height: 216))), at: 0)
        let input = try Fixtures.write(document, to: folder, name: "big")
        let output = try PDFToolJobs.compress(input)
        #expect(try PDFOperations.load(output).pageCount == 1)
        let size = { (url: URL) in try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        #expect(try size(output) < size(input))
    }

    @Test func compressedCopyKeepsAnnotationsAndOutline() throws {
        let document = try #require(Fixtures.outlined(["First": 0, "Second": 1]))
        document.page(at: 1)?.addAnnotation(AnnotationFactory.note(at: CGPoint(x: 50, y: 50), style: .defaults(for: .note)))
        let smaller = try #require(PDFDocument(data: try PDFOperations.compressedData(document)))
        #expect(smaller.outlineRoot?.child(at: 1)?.label == "Second")
        let target = try #require(smaller.outlineRoot?.child(at: 1)?.destination?.page)
        #expect(smaller.index(for: target) == 1)
        #expect(smaller.page(at: 1)?.annotations.contains { $0.type == "Text" } == true)
        #expect(smaller.page(at: 1)?.string?.contains("Page 2") == true)
    }

    @Test func unreadableInputGivesAPlainLanguageError() throws {
        let folder = try Fixtures.temporaryFolder()
        let bogus = folder.appending(path: "not.pdf")
        try Data("hello".utf8).write(to: bogus)
        #expect(throws: FolioError.self) { try PDFOperations.load(bogus) }
    }
}

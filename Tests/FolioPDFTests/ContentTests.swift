import PDFKit
import Testing

@testable import FolioPDF

/// Operations that rewrite page content: redaction, OCR, flattening, stamping.
@Suite struct ContentTests {
    @Test func redactionRemovesTextFromTheFile() throws {
        let secret = "Account 4242-SECRET"
        let document = Fixtures.document(pages: 2, extra: [0: secret])
        let model = PDFEditorModel(document: PDFFileDocument(pdf: document))
        let page = try #require(document.page(at: 0))
        let match = try #require(document.findString("4242-SECRET", withOptions: []).first)
        model.redact(match.bounds(for: page).insetBy(dx: -4, dy: -4), on: page)

        let redacted = try #require(document.page(at: 0))
        #expect(redacted !== page)
        #expect(redacted.string?.contains("SECRET") != true)
        // The saved file, not just the in-memory page, must be clean.
        let data = try PDFOperations.data(document)
        let reopened = try #require(PDFDocument(data: data))
        #expect(reopened.page(at: 0)?.string?.contains("SECRET") != true)
        #expect(PDFOperations.text(of: reopened).contains("Page 2"))
        // And the box is really painted black.
        let center = match.bounds(for: page)
        let pixel = try #require(Fixtures.color(of: redacted, at: CGPoint(x: center.midX, y: center.midY)))
        #expect(pixel.red < 0.1 && pixel.green < 0.1 && pixel.blue < 0.1)
    }

    @Test func redactionIsUndoable() throws {
        let document = Fixtures.document(pages: 1, extra: [0: "classified"])
        let model = PDFEditorModel(document: PDFFileDocument(pdf: document))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let page = try #require(document.page(at: 0))
        undo.beginUndoGrouping()
        model.redact(CGRect(x: 60, y: 380, width: 300, height: 40), on: page)
        undo.endUndoGrouping()
        #expect(document.page(at: 0)?.string?.contains("classified") != true)
        undo.undo()
        #expect(document.page(at: 0) === page)
    }

    @Test func recognizedTextBecomesSelectable() async throws {
        let scan = try #require(Fixtures.scannedPage(text: "FOLIO READS SCANS"))
        #expect((scan.string ?? "").isEmpty)
        let image = try #require(Rasterizer.raster(scan, scale: TextRecognizer.scale, annotations: false))
        let lines = try await TextRecognizer.recognize(image)
        #expect(lines.contains { $0.text.uppercased().contains("SCANS") })
        let layered = try #require(TextRecognizer.addingTextLayer(to: scan, lines: lines))
        let single = PDFDocument()
        single.insert(layered, at: 0)
        let reopened = try #require(Fixtures.reloaded(single))
        #expect(reopened.page(at: 0)?.string?.uppercased().contains("READS") == true)
    }

    @Test func flattenFormBurnsValuesIn() throws {
        let document = Fixtures.form(value: "Ada Lovelace")
        let model = PDFEditorModel(document: PDFFileDocument(pdf: document))
        model.flattenForm()
        let page = try #require(document.page(at: 0))
        #expect(!page.annotations.contains { $0.type == PDFAnnotationSubtype.widget.name })
        #expect(page.string?.contains("Ada Lovelace") == true)
    }

    @Test func formEditsAreUndoable() throws {
        let document = Fixtures.form(value: "")
        let model = PDFEditorModel(document: PDFFileDocument(pdf: document))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let field = try #require(document.page(at: 0)?.annotations.first)
        undo.beginUndoGrouping()
        model.beginFormEdit(field)
        field.widgetStringValue = "Grace"
        model.commitFormEdit()
        undo.endUndoGrouping()
        #expect(undo.canUndo)
        undo.undo()
        #expect(field.widgetStringValue == "")
    }

    @Test func flattenedExportHasNoAnnotations() throws {
        let document = Fixtures.document(pages: 1)
        let page = try #require(document.page(at: 0))
        page.addAnnotation(
            AnnotationFactory.shape(
                .rectangle, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200), style: .defaults(for: .rectangle)))
        let flat = try #require(PDFDocument(data: try PDFOperations.flattenedData(document)))
        #expect(flat.page(at: 0)?.annotations.isEmpty == true)
        let flatPage = try #require(flat.page(at: 0))
        let edge = try #require(Fixtures.color(of: flatPage, at: CGPoint(x: 100, y: 150)))
        #expect(Fixtures.isRed(edge))
    }

    @Test func pageNumbersAreRealText() throws {
        let document = Fixtures.document(pages: 3)
        PDFOperations.addPageNumbers(document)
        let reopened = try #require(Fixtures.reloaded(document))
        #expect(reopened.page(at: 1)?.string?.contains("2 of 3") == true)
        #expect(reopened.page(at: 1)?.string?.contains("Page 2") == true)
    }

    @Test func pageNumbersSitAtTheVisualBottomOfRotatedPages() throws {
        let document = Fixtures.document(pages: 1)
        document.page(at: 0)?.rotation = 90
        PDFOperations.addPageNumbers(document)
        let page = try #require(document.page(at: 0))
        let label = try #require(document.findString("1 of 1", withOptions: []).first)
        // Rotated 90° clockwise, the visual bottom is the page's right edge.
        #expect(label.bounds(for: page).minX > page.bounds(for: .mediaBox).width - 60)
    }

    @Test func rebuiltPagesKeepTheirAnnotationsAfterSaving() throws {
        let document = Fixtures.document(pages: 1)
        let page = try #require(document.page(at: 0))
        page.addAnnotation(AnnotationFactory.note(at: CGPoint(x: 50, y: 50), style: .defaults(for: .note)))
        let stamp = try #require(Stamp.approved.render())
        page.addAnnotation(
            ImageAnnotation(image: stamp.image, bounds: CGRect(origin: CGPoint(x: 200, y: 200), size: stamp.size), name: "Approved"))
        PDFOperations.addWatermark(document, text: "COPY")
        let reopened = try #require(Fixtures.reloaded(document))
        let types = reopened.page(at: 0)?.annotations.compactMap(\.type) ?? []
        #expect(types.contains("Text") && types.contains("Stamp"))
    }

    @Test func watermarkIsAddedToEveryPage() throws {
        let document = Fixtures.document(pages: 2)
        PDFOperations.addWatermark(document, text: "DRAFT")
        for index in 0..<2 {
            #expect(document.page(at: index)?.string?.contains("DRAFT") == true)
        }
    }

    @Test func imageAnnotationIsStoredInTheFile() throws {
        let document = Fixtures.document(pages: 1)
        let red = try #require(Fixtures.image(width: 20, height: 20, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)))
        document.page(at: 0)?.addAnnotation(
            ImageAnnotation(image: red, bounds: CGRect(x: 300, y: 100, width: 80, height: 60), name: "Image"))
        let reopened = try #require(Fixtures.reloaded(document))
        let page = try #require(reopened.page(at: 0))
        #expect(page.annotations.contains { $0.type == PDFAnnotationSubtype.stamp.name })
        let pixel = try #require(Fixtures.color(of: page, at: CGPoint(x: 340, y: 130)))
        #expect(Fixtures.isRed(pixel))
    }
}

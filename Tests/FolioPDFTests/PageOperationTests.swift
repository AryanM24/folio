import PDFKit
import Testing

@testable import FolioPDF

/// Page commands go through the editor model, so these also prove each one is
/// undoable (and therefore autosaved) and that redo works.
@Suite struct PageOperationTests {
    let undo = UndoManager()

    private func model(pages: Int) -> PDFEditorModel {
        let model = PDFEditorModel(document: PDFFileDocument(pdf: Fixtures.document(pages: pages)))
        undo.groupsByEvent = false
        model.undoManager = undo
        return model
    }

    /// The "Page n" label of every page, in order.
    private func labels(_ model: PDFEditorModel) -> [String] {
        (0..<model.pdf.pageCount).map { model.pdf.page(at: $0)?.string?.components(separatedBy: "\n").first ?? "" }
    }

    /// Runs one undoable step in its own group, like one user action.
    private func step(_ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    @Test func newDocumentHasOneBlankPage() {
        let document = PDFFileDocument()
        #expect(document.pdf.pageCount == 1)
        #expect(document.pdf.page(at: 0)?.bounds(for: .mediaBox).width ?? 0 > 500)
    }

    @Test func insertBlankPageAndUndo() {
        let model = model(pages: 2)
        step { model.insertBlankPage() }
        #expect(model.pdf.pageCount == 3)
        #expect(labels(model) == ["Page 1", "", "Page 2"])
        undo.undo()
        #expect(labels(model) == ["Page 1", "Page 2"])
        undo.redo()
        #expect(model.pdf.pageCount == 3)
    }

    @Test func deleteRestoresAtOriginalPositions() {
        let model = model(pages: 5)
        model.selectedPages = [1, 3]
        step { model.deleteSelectedPages() }
        #expect(labels(model) == ["Page 1", "Page 3", "Page 5"])
        undo.undo()
        #expect(labels(model) == ["Page 1", "Page 2", "Page 3", "Page 4", "Page 5"])
    }

    @Test func refusesToDeleteEveryPage() {
        let model = model(pages: 1)
        model.remove([model.pdf.page(at: 0)!])  // page 0 exists: the fixture has one page.
        #expect(model.pdf.pageCount == 1)
    }

    @Test func moveKeepsRelativeOrderAndUndoes() {
        let model = model(pages: 5)
        step { model.movePages([0, 1], to: 4) }
        #expect(labels(model) == ["Page 3", "Page 4", "Page 1", "Page 2", "Page 5"])
        undo.undo()
        #expect(labels(model) == ["Page 1", "Page 2", "Page 3", "Page 4", "Page 5"])
        undo.redo()
        #expect(labels(model) == ["Page 3", "Page 4", "Page 1", "Page 2", "Page 5"])
    }

    @Test func moveToEnd() {
        let model = model(pages: 3)
        step { model.movePages([0], to: 3) }
        #expect(labels(model) == ["Page 2", "Page 3", "Page 1"])
    }

    @Test func rotateAndUndo() {
        let model = model(pages: 2)
        model.selectedPages = [0, 1]
        step { model.rotateRight() }
        #expect(model.pdf.page(at: 0)?.rotation == 90)
        #expect(model.pdf.page(at: 1)?.rotation == 90)
        step { model.rotateLeft() }
        step { model.rotateLeft() }
        #expect(model.pdf.page(at: 0)?.rotation == 270)
        undo.undo()
        undo.undo()
        undo.undo()
        #expect(model.pdf.page(at: 0)?.rotation == 0)
    }

    @Test func duplicateInsertsCopiesAfterSelection() {
        let model = model(pages: 3)
        model.selectedPages = [0, 1]
        step { model.duplicateSelectedPages() }
        #expect(labels(model) == ["Page 1", "Page 2", "Page 1", "Page 2", "Page 3"])
    }

    @Test func duplicatedPagesKeepImageStampsAfterSaving() throws {
        let model = model(pages: 1)
        let stamp = try #require(Stamp.check.render())
        model.pdf.page(at: 0)?.addAnnotation(
            ImageAnnotation(image: stamp.image, bounds: CGRect(origin: CGPoint(x: 100, y: 100), size: stamp.size), name: "Check"))
        step { model.duplicateSelectedPages() }
        let reopened = try #require(Fixtures.reloaded(model.pdf))
        #expect(reopened.page(at: 1)?.annotations.contains { $0.type == "Stamp" } == true)
    }

    @Test func extractCopiesPagesWithAnnotations() throws {
        let source = Fixtures.document(pages: 4)
        source.page(at: 2)?.addAnnotation(AnnotationFactory.note(at: CGPoint(x: 100, y: 100), style: .defaults(for: .note)))
        let extracted = try #require(Fixtures.reloaded(PDFOperations.extract([2, 0], from: source)))
        #expect(extracted.pageCount == 2)
        #expect(extracted.page(at: 0)?.string?.contains("Page 3") == true)
        #expect(extracted.page(at: 0)?.annotations.contains { $0.type == "Text" } == true)
        #expect(source.pageCount == 4)
    }

    @Test func documentPropertiesAreUndoable() {
        let model = model(pages: 1)
        step { model.setAttribute(.titleAttribute, to: "Quarterly report") }
        step { model.setAttribute(.keywordsAttribute, to: "finance, q3") }
        #expect(model.attribute(.titleAttribute) == "Quarterly report")
        #expect(model.pdf.documentAttributes?[PDFDocumentAttribute.keywordsAttribute] as? [String] == ["finance", "q3"])
        undo.undo()
        undo.undo()
        #expect(model.attribute(.titleAttribute) == "")
    }

    @Test func snapshotSerialisesLiveEdits() throws {
        let document = PDFFileDocument(pdf: Fixtures.document(pages: 2))
        let model = PDFEditorModel(document: document)
        model.insertBlankPage()
        let snapshot = try document.snapshot(contentType: .pdf)
        let data = try snapshot.access.withLock { try PDFOperations.data($0) }
        #expect(PDFDocument(data: data)?.pageCount == 3)
    }

    @Test func largeDocumentOpensQuickly() throws {
        let data = try #require(Fixtures.document(pages: 500).dataRepresentation())
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let document = PDFDocument(data: data)
            _ = document?.page(at: 0)?.string
        }
        #expect(elapsed < .milliseconds(500))
    }
}

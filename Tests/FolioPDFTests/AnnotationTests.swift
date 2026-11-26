import PDFKit
import SwiftUI
import Testing

@testable import FolioPDF

@Suite struct AnnotationTests {
    private func model(pages: Int = 1) -> (PDFEditorModel, UndoManager) {
        let model = PDFEditorModel(document: PDFFileDocument(pdf: Fixtures.document(pages: pages, extra: [0: "highlight me please"])))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        return (model, undo)
    }

    private func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    @Test func inkPathIsRelativeToItsBounds() throws {
        let points = [CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 180), CGPoint(x: 220, y: 120)]
        let ink = try #require(AnnotationFactory.ink(points: points, style: .defaults(for: .pen)))
        #expect(ink.bounds.contains(CGRect(x: 100, y: 100, width: 120, height: 80)))
        let path = try #require(ink.paths?.first)
        #expect(path.bounds.minX >= 0 && path.bounds.maxX <= ink.bounds.width)
    }

    @Test func arrowHasEndpointsAndHead() {
        let arrow = AnnotationFactory.shape(.arrow, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 90), style: .defaults(for: .arrow))
        #expect(arrow.type == PDFAnnotationSubtype.line.name)
        #expect(arrow.endLineStyle == .openArrow)
        let start = CGPoint(x: arrow.bounds.minX + arrow.startPoint.x, y: arrow.bounds.minY + arrow.startPoint.y)
        #expect(abs(start.x - 50) < 0.01 && abs(start.y - 50) < 0.01)
    }

    @Test func markupCoversEachSelectedLine() throws {
        let (model, undo) = model()
        let selection = try #require(model.pdf.findString("highlight me", withOptions: []).first)
        step(undo) { model.applyMarkup(.highlight, to: selection) }
        let page = try #require(model.pdf.page(at: 0))
        let highlights = page.annotations.filter { $0.type == PDFAnnotationSubtype.highlight.name }
        #expect(highlights.count == 1)
        #expect(highlights.first?.quadrilateralPoints?.count == 4)
        undo.undo()
        #expect(page.annotations.isEmpty)
    }

    @Test func addMoveAndDeleteAreUndoable() throws {
        let (model, undo) = model()
        let page = try #require(model.pdf.page(at: 0))
        model.tool = .rectangle
        step(undo) { model.finishDrag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 160), on: page) }
        let shape = try #require(page.annotations.first)
        #expect(model.selectedAnnotation === shape)
        #expect(model.tool == .select)

        let original = shape.bounds
        step(undo) { model.nudgeSelection(dx: 10, dy: 0) }
        #expect(shape.bounds.minX == original.minX + 10)
        step(undo) { model.deleteSelectedAnnotation() }
        #expect(page.annotations.isEmpty)

        undo.undo()
        #expect(page.annotations.count == 1)
        undo.undo()
        #expect(shape.bounds == original)
        undo.undo()
        #expect(page.annotations.isEmpty)
    }

    @Test func styleChangesAreUndoable() throws {
        let (model, undo) = model()
        let page = try #require(model.pdf.page(at: 0))
        model.tool = .rectangle
        step(undo) { model.finishDrag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 160), on: page) }
        let shape = try #require(model.selectedAnnotation)
        var style = model.activeStyle
        style.lineWidth = 9
        style.color = .blue
        step(undo) { model.updateStyle(style) }
        #expect(shape.border?.lineWidth == 9)
        #expect(PDFColor.nearestSwatch(to: shape.color) == .blue)
        undo.undo()
        #expect(shape.border?.lineWidth == 2)
    }

    @Test func textBoxTextIsUndoable() throws {
        let (model, undo) = model()
        let page = try #require(model.pdf.page(at: 0))
        model.tool = .textBox
        step(undo) { model.finishDrag(from: CGPoint(x: 72, y: 300), to: CGPoint(x: 72, y: 300), on: page) }
        let box = try #require(model.selectedAnnotation)
        #expect(box.type == PDFAnnotationSubtype.freeText.name)
        step(undo) { model.setText("Signed and dated", of: box) }
        #expect(box.contents == "Signed and dated")
        undo.undo()
        #expect(box.contents == "Text")
    }

    @Test func colorsResolveForPaperNotTheWindow() {
        let yellow = PDFColor.resolve(.yellow, alpha: 0.5)
        #expect(yellow.alphaComponent == 0.5)
        #expect(yellow.redComponent > 0.9 && yellow.blueComponent < 0.3)
        #expect(PDFColor.nearestSwatch(to: NSColor(srgbRed: 0.95, green: 0.1, blue: 0.1, alpha: 1)) == .red)
    }

    @Test func everyStampRenders() {
        for stamp in Stamp.allCases {
            let rendered = stamp.render(on: Date(timeIntervalSince1970: 0))
            #expect(rendered != nil, "\(stamp.title)")
            #expect((rendered?.size.width ?? 0) >= 30)
        }
    }

    @Test func signatureRoundTripsThroughDisk() throws {
        let folder = try Fixtures.temporaryFolder()
        #expect(SignatureStore.load(from: folder) == nil)
        let ink = try #require(Fixtures.image(width: 300, height: 100, color: CGColor(gray: 0, alpha: 1)))
        try SignatureStore.save(ink, in: folder)
        #expect(SignatureStore.load(from: folder)?.width == 300)
        SignatureStore.clear(in: folder)
        #expect(SignatureStore.load(from: folder) == nil)
    }

    @Test func kindsDecideWhatCanBeEdited() {
        let widget = PDFAnnotation(bounds: .zero, forType: .widget, withProperties: nil)
        let highlight = PDFAnnotation(bounds: .zero, forType: .highlight, withProperties: nil)
        let square = PDFAnnotation(bounds: .zero, forType: .square, withProperties: nil)
        #expect(!AnnotationKind(widget).isEditable)
        #expect(AnnotationKind(highlight).isEditable && !AnnotationKind(highlight).isMovable)
        #expect(AnnotationKind(square).isResizable)
    }
}

import Testing

@testable import FolioSheets

private func ref(_ a1: String) -> CellRef { CellRef(a1: a1)! }

@Suite("Structural edits")
struct StructuralEditTests {
    @Test func insertRowShiftsCellsAndFormulas() {
        let wb = makeWorkbook(["A1": "1", "A2": "2", "A3": "=SUM(A1:A2)"], sheets: ["Other": ["A1": "='Sheet 1'!A2"]])
        let out = StructuralEdits.insert(.rows, at: 1, sheet: 0, in: wb)
        #expect(out.sheets[0][ref("A1")] == "1")
        #expect(out.sheets[0][ref("A2")] == "")
        #expect(out.sheets[0][ref("A3")] == "2")
        #expect(out.sheets[0][ref("A4")] == "=SUM(A1:A3)")
        #expect(out.sheets[1][ref("A1")] == "='Sheet 1'!A3")
        #expect(value("A4", in: out) == .number(3))
    }

    @Test func deleteRowMakesDanglingReferencesRefErrors() {
        let wb = makeWorkbook(["A1": "1", "A2": "2", "A3": "=A2*2", "A4": "=SUM(A1:A3)"])
        let out = StructuralEdits.delete(.rows, at: 1, sheet: 0, in: wb)
        #expect(out.sheets[0][ref("A2")] == "=#REF!*2")
        #expect(out.sheets[0][ref("A3")] == "=SUM(A1:A2)")
        #expect(value("A2", in: out) == .error(.ref))
    }

    @Test func insertAndDeleteColumnsMoveWidths() {
        var wb = makeWorkbook(["A1": "1", "B1": "=A1+1", "C1": "x"])
        wb.sheets[0].columnWidths = [1: 150, 2: 60]
        let inserted = StructuralEdits.insert(.columns, at: 1, count: 2, sheet: 0, in: wb)
        #expect(inserted.sheets[0][ref("D1")] == "=A1+1")
        #expect(inserted.sheets[0].columnWidths == [3: 150, 4: 60])
        let deleted = StructuralEdits.delete(.columns, at: 0, sheet: 0, in: wb)
        #expect(deleted.sheets[0][ref("A1")] == "=#REF!+1")
        #expect(deleted.sheets[0].columnWidths == [0: 150, 1: 60])
    }

    @Test func renameRewritesReferencesEverywhere() throws {
        let wb = makeWorkbook(["A1": "=Data!B2"], sheets: ["Data": ["B2": "7"]])
        let out = try StructuralEdits.renameSheet(1, to: "Raw data", in: wb)
        #expect(out.sheets[1].name == "Raw data")
        #expect(out.sheets[0][ref("A1")] == "='Raw data'!B2")
        #expect(value("A1", in: out) == .number(7))
    }

    @Test(arguments: ["", "  ", "a/b", "x[1]", "Data"])
    func rejectsBadSheetNames(_ name: String) {
        let wb = makeWorkbook([:], sheets: ["Data": [:]])
        #expect(throws: FolioSheetsError.self) { try StructuralEdits.renameSheet(0, to: name, in: wb) }
    }

    @Test func deleteSheetBreaksReferencesToIt() {
        let wb = makeWorkbook(["A1": "=Data!B2+1"], sheets: ["Data": ["B2": "7"]])
        let out = StructuralEdits.deleteSheet(1, in: wb)
        #expect(out.sheets.count == 1)
        #expect(out.sheets[0][ref("A1")] == "=#REF!+1")
        #expect(StructuralEdits.deleteSheet(0, in: out).sheets.count == 1)  // never deletes the last sheet
    }

    @Test func moveSheetKeepsActiveSheet() {
        var wb = makeWorkbook([:], sheets: ["B": [:], "C": [:]])
        wb.activeSheetIndex = 0
        let out = StructuralEdits.moveSheet(from: 0, to: 2, in: wb)
        #expect(out.sheets.map(\.name) == ["B", "C", "Sheet 1"])
        #expect(out.activeSheetIndex == 2)
    }

    @Test func uniqueSheetNames() {
        var wb = Workbook()
        wb.addSheet()
        wb.addSheet()
        #expect(wb.sheets.map(\.name) == ["Sheet 1", "Sheet 2", "Sheet 3"])
        #expect(Set(wb.sheets.map(\.id)).count == 3)
    }
}

@Suite("Range edits")
struct RangeEditTests {
    @Test func fillDownAdjustsReferences() {
        let wb = makeWorkbook(["A1": "1", "B1": "=A1*2", "C1": "=$A$1+A1"])
        let changes = RangeEdits.fill(CellRange(a1: "B1:C3")!, .down, in: wb.sheets[0])
        #expect(changes[ref("B2")]?.input == "=A2*2")
        #expect(changes[ref("B3")]?.input == "=A3*2")
        #expect(changes[ref("C3")]?.input == "=$A$1+A3")
        #expect(changes.count == 4)
    }

    @Test func fillRightCopiesStyles() {
        var wb = makeWorkbook(["A1": "=A2", "A2": "5"])
        wb.sheets[0].setStyle(CellStyle(bold: true), at: ref("A1"))
        let changes = RangeEdits.fill(CellRange(a1: "A1:C1")!, .right, in: wb.sheets[0])
        #expect(changes[ref("C1")] == CellContent(input: "=C2", style: CellStyle(bold: true)))
    }

    @Test func pasteOffsetsFormulasFromTheirOrigin() {
        let wb = makeWorkbook(["A1": "1", "B1": "=A1+1"])
        let block = CellBlock(sheet: wb.sheets[0], range: CellRange(a1: "A1:B1")!)
        let changes = RangeEdits.paste(block, at: ref("C5"))
        #expect(changes[ref("C5")]?.input == "1")
        #expect(changes[ref("D5")]?.input == "=C5+1")
    }

    @Test func pastingOneCellFillsASelection() {
        let wb = makeWorkbook(["A1": "=B1"])
        let block = CellBlock(sheet: wb.sheets[0], range: CellRange(a1: "A1")!)
        let changes = RangeEdits.paste(block, at: ref("D1"), fillRange: CellRange(a1: "D1:D3")!)
        #expect(changes.count == 3)
        #expect(changes[ref("D3")]?.input == "=E3")
    }

    @Test func sortsRowsByColumn() {
        let wb = makeWorkbook(["A1": "b", "B1": "2", "A2": "", "B2": "9", "A3": "a", "B3": "1", "A4": "C", "B4": "3"])
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        let sheet = wb.sheets[0]
        let changes = RangeEdits.sort(CellRange(a1: "A1:B4")!, byColumn: 0, ascending: true, in: sheet) { CellValue.literal(sheet[$0]) }
        var sorted = sheet
        for (r, c) in changes { sorted.setInput(c.input, at: r) }
        #expect((0..<4).map { sorted[CellRef(row: $0, col: 0)] } == ["a", "b", "C", ""])  // empty sorts last
        #expect((0..<4).map { sorted[CellRef(row: $0, col: 1)] } == ["1", "2", "3", "9"])
    }

    @Test func sortsDescendingNumbers() {
        let wb = makeWorkbook(["A1": "10", "A2": "2", "A3": "33"])
        let sheet = wb.sheets[0]
        let changes = RangeEdits.sort(CellRange(a1: "A1:A3")!, byColumn: 0, ascending: false, in: sheet) { CellValue.literal(sheet[$0]) }
        #expect(changes[ref("A1")]?.input == "33")
        #expect(changes[ref("A3")]?.input == "2")
    }

    @Test func findAndReplace() {
        let wb = makeWorkbook(["A1": "Apple pie", "B2": "apple", "C3": "pear", "A2": "=\"apple\""])
        let sheet = wb.sheets[0]
        #expect(RangeEdits.find("apple", in: sheet) == [ref("A1"), ref("A2"), ref("B2")])
        #expect(RangeEdits.find("apple", in: sheet, matchCase: true) == [ref("A2"), ref("B2")])
        let changes = RangeEdits.replace("apple", with: "plum", in: sheet)
        #expect(changes[ref("A1")]?.input == "plum pie")
        #expect(changes[ref("C3")] == nil)
        #expect(RangeEdits.find("", in: sheet).isEmpty)
    }

    @Test func clearKeepsStylesUnlessAsked() {
        var wb = makeWorkbook(["A1": "x"])
        wb.sheets[0].setStyle(CellStyle(italic: true), at: ref("A1"))
        let keep = RangeEdits.clear(CellRange(a1: "A1:Z100")!, in: wb.sheets[0])
        #expect(keep[ref("A1")] == CellContent(input: "", style: CellStyle(italic: true)))
        let wipe = RangeEdits.clear(CellRange(a1: "A1:Z100")!, in: wb.sheets[0], styles: true)
        #expect(wipe[ref("A1")] == .empty)
    }

    @Test func criteriaWildcards() {
        #expect(Criteria.wildcardMatch("banana", "b*a"))
        #expect(Criteria.wildcardMatch("banana", "?anana"))
        #expect(!Criteria.wildcardMatch("banana", "b?a"))
        #expect(Criteria.wildcardMatch("a*b", "a~*b"))
        #expect(!Criteria.wildcardMatch("axb", "a~*b"))
    }
}

@Suite("Document editing")
@MainActor
struct DocumentTests {
    @Test func editsAreUndoable() {
        let doc = SpreadsheetDocument()
        let undo = newUndoManager()
        undo.beginUndoGrouping()
        doc.apply([ref("A1"): CellContent(input: "4"), ref("A2"): CellContent(input: "=A1*2")], actionName: "Typing", undoManager: undo)
        undo.endUndoGrouping()
        #expect(doc.value(at: ref("A2")) == .number(8))
        #expect(doc.displayText(at: ref("A2")) == "8")
        undo.undo()
        #expect(doc.activeSheet[ref("A1")] == "")
        #expect(doc.value(at: ref("A2")) == .empty)
        undo.redo()
        #expect(doc.value(at: ref("A2")) == .number(8))
    }

    @Test func structuralEditsUndo() {
        let doc = SpreadsheetDocument()
        let undo = newUndoManager()
        doc.apply([ref("A1"): CellContent(input: "1"), ref("A2"): CellContent(input: "=A1")], actionName: "Typing", undoManager: nil)
        undo.beginUndoGrouping()
        doc.replaceWorkbook(StructuralEdits.insert(.rows, at: 0, sheet: 0, in: doc.workbook), actionName: "Insert Row", undoManager: undo)
        undo.endUndoGrouping()
        #expect(doc.activeSheet[ref("A3")] == "=A2")
        #expect(doc.value(at: ref("A3")) == .number(1))
        undo.undo()
        #expect(doc.activeSheet[ref("A2")] == "=A1")
    }

    @Test func sheetPropertiesUndo() {
        let doc = SpreadsheetDocument()
        let undo = newUndoManager()
        undo.beginUndoGrouping()
        doc.updateSheet(0, actionName: "Freeze", undoManager: undo) {
            $0.frozenRows = 1; $0.columnWidths[2] = 200
        }
        undo.endUndoGrouping()
        #expect(doc.activeSheet.frozenRows == 1)
        undo.undo()
        #expect(doc.activeSheet.frozenRows == 0)
        #expect(doc.activeSheet.columnWidths.isEmpty)
    }

    @Test func csvDocumentWarnsOnceAboutExtraSheets() throws {
        let doc = try SpreadsheetDocument(data: bytes("a,b\n"), format: .csv)
        doc.apply([ref("C1"): CellContent(input: "=1+1")], actionName: "Typing", undoManager: nil)
        #expect(doc.formatWarning == nil, "formulas are kept in CSV, so there's nothing to warn about")
        doc.replaceWorkbook(
            {
                var w = doc.workbook; w.addSheet(); return w
            }(), actionName: "Add Sheet", undoManager: nil)
        #expect(doc.formatWarning != nil)
        doc.dismissFormatWarning()
        doc.replaceWorkbook(
            {
                var w = doc.workbook; w.addSheet(); return w
            }(), actionName: "Add Sheet", undoManager: nil)
        #expect(doc.formatWarning == nil)
    }

    @Test func snapshotSavesInOpenedFormat() throws {
        let doc = try SpreadsheetDocument(data: bytes("x,1\n"), format: .csv)
        doc.apply([ref("B1"): CellContent(input: "=1+1")], actionName: "Typing", undoManager: nil)
        let snap = try doc.snapshot(contentType: csvType)
        let out = try doc.format.write(snap.workbook, values: snap.values)
        #expect(text(out) == "x,=1+1\r\n")
    }

    @Test func selectingASheetIsNotAnEdit() {
        let doc = SpreadsheetDocument()
        doc.replaceWorkbook(
            {
                var w = doc.workbook; w.addSheet(); return w
            }(), actionName: "Add Sheet", undoManager: nil)
        doc.selectSheet(1)
        #expect(doc.activeSheetIndex == 1)
    }
}

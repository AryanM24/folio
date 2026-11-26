import Testing

@testable import FolioSheets

private func ref(_ a1: String) -> CellRef { CellRef(a1: a1)! }

@MainActor
private func controller(_ cells: [String: String]) -> SheetController {
    let doc = SpreadsheetDocument()
    doc.apply(cells.reduce(into: [:]) { $0[ref($1.key)] = CellContent(input: $1.value) }, actionName: "Setup", undoManager: nil)
    return SheetController(document: doc)
}

@Suite("Editor controller")
@MainActor
struct EditorControllerTests {
    @Test func commandArrowJumpsToDataEdges() {
        // A1:A3 filled, gap, A6:A7 filled.
        let c = controller(["A1": "1", "A2": "2", "A3": "3", "A6": "6", "A7": "7"])
        #expect(c.dataEdge(from: ref("A1"), dr: 1, dc: 0) == ref("A3"))  // end of block
        #expect(c.dataEdge(from: ref("A3"), dr: 1, dc: 0) == ref("A6"))  // next block
        #expect(c.dataEdge(from: ref("A6"), dr: 1, dc: 0) == ref("A7"))
        #expect(c.dataEdge(from: ref("A7"), dr: -1, dc: 0) == ref("A6"))
        #expect(c.dataEdge(from: ref("A5"), dr: -1, dc: 0) == ref("A3"))
        #expect(c.dataEdge(from: ref("A1"), dr: -1, dc: 0) == ref("A1"))  // already at the edge
    }

    @Test func shiftArrowsExtendFromTheAnchor() {
        let c = controller([:])
        c.select(ref("B2"))
        c.move(rows: 2, cols: 1, extend: true)
        #expect(c.selectedRange == CellRange(a1: "B2:C4"))
        #expect(c.selection.active == ref("B2"))
        c.move(rows: 1, cols: 0)
        #expect(c.selectedRange == CellRange(a1: "B3"))
    }

    @Test func movementStopsAtTheTopLeft() {
        let c = controller([:])
        c.move(rows: -5, cols: -5)
        #expect(c.selection.active == ref("A1"))
    }

    @Test func typedInputInfersFormats() {
        let c = controller([:])
        c.setInput("12%", at: ref("A1"))
        c.setInput("$4.50", at: ref("A2"))
        c.setInput("2024-01-01", at: ref("A3"))
        c.setInput("42", at: ref("A4"))
        #expect(c.sheet.style(at: ref("A1")).numberFormat == .percent)
        #expect(c.sheet.style(at: ref("A2")).numberFormat == .currency)
        #expect(c.sheet[ref("A3")] == "45292")
        #expect(c.sheet.style(at: ref("A3")).numberFormat == .date)
        #expect(c.sheet.style(at: ref("A4")).isPlain)
        #expect(c.document.value(at: ref("A1")) == .number(0.12))
    }

    @Test func editingCommitsAndMoves() {
        let c = controller(["A1": "1"])
        c.select(ref("A2"))
        c.beginEditing(initial: "=A1+1")
        #expect(c.isEditing)
        #expect(c.formulaText == "=A1+1")
        c.commitEditing("=A1+1", move: (1, 0))
        #expect(!c.isEditing)
        #expect(c.selection.active == ref("A3"))
        #expect(c.document.value(at: ref("A2")) == .number(2))
        c.select(ref("A1"))
        c.beginEditing()
        c.cancelEditing()
        #expect(c.sheet[ref("A1")] == "1")
    }

    @Test func nameBoxNavigates() {
        let c = controller([:])
        #expect(c.go(to: "c5"))
        #expect(c.selection.active == ref("C5"))
        #expect(c.go(to: "A1:B3"))
        #expect(c.selectedRange == CellRange(a1: "A1:B3"))
        #expect(!c.go(to: "nonsense"))
        #expect(!c.go(to: "Nope!A1"))
    }

    @Test func formattingToggleAppliesToSelection() {
        let c = controller(["A1": "x", "B1": "y"])
        _ = c.go(to: "A1:B1")
        c.toggleBold()
        #expect(c.sheet.style(at: ref("B1")).bold)
        c.toggleBold()
        #expect(!c.sheet.style(at: ref("B1")).bold)
        c.setFill(RGBColor(hex: 0xFF0000))
        c.setNumberFormat(.currency)
        #expect(c.sheet.style(at: ref("A1")) == CellStyle(fill: RGBColor(hex: 0xFF0000), numberFormat: .currency))
        c.clearFormatting()
        #expect(c.sheet.style(at: ref("A1")).isPlain)
    }

    @Test func wholeColumnFormattingStaysWithinData() {
        let c = controller(["B1": "1", "B5": "2"])
        c.selectColumns(1, 1)
        c.toggleItalic()
        #expect(c.sheet.styles.count == 5)  // B1:B5, not 1,000 rows
    }

    @Test func statusBarStats() {
        let c = controller(["A1": "2", "A2": "4", "A3": "x"])
        #expect(c.stats == nil)  // single cell
        _ = c.go(to: "A1:A4")
        #expect(c.stats == SheetController.Stats(sum: 6, count: 3, numbers: 2))
        #expect(c.stats?.average == 3)
    }

    @Test func insertAndDeleteRowsFromSelection() {
        let c = controller(["A1": "1", "A2": "=A1"])
        c.select(ref("A1"))
        c.insertRows(above: true)
        #expect(c.sheet[ref("A3")] == "=A2")
        c.select(ref("A1"))
        c.deleteRows()
        #expect(c.sheet[ref("A2")] == "=A1")
    }

    @Test func sheetsAddRenameDelete() {
        let c = controller([:])
        c.addSheet()
        #expect(c.document.workbook.sheets.count == 2)
        #expect(c.document.activeSheetIndex == 1)
        c.renameSheet(1, to: "Totals")
        #expect(c.document.workbook.sheets[1].name == "Totals")
        c.moveSheet(1, by: -1)
        #expect(c.document.workbook.sheets[0].name == "Totals")
        c.deleteSheet(0)
        #expect(c.document.workbook.sheets.map(\.name) == ["Sheet 1"])
    }

    @Test func findCyclesThroughMatches() {
        let c = controller(["A1": "apple", "C3": "Apple pie", "B9": "pear"])
        c.findText = "apple"
        c.findNext()
        #expect(c.selection.active == ref("C3"))
        c.findNext()
        #expect(c.selection.active == ref("A1"))  // wraps
        c.replaceText = "fig"
        c.replaceAll()
        #expect(c.sheet[ref("C3")] == "fig pie")
    }

    @Test func insertChartUsesSelectionOrData() {
        let c = controller(["A1": "1", "B2": "2"])
        c.insertChart()
        #expect(c.chart?.range == CellRange(a1: "A1:B2"))
    }
}

@Suite("Clipboard and charts")
struct ClipboardChartTests {
    @Test func tsvQuotesSpecialFields() {
        #expect(ClipboardFormat.tsv(rows: [["a", "b\tc"], ["say \"hi\"", "x"]]) == "a\t\"b\tc\"\n\"say \"\"hi\"\"\"\tx")
    }

    @Test func htmlCarriesStyles() {
        let html = ClipboardFormat.html(rows: [["<b>"]], styles: [[CellStyle(bold: true, fill: RGBColor(hex: 0x00FF00))]])
        #expect(html.contains("font-weight:bold"))
        #expect(html.contains("background-color:#00FF00"))
        #expect(html.contains("&lt;b&gt;"))
    }

    @Test func pastedTextBecomesABlock() {
        let block = ClipboardFormat.block(fromText: "a\tb\n1\t2\n", at: CellRef(row: 3, col: 3))
        #expect(block.rows == 2)
        #expect(block.cols == 2)
        #expect(block[1, 1].input == "2")
        let single = ClipboardFormat.block(fromText: "1,234", at: CellRef(row: 0, col: 0))
        #expect(single.rows == 1 && single.cols == 1)
        #expect(single[0, 0].input == "1,234")
        let csv = ClipboardFormat.block(fromText: "x,y\n1,2", at: CellRef(row: 0, col: 0))
        #expect(csv.cols == 2)
    }

    @Test func chartDataDetectsHeadersAndCategories() {
        let wb = makeWorkbook([
            "A1": "Month", "B1": "Sales", "C1": "Cost", "A2": "Jan", "B2": "10", "C2": "4", "A3": "Feb", "B3": "12", "C3": "x",
        ])
        let sheet = wb.sheets[0]
        let data = ChartData(range: CellRange(a1: "A1:C3")!) { CellValue.literal(sheet[$0]) }
        #expect(data.seriesNames == ["Sales", "Cost"])
        #expect(data.points.count == 3)  // "x" is skipped
        #expect(data.points.first == ChartData.Point(id: 0, category: "Jan", series: "Sales", value: 10))
    }

    @Test func chartDataWithoutLabelsUsesRowNumbers() {
        let wb = makeWorkbook(["B2": "5", "B3": "6"])
        let sheet = wb.sheets[0]
        let data = ChartData(range: CellRange(a1: "B2:B3")!) { CellValue.literal(sheet[$0]) }
        #expect(data.seriesNames == ["B"])
        #expect(data.points.map(\.category) == ["2", "3"])
    }
}

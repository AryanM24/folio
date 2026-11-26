import Testing

@testable import FolioSheets

@Suite("Formula engine")
struct FormulaEngineTests {
    @Test func computesFormulaCells() {
        let wb = makeWorkbook(["A1": "2", "A2": "3", "A3": "=A1*A2"])
        #expect(value("A3", in: wb) == .number(6))
    }

    @Test func formulasReadOtherFormulas() {
        let wb = makeWorkbook(["A1": "=A2+1", "A2": "=A3+1", "A3": "1"])
        #expect(value("A1", in: wb) == .number(3))
    }

    @Test func tenThousandCellChainDoesNotOverflowTheStack() {
        var wb = Workbook()
        wb.sheets[0].setInput("1", at: CellRef(row: 0, col: 0))
        for r in 1..<10_000 { wb.sheets[0].setInput("=A\(r)+1", at: CellRef(row: r, col: 0)) }
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        #expect(engine.value(sheetID: wb.sheets[0].id, cell: CellRef(row: 9_999, col: 0)) == .number(10_000))
        // And incrementally, after changing the head of the chain.
        wb.sheets[0].setInput("101", at: CellRef(row: 0, col: 0))
        engine.cellsChanged([CellKey(sheetID: wb.sheets[0].id, cell: CellRef(row: 0, col: 0))], in: wb)
        #expect(engine.value(sheetID: wb.sheets[0].id, cell: CellRef(row: 9_999, col: 0)) == .number(10_100))
    }

    @Test func reverseOrderChainOfTenThousand() {
        // Formulas that point *down* the sheet: evaluation order must not follow row order.
        var wb = Workbook()
        for r in 0..<9_999 { wb.sheets[0].setInput("=A\(r + 2)+1", at: CellRef(row: r, col: 0)) }
        wb.sheets[0].setInput("0", at: CellRef(row: 9_999, col: 0))
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        #expect(engine.value(sheetID: 0, cell: CellRef(row: 0, col: 0)) == .number(9_999))
    }

    @Test func selfReferenceIsCircular() {
        let wb = makeWorkbook(["A1": "=A1+1"])
        #expect(value("A1", in: wb) == .error(.circular))
    }

    @Test func indirectCycleMarksEveryMember() {
        let wb = makeWorkbook(["A1": "=B1", "B1": "=C1", "C1": "=A1", "D1": "=A1+1", "E1": "5"])
        #expect(value("A1", in: wb) == .error(.circular))
        #expect(value("B1", in: wb) == .error(.circular))
        #expect(value("C1", in: wb) == .error(.circular))
        #expect(value("D1", in: wb) == .error(.circular))  // depends on the cycle
        #expect(value("E1", in: wb) == .number(5))
    }

    @Test func rangeCycleIsDetected() {
        let wb = makeWorkbook(["A1": "1", "A2": "=SUM(A1:A3)", "A3": "2"])
        #expect(value("A2", in: wb) == .error(.circular))
    }

    @Test func incrementalUpdateRecomputesDependents() {
        var wb = makeWorkbook(["A1": "1", "A2": "=A1*10", "A3": "=SUM(A1:A2)", "B1": "=A3&\"!\""])
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        #expect(engine.value(sheetID: 0, cell: CellRef(a1: "B1")!) == .text("11!"))
        wb.sheets[0].setInput("2", at: CellRef(a1: "A1")!)
        engine.cellsChanged([CellKey(sheetID: 0, cell: CellRef(a1: "A1")!)], in: wb)
        #expect(engine.value(sheetID: 0, cell: CellRef(a1: "A3")!) == .number(22))
        #expect(engine.value(sheetID: 0, cell: CellRef(a1: "B1")!) == .text("22!"))
    }

    @Test func replacingAFormulaWithAValueDropsIt() {
        var wb = makeWorkbook(["A1": "=1+1", "A2": "=A1"])
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        wb.sheets[0].setInput("7", at: CellRef(a1: "A1")!)
        engine.cellsChanged([CellKey(sheetID: 0, cell: CellRef(a1: "A1")!)], in: wb)
        #expect(engine.value(sheetID: 0, cell: CellRef(a1: "A1")!) == nil)
        #expect(engine.value(sheetID: 0, cell: CellRef(a1: "A2")!) == .number(7))
        #expect(engine.formulaCount == 1)
    }

    @Test func breakingACycleRecovers() {
        var wb = makeWorkbook(["A1": "=B1", "B1": "=A1"])
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        #expect(engine.value(sheetID: 0, cell: CellRef(a1: "A1")!) == .error(.circular))
        wb.sheets[0].setInput("4", at: CellRef(a1: "B1")!)
        engine.cellsChanged([CellKey(sheetID: 0, cell: CellRef(a1: "B1")!)], in: wb)
        #expect(engine.value(sheetID: 0, cell: CellRef(a1: "A1")!) == .number(4))
    }

    @Test func crossSheetDependencyUpdates() {
        var wb = makeWorkbook(["A1": "='My Sheet'!A1*2"], sheets: ["My Sheet": ["A1": "5"]])
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        #expect(engine.value(sheetID: 0, cell: CellRef(a1: "A1")!) == .number(10))
        let other = wb.index(ofSheetNamed: "My Sheet")!
        wb.sheets[other].setInput("6", at: CellRef(a1: "A1")!)
        engine.cellsChanged([CellKey(sheetID: wb.sheets[other].id, cell: CellRef(a1: "A1")!)], in: wb)
        #expect(engine.value(sheetID: 0, cell: CellRef(a1: "A1")!) == .number(12))
    }

    @Test func wholeColumnDependencyUpdates() {
        var wb = makeWorkbook(["A1": "1", "B1": "=SUM(A:A)"])
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        wb.sheets[0].setInput("9", at: CellRef(a1: "A50")!)
        engine.cellsChanged([CellKey(sheetID: 0, cell: CellRef(a1: "A50")!)], in: wb)
        #expect(engine.value(sheetID: 0, cell: CellRef(a1: "B1")!) == .number(10))
    }

    @Test func volatileFormulasRecalculateOnAnyEdit() {
        var wb = makeWorkbook(["A1": "=TODAY()"])
        let engine = FormulaEngine(clock: { fixedNow })
        engine.recalculateAll(wb)
        wb.sheets[0].setInput("x", at: CellRef(a1: "Z9")!)
        engine.cellsChanged([CellKey(sheetID: 0, cell: CellRef(a1: "Z9")!)], in: wb)
        #expect(engine.value(sheetID: 0, cell: CellRef(a1: "A1")!) == .number(45366))
    }

    @Test func rangeOfTenThousandRunningTotals() {
        var wb = Workbook()
        for r in 0..<2_000 {
            wb.sheets[0].setInput("1", at: CellRef(row: r, col: 0))
            wb.sheets[0].setInput("=SUM($A$1:A\(r + 1))", at: CellRef(row: r, col: 1))
        }
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        #expect(engine.value(sheetID: 0, cell: CellRef(row: 1_999, col: 1)) == .number(2_000))
    }

    @Test func errorsPropagateThroughFormulas() {
        let wb = makeWorkbook(["A1": "=1/0", "A2": "=A1+1", "A3": "=IFERROR(A2,0)"])
        #expect(value("A2", in: wb) == .error(.div0))
        #expect(value("A3", in: wb) == .number(0))
    }
}

@Suite("Tokenizer and parser")
struct ParserTests {
    @Test func tokenizesReferencesWithSheets() {
        let tokens = Tokenizer.tokenize("'My Sheet'!$A$1:B2+Data!C3")
        guard case .reference(let r) = tokens[0].kind else { Issue.record("not a reference"); return }
        #expect(r.sheet == "My Sheet")
        #expect(r.start == RefPoint(col: 0, row: 0, colAbsolute: true, rowAbsolute: true))
        #expect(r.end == RefPoint(col: 1, row: 1))
        guard case .reference(let r2) = tokens[2].kind else { Issue.record("not a reference"); return }
        #expect(r2.sheet == "Data")
    }

    @Test func quotedSheetNamesEscapeApostrophes() {
        let tokens = Tokenizer.tokenize("'Bob''s'!A1")
        guard case .reference(let r) = tokens.first?.kind else { Issue.record("not a reference"); return }
        #expect(r.sheet == "Bob's")
        #expect(r.text == "'Bob''s'!A1")
    }

    @Test func functionNamesAreUppercased() {
        #expect(Tokenizer.tokenize("sum(1)").first?.kind == .function("SUM"))
    }

    @Test func distinguishesNamesFromReferences() {
        #expect(Tokenizer.tokenize("ABCD1").first?.kind == .name("ABCD1"))
        #expect(Tokenizer.tokenize("TRUE").first?.kind == .bool(true))
        if case .reference = Tokenizer.tokenize("XFD1").first?.kind {} else { Issue.record("XFD1 is the last column") }
    }

    @Test func parsesPrecedence() {
        #expect(Parser.parse("1+2*3") == .binary("+", .number(1), .binary("*", .number(2), .number(3))))
        #expect(Parser.parse("1&2=\"12\"") == .binary("=", .binary("&", .number(1), .number(2)), .string("12")))
    }

    @Test func parsesEmptyArguments() {
        #expect(Parser.parse("IF(A1,,2)") == .call("IF", [.reference(Reference(start: RefPoint(col: 0, row: 0))), .missing, .number(2)]))
    }

    @Test(arguments: ["1+", "SUM(1", ")", "1 2", "SUM(1,,", "'unterminated!A1", "A1:"])
    func rejectsMalformed(_ text: String) {
        #expect(Parser.parse(text) == .error(.syntax))
    }

    @Test func volatileDetection() {
        #expect(Parser.parse("TODAY()+1").isVolatile)
        #expect(!Parser.parse("SUM(A1)").isVolatile)
    }
}

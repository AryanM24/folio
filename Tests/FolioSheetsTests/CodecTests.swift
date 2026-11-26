import Testing

@testable import FolioSheets

private func cell(_ wb: Workbook, _ a1: String, sheet: Int = 0) -> String { wb.sheets[sheet][CellRef(a1: a1)!] }

@Suite("CSV and TSV")
struct CSVTests {
    @Test func parsesQuotedFields() {
        let csv = "name,note\r\n\"Smith, J\",\"said \"\"hi\"\"\"\n\"multi\nline\",x\n"
        let wb = CSVCodec.read(bytes(csv))
        #expect(cell(wb, "A2") == "Smith, J")
        #expect(cell(wb, "B2") == "said \"hi\"")
        #expect(cell(wb, "A3") == "multi\nline")
        #expect(cell(wb, "B3") == "x")
        #expect(wb.sheets[0].maxRow == 2)
    }

    @Test func handlesEmptyFieldsAndLoneCR() {
        let wb = CSVCodec.read(bytes("a,,c\r,b\r"))
        #expect(cell(wb, "A1") == "a")
        #expect(cell(wb, "B1") == "")
        #expect(cell(wb, "C1") == "c")
        #expect(cell(wb, "B2") == "b")
    }

    @Test(arguments: [
        ("a,b,c\n1,2,3\n", UInt8(ascii: ",")),
        ("a\tb\tc\n1\t2\t3\n", UInt8(ascii: "\t")),
        ("a;b;c\n1,5;2;3\n", UInt8(ascii: ";")),
        ("a|b\n1|2\n", UInt8(ascii: "|")),
        ("\"x,y\";z\n\"1,2\";3\n", UInt8(ascii: ";")),  // delimiters inside quotes don't count
    ])
    func sniffsDelimiter(_ text: String, _ expected: UInt8) {
        #expect(CSVCodec.sniffDelimiter(Array(text.utf8)) == expected)
    }

    @Test func detectsEncodings() {
        #expect(CSVCodec.decode(rawBytes([0xEF, 0xBB, 0xBF, 0xC3, 0xA9, 0x2C, 0x31])) == "é,1")
        #expect(CSVCodec.decode(utf16("hé", bigEndian: false, bom: true)) == "hé")
        #expect(CSVCodec.decode(utf16("hé", bigEndian: true, bom: true)) == "hé")
        #expect(CSVCodec.decode(rawBytes([0x63, 0x61, 0x66, 0xE9])) == "café")  // Windows-1252
        #expect(CSVCodec.decode(utf16("a,b\n1,2", bigEndian: false, bom: false)) == "a,b\n1,2")
    }

    @Test func writesWithMinimalQuoting() {
        var sheet = Sheet(id: 0, name: "S")
        sheet.setInput("plain", at: CellRef(a1: "A1")!)
        sheet.setInput("has,comma", at: CellRef(a1: "B1")!)
        sheet.setInput("say \"x\"", at: CellRef(a1: "C1")!)
        sheet.setInput("two\nlines", at: CellRef(a1: "A3")!)
        let out = text(CSVCodec.write(sheet, values: { sheet[$0] }))
        #expect(out == "plain,\"has,comma\",\"say \"\"x\"\"\"\r\n\r\n\"two\nlines\"\r\n")
    }

    @Test func roundTripsThroughDocumentFormat() throws {
        let csv = "Item,Qty,Price\nApple,3,1.5\n\"Pear, green\",2,00123\n"
        let wb = try SpreadsheetFormat.csv.read(bytes(csv))
        let out = try SpreadsheetFormat.csv.write(wb, values: [:])
        let again = try SpreadsheetFormat.csv.read(out)
        #expect(again.sheets[0].cells == wb.sheets[0].cells)
        #expect(cell(again, "C3") == "00123")  // raw text survives
    }

    /// Autosave must never change what a CSV says, so formulas are written as typed.
    @Test func savesFormulasAsTyped() throws {
        let wb = makeWorkbook(["A1": "2", "A2": "=A1*21", "A3": "'007"])
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        let out = text(try SpreadsheetFormat.csv.write(wb, values: engine.values))
        #expect(out == "2\r\n=A1*21\r\n007\r\n")
    }

    @Test func formulaCSVRoundTripsExactly() throws {
        let original = "Units,Price,Revenue\r\n3,4,=A2*B2\r\n"
        let wb = try SpreadsheetFormat.csv.read(bytes(original))
        #expect(text(try SpreadsheetFormat.csv.write(wb, values: [:])) == original)
    }

    @Test func tsvUsesTabs() throws {
        let wb = try SpreadsheetFormat.tsv.read(bytes("a,b\tc\n"))
        #expect(cell(wb, "A1") == "a,b")
        #expect(cell(wb, "B1") == "c")
        #expect(text(try SpreadsheetFormat.tsv.write(wb, values: [:])) == "a,b\tc\r\n")
    }

    @Test func losesWarnsAboutMultipleSheetsButNotFormulas() {
        var wb = makeWorkbook(["A1": "=1+1"])
        #expect(SpreadsheetFormat.csv.losses(in: wb) == nil)
        #expect(SpreadsheetFormat.xlsx.losses(in: wb) == nil)
        wb.addSheet()
        #expect(SpreadsheetFormat.csv.losses(in: wb)?.contains("current sheet") == true)
    }

    @Test func largeFileParsesQuickly() {
        var csv = "id,name,value,flag\n"
        for i in 0..<100_000 { csv += "\(i),name \(i),\(Double(i) * 1.5),\(i % 2 == 0)\n" }
        let clock = ContinuousClock()
        var wb = Workbook()
        let elapsed = clock.measure { wb = CSVCodec.read(bytes(csv)) }
        #expect(wb.sheets[0].maxRow == 100_000)
        #expect(wb.sheets[0].cells.count == 400_004)
        // Generous bound for debug builds on CI; release is ~10× faster.
        #expect(elapsed < .seconds(15))
    }
}

@Suite("XLSX")
struct XLSXTests {
    private func roundTrip(_ wb: Workbook) throws -> Workbook {
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        let data = try XLSXWriter.write(wb) { engine.value(sheetID: $0, cell: $1) }
        return try XLSXReader.read(data)
    }

    @Test func roundTripsValuesFormulasAndSheets() throws {
        var wb = makeWorkbook(
            ["A1": "Name", "B1": "42", "C1": "TRUE", "D1": "=B1*2", "E1": "'00123", "F1": "#N/A", "G1": "a & <b>", "A2": "  padded  "],
            sheets: ["Second Sheet": ["A1": "=Sheet 1!B1"]]
        )
        // A quoted cross-sheet reference.
        wb.sheets[1].setInput("='Sheet 1'!B1+1", at: CellRef(a1: "A1")!)
        let back = try roundTrip(wb)
        #expect(back.sheets.map(\.name) == ["Sheet 1", "Second Sheet"])
        #expect(back.sheets[0].cells == wb.sheets[0].cells)
        #expect(cell(back, "A1", sheet: 1) == "='Sheet 1'!B1+1")
    }

    @Test func roundTripsStylesWidthsAndPanes() throws {
        var wb = makeWorkbook(["A1": "1", "B2": "0.5", "C3": "45292"])
        let bold = CellStyle(
            bold: true, italic: true, underline: true, alignment: .center, fill: RGBColor(hex: 0xFFEE00), textColor: RGBColor(hex: 0x1155CC)
        )
        wb.sheets[0].setStyle(bold, at: CellRef(a1: "A1")!)
        wb.sheets[0].setStyle(CellStyle(numberFormat: .percent), at: CellRef(a1: "B2")!)
        wb.sheets[0].setStyle(CellStyle(numberFormat: .date), at: CellRef(a1: "C3")!)
        wb.sheets[0].setStyle(CellStyle(numberFormat: .currency), at: CellRef(a1: "D4")!)
        wb.sheets[0].setStyle(CellStyle(alignment: .right, numberFormat: .number), at: CellRef(a1: "E5")!)
        wb.sheets[0].columnWidths = [0: 180, 3: 54]
        wb.sheets[0].frozenRows = 1
        wb.sheets[0].frozenCols = 2
        let back = try roundTrip(wb)
        #expect(back.sheets[0].styles == wb.sheets[0].styles)
        #expect(back.sheets[0].columnWidths == wb.sheets[0].columnWidths)
        #expect(back.sheets[0].frozenRows == 1)
        #expect(back.sheets[0].frozenCols == 2)
    }

    @Test func writesCachedFormulaValues() throws {
        let wb = makeWorkbook(["A1": "3", "A2": "=A1*2", "A3": "=\"x\"&A1"])
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        let data = try XLSXWriter.write(wb) { engine.value(sheetID: $0, cell: $1) }
        let archive = try ZipPackage.open(data)
        let sheet = text(try #require(try ZipPackage.read(archive, "xl/worksheets/sheet1.xml")))
        #expect(sheet.contains("<c r=\"A2\"><f>A1*2</f><v>6</v></c>"))
        #expect(sheet.contains("<c r=\"A3\" t=\"str\"><f>&quot;x&quot;&amp;A1</f><v>x3</v></c>"))
    }

    @Test func rememberedActiveSheet() throws {
        var wb = makeWorkbook([:], sheets: ["B": [:]])
        wb.activeSheetIndex = 1
        #expect(try roundTrip(wb).activeSheetIndex == 1)
    }

    @Test func readsExcelStyleParts() throws {
        // Hand-written parts in the shape Excel produces: shared strings with rich runs,
        // inline strings, shared formulas, a booleans and a date style.
        let workbook = """
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>
            """
        let rels = """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="worksheet" Target="/xl/worksheets/data.xml"/></Relationships>
            """
        let strings = """
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>plain</t></si>\
            <si><r><rPr><b/></rPr><t>rich </t></r><r><t>text</t></r><rPh><t>ignored</t></rPh></si></sst>
            """
        let styles = """
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <numFmts count="1"><numFmt numFmtId="170" formatCode="yyyy\\-mm\\-dd"/></numFmts>\
            <fonts count="2"><font><sz val="11"/></font><font><b/><sz val="11"/></font></fonts>\
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
            <cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0"/><xf numFmtId="170" fontId="0" fillId="0"/><xf numFmtId="0" fontId="1" fillId="0"/></cellXfs>\
            </styleSheet>
            """
        let sheet = """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s" s="2"><v>1</v></c><c r="C1" t="inlineStr"><is><t>inline</t></is></c></row>\
            <row r="2"><c r="A2"><v>1</v></c><c r="B2"><f t="shared" ref="B2:B4" si="0">A2*10</f><v>10</v></c></row>\
            <row r="3"><c r="A3"><v>2</v></c><c r="B3"><f t="shared" si="0"/><v>20</v></c></row>\
            <row r="4"><c r="A4" t="b"><v>1</v></c><c r="B4"><f t="shared" si="0"/></c><c r="C4" s="1"><v>45292</v></c></row>\
            </sheetData></worksheet>
            """
        let data = try ZipPackage.write([
            ("xl/workbook.xml", bytes(workbook), false),
            ("xl/_rels/workbook.xml.rels", bytes(rels), false),
            ("xl/sharedStrings.xml", bytes(strings), false),
            ("xl/styles.xml", bytes(styles), false),
            ("xl/worksheets/data.xml", bytes(sheet), false),
        ])
        let wb = try XLSXReader.read(data)
        #expect(wb.sheets[0].name == "Data")
        #expect(cell(wb, "A1") == "plain")
        #expect(cell(wb, "B1") == "rich text")
        #expect(wb.sheets[0].style(at: CellRef(a1: "B1")!).bold)
        #expect(cell(wb, "C1") == "inline")
        #expect(cell(wb, "B3") == "=A3*10")
        #expect(cell(wb, "B4") == "=A4*10")
        #expect(cell(wb, "A4") == "TRUE")
        #expect(wb.sheets[0].style(at: CellRef(a1: "C4")!).numberFormat == .date)
    }

    @Test func rejectsGarbage() {
        #expect(throws: FolioSheetsError.self) { try XLSXReader.read(bytes("not a zip")) }
    }

    @Test(arguments: [
        (0, NumberFormat.general), (2, .number), (7, .currency), (10, .percent), (14, .date), (22, .date),
    ])
    func classifiesBuiltInFormats(_ id: Int, _ expected: NumberFormat) {
        #expect(XLSXStyles.classify(id, [:]) == expected)
    }

    @Test(arguments: [
        ("0.00%", NumberFormat.percent), ("[$€-407]#,##0.00", .currency), ("d/m/yyyy", .date), ("#,##0.000", .number),
        ("[Red]0.00", .number), ("mmm", .date), ("General", .general),
    ])
    func classifiesCustomFormats(_ code: String, _ expected: NumberFormat) {
        #expect(XLSXStyles.classify(200, [200: code]) == expected)
    }
}

@Suite("ODS")
struct ODSTests {
    @Test(arguments: [
        ("of:=SUM([.A1:.B2])", "=SUM(A1:B2)"),
        ("of:=[.A1]+[Sheet2.B3]", "=A1+Sheet2!B3"),
        ("of:=IF([.A1]>0;\"a;b\";2)", "=IF(A1>0,\"a;b\",2)"),
        ("of:=['My Sheet'.$A$1]", "='My Sheet'!$A$1"),
        ("of:=SUM([$Data.A1:.A3])", "=SUM(Data!A1:A3)"),
    ])
    func convertsOpenFormula(_ odf: String, _ a1: String) {
        #expect(ODSCodec.fromOpenFormula(odf) == a1)
    }

    @Test func convertsBackToOpenFormula() {
        #expect(ODSCodec.toOpenFormula("=SUM(A1:B2,'My Sheet'!C3)") == "of:=SUM([.A1:.B2];[$'My Sheet'.C3])")
    }

    @Test func roundTripsValuesAndFormulas() throws {
        var wb = makeWorkbook(
            ["A1": "Label", "B1": "2.5", "C1": "TRUE", "A3": "=B1*2", "D5": "'0042"],
            sheets: ["Other": ["B2": "='Sheet 1'!B1+1"]]
        )
        wb.sheets[0].setInput("45292", at: CellRef(a1: "E1")!)
        wb.sheets[0].setStyle(CellStyle(numberFormat: .date), at: CellRef(a1: "E1")!)
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        let data = try ODSCodec.write(wb) { engine.value(sheetID: $0, cell: $1) }
        let back = try ODSCodec.read(data)
        #expect(back.sheets.map(\.name) == ["Sheet 1", "Other"])
        #expect(back.sheets[0].cells == wb.sheets[0].cells)
        #expect(back.sheets[1][CellRef(a1: "B2")!] == "='Sheet 1'!B1+1")
        #expect(back.sheets[0].style(at: CellRef(a1: "E1")!).numberFormat == .date)
    }

    @Test func expandsRepeatedRowsAndCells() throws {
        let content = """
            <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">\
            <office:body><office:spreadsheet><table:table table:name="T">\
            <table:table-row table:number-rows-repeated="2"><table:table-cell table:number-columns-repeated="3" office:value-type="float" office:value="7"><text:p>7</text:p></table:table-cell></table:table-row>\
            <table:table-row table:number-rows-repeated="1048000"><table:table-cell table:number-columns-repeated="1024"/></table:table-row>\
            <table:table-row><table:table-cell office:value-type="string"><text:p>Hello <text:span>big</text:span><text:s text:c="2"/>world</text:p><text:p>line 2</text:p></table:table-cell>\
            <table:table-cell office:value-type="percentage" office:value="0.25"><text:p>25%</text:p></table:table-cell></table:table-row>\
            </table:table></office:spreadsheet></office:body></office:document-content>
            """
        let data = try ZipPackage.write([
            ("mimetype", bytes("application/vnd.oasis.opendocument.spreadsheet"), true),
            ("content.xml", bytes(content), false),
        ])
        let wb = try ODSCodec.read(data)
        let s = wb.sheets[0]
        #expect(s.cells.count == 8)
        #expect(s[CellRef(a1: "C2")!] == "7")
        #expect(s[CellRef(row: 1_048_002, col: 0)] == "Hello big  world\nline 2")
        #expect(s.style(at: CellRef(row: 1_048_002, col: 1)).numberFormat == .percent)
    }
}

@Suite("Spreadsheet tools")
struct ToolTests {
    @Test func convertsCSVToXLSXAndBack() throws {
        let dir = try makeTempDir()
        let csv = try writeFile("a,b\n1,2\n", in: dir, named: "data.csv")
        let xlsx = try SpreadsheetTools.convertFile(csv, to: .xlsx)
        #expect(xlsx.lastPathComponent == "data.xlsx")
        let back = try SpreadsheetTools.convertFile(xlsx, to: .csv)
        #expect(back.lastPathComponent == "data 2.csv")  // never overwrites the input
        #expect(try readText(back) == "a,b\r\n1,2\r\n")
    }

    @Test func mergesCSVsKeepingOneHeader() throws {
        let dir = try makeTempDir()
        let a = try writeFile("id,name\n1,Ann\n", in: dir, named: "a.csv")
        let b = try writeFile("id,name\n2,\"Bob, Jr\"\n", in: dir, named: "b.csv")
        let merged = try SpreadsheetTools.mergeCSVFiles([a, b])
        #expect(text(merged) == "id,name\r\n1,Ann\r\n2,\"Bob, Jr\"")
    }

    @Test func toolIDsFollowConvention() {
        #expect(SpreadsheetTools.all.map(\.id) == ["sheets.convert", "sheets.mergeCSV"])
    }
}

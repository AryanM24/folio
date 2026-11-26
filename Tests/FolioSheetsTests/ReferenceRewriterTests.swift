import Testing

@testable import FolioSheets

@Suite("Reference rewriting")
struct ReferenceRewriterTests {
    @Test(
        arguments: [
            ("=A1+B2", 1, 0, "=A2+B3"),
            ("=A1+B2", 0, 2, "=C1+D2"),
            ("=$A$1+A1", 3, 3, "=$A$1+D4"),
            ("=A$1+$A1", 2, 2, "=C$1+$A3"),
            ("=SUM(A1:A3)", 1, 0, "=SUM(A2:A4)"),
            ("=SUM( A1 , B1 )", 1, 0, "=SUM( A2 , B2 )"),  // spacing survives
            ("=A1", -1, 0, "=#REF!"),
            ("=Data!A1*2", 0, 1, "=Data!B1*2"),
            ("=\"A1\"&A1", 1, 0, "=\"A1\"&A2"),  // strings untouched
            ("plain text", 1, 1, "plain text"),
            ("=SUM(A:A)", 5, 1, "=SUM(B:B)"),
        ] as [(String, Int, Int, String)])
    func offsets(_ formula: String, _ dr: Int, _ dc: Int, _ expected: String) {
        #expect(ReferenceRewriter.offset(formula, rows: dr, cols: dc) == expected)
    }

    @Test(
        arguments: [
            ("=A1+A5", 2, 1, "=A1+A6"),  // insert one row before row 3
            ("=SUM(A1:A5)", 2, 2, "=SUM(A1:A7)"),  // range grows
            ("=SUM(A3:A5)", 0, 1, "=SUM(A4:A6)"),
            ("=$A$9", 0, 1, "=$A$10"),  // absolute refs still follow their data
        ] as [(String, Int, Int, String)])
    func insertRows(_ formula: String, _ at: Int, _ count: Int, _ expected: String) {
        #expect(
            ReferenceRewriter.insert(formula, axis: .rows, at: at, count: count, sheetName: "Sheet 1", formulaSheet: "Sheet 1") == expected)
    }

    @Test(
        arguments: [
            ("=A1+A5", 2, 1, "=A1+A4"),
            ("=A3", 2, 1, "=#REF!"),
            ("=SUM(A1:A5)", 1, 2, "=SUM(A1:A3)"),  // range shrinks
            ("=SUM(A2:A3)", 1, 2, "=SUM(#REF!)"),
            ("=SUM(A3:A6)", 1, 3, "=SUM(A2:A3)"),  // start inside the deleted span
        ] as [(String, Int, Int, String)])
    func deleteRows(_ formula: String, _ at: Int, _ count: Int, _ expected: String) {
        #expect(
            ReferenceRewriter.delete(formula, axis: .rows, at: at, count: count, sheetName: "Sheet 1", formulaSheet: "Sheet 1") == expected)
    }

    @Test func insertAndDeleteColumns() {
        #expect(
            ReferenceRewriter.insert("=B1+SUM(A:C)", axis: .columns, at: 1, count: 1, sheetName: "S", formulaSheet: "S") == "=C1+SUM(A:D)")
        #expect(ReferenceRewriter.delete("=C1+A1", axis: .columns, at: 1, count: 1, sheetName: "S", formulaSheet: "S") == "=B1+A1")
        #expect(ReferenceRewriter.delete("=B1", axis: .columns, at: 1, count: 1, sheetName: "S", formulaSheet: "S") == "=#REF!")
    }

    @Test func onlyReferencesToTheEditedSheetMove() {
        let f = "=A5+Other!A5"
        #expect(ReferenceRewriter.insert(f, axis: .rows, at: 0, count: 1, sheetName: "Main", formulaSheet: "Main") == "=A6+Other!A5")
        #expect(ReferenceRewriter.insert(f, axis: .rows, at: 0, count: 1, sheetName: "other", formulaSheet: "Main") == "=A5+Other!A6")
    }

    @Test func renameSheet() {
        #expect(ReferenceRewriter.renameSheet("=Data!A1+data!B2+A1", from: "Data", to: "My Data") == "='My Data'!A1+'My Data'!B2+A1")
        #expect(ReferenceRewriter.renameSheet("='Old One'!A1", from: "old one", to: "New") == "=New!A1")
    }

    @Test func deleteSheet() {
        #expect(ReferenceRewriter.deleteSheet("=Gone!A1+A1", named: "Gone") == "=#REF!+A1")
    }

    @Test func sheetNamesThatLookLikeReferencesAreQuoted() {
        #expect(Reference.quoteSheetName("A1") == "'A1'")
        #expect(Reference.quoteSheetName("2024") == "'2024'")
        #expect(Reference.quoteSheetName("Sales") == "Sales")
    }
}

@Suite("Cell references")
struct CellRefTests {
    @Test(arguments: [(0, "A"), (25, "Z"), (26, "AA"), (51, "AZ"), (52, "BA"), (701, "ZZ"), (702, "AAA"), (16383, "XFD")])
    func columnNames(_ index: Int, _ name: String) {
        #expect(CellRef.columnName(index) == name)
        #expect(CellRef.columnIndex(name) == index)
    }

    @Test func parsesA1() {
        #expect(CellRef(a1: "B7") == CellRef(row: 6, col: 1))
        #expect(CellRef(a1: "$c$3") == CellRef(row: 2, col: 2))
        #expect(CellRef(a1: "A0") == nil)
        #expect(CellRef(a1: "7B") == nil)
        #expect(CellRange(a1: "C3:A1") == CellRange(CellRef(row: 0, col: 0), CellRef(row: 2, col: 2)))
        #expect(CellRange(a1: "A1:B2")?.cellCount == 4)
    }

    @Test func rangeIntersection() {
        let a = CellRange(a1: "A1:C3")!, b = CellRange(a1: "B2:D4")!
        #expect(a.intersection(b) == CellRange(a1: "B2:C3"))
        #expect(a.intersection(CellRange(a1: "E5")!) == nil)
    }
}

@Suite("Values and formatting")
struct ValueTests {
    @Test(arguments: [
        ("12", CellValue.number(12)), ("-3.5", .number(-3.5)), ("1,234.5", .number(1234.5)),
        ("12%", .number(0.12)), ("$9.99", .number(9.99)), ("(5)", .number(-5)), ("1e3", .number(1000)),
        ("TRUE", .bool(true)), ("false", .bool(false)), ("hello", .text("hello")), ("'42", .text("42")),
        ("12,34", .text("12,34")), ("0x1A", .text("0x1A")), ("nan", .text("nan")), ("#N/A", .error(.na)),
    ])
    func literals(_ input: String, _ expected: CellValue) {
        #expect(CellValue.literal(input) == expected)
    }

    @Test func generalFormat() {
        #expect(ValueFormatter.general(3) == "3")
        #expect(ValueFormatter.general(0.1 + 0.2) == "0.3")
        #expect(ValueFormatter.general(1.0 / 3) == "0.3333333333")
        #expect(ValueFormatter.general(1e12) == "1.00000E+12")
    }

    @Test func numberFormats() {
        let f = enUSFormatter
        #expect(f.string(for: 1234.5, format: .number) == "1,234.50")
        #expect(f.string(for: 1234.5, format: .currency) == "$1,234.50")
        #expect(f.string(for: 0.125, format: .percent) == "12.5%")
        #expect(f.string(for: 45292, format: .date) == "Jan 1, 2024")
        #expect(f.string(for: .error(.div0), format: .number) == "#DIV/0!")
    }

    @Test func plainNumberText() {
        #expect(CellValue.plainNumberText(2) == "2")
        #expect(CellValue.plainNumberText(2.5) == "2.5")
        #expect(CellValue.plainNumberText(0.1 + 0.2) == "0.3")
    }

    @Test func dateSerialRoundTrip() {
        for serial in [1.0, 59, 61, 25569, 45292, 60000] {
            let c = DateSerial.components(serial)!
            #expect(DateSerial.serial(year: c.year, month: c.month, day: c.day) == serial)
        }
        #expect(DateSerial.parseISO("2024-01-01") == 45292)
        #expect(DateSerial.parseISO("2024-13-01") == nil)
    }
}

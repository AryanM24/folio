import Testing

@testable import FolioSheets

/// One row per formula: what it evaluates to against `fixture`.
nonisolated struct FormulaCase: Sendable, CustomTestStringConvertible {
    let formula: String
    let expected: CellValue
    init(_ formula: String, _ expected: CellValue) {
        self.formula = formula
        self.expected = expected
    }
    var testDescription: String { formula }
}

private nonisolated func n(_ x: Double) -> CellValue { .number(x) }
private nonisolated func t(_ s: String) -> CellValue { .text(s) }
private nonisolated func b(_ x: Bool) -> CellValue { .bool(x) }
private nonisolated func e(_ x: FormulaError) -> CellValue { .error(x) }

@Suite("Operators")
struct OperatorTests {
    nonisolated static let cases: [FormulaCase] = [
        .init("=1+2", n(3)),
        .init("=10-4", n(6)),
        .init("=6*7", n(42)),
        .init("=7/2", n(3.5)),
        .init("=2^10", n(1024)),
        .init("=2+3*4", n(14)),
        .init("=(2+3)*4", n(20)),
        .init("=-2^2", n(4)),  // Excel: negation binds tighter than ^
        .init("=2^3^2", n(64)),  // left-associative
        .init("=-A1", n(-1)),
        .init("=--A2", n(2)),
        .init("=50%", n(0.5)),
        .init("=A5%", n(0.05)),
        .init("=\"a\"&\"b\"", t("ab")),
        .init("=A1&B1", t("1apple")),
        .init("=1&2", t("12")),
        .init("=1=1", b(true)),
        .init("=1<>1", b(false)),
        .init("=2>1", b(true)),
        .init("=2<1", b(false)),
        .init("=2>=2", b(true)),
        .init("=1<=0", b(false)),
        .init("=\"abc\"=\"ABC\"", b(true)),  // case-insensitive
        .init("=\"a\"<\"b\"", b(true)),
        .init("=1<\"a\"", b(true)),  // numbers sort before text
        .init("=TRUE>\"z\"", b(true)),  // booleans after text
        .init("=1/0", e(.div0)),
        .init("=A1/Z99", e(.div0)),  // empty cell is zero
        .init("=\"x\"+1", e(.value)),
        .init("=\"3\"+1", n(4)),  // numeric text coerces
        .init("=TRUE+1", n(2)),
        .init("=Z99+1", n(1)),
        .init("=Z99", n(0)),
        .init("=1+", e(.syntax)),
        .init("=(1+2", e(.syntax)),
        .init("=\"unterminated", e(.syntax)),
        .init("=foo", e(.name)),
        .init("=NOSUCHFN(1)", e(.name)),
        .init("=#N/A", e(.na)),
        .init("=#REF!+1", e(.ref)),
        .init("=0^-1", e(.div0)),
        .init("=1e3", n(1000)),
        .init("=.5*2", n(1)),
        .init("= 1 + 2 ", n(3)),
        .init("=SUM(A1:A3*2)", n(12)),  // element-wise arrays
        .init("=SUM(A1:A3*D1:D3)", n(140)),
    ]

    @Test(arguments: cases)
    func evaluates(_ c: FormulaCase) {
        #expect(evaluate(c.formula) == c.expected)
    }
}

@Suite("References")
struct ReferenceTests {
    nonisolated static let cases: [FormulaCase] = [
        .init("=A1", n(1)),
        .init("=$A$2", n(2)),
        .init("=a3", n(3)),  // lower case
        .init("=A$4+$A5", n(9)),
        .init("=SUM(A1:A5)", n(15)),
        .init("=SUM(A5:A1)", n(15)),  // reversed range
        .init("=SUM(A:A)", n(15)),  // whole column
        .init("=SUM(D:D)", n(60)),
        .init("='My Sheet'!A1", n(100)),
        .init("='My Sheet'!A2", n(200)),  // formula on another sheet
        .init("=Data!B2*2", n(14)),
        .init("=data!B2", n(7)),  // sheet names are case-insensitive
        .init("=SUM('My Sheet'!A1:A2)", n(300)),
        .init("=Nope!A1", e(.ref)),
        .init("=B5", t("00123")),  // apostrophe keeps text
        .init("=LEN(B5)", n(5)),
    ]

    @Test(arguments: cases)
    func evaluates(_ c: FormulaCase) {
        #expect(evaluate(c.formula) == c.expected)
    }
}

@Suite("Math and logic functions")
struct MathFunctionTests {
    nonisolated static let cases: [FormulaCase] = [
        .init("=SUM(1,2,3)", n(6)),
        .init("=SUM(A1:A5,10)", n(25)),
        .init("=SUM(B1:B3)", n(0)),  // text in ranges is ignored
        .init("=SUM(\"3\",TRUE)", n(4)),  // typed args are coerced
        .init("=SUM()", n(0)),
        .init("=SUM(A1,#N/A)", e(.na)),
        .init("=AVERAGE(A1:A5)", n(3)),
        .init("=AVERAGE(B1:B3)", e(.div0)),
        .init("=MIN(A1:A5)", n(1)),
        .init("=MAX(A1:A5,D1:D3)", n(30)),
        .init("=MIN(B1:B2)", n(0)),
        .init("=COUNT(A1:B5)", n(5)),
        .init("=COUNT(1,\"2\",\"x\")", n(2)),
        .init("=COUNTA(A1:B5)", n(10)),
        .init("=COUNTA(Z1:Z9)", n(0)),
        .init("=ROUND(2.675,2)", n(2.68)),
        .init("=ROUND(-2.5,0)", n(-3)),
        .init("=ROUND(1234,-2)", n(1200)),
        .init("=ROUNDUP(1.21,1)", n(1.3)),
        .init("=ROUNDUP(-1.21,1)", n(-1.3)),
        .init("=ROUNDUP(2,0)", n(2)),
        .init("=ROUNDDOWN(1.29,1)", n(1.2)),
        .init("=ROUNDDOWN(-1.29,1)", n(-1.2)),
        .init("=ABS(-4)", n(4)),
        .init("=SQRT(16)", n(4)),
        .init("=SQRT(-1)", e(.num)),
        .init("=POWER(2,8)", n(256)),
        .init("=MOD(10,3)", n(1)),
        .init("=MOD(-10,3)", n(2)),  // sign of divisor
        .init("=MOD(10,-3)", n(-2)),
        .init("=MOD(1,0)", e(.div0)),
        .init("=INT(3.7)", n(3)),
        .init("=INT(-3.2)", n(-4)),
        .init("=IF(A1>0,\"pos\",\"neg\")", t("pos")),
        .init("=IF(A1<0,\"pos\",\"neg\")", t("neg")),
        .init("=IF(FALSE,1)", b(false)),
        .init("=IF(TRUE,,2)", n(0)),
        .init("=IF(\"x\",1,2)", e(.value)),
        .init("=IFS(A1>2,\"a\",A1>0,\"b\")", t("b")),
        .init("=IFS(A1>5,\"a\")", e(.na)),
        .init("=IFERROR(1/0,\"oops\")", t("oops")),
        .init("=IFERROR(5,\"oops\")", n(5)),
        .init("=AND(TRUE,1)", b(true)),
        .init("=AND(TRUE,0)", b(false)),
        .init("=AND(C1:C2)", b(false)),
        .init("=OR(FALSE,0)", b(false)),
        .init("=OR(C1:C2)", b(true)),
        .init("=NOT(TRUE)", b(false)),
        .init("=NOT(0)", b(true)),
        .init("=AND()", e(.value)),
    ]

    @Test(arguments: cases)
    func evaluates(_ c: FormulaCase) {
        #expect(evaluate(c.formula) == c.expected)
    }
}

@Suite("Text functions")
struct TextFunctionTests {
    nonisolated static let cases: [FormulaCase] = [
        .init("=CONCAT(\"a\",1,TRUE)", t("a1TRUE")),
        .init("=CONCAT(A1:A3)", t("123")),
        .init("=CONCATENATE(B1,\"-\",B2)", t("apple-Banana")),
        .init("=TEXTJOIN(\", \",TRUE,B1:B3)", t("apple, Banana, cherry")),
        .init("=TEXTJOIN(\"-\",TRUE,A1,Z1,A2)", t("1-2")),
        .init("=TEXTJOIN(\"-\",FALSE,A1,Z1,A2)", t("1--2")),
        .init("=LEN(\"hello\")", n(5)),
        .init("=LEN(1234)", n(4)),
        .init("=LEFT(\"hello\",2)", t("he")),
        .init("=LEFT(\"hello\")", t("h")),
        .init("=LEFT(\"hi\",10)", t("hi")),
        .init("=RIGHT(\"hello\",3)", t("llo")),
        .init("=MID(\"hello\",2,3)", t("ell")),
        .init("=MID(\"hello\",10,3)", t("")),
        .init("=MID(\"hello\",0,3)", e(.value)),
        .init("=UPPER(B1)", t("APPLE")),
        .init("=LOWER(B2)", t("banana")),
        .init("=TRIM(B4)", t("spaced out")),
        .init("=SUBSTITUTE(\"a-b-c\",\"-\",\"+\")", t("a+b+c")),
        .init("=SUBSTITUTE(\"a-b-c\",\"-\",\"+\",2)", t("a-b+c")),
        .init("=SUBSTITUTE(\"abc\",\"x\",\"y\")", t("abc")),
        .init("=LEFT(1/0,1)", e(.div0)),
    ]

    @Test(arguments: cases)
    func evaluates(_ c: FormulaCase) {
        #expect(evaluate(c.formula) == c.expected)
    }
}

@Suite("Date functions")
struct DateFunctionTests {
    nonisolated static let cases: [FormulaCase] = [
        .init("=DATE(2024,1,1)", n(45292)),
        .init("=DATE(1900,1,1)", n(1)),
        .init("=DATE(1900,3,1)", n(61)),  // after the phantom 1900-02-29
        .init("=DATE(2024,13,1)", n(45658)),  // month overflow → 2025-01-01
        .init("=DATE(2024,3,0)", n(45351)),  // day 0 → last day of February
        .init("=YEAR(45292)", n(2024)),
        .init("=MONTH(45292)", n(1)),
        .init("=DAY(DATE(2024,2,29))", n(29)),
        .init("=YEAR(\"2023-07-04\")", n(2023)),
        .init("=DAY(60)", n(29)),  // Excel's fictional 1900-02-29
        .init("=TODAY()", n(45366)),  // 2024-03-15 from the fixed clock
        .init("=YEAR(TODAY())", n(2024)),
        .init("=NOW()>TODAY()", b(true)),
        .init("=YEAR(-1)", e(.num)),
        .init("=TODAY(1)", e(.value)),
    ]

    @Test(arguments: cases)
    func evaluates(_ c: FormulaCase) {
        // TODAY/NOW use the local time zone; compare whole days only.
        #expect(evaluate(c.formula) == c.expected)
    }
}

@Suite("Conditional aggregates")
struct ConditionalFunctionTests {
    nonisolated static let cases: [FormulaCase] = [
        .init("=SUMIF(A1:A5,\">2\")", n(12)),
        .init("=SUMIF(A1:A5,3)", n(3)),
        .init("=SUMIF(A1:A5,\"<>3\")", n(12)),
        .init("=SUMIF(E1:E3,\"x\",D1:D3)", n(40)),
        .init("=SUMIF(B1:B3,\"*an*\",A1:A3)", n(2)),
        .init("=SUMIF(B1:B3,\"?pple\",A1:A3)", n(1)),
        .init("=SUMIF(A:A,\">=4\")", n(9)),
        .init("=SUMIFS(D1:D3,E1:E3,\"x\",A1:A3,\">1\")", n(30)),
        .init("=SUMIFS(D1:D3,E1:E3,\"x\")", n(40)),
        .init("=SUMIFS(D1:D3,E1:E2,\"x\")", e(.value)),  // mismatched sizes
        .init("=COUNTIF(E1:E3,\"x\")", n(2)),
        .init("=COUNTIF(A1:A5,\">=3\")", n(3)),
        .init("=COUNTIF(Z1:Z3,\"\")", n(3)),
        .init("=COUNTIF(A1:A5,\"<>\")", n(5)),
        .init("=COUNTIF(B1:B3,\"BANANA\")", n(1)),
        .init("=COUNTIFS(E1:E3,\"x\",D1:D3,\">15\")", n(1)),
        .init("=AVERAGEIF(E1:E3,\"x\",D1:D3)", n(20)),
        .init("=AVERAGEIF(A1:A5,\">10\")", e(.div0)),
        .init("=COUNTIF(C1:C2,TRUE)", n(1)),
    ]

    @Test(arguments: cases)
    func evaluates(_ c: FormulaCase) {
        #expect(evaluate(c.formula) == c.expected)
    }
}

@Suite("Lookup functions")
struct LookupFunctionTests {
    nonisolated static let cases: [FormulaCase] = [
        .init("=VLOOKUP(\"Bob\",F2:G4,2,FALSE)", n(75)),
        .init("=VLOOKUP(\"bob\",F2:G4,2,FALSE)", n(75)),
        .init("=VLOOKUP(\"Zed\",F2:G4,2,FALSE)", e(.na)),
        .init("=VLOOKUP(\"B*\",F2:G4,2,FALSE)", n(75)),
        .init("=VLOOKUP(3.5,A1:D5,1)", n(3)),  // approximate match
        .init("=VLOOKUP(0,A1:A5,1)", e(.na)),
        .init("=VLOOKUP(\"Bob\",F2:G4,3,FALSE)", e(.ref)),
        .init("=VLOOKUP(\"Bob\",F2:G4,0,FALSE)", e(.value)),
        .init("=HLOOKUP(\"Score\",F1:G4,3,FALSE)", n(75)),
        .init("=HLOOKUP(\"Nope\",F1:G4,2,FALSE)", e(.na)),
        .init("=INDEX(F2:G4,2,2)", n(75)),
        .init("=INDEX(A1:A5,4)", n(4)),
        .init("=INDEX(F2:G4,9,1)", e(.ref)),
        .init("=SUM(INDEX(F2:G4,0,2))", n(247)),
        .init("=MATCH(\"Cy\",F2:F4,0)", n(3)),
        .init("=MATCH(3.5,A1:A5,1)", n(3)),
        .init("=MATCH(\"q\",F2:F4,0)", e(.na)),
        .init("=INDEX(G2:G4,MATCH(\"Ann\",F2:F4,0))", n(90)),
        .init("=XLOOKUP(\"Cy\",F2:F4,G2:G4)", n(82)),
        .init("=XLOOKUP(\"Zed\",F2:F4,G2:G4)", e(.na)),
        .init("=XLOOKUP(\"Zed\",F2:F4,G2:G4,\"none\")", t("none")),
        .init("=XLOOKUP(3.5,A1:A5,D1:D5,,-1)", n(30)),
        .init("=XLOOKUP(3.5,A1:A5,A1:A5,,1)", n(4)),
        .init("=XLOOKUP(\"x\",E1:E3,D1:D3,,0,-1)", n(30)),  // search last to first
        .init("=XLOOKUP(\"C*\",F2:F4,G2:G4,,2)", n(82)),
        .init("=XLOOKUP(\"Score\",F1:G1,F3:G3)", n(75)),  // horizontal
    ]

    @Test(arguments: cases)
    func evaluates(_ c: FormulaCase) {
        #expect(evaluate(c.formula) == c.expected)
    }
}

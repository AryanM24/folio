import Testing

@testable import FolioSheets

/// Coarse performance guards. Bounds are generous for debug builds on CI; the numbers
/// quoted in docs/editors/spreadsheets.md come from release builds.
@Suite("Performance")
struct PerformanceTests {
    /// 100,000 rows × 20 columns: the "open a big CSV" budget.
    static func bigCSV(rows: Int = 100_000, cols: Int = 20) -> String {
        var s = (0..<cols).map { "col\($0)" }.joined(separator: ",") + "\n"
        s.reserveCapacity(rows * cols * 5)
        for r in 0..<rows {
            for c in 0..<cols {
                if c > 0 { s += "," }
                s += c % 4 == 0 ? "item \(r)" : String((r * 31 + c * 7) % 1000)
            }
            s += "\n"
        }
        return s
    }

    @Test func opensHundredThousandRowCSV() throws {
        let data = bytes(Self.bigCSV())
        let clock = ContinuousClock()
        var cells = 0
        let elapsed = try clock.measure {
            let doc = try SpreadsheetDocument(data: data, format: .csv)
            cells = MainActor.assumeIsolated { doc.workbook.sheets[0].cells.count }
        }
        print("PERF open 100k-row CSV (2M cells): \(elapsed)")
        #expect(cells == 2_000_020)
        #expect(elapsed < .seconds(30))
    }

    @Test func xlsxRoundTripOfFiftyThousandRows() throws {
        let wb = CSVCodec.read(bytes(Self.bigCSV(rows: 50_000, cols: 10)))
        let clock = ContinuousClock()
        var back = Workbook()
        let elapsed = try clock.measure {
            back = try XLSXReader.read(try XLSXWriter.write(wb) { _, _ in nil })
        }
        print("PERF XLSX write+read 50k rows (500k cells): \(elapsed)")
        #expect(back.sheets[0].cells.count == wb.sheets[0].cells.count)
    }

    @Test func recalculatesTenThousandFormulasQuickly() {
        var wb = Workbook()
        for r in 0..<10_000 {
            wb.sheets[0].setInput(String(r), at: CellRef(row: r, col: 0))
            wb.sheets[0].setInput("=A\(r + 1)*2+SUM($A$1:$A$10)", at: CellRef(row: r, col: 1))
        }
        let engine = FormulaEngine()
        let clock = ContinuousClock()
        let elapsed = clock.measure { engine.recalculateAll(wb) }
        print("PERF recalc 10k formulas: \(elapsed)")
        #expect(engine.value(sheetID: 0, cell: CellRef(row: 9_999, col: 1)) == .number(19_998 + 45))
    }
}

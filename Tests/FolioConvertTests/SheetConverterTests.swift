import AppKit  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import FolioSheets
import Testing

@testable import FolioConvert

@Suite("Sheet conversions", .timeLimit(.minutes(1)))
struct SheetConverterTests {
    func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }
    func read(_ path: String?) throws -> String { try String(contentsOf: URL(fileURLWithPath: try #require(path)), encoding: .utf8) }

    @Test("CSV → xlsx → CSV keeps every value")
    func csvRoundTrip() async throws {
        let folder = try scratchFolder()
        let csv = "name,qty,price,note\r\nApple,3,1.25,\"red, crisp\"\r\nPear,10,0.5,\r\nFig,-2,1e3,\"say \"\"hi\"\"\""
        let input = folder.appending(path: "fruit.csv")
        try write(csv, to: input)
        let xlsx = await convert(input, to: .xlsx, quality: .lossless, into: folder)
        #expect(xlsx.status == .ok, "\(String(describing: xlsx.error))")
        #expect(xlsx.fidelity == .lossless)
        #expect(xlsx.verification?.passed == true)

        let out = folder.appending(path: "out")
        let back = await convert(URL(fileURLWithPath: try #require(xlsx.output)), to: .csv, into: out)
        #expect(back.status == .ok)
        #expect(back.verification?.passed == true)
        // 1e3 is a number, so it comes back as Excel stores it; empty trailing cells aren't written.
        #expect(
            try read(back.output) == csv.replacingOccurrences(of: "1e3", with: "1000").replacingOccurrences(of: "0.5,", with: "0.5")
                + "\r\n")
    }

    @Test("A two-sheet workbook becomes a folder of CSV files")
    func multiSheetToFolder() async throws {
        let folder = try scratchFolder()
        var wb = Workbook(sheets: [Sheet(id: 0, name: "Sales"), Sheet(id: 1, name: "Costs/2026")])
        wb.sheets[0].setInput("Total", at: CellRef(row: 0, col: 0))
        wb.sheets[0].setInput("=2*21", at: CellRef(row: 0, col: 1))
        wb.sheets[1].setInput("Rent", at: CellRef(row: 0, col: 0))
        wb.sheets[1].setInput("900", at: CellRef(row: 0, col: 1))
        let input = folder.appending(path: "book.xlsx")
        try XLSXWriter.write(wb, formulaValue: { _, _ in nil }).write(to: input)

        let result = await convert(input, to: .csv, into: folder)
        #expect(result.status == .ok, "\(String(describing: result.error))")
        #expect(result.verification?.passed == true)
        #expect(result.dropped == ["formulas"])
        let dir = URL(fileURLWithPath: try #require(result.output))
        #expect(dir.lastPathComponent == "book")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["Costs-2026.csv", "Sales.csv"])
        #expect(try String(contentsOf: dir.appending(path: "Sales.csv"), encoding: .utf8) == "Total,42\r\n")
    }

    @Test("JSON → xlsx → JSON round trip")
    func jsonRoundTrip() async throws {
        let folder = try scratchFolder()
        let json = """
            [
              {"id": 1, "name": "Ada", "zip": "00123", "active": true, "score": 9.5},
              {"id": 2, "name": "=not a formula", "zip": null, "active": false, "score": -1}
            ]
            """
        let input = folder.appending(path: "people.json")
        try write(json, to: input)
        let xlsx = await convert(input, to: .xlsx, quality: .lossless, into: folder)
        #expect(xlsx.status == .ok, "\(String(describing: xlsx.error))")
        #expect(xlsx.verification?.passed == true)

        let out = folder.appending(path: "out")
        let back = await convert(URL(fileURLWithPath: try #require(xlsx.output)), to: .json, into: out)
        #expect(back.status == .ok, "\(String(describing: back.error))")
        #expect(back.verification?.passed == true)
        let text = try read(back.output)
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        #expect(rows.count == 2)
        #expect(rows[0]["zip"] as? String == "00123")
        #expect(rows[0]["active"] as? Bool == true)
        #expect(rows[0]["score"] as? Double == 9.5)
        #expect(rows[1]["name"] as? String == "=not a formula")
        #expect(rows[1]["zip"] is NSNull)
        // Keys stay in the file's column order.
        #expect(text.range(of: "\"id\"")!.lowerBound < text.range(of: "\"score\"")!.lowerBound)
    }

    @Test("Formulas are evaluated for value-only formats")
    func formulasEvaluated() async throws {
        let folder = try scratchFolder()
        let input = folder.appending(path: "calc.csv")
        try write("a,b,sum\n2,3,=A2+B2\n4,5,=SUM(A3:B3)\n", to: input)
        let tsv = await convert(input, to: .tsv, into: folder)
        #expect(tsv.status == .ok)
        #expect(try read(tsv.output) == "a\tb\tsum\r\n2\t3\t5\r\n4\t5\t9\r\n")
        let json = await convert(input, to: .json, into: folder)
        #expect(json.status == .ok)
        #expect(try read(json.output).contains("\"sum\": 9"))
        // Workbook formats keep the formula itself.
        let xlsx = await convert(input, to: .xlsx, into: folder)
        #expect(xlsx.status == .ok)
        let info = await Engine.inspect(URL(fileURLWithPath: try #require(xlsx.output)))
        #expect(info.meta["has_formulas"] == .bool(true))
        #expect(info.meta["sheets"] == .array([.object(["name": "Sheet 1", "rows": 3, "cols": 3])]))
    }

    @Test("Extract gives a Markdown table and TSV text")
    func extractTable() async throws {
        let folder = try scratchFolder()
        let input = folder.appending(path: "t.csv")
        try write("city,pop\nOslo,700000\n\"A|B\",=1+1\n", to: input)
        let markdown = try await Engine.extract(input, as: .markdown)
        #expect(markdown == "| city | pop |\n| --- | --- |\n| Oslo | 700000 |\n| A\\|B | 2 |\n")
        let text = try await Engine.extract(input, as: .text)
        #expect(text == "city\tpop\nOslo\t700000\nA|B\t2")
    }

    @Test("Bad JSON fails with CORRUPT_INPUT")
    func badJSON() async throws {
        let folder = try scratchFolder()
        let input = folder.appending(path: "bad.json")
        try write("{\"not\": \"an array\"}", to: input)
        #expect(await convert(input, to: .csv, into: folder).error?.code == .corruptInput)
    }
}

import Foundation

@testable import FolioSheets

/// Builds a workbook from A1-style cell inputs. Extra sheets are given by name.
nonisolated func makeWorkbook(_ cells: [String: String], sheets extra: [String: [String: String]] = [:]) -> Workbook {
    var wb = Workbook()
    for (a1, input) in cells {
        wb.sheets[0].setInput(input, at: CellRef(a1: a1)!)
    }
    for (name, cells) in extra.sorted(by: { $0.key < $1.key }) {
        let i = wb.addSheet(named: name)
        for (a1, input) in cells { wb.sheets[i].setInput(input, at: CellRef(a1: a1)!) }
    }
    return wb
}

/// A fixed clock: 2024-03-15 12:00 UTC.
nonisolated let fixedNow = Date(timeIntervalSince1970: 1_710_504_000)

/// Recalculates and returns the value of `cell` on the first sheet.
nonisolated func value(_ cell: String, in wb: Workbook) -> CellValue {
    let engine = FormulaEngine(clock: { fixedNow })
    engine.recalculateAll(wb)
    let ref = CellRef(a1: cell)!
    return engine.value(sheetID: wb.sheets[0].id, cell: ref) ?? CellValue.literal(wb.sheets[0][ref])
}

/// Standard fixture used by the function table tests.
nonisolated let fixture: [String: String] = [
    "A1": "1", "A2": "2", "A3": "3", "A4": "4", "A5": "5",
    "B1": "apple", "B2": "Banana", "B3": "cherry", "B4": "  spaced   out  ", "B5": "'00123",
    "C1": "TRUE", "C2": "FALSE",
    "D1": "10", "D2": "20", "D3": "30",
    "E1": "x", "E2": "y", "E3": "x",
    "F1": "Name", "G1": "Score",
    "F2": "Ann", "G2": "90",
    "F3": "Bob", "G3": "75",
    "F4": "Cy", "G4": "82",
]

nonisolated let fixtureSheets: [String: [String: String]] = [
    "My Sheet": ["A1": "100", "A2": "=A1*2"],
    "Data": ["B2": "7"],
]

/// Evaluates a one-off formula against the fixture workbook.
nonisolated func evaluate(_ formula: String) -> CellValue {
    let wb = makeWorkbook(fixture, sheets: fixtureSheets)
    let engine = FormulaEngine(clock: { fixedNow })
    engine.recalculateAll(wb)
    return engine.evaluate(formula: formula, in: wb)
}

// MARK: - Foundation helpers
//
// The Command Line Tools ship Swift Testing without its Foundation cross-import
// overlay, so a file can't import both `Testing` and `Foundation`. Test files use
// these helpers instead of naming Foundation types directly.

nonisolated func bytes(_ s: String) -> Data { Data(s.utf8) }
nonisolated func rawBytes(_ b: [UInt8]) -> Data { Data(b) }
nonisolated func utf16(_ s: String, bigEndian: Bool, bom: Bool) -> Data {
    let body = s.data(using: bigEndian ? .utf16BigEndian : .utf16LittleEndian) ?? Data()
    guard bom else { return body }
    return Data(bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]) + body
}
nonisolated func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

nonisolated func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "folio-sheets-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
nonisolated func writeFile(_ s: String, in dir: URL, named name: String) throws -> URL {
    let url = dir.appending(path: name)
    try Data(s.utf8).write(to: url)
    return url
}
nonisolated func readText(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

nonisolated let enUSFormatter = ValueFormatter(locale: Locale(identifier: "en_US"))

@MainActor func newUndoManager() -> UndoManager {
    let u = UndoManager()
    u.groupsByEvent = false
    return u
}

nonisolated let csvType = SpreadsheetFormat.csv.type

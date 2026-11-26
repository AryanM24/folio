import FolioKit
public import Foundation
public import UniformTypeIdentifiers

/// The file formats the spreadsheet editor reads and writes.
public nonisolated enum SpreadsheetFormat: String, Sendable, CaseIterable {
    case csv, tsv, xlsx, ods

    public init?(type: UTType) {
        if type.conforms(to: .xlsx) {
            self = .xlsx
        } else if type.conforms(to: .ods) {
            self = .ods
        } else if type.conforms(to: .tabSeparatedText) {
            self = .tsv
        } else if type.conforms(to: .commaSeparatedText) {
            self = .csv
        } else {
            return nil
        }
    }

    public init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "csv": self = .csv
        case "tsv", "tab": self = .tsv
        case "xlsx", "xlsm": self = .xlsx
        case "ods": self = .ods
        default: return nil
        }
    }

    public var type: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .tsv: .tabSeparatedText
        case .xlsx: .xlsx
        case .ods: .ods
        }
    }

    public var fileExtension: String { rawValue }

    /// CSV and TSV hold one sheet of text: no styles or extra sheets. Formulas are kept as typed.
    public var isPlainText: Bool { self == .csv || self == .tsv }

    public func read(_ data: Data) throws -> Workbook {
        switch self {
        case .csv: CSVCodec.read(data)
        case .tsv: CSVCodec.read(data, delimiter: UInt8(ascii: "\t"))
        case .xlsx: try XLSXReader.read(data)
        case .ods: try ODSCodec.read(data)
        }
    }

    /// Encodes a workbook. `values` supplies computed formula values (sheet id, cell).
    public func write(_ wb: Workbook, values: [CellKey: CellValue]) throws -> Data {
        let lookup: (Int, CellRef) -> CellValue? = { values[CellKey(sheetID: $0, cell: $1)] }
        switch self {
        case .xlsx: return try XLSXWriter.write(wb, formulaValue: lookup)
        case .ods: return try ODSCodec.write(wb, formulaValue: lookup)
        case .csv, .tsv:
            let sheet = wb.activeSheet
            return CSVCodec.write(
                sheet,
                values: { ref in
                    SpreadsheetFormat.plainValue(sheet: sheet, ref: ref, lookup: lookup)
                }, delimiter: self == .tsv ? "\t" : ",")
        }
    }

    /// What CSV stores for a cell: exactly what was typed, formulas included.
    ///
    /// Autosave rewrites the file without asking, so it must never change what the file
    /// says. A CSV that contained `=C2*D2` keeps `=C2*D2` (Excel, Numbers and Google
    /// Sheets all evaluate it on open), and "00123" or "1,234" survive exactly as typed.
    /// A leading apostrophe only marks text in the grid, so it isn't written.
    static func plainValue(sheet: Sheet, ref: CellRef, lookup: (Int, CellRef) -> CellValue?) -> String {
        let input = sheet[ref]
        return input.hasPrefix("'") ? String(input.dropFirst()) : input
    }

    /// Whether saving `wb` as this format would drop something, and what.
    public func losses(in wb: Workbook) -> String? {
        guard isPlainText else { return nil }
        var lost: [String] = []
        if wb.sheets.count > 1 { lost.append("only the current sheet is saved") }
        if wb.sheets.contains(where: { !$0.styles.isEmpty }) { lost.append("formatting isn't kept") }
        guard !lost.isEmpty else { return nil }
        let joined = lost.joined(separator: ", ")
        return "\(rawValue.uppercased()) holds plain values: " + joined + ". Save a copy as Excel (.xlsx) to keep everything."
    }
}

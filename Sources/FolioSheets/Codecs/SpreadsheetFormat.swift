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

    /// CSV and TSV hold one sheet of values: no formulas, styles or extra sheets.
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

    /// What CSV stores for a cell: the computed value for formulas, the raw input otherwise
    /// (so "00123" and "1,234" survive a round trip exactly as typed).
    static func plainValue(sheet: Sheet, ref: CellRef, lookup: (Int, CellRef) -> CellValue?) -> String {
        let input = sheet[ref]
        guard input.hasPrefix("=") else { return input.hasPrefix("'") ? String(input.dropFirst()) : input }
        switch lookup(sheet.id, ref) ?? .empty {
        case .number(let n): return CellValue.plainNumberText(n)
        case let other: return (try? other.asText().get()) ?? other.errorValue?.rawValue ?? ""
        }
    }

    /// Whether saving `wb` as this format would drop something, and what.
    public func losses(in wb: Workbook) -> String? {
        guard isPlainText else { return nil }
        var lost: [String] = []
        if wb.sheets.count > 1 { lost.append("only the current sheet is saved") }
        if wb.sheets.contains(where: { !$0.styles.isEmpty }) { lost.append("formatting isn't kept") }
        if wb.sheets.contains(where: { $0.cells.values.contains { $0.hasPrefix("=") } }) {
            lost.append("formulas are saved as their results")
        }
        guard !lost.isEmpty else { return nil }
        let joined = lost.joined(separator: ", ")
        return "\(rawValue.uppercased()) holds plain values: " + joined + ". Save a copy as Excel (.xlsx) to keep everything."
    }
}

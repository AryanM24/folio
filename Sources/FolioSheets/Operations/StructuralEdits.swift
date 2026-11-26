public import Foundation

/// Workbook-wide edits that move cells: inserting/deleting rows and columns, and
/// renaming or deleting sheets. Each returns a new workbook with every formula in every
/// sheet rewritten so references keep pointing at the same data.
public nonisolated enum StructuralEdits {
    public static func insert(_ axis: ReferenceRewriter.Axis, at index: Int, count: Int = 1, sheet: Int, in wb: Workbook) -> Workbook {
        var wb = wb
        let name = wb.sheets[sheet].name
        wb.sheets[sheet] = shifted(wb.sheets[sheet], axis: axis) { i in i >= index ? i + count : i }
        if axis == .columns {
            wb.sheets[sheet].columnWidths = remap(wb.sheets[sheet].columnWidths) { $0 >= index ? $0 + count : $0 }
        }
        rewriteFormulas(&wb) { formula, formulaSheet in
            ReferenceRewriter.insert(formula, axis: axis, at: index, count: count, sheetName: name, formulaSheet: formulaSheet)
        }
        return wb
    }

    public static func delete(_ axis: ReferenceRewriter.Axis, at index: Int, count: Int = 1, sheet: Int, in wb: Workbook) -> Workbook {
        var wb = wb
        let name = wb.sheets[sheet].name
        let last = index + count - 1
        let map: (Int) -> Int? = { i in i < index ? i : (i <= last ? nil : i - count) }
        // Rewrite first so the moved formulas below are already adjusted.
        rewriteFormulas(&wb) { formula, formulaSheet in
            ReferenceRewriter.delete(formula, axis: axis, at: index, count: count, sheetName: name, formulaSheet: formulaSheet)
        }
        wb.sheets[sheet] = shifted(wb.sheets[sheet], axis: axis, map)
        if axis == .columns {
            wb.sheets[sheet].columnWidths = remap(wb.sheets[sheet].columnWidths, map)
        }
        return wb
    }

    public static func renameSheet(_ index: Int, to newName: String, in wb: Workbook) throws(FolioSheetsError) -> Workbook {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw .invalidSheetName("A sheet name can't be empty.") }
        guard !trimmed.contains(where: { "[]:*?/\\".contains($0) }) else {
            throw .invalidSheetName("Sheet names can't contain [ ] : * ? / or \\.")
        }
        if let existing = wb.index(ofSheetNamed: trimmed), existing != index {
            throw .invalidSheetName("There's already a sheet called “\(trimmed)”.")
        }
        var wb = wb
        let old = wb.sheets[index].name
        wb.sheets[index].name = trimmed
        rewriteFormulas(&wb) { formula, _ in ReferenceRewriter.renameSheet(formula, from: old, to: trimmed) }
        return wb
    }

    public static func deleteSheet(_ index: Int, in wb: Workbook) -> Workbook {
        guard wb.sheets.count > 1 else { return wb }
        var wb = wb
        let name = wb.sheets.remove(at: index).name
        rewriteFormulas(&wb) { formula, _ in ReferenceRewriter.deleteSheet(formula, named: name) }
        wb.activeSheetIndex = min(wb.activeSheetIndex, wb.sheets.count - 1)
        return wb
    }

    public static func moveSheet(from: Int, to: Int, in wb: Workbook) -> Workbook {
        guard from != to, wb.sheets.indices.contains(from), wb.sheets.indices.contains(to) else { return wb }
        var wb = wb
        let activeID = wb.activeSheet.id
        let s = wb.sheets.remove(at: from)
        wb.sheets.insert(s, at: to)
        wb.activeSheetIndex = wb.index(ofSheetID: activeID) ?? 0
        return wb
    }

    // MARK: - Helpers

    /// Moves cells and styles along an axis; `map` returning `nil` drops the cell.
    static func shifted(_ sheet: Sheet, axis: ReferenceRewriter.Axis, _ map: (Int) -> Int?) -> Sheet {
        func move(_ ref: CellRef) -> CellRef? {
            switch axis {
            case .rows: map(ref.row).map { CellRef(row: $0, col: ref.col) }
            case .columns: map(ref.col).map { CellRef(row: ref.row, col: $0) }
            }
        }
        var cells: [CellRef: String] = [:]
        cells.reserveCapacity(sheet.cells.count)
        for (ref, v) in sheet.cells { if let n = move(ref) { cells[n] = v } }
        var styles: [CellRef: CellStyle] = [:]
        for (ref, v) in sheet.styles { if let n = move(ref) { styles[n] = v } }
        var out = sheet
        out.replaceAll(cells: cells, styles: styles)
        return out
    }

    private static func remap(_ widths: [Int: Double], _ map: (Int) -> Int?) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for (k, v) in widths { if let n = map(k) { out[n] = v } }
        return out
    }

    /// Rewrites every formula in the workbook. `transform` gets the formula and the
    /// name of the sheet that holds it.
    static func rewriteFormulas(_ wb: inout Workbook, _ transform: (String, String) -> String) {
        for i in wb.sheets.indices {
            let sheetName = wb.sheets[i].name
            let changes = wb.sheets[i].cells.compactMap { ref, input -> (CellRef, String)? in
                guard input.utf8.first == UInt8(ascii: "=") else { return nil }
                let new = transform(input, sheetName)
                return new == input ? nil : (ref, new)
            }
            for (ref, new) in changes { wb.sheets[i].setInput(new, at: ref) }
        }
    }
}

/// Errors the spreadsheet module reports to people.
public nonisolated enum FolioSheetsError: LocalizedError, Sendable, Equatable {
    case invalidSheetName(String)
    case unreadableFile(String)
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .invalidSheetName(let m): m
        case .unreadableFile(let m): m
        case .unsupportedFormat: "Folio can't open this kind of spreadsheet."
        }
    }
}

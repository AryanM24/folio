import Foundation

/// One sheet: sparse cells, their styles, column widths and frozen panes.
///
/// A value type so `snapshot(contentType:)` is a cheap copy-on-write copy, and undo
/// can hold whole sheets for structural edits. Cells hold the *raw input* the user
/// typed ("=SUM(A1:A3)", "12", "Hello"); computed values live in `FormulaEngine`.
public nonisolated struct Sheet: Sendable, Equatable {
    /// Stable for the workbook's lifetime, so caches survive renames and reordering.
    public var id: Int
    public var name: String
    public private(set) var cells: [CellRef: String] = [:]
    public private(set) var styles: [CellRef: CellStyle] = [:]
    /// Points. Missing columns use `Sheet.defaultColumnWidth`.
    public var columnWidths: [Int: Double] = [:]
    public var frozenRows = 0
    public var frozenCols = 0
    /// Upper bound of used rows/columns (−1 when empty). Grows on writes; exact after
    /// `recomputeExtent()`. Kept as a bound so clearing a cell stays O(1).
    public private(set) var maxRow = -1
    public private(set) var maxCol = -1

    public static let defaultColumnWidth: Double = 100

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    public subscript(_ ref: CellRef) -> String { cells[ref] ?? "" }

    public func style(at ref: CellRef) -> CellStyle { styles[ref] ?? .plain }

    public func width(ofColumn col: Int) -> Double { columnWidths[col] ?? Sheet.defaultColumnWidth }

    /// Set raw input; empty clears the cell (its style stays, like every spreadsheet).
    public mutating func setInput(_ input: String, at ref: CellRef) {
        if input.isEmpty {
            cells[ref] = nil
        } else {
            cells[ref] = input
            grow(to: ref)
        }
    }

    public mutating func setStyle(_ style: CellStyle, at ref: CellRef) {
        if style.isPlain {
            styles[ref] = nil
        } else {
            styles[ref] = style
            grow(to: ref)
        }
    }

    /// Bulk load from a codec without per-cell extent bookkeeping.
    public mutating func replaceAll(cells: [CellRef: String], styles: [CellRef: CellStyle]) {
        self.cells = cells
        self.styles = styles
        recomputeExtent()
    }

    public mutating func reserveCapacity(_ n: Int) { cells.reserveCapacity(n) }

    public mutating func recomputeExtent() {
        var r = -1, c = -1
        for ref in cells.keys { r = max(r, ref.row); c = max(c, ref.col) }
        for ref in styles.keys { r = max(r, ref.row); c = max(c, ref.col) }
        maxRow = r
        maxCol = c
    }

    /// Smallest rectangle holding every non-empty cell, `nil` for an empty sheet.
    public var usedRange: CellRange? {
        guard maxRow >= 0, maxCol >= 0 else { return nil }
        return CellRange(CellRef(row: 0, col: 0), CellRef(row: maxRow, col: maxCol))
    }

    private mutating func grow(to ref: CellRef) {
        if ref.row > maxRow { maxRow = ref.row }
        if ref.col > maxCol { maxCol = ref.col }
    }
}

/// An ordered list of sheets plus which one is showing.
public nonisolated struct Workbook: Sendable, Equatable {
    public var sheets: [Sheet]
    public var activeSheetIndex = 0
    private var nextID: Int

    public init(sheets: [Sheet] = []) {
        self.sheets = sheets.isEmpty ? [Sheet(id: 0, name: "Sheet 1")] : sheets
        nextID = (self.sheets.map(\.id).max() ?? 0) + 1
    }

    /// Builds a workbook from (name, sheet-builder) pairs and assigns ids. Used by codecs.
    public init(named: [(String, (inout Sheet) -> Void)]) {
        var sheets: [Sheet] = []
        for (i, (name, build)) in named.enumerated() {
            var s = Sheet(id: i, name: name)
            build(&s)
            sheets.append(s)
        }
        self.init(sheets: sheets)
    }

    public var activeSheet: Sheet {
        get { sheets[clampedActive] }
        set { sheets[clampedActive] = newValue }
    }

    private var clampedActive: Int { min(max(0, activeSheetIndex), sheets.count - 1) }

    /// Case-insensitive, as in every spreadsheet app.
    public func index(ofSheetNamed name: String) -> Int? {
        sheets.firstIndex { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    public func index(ofSheetID id: Int) -> Int? { sheets.firstIndex { $0.id == id } }

    @discardableResult
    public mutating func addSheet(named name: String? = nil, at position: Int? = nil) -> Int {
        let sheet = Sheet(id: nextID, name: name ?? uniqueSheetName())
        nextID += 1
        let at = min(position ?? sheets.count, sheets.count)
        sheets.insert(sheet, at: at)
        return at
    }

    /// "Sheet N" for the smallest N not already taken.
    public func uniqueSheetName(base: String = "Sheet") -> String {
        var n = sheets.count + 1
        while index(ofSheetNamed: "\(base) \(n)") != nil { n += 1 }
        return "\(base) \(n)"
    }
}

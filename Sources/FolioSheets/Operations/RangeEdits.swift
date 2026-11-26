import Foundation

/// A cell's input and style together: the unit of copy, paste, fill, sort and undo.
public nonisolated struct CellContent: Hashable, Sendable, Codable {
    public var input: String
    public var style: CellStyle

    public init(input: String = "", style: CellStyle = .plain) {
        self.input = input
        self.style = style
    }

    public static let empty = CellContent()
}

/// A rectangle of copied cells, remembering where it came from so pasted formulas
/// can have their relative references adjusted.
public nonisolated struct CellBlock: Hashable, Sendable, Codable {
    public var origin: CellRef
    public var rows: Int
    public var cols: Int
    /// Row-major, `rows * cols` entries.
    public var contents: [CellContent]

    public init(origin: CellRef, rows: Int, cols: Int, contents: [CellContent]) {
        self.origin = origin
        self.rows = rows
        self.cols = cols
        self.contents = contents
    }

    public init(sheet: Sheet, range: CellRange) {
        origin = range.start
        rows = range.rowCount
        cols = range.colCount
        contents = range.cells.map { CellContent(input: sheet[$0], style: sheet.style(at: $0)) }
    }

    public subscript(r: Int, c: Int) -> CellContent { contents[r * cols + c] }
}

/// Edits confined to a range. Each returns the cells to change, so the document can
/// apply them through one undoable step.
public nonisolated enum RangeEdits {
    public typealias Changes = [CellRef: CellContent]

    public enum FillDirection: Sendable { case down, right }

    /// ⌘D / ⌘R: copy the first row (or column) of the range across the rest,
    /// adjusting relative references as it goes.
    public static func fill(_ range: CellRange, _ direction: FillDirection, in sheet: Sheet) -> Changes {
        var out: Changes = [:]
        switch direction {
        case .down:
            guard range.rowCount > 1 else { return out }
            for c in range.cols {
                let src = CellRef(row: range.start.row, col: c)
                for r in (range.start.row + 1)...range.end.row {
                    out[CellRef(row: r, col: c)] = moved(sheet, from: src, rows: r - src.row, cols: 0)
                }
            }
        case .right:
            guard range.colCount > 1 else { return out }
            for r in range.rows {
                let src = CellRef(row: r, col: range.start.col)
                for c in (range.start.col + 1)...range.end.col {
                    out[CellRef(row: r, col: c)] = moved(sheet, from: src, rows: 0, cols: c - src.col)
                }
            }
        }
        return out
    }

    /// Pastes a block with its top-left at `target`. A single copied cell fills the
    /// whole `fillRange` when one is given (paste one value into a selection).
    public static func paste(_ block: CellBlock, at target: CellRef, fillRange: CellRange? = nil) -> Changes {
        var out: Changes = [:]
        let tileRows = fillRange.map { max(block.rows, $0.rowCount - ($0.rowCount % block.rows)) } ?? block.rows
        let tileCols = fillRange.map { max(block.cols, $0.colCount - ($0.colCount % block.cols)) } ?? block.cols
        for r in 0..<tileRows {
            for c in 0..<tileCols {
                let src = block[r % block.rows, c % block.cols]
                let dest = target.offset(rows: r, cols: c)
                let dr = dest.row - (block.origin.row + r % block.rows)
                let dc = dest.col - (block.origin.col + c % block.cols)
                out[dest] = CellContent(input: ReferenceRewriter.offset(src.input, rows: dr, cols: dc), style: src.style)
            }
        }
        return out
    }

    /// Clears inputs (keeping styles) for every non-empty cell in `range`.
    public static func clear(_ range: CellRange, in sheet: Sheet, styles: Bool = false) -> Changes {
        var out: Changes = [:]
        for ref in cells(in: range, of: sheet) {
            out[ref] = CellContent(input: "", style: styles ? .plain : sheet.style(at: ref))
        }
        return out
    }

    /// Sorts the rows of `range` by the values in column `key`. Empty keys sort last
    /// in both directions, like Numbers and Excel. Formulas move with their rows.
    public static func sort(
        _ range: CellRange, byColumn key: Int, ascending: Bool, in sheet: Sheet, value: (CellRef) -> CellValue
    ) -> Changes {
        let rows = Array(range.rows)
        let keyed = rows.map { ($0, value(CellRef(row: $0, col: key))) }
        let sorted = keyed.enumerated().sorted { a, b in
            let (x, y) = (a.element.1, b.element.1)
            if x.isEmpty != y.isEmpty { return !x.isEmpty }
            let c = Operators.compare(x, y)
            if c == 0 { return a.offset < b.offset }  // stable
            return ascending ? c < 0 : c > 0
        }.map(\.element.0)
        var out: Changes = [:]
        for (i, srcRow) in sorted.enumerated() where srcRow != rows[i] {
            for c in range.cols {
                out[CellRef(row: rows[i], col: c)] = moved(sheet, from: CellRef(row: srcRow, col: c), rows: rows[i] - srcRow, cols: 0)
            }
        }
        return out
    }

    /// Cells whose input contains `query`, row by row.
    public static func find(_ query: String, in sheet: Sheet, matchCase: Bool = false) -> [CellRef] {
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = matchCase ? [] : [.caseInsensitive]
        return sheet.cells.compactMap { ref, input in input.range(of: query, options: options) != nil ? ref : nil }.sorted()
    }

    /// Replaces `query` in every matching cell (or just `only`).
    public static func replace(
        _ query: String, with replacement: String, in sheet: Sheet, matchCase: Bool = false, only: [CellRef]? = nil
    ) -> Changes {
        let options: String.CompareOptions = matchCase ? [] : [.caseInsensitive]
        var out: Changes = [:]
        for ref in only ?? find(query, in: sheet, matchCase: matchCase) {
            let input = sheet[ref]
            let new = input.replacingOccurrences(of: query, with: replacement, options: options)
            if new != input { out[ref] = CellContent(input: new, style: sheet.style(at: ref)) }
        }
        return out
    }

    /// Non-empty (input or styled) cells inside `range`, without walking empty space.
    public static func cells(in range: CellRange, of sheet: Sheet) -> [CellRef] {
        var out = Set<CellRef>()
        if range.cellCount <= sheet.cells.count + sheet.styles.count {
            for r in range.rows {
                for c in range.cols {
                    let ref = CellRef(row: r, col: c)
                    if sheet.cells[ref] != nil || sheet.styles[ref] != nil { out.insert(ref) }
                }
            }
        } else {
            for ref in sheet.cells.keys where range.contains(ref) { out.insert(ref) }
            for ref in sheet.styles.keys where range.contains(ref) { out.insert(ref) }
        }
        return out.sorted()
    }

    /// Calls `body` for each cell with input inside `range`, in no particular order,
    /// choosing whichever is smaller to walk: the range or the sheet's cells.
    public static func forEachFilledCell(in range: CellRange, of sheet: Sheet, _ body: (CellRef) -> Void) {
        if range.cellCount <= sheet.cells.count {
            for r in range.rows {
                for c in range.cols where sheet.cells[CellRef(row: r, col: c)] != nil { body(CellRef(row: r, col: c)) }
            }
        } else {
            for ref in sheet.cells.keys where range.contains(ref) { body(ref) }
        }
    }

    private static func moved(_ sheet: Sheet, from src: CellRef, rows: Int, cols: Int) -> CellContent {
        CellContent(input: ReferenceRewriter.offset(sheet[src], rows: rows, cols: cols), style: sheet.style(at: src))
    }
}

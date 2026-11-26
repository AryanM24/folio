import Foundation

/// A cell position: zero-based row and column. `CellRef(row: 0, col: 0)` is A1.
///
/// Zero-based because every array and loop in the editor is; A1 notation is only
/// produced at the edges (formula text, the name box, file formats).
public nonisolated struct CellRef: Hashable, Sendable, Comparable, Codable {
    public var row: Int
    public var col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    /// Row-major order, which is the order people read a sheet in.
    public static func < (a: CellRef, b: CellRef) -> Bool {
        a.row != b.row ? a.row < b.row : a.col < b.col
    }

    /// "A1"-style name.
    public var a1: String { CellRef.columnName(col) + String(row + 1) }

    public func offset(rows: Int = 0, cols: Int = 0) -> CellRef {
        CellRef(row: row + rows, col: col + cols)
    }

    /// Spreadsheet column letters: 0 → "A", 25 → "Z", 26 → "AA".
    public static func columnName(_ index: Int) -> String {
        var n = index + 1
        var scalars: [Character] = []
        while n > 0 {
            let r = (n - 1) % 26
            scalars.append(Character(UnicodeScalar(UInt8(65 + r))))
            n = (n - 1) / 26
        }
        return String(scalars.reversed())
    }

    /// Inverse of `columnName`. Case-insensitive; `nil` for anything that isn't letters.
    public static func columnIndex(_ letters: some StringProtocol) -> Int? {
        guard !letters.isEmpty, letters.count <= 4 else { return nil }
        var n = 0
        for u in letters.utf8 {
            let upper = u >= 97 ? u - 32 : u
            guard upper >= 65, upper <= 90 else { return nil }
            n = n * 26 + Int(upper - 64)
        }
        return n - 1
    }

    /// Parse "B7", "$B$7" (dollars ignored). `nil` for anything else.
    public init?(a1 text: some StringProtocol) {
        let s = text.replacingOccurrences(of: "$", with: "")
        guard let split = s.firstIndex(where: \.isNumber),
            let col = CellRef.columnIndex(s[s.startIndex..<split]),
            let row = Int(s[split...]), row >= 1
        else { return nil }
        self.init(row: row - 1, col: col)
    }
}

/// An inclusive rectangle of cells. Always normalised so `start` is top-left.
public nonisolated struct CellRange: Hashable, Sendable, Codable {
    public var start: CellRef
    public var end: CellRef

    public init(_ a: CellRef, _ b: CellRef) {
        start = CellRef(row: min(a.row, b.row), col: min(a.col, b.col))
        end = CellRef(row: max(a.row, b.row), col: max(a.col, b.col))
    }

    public init(_ cell: CellRef) { self.init(cell, cell) }

    public var rowCount: Int { end.row - start.row + 1 }
    public var colCount: Int { end.col - start.col + 1 }
    public var cellCount: Int { rowCount * colCount }
    public var isSingleCell: Bool { start == end }
    public var rows: ClosedRange<Int> { start.row...end.row }
    public var cols: ClosedRange<Int> { start.col...end.col }

    public func contains(_ cell: CellRef) -> Bool {
        cell.row >= start.row && cell.row <= end.row && cell.col >= start.col && cell.col <= end.col
    }

    public func intersection(_ other: CellRange) -> CellRange? {
        let r0 = max(start.row, other.start.row), r1 = min(end.row, other.end.row)
        let c0 = max(start.col, other.start.col), c1 = min(end.col, other.end.col)
        guard r0 <= r1, c0 <= c1 else { return nil }
        return CellRange(CellRef(row: r0, col: c0), CellRef(row: r1, col: c1))
    }

    /// "A1:B3", or "A1" for a single cell.
    public var a1: String { isSingleCell ? start.a1 : "\(start.a1):\(end.a1)" }

    /// Parse "A1:B3" or "A1".
    public init?(a1 text: String) {
        let parts = text.split(separator: ":")
        guard let first = parts.first, let a = CellRef(a1: first), parts.count <= 2 else { return nil }
        guard parts.count == 2 else { self.init(a); return }
        guard let b = CellRef(a1: parts[1]) else { return nil }
        self.init(a, b)
    }

    /// Every cell, row-major. Use only for ranges you know are small or bounded by data.
    public var cells: [CellRef] {
        var out: [CellRef] = []
        out.reserveCapacity(cellCount)
        for r in rows { for c in cols { out.append(CellRef(row: r, col: c)) } }
        return out
    }
}

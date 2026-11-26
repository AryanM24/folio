import AppKit
import FolioKit
import SwiftUI

/// Geometry of the grid in document-view coordinates (flipped: y grows downward).
///
/// Rows have one fixed height, so row lookups are O(1) arithmetic even at a million
/// rows. Columns can vary, so their left edges are a prefix-sum array and lookups are
/// a binary search.
struct GridLayout {
    static let rowHeight: CGFloat = 24
    static let columnHeaderHeight: CGFloat = 24
    static let rowHeaderMinWidth: CGFloat = 44

    let rows: Int
    let cols: Int
    let frozenRows: Int
    let frozenCols: Int
    /// Left edge of each column relative to the cell area, plus the total width at the end.
    private let colEdges: [CGFloat]
    let rowHeaderWidth: CGFloat

    /// - Parameter widthOverride: a column being resized live, drawn before the width is committed.
    init(sheet: Sheet, rows: Int, cols: Int, widthOverride: (col: Int, width: Double)? = nil) {
        self.rows = rows
        self.cols = cols
        frozenRows = min(sheet.frozenRows, rows)
        frozenCols = min(sheet.frozenCols, cols)
        var edges = [CGFloat](repeating: 0, count: cols + 1)
        for c in 0..<cols {
            let w = widthOverride?.col == c ? widthOverride?.width ?? 0 : sheet.width(ofColumn: c)
            edges[c + 1] = edges[c] + CGFloat(w)
        }
        colEdges = edges
        // Wide enough for the largest row number in 11 pt digits.
        let digits = CGFloat(String(rows).count)
        rowHeaderWidth = max(GridLayout.rowHeaderMinWidth, digits * 7.5 + 16)
    }

    var contentSize: CGSize {
        CGSize(width: rowHeaderWidth + colEdges[cols], height: GridLayout.columnHeaderHeight + CGFloat(rows) * GridLayout.rowHeight)
    }

    // MARK: Cells → rects

    func x(ofColumn c: Int) -> CGFloat { rowHeaderWidth + colEdges[min(max(0, c), cols)] }
    func width(ofColumn c: Int) -> CGFloat { c < cols ? colEdges[c + 1] - colEdges[c] : CGFloat(Sheet.defaultColumnWidth) }
    func y(ofRow r: Int) -> CGFloat { GridLayout.columnHeaderHeight + CGFloat(r) * GridLayout.rowHeight }

    func rect(of cell: CellRef) -> CGRect {
        CGRect(x: x(ofColumn: cell.col), y: y(ofRow: cell.row), width: width(ofColumn: cell.col), height: GridLayout.rowHeight)
    }

    func rect(of range: CellRange) -> CGRect {
        let a = rect(of: range.start), b = rect(of: range.end)
        return a.union(b)
    }

    /// Height of the frozen band below the column letters.
    var frozenHeight: CGFloat { CGFloat(frozenRows) * GridLayout.rowHeight }
    var frozenWidth: CGFloat { colEdges[frozenCols] }
    /// Total size of the sticky bands (headers plus frozen panes).
    var topBand: CGFloat { GridLayout.columnHeaderHeight + frozenHeight }
    var leftBand: CGFloat { rowHeaderWidth + frozenWidth }

    // MARK: Points → cells

    /// Column containing an x coordinate in the cell area (clamped).
    func column(atX x: CGFloat) -> Int {
        let local = x - rowHeaderWidth
        guard local > 0 else { return 0 }
        var lo = 0, hi = cols - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if colEdges[mid] <= local { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func row(atY y: CGFloat) -> Int {
        let r = Int(((y - GridLayout.columnHeaderHeight) / GridLayout.rowHeight).rounded(.down))
        return min(max(0, r), rows - 1)
    }

    /// The column whose right edge is within a few points of `x`, for resizing.
    func columnBorder(nearX x: CGFloat, tolerance: CGFloat = 4) -> Int? {
        let c = column(atX: x)
        for candidate in [c - 1, c] where candidate >= 0 && candidate < cols {
            if abs(self.x(ofColumn: candidate + 1) - x) <= tolerance { return candidate }
        }
        return nil
    }

    /// Visible rows/columns for a rect, never including frozen ones.
    func rows(in rect: CGRect) -> Range<Int> {
        let first = max(frozenRows, row(atY: rect.minY))
        let last = min(rows - 1, row(atY: rect.maxY))
        return first <= last ? first..<(last + 1) : first..<first
    }

    func cols(in rect: CGRect) -> Range<Int> {
        let first = max(frozenCols, column(atX: rect.minX))
        let last = min(cols - 1, column(atX: rect.maxX))
        return first <= last ? first..<(last + 1) : first..<first
    }
}

/// Grid colours, bridged once from Hero tokens. They are dynamic `NSColor`s, so they
/// resolve to light or dark values at draw time.
enum GridPalette {
    static let surface = NSColor(Hero.surface)
    static let header = NSColor(Hero.surface)
    static let headerSelected = NSColor(Hero.accentSoft)
    static let headerText = NSColor(Hero.muted)
    static let headerTextSelected = NSColor(Hero.accentSoftForeground)
    static let separator = NSColor(Hero.separator)
    static let border = NSColor(Hero.border)
    static let text = NSColor(Hero.foreground)
    static let muted = NSColor(Hero.muted)
    static let accent = NSColor(Hero.accent)
    static let danger = NSColor(Hero.danger)
    static let frozenShadow = NSColor(Hero.border)
}

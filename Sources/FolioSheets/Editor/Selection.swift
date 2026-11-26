import Foundation

/// The selected cells: an anchor where the selection started and a cursor that
/// moves with shift-arrows or dragging. The active cell (where typing goes) is the anchor,
/// as in Numbers and Excel.
struct Selection: Equatable {
    enum Kind: Equatable {
        case cells
        /// Whole rows or columns, from clicking the headers.
        case rows, columns
    }

    var anchor: CellRef
    var cursor: CellRef
    var kind: Kind = .cells

    init(_ cell: CellRef) {
        anchor = cell
        cursor = cell
    }

    var active: CellRef { anchor }

    /// The selected rectangle, with whole rows/columns spanning `bounds`.
    func range(bounds: CellRef) -> CellRange {
        switch kind {
        case .cells: CellRange(anchor, cursor)
        case .rows: CellRange(CellRef(row: anchor.row, col: 0), CellRef(row: cursor.row, col: bounds.col))
        case .columns: CellRange(CellRef(row: 0, col: anchor.col), CellRef(row: bounds.row, col: cursor.col))
        }
    }
}

/// What the chart panel shows. Charts are a view of the current data, not saved in the file.
struct ChartSpec: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case bar, line, area, pie
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .bar: "chart.bar"
            case .line: "chart.xyaxis.line"
            case .area: "chart.line.uptrend.xyaxis"
            case .pie: "chart.pie"
            }
        }
    }

    var range: CellRange
    var kind: Kind = .bar
}

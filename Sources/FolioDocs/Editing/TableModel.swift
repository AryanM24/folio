public import AppKit

/// A text table as a grid of cells, for inserting tables and adding or removing rows
/// and columns.
///
/// The Cocoa text system stores a table as consecutive paragraphs whose paragraph
/// style carries an `NSTextTableBlock` (row, column) of one shared `NSTextTable`.
/// Editing that in place is fiddly, so structural edits read the table into this
/// grid, change the grid, and render a fresh table that replaces the old range in a
/// single undoable edit.
///
/// Shortcut: merged cells (row/column spans) are read at their top-left position and
/// rendered unmerged; upgrade if Folio grows a "merge cells" command.
public nonisolated struct TableModel {
    /// `cells[row][column]` holds the cell's paragraphs, each ending in a newline.
    public private(set) var cells: [[NSAttributedString]]
    /// Block whose borders, padding and background new cells copy.
    private let template: NSTextTableBlock?
    private let sourceTable: NSTextTable?

    public var rowCount: Int { cells.count }
    public var columnCount: Int { cells.first?.count ?? 0 }

    /// A new, empty table.
    public init(rows: Int, columns: Int, attributes: [NSAttributedString.Key: Any]) {
        let empty = NSAttributedString(
            string: "\n", attributes: attributes.filter { $0.key != .paragraphStyle && $0.key != .attachment && $0.key != .link })
        cells = Array(repeating: Array(repeating: empty, count: max(1, columns)), count: max(1, rows))
        template = nil
        sourceTable = nil
    }

    /// Reads the table containing `location`. Returns the model and the character range
    /// the table occupies, or `nil` when `location` isn't in a table.
    public static func read(from text: NSAttributedString, at location: Int) -> (model: TableModel, range: NSRange)? {
        guard let range = tableRange(in: text, at: location), let table = table(in: text, at: range.location) else { return nil }
        let ns = text.string as NSString
        var grid: [[NSMutableAttributedString]] = []
        var template: NSTextTableBlock?
        for paragraph in ListFormatting.paragraphRanges(in: ns.substring(with: range) as NSString) {
            let absolute = NSRange(location: paragraph.location + range.location, length: paragraph.length)
            guard let block = cellBlock(in: text, at: absolute.location, of: table) else { continue }
            template = template ?? block
            while grid.count <= block.startingRow { grid.append([]) }
            while grid[block.startingRow].count <= block.startingColumn { grid[block.startingRow].append(NSMutableAttributedString()) }
            grid[block.startingRow][block.startingColumn].append(text.attributedSubstring(from: absolute))
        }
        let columns = max(table.numberOfColumns, grid.map(\.count).max() ?? 1)
        let filler = NSAttributedString(string: "\n", attributes: [.font: TextStyle.body.font])
        let cells: [[NSAttributedString]] = grid.map { row in
            (0..<columns).map { c in c < row.count && row[c].length > 0 ? row[c] : filler }
        }
        return (TableModel(cells: cells, template: template, sourceTable: table), range)
    }

    /// A table with the given cell contents (each cell's paragraphs end in "\n").
    init(cells: [[NSAttributedString]], template: NSTextTableBlock? = nil, sourceTable: NSTextTable? = nil) {
        self.cells = cells
        self.template = template
        self.sourceTable = sourceTable
    }

    /// Row and column of the cell containing `location`, if it is in this kind of table.
    public static func cell(in text: NSAttributedString, at location: Int) -> (row: Int, column: Int)? {
        guard location <= text.length, text.length > 0 else { return nil }
        let at = min(location, text.length - 1)
        guard let style = text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle,
            let block = style.textBlocks.last(where: { $0 is NSTextTableBlock }) as? NSTextTableBlock
        else { return nil }
        return (block.startingRow, block.startingColumn)
    }

    // MARK: Structure edits

    public mutating func insertRow(at index: Int) {
        let i = min(max(0, index), rowCount)
        let source = cells[min(i, rowCount - 1)]
        cells.insert(source.map(Self.emptyCell(like:)), at: i)
    }

    public mutating func deleteRow(at index: Int) {
        guard rowCount > 1, cells.indices.contains(index) else { return }
        cells.remove(at: index)
    }

    public mutating func insertColumn(at index: Int) {
        let i = min(max(0, index), columnCount)
        for r in cells.indices {
            cells[r].insert(Self.emptyCell(like: cells[r][min(i, cells[r].count - 1)]), at: i)
        }
    }

    public mutating func deleteColumn(at index: Int) {
        guard columnCount > 1, (0..<columnCount).contains(index) else { return }
        for r in cells.indices { cells[r].remove(at: index) }
    }

    /// Offset of a cell's first character in `render()`'s output, for placing the caret.
    public func offset(ofRow row: Int, column: Int) -> Int {
        var offset = 0
        for (r, cellsInRow) in cells.enumerated() {
            for (c, cell) in cellsInRow.enumerated() {
                if r == row, c == column { return offset }
                offset += cell.string.hasSuffix("\n") ? cell.length : cell.length + 1
            }
        }
        return offset
    }

    // MARK: Rendering

    /// The table as attributed text: one `NSTextTableBlock` per cell, light hairline
    /// borders, equal column widths across the text width.
    public func render() -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = sourceTable?.layoutAlgorithm ?? .automaticLayoutAlgorithm
        table.collapsesBorders = sourceTable?.collapsesBorders ?? true
        table.hidesEmptyCells = false
        let out = NSMutableAttributedString()
        for (r, row) in cells.enumerated() {
            for (c, content) in row.enumerated() {
                let block = makeBlock(table: table, row: r, column: c)
                let cell = NSMutableAttributedString(attributedString: content)
                if cell.length == 0 || !(cell.string.hasSuffix("\n")) {
                    cell.append(
                        NSAttributedString(
                            string: "\n", attributes: cell.length > 0 ? cell.attributes(at: cell.length - 1, effectiveRange: nil) : [:]))
                }
                for paragraph in ListFormatting.paragraphRanges(in: cell.string as NSString) where paragraph.length > 0 {
                    let base = cell.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
                    let style = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                    let outer = style.textBlocks.filter { !($0 is NSTextTableBlock) }
                    style.textBlocks = outer + [block]
                    style.headerLevel = 0
                    cell.addAttribute(.paragraphStyle, value: style, range: paragraph)
                }
                out.append(cell)
            }
        }
        return out
    }

    private func makeBlock(table: NSTextTable, row: Int, column: Int) -> NSTextTableBlock {
        let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        let border = template?.width(for: .border, edge: .minX) ?? 0.5
        let padding = template?.width(for: .padding, edge: .minX) ?? 6
        block.setWidth(border > 0 ? border : 0.5, type: .absoluteValueType, for: .border)
        block.setWidth(padding > 0 ? padding : 6, type: .absoluteValueType, for: .padding)
        block.setBorderColor(template?.borderColor(for: .minX) ?? NSColor(srgbRed: 0.75, green: 0.75, blue: 0.78, alpha: 1))
        block.backgroundColor = template?.backgroundColor
        block.verticalAlignment = template?.verticalAlignment ?? .topAlignment
        block.setValue(100 / CGFloat(max(1, columnCount)), type: .percentageValueType, for: .width)
        return block
    }

    // MARK: Lookup helpers

    private static func emptyCell(like cell: NSAttributedString) -> NSAttributedString {
        let attrs = cell.length > 0 ? cell.attributes(at: 0, effectiveRange: nil) : [:]
        return NSAttributedString(string: "\n", attributes: attrs.filter { $0.key != .attachment && $0.key != .link })
    }

    private static func table(in text: NSAttributedString, at location: Int) -> NSTextTable? {
        guard location < text.length,
            let style = text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
            let block = style.textBlocks.last(where: { $0 is NSTextTableBlock }) as? NSTextTableBlock
        else { return nil }
        return block.table
    }

    private static func cellBlock(in text: NSAttributedString, at location: Int, of table: NSTextTable) -> NSTextTableBlock? {
        guard location < text.length,
            let style = text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        else { return nil }
        return style.textBlocks.compactMap { $0 as? NSTextTableBlock }.first { $0.table === table }
    }

    /// The paragraphs, around `location`, that belong to the same table.
    static func tableRange(in text: NSAttributedString, at location: Int) -> NSRange? {
        guard text.length > 0 else { return nil }
        let at = min(location, text.length - 1)
        guard let table = table(in: text, at: at) else { return nil }
        let ns = text.string as NSString
        var range = ns.paragraphRange(for: NSRange(location: at, length: 0))
        while range.location > 0 {
            let previous = ns.paragraphRange(for: NSRange(location: range.location - 1, length: 0))
            guard cellBlock(in: text, at: previous.location, of: table) != nil else { break }
            range = NSUnionRange(range, previous)
        }
        while NSMaxRange(range) < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0))
            guard cellBlock(in: text, at: next.location, of: table) != nil else { break }
            range = NSUnionRange(range, next)
        }
        return range
    }
}

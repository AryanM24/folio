import AppKit
import Combine
import FolioKit
import Observation

/// Editor state for one spreadsheet window: selection, in-cell editing, find, the chart
/// panel, and every user action. Views and menus call into this; it turns actions into
/// undoable document edits.
@MainActor @Observable
final class SheetController {
    let document: SpreadsheetDocument
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored weak var grid: GridView?

    var selection = Selection(CellRef(row: 0, col: 0)) {
        didSet { if selection != oldValue { selectionChanged() } }
    }
    /// True while the in-cell field editor is open.
    private(set) var isEditing = false
    /// The formula bar's text: the active cell's input, or what's being typed.
    var formulaText = ""
    /// Bumped whenever the document changes so SwiftUI re-reads derived values.
    private(set) var revision = 0

    // Find & replace.
    var showFind = false
    var findText = ""
    var replaceText = ""
    var matchCase = false

    var chart: ChartSpec?
    /// The sheet being renamed inline in the tab bar.
    var renamingSheet: Int?

    @ObservationIgnored private var statsCache: (revision: Int, range: CellRange, stats: Stats?)?
    @ObservationIgnored private var subscription: AnyCancellable?
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored let log = Log.make("Sheets")

    init(document: SpreadsheetDocument) {
        self.document = document
        formulaText = document.activeSheet[selection.active]
        subscription = document.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires *before* the change; read the new state on the next turn.
            guard let self, !self.refreshScheduled else { return }
            self.refreshScheduled = true
            DispatchQueue.main.async { [weak self] in self?.documentChanged() }
        }
    }

    var sheet: Sheet { document.activeSheet }

    // MARK: - Extent

    /// Rows shown: the data plus room to grow, at least a screenful.
    var displayRows: Int { min(1_048_576, max(1_000, sheet.maxRow + 101, selection.cursor.row + 30, selection.anchor.row + 30)) }
    var displayCols: Int { min(16_384, max(26, sheet.maxCol + 6, selection.cursor.col + 4, selection.anchor.col + 4)) }
    /// Bottom-right corner for whole-row/column selections.
    var bounds: CellRef { CellRef(row: displayRows - 1, col: displayCols - 1) }
    var selectedRange: CellRange { selection.range(bounds: bounds) }

    /// The selection limited to cells that hold data or formatting, so formatting a whole
    /// column of a 100k-row sheet doesn't create 100k empty styled cells.
    var effectiveRange: CellRange {
        let r = selectedRange
        guard selection.kind != .cells || r.cellCount > 100_000 else { return r }
        let used = sheet.usedRange ?? CellRange(CellRef(row: 0, col: 0))
        return r.intersection(used) ?? CellRange(r.start)
    }

    // MARK: - Change propagation

    private func documentChanged() {
        refreshScheduled = false
        revision += 1
        if !isEditing { formulaText = sheet[selection.active] }
        grid?.reloadLayout()
    }

    private func selectionChanged() {
        if !isEditing { formulaText = sheet[selection.active] }
        grid?.selectionDidChange()
    }

    // MARK: - Navigation

    func select(_ cell: CellRef, extend: Bool = false) {
        let c = clamp(cell)
        if extend {
            selection.cursor = c
        } else {
            var s = Selection(c)
            s.kind = .cells
            selection = s
        }
    }

    func selectAll() {
        var s = Selection(CellRef(row: 0, col: 0))
        s.cursor = CellRef(row: max(sheet.maxRow, 0), col: max(sheet.maxCol, 0))
        s.kind = .cells
        selection = s
    }

    func selectRows(_ from: Int, _ to: Int) {
        var s = Selection(CellRef(row: from, col: 0))
        s.cursor = CellRef(row: to, col: 0)
        s.kind = .rows
        selection = s
    }

    func selectColumns(_ from: Int, _ to: Int) {
        var s = Selection(CellRef(row: 0, col: from))
        s.cursor = CellRef(row: 0, col: to)
        s.kind = .columns
        selection = s
    }

    /// Arrow keys. With `extend` the cursor moves and the anchor stays.
    func move(rows dr: Int, cols dc: Int, extend: Bool = false) {
        if extend {
            selection.cursor = clamp(selection.cursor.offset(rows: dr, cols: dc))
            if selection.kind != .cells { selection.kind = .cells }
        } else {
            select(selection.active.offset(rows: dr, cols: dc))
        }
    }

    /// ⌘-arrow: jump to the edge of the current block of data, or the next block.
    func moveToDataEdge(rows dr: Int, cols dc: Int, extend: Bool = false) {
        let from = extend ? selection.cursor : selection.active
        let target = dataEdge(from: from, dr: dr, dc: dc)
        extend ? (selection.cursor = target) : select(target)
    }

    func dataEdge(from start: CellRef, dr: Int, dc: Int) -> CellRef {
        let s = sheet
        let limitRow = dr > 0 ? max(s.maxRow, start.row) : 0
        let limitCol = dc > 0 ? max(s.maxCol, start.col) : 0
        func filled(_ c: CellRef) -> Bool { s.cells[c] != nil }
        func inBounds(_ c: CellRef) -> Bool {
            c.row >= 0 && c.col >= 0 && (dr <= 0 || c.row <= limitRow) && (dc <= 0 || c.col <= limitCol)
        }
        var cur = start
        let next = cur.offset(rows: dr, cols: dc)
        guard inBounds(next) else { return start }
        if filled(cur) && filled(next) {
            // Run to the last filled cell of this block.
            while true {
                let n = cur.offset(rows: dr, cols: dc)
                guard inBounds(n), filled(n) else { return cur }
                cur = n
            }
        }
        // Skip empties to the next filled cell, or stop at the edge.
        cur = next
        while !filled(cur) {
            let n = cur.offset(rows: dr, cols: dc)
            guard inBounds(n) else { return cur }
            cur = n
        }
        return cur
    }

    func page(_ direction: Int, extend: Bool = false) {
        let rows = max(1, (grid?.visibleRowCount ?? 20) - 1)
        move(rows: direction * rows, cols: 0, extend: extend)
    }

    private func clamp(_ c: CellRef) -> CellRef {
        CellRef(row: min(max(0, c.row), 1_048_575), col: min(max(0, c.col), 16_383))
    }

    /// Name box: jump to "B12", select "A1:C3", or switch to "Sheet 2!A1".
    @discardableResult
    func go(to text: String) -> Bool {
        var target = text.trimmingCharacters(in: .whitespaces)
        if let bang = target.lastIndex(of: "!") {
            var name = String(target[..<bang])
            if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            guard let idx = document.workbook.index(ofSheetNamed: name) else { return false }
            selectSheet(idx)
            target = String(target[target.index(after: bang)...])
        }
        guard let range = CellRange(a1: target.uppercased()) else { return false }
        var s = Selection(range.start)
        s.cursor = range.end
        selection = s
        grid?.focus()
        return true
    }

    // MARK: - Editing

    /// Opens the in-cell editor. `initial` replaces the content (type-to-edit); `nil`
    /// edits the existing input (Return, F2, double-click).
    func beginEditing(initial: String? = nil) {
        guard !isEditing else { return }
        isEditing = true
        formulaText = initial ?? sheet[selection.active]
        grid?.showEditor(text: formulaText, at: selection.active)
    }

    /// Ends editing, writes the text, then moves (Return → down, Tab → right).
    func commitEditing(_ text: String, move: (rows: Int, cols: Int) = (1, 0)) {
        guard isEditing else { return }
        isEditing = false
        grid?.hideEditor()
        setInput(text, at: selection.active)
        if move != (0, 0) { self.move(rows: move.rows, cols: move.cols) }
        formulaText = sheet[selection.active]
        grid?.focus()
    }

    func cancelEditing() {
        guard isEditing else { return }
        isEditing = false
        grid?.hideEditor()
        formulaText = sheet[selection.active]
        grid?.focus()
    }

    /// Called by the in-cell editor as the user types, to mirror into the formula bar.
    func editorTextChanged(_ text: String) { formulaText = text }

    /// Commits from the formula bar.
    func commitFormulaBar() {
        if isEditing {
            commitEditing(formulaText, move: (0, 0))
        } else {
            setInput(formulaText, at: selection.active)
            grid?.focus()
        }
    }

    /// Writes typed text into a cell, inferring a number format from what was typed
    /// ("12%" → percentage, "$4" → currency, "2024-03-15" → date) when the cell has none.
    func setInput(_ raw: String, at ref: CellRef) {
        var input = raw
        var style = sheet.style(at: ref)
        if !input.hasPrefix("="), !input.hasPrefix("'"), style.numberFormat == .general {
            let trimmed = input.trimmingCharacters(in: .whitespaces)
            if let serial = DateSerial.parseISO(trimmed) {
                input = CellValue.plainNumberText(serial)
                style.numberFormat = .date
            } else if CellValue.parseNumber(trimmed) != nil, Double(trimmed) == nil {
                if trimmed.hasSuffix("%") {
                    style.numberFormat = .percent
                } else if let f = trimmed.first, "$€£¥".contains(f) {
                    style.numberFormat = .currency
                }
            }
        }
        guard input != sheet[ref] || style != sheet.style(at: ref) else { return }
        document.apply([ref: CellContent(input: input, style: style)], actionName: "Typing", undoManager: undoManager)
    }

    // MARK: - Status bar

    struct Stats: Equatable {
        var sum: Double
        var count: Int
        var numbers: Int
        var average: Double? { numbers > 0 ? sum / Double(numbers) : nil }
    }

    /// Sum, average and count of the selection; `nil` for a single cell.
    var stats: Stats? {
        let range = effectiveRange
        if let cached = statsCache, cached.revision == revision, cached.range == range { return cached.stats }
        var result: Stats?
        if !range.isSingleCell || selection.kind != .cells {
            var sum = 0.0, count = 0, numbers = 0
            let s = sheet
            RangeEdits.forEachFilledCell(in: range, of: s) { ref in
                count += 1
                if case .number(let n) = document.value(at: ref) { sum += n; numbers += 1 }
            }
            result = Stats(sum: sum, count: count, numbers: numbers)
        }
        statsCache = (revision, range, result)
        return result
    }
}

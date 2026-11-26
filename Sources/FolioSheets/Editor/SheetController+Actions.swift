import AppKit
import FolioKit

/// Every command the toolbar, menus, context menus and keyboard can trigger.
/// Each one is a single undoable document edit.
extension SheetController {
    // MARK: - Formatting

    /// The style of the active cell, which toolbar toggles reflect.
    var activeStyle: CellStyle { sheet.style(at: selection.active) }

    /// Applies `change` to the style of every cell in the selection.
    func updateStyle(_ actionName: String, _ change: (inout CellStyle) -> Void) {
        let range = effectiveRange
        var changes: RangeEdits.Changes = [:]
        let s = sheet
        for ref in range.cells {
            var style = s.style(at: ref)
            change(&style)
            if style != s.style(at: ref) { changes[ref] = CellContent(input: s[ref], style: style) }
        }
        document.apply(changes, actionName: actionName, undoManager: undoManager)
    }

    /// Bold/italic/underline toggle: on for all unless the active cell already has it.
    func toggle(_ trait: WritableKeyPath<CellStyle, Bool>, name: String) {
        let on = !activeStyle[keyPath: trait]
        updateStyle(name) { $0[keyPath: trait] = on }
    }

    func toggleBold() { toggle(\.bold, name: "Bold") }
    func toggleItalic() { toggle(\.italic, name: "Italic") }
    func toggleUnderline() { toggle(\.underline, name: "Underline") }

    func setAlignment(_ a: HorizontalAlignment) {
        let target: HorizontalAlignment = activeStyle.alignment == a ? .automatic : a
        updateStyle("Alignment") { $0.alignment = target }
    }

    func setFill(_ color: RGBColor?) { updateStyle("Fill Color") { $0.fill = color } }
    func setTextColor(_ color: RGBColor?) { updateStyle("Text Color") { $0.textColor = color } }
    func setNumberFormat(_ f: NumberFormat) { updateStyle("Number Format") { $0.numberFormat = f } }

    func clearFormatting() {
        let s = sheet
        var changes: RangeEdits.Changes = [:]
        for ref in RangeEdits.cells(in: effectiveRange, of: s) where !s.style(at: ref).isPlain {
            changes[ref] = CellContent(input: s[ref], style: .plain)
        }
        document.apply(changes, actionName: "Clear Formatting", undoManager: undoManager)
    }

    // MARK: - Contents

    /// Delete key: clear values in the selection, keep formatting.
    func clearContents() {
        document.apply(RangeEdits.clear(effectiveRange, in: sheet), actionName: "Delete", undoManager: undoManager)
    }

    func fill(_ direction: RangeEdits.FillDirection) {
        let changes = RangeEdits.fill(effectiveRange, direction, in: sheet)
        document.apply(changes, actionName: direction == .down ? "Fill Down" : "Fill Right", undoManager: undoManager)
    }

    /// Sorts the selected rows by the active cell's column. A single selected cell
    /// sorts the whole used area, keeping a header row in place when the sheet has a
    /// frozen header.
    func sort(ascending: Bool) {
        var range = effectiveRange
        if range.isSingleCell, let used = sheet.usedRange {
            range = used
            if sheet.frozenRows > 0, range.rowCount > sheet.frozenRows {
                range = CellRange(range.start.offset(rows: sheet.frozenRows), range.end)
            }
        }
        let key = min(max(selection.active.col, range.start.col), range.end.col)
        let doc = document
        let changes = RangeEdits.sort(range, byColumn: key, ascending: ascending, in: sheet) { doc.value(at: $0) }
        document.apply(changes, actionName: ascending ? "Sort Ascending" : "Sort Descending", undoManager: undoManager)
    }

    // MARK: - Rows and columns

    /// Rows/columns a structural edit applies to; a column selection inserts one row.
    private var rowSpan: (start: Int, count: Int) {
        let r = selectedRange
        return selection.kind == .columns ? (selection.active.row, 1) : (r.start.row, r.rowCount)
    }

    private var colSpan: (start: Int, count: Int) {
        let r = selectedRange
        return selection.kind == .rows ? (selection.active.col, 1) : (r.start.col, r.colCount)
    }

    func insertRows(above: Bool) {
        let r = rowSpan
        let at = above ? r.start : r.start + r.count
        replaceWorkbook(
            StructuralEdits.insert(.rows, at: at, count: r.count, sheet: document.activeSheetIndex, in: document.workbook),
            name: r.count == 1 ? "Insert Row" : "Insert Rows")
        if !above { select(CellRef(row: at, col: selection.active.col)) }
    }

    func insertColumns(left: Bool) {
        let r = colSpan
        let at = left ? r.start : r.start + r.count
        replaceWorkbook(
            StructuralEdits.insert(.columns, at: at, count: r.count, sheet: document.activeSheetIndex, in: document.workbook),
            name: r.count == 1 ? "Insert Column" : "Insert Columns")
        if !left { select(CellRef(row: selection.active.row, col: at)) }
    }

    func deleteRows() {
        let r = rowSpan
        replaceWorkbook(
            StructuralEdits.delete(.rows, at: r.start, count: r.count, sheet: document.activeSheetIndex, in: document.workbook),
            name: r.count == 1 ? "Delete Row" : "Delete Rows")
        select(CellRef(row: r.start, col: selection.active.col))
    }

    func deleteColumns() {
        let r = colSpan
        replaceWorkbook(
            StructuralEdits.delete(.columns, at: r.start, count: r.count, sheet: document.activeSheetIndex, in: document.workbook),
            name: r.count == 1 ? "Delete Column" : "Delete Columns")
        select(CellRef(row: selection.active.row, col: r.start))
    }

    func setColumnWidth(_ col: Int, to width: Double) {
        let w = min(max(24, width), 1000)
        document.updateSheet(document.activeSheetIndex, actionName: "Column Width", undoManager: undoManager) { $0.columnWidths[col] = w }
    }

    var isHeaderRowFrozen: Bool { sheet.frozenRows > 0 }

    func toggleFrozenHeaderRow() {
        let on = !isHeaderRowFrozen
        document.updateSheet(
            document.activeSheetIndex, actionName: on ? "Freeze Header Row" : "Unfreeze Header Row", undoManager: undoManager
        ) {
            $0.frozenRows = on ? 1 : 0
        }
    }

    private func replaceWorkbook(_ wb: Workbook, name: String) {
        document.replaceWorkbook(wb, actionName: name, undoManager: undoManager)
    }

    // MARK: - Sheets

    func selectSheet(_ index: Int) {
        if isEditing { commitEditing(formulaText, move: (0, 0)) }
        document.selectSheet(index)
        select(CellRef(row: 0, col: 0))
        chart = nil
    }

    func addSheet() {
        var wb = document.workbook
        let i = wb.addSheet(at: document.activeSheetIndex + 1)
        wb.activeSheetIndex = i
        replaceWorkbook(wb, name: "Add Sheet")
        select(CellRef(row: 0, col: 0))
    }

    func renameSheet(_ index: Int, to name: String) {
        renamingSheet = nil
        guard name != document.workbook.sheets[index].name else { return }
        do {
            replaceWorkbook(try StructuralEdits.renameSheet(index, to: name, in: document.workbook), name: "Rename Sheet")
        } catch {
            Alert.show(error, title: "Couldn't rename the sheet", window: grid?.window)
        }
    }

    func deleteSheet(_ index: Int) {
        guard document.workbook.sheets.count > 1 else { return }
        replaceWorkbook(StructuralEdits.deleteSheet(index, in: document.workbook), name: "Delete Sheet")
        select(CellRef(row: 0, col: 0))
    }

    func moveSheet(_ index: Int, by offset: Int) {
        replaceWorkbook(StructuralEdits.moveSheet(from: index, to: index + offset, in: document.workbook), name: "Move Sheet")
    }

    // MARK: - Find & replace

    var findMatches: [CellRef] {
        _ = revision
        return RangeEdits.find(findText, in: sheet, matchCase: matchCase)
    }

    /// Selects the next (or previous) match after the active cell, wrapping around.
    func findNext(backwards: Bool = false) {
        let matches = findMatches
        guard !matches.isEmpty else { NSSound.beep(); return }
        let here = selection.active
        let next =
            backwards
            ? (matches.last { $0 < here } ?? matches.last)
            : (matches.first { $0 > here } ?? matches.first)
        if let next { select(next) }
    }

    func replaceCurrent() {
        let here = selection.active
        if findMatches.contains(here) {
            let changes = RangeEdits.replace(findText, with: replaceText, in: sheet, matchCase: matchCase, only: [here])
            document.apply(changes, actionName: "Replace", undoManager: undoManager)
        }
        findNext()
    }

    func replaceAll() {
        let changes = RangeEdits.replace(findText, with: replaceText, in: sheet, matchCase: matchCase)
        document.apply(changes, actionName: "Replace All", undoManager: undoManager)
    }

    // MARK: - Charts

    func insertChart() {
        var range = effectiveRange
        if range.isSingleCell, let used = sheet.usedRange { range = used }
        chart = ChartSpec(range: range, kind: chart?.kind ?? .bar)
    }
}

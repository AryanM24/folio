import AppKit

/// Mouse, keyboard and responder-chain commands for the grid.
extension GridView {
    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let c = controller else { return }
        if c.isEditing { c.commitEditing(editor.stringValue, move: (0, 0)) }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        switch hit(p) {
        case .corner:
            c.selectAll()
        case .columnHeader(let col, let border):
            if let border {
                if event.clickCount == 2 { autofit(column: border) } else { trackResize(of: border, from: event) }
                return
            }
            if shift, c.selection.kind == .columns { c.selection.cursor = CellRef(row: 0, col: col) } else { c.selectColumns(col, col) }
            trackDrag { hit in
                if case .columnHeader(let col, _) = hit { c.selection.cursor = CellRef(row: 0, col: col) }
            }
        case .rowHeader(let row):
            if shift, c.selection.kind == .rows { c.selection.cursor = CellRef(row: row, col: 0) } else { c.selectRows(row, row) }
            trackDrag { hit in
                if case .rowHeader(let row) = hit { c.selection.cursor = CellRef(row: row, col: 0) }
            }
        case .cell(let cell):
            if event.clickCount == 2 && !shift {
                c.select(cell)
                c.beginEditing()
                return
            }
            c.select(cell, extend: shift)
            trackDrag { hit in
                switch hit {
                case .cell(let cell): c.select(cell, extend: true)
                case .rowHeader(let row): c.select(CellRef(row: row, col: 0), extend: true)
                case .columnHeader(let col, _): c.select(CellRef(row: 0, col: col), extend: true)
                case .corner: break
                }
            }
        }
    }

    /// Runs a local drag loop, autoscrolling at the edges, until the mouse goes up.
    private func trackDrag(_ update: (Hit) -> Void) {
        guard let window else { return }
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            autoscroll(with: e)
            update(hit(convert(e.locationInWindow, from: nil)))
        }
    }

    private func trackResize(of col: Int, from event: NSEvent) {
        guard let window, let c = controller else { return }
        let startX = convert(event.locationInWindow, from: nil).x
        let startWidth = Double(layout.width(ofColumn: col))
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let x = convert(e.locationInWindow, from: nil).x
            let w = max(24, startWidth + Double(x - startX))
            if e.type == .leftMouseUp {
                resizing = nil
                c.setColumnWidth(col, to: w)
                reloadLayout()
                break
            }
            resizing = (col, w)
            reloadLayout()
        }
    }

    /// Double-clicking a column border fits the widest value (first 2,000 rows).
    private func autofit(column col: Int) {
        guard let c = controller else { return }
        let sheet = c.sheet
        var widest: CGFloat = 40
        for row in 0...min(max(sheet.maxRow, 0), 2_000) {
            let ref = CellRef(row: row, col: col)
            guard sheet.cells[ref] != nil else { continue }
            let text = c.document.displayText(at: ref) as NSString
            widest = max(widest, text.size(withAttributes: attributes(for: sheet.style(at: ref))).width + 16)
        }
        c.setColumnWidth(col, to: Double(ceil(widest)))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let c = controller else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let h = hit(p)
        switch h {
        case .cell(let cell) where !c.selectedRange.contains(cell): c.select(cell)
        case .rowHeader(let row) where !c.selectedRange.rows.contains(row) || c.selection.kind != .rows: c.selectRows(row, row)
        case .columnHeader(let col, _) where !c.selectedRange.cols.contains(col) || c.selection.kind != .columns: c.selectColumns(col, col)
        default: break
        }
        return GridMenus.contextMenu(for: c, hit: h)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)
        switch event.keyCode {
        case 126: command ? c.moveToDataEdge(rows: -1, cols: 0, extend: shift) : c.move(rows: -1, cols: 0, extend: shift)
        case 125: command ? c.moveToDataEdge(rows: 1, cols: 0, extend: shift) : c.move(rows: 1, cols: 0, extend: shift)
        case 123: command ? c.moveToDataEdge(rows: 0, cols: -1, extend: shift) : c.move(rows: 0, cols: -1, extend: shift)
        case 124: command ? c.moveToDataEdge(rows: 0, cols: 1, extend: shift) : c.move(rows: 0, cols: 1, extend: shift)
        case 36, 76:  // Return, Enter
            if command { c.beginEditing() } else { c.move(rows: shift ? -1 : 1, cols: 0) }
        case 48: c.move(rows: 0, cols: shift ? -1 : 1)  // Tab
        case 116: c.page(-1, extend: shift)  // Page Up
        case 121: c.page(1, extend: shift)  // Page Down
        case 115: command ? c.select(CellRef(row: 0, col: 0)) : c.select(CellRef(row: c.selection.active.row, col: 0))  // Home
        case 119: c.select(CellRef(row: max(c.sheet.maxRow, 0), col: max(c.sheet.maxCol, 0)))  // End
        case 120: c.beginEditing()  // F2
        case 51, 117: c.clearContents()  // Delete, Forward Delete
        case 53: if c.showFind { c.showFind = false }  // Esc
        default:
            // Type-to-edit: open the editor empty and let it handle the keystroke, so
            // dead keys and input methods work.
            guard !command, !flags.contains(.control), let chars = event.characters, !chars.isEmpty,
                chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            else {
                super.keyDown(with: event)
                return
            }
            c.beginEditing(initial: "")
            editor.currentEditor()?.keyDown(with: event)
        }
    }

    /// Formatting and fill shortcuts work even when the editor's menus aren't installed.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let c = controller, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "b": c.toggleBold()
        case "i": c.toggleItalic()
        case "u": c.toggleUnderline()
        case "d": c.fill(.down)
        case "r": c.fill(.right)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // MARK: - Responder-chain actions (Edit menu)

    @objc func copy(_ sender: Any?) { controller?.copy() }
    @objc func cut(_ sender: Any?) { controller?.cut() }
    @objc func paste(_ sender: Any?) { controller?.paste() }
    @objc func delete(_ sender: Any?) { controller?.clearContents() }
    override func selectAll(_ sender: Any?) { controller?.selectAll() }

    /// Edit › Find › Find… (⌘F) opens Folio's find & replace bar.
    override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        switch NSTextFinder.Action(rawValue: tag) {
        case .nextMatch?: controller?.findNext()
        case .previousMatch?: controller?.findNext(backwards: true)
        case .showReplaceInterface?, .showFindInterface?: controller?.showFind = true
        default: controller?.showFind = true
        }
    }

    @objc func performFindPanelAction(_ sender: Any?) { performTextFinderAction(sender) }
}

/// Native context menus for cells and headers. Items run closures.
@MainActor
enum GridMenus {
    static func contextMenu(for c: SheetController, hit: GridView.Hit) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String? = nil, _ action: @escaping () -> Void) {
            let item = ClosureMenuTarget.item(title, action: action)
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        add("Cut", "scissors") { c.cut() }
        add("Copy", "doc.on.doc") { c.copy() }
        add("Paste", "doc.on.clipboard") { c.paste() }
        menu.addItem(.separator())
        switch hit {
        case .columnHeader:
            add("Insert Column Left") { c.insertColumns(left: true) }
            add("Insert Column Right") { c.insertColumns(left: false) }
            add("Delete Column", "trash") { c.deleteColumns() }
        case .rowHeader:
            add("Insert Row Above") { c.insertRows(above: true) }
            add("Insert Row Below") { c.insertRows(above: false) }
            add("Delete Row", "trash") { c.deleteRows() }
        default:
            add("Insert Row Above") { c.insertRows(above: true) }
            add("Insert Column Left") { c.insertColumns(left: true) }
            add("Delete Row") { c.deleteRows() }
            add("Delete Column") { c.deleteColumns() }
        }
        menu.addItem(.separator())
        add("Sort Ascending", "arrow.up") { c.sort(ascending: true) }
        add("Sort Descending", "arrow.down") { c.sort(ascending: false) }
        menu.addItem(.separator())
        add("Clear Contents") { c.clearContents() }
        add("Clear Formatting") { c.clearFormatting() }
        menu.addItem(.separator())
        add("Insert Chart", "chart.bar") { c.insertChart() }
        return menu
    }
}

/// Runs a Swift closure as a menu item's action. The menu item retains it through
/// `representedObject`.
final class ClosureMenuTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }

    static func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let target = ClosureMenuTarget(action)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        return item
    }
}

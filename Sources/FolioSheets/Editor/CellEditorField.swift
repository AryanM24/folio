import AppKit

/// The in-place editor: a borderless text field laid over the active cell. The grid
/// draws the accent border around it, so it looks like the cell itself is editable.
final class CellEditorField: NSTextField {
    weak var cellDelegate: GridView? {
        didSet { delegate = cellDelegate }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = true
        backgroundColor = GridPalette.surface
        textColor = GridPalette.text
        font = .systemFont(ofSize: 13)
        focusRingType = .none
        lineBreakMode = .byClipping
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        setAccessibilityLabel("Cell contents")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("CellEditorField is created in code") }
}

extension GridView: NSTextFieldDelegate {
    func showEditor(text: String, at cell: CellRef) {
        editingCell = cell
        editor.stringValue = text
        editor.isHidden = false
        positionEditor(at: cell)
        needsDisplay = true
        window?.makeFirstResponder(editor)
        // Put the caret at the end rather than selecting everything.
        if let fieldEditor = editor.currentEditor() {
            fieldEditor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    func hideEditor() {
        if let cell = editingCell { setNeedsDisplay(displayedRect(of: cell).insetBy(dx: -4, dy: -4)) }
        editingCell = nil
        editor.isHidden = true
        needsDisplay = true
    }

    /// Fits the editor inside the cell's border, widening it as the text grows.
    func positionEditor(at cell: CellRef) {
        let r = displayedRect(of: cell)
        let attrs: [NSAttributedString.Key: Any] = [.font: editor.font ?? .systemFont(ofSize: 13)]
        let needed = (editor.stringValue as NSString).size(withAttributes: attrs).width + 16
        let maxWidth = max(r.width, visibleRect.maxX - r.minX - 4)
        let width = min(max(r.width, needed), maxWidth)
        let fieldHeight: CGFloat = 17
        editor.frame = CGRect(x: r.minX + 4, y: r.minY + (r.height - fieldHeight) / 2 - 1, width: width - 8, height: fieldHeight)
        setNeedsDisplay(CGRect(x: r.minX - 4, y: r.minY - 4, width: width + 8, height: r.height + 8))
    }

    func controlTextDidChange(_ obj: Notification) {
        controller?.editorTextChanged(editor.stringValue)
        if let cell = editingCell { positionEditor(at: cell) }
        suggestFunctionNames()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let c = controller else { return false }
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        switch selector {
        case #selector(insertNewline(_:)):
            c.commitEditing(editor.stringValue, move: (shift ? -1 : 1, 0))
        case #selector(insertTab(_:)):
            c.commitEditing(editor.stringValue, move: (0, 1))
        case #selector(insertBacktab(_:)):
            c.commitEditing(editor.stringValue, move: (0, -1))
        case #selector(cancelOperation(_:)):
            c.cancelEditing()
        default:
            return false
        }
        return true
    }

    /// Clicking elsewhere (or the window losing focus) commits, like Numbers.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let c = controller, c.isEditing else { return }
        c.commitEditing(editor.stringValue, move: (0, 0))
    }

    // MARK: - Function name autocomplete

    /// The identifier being typed at the caret, when the text is a formula.
    private func partialFunctionName(in textView: NSTextView) -> NSRange? {
        let s = textView.string as NSString
        guard s.hasPrefix("=") else { return nil }
        let caret = textView.selectedRange.location
        guard caret == s.length else { return nil }
        var start = caret
        while start > 1, let scalar = UnicodeScalar(s.character(at: start - 1)), CharacterSet.letters.contains(scalar) { start -= 1 }
        guard caret - start >= 2 else { return nil }
        // Only after an operator, "(", "," or the "=" itself — not inside a cell reference.
        if start > 0, let prev = UnicodeScalar(s.character(at: start - 1)), CharacterSet.alphanumerics.contains(prev) || prev == "$" {
            return nil
        }
        return NSRange(location: start, length: caret - start)
    }

    private func suggestFunctionNames() {
        guard !isCompleting, let tv = editor.currentEditor() as? NSTextView, partialFunctionName(in: tv) != nil else { return }
        isCompleting = true
        tv.complete(nil)
        isCompleting = false
    }

    func control(
        _ control: NSControl, textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        guard let partial = partialFunctionName(in: textView) else { return [] }
        let prefix = (textView.string as NSString).substring(with: partial).uppercased()
        index.pointee = -1
        return FunctionLibrary.names.filter { $0.hasPrefix(prefix) && $0 != prefix }.map { $0 + "(" }
    }
}

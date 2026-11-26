import AppKit

/// The editing surface: an `NSTextView` with code-editor typing behavior.
///
/// Everything here routes through ``apply(_:actionName:)``, which uses `shouldChangeText` /
/// `didChangeText`, so each command is one undo step on the document's undo manager (and so
/// triggers autosave). Multiple selections fall back to plain `NSTextView` behavior.
///
/// Use ``text`` rather than `string`, which copies the whole document on every call.
final class CodeTextView: NSTextView {
    weak var controller: EditorController?
    var language: Language = .plain
    var indentStyle = IndentStyle(usesTabs: false, width: 4)
    var highlightsCurrentLine = true

    /// The live backing string. No copy.
    var text: NSString { textStorage?.mutableString ?? "" }

    // MARK: Applying edits

    func apply(_ edit: TextEdit, actionName: String? = nil) {
        if edit.isCaretMoveOnly {
            setSelectedRange(edit.selection)
            return
        }
        if actionName != nil { breakUndoCoalescing() }
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: typingAttributes))
        didChangeText()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
        if let actionName {
            undoManager?.setActionName(actionName)
            breakUndoCoalescing()
        }
    }

    private var hasSingleSelection: Bool { selectedRanges.count == 1 && !hasMarkedText() }

    // MARK: Typing

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if replacementRange.location == NSNotFound, hasSingleSelection, let typed = string as? String,
           let edit = TextEditing.typing(typed, in: text, selection: selectedRange(), pairQuotes: language.pairsQuotes) {
            apply(edit)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func insertNewline(_ sender: Any?) {
        guard hasSingleSelection, isEditable else { return super.insertNewline(sender) }
        apply(TextEditing.newline(text, selection: selectedRange(), style: indentStyle, language: language))
    }

    override func insertTab(_ sender: Any?) {
        guard hasSingleSelection, isEditable else { return super.insertTab(sender) }
        apply(TextEditing.tab(text, selection: selectedRange(), style: indentStyle))
    }

    override func insertBacktab(_ sender: Any?) {
        guard hasSingleSelection, isEditable else { return super.insertBacktab(sender) }
        apply(TextEditing.outdent(text, selection: selectedRange(), width: indentStyle.width), actionName: "Outdent")
    }

    override func deleteBackward(_ sender: Any?) {
        if hasSingleSelection, let edit = TextEditing.deleteBackward(text, selection: selectedRange()) {
            apply(edit)
            return
        }
        super.deleteBackward(sender)
    }

    // MARK: Shortcuts

    /// Editor shortcuts that work even when the app hasn't mounted ``CodeCommands``.
    /// When the menu is mounted it sees the key first and calls the same controller methods.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let controller else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = event.charactersIgnoringModifiers ?? ""
        let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey)).map(Character.init) ?? " ")
        let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey)).map(Character.init) ?? " ")
        switch (flags, key) {
        case ([.command], "/"): controller.toggleComment()
        case ([.command], "]"): controller.indent()
        case ([.command], "["): controller.outdent()
        case ([.command, .option], up): controller.moveLines(up: true)
        case ([.command, .option], down): controller.moveLines(up: false)
        case ([.command, .shift], "d"), ([.command, .shift], "D"): controller.duplicateLines()
        case ([.command], "l"): controller.showGoToLine()
        case ([.command], "b") where language == .markdown: controller.bold()
        case ([.command], "i") where language == .markdown: controller.italic()
        case ([.command], "k") where language == .markdown: controller.insertLink()
        case ([.command], "="), ([.command], "+"), ([.command, .shift], "="), ([.command, .shift], "+"): controller.zoom(by: 1)
        case ([.command], "-"): controller.zoom(by: -1)
        case ([.command], "0"): controller.resetZoom()
        case ([.command, .option], "f"): controller.showFindReplace()
        case ([.command, .option, .shift], "f"), ([.command, .option, .shift], "F"): controller.formatJSON()
        case ([.command], "p"): controller.printDocument()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard highlightsCurrentLine, window?.firstResponder === self || window == nil, let lineRect = currentLineRect(), lineRect.intersects(rect) else { return }
        CodeTheme.currentLine.setFill()
        lineRect.fill()
    }

    /// The caret's visual line, full width. `nil` with a range selection.
    func currentLineRect() -> NSRect? {
        guard selectedRanges.count == 1, selectedRange().length == 0,
              let layoutManager, let textStorage else { return nil }
        let location = selectedRange().location
        var rect: NSRect
        if location >= textStorage.length, !layoutManager.extraLineFragmentRect.isEmpty {
            rect = layoutManager.extraLineFragmentRect
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(location, max(0, textStorage.length - 1)))
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        rect.origin.x = 0
        rect.size.width = bounds.width
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    private var reportedFirstDraw = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if !reportedFirstDraw {
            reportedFirstDraw = true
            controller?.didFirstDraw()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Take focus when the window opens so typing goes straight into the file.
        DispatchQueue.main.async { [weak self] in
            guard let self, window.firstResponder === window || window.firstResponder == nil else { return }
            window.makeFirstResponder(self)
        }
    }
}

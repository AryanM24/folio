import AppKit

/// Character and paragraph formatting. Each command changes the selection (or, with
/// just a caret, the typing attributes) as one named, undoable edit.
extension DocumentEditorController {

    // MARK: Edit primitives

    /// Selected ranges with content; empty when there's only a caret.
    private var selectedRanges: [NSRange] {
        (textView?.selectedRanges ?? []).map(\.rangeValue).filter { $0.length > 0 }
    }

    /// Whole paragraphs touched by the selection.
    func selectedParagraphs() -> NSRange {
        guard let textView, let storage else { return NSRange(location: 0, length: 0) }
        let ns = storage.string as NSString
        return textView.selectedRanges.map(\.rangeValue).reduce(nil as NSRange?) { union, range in
            let p = ns.paragraphRange(for: range)
            return union.map { NSUnionRange($0, p) } ?? p
        } ?? ns.paragraphRange(for: textView.selectedRange())
    }

    /// Changes character attributes of the selection, or of what's typed next.
    func changeCharacters(_ actionName: String, _ transform: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard let textView, let storage else { return }
        let ranges = selectedRanges
        if ranges.isEmpty {
            var typing = textView.typingAttributes
            transform(&typing)
            textView.typingAttributes = typing
        } else {
            guard textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil) else { return }
            storage.beginEditing()
            for range in ranges {
                storage.enumerateAttributes(in: range) { attrs, run, _ in
                    var updated = attrs
                    transform(&updated)
                    storage.setAttributes(updated, range: run)
                }
            }
            storage.endEditing()
            textView.didChangeText()
            textView.undoManager?.setActionName(actionName)
        }
        selectionChanged()
    }

    /// Changes the paragraph style of every selected paragraph (and the typing style).
    func changeParagraphs(_ actionName: String, _ transform: (NSParagraphStyle?) -> NSParagraphStyle) {
        guard let textView, let storage else { return }
        let range = selectedParagraphs()
        if range.length > 0, textView.shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            storage.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
                storage.addAttribute(.paragraphStyle, value: transform(value as? NSParagraphStyle), range: run)
            }
            storage.endEditing()
            textView.didChangeText()
            textView.undoManager?.setActionName(actionName)
        }
        textView.typingAttributes[.paragraphStyle] = transform(textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        selectionChanged()
    }

    /// Replaces `range` with `replacement` as one undoable edit and selects `select`.
    func replace(_ range: NSRange, with replacement: NSAttributedString, actionName: String, select: NSRange? = nil) {
        guard let textView, let storage else { return }
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        textView.undoManager?.setActionName(actionName)
        textView.setSelectedRange(select ?? NSRange(location: range.location + replacement.length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        selectionChanged()
    }

    /// Inserts text at the selection, replacing it.
    func insert(_ text: NSAttributedString, actionName: String) {
        guard let textView else { return }
        replace(textView.selectedRange(), with: text, actionName: actionName)
    }

    // MARK: Paragraph styles

    func applyStyle(_ style: TextStyle) {
        guard let textView, let storage else { return }
        let range = selectedParagraphs()
        if range.length > 0, textView.shouldChangeText(in: range, replacementString: nil) {
            TextStyle.apply(style, to: storage, paragraphsIn: range)
            textView.didChangeText()
            textView.undoManager?.setActionName(style.name)
        }
        var typing = textView.typingAttributes
        typing.merge(style.attributes(base: typing[.paragraphStyle] as? NSParagraphStyle)) { $1 }
        if style.color == nil { typing[.foregroundColor] = nil }
        textView.typingAttributes = typing
        selectionChanged()
        textChanged()
    }

    // MARK: Character formatting

    func toggleBold() {
        let on = !selection.bold
        changeCharacters("Bold") { a in
            let f = a[.font] as? NSFont ?? TextStyle.body.font
            a[.font] = on ? f.adding(.bold) : f.removing(.bold)
        }
    }

    func toggleItalic() {
        let on = !selection.italic
        changeCharacters("Italic") { a in
            let f = a[.font] as? NSFont ?? TextStyle.body.font
            a[.font] = on ? f.adding(.italic) : f.removing(.italic)
        }
    }

    func toggleUnderline() {
        let on = !selection.underline
        changeCharacters("Underline") { $0[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : nil }
    }

    func toggleStrikethrough() {
        let on = !selection.strikethrough
        changeCharacters("Strikethrough") { $0[.strikethroughStyle] = on ? NSUnderlineStyle.single.rawValue : nil }
    }

    /// 1 superscript, -1 subscript; choosing the current one returns to normal.
    func setBaseline(_ value: Int) {
        let target = selection.baseline == value ? 0 : value
        changeCharacters(target > 0 ? "Superscript" : target < 0 ? "Subscript" : "Baseline") { a in
            a[.superscript] = target == 0 ? nil : target
            a[.baselineOffset] = nil
        }
    }

    func setFontFamily(_ family: String) {
        changeCharacters("Font") { a in a[.font] = (a[.font] as? NSFont ?? TextStyle.body.font).withFamily(family) }
    }

    func setFontSize(_ size: CGFloat) {
        let size = min(400, max(4, size))
        changeCharacters("Font Size") { a in a[.font] = (a[.font] as? NSFont ?? TextStyle.body.font).withSize(size) }
    }

    func biggerFont() { setFontSize(selection.fontSize + 1) }
    func smallerFont() { setFontSize(selection.fontSize - 1) }

    func setTextColor(_ color: NSColor?) {
        changeCharacters("Text Color") { $0[.foregroundColor] = color }
    }

    func setHighlight(_ color: NSColor?) {
        changeCharacters("Highlight") { $0[.backgroundColor] = color }
    }

    /// Resets character formatting to Body; whole paragraphs also get the Body style.
    func clearFormatting() {
        guard let textView else { return }
        if selectedRanges.isEmpty {
            textView.typingAttributes = TextStyle.body.attributes(base: textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
            selectionChanged()
            return
        }
        changeCharacters("Clear Formatting") { a in
            var clean = TextStyle.body.attributes(base: a[.paragraphStyle] as? NSParagraphStyle)
            clean[.paragraphStyle] = a[.paragraphStyle]
            for key in [NSAttributedString.Key.link, .attachment] where a[key] != nil { clean[key] = a[key] }
            a = clean
        }
    }

    func copyStyle() {
        guard let textView, let storage else { return }
        let range = textView.selectedRange()
        let attrs =
            range.length > 0 && range.location < storage.length
            ? storage.attributes(at: range.location, effectiveRange: nil) : textView.typingAttributes
        copiedStyle = attrs.filter { $0.key != .attachment && $0.key != .link }
    }

    func pasteStyle() {
        guard let copied = copiedStyle else { return NSSound.beep() }
        changeCharacters("Paste Style") { a in
            for key in [
                NSAttributedString.Key.font, .foregroundColor, .backgroundColor, .underlineStyle, .strikethroughStyle, .superscript,
            ] {
                a[key] = copied[key]
            }
        }
        if let paragraph = copied[.paragraphStyle] as? NSParagraphStyle {
            changeParagraphs("Paste Style") { current in
                let p = (paragraph.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                p.textLists = current?.textLists ?? []
                p.textBlocks = current?.textBlocks ?? []
                return p
            }
        }
    }

    // MARK: Paragraph formatting

    func setAlignment(_ alignment: NSTextAlignment) {
        changeParagraphs("Alignment") { style in
            let p = (style?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            p.alignment = alignment
            return p
        }
    }

    func setLineSpacing(_ multiple: CGFloat) {
        changeParagraphs("Line Spacing") { style in
            let p = (style?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            p.lineHeightMultiple = multiple
            return p
        }
    }

    func indent() { changeParagraphs("Indent") { ListFormatting.indent($0, by: 1) } }
    func outdent() { changeParagraphs("Outdent") { ListFormatting.indent($0, by: -1) } }

    // MARK: Lists

    func toggleList(_ kind: ListKind) {
        guard let textView, let storage else { return }
        let range = selectedParagraphs()
        if range.length == 0 {
            // Caret on the empty last line: the list starts with what's typed next.
            let style =
                (textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            if ListKind.of(style) == kind {
                style.textLists = []; style.headIndent = 0; style.firstLineHeadIndent = 0
            } else {
                let list = NSTextList(markerFormat: kind.markerFormat, options: 0)
                ListFormatting.configure(style, list: list)
                if ListFormatting.markersInContent {
                    var attrs = textView.typingAttributes
                    attrs[.paragraphStyle] = style
                    insert(NSAttributedString(string: "\t\(list.marker(forItemNumber: 1))\t", attributes: attrs), actionName: kind.title)
                }
            }
            textView.typingAttributes[.paragraphStyle] = style
            selectionChanged()
            return
        }
        let hadSelection = textView.selectedRange().length > 0
        let replacement = ListFormatting.toggle(kind, in: storage.attributedSubstring(from: range))
        let trailing = replacement.string.hasSuffix("\n") ? 1 : 0
        let select =
            hadSelection
            ? NSRange(location: range.location, length: replacement.length - trailing)
            : NSRange(location: range.location + replacement.length - trailing, length: 0)
        replace(range, with: replacement, actionName: kind.title, select: select)
    }

    func toggleCheckbox() {
        changeParagraphs("Toggle Checkbox") { style in ListFormatting.toggledCheck(style) ?? style ?? .default }
    }
}

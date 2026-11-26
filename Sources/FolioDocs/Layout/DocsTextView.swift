import AppKit

/// The editor's text view: a TextKit 1 `NSTextView` with Folio's defaults and a few
/// document behaviors the stock view lacks.
///
/// TextKit 1 because `NSTextTable` only lays out in TextKit 1 (a TextKit 2 view
/// silently falls back the first time it meets a table, losing its state), and
/// because pagination for Print/PDF uses the same `NSLayoutManager` machinery.
/// Non-contiguous layout keeps very long documents fast.
final class DocsTextView: NSTextView {
    /// Called for ⌘P / File › Print, which should print pages with margins rather
    /// than the on-screen view.
    var onPrint: (() -> Void)?

    /// Builds the text view on top of an existing storage (the document's).
    static func make(storage: NSTextStorage) -> DocsTextView {
        let layout = MarkerLayoutManager(showsPageBreaks: true)
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 468, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        let view = DocsTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792), textContainer: container)
        view.configure()
        return view
    }

    private func configure() {
        // Paper stays white in dark mode (like Pages), so the text view always draws
        // in the light appearance: black default text, light selection, dark caret.
        appearance = NSAppearance(named: .aqua)
        backgroundColor = .white
        drawsBackground = true
        insertionPointColor = .black
        isRichText = true
        importsGraphics = true
        allowsImageEditing = true
        allowsUndo = true
        isEditable = true
        isSelectable = true
        usesFontPanel = true
        usesRuler = false
        usesInspectorBar = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        allowsDocumentBackgroundColorChange = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = true
        isAutomaticDashSubstitutionEnabled = true
        isAutomaticTextReplacementEnabled = true
        isAutomaticSpellingCorrectionEnabled = NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        isAutomaticLinkDetectionEnabled = false
        writingToolsBehavior = .complete
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = []
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        typingAttributes = TextStyle.body.attributes()
        linkTextAttributes = [
            .foregroundColor: NSColor(srgbRed: 0.02, green: 0.45, blue: 0.87, alpha: 1),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        setAccessibilityLabel("Document")
        setAccessibilityRoleDescription("document text")
    }

    // MARK: Lists

    /// Return in an empty list item ends the list, as in Pages and Word.
    override func insertNewline(_ sender: Any?) {
        let range = selectedRange()
        guard range.length == 0, let storage = textStorage else { return super.insertNewline(sender) }
        let ns = storage.string as NSString
        let paragraph = ns.paragraphRange(for: range)
        let style =
            paragraph.location < storage.length
            ? storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            : typingAttributes[.paragraphStyle] as? NSParagraphStyle
        guard let style, !style.textLists.isEmpty else { return super.insertNewline(sender) }
        var content = ns.substring(with: paragraph).trimmingCharacters(in: .newlines)
        if ListFormatting.markersInContent { content = String(content.drop { $0 != "\t" }.dropFirst().drop { $0 != "\t" }.dropFirst()) }
        guard content.isEmpty else { return super.insertNewline(sender) }
        let plain = (style.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        plain.textLists = []
        plain.headIndent = 0
        plain.firstLineHeadIndent = 0
        if paragraph.length > 0 {
            let marker = ListFormatting.markersInContent ? ListFormatting.markerLength(in: ns, at: paragraph.location, isList: true) : 0
            let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paragraph))
            replacement.deleteCharacters(in: NSRange(location: 0, length: marker))
            replacement.addAttribute(.paragraphStyle, value: plain, range: NSRange(location: 0, length: replacement.length))
            if shouldChangeText(in: paragraph, replacementString: replacement.string) {
                storage.replaceCharacters(in: paragraph, with: replacement)
                didChangeText()
                setSelectedRange(NSRange(location: paragraph.location, length: 0))
            }
        }
        typingAttributes[.paragraphStyle] = plain
    }

    /// Clicking a checklist box toggles it.
    override func mouseDown(with event: NSEvent) {
        if toggleCheckbox(at: convert(event.locationInWindow, from: nil)) { return }
        super.mouseDown(with: event)
    }

    private func toggleCheckbox(at point: NSPoint) -> Bool {
        guard let layout = layoutManager as? MarkerLayoutManager, let container = textContainer, let storage = textStorage,
            storage.length > 0
        else { return false }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: inContainer, in: container)
        let location = layout.characterIndexForGlyph(at: glyph)
        guard location < storage.length else { return false }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        let style = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
        guard let toggled = ListFormatting.toggledCheck(style) else { return false }
        // Only clicks on the box itself, which sits in the indent left of the text.
        let marker = MarkerLayoutManager.marker(at: paragraph.location, in: storage)?.string ?? "☐"
        guard let box = layout.markerFrame(forParagraphAt: paragraph.location, marker: marker, origin: textContainerOrigin),
            box.insetBy(dx: -4, dy: -2).contains(point)
        else { return false }
        if shouldChangeText(in: paragraph, replacementString: nil) {
            storage.addAttribute(.paragraphStyle, value: toggled, range: paragraph)
            didChangeText()
            undoManager?.setActionName("Toggle Checkbox")
        }
        return true
    }

    // MARK: Printing

    override func printView(_ sender: Any?) {
        if let onPrint { onPrint() } else { super.printView(sender) }
    }
}

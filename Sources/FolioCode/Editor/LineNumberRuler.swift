import AppKit

/// Line numbers beside the text.
///
/// Only the visible glyph range is walked, and each visual line's number comes from the
/// shared ``LineIndex`` by binary search, so cost doesn't grow with file size. Wrapped lines
/// get one number, on their first visual line.
final class LineNumberRuler: NSRulerView {
    weak var controller: EditorController?
    var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) {
        didSet { updateThickness(force: true) }
    }
    private var digits = 0

    init(textView: CodeTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        setAccessibilityElement(false)
        updateThickness(force: true)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not used from nibs") }

    override var isFlipped: Bool { true }

    /// Widens the gutter when the line count gains a digit.
    func updateThickness(force: Bool = false) {
        let count = controller?.highlighter.lines.count ?? 1
        let needed = max(3, String(count).count)
        guard force || needed != digits else { return }
        digits = needed
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        ruleThickness = ceil(CGFloat(digits) * digitWidth + 24)
        scrollView?.tile()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Views don't clip to bounds by default (macOS 14+), so never fill past our own edge.
        let rect = dirtyRect.intersection(bounds)
        CodeTheme.background.setFill()
        rect.fill()
        drawHashMarksAndLabels(in: rect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? CodeTextView, let controller,
              let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let lines = controller.highlighter.lines
        let text = textView.text
        let origin = textView.textContainerOrigin
        let current = controller.caretLine
        let muted: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CodeTheme.muted.withAlphaComponent(0.75)]
        let strong: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CodeTheme.foreground]

        // Extra line height goes above the glyphs, so the baseline sits one descent above the bottom.
        let textDescender = (textView.typingAttributes[.font] as? NSFont)?.descender ?? font.descender

        /// Draws `number` on the same baseline as the text line.
        func draw(_ number: Int, in lineRect: NSRect) {
            let baseline = lineRect.height + textDescender
            let top = convert(NSPoint(x: 0, y: lineRect.minY + origin.y), from: textView).y
            guard top + lineRect.height >= rect.minY, top <= rect.maxY else { return }
            let label = "\(number)" as NSString
            let attributes = number - 1 == current ? strong : muted
            let width = label.size(withAttributes: attributes).width
            label.draw(at: NSPoint(x: ruleThickness - 12 - width, y: top + baseline - font.ascender), withAttributes: attributes)
        }

        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        var glyph = glyphs.location
        while glyph < NSMaxRange(glyphs) {
            var fragmentGlyphs = NSRange()
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentGlyphs, withoutAdditionalLayout: true)
            let character = layoutManager.characterIndexForGlyph(at: glyph)
            // Number only the first visual line of each source line.
            if character == 0 || (character <= text.length && text.character(at: character - 1) == 10) {
                draw(lines.line(containing: character) + 1, in: lineRect)
            }
            glyph = max(NSMaxRange(fragmentGlyphs), glyph + 1)
        }
        // The empty line after a final newline.
        let extra = layoutManager.extraLineFragmentRect
        if !extra.isEmpty, extra.maxY >= visible.minY, extra.minY <= visible.maxY {
            draw(lines.count, in: extra)
        }
    }
}

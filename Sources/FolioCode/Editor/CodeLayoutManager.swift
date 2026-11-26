import AppKit

/// Draws spaces, tabs and line ends as faint marks when "Show Invisibles" is on.
///
/// `NSLayoutManager.showsInvisibleCharacters` exists, but draws them in the text color,
/// which is far too loud for code.
nonisolated final class CodeLayoutManager: NSLayoutManager {
    var showsInvisibles = false

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard showsInvisibles, let storage = textStorage else { return }
        let text = storage.mutableString
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: CodeTheme.invisible]
        for index in characters.location..<NSMaxRange(characters) {
            let mark: String
            switch text.character(at: index) {
            case 32: mark = "·"
            case 9: mark = "→"
            case 10: mark = "¬"
            default: continue
            }
            let glyph = glyphIndexForCharacter(at: index)
            let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            let location = self.location(forGlyphAt: glyph)
            if attributes[.font] == nil { attributes[.font] = storage.attribute(.font, at: index, effectiveRange: nil) }
            let font = attributes[.font] as? NSFont
            let ascent = font?.ascender ?? 10
            (mark as NSString).draw(at: NSPoint(x: origin.x + lineRect.minX + location.x, y: origin.y + lineRect.minY + location.y - ascent), withAttributes: attributes)
        }
    }
}

import AppKit

/// A TextKit 1 layout manager that draws list markers.
///
/// From macOS 26, list markers ("•", "1.") are no longer characters in the text
/// (`NSTextList.includesTextListMarkers` is false) and only TextKit 2 draws them.
/// Folio uses TextKit 1 because `NSTextTable` (tables) requires it, so this draws the
/// marker for each list item in the indent before its first line, the way TextKit 2
/// does. On systems where markers are text, it draws nothing extra.
///
/// In the editor (`showsPageBreaks`), a page break (form feed) ends the line and is
/// drawn as a dashed rule, because the editor is one long column. When paginating,
/// form feeds keep their usual meaning: continue in the next page's container.
nonisolated final class MarkerLayoutManager: NSLayoutManager {
    /// Gap between a marker and the item's text, in points.
    static let markerGap: CGFloat = 6

    /// Strong reference: `NSLayoutManager.delegate` is unowned.
    private let pageBreaks = PageBreakDelegate()

    /// Treat page breaks as line breaks and draw them (the editor), or as container
    /// breaks (print and PDF).
    init(showsPageBreaks: Bool = false) {
        super.init()
        if showsPageBreaks { delegate = pageBreaks }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used from Interface Builder") }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        if delegate != nil { drawPageBreaks(in: chars, origin: origin) }
        guard !ListFormatting.markersInContent else { return }
        let ns = storage.string as NSString
        var location = ns.paragraphRange(for: NSRange(location: min(chars.location, ns.length - 1), length: 0)).location
        while location < NSMaxRange(chars), location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            guard paragraph.location >= chars.location,
                let marker = Self.marker(at: paragraph.location, in: storage),
                let frame = markerFrame(forParagraphAt: paragraph.location, marker: marker.string, origin: origin)
            else { continue }
            marker.string.draw(at: frame.origin, withAttributes: marker.attributes)
        }
    }

    /// The marker text and attributes for the list item starting at `location`.
    static func marker(at location: Int, in text: NSAttributedString) -> (string: String, attributes: [NSAttributedString.Key: Any])? {
        guard let style = text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
            let list = style.textLists.last
        else { return nil }
        let font = text.attribute(.font, at: location, effectiveRange: nil) as? NSFont ?? TextStyle.body.font
        let color = text.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor ?? .black
        let string: String =
            switch list.markerFormat {
            case .box: "☐"
            case .check: "☑"
            default:
                list.isOrdered
                    ? list.marker(forItemNumber: ListFormatting.itemNumber(at: location, in: text)) + "."
                    : list.marker(forItemNumber: 1)
            }
        return (string, [.font: font, .foregroundColor: color])
    }

    /// Where the marker for the paragraph at `location` goes, in the coordinates the
    /// text is drawn in: right-aligned just before the first line's text.
    func markerFrame(forParagraphAt location: Int, marker: String, origin: NSPoint) -> NSRect? {
        guard let storage = textStorage, location < storage.length else { return nil }
        let glyph = glyphIndexForCharacter(at: location)
        guard glyph < numberOfGlyphs else { return nil }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = self.location(forGlyphAt: glyph)
        let font = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont ?? TextStyle.body.font
        let size = (marker as NSString).size(withAttributes: [.font: font])
        let textX = origin.x + line.minX + baseline.x
        return NSRect(
            x: textX - Self.markerGap - size.width,
            y: origin.y + line.minY + baseline.y - font.ascender,
            width: size.width, height: size.height)
    }

    /// Draws a dashed "page break" rule across each line that ends in a form feed.
    private func drawPageBreaks(in chars: NSRange, origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        let ns = storage.string as NSString
        var search = chars
        while search.length > 0 {
            let found = ns.range(of: "\u{0C}", options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            let glyph = glyphIndexForCharacter(at: found.location)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = origin.y + line.maxY - 1
            let path = NSBezierPath()
            path.move(to: NSPoint(x: origin.x, y: y))
            path.line(to: NSPoint(x: origin.x + container.size.width, y: y))
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor(srgbRed: 0.62, green: 0.62, blue: 0.66, alpha: 1).setStroke()
            path.stroke()
            search = NSRange(location: NSMaxRange(found), length: NSMaxRange(search) - NSMaxRange(found))
        }
    }
}

/// Makes a form feed end the line in the single-column editor instead of jumping to
/// a next text container that doesn't exist.
private nonisolated final class PageBreakDelegate: NSObject, NSLayoutManagerDelegate {
    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = layoutManager.textStorage, charIndex < storage.length,
            (storage.string as NSString).character(at: charIndex) == 0x0C
        else { return action }
        return .lineBreak
    }
}

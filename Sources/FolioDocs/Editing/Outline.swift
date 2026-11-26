public import AppKit

/// One heading in the outline sidebar.
public nonisolated struct OutlineItem: Identifiable, Equatable, Sendable {
    /// Character offset of the heading; also its identity, since two headings can't
    /// start at the same place.
    public var id: Int { location }
    public let location: Int
    public let title: String
    /// 0 for the title, 1–3 for headings.
    public let level: Int
}

nonisolated enum Outline {
    /// Headings in document order.
    ///
    /// Scans paragraphs by their first character's font and paragraph style (see
    /// `TextStyle.detect`). Paragraphs longer than 200 characters are never headings,
    /// which keeps big bold body text out of the outline.
    static func headings(in text: NSAttributedString) -> [OutlineItem] {
        let ns = text.string as NSString
        var items: [OutlineItem] = []
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            guard range.length > 1, range.length < 200 else { continue }
            let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let para = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            if para?.textBlocks.isEmpty == false || para?.textLists.isEmpty == false { continue }
            guard let level = TextStyle.detect(font: font, paragraph: para).outlineLevel else { continue }
            let title = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { items.append(OutlineItem(location: range.location, title: title, level: level)) }
        }
        return items
    }
}

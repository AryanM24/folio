public import AppKit

/// The paragraph styles in the style menu: Title, Heading 1–3, Body, Caption, Quote, Code.
///
/// A style is applied as real attributes (font, color, paragraph spacing and the
/// paragraph's `headerLevel`), not as a private tag, so it survives every format the
/// Cocoa text system writes and Word, Pages and browsers render it the same way.
/// `headerLevel` is what HTML export turns into `<h1>`…`<h3>` and what the outline reads.
public nonisolated enum TextStyle: String, CaseIterable, Sendable, Identifiable {
    case title, heading1, heading2, heading3, body, caption, quote, code

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .title: "Title"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .body: "Body"
        case .caption: "Caption"
        case .quote: "Quote"
        case .code: "Code"
        }
    }

    /// Outline depth: 0 for the title, 1–3 for headings, `nil` for text.
    public var outlineLevel: Int? {
        switch self {
        case .title: 0
        case .heading1: 1
        case .heading2: 2
        case .heading3: 3
        default: nil
        }
    }

    /// `NSParagraphStyle.headerLevel` (HTML h1–h6); 0 means "not a heading".
    var headerLevel: Int {
        switch self {
        case .title, .heading1: 1
        case .heading2: 2
        case .heading3: 3
        default: 0
        }
    }

    /// Font family used for body text and headings. Helvetica Neue ships with every Mac
    /// and is a real family name, so Word and LibreOffice can map it (the system UI
    /// font's private name can't be written to files).
    static let family = "Helvetica Neue"

    public var font: NSFont {
        switch self {
        case .title: Self.font("HelveticaNeue-Bold", 26)
        case .heading1: Self.font("HelveticaNeue-Bold", 20)
        case .heading2: Self.font("HelveticaNeue-Bold", 16)
        case .heading3: Self.font("HelveticaNeue-Medium", 13)
        case .body: Self.font("HelveticaNeue", 12)
        case .caption: Self.font("HelveticaNeue", 10)
        case .quote: Self.font("HelveticaNeue-Italic", 12)
        case .code: Self.font("Menlo-Regular", 11)
        }
    }

    /// Text color; `nil` means the document's default (black on paper).
    var color: NSColor? {
        switch self {
        case .caption: NSColor(srgbRed: 0.44, green: 0.44, blue: 0.48, alpha: 1)
        case .quote: NSColor(srgbRed: 0.30, green: 0.30, blue: 0.33, alpha: 1)
        default: nil
        }
    }

    /// The style's paragraph attributes on top of `base`, keeping what the style doesn't
    /// own (alignment, lists, table cells) so restyling a centered list item keeps both.
    func paragraphStyle(base: NSParagraphStyle?) -> NSParagraphStyle {
        let p = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        p.headerLevel = headerLevel
        switch self {
        case .title:
            p.paragraphSpacingBefore = 0; p.paragraphSpacing = 12; p.lineHeightMultiple = 1
        case .heading1:
            p.paragraphSpacingBefore = 18; p.paragraphSpacing = 6; p.lineHeightMultiple = 1
        case .heading2, .heading3:
            p.paragraphSpacingBefore = 12; p.paragraphSpacing = 4; p.lineHeightMultiple = 1
        case .body, .caption:
            p.paragraphSpacingBefore = 0; p.paragraphSpacing = 6
            if p.lineHeightMultiple == 0 { p.lineHeightMultiple = 1.15 }
        case .quote:
            p.paragraphSpacingBefore = 6; p.paragraphSpacing = 6
            p.headIndent = 24; p.firstLineHeadIndent = 24
        case .code:
            p.paragraphSpacingBefore = 0; p.paragraphSpacing = 0; p.lineHeightMultiple = 1
        }
        if self != .quote, base?.headIndent == 24, base?.firstLineHeadIndent == 24, base?.textLists.isEmpty ?? true {
            // Leaving Quote: drop its indent rather than keeping a stray one.
            p.headIndent = 0; p.firstLineHeadIndent = 0
        }
        return p
    }

    /// Typing attributes for a fresh paragraph in this style.
    func attributes(base: NSParagraphStyle? = nil) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraphStyle(base: base)]
        if let color { a[.foregroundColor] = color }
        return a
    }

    /// Applies the style to every paragraph that intersects `range`. Links and
    /// attachments are kept; other character formatting is reset, as in Pages.
    static func apply(_ style: TextStyle, to text: NSMutableAttributedString, paragraphsIn range: NSRange) {
        let ns = text.string as NSString
        let paragraphs = ns.paragraphRange(for: range)
        text.beginEditing()
        var location = paragraphs.location
        while location < NSMaxRange(paragraphs) {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let base = text.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
            text.addAttribute(.paragraphStyle, value: style.paragraphStyle(base: base), range: para)
            text.addAttribute(.font, value: style.font, range: para)
            if let color = style.color {
                text.addAttribute(.foregroundColor, value: color, range: para)
            } else {
                text.removeAttribute(.foregroundColor, range: para)
            }
            location = NSMaxRange(para)
            if para.length == 0 { break }
        }
        text.endEditing()
    }

    /// Best guess of the style a paragraph is in, for the style menu and the outline.
    ///
    /// Folio's own styles match exactly by size and weight. Files from elsewhere are
    /// matched by `headerLevel` (HTML, Word headings), then by "big and bold".
    static func detect(font: NSFont?, paragraph: NSParagraphStyle?) -> TextStyle {
        if let font {
            let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
            let italic = font.fontDescriptor.symbolicTraits.contains(.italic)
            let size = font.pointSize
            if font.isFixedPitch || font.fontName.hasPrefix("Menlo") || font.fontName.hasPrefix("Courier") { return .code }
            for style in [TextStyle.title, .heading1, .heading2] where abs(style.font.pointSize - size) < 0.5 && bold {
                return style
            }
            if abs(size - 13) < 0.5, font.fontName.contains("Medium") || bold { return .heading3 }
            if let level = paragraph?.headerLevel, level > 0 {
                return [.heading1, .heading2, .heading3][min(level, 3) - 1]
            }
            if bold, size >= 24 { return .title }
            if bold, size >= 18 { return .heading1 }
            if bold, size >= 15 { return .heading2 }
            if size <= 10.5 { return .caption }
            if italic, paragraph?.headIndent ?? 0 >= 18 { return .quote }
            return .body
        }
        if let level = paragraph?.headerLevel, level > 0 { return [.heading1, .heading2, .heading3][min(level, 3) - 1] }
        return .body
    }

    private static func font(_ name: String, _ size: CGFloat) -> NSFont {
        NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
    }
}

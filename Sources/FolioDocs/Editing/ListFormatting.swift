public import AppKit

/// Bulleted, numbered and checklist paragraphs, built on `NSTextList` so every format
/// the Cocoa text system writes (RTF, ODT, HTML, Word) carries them as real lists.
public nonisolated enum ListKind: String, CaseIterable, Sendable {
    case bullet, numbered, checklist

    public var title: String {
        switch self {
        case .bullet: "Bulleted List"
        case .numbered: "Numbered List"
        case .checklist: "Checklist"
        }
    }

    public var symbol: String {
        switch self {
        case .bullet: "list.bullet"
        case .numbered: "list.number"
        case .checklist: "checklist"
        }
    }

    var markerFormat: NSTextList.MarkerFormat {
        switch self {
        case .bullet: .disc
        case .numbered: .decimal
        case .checklist: .box
        }
    }

    /// The list kind of a paragraph, from its innermost list.
    static func of(_ paragraph: NSParagraphStyle?) -> ListKind? {
        guard let list = paragraph?.textLists.last else { return nil }
        switch list.markerFormat {
        case .box, .check: return .checklist
        default: return list.isOrdered ? .numbered : .bullet
        }
    }
}

/// Pure list editing on attributed strings. The editor feeds it the selected paragraphs
/// and replaces them with the result in one undoable change.
nonisolated enum ListFormatting {
    /// Indent of one list level, in points (Cocoa's and Word's default).
    static let indent: CGFloat = 36

    /// Whether list markers ("\t•\t") are part of the text.
    ///
    /// Up to macOS 15 the text system stores markers as characters. From macOS 26 it
    /// doesn't (`NSTextList.includesTextListMarkers` is false) and readers return the
    /// bare item text, so Folio draws markers itself (`MarkerLayoutManager`).
    static var markersInContent: Bool {
        if #available(macOS 26, *) { return NSTextList.includesTextListMarkers }
        return true
    }

    /// Turns every paragraph of `fragment` into an item of a new `kind` list, or removes
    /// the list when every paragraph is already that kind (toolbar toggle behavior).
    /// `fragment` must start and end on paragraph boundaries.
    static func toggle(_ kind: ListKind, in fragment: NSAttributedString) -> NSAttributedString {
        let paragraphs = paragraphRanges(in: fragment.string as NSString)
        let allSame =
            !paragraphs.isEmpty
            && paragraphs.allSatisfy { range in
                ListKind.of(fragment.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle) == kind
            }
        let list = NSTextList(markerFormat: kind.markerFormat, options: 0)
        let out = NSMutableAttributedString()
        for (index, range) in paragraphs.enumerated() {
            let para = NSMutableAttributedString(attributedString: fragment.attributedSubstring(from: range))
            stripMarker(from: para)
            let base = para.length > 0 ? para.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
            let style = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            if allSame {
                style.textLists = []
                style.headIndent = 0
                style.firstLineHeadIndent = 0
                style.tabStops = NSParagraphStyle.default.tabStops
            } else {
                configure(style, list: list)
                if markersInContent {
                    let attrs = para.length > 0 ? para.attributes(at: 0, effectiveRange: nil) : [:]
                    para.insert(NSAttributedString(string: "\t\(list.marker(forItemNumber: index + 1))\t", attributes: attrs), at: 0)
                }
            }
            para.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: para.length))
            out.append(para)
        }
        return out
    }

    /// Gives every imported list item room for its marker.
    ///
    /// RTF and Word files written elsewhere often give list items a first-line indent of
    /// 0, because older text systems kept the marker ("•", "1.") as characters at the
    /// start of the line. From macOS 26 the reader drops those characters, so the first
    /// line would start flush left and `MarkerLayoutManager` would have nowhere to draw
    /// the marker (it would land outside the text view and be clipped). This applies the
    /// same hanging indent Folio uses for its own lists: the marker sits in the indent.
    static func normalizeImportedLists(in text: NSMutableAttributedString) {
        guard !markersInContent, text.length > 0 else { return }
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle, !style.textLists.isEmpty else { return }
            let level = CGFloat(style.textLists.count - 1)
            let needed = max(style.headIndent, indent * (level + 1))
            guard style.firstLineHeadIndent < needed - 0.5 || style.headIndent < needed - 0.5 else { return }
            let fixed = style.mutableCopy() as! NSMutableParagraphStyle  // NSParagraphStyle always copies to its mutable subclass
            fixed.headIndent = needed
            fixed.firstLineHeadIndent = needed
            text.addAttribute(.paragraphStyle, value: fixed, range: range)
        }
    }

    /// Sets the indent and tab stops a one-level list item needs.
    static func configure(_ style: NSMutableParagraphStyle, list: NSTextList) {
        style.textLists = [list]
        style.headIndent = indent
        style.firstLineHeadIndent = markersInContent ? 0 : indent
        style.tabStops = [NSTextTab(textAlignment: .left, location: 11), NSTextTab(textAlignment: .left, location: indent)]
    }

    /// Removes a leading "\t<marker>\t" from a list paragraph, when markers are text.
    static func stripMarker(from para: NSMutableAttributedString) {
        let n = markerLength(
            in: para.string as NSString, at: 0,
            isList: para.length > 0
                && !((para.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.textLists.isEmpty ?? true))
        if n > 0 { para.deleteCharacters(in: NSRange(location: 0, length: n)) }
    }

    /// Length of the marker text at the start of a list paragraph ("\t1.\t" → 4), or 0.
    static func markerLength(in string: NSString, at start: Int, isList: Bool) -> Int {
        guard isList, start < string.length, string.character(at: start) == 9 else { return 0 }
        var i = start + 1
        while i < string.length, i - start < 12 {
            let c = string.character(at: i)
            if c == 9 { return i - start + 1 }
            if c == 10 || c == 13 { return 0 }
            i += 1
        }
        return 0
    }

    /// The 1-based number of the list item starting at `paragraphStart`: how many
    /// paragraphs before it, without a gap, belong to the same list.
    static func itemNumber(at paragraphStart: Int, in text: NSAttributedString) -> Int {
        guard let list = (text.attribute(.paragraphStyle, at: paragraphStart, effectiveRange: nil) as? NSParagraphStyle)?.textLists.last
        else { return 1 }
        let ns = text.string as NSString
        var count = 0
        var start = paragraphStart
        while start > 0 {
            let previous = ns.paragraphRange(for: NSRange(location: start - 1, length: 0))
            let lists = (text.attribute(.paragraphStyle, at: previous.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists ?? []
            guard lists.contains(where: { $0 === list }) else { break }
            if lists.last === list { count += 1 }
            start = previous.location
        }
        return list.startingItemNumber + count
    }

    /// Flips a checklist item between unchecked (box) and checked. Returns the new
    /// paragraph style, or `nil` if the paragraph isn't a checklist item.
    static func toggledCheck(_ style: NSParagraphStyle?) -> NSParagraphStyle? {
        guard let style, let list = style.textLists.last, ListKind.of(style) == .checklist,
            let copy = style.mutableCopy() as? NSMutableParagraphStyle
        else { return nil }
        let next = NSTextList(markerFormat: list.markerFormat == .check ? .box : .check, options: 0)
        copy.textLists = Array(style.textLists.dropLast()) + [next]
        return copy
    }

    /// Shifts paragraph indents by one level (`delta` = +1 indent, -1 outdent), never below 0.
    static func indent(_ style: NSParagraphStyle?, by delta: Int) -> NSParagraphStyle {
        let p = (style?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        let shift = indent * CGFloat(delta)
        let newHead = max(0, p.headIndent + shift)
        let applied = newHead - p.headIndent
        p.headIndent = newHead
        p.firstLineHeadIndent = max(0, p.firstLineHeadIndent + applied)
        if !p.textLists.isEmpty {
            p.tabStops = p.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: max(0, $0.location + applied)) }
        }
        return p
    }

    /// Paragraph ranges of a string, including each paragraph's terminator.
    static func paragraphRanges(in string: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(range)
            location = NSMaxRange(range)
        }
        if string.length == 0 { ranges.append(NSRange(location: 0, length: 0)) }
        return ranges
    }
}

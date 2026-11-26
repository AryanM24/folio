import AppKit

/// Restores what the system Word reader drops: paragraph styles, list numbering
/// formats and hyperlinks.
///
/// `NSAttributedString`'s Word reader applies only direct formatting (a "Heading 1"
/// whose size comes from `styles.xml` opens as 12 pt Times and the outline finds
/// nothing), reads every list as bullets (numbered lists lose their numbers), and
/// drops `w:hyperlink` targets. This pass reads `document.xml`, `styles.xml`,
/// `numbering.xml` and the relationships, then fills those back in.
///
/// It only runs when its paragraph count matches the reader's, so documents it
/// doesn't understand (text boxes, tracked deletions) open exactly as the reader
/// produced them.
nonisolated enum DocxStyles {
    /// Run formatting a paragraph style contributes, after following `basedOn`.
    struct Style {
        var basedOn: String?
        var name: String?
        var family: String?
        var halfPoints: Int?
        var bold: Bool?
        var italic: Bool?
        var color: String?
        var outlineLevel: Int?
    }

    /// What `document.xml` says about one paragraph.
    struct Paragraph {
        var style: String?
        var numID: String?
        var level = 0
        /// Hyperlinked text in order, with its relationship id.
        var links: [(text: String, id: String)] = []
    }

    /// One list level from `numbering.xml`.
    struct Level {
        var format = "bullet"
        var text = "•"
        var start = 1
    }

    /// Applies styles, list formats and links from the package to `text`, which the
    /// system reader made from the same `docx` bytes.
    static func apply(docx: Data, to text: NSMutableAttributedString) {
        guard let documentXML = ZipArchive.read("word/document.xml", from: docx) else { return }
        let styles = ZipArchive.read("word/styles.xml", from: docx).map(StyleTableParser.parse) ?? (defaults: Style(), styles: [:])
        let numbering = ZipArchive.read("word/numbering.xml", from: docx).map(NumberingParser.parse) ?? [:]
        let links = ZipArchive.read("word/_rels/document.xml.rels", from: docx).map(RelationshipParser.parse) ?? [:]
        let paragraphs = ParagraphParser.parse(documentXML)
        let ranges = ListFormatting.paragraphRanges(in: text.string as NSString)
        guard ranges.count == paragraphs.count || ranges.count == paragraphs.count + 1 else { return }

        text.beginEditing()
        defer { text.endEditing() }
        var lists: [String: NSTextList] = [:]
        for (range, paragraph) in zip(ranges, paragraphs) where range.length > 0 {
            var style = resolve(paragraph.style ?? "Normal", in: styles.styles)
            style.family = style.family ?? styles.defaults.family
            style.halfPoints = style.halfPoints ?? styles.defaults.halfPoints
            apply(style, to: text, range: range)
            if let id = paragraph.numID, id != "0", let levels = numbering[id] {
                applyList(id: id, level: paragraph.level, levels: levels, cache: &lists, to: text, range: range)
            }
            applyLinks(paragraph.links, targets: links, to: text, range: range)
        }
    }

    private static func resolve(_ id: String, in styles: [String: Style], depth: Int = 0) -> Style {
        guard var style = styles[id] else { return Style() }
        if let parent = style.basedOn, depth < 8 {
            let base = resolve(parent, in: styles, depth: depth + 1)
            style.family = style.family ?? base.family
            style.halfPoints = style.halfPoints ?? base.halfPoints
            style.bold = style.bold ?? base.bold
            style.italic = style.italic ?? base.italic
            style.color = style.color ?? base.color
        }
        if style.outlineLevel == nil, let name = style.name?.lowercased() {
            if name.hasPrefix("heading "), let n = Int(name.dropFirst(8)) { style.outlineLevel = n - 1 }
        }
        return style
    }

    private static func apply(_ style: Style, to text: NSMutableAttributedString, range: NSRange) {
        text.enumerateAttribute(.font, in: range) { value, run, _ in
            let current = value as? NSFont
            // The reader's stand-in when a run has no font of its own is Times 12.
            var font = current ?? NSFont(name: "Times-Roman", size: 12) ?? .systemFont(ofSize: 12)
            if font.familyName == "Times", let family = style.family { font = font.withFamily(family) }
            if abs(font.pointSize - 12) < 0.01, let half = style.halfPoints, half != 24 { font = font.withSize(CGFloat(half) / 2) }
            if style.bold == true { font = font.adding(.bold) }
            if style.italic == true { font = font.adding(.italic) }
            if font != current { text.addAttribute(.font, value: font, range: run) }
        }
        if let hex = style.color, let rgb = UInt32(hex, radix: 16) {
            let color = NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
            text.enumerateAttribute(.foregroundColor, in: range) { value, run, _ in
                if value == nil { text.addAttribute(.foregroundColor, value: color, range: run) }
            }
        }
        if let level = style.outlineLevel, (0...5).contains(level) {
            updateParagraphStyle(of: text, range: range) { $0.headerLevel = level + 1 }
        }
    }

    /// Gives the paragraph the list format its `w:numPr` names. One `NSTextList` per
    /// list and level, shared by its paragraphs, so numbering continues across items.
    private static func applyList(
        id: String, level: Int, levels: [Int: Level], cache: inout [String: NSTextList],
        to text: NSMutableAttributedString, range: NSRange
    ) {
        var chain: [NSTextList] = []
        for l in 0...max(0, min(level, 8)) {
            let key = "\(id).\(l)"
            if cache[key] == nil {
                let spec = levels[l] ?? Level()
                let list = NSTextList(markerFormat: markerFormat(spec), options: 0)
                list.startingItemNumber = spec.start
                cache[key] = list
            }
            if let list = cache[key] { chain.append(list) }
        }
        updateParagraphStyle(of: text, range: range) { $0.textLists = chain }
    }

    static func markerFormat(_ level: Level) -> NSTextList.MarkerFormat {
        switch level.format {
        case "decimal", "decimalZero": .decimal
        case "lowerLetter": .lowercaseAlpha
        case "upperLetter": .uppercaseAlpha
        case "lowerRoman": .lowercaseRoman
        case "upperRoman": .uppercaseRoman
        default:
            switch level.text {
            case "☐", "□", "❑": .box
            case "☑", "☒", "✓", "✔": .check
            case "–", "-", "—": .hyphen
            case "◦", "○", "o": .circle
            case "▪", "■", "§": .square
            default: .disc
            }
        }
    }

    private static func applyLinks(
        _ links: [(text: String, id: String)], targets: [String: String],
        to text: NSMutableAttributedString, range: NSRange
    ) {
        let ns = text.string as NSString
        var search = range
        for link in links where !link.text.isEmpty {
            guard let target = targets[link.id], let url = URL(string: target) else { continue }
            let found = ns.range(of: link.text, options: .literal, range: search)
            guard found.location != NSNotFound else { continue }
            text.addAttribute(.link, value: url, range: found)
            search = NSRange(location: NSMaxRange(found), length: NSMaxRange(range) - NSMaxRange(found))
        }
    }

    private static func updateParagraphStyle(
        of text: NSMutableAttributedString, range: NSRange, _ change: (NSMutableParagraphStyle) -> Void
    ) {
        let base = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        let p = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        change(p)
        text.addAttribute(.paragraphStyle, value: p, range: range)
    }
}

// MARK: - Parsers

/// Reads `word/styles.xml` into paragraph styles and document defaults.
private nonisolated final class StyleTableParser: NSObject, XMLParserDelegate {
    private var styles: [String: DocxStyles.Style] = [:]
    private var defaults = DocxStyles.Style()
    private var current: (id: String, style: DocxStyles.Style)?
    private var inDefaults = false

    static func parse(_ data: Data) -> (defaults: DocxStyles.Style, styles: [String: DocxStyles.Style]) {
        let delegate = StyleTableParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return (delegate.defaults, delegate.styles)
    }

    func parser(
        _ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        let value = attributes["w:val"]
        switch element {
        case "w:rPrDefault": inDefaults = true
        case "w:style":
            if attributes["w:type"] == "paragraph", let id = attributes["w:styleId"] { current = (id, DocxStyles.Style()) }
        default:
            func set(_ update: (inout DocxStyles.Style) -> Void) {
                if inDefaults {
                    update(&defaults)
                } else if var style = current {
                    update(&style.style)
                    current = style
                }
            }
            switch element {
            case "w:basedOn": set { $0.basedOn = value }
            case "w:name": set { $0.name = value }
            case "w:rFonts": set { $0.family = attributes["w:ascii"] ?? attributes["w:hAnsi"] ?? $0.family }
            case "w:sz": set { $0.halfPoints = value.flatMap(Int.init) }
            case "w:b": set { $0.bold = value != "0" && value != "false" }
            case "w:i": set { $0.italic = value != "0" && value != "false" }
            case "w:color": set { $0.color = value == "auto" ? nil : value }
            case "w:outlineLvl": set { $0.outlineLevel = value.flatMap(Int.init) }
            default: break
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "w:rPrDefault" { inDefaults = false }
        if element == "w:style", let current {
            styles[current.id] = current.style
            self.current = nil
        }
    }
}

/// Lists each body paragraph's style, list membership and links, in document order.
private nonisolated final class ParagraphParser: NSObject, XMLParserDelegate {
    private var result: [DocxStyles.Paragraph] = []
    private var current: DocxStyles.Paragraph?
    private var link: (text: String, id: String)?
    private var inText = false
    private var skipDepth = 0

    static func parse(_ data: Data) -> [DocxStyles.Paragraph] {
        let delegate = ParagraphParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.result
    }

    func parser(
        _ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        if ["w:txbxContent", "w:footnote", "w:endnote", "w:comment"].contains(element) { skipDepth += 1 }
        guard skipDepth == 0 else { return }
        switch element {
        case "w:p": current = DocxStyles.Paragraph()
        case "w:pStyle": current?.style = attributes["w:val"]
        case "w:numId": current?.numID = attributes["w:val"]
        case "w:ilvl": current?.level = attributes["w:val"].flatMap(Int.init) ?? 0
        case "w:hyperlink": if let id = attributes["r:id"] { link = ("", id) }
        case "w:t": inText = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText, link != nil { link?.text += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if ["w:txbxContent", "w:footnote", "w:endnote", "w:comment"].contains(element) { skipDepth -= 1; return }
        guard skipDepth == 0 else { return }
        switch element {
        case "w:t": inText = false
        case "w:hyperlink":
            if let link { current?.links.append(link) }
            link = nil
        case "w:p":
            if let current { result.append(current) }
            current = nil
        default: break
        }
    }
}

/// `numbering.xml`: numId → level → format.
private nonisolated final class NumberingParser: NSObject, XMLParserDelegate {
    private var abstract: [String: [Int: DocxStyles.Level]] = [:]
    private var nums: [String: String] = [:]
    private var currentAbstract: String?
    private var currentLevel: Int?
    private var currentNum: String?

    static func parse(_ data: Data) -> [String: [Int: DocxStyles.Level]] {
        let delegate = NumberingParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.nums.compactMapValues { delegate.abstract[$0] }
    }

    func parser(
        _ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        let value = attributes["w:val"]
        switch element {
        case "w:abstractNum": currentAbstract = attributes["w:abstractNumId"]
        case "w:lvl":
            currentLevel = attributes["w:ilvl"].flatMap(Int.init)
            if let a = currentAbstract, let l = currentLevel { abstract[a, default: [:]][l] = DocxStyles.Level() }
        case "w:num": currentNum = attributes["w:numId"]
        case "w:abstractNumId": if let n = currentNum, let value { nums[n] = value }
        case "w:numFmt", "w:lvlText", "w:start":
            guard let a = currentAbstract, let l = currentLevel, let value else { return }
            switch element {
            case "w:numFmt": abstract[a]?[l]?.format = value
            case "w:lvlText": abstract[a]?[l]?.text = value
            default: abstract[a]?[l]?.start = Int(value) ?? 1
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "w:abstractNum": currentAbstract = nil
        case "w:lvl": currentLevel = nil
        case "w:num": currentNum = nil
        default: break
        }
    }
}

/// `document.xml.rels`: relationship id → external link target.
private nonisolated final class RelationshipParser: NSObject, XMLParserDelegate {
    private var targets: [String: String] = [:]

    static func parse(_ data: Data) -> [String: String] {
        let delegate = RelationshipParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.targets
    }

    func parser(
        _ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        guard element == "Relationship", attributes["Type"]?.hasSuffix("/hyperlink") == true,
            let id = attributes["Id"], let target = attributes["Target"]
        else { return }
        targets[id] = target
    }
}

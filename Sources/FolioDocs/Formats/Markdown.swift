public import AppKit

/// Markdown export and import.
///
/// The Cocoa text system has no Markdown writer, so export walks paragraphs and maps
/// Folio's styles to CommonMark (plus GitHub tables, task lists and strikethrough).
/// Import handles the block structure itself and leaves inline syntax (emphasis,
/// links, code spans) to Foundation's Markdown parser.
public nonisolated enum Markdown {

    // MARK: Export

    /// CommonMark/GFM for an attributed string.
    public static func string(from text: NSAttributedString) -> String {
        let ns = text.string as NSString
        var blocks: [String] = []
        var codeLines: [String] = []
        func flushCode() {
            guard !codeLines.isEmpty else { return }
            blocks.append("```\n" + codeLines.joined(separator: "\n") + "\n```")
            codeLines = []
        }
        var location = 0
        var previousWasListItem = false
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let para = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle

            if para?.textBlocks.contains(where: { $0 is NSTextTableBlock }) == true,
                let (table, tableRange) = TableModel.read(from: text, at: range.location)
            {
                flushCode()
                blocks.append(tableMarkdown(table))
                location = NSMaxRange(tableRange)
                previousWasListItem = false
                continue
            }
            location = NSMaxRange(range)

            let content = trimmedContent(of: range, in: ns)
            let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let style = TextStyle.detect(font: font, paragraph: para)

            if style == .code {
                codeLines.append(ns.substring(with: content))
                continue
            }
            flushCode()

            if isRule(para, content: content) {
                blocks.append("---")
                previousWasListItem = false
                continue
            }
            if content.length == 0 { previousWasListItem = false; continue }

            var line = inline(text, in: content, quote: style == .quote)
            if let kind = ListKind.of(para) {
                let depth = max(0, (para?.textLists.count ?? 1) - 1)
                let number = ListFormatting.itemNumber(at: range.location, in: text)
                let checked = para?.textLists.last?.markerFormat == .check
                let marker =
                    switch kind {
                    case .bullet: "- "
                    case .numbered: "\(number). "
                    case .checklist: checked ? "- [x] " : "- [ ] "
                    }
                line = String(repeating: "    ", count: depth) + marker + line
                if previousWasListItem, let last = blocks.popLast() {
                    blocks.append(last + "\n" + line)
                } else {
                    blocks.append(line)
                }
                previousWasListItem = true
                continue
            }
            previousWasListItem = false
            switch style {
            case .title, .heading1: line = "# " + line
            case .heading2: line = "## " + line
            case .heading3: line = "### " + line
            case .quote: line = "> " + line
            default: break
            }
            blocks.append(line)
        }
        flushCode()
        return blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
    }

    /// Paragraph content without its terminator, list marker text or page breaks.
    private static func trimmedContent(of range: NSRange, in ns: NSString) -> NSRange {
        var r = range
        while r.length > 0, [10, 13, 0x0C, 0x2029].contains(ns.character(at: NSMaxRange(r) - 1)) { r.length -= 1 }
        let marker = ListFormatting.markersInContent ? ListFormatting.markerLength(in: ns, at: r.location, isList: true) : 0
        if marker > 0, marker <= r.length, ns.character(at: r.location) == 9 {
            r.location += marker; r.length -= marker
        }
        return r
    }

    /// A horizontal rule is an empty paragraph whose block draws only a bottom border.
    static func isRule(_ para: NSParagraphStyle?, content: NSRange) -> Bool {
        guard content.length == 0, let block = para?.textBlocks.last, !(block is NSTextTableBlock) else { return false }
        return block.width(for: .border, edge: .maxY) > 0
    }

    /// Inline Markdown for a range: emphasis, strikethrough, code spans and links.
    static func inline(_ text: NSAttributedString, in range: NSRange, quote: Bool = false) -> String {
        var out = ""
        text.enumerateAttributes(in: range) { attrs, run, _ in
            var s = (text.string as NSString).substring(with: run)
            if attrs[.attachment] != nil { return }
            s = s.replacingOccurrences(of: "\u{2028}", with: "  \n").replacingOccurrences(of: "\u{0C}", with: "")
            let font = attrs[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let code = font.map { $0.isFixedPitch || $0.fontName.hasPrefix("Menlo") } ?? false
            if code {
                s = "`" + s + "`"
            } else {
                s = escape(s)
                var wrap = ""
                if traits.contains(.bold), TextStyle.detect(font: font, paragraph: nil).outlineLevel == nil { wrap += "**" }
                if traits.contains(.italic), !quote { wrap += "*" }
                if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { wrap += "~~" }
                s = wrapKeepingWhitespace(s, with: wrap)
            }
            if let link = attrs[.link] {
                let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                s = "[\(s)](\(url))"
            }
            out += s
        }
        return out
    }

    private static func wrapKeepingWhitespace(_ s: String, with marker: String) -> String {
        guard !marker.isEmpty else { return s }
        let core = s.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return s }
        let lead = String(s.prefix { $0 == " " || $0 == "\t" })
        let trail = String(s.reversed().prefix { $0 == " " || $0 == "\t" })
        return lead + marker + core + String(marker.reversed()) + trail
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\*_`[]".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    private static func tableMarkdown(_ table: TableModel) -> String {
        func cellText(_ cell: NSAttributedString) -> String {
            inline(cell, in: NSRange(location: 0, length: cell.length))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "|", with: "\\|")
        }
        var lines = table.cells.map { "| " + $0.map(cellText).joined(separator: " | ") + " |" }
        lines.insert("|" + String(repeating: " --- |", count: table.columnCount), at: 1)
        return lines.joined(separator: "\n")
    }

    // MARK: Import

    /// Attributed text for Markdown, styled with Folio's paragraph styles.
    public static func attributedString(from markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var paragraph: [String] = []
        var inCode = false
        var lists: [ListKind: NSTextList] = [:]

        func emit(_ text: String, style: TextStyle, list: (ListKind, Bool)? = nil) {
            let line =
                style == .code ? NSAttributedString(string: text, attributes: style.attributes()) : inlineAttributed(text, style: style)
            let p = NSMutableAttributedString(attributedString: line)
            p.append(NSAttributedString(string: "\n", attributes: style.attributes()))
            var paraStyle = style.paragraphStyle(base: nil)
            if let (kind, checked) = list {
                let textList: NSTextList
                if kind == .checklist {
                    textList = NSTextList(markerFormat: checked ? .check : .box, options: 0)
                } else {
                    textList = lists[kind] ?? NSTextList(markerFormat: kind.markerFormat, options: 0)
                    lists[kind] = textList
                }
                let mutable = (paraStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                ListFormatting.configure(mutable, list: textList)
                paraStyle = mutable
                if ListFormatting.markersInContent {
                    let number = kind == .numbered ? ListFormatting.itemNumber(at: max(0, out.length - 1), in: out) + 1 : 1
                    p.insert(
                        NSAttributedString(string: "\t\(textList.marker(forItemNumber: number))\t", attributes: style.attributes()), at: 0)
                }
            } else {
                lists.removeAll()
            }
            p.addAttribute(.paragraphStyle, value: paraStyle, range: NSRange(location: 0, length: p.length))
            out.append(p)
        }
        func flush() {
            guard !paragraph.isEmpty else { return }
            emit(paragraph.joined(separator: " "), style: .body)
            paragraph = []
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { flush(); inCode.toggle(); continue }
            if inCode { emit(raw, style: .code); continue }
            if line.isEmpty { flush(); lists.removeAll(); continue }
            if let (level, title) = heading(line) {
                flush()
                emit(title, style: [.heading1, .heading2, .heading3][min(level, 3) - 1])
            } else if line == "---" || line == "***" || line == "___" {
                flush()
            } else if let rest = line.stripping(prefixes: ["- [ ] ", "* [ ] "]) {
                flush(); emit(rest, style: .body, list: (.checklist, false))
            } else if let rest = line.stripping(prefixes: ["- [x] ", "- [X] ", "* [x] "]) {
                flush(); emit(rest, style: .body, list: (.checklist, true))
            } else if let rest = line.stripping(prefixes: ["- ", "* ", "+ "]) {
                flush(); emit(rest, style: .body, list: (.bullet, false))
            } else if let rest = numbered(line) {
                flush(); emit(rest, style: .body, list: (.numbered, false))
            } else if let rest = line.stripping(prefixes: ["> ", ">"]) {
                flush(); emit(rest, style: .quote)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return out
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func numbered(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return String(line.dropFirst(digits.count + 2))
    }

    /// Inline Markdown → attributed text in `style`, mapping emphasis to font traits.
    private static func inlineAttributed(_ text: String, style: TextStyle) -> NSAttributedString {
        let base = style.attributes()
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var attrs = base
            let intent = run.inlinePresentationIntent ?? []
            var font = style.font
            if intent.contains(.code) { font = TextStyle.code.font }
            if intent.contains(.stronglyEmphasized) { font = font.adding(.bold) }
            if intent.contains(.emphasized) { font = font.adding(.italic) }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            attrs[.font] = font
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return out
    }
}

private nonisolated extension String {
    func stripping(prefixes: [String]) -> String? {
        for p in prefixes where hasPrefix(p) { return String(dropFirst(p.count)) }
        return nil
    }
}

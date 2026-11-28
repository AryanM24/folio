import Foundation

/// GitHub-flavored Markdown to sanitized HTML.
///
/// Covers what people actually write in READMEs and notes: ATX and setext headings,
/// paragraphs, emphasis, strikethrough, code spans and fenced/indented code (syntax colored
/// with the editor's own lexers), block quotes, nested ordered/unordered/task lists, tables
/// with alignment, rules, inline and reference links, images, autolinks and hard breaks.
///
/// Safety: raw HTML is never passed through — it's escaped and shown as text — and link
/// and image URLs are limited to http(s), mailto, relative paths and data: images, so a
/// Markdown file can't run script or reach `javascript:` / `file:` URLs in the preview.
///
/// Top-level blocks carry `data-line` (zero-based source line) for editor → preview scroll sync.
public nonisolated struct MarkdownRenderer {
    struct Reference: Sendable { var url: String; var title: String? }
    var references: [String: Reference] = [:]

    /// Renders a whole document to an HTML fragment (no `<html>` wrapper).
    public static func render(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        var renderer = MarkdownRenderer()
        renderer.collectReferences(&lines)
        var out = ""
        renderer.blocks(lines[...], top: true, tight: false, into: &out)
        return out
    }

    // MARK: Reference definitions

    /// Pulls `[label]: url "title"` lines out of the document (outside code fences), leaving
    /// blank lines so `data-line` numbers stay correct.
    private mutating func collectReferences(_ lines: inout [String]) {
        var fence: Character?
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if let f = fence {
                if trimmed.hasPrefix(String(repeating: f, count: 3)) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence = trimmed.first; continue }
            guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]"),
                trimmed.index(after: close) < trimmed.endIndex, trimmed[trimmed.index(after: close)] == ":"
            else { continue }
            let label = Self.normalize(String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]))
            guard !label.isEmpty, !label.hasPrefix("^") else { continue }
            var rest = trimmed[trimmed.index(close, offsetBy: 2)...].trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { continue }
            let url: String
            if rest.hasPrefix("<"), let end = rest.firstIndex(of: ">") {
                url = String(rest[rest.index(after: rest.startIndex)..<end])
                rest = String(rest[rest.index(after: end)...])
            } else {
                let end = rest.firstIndex(of: " ") ?? rest.endIndex
                url = String(rest[..<end])
                rest = String(rest[end...])
            }
            var title: String?
            let t = rest.trimmingCharacters(in: .whitespaces)
            if t.count >= 2, let first = t.first, "\"'(".contains(first) { title = String(t.dropFirst().dropLast()) }
            if references[label] == nil { references[label] = Reference(url: url, title: title) }
            lines[index] = ""
        }
    }

    static func normalize(_ label: String) -> String {
        label.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Blocks

    private func blocks(_ lines: ArraySlice<String>, top: Bool, tight: Bool, into out: inout String) {
        var i = lines.startIndex
        func attr(_ index: Int) -> String { top ? " data-line=\"\(index)\"" : "" }

        while i < lines.endIndex {
            let line = lines[i]
            if Self.isBlank(line) { i += 1; continue }

            if let fence = Self.fence(line) {
                var j = i + 1
                var code: [String] = []
                while j < lines.endIndex {
                    if let close = Self.fence(lines[j]), close.char == fence.char, close.count >= fence.count, close.info.isEmpty {
                        j += 1; break
                    }
                    code.append(Self.dropIndent(lines[j], upTo: fence.indent))
                    j += 1
                }
                let language = Language(fenceName: fence.info.split(separator: " ").first.map(String.init) ?? "")
                let classAttr = fence.info.isEmpty ? "" : " class=\"language-\(Self.escape(String(fence.info.split(separator: " ")[0])))\""
                out +=
                    "<pre\(attr(i))><code\(classAttr)>\(CodeHighlighter.html(code.joined(separator: "\n"), language: language))</code></pre>\n"
                i = j
                continue
            }

            if let (level, text) = Self.atxHeading(line) {
                out += "<h\(level)\(attr(i)) id=\"\(Self.slug(text))\">\(inline(text))</h\(level)>\n"
                i += 1
                continue
            }

            if Self.isThematicBreak(line) {
                out += "<hr\(attr(i))>\n"
                i += 1
                continue
            }

            if Self.quoteContent(line) != nil {
                var inner: [String] = []
                var j = i
                while j < lines.endIndex {
                    if let content = Self.quoteContent(lines[j]) {
                        inner.append(content)
                    } else if !Self.isBlank(lines[j]), !inner.isEmpty, !Self.isBlank(inner[inner.count - 1]), !startsBlock(lines[j]) {
                        inner.append(lines[j])  // Lazy continuation of a quoted paragraph.
                    } else {
                        break
                    }
                    j += 1
                }
                out += "<blockquote\(attr(i))>\n"
                blocks(inner[...], top: false, tight: false, into: &out)
                out += "</blockquote>\n"
                i = j
                continue
            }

            if let marker = Self.listMarker(line) {
                i = list(lines, from: i, first: marker, attr: attr(i), into: &out)
                continue
            }

            if i + 1 < lines.endIndex, line.contains("|"), let aligns = Self.tableAlignments(lines[i + 1]) {
                let header = Self.cells(line)
                if header.count == aligns.count {
                    i = table(lines, from: i, header: header, aligns: aligns, attr: attr(i), into: &out)
                    continue
                }
            }

            if Self.indentWidth(line) >= 4 {
                var code: [String] = []
                var j = i
                while j < lines.endIndex, Self.isBlank(lines[j]) || Self.indentWidth(lines[j]) >= 4 {
                    code.append(Self.dropIndent(lines[j], upTo: 4))
                    j += 1
                }
                while let last = code.last, Self.isBlank(last) { code.removeLast(); j -= 1 }
                out += "<pre\(attr(i))><code>\(Self.escape(code.joined(separator: "\n")))</code></pre>\n"
                i = j
                continue
            }

            // Paragraph, possibly a setext heading.
            var text: [String] = [String(line.drop { $0 == " " || $0 == "\t" })]
            var j = i + 1
            var heading: Int?
            while j < lines.endIndex, !Self.isBlank(lines[j]) {
                let next = lines[j].trimmingCharacters(in: .whitespaces)
                if !next.isEmpty, next.allSatisfy({ $0 == "=" }) { heading = 1; j += 1; break }
                if next.count >= 2, next.allSatisfy({ $0 == "-" }) { heading = 2; j += 1; break }
                if startsBlock(lines[j]) { break }
                // Keep trailing spaces for hard breaks; drop leading indentation.
                text.append(String(lines[j].drop { $0 == " " || $0 == "\t" }))
                j += 1
            }
            let body = inline(text.joined(separator: "\n"))
            if let heading {
                out += "<h\(heading)\(attr(i)) id=\"\(Self.slug(text.joined(separator: " ")))\">\(body)</h\(heading)>\n"
            } else if tight {
                out += body + "\n"
            } else {
                out += "<p\(attr(i))>\(body)</p>\n"
            }
            i = j
        }
    }

    /// Whether `line` starts a block that can interrupt a paragraph.
    private func startsBlock(_ line: String) -> Bool {
        if Self.fence(line) != nil || Self.atxHeading(line) != nil || Self.isThematicBreak(line) || Self.quoteContent(line) != nil {
            return true
        }
        if let marker = Self.listMarker(line) { return !marker.ordered || marker.start == 1 }
        return false
    }

    // MARK: Lists

    private func list(_ lines: ArraySlice<String>, from start: Int, first: ListMarker, attr: String, into out: inout String) -> Int {
        var items: [[String]] = []
        var loose = false
        var i = start
        var marker = first
        var sawBlank = false
        while i < lines.endIndex {
            // One item: its first line, then indented continuation lines.
            var item = [marker.content]
            i += 1
            while i < lines.endIndex {
                let line = lines[i]
                if Self.isBlank(line) {
                    item.append("")
                    i += 1
                    continue
                }
                if Self.indentWidth(line) >= marker.contentIndent {
                    if item.last == "" { sawBlank = true }
                    item.append(Self.dropIndent(line, upTo: marker.contentIndent))
                    i += 1
                    continue
                }
                if item.last != "", Self.listMarker(line) == nil, !startsBlock(line), Self.tableAlignments(line) == nil {
                    item.append(line.trimmingCharacters(in: .whitespaces))  // Lazy continuation.
                    i += 1
                    continue
                }
                break
            }
            // Blank lines at the end of an item belong between items.
            var trailingBlank = false
            while item.count > 1, item.last == "" { item.removeLast(); trailingBlank = true }
            if sawBlank { loose = true }
            sawBlank = false
            items.append(item)
            guard i < lines.endIndex, let next = Self.listMarker(lines[i]), next.ordered == first.ordered, next.bullet == first.bullet
            else { break }
            if trailingBlank { loose = true }
            marker = next
        }
        let tag = first.ordered ? "ol" : "ul"
        let startAttr = first.ordered && first.start != 1 ? " start=\"\(first.start)\"" : ""
        let hasTasks = items.contains { Self.taskState($0[0]) != nil }
        out += "<\(tag)\(attr)\(startAttr)\(hasTasks ? " class=\"contains-task-list\"" : "")>\n"
        for var item in items {
            var prefix = ""
            if let checked = Self.taskState(item[0]) {
                prefix = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                item[0] = String(item[0].dropFirst(4))
            }
            out += hasTasks && !prefix.isEmpty ? "<li class=\"task-list-item\">" : "<li>"
            out += prefix
            var body = ""
            blocks(item[...], top: false, tight: !loose, into: &body)
            if !loose, body.hasSuffix("\n") { body.removeLast() }
            out += body + "</li>\n"
        }
        out += "</\(tag)>\n"
        return i
    }

    private static func taskState(_ content: String) -> Bool? {
        if content.hasPrefix("[ ] ") || content == "[ ]" { return false }
        if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") || content == "[x]" { return true }
        return nil
    }

    // MARK: Tables

    private func table(
        _ lines: ArraySlice<String>, from start: Int, header: [String], aligns: [String?], attr: String, into out: inout String
    ) -> Int {
        func row(_ cells: [String], tag: String) -> String {
            var html = "<tr>"
            for (index, align) in aligns.enumerated() {
                let cell = index < cells.count ? cells[index] : ""
                html += "<\(tag)\(align.map { " style=\"text-align: \($0)\"" } ?? "")>\(inline(cell))</\(tag)>"
            }
            return html + "</tr>\n"
        }
        out += "<table\(attr)>\n<thead>\n" + row(header, tag: "th") + "</thead>\n"
        var i = start + 2
        var body = ""
        while i < lines.endIndex, !Self.isBlank(lines[i]), lines[i].contains("|"), !startsBlock(lines[i]) {
            body += row(Self.cells(lines[i]), tag: "td")
            i += 1
        }
        if !body.isEmpty { out += "<tbody>\n" + body + "</tbody>\n" }
        out += "</table>\n"
        return i
    }

    /// `| :--- | :---: | ---: |` → alignments, or `nil` if this isn't a delimiter row.
    static func tableAlignments(_ line: String) -> [String?]? {
        guard line.contains("-") else { return nil }
        let cells = cells(line)
        guard !cells.isEmpty else { return nil }
        var result: [String?] = []
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty, c.allSatisfy({ $0 == "-" || $0 == ":" }), c.contains("-") else { return nil }
            let left = c.hasPrefix(":"), right = c.hasSuffix(":")
            result.append(left && right ? "center" : right ? "right" : left ? "left" : nil)
        }
        return result
    }

    /// Splits a table row on unescaped `|`, ignoring the outer pipes.
    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for ch in text {
            if escaped { current.append(ch == "|" ? "|" : "\\\(ch)"); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|", !inCode { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: Line classification

    static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

    /// Columns of leading whitespace, with tabs to the next multiple of 4.
    static func indentWidth(_ line: String) -> Int {
        var width = 0
        for ch in line {
            if ch == " " { width += 1 } else if ch == "\t" { width += 4 - width % 4 } else { break }
        }
        return width
    }

    static func dropIndent(_ line: String, upTo columns: Int) -> String {
        var width = 0
        var index = line.startIndex
        while index < line.endIndex, width < columns {
            let ch = line[index]
            if ch == " " { width += 1 } else if ch == "\t" { width += 4 - width % 4 } else { break }
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    struct Fence { var char: Character; var count: Int; var info: String; var indent: Int }

    static func fence(_ line: String) -> Fence? {
        let indent = indentWidth(line)
        guard indent <= 3 else { return nil }
        let rest = line.drop { $0 == " " }
        guard let ch = rest.first, ch == "`" || ch == "~" else { return nil }
        let count = rest.prefix { $0 == ch }.count
        guard count >= 3 else { return nil }
        let info = rest.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if ch == "`", info.contains("`") { return nil }
        return Fence(char: ch, count: count, info: info, indent: indent)
    }

    static func atxHeading(_ line: String) -> (Int, String)? {
        guard indentWidth(line) <= 3 else { return nil }
        let rest = line.drop { $0 == " " }
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes: `## Title ##`.
        if let last = text.lastIndex(where: { $0 != "#" }), text.last == "#", text[last] == " " {
            text = String(text[..<last]).trimmingCharacters(in: .whitespaces)
        } else if text.allSatisfy({ $0 == "#" }) {
            text = ""
        }
        return (level, text)
    }

    static func isThematicBreak(_ line: String) -> Bool {
        guard indentWidth(line) <= 3 else { return false }
        let chars = line.filter { $0 != " " && $0 != "\t" }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    static func quoteContent(_ line: String) -> String? {
        guard indentWidth(line) <= 3 else { return nil }
        let rest = line.drop { $0 == " " }
        guard rest.first == ">" else { return nil }
        var content = rest.dropFirst()
        if content.first == " " { content = content.dropFirst() }
        return String(content)
    }

    struct ListMarker {
        var ordered: Bool
        var bullet: Character
        var start: Int
        /// Column where the item's text starts; continuation lines must reach it.
        var contentIndent: Int
        var content: String
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let indent = indentWidth(line)
        guard indent <= 3 else { return nil }
        let rest = Substring(line.drop { $0 == " " })
        guard let first = rest.first else { return nil }
        var markerLength: Int
        var ordered = false
        var bullet = first
        var start = 1
        if "-*+".contains(first) {
            markerLength = 1
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
            let after = rest.dropFirst(digits.count)
            guard let delimiter = after.first, delimiter == "." || delimiter == ")" else { return nil }
            markerLength = digits.count + 1
            ordered = true
            bullet = delimiter
            start = number
        }
        let after = rest.dropFirst(markerLength)
        if after.isEmpty {
            return ListMarker(ordered: ordered, bullet: bullet, start: start, contentIndent: indent + markerLength + 1, content: "")
        }
        guard after.first == " " || after.first == "\t" else { return nil }
        let spaces = min(4, after.prefix { $0 == " " }.count)
        let content = String(after.dropFirst(max(1, spaces)))
        // A thematic break like `- - -` isn't a list.
        if isThematicBreak(line) { return nil }
        return ListMarker(
            ordered: ordered, bullet: bullet, start: start, contentIndent: indent + markerLength + max(1, spaces), content: content)
    }

    // MARK: Escaping

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// GitHub-style heading anchors: lowercased, punctuation dropped, spaces to hyphens.
    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { out.append(ch) } else if ch == " " { out.append("-") }
        }
        return escape(out)
    }
}

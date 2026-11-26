import Foundation

/// Inline Markdown: emphasis, code spans, links, images, autolinks, breaks.
nonisolated extension MarkdownRenderer {
    func inline(_ text: String) -> String {
        let c = Array(text)
        var out = ""
        var i = 0
        let n = c.count

        while i < n {
            let ch = c[i]
            switch ch {
            case "\\":
                if i + 1 < n, c[i + 1] == "\n" {
                    out += "<br>\n"
                    i += 2
                } else if i + 1 < n, c[i + 1].isASCII, c[i + 1].isPunctuation || c[i + 1].isSymbol {
                    out += Self.escape(String(c[i + 1]))
                    i += 2
                } else {
                    out += "\\"
                    i += 1
                }

            case "`":
                let run = Self.runLength(c, at: i)
                if let close = Self.findRun(c, of: "`", length: run, from: i + run) {
                    var code = String(c[(i + run)..<close]).replacingOccurrences(of: "\n", with: " ")
                    if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    out += "<code>\(Self.escape(code))</code>"
                    i = close + run
                } else {
                    out += String(repeating: "`", count: run)
                    i += run
                }

            case "!" where i + 1 < n && c[i + 1] == "[":
                if let (html, end) = link(c, at: i + 1, image: true) {
                    out += html
                    i = end
                } else {
                    out += "!"
                    i += 1
                }

            case "[":
                if let (html, end) = link(c, at: i, image: false) {
                    out += html
                    i = end
                } else {
                    out += "["
                    i += 1
                }

            case "<":
                if let close = c[(i + 1)...].firstIndex(of: ">"), close > i + 1 {
                    let inner = String(c[(i + 1)..<close])
                    if !inner.contains(" "), inner.contains("@"), !inner.contains(":") {
                        out += "<a href=\"mailto:\(Self.escape(inner))\">\(Self.escape(inner))</a>"
                        i = close + 1
                        continue
                    }
                    if !inner.contains(" "), let href = Self.safeURL(inner, image: false), inner.contains(":") {
                        out += "<a href=\"\(href)\">\(Self.escape(inner))</a>"
                        i = close + 1
                        continue
                    }
                }
                out += "&lt;"
                i += 1

            case "*", "_", "~":
                if let (html, end) = emphasis(c, at: i) {
                    out += html
                    i = end
                } else {
                    let run = Self.runLength(c, at: i)
                    out += String(repeating: ch, count: run)
                    i += run
                }

            case "\n":
                // Two trailing spaces make a hard break; otherwise a soft one.
                var trailing = 0
                while out.hasSuffix(" ") { out.removeLast(); trailing += 1 }
                out += trailing >= 2 ? "<br>\n" : "\n"
                i += 1

            case "h" where i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber),
                 "w" where i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber):
                if let (html, end) = Self.bareURL(c, at: i) {
                    out += html
                    i = end
                } else {
                    out += String(ch)
                    i += 1
                }

            default:
                out += Self.escape(String(ch))
                i += 1
            }
        }
        return out
    }

    // MARK: Emphasis

    /// `*em*`, `**strong**`, `***both***`, the `_` forms, and `~~strike~~`.
    private func emphasis(_ c: [Character], at i: Int) -> (String, Int)? {
        let ch = c[i]
        let run = Self.runLength(c, at: i)
        let n = c.count
        if ch == "~", run != 2 { return nil }
        guard run <= 3, i + run < n, !c[i + run].isWhitespace else { return nil }
        if ch == "_", i > 0, c[i - 1].isLetter || c[i - 1].isNumber { return nil }
        var j = i + run
        while j < n {
            if c[j] == "`" {
                // Don't close inside a code span.
                let codeRun = Self.runLength(c, at: j)
                if let close = Self.findRun(c, of: "`", length: codeRun, from: j + codeRun) { j = close + codeRun; continue }
            }
            if c[j] == ch, Self.runLength(c, at: j) == run, !c[j - 1].isWhitespace {
                let after = j + run
                if ch == "_", after < n, c[after].isLetter || c[after].isNumber { j += run; continue }
                let inner = inline(String(c[(i + run)..<j]))
                let html: String
                switch (ch, run) {
                case ("~", _): html = "<del>\(inner)</del>"
                case (_, 1): html = "<em>\(inner)</em>"
                case (_, 2): html = "<strong>\(inner)</strong>"
                default: html = "<em><strong>\(inner)</strong></em>"
                }
                return (html, after)
            }
            j += 1
        }
        return nil
    }

    // MARK: Links

    /// `[text](url "title")`, `[text][ref]`, `[ref][]`, `[ref]`, and the `![…]` image forms.
    private func link(_ c: [Character], at open: Int, image: Bool) -> (String, Int)? {
        guard let close = Self.matchingBracket(c, from: open) else { return nil }
        let label = String(c[(open + 1)..<close])
        var destination: (url: String, title: String?)?
        var end = close + 1

        if end < c.count, c[end] == "(" {
            guard let (url, title, after) = Self.inlineDestination(c, from: end + 1) else { return nil }
            destination = (url, title)
            end = after
        } else if end < c.count, c[end] == "[", let refClose = c[end...].firstIndex(of: "]") {
            let ref = String(c[(end + 1)..<refClose])
            let key = Self.normalize(ref.isEmpty ? label : ref)
            guard let reference = references[key] else { return nil }
            destination = (reference.url, reference.title)
            end = refClose + 1
        } else if let reference = references[Self.normalize(label)] {
            destination = (reference.url, reference.title)
        }
        guard let destination else { return nil }
        let titleAttr = destination.title.map { " title=\"\(Self.escape($0))\"" } ?? ""
        if image {
            guard let src = Self.safeURL(destination.url, image: true) else { return (Self.escape(label), end) }
            return ("<img src=\"\(src)\" alt=\"\(Self.escape(Self.plainText(label)))\"\(titleAttr)>", end)
        }
        guard let href = Self.safeURL(destination.url, image: false) else { return (inline(label), end) }
        return ("<a href=\"\(href)\"\(titleAttr)>\(inline(label))</a>", end)
    }

    /// Parses `url "title")` after the `(`. Returns the index after `)`.
    private static func inlineDestination(_ c: [Character], from: Int) -> (String, String?, Int)? {
        var i = from
        while i < c.count, c[i] == " " { i += 1 }
        var url = ""
        if i < c.count, c[i] == "<" {
            guard let close = c[i...].firstIndex(of: ">") else { return nil }
            url = String(c[(i + 1)..<close])
            i = close + 1
        } else {
            var depth = 0
            while i < c.count, !c[i].isWhitespace {
                if c[i] == "(" { depth += 1 }
                if c[i] == ")" { if depth == 0 { break }; depth -= 1 }
                url.append(c[i])
                i += 1
            }
        }
        while i < c.count, c[i] == " " { i += 1 }
        var title: String?
        if i < c.count, c[i] == "\"" || c[i] == "'" {
            let quote = c[i]
            guard let close = c[(i + 1)...].firstIndex(of: quote) else { return nil }
            title = String(c[(i + 1)..<close])
            i = close + 1
            while i < c.count, c[i] == " " { i += 1 }
        }
        guard i < c.count, c[i] == ")" else { return nil }
        return (url, title, i + 1)
    }

    /// GFM bare `https://…` and `www.…` links. Trailing punctuation stays outside the link.
    private static func bareURL(_ c: [Character], at i: Int) -> (String, Int)? {
        let prefixes = ["https://", "http://", "www."]
        let rest = String(c[i..<min(c.count, i + 8)])
        guard let prefix = prefixes.first(where: { rest.hasPrefix($0) }) else { return nil }
        var j = i + prefix.count
        while j < c.count, !c[j].isWhitespace, c[j] != "<" { j += 1 }
        while j > i + prefix.count, ".,:;!?\"')*_~".contains(c[j - 1]) {
            if c[j - 1] == ")", c[i..<j].filter({ $0 == "(" }).count >= c[i..<j].filter({ $0 == ")" }).count { break }
            j -= 1
        }
        guard j > i + prefix.count else { return nil }
        let text = String(c[i..<j])
        guard let href = safeURL(prefix == "www." ? "http://" + text : text, image: false) else { return nil }
        return ("<a href=\"\(href)\">\(escape(text))</a>", j)
    }

    /// Allows only schemes that can't run code or read local files. Relative URLs and
    /// in-page anchors pass. Returns the URL escaped for an attribute, or `nil` to drop it.
    static func safeURL(_ raw: String, image: Bool) -> String? {
        let url = raw.trimmingCharacters(in: .whitespaces)
        let lower = url.lowercased()
        if let colon = lower.firstIndex(of: ":") {
            let scheme = lower[..<colon]
            let looksLikeScheme = scheme.allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) } && !scheme.isEmpty
            if looksLikeScheme {
                let allowed = ["http", "https", "mailto"].contains(scheme)
                let dataImage = image && scheme == "data" && ["data:image/png", "data:image/jpeg", "data:image/gif", "data:image/webp"].contains { lower.hasPrefix($0) }
                guard allowed || dataImage else { return nil }
            }
        }
        return escape(url)
    }

    // MARK: Helpers

    static func runLength(_ c: [Character], at i: Int) -> Int {
        var j = i
        while j < c.count, c[j] == c[i] { j += 1 }
        return j - i
    }

    /// Start of the next run of exactly `length` `ch` characters.
    static func findRun(_ c: [Character], of ch: Character, length: Int, from: Int) -> Int? {
        var j = from
        while j < c.count {
            if c[j] == ch {
                let run = runLength(c, at: j)
                if run == length { return j }
                j += run
            } else {
                j += 1
            }
        }
        return nil
    }

    static func matchingBracket(_ c: [Character], from open: Int) -> Int? {
        var depth = 0
        var j = open
        while j < c.count {
            switch c[j] {
            case "\\": j += 1
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return j }
            case "`":
                let run = runLength(c, at: j)
                if let close = findRun(c, of: "`", length: run, from: j + run) { j = close + run - 1 }
            default: break
            }
            j += 1
        }
        return nil
    }

    /// Alt text: the label without Markdown punctuation.
    static func plainText(_ label: String) -> String {
        label.filter { !"*_`[]".contains($0) }
    }
}

/// Syntax-colored HTML for code blocks, using the same lexers (and colors) as the editor.
nonisolated enum CodeHighlighter {
    static func html(_ code: String, language: Language?) -> String {
        guard let language, language != .plain else { return MarkdownRenderer.escape(code) }
        let lexer = language.lexer
        var out = ""
        var state = LexState.initial
        var first = true
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            if !first { out += "\n" }
            first = false
            let units = Array(line.utf16)
            var tokens: [Token]? = []
            state = units.withUnsafeBufferPointer { lexer.lex($0, state: state, tokens: &tokens) }
            var position = 0
            func text(_ range: Range<Int>) -> String {
                MarkdownRenderer.escape(String(decoding: units[range], as: UTF16.self))
            }
            for token in tokens ?? [] where token.start >= position {
                out += text(position..<token.start)
                out += "<span class=\"tok-\(token.kind)\">\(text(token.start..<token.end))</span>"
                position = token.end
            }
            out += text(position..<units.count)
        }
        return out
    }
}

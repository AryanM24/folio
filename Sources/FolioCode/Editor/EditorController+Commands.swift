import AppKit
import UniformTypeIdentifiers
import FolioKit

/// Menu, toolbar and shortcut commands. Each is one undoable step.
extension EditorController {
    private func run(_ actionName: String, _ make: (NSString, NSRange) -> TextEdit?) {
        guard let textView, textView.isEditable else { return }
        guard let edit = make(textView.text, textView.selectedRange()) else { NSSound.beep(); return }
        textView.apply(edit, actionName: actionName)
    }

    // MARK: Lines

    func toggleComment() {
        run("Toggle Comment") { TextEditing.toggleComment($0, selection: $1, lineComment: language.lineComment, blockComment: language.blockComment) }
    }
    func indent() { run("Indent") { TextEditing.indent($0, selection: $1, unit: textView?.indentStyle.unit ?? "    ") } }
    func outdent() { run("Outdent") { TextEditing.outdent($0, selection: $1, width: textView?.indentStyle.width ?? 4) } }
    func moveLines(up: Bool) { run(up ? "Move Line Up" : "Move Line Down") { TextEditing.moveLines($0, selection: $1, up: up) } }
    func duplicateLines() { run("Duplicate Line") { TextEditing.duplicateLines($0, selection: $1) } }

    // MARK: Markdown

    func bold() { run("Bold") { TextEditing.toggleWrap($0, selection: $1, marker: "**") } }
    func italic() { run("Italic") { TextEditing.toggleWrap($0, selection: $1, marker: "*") } }
    func insertLink() { run("Insert Link") { TextEditing.link($0, selection: $1) } }

    // MARK: Navigation

    func showGoToLine() { showsGoToLine = true }

    /// Moves the caret to a one-based line (and optional column) and centers it.
    func goTo(line: Int, column: Int = 1) {
        guard let textView else { return }
        let lines = highlighter.lines
        let index = max(0, min(line - 1, lines.count - 1))
        let content = lines.contentRange(ofLine: index, length: textView.text.length)
        let location = content.location + max(0, min(column - 1, content.length))
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        if let scrollView, let rect = textView.currentLineRect() {
            let visible = scrollView.contentView.bounds
            let y = max(0, rect.midY - visible.height / 2)
            scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: min(y, max(0, textView.frame.height - visible.height))))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: View

    func zoom(by step: Double) {
        let size = min(28, max(9, settings.fontSize + step))
        UserDefaults.standard.set(size, forKey: EditorSettings.Key.fontSize)
    }
    func resetZoom() { UserDefaults.standard.set(EditorSettings.defaultFontSize, forKey: EditorSettings.Key.fontSize) }
    func toggleWrap() { UserDefaults.standard.set(!settings.wrapLines, forKey: EditorSettings.Key.wrapLines) }
    func toggleLineNumbers() { UserDefaults.standard.set(!settings.showLineNumbers, forKey: EditorSettings.Key.showLineNumbers) }
    func toggleInvisibles() { UserDefaults.standard.set(!settings.showInvisibles, forKey: EditorSettings.Key.showInvisibles) }

    // MARK: Format (encoding, line endings)

    func setEncoding(_ encoding: TextEncoding) {
        guard let document, let textView else { return }
        let text = textView.textStorage?.string ?? ""
        guard text.canBeConverted(to: encoding.stringEncoding) else {
            Alert.show(FolioError("Some characters in this file can’t be represented in \(encoding.title), so it stays \(document.format.encoding.title)."),
                       title: "Can’t use \(encoding.title)", window: textView.window)
            return
        }
        document.setFormat(TextFormat(encoding: encoding, lineEnding: document.format.lineEnding), undoManager: undoManager)
        noteChange()
    }

    func setLineEnding(_ ending: LineEnding) {
        guard let document else { return }
        document.setFormat(TextFormat(encoding: document.format.encoding, lineEnding: ending), undoManager: undoManager)
        noteChange()
    }

    // MARK: JSON

    func formatJSON() {
        guard language == .json else { NSSound.beep(); return }
        let unit = textView?.indentStyle.unit ?? "  "
        rewriteJSON(name: "Format JSON") { (text: String) throws(JSONTools.Issue) -> String in try JSONTools.format(text, indent: unit) }
    }
    func minifyJSON() { rewriteJSON(name: "Minify JSON") { (text: String) throws(JSONTools.Issue) -> String in try JSONTools.minify(text) } }

    func validateJSON() {
        guard let text = textView?.textStorage?.string else { return }
        jsonIssue = JSONTools.validate(text)
        jsonChecked = true
        if let issue = jsonIssue { reveal(issue) }
    }

    private func rewriteJSON(name: String, _ transform: (String) throws(JSONTools.Issue) -> String) {
        guard let textView, let text = textView.textStorage?.string else { return }
        do throws(JSONTools.Issue) {
            let result = try transform(text)
            guard result != text else { return }
            textView.apply(TextEdit(range: NSRange(location: 0, length: textView.text.length), replacement: result,
                                    selection: NSRange(location: 0, length: 0)), actionName: name)
            jsonIssue = nil
            jsonChecked = true
        } catch {
            jsonIssue = error
            jsonChecked = true
            reveal(error)
        }
    }

    /// Moves the caret to a JSON error.
    func reveal(_ issue: JSONTools.Issue) {
        goTo(line: issue.line, column: issue.column)
        NSSound.beep()
    }

    // MARK: Find & Replace with regular expressions

    func showFindReplace() {
        if let textView, textView.selectedRange().length > 0, textView.selectedRange().length < 200 {
            let selected = textView.text.substring(with: textView.selectedRange())
            if !selected.contains("\n") { find.query = find.isRegex ? NSRegularExpression.escapedPattern(for: selected) : selected }
        }
        find.isVisible = true
        find.status = ""
    }

    func hideFindReplace() {
        find.isVisible = false
        if let textView { textView.window?.makeFirstResponder(textView) }
    }

    private func makeRegex() -> NSRegularExpression? {
        guard !find.query.isEmpty else { find.status = ""; return nil }
        let pattern = find.isRegex ? find.query : NSRegularExpression.escapedPattern(for: find.query)
        do {
            let options: NSRegularExpression.Options = find.matchCase ? [.anchorsMatchLines] : [.caseInsensitive, .anchorsMatchLines]
            find.isError = false
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            find.status = "Invalid pattern"
            find.isError = true
            return nil
        }
    }

    private var template: String { find.isRegex ? find.replacement : NSRegularExpression.escapedTemplate(for: find.replacement) }

    func findNext(backwards: Bool = false) {
        guard let textView, let regex = makeRegex() else { return }
        let text = textView.text as String
        let selection = textView.selectedRange()
        let length = (text as NSString).length
        var match: NSTextCheckingResult?
        if backwards {
            let before = regex.matches(in: text, range: NSRange(location: 0, length: selection.location))
            match = before.last ?? regex.matches(in: text, range: NSRange(location: 0, length: length)).last
        } else {
            let start = min(length, selection.upperBound)
            match = regex.firstMatch(in: text, range: NSRange(location: start, length: length - start))
                ?? regex.firstMatch(in: text, range: NSRange(location: 0, length: length))
        }
        guard let match, match.range.length > 0 || match.range.location != NSNotFound else {
            find.status = "No matches"
            NSSound.beep()
            return
        }
        textView.setSelectedRange(match.range)
        textView.scrollRangeToVisible(match.range)
        textView.showFindIndicator(for: match.range)
        let count = regex.numberOfMatches(in: text, range: NSRange(location: 0, length: length))
        let index = regex.numberOfMatches(in: text, range: NSRange(location: 0, length: match.range.location)) + 1
        find.status = "\(index) of \(count)"
    }

    /// Replaces the current match (if the selection is one) and moves to the next.
    func replaceCurrent() {
        guard let textView, let regex = makeRegex() else { return }
        let text = textView.text as String
        let selection = textView.selectedRange()
        if selection.length > 0, let match = regex.firstMatch(in: text, options: .anchored, range: selection), match.range == selection {
            let replacement = regex.replacementString(for: match, in: text, offset: 0, template: template)
            textView.apply(TextEdit(range: selection, replacement: replacement,
                                    selection: NSRange(location: selection.location + (replacement as NSString).length, length: 0)), actionName: "Replace")
        }
        findNext()
    }

    func replaceAll() {
        guard let textView, let regex = makeRegex() else { return }
        let text = textView.text as String
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        guard let first = matches.first, let last = matches.last else {
            find.status = "No matches"
            NSSound.beep()
            return
        }
        // One edit spanning first…last match keeps it a single undo step.
        let ns = text as NSString
        var result = ""
        var cursor = first.range.location
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += regex.replacementString(for: match, in: text, offset: 0, template: template)
            cursor = match.range.upperBound
        }
        let span = NSRange(location: first.range.location, length: last.range.upperBound - first.range.location)
        textView.apply(TextEdit(range: span, replacement: result, selection: NSRange(location: span.location, length: 0)), actionName: "Replace All")
        find.status = "Replaced \(matches.count)"
    }

    // MARK: Export and print

    enum ExportFormat { case html, pdf, docx }

    private var exportTitle: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    func export(_ format: ExportFormat) {
        guard let text = textView?.textStorage?.string else { return }
        let title = exportTitle
        let window = textView?.window
        Task {
            switch format {
            case .html:
                await Exporter.save(suggestedName: title, type: .html, window: window) {
                    Data(MarkdownExport.html(markdown: text, title: title).utf8)
                }
            case .pdf:
                await Exporter.save(suggestedName: title, type: .pdf, window: window) {
                    try await MarkdownExport.pdf(markdown: text, title: title)
                }
            case .docx:
                await Exporter.save(suggestedName: title, type: .docx, window: window) {
                    try await MarkdownExport.docx(markdown: text, title: title)
                }
            }
        }
    }

    /// Markdown prints as the rendered document; everything else as syntax-colored source.
    func printDocument() {
        guard let textView, let text = textView.textStorage?.string else { return }
        do {
            let attributed = language == .markdown
                ? try MarkdownExport.attributedString(markdown: text, title: exportTitle)
                : PrintSupport.coloredSource(text, language: language, fontSize: 10)
            PrintSupport.print(attributed, title: exportTitle, window: textView.window)
        } catch {
            Alert.show(error, title: "Couldn’t print “\(exportTitle)”", window: textView.window)
        }
    }
}

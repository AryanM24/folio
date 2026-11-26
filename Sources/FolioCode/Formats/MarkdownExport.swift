import AppKit
import FolioKit

/// Markdown to HTML, PDF and Word.
///
/// HTML is the rendered page itself. PDF and Word go through `NSAttributedString`'s HTML
/// import, then the Cocoa text system paginates (PDF) or writes Office Open XML (Word). That
/// keeps both exports headless (they also run from Finder Quick Actions) and gives real
/// pagination with selectable text. Exports always use the light theme.
enum MarkdownExport {
    nonisolated static func html(markdown: String, title: String) -> String {
        HTMLPage.document(body: MarkdownRenderer.render(markdown), title: title)
    }

    static func attributedString(markdown: String, title: String) throws -> NSAttributedString {
        // The HTML importer drops form controls, so task boxes become characters.
        let body = MarkdownRenderer.render(markdown)
            .replacingOccurrences(of: "<input type=\"checkbox\" disabled checked>", with: "☑")
            .replacingOccurrences(of: "<input type=\"checkbox\" disabled>", with: "☐")
        let page = HTMLPage.document(body: body, title: title, appearance: .light)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        do {
            return try NSAttributedString(data: Data(page.utf8), options: options, documentAttributes: nil)
        } catch {
            throw FolioError("Folio couldn’t lay out this Markdown for export.")
        }
    }

    static func pdf(markdown: String, title: String) throws -> Data {
        try PrintSupport.pdf(from: attributedString(markdown: markdown, title: title), title: title)
    }

    static func docx(markdown: String, title: String) throws -> Data {
        let attributed = try attributedString(markdown: markdown, title: title)
        do {
            return try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [
                    .documentType: NSAttributedString.DocumentType.officeOpenXML,
                    .title: title,
                ])
        } catch {
            throw FolioError("Folio couldn’t create the Word document.")
        }
    }
}

/// Paginated output through the Cocoa text system: printing, and PDF files.
enum PrintSupport {
    private static func printInfo(saveTo url: URL? = nil) -> NSPrintInfo {
        let info = NSPrintInfo(dictionary: url.map { [.jobSavingURL: $0] } ?? [:])
        if url != nil { info.jobDisposition = .save }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        return info
    }

    /// A TextKit 1 view sized to the page width; TextKit 1 paginates reliably when printing.
    private static func pageView(_ attributed: NSAttributedString, info: NSPrintInfo) -> NSTextView {
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(usingTextLayoutManager: false)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.backgroundColor = .white
        view.textStorage?.setAttributedString(attributed)
        if let container = view.textContainer, let layoutManager = view.layoutManager {
            layoutManager.ensureLayout(for: container)
            view.setFrameSize(NSSize(width: width, height: ceil(layoutManager.usedRect(for: container).height) + 1))
        }
        return view
    }

    static func pdf(from attributed: NSAttributedString, title: String) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "Folio-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let info = printInfo(saveTo: url)
        let operation = NSPrintOperation(view: pageView(attributed, info: info), printInfo: info)
        operation.jobTitle = title
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), let data = try? Data(contentsOf: url) else {
            throw FolioError("Folio couldn’t create the PDF.")
        }
        return data
    }

    static func print(_ attributed: NSAttributedString, title: String, window: NSWindow?) {
        let info = printInfo()
        let operation = NSPrintOperation(view: pageView(attributed, info: info), printInfo: info)
        operation.jobTitle = title
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// Source code in the editor's light-theme colors, for printing.
    static func coloredSource(_ text: String, language: Language, fontSize: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        guard language != .plain else { return result }
        let lexer = language.lexer
        var state = LexState.initial
        var offset = 0
        let units = Array(text.utf16)
        var lineStart = 0
        result.beginEditing()
        for index in 0...units.count where index == units.count || units[index] == 10 {
            var tokens: [Token]? = []
            let line = units[lineStart..<index]
            state = line.withUnsafeBufferPointer { lexer.lex($0, state: state, tokens: &tokens) }
            for token in tokens ?? [] {
                guard let pair = SyntaxPalette.pair(for: token.kind) else { continue }
                result.addAttribute(
                    .foregroundColor,
                    value: NSColor(
                        srgbRed: CGFloat((pair.light >> 16) & 0xFF) / 255, green: CGFloat((pair.light >> 8) & 0xFF) / 255,
                        blue: CGFloat(pair.light & 0xFF) / 255, alpha: 1),
                    range: NSRange(location: offset + token.start, length: token.end - token.start))
            }
            offset = index + 1
            lineStart = index + 1
        }
        result.endEditing()
        return result
    }
}

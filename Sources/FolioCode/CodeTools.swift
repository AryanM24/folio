public import FolioKit
import Foundation
import UniformTypeIdentifiers

/// File tools owned by this module. Surfaced in the Welcome window, File > Tools and
/// Finder Quick Actions. Each writes new files next to its inputs and never changes them.
public enum CodeTools {
    public nonisolated static let all: [FolioTool] = [markdownToPDF, markdownToHTML, markdownToWord, formatJSON, convertLineEndings, convertToUTF8]

    private nonisolated static let markdownTypes: [UTType] = [.markdown]
    private nonisolated static let textTypes: [UTType] = FileKind.code.readableTypes

    nonisolated static let markdownToPDF = FolioTool(
        id: "code.markdownToPDF", title: "Markdown to PDF", subtitle: "Render Markdown files as paginated PDFs",
        symbol: "doc.richtext", inputTypes: markdownTypes
    ) { inputs, _ in
        try await convertMarkdown(inputs, ext: "pdf") { text, title in try await MarkdownExport.pdf(markdown: text, title: title) }
    }

    nonisolated static let markdownToHTML = FolioTool(
        id: "code.markdownToHTML", title: "Markdown to HTML", subtitle: "Render Markdown files as standalone web pages",
        symbol: "globe", inputTypes: markdownTypes
    ) { inputs, _ in
        try await convertMarkdown(inputs, ext: "html") { text, title in Data(MarkdownExport.html(markdown: text, title: title).utf8) }
    }

    nonisolated static let markdownToWord = FolioTool(
        id: "code.markdownToDOCX", title: "Markdown to Word", subtitle: "Convert Markdown files to .docx documents",
        symbol: "doc.text", inputTypes: markdownTypes
    ) { inputs, _ in
        try await convertMarkdown(inputs, ext: "docx") { text, title in try await MarkdownExport.docx(markdown: text, title: title) }
    }

    nonisolated static let formatJSON = FolioTool(
        id: "code.formatJSON", title: "Format JSON", subtitle: "Pretty-print JSON files, keeping key order",
        symbol: "curlybraces", inputTypes: [.json],
        options: [FolioTool.Option(id: "indent", label: "Indent", choices: [("2", "2 spaces"), ("4", "4 spaces"), ("tab", "Tabs")], defaultValue: "2")]
    ) { inputs, options in
        let indent = options["indent"] == "tab" ? "\t" : String(repeating: " ", count: Int(options["indent"] ?? "2") ?? 2)
        return try inputs.map { url in
            let (text, format) = try read(url)
            let formatted: String
            do throws(JSONTools.Issue) { formatted = try JSONTools.format(text, indent: indent) } catch {
                throw FolioError("“\(url.lastPathComponent)” isn’t valid JSON. \(error.description).")
            }
            return try write(TextCodec.encode(formatted, as: format), nextTo: url, suffix: "formatted")
        }
    }

    nonisolated static let convertLineEndings = FolioTool(
        id: "code.convertLineEndings", title: "Convert Line Endings", subtitle: "Save copies with macOS/Linux or Windows line endings",
        symbol: "return", inputTypes: textTypes,
        options: [FolioTool.Option(id: "ending", label: "Line endings", choices: [("lf", "macOS and Linux (LF)"), ("crlf", "Windows (CRLF)")], defaultValue: "lf")]
    ) { inputs, options in
        let ending = LineEnding(rawValue: options["ending"] ?? "lf") ?? .lf
        return try inputs.map { url in
            let (text, format) = try read(url)
            return try write(TextCodec.encode(text, as: TextFormat(encoding: format.encoding, lineEnding: ending)), nextTo: url, suffix: ending.title)
        }
    }

    nonisolated static let convertToUTF8 = FolioTool(
        id: "code.convertToUTF8", title: "Convert to UTF-8", subtitle: "Save copies of text files encoded as UTF-8",
        symbol: "textformat", inputTypes: textTypes
    ) { inputs, _ in
        try inputs.map { url in
            let (text, format) = try read(url)
            return try write(TextCodec.encode(text, as: TextFormat(encoding: .utf8, lineEnding: format.lineEnding)), nextTo: url, suffix: "UTF-8")
        }
    }

    // MARK: Helpers

    private nonisolated static func read(_ url: URL) throws -> (String, TextFormat) {
        do {
            let decoded = TextCodec.decode(try Data(contentsOf: url))
            return (decoded.text, decoded.format)
        } catch {
            throw FolioError("Folio couldn’t read “\(url.lastPathComponent)”.")
        }
    }

    /// Writes `name suffix.ext` beside the input, never overwriting.
    private nonisolated static func write(_ data: Data, nextTo url: URL, suffix: String, ext: String? = nil) throws -> URL {
        let name = url.deletingPathExtension().lastPathComponent + (suffix.isEmpty ? "" : " (\(suffix))")
        let output = FolioTool.outputURL(nextTo: url, name: name, ext: ext ?? url.pathExtension)
        try data.write(to: output, options: .atomic)
        return output
    }

    private nonisolated static func convertMarkdown(_ inputs: [URL], ext: String, _ convert: @Sendable (String, String) async throws -> Data) async throws -> [URL] {
        var outputs: [URL] = []
        for url in inputs {
            let (text, _) = try read(url)
            let title = url.deletingPathExtension().lastPathComponent
            outputs.append(try write(try await convert(text, title), nextTo: url, suffix: "", ext: ext))
        }
        return outputs
    }
}

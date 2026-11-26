public import FolioKit
public import Foundation

/// File tools owned by this module. Surfaced in the workspace's Tools view, File > Tools and
/// Finder Quick Actions. See `FolioTool`.
public enum DocumentTools {
    public nonisolated static let all: [FolioTool] = [convert]

    /// "Convert Documents": Word, RTF, ODT, HTML, Markdown, plain text → any of those or PDF.
    nonisolated static let convert = FolioTool(
        id: "docs.convert",
        title: "Convert Documents",
        subtitle: "Word, RTF, OpenDocument, HTML, Markdown, text or PDF",
        symbol: "doc.on.doc",
        inputTypes: DocFormat.convertibleInputs.map(\.contentType),
        options: [
            .init(
                id: "format",
                label: "Convert to",
                choices: [DocFormat.pdf, .docx, .rtf, .odt, .html, .md, .txt].map { ($0.rawValue, $0.title) },
                defaultValue: DocFormat.pdf.rawValue
            )
        ]
    ) { inputs, options in
        let format = DocFormat(rawValue: options["format"] ?? "") ?? .pdf
        var outputs: [URL] = []
        for input in inputs {
            outputs.append(try await DocumentConverter.convert(input, to: format))
        }
        return outputs
    }
}

/// Converts a document file to another format, writing the result next to it.
/// Never modifies the input.
public enum DocumentConverter {
    /// - Returns: The new file's URL (" 2", " 3"… appended rather than overwriting).
    public nonisolated static func convert(_ input: URL, to format: DocFormat) async throws -> URL {
        guard let source = DocFormat.format(for: input), DocFormat.convertibleInputs.contains(source) else {
            throw FolioError("“\(input.lastPathComponent)” isn't a document Folio can convert.")
        }
        let output = FolioTool.outputURL(nextTo: input, name: input.deletingPathExtension().lastPathComponent, ext: format.fileExtension)
        if format == .pdf {
            // Pagination uses AppKit printing, which runs on the main thread.
            let data = try await MainActor.run {
                let (text, attributes) = try DocumentCodec.read(try FileWrapper(url: input), as: source)
                return try PDFRenderer.pdf(text, page: PageSetup(attributes: attributes))
            }
            try data.write(to: output, options: .atomic)
        } else {
            let (text, attributes) = try DocumentCodec.read(try FileWrapper(url: input), as: source)
            let wrapper = try DocumentCodec.fileWrapper(text, attributes: attributes, page: PageSetup(attributes: attributes), as: format)
            try wrapper.write(to: output, options: .atomic, originalContentsURL: nil)
        }
        return output
    }
}

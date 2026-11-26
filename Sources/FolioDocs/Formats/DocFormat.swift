public import AppKit
import FolioKit
public import UniformTypeIdentifiers

/// Every file format the document editor reads, writes or exports.
///
/// One enum keeps the mapping between file extension, content type and the Cocoa
/// text system's `DocumentType` in a single place, so the document, the export menu
/// and the conversion tools can never disagree about what a format means.
public nonisolated enum DocFormat: String, CaseIterable, Sendable, Identifiable {
    case docx, rtf, rtfd, odt, html, webarchive, doc, txt, md, pdf

    public var id: String { rawValue }

    /// Name shown in menus ("Word Document").
    public var title: String {
        switch self {
        case .docx: "Word Document"
        case .rtf: "Rich Text"
        case .rtfd: "Rich Text with Attachments"
        case .odt: "OpenDocument Text"
        case .html: "Web Page"
        case .webarchive: "Web Archive"
        case .doc: "Word 97 Document"
        case .txt: "Plain Text"
        case .md: "Markdown"
        case .pdf: "PDF"
        }
    }

    /// File extension written for this format.
    public var fileExtension: String { rawValue }

    public var contentType: UTType {
        switch self {
        case .docx: .docx
        case .rtf: .rtf
        case .rtfd: .rtfd
        case .odt: .odt
        case .html: .html
        case .webarchive: .webArchive
        case .doc: .doc
        case .txt: .plainText
        case .md: .markdown
        case .pdf: .pdf
        }
    }

    /// The Cocoa text system's name for the format, when it reads or writes it itself.
    /// `nil` for formats Folio encodes on its own (Markdown, PDF).
    var cocoaType: NSAttributedString.DocumentType? {
        switch self {
        case .docx: .officeOpenXML
        case .rtf: .rtf
        case .rtfd: .rtfd
        case .odt: .openDocument
        case .html: .html
        case .webarchive: .webArchive
        case .doc: .docFormat
        case .txt: .plain
        case .md, .pdf: nil
        }
    }

    /// Formats the editor can open and save in place (the document's readable types).
    static let editable: [DocFormat] = [.docx, .rtf, .rtfd, .odt, .html, .webarchive, .doc]

    /// Formats a conversion can start from.
    static let convertibleInputs: [DocFormat] = editable + [.txt, .md]

    /// Formats offered by Export and the conversion tool.
    static let exportable: [DocFormat] = [.pdf, .docx, .rtf, .odt, .html, .md, .txt, .webarchive, .doc]

    /// The format of a content type, matching the most specific type first
    /// (Markdown conforms to plain text, RTFD is not RTF).
    public static func format(for type: UTType) -> DocFormat? {
        let ordered: [DocFormat] = [.docx, .doc, .odt, .rtfd, .rtf, .webarchive, .html, .md, .pdf, .txt]
        return ordered.first { type == $0.contentType }
            ?? ordered.first { type.conforms(to: $0.contentType) }
    }

    /// The format of a file on disk, from its extension.
    public static func format(for url: URL) -> DocFormat? {
        if let type = UTType(filenameExtension: url.pathExtension) { return format(for: type) }
        return nil
    }
}

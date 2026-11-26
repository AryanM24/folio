public import AppKit
import FolioKit

/// Reads and writes every non-PDF format as pure functions of bytes, so the document,
/// export and the conversion tools share one tested implementation and can run off
/// the main thread. (PDF needs AppKit's printing system; see `PDFRenderer`.)
public nonisolated enum DocumentCodec {
    public typealias Attributes = [NSAttributedString.DocumentAttributeKey: Any]

    /// Parses a file in `format`. Directory wrappers are accepted for RTFD.
    public static func read(
        _ wrapper: FileWrapper, as format: DocFormat
    ) throws -> (text: NSMutableAttributedString, attributes: Attributes) {
        if format == .rtfd, wrapper.isDirectory {
            var attributes: NSDictionary?
            guard let text = NSAttributedString(rtfdFileWrapper: wrapper, documentAttributes: &attributes) else {
                throw FolioError("This RTFD package is damaged or empty.")
            }
            return (NSMutableAttributedString(attributedString: text), attributes as? Attributes ?? [:])
        }
        guard let data = wrapper.regularFileContents else {
            throw FolioError("Folio couldn't read this file's contents.")
        }
        return try read(data, as: format)
    }

    /// Parses bytes in `format`. An empty file opens as an empty document.
    public static func read(_ data: Data, as format: DocFormat) throws -> (text: NSMutableAttributedString, attributes: Attributes) {
        if data.isEmpty { return (NSMutableAttributedString(), [:]) }
        switch format {
        case .md:
            return (NSMutableAttributedString(attributedString: Markdown.attributedString(from: decode(data))), [:])
        case .txt:
            return (NSMutableAttributedString(string: decode(data), attributes: TextStyle.body.attributes()), [:])
        case .pdf:
            throw FolioError("PDFs open in Folio's PDF editor. To get the text, open the PDF and copy it.")
        default:
            guard let type = format.cocoaType else { throw FolioError("Folio can't read \(format.title) files.") }
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
            if format == .html { options[.characterEncoding] = String.Encoding.utf8.rawValue }
            var attributes: NSDictionary?
            let text: NSAttributedString
            do {
                text = try NSAttributedString(data: data, options: options, documentAttributes: &attributes)
            } catch {
                throw FolioError(
                    "This file isn't a readable \(format.title). It may be damaged, password-protected, or saved by a newer app.")
            }
            let mutable = NSMutableAttributedString(attributedString: text)
            if format == .docx { DocxStyles.apply(docx: data, to: mutable) }
            return (mutable, attributes as? Attributes ?? [:])
        }
    }

    /// Encodes `text` as `format`. `attributes` are the document attributes read from
    /// the original file (title, author, page setup); they're written back where the
    /// format supports them.
    public static func fileWrapper(
        _ text: NSAttributedString, attributes: Attributes = [:], page: PageSetup, as format: DocFormat
    ) throws -> FileWrapper {
        if format == .rtfd {
            var attrs = attributes.merging(page.attributes) { $1 }
            attrs[.documentType] = NSAttributedString.DocumentType.rtfd
            guard let wrapper = text.rtfdFileWrapper(from: NSRange(location: 0, length: text.length), documentAttributes: attrs) else {
                throw FolioError("Folio couldn't encode this document as RTFD.")
            }
            return wrapper
        }
        return FileWrapper(regularFileWithContents: try data(text, attributes: attributes, page: page, as: format))
    }

    /// Encodes `text` as a single-file `format` (everything except RTFD packages and PDF).
    public static func data(_ text: NSAttributedString, attributes: Attributes = [:], page: PageSetup, as format: DocFormat) throws -> Data
    {
        switch format {
        case .docx:
            return DocxWriter.data(from: text, page: page)
        case .md:
            return Data(Markdown.string(from: text).utf8)
        case .txt:
            return Data(plainText(text).utf8)
        case .pdf, .rtfd:
            throw FolioError("\(format.title) can't be written as a single file here.")
        default:
            guard let type = format.cocoaType else { throw FolioError("Folio can't write \(format.title) files.") }
            var attrs = attributes.merging(page.attributes) { $1 }
            attrs[.documentType] = type
            if format == .html || format == .webarchive { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
            do {
                return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attrs)
            } catch {
                throw FolioError("Folio couldn't encode this document as \(format.title).")
            }
        }
    }

    /// Plain text with list markers spelled out (they aren't characters on macOS 26+)
    /// and attachments removed.
    static func plainText(_ text: NSAttributedString) -> String {
        let ns = text.string as NSString
        var out = ""
        for range in ListFormatting.paragraphRanges(in: ns) where range.length > 0 {
            var line = ns.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
            let para = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            if let list = para?.textLists.last, !ListFormatting.markersInContent {
                let indent = String(repeating: "    ", count: max(0, (para?.textLists.count ?? 1) - 1))
                let marker = list.marker(forItemNumber: ListFormatting.itemNumber(at: range.location, in: text))
                line = indent + marker + " " + line
            }
            out += line
        }
        return out
    }

    /// UTF-8 when valid, otherwise Windows Latin 1 (what most legacy .txt files are).
    private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }
}

public import UniformTypeIdentifiers

/// The editor families Folio ships. Every file Folio can open maps to exactly one kind.
///
/// The app target uses this to build one `DocumentGroup` per kind, the Welcome window
/// uses it for the "New" tiles, and `Info.plist` declares the same content types
/// (see `Resources/Info.plist`; `make check-plist` verifies the two agree).
public nonisolated enum FileKind: String, CaseIterable, Identifiable, Sendable {
    case pdf
    case document
    case spreadsheet
    case image
    case code
    case media

    public var id: String { rawValue }

    /// Name shown in menus and the Welcome window.
    public var title: String {
        switch self {
        case .pdf: "PDF"
        case .document: "Document"
        case .spreadsheet: "Spreadsheet"
        case .image: "Image"
        case .code: "Text & Code"
        case .media: "Audio & Video"
        }
    }

    /// SF Symbol used wherever the kind is represented.
    public var symbol: String {
        switch self {
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .image: "photo"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .media: "play.rectangle"
        }
    }

    /// Content types this kind's editor can open. Order matters: the first type is the
    /// default for new documents created from the Welcome window.
    public var readableTypes: [UTType] {
        switch self {
        case .pdf: [.pdf]
        case .document: [.docx, .rtf, .rtfd, .odt, .html, .webArchive, .doc]
        case .spreadsheet: [.xlsx, .commaSeparatedText, .tabSeparatedText, .ods]
        case .image: [.png, .jpeg, .heic, .tiff, .gif, .bmp, .webP]
        case .code:
            [
                .plainText, .markdown, .json, .sourceCode, .script, .xml, .yaml, .propertyList, .css, .javaScript, .swiftSource,
                .pythonScript,
            ]
        case .media: [.audiovisualContent, .movie, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .mpeg4Audio]
        }
    }

    /// Resolve the kind for a file on disk, using its declared content type.
    public static func kind(for url: URL) -> FileKind? {
        guard
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: url.pathExtension)
        else { return nil }
        return kind(for: type)
    }

    /// Resolve the kind for a content type. More specific kinds win over broad ones
    /// (an HTML file is a document, not plain text).
    public static func kind(for type: UTType) -> FileKind? {
        let order: [FileKind] = [.pdf, .spreadsheet, .document, .image, .media, .code]
        return order.first { kind in kind.readableTypes.contains { type.conforms(to: $0) } }
    }
}

// Content types the SDK doesn't name. Each is declared by macOS itself, so `UTType(_:)`
// resolves without an import declaration in Info.plist.
public nonisolated extension UTType {
    static let docx = UTType("org.openxmlformats.wordprocessingml.document")!
    static let xlsx = UTType("org.openxmlformats.spreadsheetml.sheet")!
    static let odt = UTType("org.oasis-open.opendocument.text")!
    static let ods = UTType("org.oasis-open.opendocument.spreadsheet")!
    static let doc = UTType("com.microsoft.word.doc")!
    static let markdown = UTType("net.daringfireball.markdown")!
    static let css = UTType(filenameExtension: "css", conformingTo: .sourceCode) ?? .sourceCode
}

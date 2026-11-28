public import Foundation
public import UniformTypeIdentifiers

/// Every file format the conversion engine knows, by the short id people and agents type
/// (`folio convert clip.mov --to mp4`). The id is also the written file extension, except
/// for ``alac``, which is Apple Lossless audio in an `.m4a` file.
public nonisolated enum Format: String, CaseIterable, Codable, Sendable {
    // PDF
    case pdf
    // Documents
    case docx, doc, rtf, odt, html, md, txt
    // Spreadsheets
    case xlsx, ods, csv, tsv, json
    // Images
    case png, jpeg, heic, avif, tiff, gif, bmp, jp2, webp, jxl
    // Audio
    case m4a, alac, flac, wav, aiff, mp3
    // Video
    case mp4, mov, m4v

    public enum Family: String, Codable, Sendable, CaseIterable {
        case pdf, document, spreadsheet, image, audio, video
    }

    public var family: Family {
        switch self {
        case .pdf: .pdf
        case .docx, .doc, .rtf, .odt, .html, .md, .txt: .document
        case .xlsx, .ods, .csv, .tsv, .json: .spreadsheet
        case .png, .jpeg, .heic, .avif, .tiff, .gif, .bmp, .jp2, .webp, .jxl: .image
        case .m4a, .alac, .flac, .wav, .aiff, .mp3: .audio
        case .mp4, .mov, .m4v: .video
        }
    }

    public var fileExtension: String {
        switch self {
        case .alac: "m4a"
        case .jpeg: "jpg"
        default: rawValue
        }
    }

    public var contentType: UTType {
        switch self {
        case .alac, .m4a: .mpeg4Audio
        case .jp2: UTType("public.jpeg-2000") ?? .image
        case .jxl: UTType("public.jpeg-xl") ?? .image
        case .avif: UTType("public.avif") ?? .image
        case .md: UTType("net.daringfireball.markdown") ?? .plainText
        case .docx: UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        case .doc: UTType("com.microsoft.word.doc") ?? .data
        case .odt: UTType("org.oasis-open.opendocument.text") ?? .data
        case .xlsx: UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data
        case .ods: UTType("org.oasis-open.opendocument.spreadsheet") ?? .data
        case .tsv: .tabSeparatedText
        case .csv: .commaSeparatedText
        case .flac: UTType("org.xiph.flac") ?? .audio
        default: UTType(filenameExtension: fileExtension) ?? .data
        }
    }

    /// Short human name: "HEIC image", "Apple Lossless audio".
    public var title: String {
        switch self {
        case .alac: "Apple Lossless audio"
        case .m4a: "AAC audio"
        case .md: "Markdown"
        case .txt: "Plain text"
        case .jpeg: "JPEG image"
        default: rawValue.uppercased() + (family == .image ? " image" : family == .video ? " video" : family == .audio ? " audio" : "")
        }
    }

    /// Accepts ids, extensions and common aliases: "jpg", ".PNG", "markdown", "tif".
    public init?(id raw: String) {
        let id = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        switch id {
        case "jpg", "jpe": self = .jpeg
        case "tif": self = .tiff
        case "heif", "hif": self = .heic
        case "markdown", "mdown": self = .md
        case "text": self = .txt
        case "htm": self = .html
        case "aif": self = .aiff
        case "aac": self = .m4a
        case "j2k", "jpf": self = .jp2
        case "xlsm": self = .xlsx
        case "tab": self = .tsv
        case "qt": self = .mov
        default:
            guard let format = Format(rawValue: id) else { return nil }
            self = format
        }
    }

    /// The format of a file, from its extension. `m4a` files are reported as AAC; the
    /// audio converter refines that to ``alac`` when it opens the file.
    public static func detect(_ url: URL) -> Format? {
        Format(id: url.pathExtension)
    }
}

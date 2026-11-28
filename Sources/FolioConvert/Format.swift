import FolioKit
public import Foundation
public import UniformTypeIdentifiers

/// Every file format the conversion engine knows, by the short id people and agents type
/// (`folio convert clip.mov --to mp4`). The id is also the written file extension, except
/// where ``fileExtension`` says otherwise (``alac`` is Apple Lossless audio in an `.m4a` file).
public nonisolated enum Format: String, CaseIterable, Codable, Sendable {
    // PDF
    case pdf
    /// Illustrator: PDF-compatible `.ai` files open in PDFKit.
    case ai
    // Documents
    case docx, doc, rtf, odt, html, md, txt
    case rtfd, webarchive, epub, eml, mbox, pptx
    // Spreadsheets, and files that read as tables
    case xlsx, ods, csv, tsv, json
    case xls, jsonl, sqlite, ics, vcf, gpx, kml, geojson
    // Images
    case png, jpeg, heic, avif, tiff, gif, bmp, jp2, webp, jxl
    /// Every camera RAW extension (dng, cr2, nef, arw…); read-only, never a target.
    case raw
    case psd, ico, icns, exr, hdr, tga, pbm, apng, heics, svg
    // Audio
    case m4a, alac, flac, wav, aiff, mp3
    case ogg, opus, caf, aac, ac3, w64, m4b, mid
    // Video
    case mp4, mov, m4v
    case ts, mpg, threegp = "3gp", dv, mkv, webm
    /// ProRes in a `.mov`, as a target "for editing".
    case prores
    // Archives
    case zip, tar, tgz, tbz, txz, gz, bz2, xz, sevenZip = "7z", rar, iso, cpio, xar
    // Fonts
    case ttf, otf, ttc, woff, woff2
    // Subtitles
    case srt, vtt, ass
    // 3D models
    case usdz, usda, usdc, obj, stl, ply, abc
    // Data and config (json is a spreadsheet source; data converters can still target it)
    case plist, xml, yaml, toml, json5

    public enum Family: String, Codable, Sendable, CaseIterable {
        case pdf, document, spreadsheet, image, audio, video, archive, font, subtitle, model, data
    }

    public var family: Family {
        switch self {
        case .pdf, .ai: .pdf
        case .docx, .doc, .rtf, .odt, .html, .md, .txt, .rtfd, .webarchive, .epub, .eml, .mbox, .pptx: .document
        case .xlsx, .ods, .csv, .tsv, .json, .xls, .jsonl, .sqlite, .ics, .vcf, .gpx, .kml, .geojson: .spreadsheet
        case .png, .jpeg, .heic, .avif, .tiff, .gif, .bmp, .jp2, .webp, .jxl, .raw, .psd, .ico, .icns, .exr, .hdr, .tga, .pbm, .apng,
            .heics, .svg:
            .image
        case .m4a, .alac, .flac, .wav, .aiff, .mp3, .ogg, .opus, .caf, .aac, .ac3, .w64, .m4b, .mid: .audio
        case .mp4, .mov, .m4v, .ts, .mpg, .threegp, .dv, .mkv, .webm, .prores: .video
        case .zip, .tar, .tgz, .tbz, .txz, .gz, .bz2, .xz, .sevenZip, .rar, .iso, .cpio, .xar: .archive
        case .ttf, .otf, .ttc, .woff, .woff2: .font
        case .srt, .vtt, .ass: .subtitle
        case .usdz, .usda, .usdc, .obj, .stl, .ply, .abc: .model
        case .plist, .xml, .yaml, .toml, .json5: .data
        }
    }

    public var fileExtension: String {
        switch self {
        case .alac: "m4a"
        case .jpeg: "jpg"
        case .raw: "dng"
        case .prores: "mov"
        case .tgz: "tar.gz"
        case .tbz: "tar.bz2"
        case .txz: "tar.xz"
        default: rawValue
        }
    }

    public var contentType: UTType {
        switch self {
        case .alac, .m4a: .mpeg4Audio
        case .jp2: UTType("public.jpeg-2000") ?? .image
        case .jxl: UTType("public.jpeg-xl") ?? .image
        case .avif: UTType("public.avif") ?? .image
        case .md: .markdown
        case .docx: .docx
        case .doc: .doc
        case .odt: .odt
        case .xlsx: .xlsx
        case .ods: .ods
        case .tsv: .tabSeparatedText
        case .csv: .commaSeparatedText
        case .flac: UTType("org.xiph.flac") ?? .audio
        // Types macOS leaves dynamic (or ambiguous) by extension; FolioKit names them.
        case .ai: .illustrator
        case .rtfd: .rtfd
        case .mbox: .mbox
        case .jsonl: .jsonl
        case .sqlite: .sqlite
        case .gpx: .gpx
        case .kml: .kml
        case .raw: .rawImage
        case .apng: .apng
        case .mkv: .mkv
        case .prores: .quickTimeMovie
        case .tgz: .tarGzip
        case .tbz: .tarBzip2
        case .txz: .tarXZ
        case .rar: .rar
        case .woff: .woff
        case .woff2: .woff2
        case .srt: .srt
        case .ass: .ass
        case .toml: .toml
        case .json5: .json5
        default: UTType(filenameExtension: fileExtension) ?? .data
        }
    }

    /// Short human name: "HEIC image", "Apple Lossless audio".
    public var title: String {
        switch self {
        case .alac: "Apple Lossless audio"
        case .m4a: "AAC audio"
        case .aac: "AAC (ADTS) audio"
        case .md: "Markdown"
        case .txt: "Plain text"
        case .jpeg: "JPEG image"
        case .raw: "Camera RAW image"
        case .ai: "Illustrator file"
        case .mid: "MIDI file"
        case .prores: "ProRes video"
        case .sevenZip: "7-Zip archive"
        case .tgz, .tbz, .txz: fileExtension + " archive"
        case .jsonl: "JSON Lines"
        case .sqlite: "SQLite database"
        default: rawValue.uppercased() + noun
        }
    }

    private var noun: String {
        switch family {
        case .image: " image"
        case .video: " video"
        case .audio: " audio"
        case .archive: " archive"
        case .font: " font"
        case .subtitle: " subtitles"
        case .model: " model"
        default: ""
        }
    }

    /// Accepts ids, extensions and common aliases: "jpg", ".PNG", "markdown", "tif", "tar.gz".
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
        case "j2k", "jpf": self = .jp2
        case "xlsm", "xltx": self = .xlsx
        case "ots": self = .ods
        case "docm", "dotx": self = .docx
        case "ott": self = .odt
        case "tab": self = .tsv
        case "qt": self = .mov
        case "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "sr2", "srf", "raf", "orf", "rw2", "pef", "srw", "3fr", "iiq", "rwl",
            "x3f", "erf", "mrw", "mef", "mos", "kdc", "dcr":
            self = .raw
        case "cur": self = .ico
        case "pgm", "ppm", "pnm": self = .pbm
        case "oga": self = .ogg
        case "midi", "smf": self = .mid
        case "m2ts", "mts": self = .ts
        case "mpeg", "vob": self = .mpg
        case "3g2": self = .threegp
        case "tar.gz": self = .tgz
        case "tar.bz2", "tbz2": self = .tbz
        case "tar.xz": self = .txz
        case "otc": self = .ttc
        case "ssa": self = .ass
        case "yml": self = .yaml
        case "jsonc": self = .json5
        case "ndjson": self = .jsonl
        case "db", "sqlite3": self = .sqlite
        case "kmz": self = .kml  // a zipped KML; the table reader unzips it
        case "vcard": self = .vcf
        default:
            guard let format = Format(rawValue: id) else { return nil }
            self = format
        }
    }

    /// Formats whose extension spans two dots, longest first.
    static let compoundExtensions: [Format] = [.tgz, .tbz, .txz]

    /// The format of a file, from its extension (`archive.tar.gz` is ``tgz``). `m4a` files are
    /// reported as AAC; the audio converter refines that to ``alac`` when it opens the file.
    public static func detect(_ url: URL) -> Format? {
        let name = url.lastPathComponent.lowercased()
        return compoundExtensions.first { name.hasSuffix("." + $0.fileExtension) } ?? Format(id: url.pathExtension)
    }

    /// The file name without its format's extension: `photos.tar.gz` → `photos`.
    public static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        if let format = detect(url), compoundExtensions.contains(format) { return String(name.dropLast(format.fileExtension.count + 1)) }
        return url.deletingPathExtension().lastPathComponent
    }
}

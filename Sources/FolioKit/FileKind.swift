public import UniformTypeIdentifiers

/// The editor families Folio ships. Every file Folio can open maps to exactly one kind.
///
/// The app target uses this to build one `DocumentGroup` per kind, the workspace uses
/// it for kind icons and filters, and `Info.plist` declares the same content types
/// (see `Resources/Info.plist`; `make check-plist` verifies the two agree).
public nonisolated enum FileKind: String, CaseIterable, Identifiable, Sendable {
    case pdf
    case document
    case spreadsheet
    case image
    case code
    case media
    /// Zip, tar, 7z, rar, iso…: browsed and extracted, never edited.
    case archive
    /// Read-only Quick Look for files Folio can't edit: iWork, PowerPoint, fonts, 3D, Illustrator, EPS.
    case preview

    public var id: String { rawValue }

    /// Name shown in menus and the workspace.
    public var title: String {
        switch self {
        case .pdf: "PDF"
        case .document: "Document"
        case .spreadsheet: "Spreadsheet"
        case .image: "Image"
        case .code: "Text & Code"
        case .media: "Audio & Video"
        case .archive: "Archive"
        case .preview: "Preview"
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
        case .archive: "archivebox"
        case .preview: "eye"
        }
    }

    /// Content types this kind's editor can open. Order matters: the first type is the
    /// default for new, untitled documents (File › New).
    public var readableTypes: [UTType] {
        switch self {
        case .pdf: [.pdf]
        case .document: [.docx, .rtf, .rtfd, .odt, .html, .webArchive, .doc, .epub, .eml, .mbox]
        case .spreadsheet: [.xlsx, .commaSeparatedText, .tabSeparatedText, .ods, .xls, .sqlite, .ics, .vCard]
        case .image:
            [
                .png, .jpeg, .heic, .tiff, .gif, .bmp, .webP, .rawImage, .psd, .ico, .icns, .exr, .radiance, .tga, .pbm, .heics,
                .apng,
            ]
        case .code:
            [
                .plainText, .markdown, .json, .sourceCode, .script, .xml, .yaml, .propertyList, .css, .javaScript, .swiftSource,
                .pythonScript, .srt, .webVTT, .ass, .toml, .json5, .jsonl,
            ]
        case .media: [.audiovisualContent, .movie, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .mpeg4Audio]
        case .archive: [.zip, .tar, .gzip, .bz2, .xz, .tarXZ, .sevenZip, .rar, .iso, .cpio, .xar]
        case .preview:
            [
                .pages, .pagesPackage, .numbers, .numbersPackage, .keynote, .keynotePackage, .pptx, .ppt, .odp, .font, .usdz, .usd,
                .obj, .stl, .ply, .illustrator, .eps,
            ]
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
    /// (an HTML file is a document, not plain text; a .usda scene is a preview, not text).
    public static func kind(for type: UTType) -> FileKind? {
        let order: [FileKind] = [.pdf, .spreadsheet, .document, .image, .media, .archive, .preview, .code]
        return order.first { kind in kind.readableTypes.contains { type.conforms(to: $0) } }
    }
}

// Content types the SDK doesn't name. Most are declared by macOS itself; `system` falls back
// to an imported type so an identifier an older macOS lacks can't crash. The ones macOS
// leaves dynamic are imported in Info.plist (`UTImportedTypeDeclarations`).
public nonisolated extension UTType {
    static let docx = UTType("org.openxmlformats.wordprocessingml.document")!
    static let xlsx = UTType("org.openxmlformats.spreadsheetml.sheet")!
    static let odt = UTType("org.oasis-open.opendocument.text")!
    static let ods = UTType("org.oasis-open.opendocument.spreadsheet")!
    static let doc = UTType("com.microsoft.word.doc")!
    static let markdown = UTType("net.daringfireball.markdown")!
    static let css = system("public.css")

    private static func system(_ id: String) -> UTType { UTType(id) ?? UTType(importedAs: id) }

    // Documents and slides
    static let eml = system("com.apple.mail.email")
    static let mbox = UTType(importedAs: "org.ietf.mbox", conformingTo: .plainText)
    static let pptx = system("org.openxmlformats.presentationml.presentation")
    static let ppt = system("com.microsoft.powerpoint.ppt")
    static let odp = system("org.oasis-open.opendocument.presentation")
    static let pages = system("com.apple.iwork.pages.sffpages")
    static let pagesPackage = system("com.apple.iwork.pages.pages")
    static let numbers = system("com.apple.iwork.numbers.sffnumbers")
    static let numbersPackage = system("com.apple.iwork.numbers.numbers")
    static let keynote = system("com.apple.iwork.keynote.sffkey")
    static let keynotePackage = system("com.apple.iwork.keynote.key")
    // Tables
    static let xls = system("com.microsoft.excel.xls")
    static let sqlite = UTType(importedAs: "org.sqlite.sqlite3", conformingTo: .database)
    static let ics = system("com.apple.ical.ics")
    static let jsonl = UTType(importedAs: "org.jsonlines.jsonl", conformingTo: .plainText)
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
    static let kml = UTType(importedAs: "com.google.earth.kml", conformingTo: .xml)
    static let geojson = system("public.geojson")
    // Images and vector
    static let psd = system("com.adobe.photoshop-image")
    static let exr = system("com.ilm.openexr-image")
    static let radiance = system("public.radiance")
    static let tga = system("com.truevision.tga-image")
    static let pbm = system("public.pbm")
    static let heics = system("public.heics")
    static let apng = UTType(importedAs: "org.libpng.apng", conformingTo: .png)
    static let illustrator = system("com.adobe.illustrator.ai-image")
    static let eps = system("com.adobe.encapsulated-postscript")
    // Audio and video
    static let ogg = system("org.xiph.ogg-audio")
    static let caf = system("com.apple.coreaudio-format")
    static let aac = system("public.aac-audio")
    static let ac3 = system("public.ac3-audio")
    static let w64 = system("com.sony.wave64")
    static let m4b = system("com.apple.protected-mpeg-4-audio-b")
    static let threeGPP = system("public.3gpp")
    static let dv = system("public.dv-movie")
    static let mkv = UTType(importedAs: "org.matroska.mkv", conformingTo: .movie)
    static let webm = system("org.webmproject.webm")
    // Subtitles
    static let srt = UTType(importedAs: "com.subrip.srt", conformingTo: .plainText)
    static let webVTT = system("org.w3.webvtt")
    static let ass = UTType(importedAs: "org.aegisub.ass", conformingTo: .plainText)
    // Archives
    static let tar = system("public.tar-archive")
    static let tarGzip = system("org.gnu.gnu-zip-tar-archive")
    static let tarBzip2 = system("public.tar-bzip2-archive")
    static let xz = system("org.tukaani.xz-archive")
    static let tarXZ = system("org.tukaani.tar-xz-archive")
    static let sevenZip = system("org.7-zip.7-zip-archive")
    static let rar = UTType(importedAs: "com.rarlab.rar-archive", conformingTo: .archive)
    static let iso = system("public.iso-image")
    static let cpio = system("public.cpio-archive")
    static let xar = system("com.apple.xar-archive")
    // Fonts
    static let ttf = system("public.truetype-ttf-font")
    static let otf = system("public.opentype-font")
    static let ttc = system("public.truetype-collection-font")
    static let woff = UTType(importedAs: "org.w3.woff", conformingTo: .font)
    static let woff2 = UTType(importedAs: "org.w3.woff2", conformingTo: .font)
    // 3D
    static let usda = system("com.pixar.universal-scene-description-utf8")
    static let usdc = system("com.pixar.universal-scene-description-binary")
    static let obj = system("public.geometry-definition-format")
    static let stl = system("public.standard-tesselated-geometry-format")
    static let ply = system("public.polygon-file-format")
    static let alembic = system("public.alembic")
    // Data
    static let toml = UTType(importedAs: "io.toml", conformingTo: .plainText)
    static let json5 = UTType(importedAs: "org.json5.json5", conformingTo: .plainText)
    // Folio's own documents, exported in Info.plist for the 0.3 video and image editors.
    static let folioVideoProject = UTType(exportedAs: "app.folio.video-project", conformingTo: .json)
    static let folioImageDocument = UTType(exportedAs: "app.folio.image-document", conformingTo: .package)
}

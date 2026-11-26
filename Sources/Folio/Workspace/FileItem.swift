import FolioKit
import Foundation
import UniformTypeIdentifiers

/// One file or folder as the workspace shows it: a snapshot of its metadata, read off the
/// main thread and then passed around by value, so views never touch the disk while drawing.
nonisolated struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    /// File name with extension, as Finder shows it.
    let name: String
    let isFolder: Bool
    /// The Folio editor that opens it; `nil` for folders.
    let kind: FileKind?
    /// Bytes on disk; `nil` for folders.
    let size: Int64?
    let modified: Date
    /// When the file was last opened (Spotlight or Open Recent), if known.
    var lastUsed: Date?
    /// Carries the "Folio Favorite" Finder tag.
    var isFavorite: Bool

    var id: URL { url }

    /// The date the "Last opened" sort and the card subtitles use.
    var activityDate: Date { max(lastUsed ?? .distantPast, modified) }
    var baseName: String { isFolder ? name : (name as NSString).deletingPathExtension }
    var kindTitle: String { isFolder ? "Folder" : kind?.singularTitle ?? "File" }
    /// Size as a sortable number (folders sort as 0).
    var sizeValue: Int64 { size ?? 0 }
    /// The enclosing folder, abbreviated with `~` like Finder's path bar.
    var location: String { (url.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath }

    /// Reads one URL's metadata. Returns `nil` for hidden files and files Folio can't edit,
    /// so every list only ever shows things a double-click can open.
    static func load(_ url: URL, lastUsed: Date? = nil) -> FileItem? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey, .totalFileSizeKey, .contentModificationDateKey,
            .contentTypeKey, .tagNamesKey, .localizedNameKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys), values.isHidden != true else { return nil }
        let isFolder = values.isDirectory == true && values.isPackage != true
        let kind = isFolder ? nil : values.contentType.flatMap(FileKind.kind(for:))
        guard isFolder || kind != nil else { return nil }
        return FileItem(
            url: url,
            name: url.lastPathComponent,
            isFolder: isFolder,
            kind: kind,
            size: isFolder ? nil : Int64(values.totalFileSize ?? values.fileSize ?? 0),
            modified: values.contentModificationDate ?? .distantPast,
            lastUsed: lastUsed,
            isFavorite: values.tagNames?.contains(Favorites.tag) == true
        )
    }

    /// The visible contents of a folder: subfolders and files Folio can edit.
    static func list(folder: URL) -> [FileItem] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
        return urls.compactMap { load($0) }
    }
}

nonisolated extension FileKind {
    /// "Document", "Spreadsheet", … for the Kind column.
    var singularTitle: String {
        switch self {
        case .code: "Text"
        case .media: "Audio or video"
        default: title
        }
    }

    /// Filter chip titles: "Documents", "Spreadsheets", …
    var pluralTitle: String {
        switch self {
        case .pdf: "PDFs"
        case .document: "Documents"
        case .spreadsheet: "Spreadsheets"
        case .image: "Images"
        case .code: "Text & Code"
        case .media: "Audio & Video"
        }
    }
}

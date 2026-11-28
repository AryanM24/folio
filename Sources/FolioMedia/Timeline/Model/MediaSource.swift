import Foundation

/// A file the project uses. Media is referenced, never copied: the project keeps the path,
/// a bookmark (which follows renames and moves) and a fingerprint to tell whether the file
/// found is still the same one.
///
/// Facts that need AVFoundation (duration, frame rate, size) are filled in by whoever
/// imports the file (`MediaInfo`), so this model stays free of it.
nonisolated struct MediaSource: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case video, audio, image }

    var id = SourceID()
    /// The file name at import, for display.
    var name: String
    /// Absolute path where the file was last seen.
    var path: String
    /// Folio isn't sandboxed, so a plain bookmark is enough (no security scope).
    var bookmark: Data?
    var fingerprint: Fingerprint
    var kind: Kind
    /// `nil` for images.
    var duration: Time?
    var frameRate: FrameRate?
    /// Display size, after the file's own rotation.
    var width: Int?
    var height: Int?
    var hasAudio = false

    var url: URL { URL(filePath: path) }

    init(
        url: URL, kind: Kind, duration: Time?, frameRate: FrameRate? = nil, width: Int? = nil, height: Int? = nil, hasAudio: Bool
    ) throws {
        name = url.lastPathComponent
        path = url.path(percentEncoded: false)
        bookmark = try? url.bookmarkData()
        fingerprint = try Fingerprint(of: url)
        self.kind = kind
        self.duration = duration
        self.frameRate = frameRate
        self.width = width
        self.height = height
        self.hasAudio = hasAudio
    }

    /// A source described without touching the disk (tests, sources still being imported).
    init(name: String, path: String = "", kind: Kind, duration: Time?, frameRate: FrameRate? = nil, hasAudio: Bool = false) {
        self.name = name
        self.path = path
        fingerprint = Fingerprint(size: 0, modified: 0)
        self.kind = kind
        self.duration = duration
        self.frameRate = frameRate
        self.hasAudio = hasAudio
    }

    enum Resolution: Equatable, Sendable {
        /// At its path and unchanged.
        case found(URL)
        /// Renamed or moved: relink to this URL.
        case moved(URL)
        /// A file is there but it isn't the one imported (different size or date).
        case changed(URL)
        case missing
    }

    /// Where the file is now. Cheap: a stat or two and a bookmark lookup; nothing is decoded.
    func resolve() -> Resolution {
        let here = url
        if (try? Fingerprint(of: here)) == fingerprint { return .found(here) }
        let followed = followBookmark()
        if let followed, (try? Fingerprint(of: followed)) == fingerprint { return .moved(followed) }
        if FileManager.default.fileExists(atPath: path) { return .changed(here) }
        if let followed { return .changed(followed) }
        return .missing
    }

    /// A file in `folder` (searched recursively, hidden files skipped) with the same
    /// fingerprint: how "Relink…" finds media that was copied to another disk or renamed.
    func findMatch(in folder: URL) -> URL? {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard
            let files = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return nil }
        for case let file as URL in files where (try? Fingerprint(of: file)) == fingerprint {
            return file
        }
        return nil
    }

    private func followBookmark() -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        else { return nil }
        return url
    }
}

/// Size and modification date: survives renames and copies that keep dates, changes when
/// the file's content is rewritten. The source's duration is the third check, made by the
/// importer that can read it.
nonisolated struct Fingerprint: Codable, Hashable, Sendable {
    var size: Int64
    /// Seconds since 1970.
    var modified: Double

    init(size: Int64, modified: Double) {
        self.size = size
        self.modified = modified
    }

    init(of url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadNoSuchFile) }
        size = Int64(values.fileSize ?? 0)
        modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
    }
}

nonisolated extension Project {
    /// Points a source at `url` (after "Relink…" or a resolved move).
    mutating func relink(_ id: SourceID, to url: URL) throws {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { throw EditError.sourceNotFound }
        sources[i].path = url.path(percentEncoded: false)
        sources[i].bookmark = try? url.bookmarkData()
        sources[i].fingerprint = try Fingerprint(of: url)
    }
}

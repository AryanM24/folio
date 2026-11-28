import CryptoKit
import FolioKit
import Foundation

/// Lets edits stay non-destructive across closing and reopening a file.
///
/// When Folio saves an edited image it also records, keyed by the SHA-256 of the
/// bytes it just wrote: the recipe, the assets the recipe refers to (layer pixels,
/// patches, masks, LUTs), and (once per original) a pristine copy of the original file.
/// Reopening a file whose bytes hash to a known key restores the original, the recipe
/// and the assets, so you can keep adjusting, or Reset All, without stacking another
/// generation of JPEG loss.
///
/// Why content hashes instead of an `app.folio.recipe` extended attribute on the file:
/// `ReferenceFileDocument` hands back a `FileWrapper`, which can not carry xattrs, and
/// the NSDocument safe-save copies the old file xattrs onto the new one, so a recipe
/// attribute would go stale the moment anything else saved the file. A hash can not go
/// stale: if another app changes the file, the hash no longer matches and Folio
/// simply opens the new pixels. It also survives renames and moves, and keeps
/// multi-megabyte originals out of the file metadata.
///
/// Privacy: when the recipe removes metadata or redacts, no session is stored, because
/// the pristine copy would still contain what the user asked to remove (see
/// `ImageDocument.updateSession`). Sessions live in
/// `~/Library/Application Support/Folio/Image Sessions` and are pruned after 30 days or
/// beyond 2 GB.
nonisolated struct EditSessionStore: Sendable {
    let root: URL

    static let shared = EditSessionStore(
        root: URL.applicationSupportDirectory.appending(path: "Folio/Image Sessions", directoryHint: .isDirectory))

    struct Session: Codable, Sendable {
        var version = EditRecipe.version
        var originalKey: String
        var originalType: String
        var recipe: EditRecipe
        /// Blobs in `assets/`; `nil` in sessions written before 0.3.
        var assets: [AssetID]?
    }

    struct Restored: Sendable {
        let original: Data
        let originalTypeIdentifier: String
        let recipe: EditRecipe
        let key: String
        let assets: [AssetID: Data]
    }

    private var sessions: URL { root.appending(path: "sessions", directoryHint: .isDirectory) }
    private var originals: URL { root.appending(path: "originals", directoryHint: .isDirectory) }
    private var assetsFolder: URL { root.appending(path: "assets", directoryHint: .isDirectory) }

    static func key(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The blobs of `assets` that `recipe` refers to. IDs are SHA-256 hex, so finding one in
    /// the encoded recipe means it is referenced (no list of every place an ID can hide).
    static func referenced(_ assets: [AssetID: Data], by recipe: EditRecipe) -> [AssetID: Data] {
        guard !assets.isEmpty, let json = try? JSONEncoder().encode(recipe) else { return [:] }
        let text = String(decoding: json, as: UTF8.self)
        return assets.filter { text.contains($0.key) }
    }

    /// Record that `output` (just saved) is `recipe` applied to `original`, with the
    /// `assets` it refers to. Returns the session key, so the previous one can be removed on
    /// the next save.
    @discardableResult
    func record(
        output: Data, original: Data, originalTypeIdentifier: String, recipe: EditRecipe, assets: [AssetID: Data] = [:]
    ) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
        let originalKey = Self.key(for: original)
        let originalURL = originals.appending(path: originalKey)
        if !fm.fileExists(atPath: originalURL.path(percentEncoded: false)) {
            try original.write(to: originalURL, options: .atomic)
        }
        if !assets.isEmpty { try fm.createDirectory(at: assetsFolder, withIntermediateDirectories: true) }
        for (id, data) in assets {
            let url = assetsFolder.appending(path: id)
            if !fm.fileExists(atPath: url.path(percentEncoded: false)) { try data.write(to: url, options: .atomic) }
        }
        let key = Self.key(for: output)
        let session = Session(
            originalKey: originalKey, originalType: originalTypeIdentifier, recipe: recipe, assets: assets.keys.sorted())
        try JSONEncoder().encode(session).write(to: sessions.appending(path: "\(key).json"), options: .atomic)
        return key
    }

    /// The original, recipe and assets behind `fileData`, if Folio saved exactly these bytes.
    func restore(fileData: Data) -> Restored? {
        let key = Self.key(for: fileData)
        guard let json = try? Data(contentsOf: sessions.appending(path: "\(key).json")),
            let session = try? JSONDecoder().decode(Session.self, from: json),
            session.version <= EditRecipe.version,
            let original = try? Data(contentsOf: originals.appending(path: session.originalKey)),
            Self.key(for: original) == session.originalKey
        else { return nil }
        var assets: [AssetID: Data] = [:]
        for id in session.assets ?? [] {
            // A missing or damaged blob only loses that layer; the rest still restores.
            if let data = try? Data(contentsOf: assetsFolder.appending(path: id)), Self.key(for: data) == id { assets[id] = data }
        }
        return Restored(
            original: original, originalTypeIdentifier: session.originalType, recipe: session.recipe, key: key, assets: assets)
    }

    func remove(key: String) {
        try? FileManager.default.removeItem(at: sessions.appending(path: "\(key).json"))
    }

    /// Delete sessions older than `maxAge`, then the oldest until under `maxBytes`,
    /// then any original or asset no session refers to.
    func prune(maxAge: TimeInterval = 30 * 24 * 3600, maxBytes: Int = 2 << 30, now: Date = .now) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let sessionFiles = (try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: keys)) ?? []
        var live: [(url: URL, date: Date, original: String, assets: [AssetID])] = []
        for url in sessionFiles {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(date) < maxAge,
                let data = try? Data(contentsOf: url),
                let session = try? JSONDecoder().decode(Session.self, from: data)
            else { try? fm.removeItem(at: url); continue }
            live.append((url, date, session.originalKey, session.assets ?? []))
        }
        live.sort { $0.date > $1.date }
        var total = 0
        var kept = Set<String>()
        var keptAssets = Set<AssetID>()
        for entry in live {
            let size = (try? originals.appending(path: entry.original).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let isNew = !kept.contains(entry.original)
            if isNew, total + size > maxBytes {
                try? fm.removeItem(at: entry.url)
                continue
            }
            if isNew { total += size; kept.insert(entry.original) }
            keptAssets.formUnion(entry.assets)
        }
        for (folder, keep) in [(originals, kept), (assetsFolder, keptAssets)] {
            for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            where !keep.contains(url.lastPathComponent) {
                // A save writes the original and assets before its session; do not race a save in flight.
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(date) > 3600 { try? fm.removeItem(at: url) }
            }
        }
    }
}

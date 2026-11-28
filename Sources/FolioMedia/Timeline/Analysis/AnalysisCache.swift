import CryptoKit
import Foundation

/// Progress from 0 to 1. Analyses call it from whatever thread they run on.
typealias AnalysisProgress = @Sendable (Double) -> Void

/// Analysis results on disk (`~/Library/Caches/app.folio/Analysis/<kind>/`), keyed by the
/// media's fingerprint and the parameters, so a second run (or reopening a project) is
/// instant and a moved file still hits.
///
/// Values are JSON; products that are media (mask movies, isolated voice, reversed proxies)
/// are files. Both are written to a temporary name and moved into place, so a cancelled or
/// failed analysis never leaves a half-written entry.
nonisolated struct AnalysisCache: Sendable {
    let root: URL

    static let shared = AnalysisCache(
        root: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appending(path: "app.folio/Analysis"))

    struct Key: Hashable, Sendable {
        /// The analysis, e.g. "silence". Also the cache subfolder.
        let kind: String
        /// SHA-256 of the fingerprint and parameters.
        let hash: String

        /// `version` changes when an analysis' output changes, so old entries stop matching.
        init(_ kind: String, version: Int = 1, fingerprint: Fingerprint, parameters: [String] = []) {
            self.kind = kind
            let text = ([kind, "v\(version)", "\(fingerprint.size)", "\(fingerprint.modified)"] + parameters).joined(separator: "|")
            hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        init(_ kind: String, version: Int = 1, media: URL, parameters: [String] = []) throws {
            // A fresh URL: URL objects cache resource values, so a reused one would miss a rewrite.
            let fresh = URL(filePath: media.path(percentEncoded: false))
            self.init(kind, version: version, fingerprint: try Fingerprint(of: fresh), parameters: parameters)
        }
    }

    func url(for key: Key, extension ext: String) -> URL {
        root.appending(path: key.kind).appending(path: "\(key.hash).\(ext)")
    }

    /// The cached file, if the analysis has run.
    func existing(_ key: Key, extension ext: String) -> URL? {
        let url = url(for: key, extension: ext)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    func cachedValue<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        guard let url = existing(key, extension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try? decoder.decode(T.self, from: data)
    }

    /// The cached value, or `compute`'s result, stored for next time.
    func value<T: Codable & Sendable>(_ key: Key, compute: () async throws -> T) async throws -> T {
        if let hit: T = cachedValue(key) { return hit }
        let value = try await compute()
        let encoder = JSONEncoder()
        // Silence measures -infinity LUFS, which plain JSON can't hold.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try? store(key, extension: "json") { try encoder.encode(value).write(to: $0) }
        return value
    }

    /// The cached file, or the one `produce` writes to the URL it's given.
    func file(_ key: Key, extension ext: String, produce: (URL) async throws -> Void) async throws -> URL {
        if let hit = existing(key, extension: ext) { return hit }
        let destination = url(for: key, extension: ext)
        let temp = try temporaryURL(beside: destination)
        defer { try? FileManager.default.removeItem(at: temp) }
        try await produce(temp)
        try Task.checkCancellation()
        try moveIntoPlace(temp, destination)
        return destination
    }

    /// Empties the cache (Settings › Clear caches, and tests).
    func removeAll() throws {
        if FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func store(_ key: Key, extension ext: String, _ write: (URL) throws -> Void) throws {
        let destination = url(for: key, extension: ext)
        let temp = try temporaryURL(beside: destination)
        defer { try? FileManager.default.removeItem(at: temp) }
        try write(temp)
        try moveIntoPlace(temp, destination)
    }

    private func temporaryURL(beside destination: URL) throws -> URL {
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: ".\(UUID().uuidString)-\(destination.lastPathComponent)")
    }

    private func moveIntoPlace(_ temp: URL, _ destination: URL) throws {
        let fm = FileManager.default
        // Another run of the same analysis may have finished first; its result is as good.
        do {
            try fm.moveItem(at: temp, to: destination)
        } catch  where fm.fileExists(atPath: destination.path(percentEncoded: false)) {}
    }
}

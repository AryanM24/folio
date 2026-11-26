import AppKit
import QuickLookThumbnailing

/// Quick Look thumbnails for file cards, cached in memory for the session.
///
/// Cards ask for their thumbnail in `.task` as they scroll into view, so nothing is
/// generated for files nobody looks at, and generation runs in Quick Look's own
/// processes, never on the main thread. The cache key includes the modification date,
/// so an edited file gets a fresh thumbnail.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 400 }

    func cached(_ item: FileItem) -> NSImage? { cache.object(forKey: key(item)) }

    func load(_ item: FileItem, size: CGSize) async -> NSImage? {
        if let hit = cached(item) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url, size: size, scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage else { return nil }
        cache.setObject(image, forKey: key(item))
        return image
    }

    private func key(_ item: FileItem) -> NSString {
        "\(item.url.path(percentEncoded: false))|\(item.modified.timeIntervalSinceReferenceDate)" as NSString
    }
}

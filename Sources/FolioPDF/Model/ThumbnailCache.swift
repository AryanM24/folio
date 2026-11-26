import AppKit
import PDFKit

/// Page thumbnails for the sidebar, rendered off the main actor and cached per page.
///
/// Rendering is lazy: the sidebar asks only for rows on screen, so opening a
/// 500-page PDF renders about a dozen thumbnails, not 500. Edits invalidate the
/// pages they touch (see `PDFEditorModel.mutate`).
final class ThumbnailCache {
    private let cache = NSCache<PDFPage, NSImage>()

    init() { cache.countLimit = 400 }

    func cached(_ page: PDFPage) -> NSImage? { cache.object(forKey: page) }

    func invalidate(_ page: PDFPage) { cache.removeObject(forKey: page) }

    /// A thumbnail at most `side` points on its longer edge, rendered at 2x.
    func load(_ page: PDFPage, access: PDFAccess, side: CGFloat) async -> NSImage? {
        if let image = cache.object(forKey: page) { return image }
        let box = Unchecked(value: page)
        let rendered = await Task.detached(priority: .userInitiated) {
            access.withLock { _ in
                Unchecked(value: box.value.thumbnail(of: CGSize(width: side * 2, height: side * 2), for: .cropBox))
            }
        }.value.value
        cache.setObject(rendered, forKey: page)
        return rendered
    }
}

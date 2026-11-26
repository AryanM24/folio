import FolioKit
import Foundation

/// A live Spotlight query (`NSMetadataQuery`) that reports matching file URLs, with
/// their last-used dates, whenever results arrive or change.
///
/// Spotlight gathers on its own threads and posts to the main queue, so starting one
/// costs nothing at launch: results stream in after the window is already on screen.
final class SpotlightSearch {
    private let query = NSMetadataQuery()
    private var observers: [any NSObjectProtocol] = []
    private let limit: Int
    private let onChange: ([(url: URL, lastUsed: Date?)]) -> Void

    init(predicate: NSPredicate, scopes: [Any], limit: Int = 300, onChange: @escaping ([(url: URL, lastUsed: Date?)]) -> Void) {
        self.limit = limit
        self.onChange = onChange
        query.predicate = predicate
        query.searchScopes = scopes
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        query.notificationBatchingInterval = 0.5
    }

    func start() {
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publish() }
                })
        }
        query.start()
    }

    func stop() {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func publish() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var out: [(url: URL, lastUsed: Date?)] = []
        for index in 0..<min(query.resultCount, limit) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            out.append((URL(fileURLWithPath: path), item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date))
        }
        onChange(out)
    }

    /// Files Folio can edit, opened in the last `days` days.
    static func recentPredicate(days: Int = 30) -> NSPredicate {
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        let types = FileKind.allCases.flatMap(\.readableTypes).map(\.identifier)
        let anyType = NSCompoundPredicate(
            orPredicateWithSubpredicates: types.map { NSPredicate(format: "%K == %@", NSMetadataItemContentTypeTreeKey, $0) })
        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "%K >= %@", NSMetadataItemLastUsedDateKey, since as NSDate), anyType,
        ])
    }

    /// Files carrying the "Folio Favorite" Finder tag.
    static var favoritesPredicate: NSPredicate {
        NSPredicate(format: "kMDItemUserTags == %@", Favorites.tag)
    }

    /// Paths Recent should never show: app data, caches, the Trash and app bundles.
    nonisolated static func isNoise(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/Library/") || path.contains("/.") || path.contains("/Caches/")
            || path.contains(".app/") || path.hasPrefix("/System/") || path.hasPrefix("/private/var/")
    }
}

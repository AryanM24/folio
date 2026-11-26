import FolioKit
import Foundation

// Pure logic behind the workspace: filtering, sorting, fuzzy matching, dates and names.
// Kept free of UI and disk access so Tests/FolioTests can check it directly.

/// Which kinds a file view shows. `nil` kind means "All".
nonisolated struct KindFilter: Hashable, Sendable {
    var kind: FileKind?

    static let all = KindFilter(kind: nil)

    func matches(_ item: FileItem) -> Bool { kind == nil || item.kind == kind }

    /// The chips to show for `items`: "All" plus each kind actually present, in a fixed
    /// order, with how many items each would show.
    static func chips(for items: [FileItem]) -> [(filter: KindFilter, count: Int)] {
        let counts = Dictionary(grouping: items.compactMap(\.kind), by: { $0 }).mapValues(\.count)
        let order: [FileKind] = [.pdf, .document, .spreadsheet, .image, .code, .media]
        return [(.all, items.count)] + order.compactMap { kind in counts[kind].map { (KindFilter(kind: kind), $0) } }
    }
}

/// The sort menu's choices. Folders always come first, like Finder's "Keep folders on top".
nonisolated enum FileSort: String, CaseIterable, Identifiable, Sendable {
    case lastOpened, name, size, kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastOpened: "Last opened"
        case .name: "Name"
        case .size: "Size"
        case .kind: "Kind"
        }
    }

    /// The direction people expect when they first pick a column: newest and biggest first.
    var defaultAscending: Bool { self == .name || self == .kind }

    func sorted(_ items: [FileItem], ascending: Bool) -> [FileItem] {
        items.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let order = compare(a, b)
            if order == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private func compare(_ a: FileItem, _ b: FileItem) -> ComparisonResult {
        switch self {
        case .lastOpened:
            a.activityDate == b.activityDate ? .orderedSame : (a.activityDate < b.activityDate ? .orderedAscending : .orderedDescending)
        case .name: a.name.localizedStandardCompare(b.name)
        case .size: a.sizeValue == b.sizeValue ? .orderedSame : (a.sizeValue < b.sizeValue ? .orderedAscending : .orderedDescending)
        case .kind: a.kindTitle.localizedStandardCompare(b.kindTitle)
        }
    }
}

/// Search and filter for every file view: what you type matches the name, in order but
/// not necessarily adjacent ("qrpt" finds "Q3 report.pdf").
nonisolated enum FileQuery {
    static func apply(_ items: [FileItem], query: String, filter: KindFilter, sort: FileSort, ascending: Bool) -> [FileItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let matching = items.filter { filter.matches($0) && (q.isEmpty || FuzzyMatch.score(q, in: $0.name) != nil) }
        return sort.sorted(matching, ascending: ascending)
    }
}

/// Command-palette style subsequence matching with a score, so the best match sorts first.
nonisolated enum FuzzyMatch {
    /// `nil` when `query`'s characters don't all appear in `candidate` in order.
    /// Higher is better: consecutive runs, matches at word starts and a matching prefix
    /// score more; long candidates score slightly less.
    static func score(_ query: String, in candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate.lowercased())
        var score = 0
        var qi = 0
        var previous = -2
        for (ci, char) in c.enumerated() where qi < q.count && char == q[qi] {
            score += 1
            if ci == previous + 1 { score += 5 }
            if ci == 0 { score += 10 } else if !c[ci - 1].isLetter && !c[ci - 1].isNumber { score += 8 }
            previous = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score * 10 - c.count
    }
}

/// Short, human dates for cards and lists: "Just now", "5 min ago", "Yesterday", "Mar 4".
nonisolated enum RelativeDate {
    static func string(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) hr ago" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if seconds < 6 * 86400 {
            style = style.weekday(.wide)
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            style = style.month(.abbreviated).day()
        } else {
            style = style.month(.abbreviated).day().year()
        }
        return date.formatted(style)
    }
}

/// Rules for renaming in place, the way Finder applies them.
nonisolated enum FileNaming {
    /// The URL `url` would move to when renamed to `input`, or `nil` when the name is
    /// unusable (empty, contains "/" or ":", or starts with a dot, which would hide it).
    /// If the person drops the extension, the original one is kept, so a document never
    /// silently stops opening in its editor.
    static func renamed(_ url: URL, to input: String, isFolder: Bool) -> URL? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else { return nil }
        let ext = url.pathExtension
        let keepsExtension = isFolder || ext.isEmpty || (name as NSString).pathExtension.lowercased() == ext.lowercased()
        return url.deletingLastPathComponent().appending(path: keepsExtension ? name : "\(name).\(ext)")
    }
}

/// Byte counts the way Finder prints them ("1.2 MB").
nonisolated func formattedSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Whether a file sits inside one of the folders the user chose (library, locations).
nonisolated enum TrustedFolders {
    /// True when `url` is `root` itself or anywhere beneath it.
    ///
    /// Compares normalised paths: `URL.path(percentEncoded:)` keeps a trailing slash on
    /// directory URLs, and a naive `root + "/"` prefix then never matches. That bug once
    /// hid every Recent file in libraries outside ~/Documents.
    static func contains(_ url: URL, in roots: [URL]) -> Bool {
        let path = normalized(url)
        return roots.contains { root in
            let base = normalized(root)
            return path == base || path.hasPrefix(base + "/")
        }
    }

    private static func normalized(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

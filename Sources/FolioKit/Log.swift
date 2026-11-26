public import OSLog

/// Unified logging. Read with `log stream --predicate 'subsystem == "app.folio"'`.
///
/// Use one category per module so Console filtering stays useful:
/// ```swift
/// private let log = Log.make("PDF")
/// log.error("Couldn't write \(url, privacy: .private): \(error)")
/// ```
/// File names and paths are user data: mark them `privacy: .private`.
public enum Log {
    public nonisolated static let subsystem = "app.folio"

    public nonisolated static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}

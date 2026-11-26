import AppKit
import FolioKit
import UniformTypeIdentifiers

/// Shows each editor's own menus (PDF, Image, Media, Text, Insert, Data) only while a
/// window of that editor is in front, the way Preview and Pages do.
///
/// SwiftUI `Commands` can't be conditional, and every editor's commands are registered
/// app-wide. Their items already disable themselves when their editor isn't focused, so
/// shortcuts never collide; this removes the visual clutter of seeing them all at once.
/// SwiftUI may rebuild the main menu at any time, so visibility is re-applied whenever
/// AppKit updates the app (cheap: a dozen top-level items).
enum MenuVisibility {
    /// Top-level menu titles owned by one editor.
    private static let owners: [String: FileKind] = [
        "PDF": .pdf, "Image": .image, "Media": .media, "Text": .code, "Insert": .spreadsheet, "Data": .spreadsheet,
    ]

    static func install() {
        NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply() }
        }
    }

    private static func apply() {
        guard let items = NSApp.mainMenu?.items else { return }
        let active = activeKind()
        for item in items {
            guard let owner = owners[item.title] else { continue }
            let hidden = owner != active
            if item.isHidden != hidden { item.isHidden = hidden }
        }
    }

    /// The editor kind of the front document window, or `nil` for Welcome, Settings or none.
    private static func activeKind() -> FileKind? {
        guard let window = NSApp.mainWindow,
            let document = NSDocumentController.shared.document(for: window),
            let typeName = document.fileType,
            let type = UTType(typeName)
        else { return nil }
        return FileKind.kind(for: type)
    }
}

import AppKit

/// Development aid: writes a PNG of each window shortly after it becomes key.
///
/// Enabled only when `FOLIO_SNAPSHOT_DIR` is set, e.g. through `scripts/snapshot.sh`:
/// ```sh
/// scripts/snapshot.sh path/to/file.pdf   # → build/snapshots/<window title>.png
/// ```
/// The app draws its own view hierarchy into a bitmap, so this needs no
/// screen-recording permission and works in CI. Used for README screenshots
/// and for checking UI changes without a display.
enum WindowSnapshots {
    static func enableIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT_DIR"] else { return }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        switch ProcessInfo.processInfo.environment["FOLIO_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let delay = Double(ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT_DELAY"] ?? "") ?? 1.5
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { write(window, to: folder) }
            }
        }
    }

    private static func write(_ window: NSWindow, to folder: URL) {
        // The theme frame (contentView's superview) includes the title bar and toolbar.
        guard let view = window.contentView?.superview ?? window.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let name = window.title.isEmpty ? "window-\(window.windowNumber)" : window.title
        let dark = ProcessInfo.processInfo.environment["FOLIO_APPEARANCE"] == "dark"
        let safe = name.replacingOccurrences(of: "/", with: "-") + (dark ? " (dark)" : "")
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(safe).png"))
    }
}

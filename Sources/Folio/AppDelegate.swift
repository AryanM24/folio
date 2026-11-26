import AppKit
import FolioKit
import Quartz

/// App-level hooks SwiftUI doesn't expose: autosave timing, Finder Quick Actions, and the
/// Quick Look panel's data source for the workspace.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Log.make("App")

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Save edits about a second after the user pauses, instead of AppKit's default
        // of several seconds. Writes are atomic (temp file + rename), so a crash or
        // power loss mid-save never leaves a half-written file.
        NSDocumentController.shared.autosavingDelay = 1
        WindowSnapshots.enableIfRequested()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Finder > Quick Actions and the Services menu call `runTool(_:userData:error:)`.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        MenuVisibility.install()
    }

    /// Quit fast: documents are already saved as you type, so there is nothing to wait for
    /// beyond AppKit's own final autosave of any still-dirty document.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // The Quick Look panel looks for a controller along the responder chain, which ends at
    // the app delegate. The workspace's selection is the only thing Folio previews.
    // The panel calls these on the main thread.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { !QuickLook.shared.urls.isEmpty }
    }
    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = QuickLook.shared }
    }
    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    /// Entry point for every `NSServices` item in Info.plist. `userData` is a `FolioTool.id`.
    @objc func runTool(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let tool = ToolCatalog.tool(id: userData) else {
            log.error("Unknown service tool \(userData, privacy: .public)")
            error.pointee = "Unknown tool" as NSString
            return
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        ToolRunner.shared.start(tool, inputs: urls)
    }
}

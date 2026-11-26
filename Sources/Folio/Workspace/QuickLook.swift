import AppKit
import Quartz

/// Space-bar previews through the system Quick Look panel, like Finder.
///
/// The panel finds its data source by walking the responder chain; `AppDelegate`
/// answers for the app and hands the panel this object.
final class QuickLook: NSObject {
    static let shared = QuickLook()

    private(set) var urls: [URL] = []

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    /// Opens the panel on `urls`, or closes it if it's already open (Space toggles).
    func toggle(_ urls: [URL]) {
        if isVisible {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        guard !urls.isEmpty else { return }
        self.urls = urls
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        QLPreviewPanel.shared().reloadData()
    }

    /// Follows the selection while the panel is open, as Finder does.
    func follow(_ urls: [URL]) {
        guard isVisible, !urls.isEmpty, urls != self.urls else { return }
        self.urls = urls
        QLPreviewPanel.shared().reloadData()
    }
}

extension QuickLook: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}

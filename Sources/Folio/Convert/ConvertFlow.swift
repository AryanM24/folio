import AppKit
import FolioConvert
import FolioKit
import UniformTypeIdentifiers

/// Every Convert entry point (context menu, ⌘K, Dock, Finder, the shelf, the clipboard)
/// ends here: run the engine, show progress and the result card, remember the result.
enum ConvertFlow {
    /// Opens the Convert panel. With no files, asks for some first.
    static func present(_ urls: [URL], preferring format: Format? = nil) {
        let files = urls.filter(\.isFileURL)
        guard files.isEmpty else { return ConvertPanelWindow.show(files, preferring: format) }
        Task {
            let picked = await Exporter.pick(types: readableTypes, multiple: true, window: nil)
            if !picked.isEmpty { ConvertPanelWindow.show(picked, preferring: format) }
        }
    }

    static func run(_ inputs: [URL], choice: ConvertChoice, outputDirectory: URL? = nil, primary: ResultCardModel.Primary = .reveal) {
        let request = ConvertRequest(
            inputs: inputs, target: choice.target, quality: choice.quality, maxBytes: choice.maxBytes,
            stripMetadata: choice.stripMetadata, outputDirectory: outputDirectory)
        run(request, primary: primary)
    }

    /// Same format, balanced, no panel: Finder's "Compress with Folio".
    static func compress(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        run(ConvertRequest(inputs: files, target: nil, quality: .balanced), primary: .reveal)
    }

    static func run(_ request: ConvertRequest, primary: ResultCardModel.Primary, cleanup: [URL] = []) {
        let card = ResultCard.begin(count: request.inputs.count, primary: primary)
        let task = Task {
            let report = await Engine.run(request) { fraction, name in
                Task { @MainActor in card.progress(fraction, name) }
            }
            cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
            let rows = report.results.map(ConvertRow.init)
            ConvertHistory.shared.add(rows)
            // A cancelled run that made nothing has nothing to show.
            if Task.isCancelled, !rows.contains(where: { $0.output != nil }) {
                card.dismiss()
            } else {
                card.finish(rows)
            }
        }
        card.onCancel = { task.cancel() }
    }

    // MARK: Clipboard

    /// Writes the clipboard's image to a temporary file and converts it into the folder the
    /// workspace shows, or Downloads. The card's main action is Copy.
    static func convertClipboard(to format: Format) {
        let pasteboard = NSPasteboard.general
        guard let data = pasteboard.data(forType: .tiff) ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation else {
            ResultCard.show([
                ConvertRow(
                    name: "the clipboard", bytesIn: 0, failed: true, message: "The clipboard has no image",
                    hint: "Copy an image, then try again")
            ])
            return
        }
        // TIFF in, so PNG/JPEG/HEIC out is always a real conversion rather than a skipped compress.
        let folder = FileManager.default.temporaryDirectory.appending(path: "Folio Clipboard/\(UUID().uuidString)")
        let input = folder.appending(path: "Clipboard image.tiff")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: input)
        } catch {
            ResultCard.show([ConvertRow(name: "the clipboard", bytesIn: 0, failed: true, message: error.localizedDescription)])
            return
        }
        let request = ConvertRequest(inputs: [input], target: format, quality: .balanced, outputDirectory: clipboardDestination)
        run(request, primary: .copy, cleanup: [folder])
    }

    /// The folder the workspace is showing, else ~/Downloads.
    static var clipboardDestination: URL {
        if case .folder(let url) = WorkspaceModel.shared.destination { return url }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Brings the workspace forward from AppKit code, which has no `openWindow`: runs
    /// Window › Folio Workspace, so it reopens the window even after it was closed.
    static func showWorkspace() {
        NSApp.activate()
        func perform(in menu: NSMenu?) -> Bool {
            for (index, item) in (menu?.items ?? []).enumerated() {
                if item.title == "Folio Workspace" {
                    menu?.performActionForItem(at: index)
                    return true
                }
                if perform(in: item.submenu) { return true }
            }
            return false
        }
        _ = perform(in: NSApp.mainMenu)
    }

    /// Every type Folio opens, for the file picker and Finder's Quick Actions.
    static var readableTypes: [UTType] {
        var seen = Set<String>()
        return FileKind.allCases.flatMap(\.readableTypes).filter { seen.insert($0.identifier).inserted }
    }
}

/// The last few results, newest first, for the shelf.
@Observable
final class ConvertHistory {
    static let shared = ConvertHistory()
    static let limit = 5

    private(set) var rows: [ConvertRow] = []

    func add(_ new: [ConvertRow]) {
        rows = Array((new.filter { $0.output != nil }.reversed() + rows).prefix(Self.limit))
    }

    func remove(_ outputs: [URL]) {
        rows.removeAll { $0.output.map(outputs.contains) == true }
    }
}

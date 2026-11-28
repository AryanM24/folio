import FolioKit
import SwiftUI

/// The context menu for one or more files, shared by cards and table rows. Mirrors
/// Finder's order: open, preview, organize, share, reveal, trash.
struct FileMenu: View {
    let model: WorkspaceModel
    let items: [FileItem]

    var body: some View {
        let files = items.filter { !$0.isFolder }
        Button(items.count > 1 ? "Open \(items.count) Items" : "Open") { model.open(items) }
        if let first = files.first, files.count == items.count {
            let apps = model.otherApps(for: first)
            if !apps.isEmpty {
                Menu("Open With") {
                    ForEach(apps, id: \.self) { app in
                        Button {
                            model.open(files, withApp: app)
                        } label: {
                            Label {
                                Text(FileManager.default.displayName(atPath: app.path(percentEncoded: false)))
                            } icon: {
                                Image(nsImage: Self.icon(for: app))
                            }
                        }
                    }
                }
            }
        }
        if !files.isEmpty {
            Button("Quick Look") { select { model.quickLook() } }
        }
        Divider()
        if items.count == 1 {
            Button("Rename") { select { model.beginRename() } }
        }
        Button("Duplicate") { select { model.duplicate() } }
        if !files.isEmpty {
            Button(files.allSatisfy(\.isFavorite) ? "Remove from Favorites" : "Add to Favorites") {
                model.setFavorite(!files.allSatisfy(\.isFavorite), files.map(\.url))
            }
        }
        Menu("Move To") {
            ForEach([model.libraryURL] + model.locations, id: \.self) { folder in
                Button(model.displayName(folder)) { select { model.moveSelection(to: folder) } }
            }
        }
        Divider()
        ShareLink("Share…", items: items.map(\.url))
        if !files.isEmpty, files.count == items.count {
            Button("Convert…") { ConvertFlow.present(files.map(\.url)) }
        }
        let tools = model.tools(for: files)
        if !tools.isEmpty, files.count == items.count {
            Menu("Tools") {
                ForEach(tools) { tool in
                    Button(tool.title) { model.runTool(tool, on: files) }
                }
            }
        }
        Divider()
        Button("Show in Finder") { select { model.showInFinder() } }
        Button("Copy Path") { select { model.copyPath() } }
        Divider()
        Button("Move to Trash") { select { model.trashSelection() } }
    }

    /// Context-menu actions act on what was right-clicked, like Finder: select it first.
    private func select(_ action: () -> Void) {
        model.selection = Set(items.map(\.url))
        action()
    }

    private static func icon(for app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path(percentEncoded: false))
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

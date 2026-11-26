import FolioKit
import SwiftUI

/// Menu bar commands for the workspace: a Go menu (Finder's shortcuts where they don't
/// clash with an editor), file actions in the File menu, and Window › Folio Workspace.
///
/// File actions are enabled only while the workspace window is key and nothing is being
/// typed, so ⌘⌫ never trashes a file while you edit a name, and editor menus that share
/// a shortcut (⌘D, ⌘R, ⌘L, ⌘[ …) keep working in editor windows.
struct WorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.workspace) private var focused

    private var model: WorkspaceModel { WorkspaceModel.shared }
    private var fileActionsDisabled: Bool { focused == nil || model.isEditingText }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Menu("New in Library") {
                ForEach(NewFile.allCases) { kind in
                    Button(kind.title) { model.create(kind, inCurrentFolder: false) }
                }
            }
        }
        CommandGroup(before: .saveItem) {
            Section {
                Button("Open Selection") { model.openSelection() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Quick Look") { model.quickLook() }
                    .keyboardShortcut("y")
                Button("Show in Finder") { model.showInFinder() }
                    .keyboardShortcut("r")
                Button("Copy Path") { model.copyPath() }
                    .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            }
            .disabled(fileActionsDisabled)
            Section {
                Button("Rename") { model.beginRename() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Duplicate") { model.duplicate() }
                    .keyboardShortcut("d")
                Button("Add to Favorites") { model.toggleFavorite() }
                    .keyboardShortcut("l")
                Button("Move to Trash") {
                    // Belt and braces: if the menu hasn't caught up with a field gaining focus,
                    // ⌘⌫ keeps its text meaning instead of trashing the selection.
                    if model.isEditingText {
                        NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
                    } else {
                        model.trashSelection()
                    }
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            .disabled(fileActionsDisabled)
        }
        CommandMenu("Go") {
            Section {
                Button("Back") { model.back() }
                    .keyboardShortcut("[")
                    .disabled(focused == nil || !model.canGoBack)
                Button("Forward") { model.forward() }
                    .keyboardShortcut("]")
                    .disabled(focused == nil || !model.canGoForward)
            }
            Section {
                go("Home", .home, key: "h")
                go("Recent", .recent, key: "f")
                go("Favorites", .favorites, key: "i")
                Button("Library") {
                    openWindow(id: WorkspaceWindow.id)
                    model.goToLibrary()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                go("Tools", .tools, key: "t")
            }
            Section {
                Button("Search") { model.searchFocusRequest += 1 }
                    .keyboardShortcut("f")
                    .disabled(focused == nil || model.isEditingText)
                Button("Command Palette…") {
                    openWindow(id: WorkspaceWindow.id)
                    model.showsPalette.toggle()
                }
                .keyboardShortcut("k")
                .disabled(focused == nil)
                Button(model.viewMode == .grid ? "Show as List" : "Show as Grid") {
                    model.viewMode = model.viewMode == .grid ? .list : .grid
                }
                .keyboardShortcut("2", modifiers: [.command, .control])
                .disabled(focused == nil)
            }
            Section {
                Button("Add Location…") { model.addLocationWithPanel() }
            }
        }
        CommandGroup(before: .windowList) {
            Button("Folio Workspace") { openWindow(id: WorkspaceWindow.id) }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            Divider()
        }
    }

    /// Go › destination: brings the workspace forward from anywhere and navigates.
    private func go(_ title: String, _ destination: Destination, key: KeyEquivalent) -> some View {
        Button(title) {
            openWindow(id: WorkspaceWindow.id)
            model.go(destination)
        }
        .keyboardShortcut(key, modifiers: [.command, .shift])
    }
}

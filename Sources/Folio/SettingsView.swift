import FolioKit
import SwiftUI

/// Folio > Settings (⌘,). Each editor stores its preferences under `<module>.<key>`
/// in `UserDefaults` via `@AppStorage`, and gets one tab here.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Editor", systemImage: "chevron.left.forwardslash.chevron.right") { CodeSettings() }
            Tab("Agents", systemImage: "sparkles") { AgentsSettings() }
        }
        .frame(width: 460)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    /// Named for the window the workspace replaced, so existing choices carry over.
    @AppStorage("general.showWelcome") private var showWorkspace = true
    @AppStorage(ViewMode.key) private var viewMode = ViewMode.grid.rawValue
    @State private var libraryPath = Library.url.path(percentEncoded: false)

    var body: some View {
        Form {
            Toggle("Open the workspace at launch", isOn: $showWorkspace)
            LabeledContent("Library folder") {
                VStack(alignment: .leading, spacing: 6) {
                    Text((libraryPath as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Change…", action: chooseLibrary)
                            .disabled(Library.isIsolated)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: libraryPath)])
                        }
                    }
                }
            }
            Picker("Show files as", selection: $viewMode) {
                Text("Grid").tag(ViewMode.grid.rawValue)
                Text("List").tag(ViewMode.list.rawValue)
            }
            .onChange(of: viewMode) { WorkspaceModel.shared.viewMode = ViewMode(rawValue: viewMode) ?? .grid }
            LabeledContent("Saving") {
                Text("Folio saves as you edit. Use File > Revert To to go back to any earlier version.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension GeneralSettings {
    /// New files are saved in the library folder; pick any folder, existing or new.
    fileprivate func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose where Folio saves new files."
        panel.directoryURL = Library.url
        guard panel.runModal() == .OK, let url = panel.url else { return }
        WorkspaceModel.shared.setLibrary(url)
        libraryPath = url.path(percentEncoded: false)
    }
}

private struct CodeSettings: View {
    @AppStorage("code.fontSize") private var fontSize = 13.0
    @AppStorage("code.wrapLines") private var wrapLines = true
    @AppStorage("code.showLineNumbers") private var showLineNumbers = true
    @AppStorage("code.tabWidth") private var tabWidth = 4

    var body: some View {
        Form {
            Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: 9...28)
            Picker("Tab width", selection: $tabWidth) {
                ForEach([2, 4, 8], id: \.self) { Text("\($0) spaces").tag($0) }
            }
            Toggle("Wrap lines", isOn: $wrapLines)
            Toggle("Show line numbers", isOn: $showLineNumbers)
        }
    }
}

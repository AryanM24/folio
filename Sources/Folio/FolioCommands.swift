import FolioKit
import SwiftUI

/// App-wide menu additions. Editor-specific menus live in each editor module.
struct FolioCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Menu("Tools") {
                ForEach(ToolCatalog.all) { tool in
                    Button(tool.title) { ToolRunner.shared.start(tool) }
                }
            }
            .disabled(ToolCatalog.all.isEmpty)
        }
        CommandGroup(before: .windowList) {
            Button("Welcome to Folio") { openWindow(id: WelcomeWindow.id) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Divider()
        }
        CommandGroup(replacing: .help) {
            Link("Folio Help", destination: URL(string: "https://github.com/AryanM24/folio#readme")!)
            Link("Report an Issue", destination: URL(string: "https://github.com/AryanM24/folio/issues/new/choose")!)
        }
    }
}

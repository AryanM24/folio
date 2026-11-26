import FolioKit
import SwiftUI

/// App-wide menu additions. Editor-specific menus live in each editor module.
struct FolioCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .importExport) {
            Menu("Tools") {
                ForEach(ToolCatalog.all) { tool in
                    Button(tool.title) { ToolRunner.shared.start(tool) }
                }
            }
            .disabled(ToolCatalog.all.isEmpty)
        }
        CommandGroup(replacing: .help) {
            Link("Folio Help", destination: URL(string: "https://github.com/AryanM24/folio#readme")!)
            Link("Report an Issue", destination: URL(string: "https://github.com/AryanM24/folio/issues/new/choose")!)
        }
    }
}

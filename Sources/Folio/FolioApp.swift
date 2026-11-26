import FolioCode
import FolioDocs
import FolioImage
import FolioKit
import FolioMedia
import FolioPDF
import FolioSheets
import SwiftUI

/// Folio's entry point.
///
/// Each editor is its own `DocumentGroup`. SwiftUI backs every group with an
/// `NSDocument`, which gives us autosave in place, Versions ("Revert To"), safe
/// atomic writes, window tabs, iCloud Drive and Recent Items without extra code.
///
/// Launch speed rule: nothing heavy runs before the first window draws. Editors
/// load their file inside `init(configuration:)` and defer expensive work (page
/// thumbnails, syntax highlighting of huge files) until after first paint.
@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @AppStorage("general.showWelcome") private var showWorkspace = true

    init() {
        // Build-time hook: scripts/bundle.sh runs `Folio --services-json` to generate the
        // Finder Quick Actions from the tool catalog, so Info.plist can't drift from code.
        if CommandLine.arguments.contains("--services-json") {
            print(ToolCatalog.servicesJSON())
            exit(0)
        }
    }

    var body: some Scene {
        // The workspace: the app's home window. The key predates the workspace (it was the
        // Welcome window's), and is kept so existing preferences carry over.
        Window("Folio", id: WorkspaceWindow.id) {
            WorkspaceWindow()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(showWorkspace ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .commands {
            FolioCommands()
            WorkspaceCommands()
        }

        // Order matters: when a file matches several groups (a CSV is also plain text),
        // SwiftUI uses the group declared last. Text & Code is the catch-all, so it goes first.
        DocumentGroup(newDocument: { CodeDocument() }) { file in
            CodeEditorView(document: file.document)
        }
        .commands { CodeCommands() }
        .defaultSize(width: 1240, height: 820)
        DocumentGroup(newDocument: { RichTextDocument() }) { file in
            RichTextEditorView(document: file.document)
        }
        .commands { DocumentCommands() }
        .defaultSize(width: 1240, height: 820)
        DocumentGroup(newDocument: { SpreadsheetDocument() }) { file in
            SpreadsheetEditorView(document: file.document)
        }
        .commands { SpreadsheetCommands() }
        .defaultSize(width: 1240, height: 820)
        DocumentGroup(newDocument: { PDFFileDocument() }) { file in
            PDFEditorView(document: file.document)
        }
        .commands { PDFCommands() }
        .defaultSize(width: 1240, height: 820)
        DocumentGroup(newDocument: { ImageDocument() }) { file in
            ImageEditorView(document: file.document)
        }
        .commands { ImageCommands() }
        .defaultSize(width: 1240, height: 820)
        // Media is view-and-export: originals are never rewritten, so no "New" item.
        DocumentGroup(viewing: MediaDocument.self) { file in
            MediaEditorView(document: file.document)
        }
        .commands { MediaCommands() }
        .defaultSize(width: 1240, height: 820)

        Settings { SettingsView() }
    }
}

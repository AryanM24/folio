import SwiftUI
import FolioKit
import FolioPDF
import FolioDocs
import FolioSheets
import FolioImage
import FolioCode
import FolioMedia

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
    @AppStorage("general.showWelcome") private var showWelcome = true

    init() {
        // Build-time hook: scripts/bundle.sh runs `Folio --services-json` to generate the
        // Finder Quick Actions from the tool catalog, so Info.plist can't drift from code.
        if CommandLine.arguments.contains("--services-json") {
            print(ToolCatalog.servicesJSON())
            exit(0)
        }
    }

    var body: some Scene {
        Window("Welcome to Folio", id: WelcomeWindow.id) {
            WelcomeWindow()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(showWelcome ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .commands { FolioCommands() }

        // Order matters: when a file matches several groups (a CSV is also plain text),
        // SwiftUI uses the group declared last. Text & Code is the catch-all, so it goes first.
        DocumentGroup(newDocument: { CodeDocument() }) { file in
            CodeEditorView(document: file.document)
        }
        DocumentGroup(newDocument: { RichTextDocument() }) { file in
            RichTextEditorView(document: file.document)
        }
        .commands { DocumentCommands() }
        DocumentGroup(newDocument: { SpreadsheetDocument() }) { file in
            SpreadsheetEditorView(document: file.document)
        }
        .commands { SpreadsheetCommands() }
        DocumentGroup(newDocument: { PDFFileDocument() }) { file in
            PDFEditorView(document: file.document)
        }
        .commands { PDFCommands() }
        DocumentGroup(newDocument: { ImageDocument() }) { file in
            ImageEditorView(document: file.document)
        }
        .commands { ImageCommands() }
        // Media is view-and-export: originals are never rewritten, so no "New" item.
        DocumentGroup(viewing: MediaDocument.self) { file in
            MediaEditorView(document: file.document)
        }
        .commands { MediaCommands() }

        Settings { SettingsView() }
    }
}

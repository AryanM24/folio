import SwiftUI
import UniformTypeIdentifiers
import FolioKit
import FolioPDF
import FolioDocs
import FolioSheets
import FolioImage
import FolioCode

/// The launch window: start something new, reopen something recent, or run a tool.
///
/// Shown at launch and from Window > Welcome to Folio (⇧⌘1). Opening any document
/// closes it, the same way Xcode's welcome window behaves.
struct WelcomeWindow: View {
    static let id = "welcome"

    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var tab: Tab = .recent
    @State private var dropTargeted = false

    enum Tab: String, CaseIterable { case recent = "Recent", tools = "Tools" }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 260)
                .background(.background.secondary)
            Divider()
            VStack(spacing: 0) {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, 14)
                .padding(.bottom, 10)
                switch tab {
                case .recent: RecentFilesView(open: open)
                case .tools: ToolsListView()
                }
            }
            .frame(width: 520)
        }
        .frame(height: 460)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            urls.forEach(open)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .padding(.top, 36)
            Text("Folio")
                .font(.title.weight(.semibold))
                .padding(.top, 10)
            Text("Version \(Bundle.main.shortVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                NewButton("Document", symbol: FileKind.document.symbol, shortcut: "N") { newDocument { RichTextDocument() } }
                NewButton("Spreadsheet", symbol: FileKind.spreadsheet.symbol) { newDocument { SpreadsheetDocument() } }
                NewButton("Text file", symbol: FileKind.code.symbol) { newDocument { CodeDocument() } }
                NewButton("Blank PDF", symbol: FileKind.pdf.symbol) { newDocument { PDFFileDocument() } }
                Divider().padding(.vertical, 6)
                NewButton("Open…", symbol: "folder", shortcut: "O") {
                    NSDocumentController.shared.openDocument(nil)
                }
            }
            .padding(.top, 28)
            Spacer()
            Text("Drop any file here to open it")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func open(_ url: URL) {
        Task {
            do {
                try await openDocument(at: url)
                dismissWindow(id: Self.id)
            } catch {
                Alert.show(error, title: "Couldn't open “\(url.lastPathComponent)”")
            }
        }
    }
}

/// A full-width row button in the Welcome sidebar.
private struct NewButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: LocalizedStringKey, symbol: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let shortcut {
                    Text("⌘\(shortcut)").font(.callout).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(.rect)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
}

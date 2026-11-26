import FolioCode
import FolioDocs
import FolioKit
import FolioPDF
import FolioSheets
import SwiftUI
import UniformTypeIdentifiers

/// The launch window: start something new, reopen something recent, or run a tool.
///
/// Shown at launch (unless turned off in Settings) and from Window › Welcome to Folio
/// (⇧⌘1). Opening a document closes it, like Xcode's welcome window. Dropping any
/// file on it opens the file in the right editor.
struct WelcomeWindow: View {
    static let id = "welcome"

    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var tab: Tab = .recent
    @State private var dropTargeted = false

    enum Tab: Hashable { case recent, tools }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 248)
                .background(Hero.surface.ignoresSafeArea())
            Rectangle().fill(Hero.separator).frame(width: 1).ignoresSafeArea()
            VStack(spacing: 0) {
                HeroTabs([(Tab.recent, "Recent", "clock"), (Tab.tools, "Tools", "wrench.and.screwdriver")], selection: $tab)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                Group {
                    switch tab {
                    case .recent: RecentFilesView(open: open)
                    case .tools: ToolsListView()
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: 560)
            .background(Hero.background.ignoresSafeArea())
        }
        .frame(height: 452)
        // Don't start with the search field focused: an empty window with a glowing
        // focus ring reads as "type here", which isn't what most people came to do.
        .task {
            try? await Task.sleep(for: .milliseconds(10))
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Hero.Radius.xl)
                    .fill(Hero.accentSoft)
                    .strokeBorder(Hero.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .overlay {
                        Label("Drop to open", systemImage: "arrow.down.doc")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Hero.accentSoftForeground)
                    }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            urls.forEach(open)
            return !urls.isEmpty
        } isTargeted: {
            dropTargeted = $0
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .padding(.top, 16)
            Text("Folio")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Hero.foreground)
                .padding(.top, 12)
            Text("Version \(Bundle.main.shortVersion)")
                .font(.system(size: 12))
                .foregroundStyle(Hero.muted)

            VStack(alignment: .leading, spacing: 2) {
                Text("New")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Hero.muted)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                SidebarRow("Document", symbol: FileKind.document.symbol, shortcut: "⌘N") { newDocument { RichTextDocument() } }
                SidebarRow("Spreadsheet", symbol: FileKind.spreadsheet.symbol) { newDocument { SpreadsheetDocument() } }
                SidebarRow("Text file", symbol: FileKind.code.symbol) { newDocument { CodeDocument() } }
                SidebarRow("Blank PDF", symbol: FileKind.pdf.symbol) { newDocument { PDFFileDocument() } }
            }
            .padding(.top, 28)

            Spacer()

            Button("Open…", systemImage: "folder") { NSDocumentController.shared.openDocument(nil) }
                .buttonStyle(.hero(.primary, fullWidth: true))
                .keyboardShortcut("o")
            Text("Or drop any file on this window")
                .font(.system(size: 11))
                .foregroundStyle(Hero.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 16)
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

/// A full-width row in the Welcome sidebar: icon, title, optional shortcut hint.
private struct SidebarRow: View {
    let title: String
    let symbol: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .frame(width: 18)
                    .foregroundStyle(Hero.muted)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Hero.foreground)
                Spacer()
                if let shortcut {
                    Text(shortcut).font(.system(size: 12)).foregroundStyle(Hero.muted)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(hovering ? Hero.defaultHover : .clear, in: .rect(cornerRadius: Hero.Radius.lg))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Hero.animation, value: hovering)
    }
}

extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
}

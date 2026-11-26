import FolioKit
import SwiftUI

/// The Folio workspace: the app's home window. A sidebar of places (Home, Recent,
/// Favorites, Tools, the library folder and added locations) and a content area that
/// shows files as cards or a table, with search, filters and Finder-style file handling.
///
/// Opens at launch unless Settings › General turns it off, and from Window › Folio
/// Workspace (⇧⌘0). It draws at once from cached state; Spotlight results, folder
/// listings and thumbnails fill in asynchronously.
struct WorkspaceWindow: View {
    static let id = "workspace"

    @State private var model = WorkspaceModel.shared
    @Environment(\.openDocument) private var openDocument
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(model: model)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            WorkspaceContent(model: model)
        }
        .frame(minWidth: 860, minHeight: 540)
        .overlay {
            if model.showsPalette {
                CommandPalette(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(Hero.animation, value: model.showsPalette)
        .focusedSceneValue(\.workspace, model)
        .onAppear {
            model.openDocumentAction = openDocument
            model.undoManager = undoManager
        }
        .onChange(of: undoManager) { model.undoManager = undoManager }
        .task {
            // Let the first frame reach the screen before Spotlight and folder listings start.
            try? await Task.sleep(for: .milliseconds(100))
            model.start()
        }
    }
}

/// The right-hand side: header, filters, then whatever the destination shows.
private struct WorkspaceContent: View {
    @Bindable var model: WorkspaceModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(model: model)
            switch model.destination {
            case .tools:
                ToolsGridView()
            case .home:
                HomeView(model: model)
            default:
                FileBrowser(model: model)
            }
        }
        .background(Hero.background)
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let toast = model.toast {
                    ToastView(toast: toast) { model.toast = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if model.selection.count >= 2 {
                    BulkActionBar(model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 20)
            .animation(Hero.animation, value: model.selection.count >= 2)
        }
        .overlay {
            if dropTargeted { DropHighlight(label: dropLabel) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            drop(urls)
        } isTargeted: {
            dropTargeted = $0 && model.destination != .tools
        }
    }

    private var dropLabel: String {
        if case .folder(let url) = model.destination {
            return NSEvent.modifierFlags.contains(.option) ? "Move to “\(model.displayName(url))”" : "Copy to “\(model.displayName(url))”"
        }
        return "Drop to open in Folio"
    }

    /// Folder views copy dropped files in (⌥ moves them); everywhere else opens them.
    private func drop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, model.destination != .tools else { return false }
        if case .folder(let folder) = model.destination {
            model.importFiles(urls, into: folder, move: NSEvent.modifierFlags.contains(.option))
        } else {
            urls.forEach(model.openFile)
        }
        return true
    }
}

/// The dashed accent frame shown while files are dragged over the content area.
struct DropHighlight: View {
    let label: String

    var body: some View {
        RoundedRectangle(cornerRadius: Hero.Radius.xxxl)
            .fill(Hero.accentSoft)
            .strokeBorder(Hero.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .overlay {
                Label(label, systemImage: "arrow.down.doc")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Hero.accentSoftForeground)
            }
            .padding(12)
            .allowsHitTesting(false)
    }
}

/// A one-line status message with an optional Undo, floating above the content.
struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(.system(size: 13))
                .foregroundStyle(Hero.foreground)
                .lineLimit(1)
            if let undo = toast.undo {
                Button("Undo", action: undo)
                    .buttonStyle(.hero(.secondary, size: .sm))
            }
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .heroOverlay(cornerRadius: Hero.Radius.track)
        .accessibilityElement(children: .contain)
    }
}

/// Designed empty states: an icon in a soft circle, a title, one line of help.
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Hero.muted)
                .frame(width: 56, height: 56)
                .background(Hero.default, in: .circle)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Hero.foreground)
                .padding(.top, 16)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Hero.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.top, 4)
            actions.padding(.top, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

import FolioKit
import SwiftUI

/// Recent, Favorites and folder views: filter chips, then cards or a table, or a
/// designed empty state when there's nothing to show.
struct FileBrowser: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        let items = model.visibleItems
        VStack(spacing: 0) {
            if !model.sourceItems.isEmpty {
                HStack {
                    KindChips(model: model, items: model.sourceItems)
                    Spacer()
                    Text(items.count == 1 ? "1 item" : "\(items.count) items")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Hero.muted)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            if items.isEmpty {
                ScrollView { emptyState.padding(.top, 40) }
            } else if model.viewMode == .list {
                FileTable(model: model, items: items)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            } else {
                ScrollView {
                    FileGrid(model: model, items: items)
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                        .padding(.bottom, 96)
                }
                .contentShape(.rect)
                .onTapGesture { model.selection = [] }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !model.sourceItems.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "No matches", message: noMatchMessage) {
                Button("Clear Search") {
                    model.query = ""
                    model.filter = .all
                }
                .buttonStyle(.hero(.tertiary, size: .sm))
            }
        } else {
            switch model.destination {
            case .favorites:
                EmptyState(
                    symbol: "star", title: "No favorites yet",
                    message:
                        "Star a file from its menu, or select it and press ⌘L. Favorites are a Finder tag, so the star shows in Finder too."
                )
            case .recent:
                if model.loadingRecent {
                    ProgressView().controlSize(.small).padding(.top, 80)
                } else {
                    EmptyState(symbol: "clock", title: "Nothing recent", message: "Files you open or change in the last month appear here.")
                    {
                        Button("Open…", systemImage: "folder") { model.showOpenPanel() }
                            .buttonStyle(.hero(.primary))
                    }
                }
            case .folder(let url) where url == model.libraryURL:
                VStack(spacing: 0) {
                    EmptyState(
                        symbol: "books.vertical", title: "Start something",
                        message: "New work you create in Folio is saved here, in your library folder. Pick a kind of file to begin."
                    )
                    .padding(.bottom, -24)
                    StartRow(model: model)
                        .frame(maxWidth: 820)
                        .padding(.horizontal, 24)
                }
            default:
                EmptyState(
                    symbol: "folder", title: "This folder is empty",
                    message: "Drag files here to copy them in. Hold ⌥ to move them instead.")
            }
        }
    }

    private var noMatchMessage: String {
        model.query.isEmpty
            ? "No \(model.filter.kind?.pluralTitle.lowercased() ?? "files") here." : "Nothing here matches “\(model.query)”."
    }
}

/// Cards in an adaptive grid, with Finder's keyboard: arrows move the selection,
/// Return opens, Space previews, ⌘A selects all.
struct FileGrid: View {
    @Bindable var model: WorkspaceModel
    let items: [FileItem]
    @State private var width: CGFloat = 900
    @FocusState private var focused: Bool

    static let minimumCardWidth: CGFloat = 160
    static let spacing: CGFloat = 16

    private var columns: Int { max(1, Int((width + Self.spacing) / (Self.minimumCardWidth + Self.spacing))) }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.minimumCardWidth, maximum: 230), spacing: Self.spacing)], spacing: 20) {
            ForEach(items) { item in
                FileCard(model: model, item: item, selected: model.selection.contains(item.url))
                    .onTapGesture {
                        focused = true
                        model.click(item, in: items)
                    }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.open([item]) })
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-columns) }
        .onKeyPress(.downArrow) { move(columns) }
        .onKeyPress(.return) {
            model.openSelection()
            return .handled
        }
        .onKeyPress(.space) {
            model.quickLook()
            return .handled
        }
        .onKeyPress(characters: ["a"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.selection = Set(items.map(\.url))
            return .handled
        }
        .onKeyPress(.escape) {
            model.selection = []
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Files")
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        guard model.renaming == nil else { return .ignored }
        model.moveSelection(by: offset, in: items)
        return .handled
    }
}

/// The list view: a native table (multi-select, keyboard, column sorting for free)
/// on a Hero card.
struct FileTable: View {
    @Bindable var model: WorkspaceModel
    let items: [FileItem]

    var body: some View {
        Table(of: FileItem.self, selection: $model.selection, sortOrder: sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 8) {
                    KindIcon(item: item, size: 14)
                    if model.renaming == item.url {
                        RenameField(model: model, item: item)
                    } else {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                    }
                    if item.isFavorite {
                        Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Hero.warning)
                            .accessibilityLabel("Favorite")
                    }
                }
            }
            .width(min: 200, ideal: 320)
            TableColumn("Kind", value: \.kindTitle) { Text($0.kindTitle).foregroundStyle(Hero.muted) }
                .width(min: 80, ideal: 110)
            TableColumn("Size", value: \.sizeValue) { item in
                Text(item.size.map(formattedSize) ?? "—").monospacedDigit().foregroundStyle(Hero.muted)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Modified", value: \.activityDate) { item in
                Text(RelativeDate.string(for: item.activityDate)).monospacedDigit().foregroundStyle(Hero.muted)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Location", value: \.location) { Text($0.location).lineLimit(1).truncationMode(.head).foregroundStyle(Hero.muted) }
                .width(min: 120, ideal: 220)
        } rows: {
            ForEach(items) { item in
                TableRow(item).itemProvider { NSItemProvider(contentsOf: item.url) }
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            FileMenu(model: model, items: items.filter { urls.contains($0.url) })
        } primaryAction: { urls in
            model.open(items.filter { urls.contains($0.url) })
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .font(.system(size: 13))
        .padding(.vertical, 8)
        .background(Hero.surface)
        .clipShape(.rect(cornerRadius: Hero.Radius.xxxl))
        .heroSurfaceShadow()
        .onKeyPress(.space) {
            model.quickLook()
            return .handled
        }
    }

    /// The table's column sort mirrors the toolbar's sort menu, so both stay in step.
    private var sortOrder: Binding<[KeyPathComparator<FileItem>]> {
        Binding {
            let order: SortOrder = model.ascending ? .forward : .reverse
            return switch model.sort {
            case .name: [KeyPathComparator(\FileItem.name, order: order)]
            case .size: [KeyPathComparator(\FileItem.sizeValue, order: order)]
            case .kind: [KeyPathComparator(\FileItem.kindTitle, order: order)]
            case .lastOpened: [KeyPathComparator(\FileItem.activityDate, order: order)]
            }
        } set: { new in
            guard let first = new.first else { return }
            switch first.keyPath {
            case \FileItem.name: model.sort = .name
            case \FileItem.sizeValue: model.sort = .size
            case \FileItem.kindTitle, \FileItem.location: model.sort = .kind
            default: model.sort = .lastOpened
            }
            model.ascending = first.order == .forward
        }
    }
}

/// The file kind's symbol with a faint kind color, so a page of cards scans quickly.
struct KindIcon: View {
    let item: FileItem
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: item.isFolder ? "folder" : item.kind?.symbol ?? "doc")
            .font(.system(size: size))
            .foregroundStyle(item.isFolder ? Hero.muted : item.kind?.tint ?? Hero.muted)
            .frame(width: size + 6)
            .accessibilityHidden(true)
    }
}

extension FileKind {
    /// A quiet per-kind tint for icons in lists and cards (muted, never loud).
    var tint: Color {
        switch self {
        case .pdf: Color(hex: 0xE5484D).opacity(0.85)
        case .document: Color(hex: 0x0485F7).opacity(0.85)
        case .spreadsheet: Color(hex: 0x17A34A).opacity(0.85)
        case .image: Color(hex: 0x8E4EC6).opacity(0.85)
        case .code: Hero.muted
        case .media: Color(hex: 0xF76B15).opacity(0.85)
        }
    }
}

/// Inline rename: edits the name without its extension; Return commits, Esc cancels.
struct RenameField: View {
    let model: WorkspaceModel
    let item: FileItem
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 4)
            .background(Hero.field, in: .rect(cornerRadius: Hero.Radius.sm))
            .overlay { RoundedRectangle(cornerRadius: Hero.Radius.sm).strokeBorder(Hero.accent, lineWidth: 1.5) }
            .focused($focused)
            .onSubmit { model.rename(item, to: text) }
            .onExitCommand { model.renaming = nil }
            .onAppear {
                text = item.baseName
                focused = true
            }
            .onChange(of: focused) { if !focused, model.renaming == item.url { model.rename(item, to: text) } }
            .accessibilityLabel("New name for \(item.name)")
    }
}

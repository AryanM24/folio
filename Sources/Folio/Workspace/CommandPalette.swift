import FolioConvert
import FolioKit
import SwiftUI

/// ⌘K: one search box over files and commands. Arrow keys move, Return runs, Esc closes.
///
/// Files come from the lists the workspace already has (Recent, Favorites, the current
/// folder), so the palette opens instantly and never touches the disk.
struct CommandPalette: View {
    @Bindable var model: WorkspaceModel
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool
    @Environment(\.openSettings) private var openSettings

    struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let section: String
        var shortcut: String?
        let run: () -> Void
    }

    var body: some View {
        let results = self.results
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(Hero.muted)
                    TextField("Search files and actions", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onKeyPress(.downArrow) { step(1, count: results.count) }
                        .onKeyPress(.upArrow) { step(-1, count: results.count) }
                        .onKeyPress(.return) {
                            run(results)
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            close()
                            return .handled
                        }
                        .onChange(of: query) { index = 0 }
                        .accessibilityLabel("Command palette search")
                    HeroKbd("esc")
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                Rectangle().fill(Hero.separator).frame(height: 1)
                if results.isEmpty {
                    Text("No files or actions match “\(query)”.")
                        .font(.system(size: 13))
                        .foregroundStyle(Hero.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { offset, entry in
                                    if offset == 0 || results[offset - 1].section != entry.section {
                                        Text(entry.section)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(Hero.muted)
                                            .padding(.horizontal, 10)
                                            .padding(.top, offset == 0 ? 4 : 10)
                                            .padding(.bottom, 4)
                                    }
                                    row(entry, selected: offset == index)
                                        .id(entry.id)
                                        .onTapGesture {
                                            index = offset
                                            run(results)
                                        }
                                }
                            }
                            .padding(8)
                        }
                        .frame(maxHeight: 380)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: index) { proxy.scrollTo(results[min(index, results.count - 1)].id) }
                    }
                }
                Rectangle().fill(Hero.separator).frame(height: 1)
                HStack(spacing: 14) {
                    hint("↑↓", "to move")
                    hint("↩", "to open")
                    Spacer()
                    hint("⌘K", "to toggle")
                }
                .padding(.horizontal, 16)
                .frame(height: 36)
            }
            .frame(width: 600)
            .heroOverlay(cornerRadius: Hero.Radius.xxxl)
            .padding(.top, 88)
        }
        .onAppear { focused = true }
        .onExitCommand(perform: close)
        .accessibilityAddTraits(.isModal)
    }

    private func row(_ entry: Entry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbol)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Hero.foreground : Hero.muted)
                .frame(width: 20)
            Text(entry.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Hero.foreground)
                .lineLimit(1)
            Text(entry.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Hero.muted)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            if let shortcut = entry.shortcut {
                Text(shortcut).font(.system(size: 12)).foregroundStyle(Hero.muted)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(selected ? Hero.default : .clear, in: .rect(cornerRadius: Hero.Radius.lg))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func hint(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(keys).font(.system(size: 11, weight: .medium)).foregroundStyle(Hero.foreground.opacity(0.7))
            Text(text).font(.system(size: 11)).foregroundStyle(Hero.muted)
        }
    }

    private func step(_ delta: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .handled }
        index = (index + delta + count) % count
        return .handled
    }

    private func run(_ results: [Entry]) {
        guard results.indices.contains(index) else { return }
        let entry = results[index]
        close()
        entry.run()
    }

    private func close() { model.showsPalette = false }

    // MARK: Results

    private var results: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let files = fileEntries
        let actions = actionEntries
        guard !q.isEmpty else { return Array(files.prefix(5)) + actions.filter { $0.section == "Actions" } }
        func ranked(_ entries: [Entry], limit: Int) -> [Entry] {
            entries.compactMap { e in FuzzyMatch.score(q, in: e.title).map { (e, $0) } }
                .sorted { $0.1 > $1.1 }
                .prefix(limit)
                .map(\.0)
        }
        return ranked(files, limit: 8) + ranked(actions, limit: 10)
    }

    private var fileEntries: [Entry] {
        var seen = Set<URL>()
        let items = (model.recent + model.favorites + model.folderItems).filter { seen.insert($0.url).inserted }
        return items.map { item in
            Entry(
                id: "file:" + item.url.path(percentEncoded: false), title: item.name,
                subtitle: model.displayName(item.url.deletingLastPathComponent()),
                symbol: item.isFolder ? "folder" : item.kind?.symbol ?? "doc", section: "Files"
            ) { model.open([item]) }
        }
    }

    private var actionEntries: [Entry] {
        var out: [Entry] = NewFile.allCases.map { kind in
            Entry(
                id: "new:" + kind.rawValue, title: "New \(kind.title)", subtitle: kind.subtitle, symbol: kind.kind.symbol,
                section: "Actions"
            ) { model.create(kind) }
        }
        out += [
            Entry(id: "open", title: "Open…", subtitle: "Any file", symbol: "folder", section: "Actions", shortcut: "⌘O") {
                model.showOpenPanel()
            },
            Entry(id: "go:home", title: "Go to Home", subtitle: "", symbol: "house", section: "Actions", shortcut: "⇧⌘H") {
                model.go(.home)
            },
            Entry(id: "go:recent", title: "Go to Recent", subtitle: "", symbol: "clock", section: "Actions", shortcut: "⇧⌘F") {
                model.go(.recent)
            },
            Entry(id: "go:favorites", title: "Go to Favorites", subtitle: "", symbol: "star", section: "Actions", shortcut: "⇧⌘I") {
                model.go(.favorites)
            },
            Entry(id: "go:library", title: "Go to Library", subtitle: "", symbol: "books.vertical", section: "Actions", shortcut: "⇧⌘L") {
                model.goToLibrary()
            },
            Entry(id: "go:tools", title: "Go to Tools", subtitle: "", symbol: "wrench.and.screwdriver", section: "Actions", shortcut: "⇧⌘T")
            {
                model.go(.tools)
            },
            Entry(
                id: "location", title: "Add Location…", subtitle: "Show a folder in the sidebar", symbol: "folder.badge.plus",
                section: "Actions"
            ) {
                model.addLocationWithPanel()
            },
            Entry(
                id: "view", title: model.viewMode == .grid ? "Show as List" : "Show as Grid", subtitle: "",
                symbol: model.viewMode == .grid ? "list.bullet" : "square.grid.2x2", section: "Actions"
            ) { model.viewMode = model.viewMode == .grid ? .list : .grid },
            Entry(id: "settings", title: "Settings…", subtitle: "", symbol: "gearshape", section: "Actions", shortcut: "⌘,") {
                openSettings()
            },
        ]
        out += convertEntries
        out += ToolCatalog.all.map { tool in
            Entry(id: "tool:" + tool.id, title: tool.title, subtitle: tool.subtitle, symbol: tool.symbol, section: "Tools") {
                ToolRunner.shared.start(tool)
            }
        }
        return out
    }
}

extension CommandPalette {
    /// Convert the selection (or files you pick), the clipboard, and the shelf's way back.
    fileprivate var convertEntries: [Entry] {
        let files = model.selectedItems.filter { !$0.isFolder }.map(\.url)
        var out: [Entry] = []
        if !files.isEmpty {
            out.append(
                Entry(
                    id: "convert:selection", title: "Convert selection to…",
                    subtitle: files.count == 1 ? files[0].lastPathComponent : "\(files.count) files", symbol: "arrow.triangle.2.circlepath",
                    section: "Actions", shortcut: "⇧⌘C"
                ) { ConvertFlow.present(files) })
        }
        out += [Format.pdf, .png, .mp4].map { format in
            Entry(
                id: "convert:\(format.rawValue)", title: "Convert to \(format.chipLabel)…",
                subtitle: files.isEmpty ? "Choose files" : "Selection", symbol: "arrow.triangle.2.circlepath", section: "Convert"
            ) { ConvertFlow.present(files, preferring: format) }
        }
        let destination = model.displayName(ConvertFlow.clipboardDestination)
        out += [Format.png, .jpeg, .heic].map { format in
            Entry(
                id: "clipboard:\(format.rawValue)", title: "Convert clipboard image to \(format.chipLabel)",
                subtitle: "Saves to \(destination)", symbol: "doc.on.clipboard", section: "Convert"
            ) { ConvertFlow.convertClipboard(to: format) }
        }
        if !ShelfController.isEnabled {
            out.append(
                Entry(
                    id: "shelf:show", title: "Show Drop Shelf in menu bar", subtitle: "Drop files on the menu bar to convert",
                    symbol: "menubar.arrow.up.rectangle", section: "Convert"
                ) { ShelfController.isEnabled = true })
        }
        return out
    }
}

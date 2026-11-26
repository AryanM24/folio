import FolioKit
import SwiftUI

/// The workspace sidebar: places, the library, added locations, and free disk space.
///
/// Rows are 32 pt with muted icons; the active row gets the Hero `default` fill and
/// medium weight, like the web version of Folio. Up and down arrows move between rows
/// when the sidebar has focus. Dropping folders from Finder anywhere on it adds them
/// as locations.
struct WorkspaceSidebar: View {
    @Bindable var model: WorkspaceModel
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row("Home", symbol: "house", destination: .home)
                    row("Recent", symbol: "clock", destination: .recent, count: model.recent.count)
                    row("Favorites", symbol: "star", destination: .favorites, count: model.favorites.count)
                    row("Tools", symbol: "wrench.and.screwdriver", destination: .tools)

                    SectionHeader("Library")
                    row(
                        model.libraryURL.lastPathComponent, symbol: "books.vertical", destination: .folder(model.libraryURL),
                        count: model.libraryItems.count
                    ) { model.goToLibrary() }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.libraryURL]) }
                    }

                    SectionHeader("Locations") {
                        Button("Add Location…", systemImage: "plus") { model.addLocationWithPanel() }
                            .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                            .scaleEffect(0.8)
                            .help("Add a folder to the sidebar")
                    }
                    ForEach(model.locations, id: \.self) { url in
                        row(model.displayName(url), symbol: "folder", destination: .folder(url))
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Divider()
                                Button("Remove from Sidebar") { model.removeLocation(url) }
                            }
                    }
                    if model.locations.isEmpty {
                        Text("Drop a folder here, or press + to add one.")
                            .font(.system(size: 12))
                            .foregroundStyle(Hero.muted)
                            .padding(.horizontal, 10)
                            .padding(.top, 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            DiskFooter(space: model.freeSpace)
        }
        .background(Hero.surface)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Hero.Radius.xxl)
                    .strokeBorder(Hero.accent, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addLocations(urls)
            return true
        } isTargeted: {
            dropTargeted = $0
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    /// Every row's destination in order, for arrow-key navigation.
    private var order: [Destination] {
        [.home, .recent, .favorites, .tools, .folder(model.libraryURL)] + model.locations.map { .folder($0) }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        let current = order.firstIndex { isActive($0) } ?? 0
        let next = order[min(max(0, current + delta), order.count - 1)]
        if case .folder(let url) = next, url == model.libraryURL { model.goToLibrary() } else { model.go(next) }
        return .handled
    }

    private func isActive(_ destination: Destination) -> Bool {
        if case .folder(let root) = destination { return model.currentRoot == root }
        return model.destination == destination
    }

    private func row(
        _ title: String, symbol: String, destination: Destination, count: Int? = nil, action: (() -> Void)? = nil
    ) -> some View {
        SidebarRow(title: title, symbol: symbol, count: count, active: isActive(destination)) {
            if let action { action() } else { model.go(destination) }
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let count: Int?
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(active ? Hero.foreground : Hero.muted)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: active ? .medium : .regular))
                    .foregroundStyle(Hero.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Hero.muted)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                active ? Hero.default : (hovering ? Hero.default.opacity(0.55) : .clear), in: .rect(cornerRadius: Hero.Radius.lg)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Hero.animation, value: hovering)
        .accessibilityLabel(count.map { "\(title), \($0) items" } ?? title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Hero.muted)
            Spacer()
            trailing
        }
        .frame(height: 24)
        .padding(.leading, 10)
        .padding(.top, 16)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title) { EmptyView() } }
}

/// Free space on the library's disk, as a quiet bar at the foot of the sidebar.
private struct DiskFooter: View {
    let space: (available: Int64, total: Int64)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let space, space.total > 0 {
                GeometryReader { geo in
                    Capsule().fill(Hero.default)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Hero.muted.opacity(0.55))
                                .frame(width: geo.size.width * CGFloat(space.total - space.available) / CGFloat(space.total))
                        }
                }
                .frame(height: 4)
                Text("\(formattedSize(space.available)) available")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Hero.muted)
            }
        }
        .frame(height: 30, alignment: .bottom)
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .accessibilityElement(children: .combine)
    }
}

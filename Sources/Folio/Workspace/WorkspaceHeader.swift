import FolioKit
import SwiftUI

/// The top of the content area: back and forward, the title or folder path, search,
/// sort and the grid/list switch. It sits in the hidden title bar's band, so dragging
/// its empty space moves the window.
struct WorkspaceHeader: View {
    @Bindable var model: WorkspaceModel

    private var showsFileControls: Bool { model.destination != .tools }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Button("Back", systemImage: "chevron.left") { model.back() }
                    .disabled(!model.canGoBack)
                    .help("Back ⌘[")
                Button("Forward", systemImage: "chevron.right") { model.forward() }
                    .disabled(!model.canGoForward)
                    .help("Forward ⌘]")
            }
            .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))

            titleView
                .padding(.leading, 4)
            Spacer(minLength: 12)

            if showsFileControls {
                SearchField(model: model)
                    .frame(width: 240)
                SortMenu(model: model)
                if model.destination != .home {
                    ViewModeSwitch(selection: $model.viewMode)
                }
            }
            Button("Command Palette", systemImage: "command") { model.showsPalette = true }
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .help("Command palette ⌘K")
        }
        .padding(.leading, 16)
        .padding(.trailing, 20)
        .frame(height: 52)
        .padding(.top, 4)
    }

    @ViewBuilder private var titleView: some View {
        let crumbs = model.breadcrumbs
        if crumbs.count > 1 {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.element) { index, url in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Hero.muted)
                    }
                    if index == crumbs.count - 1 {
                        Text(model.displayName(url))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Hero.foreground)
                            .lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                    } else {
                        Button(model.displayName(url)) { model.go(.folder(url)) }
                            .buttonStyle(.plain)
                            .font(.system(size: 15))
                            .foregroundStyle(Hero.muted)
                            .lineLimit(1)
                    }
                }
            }
        } else {
            Text(model.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Hero.foreground)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// A Hero input with a search glyph, a clear button and a ⌘F hint. Filters the
/// current view as you type.
private struct SearchField: View {
    @Bindable var model: WorkspaceModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Hero.muted)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onExitCommand {
                    model.query = ""
                    focused = false
                }
                .accessibilityLabel("Search \(model.title)")
            if !model.query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { model.query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Hero.muted)
            } else if !focused {
                Text("⌘F")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Hero.muted)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Hero.field, in: .rect(cornerRadius: Hero.Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: Hero.Radius.xl)
                .strokeBorder(focused ? Hero.accent : Hero.border.opacity(0.6), lineWidth: focused ? 2 : 0.5)
        }
        .heroSurfaceShadow()
        .animation(Hero.animation, value: focused)
        .onChange(of: focused) { model.isSearchFocused = focused }
        .onChange(of: model.searchFocusRequest) { focused = true }
    }
}

/// Sort by last opened, name, size or kind, and the direction.
private struct SortMenu: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        Menu {
            Picker("Sort By", selection: $model.sort) {
                ForEach(FileSort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .onChange(of: model.sort) { model.ascending = model.sort.defaultAscending }
            Divider()
            Picker("Order", selection: $model.ascending) {
                Text(model.sort == .lastOpened ? "Oldest First" : "Ascending").tag(true)
                Text(model.sort == .lastOpened ? "Newest First" : "Descending").tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
        .fixedSize()
        .help("Sort by \(model.sort.title.lowercased())")
    }
}

/// Grid or list, as two icon segments on a Hero track.
private struct ViewModeSwitch: View {
    @Binding var selection: ViewMode
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            segment(.grid, title: "Grid", symbol: "square.grid.2x2")
            segment(.list, title: "List", symbol: "list.bullet")
        }
        .padding(2)
        .background(Hero.default, in: .capsule)
    }

    private func segment(_ mode: ViewMode, title: String, symbol: String) -> some View {
        let selected = selection == mode
        return Button {
            withAnimation(Hero.animation) { selection = mode }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Hero.foreground : Hero.muted)
                .frame(width: 32, height: 28)
                .background {
                    if selected {
                        Capsule().fill(Hero.segment).heroSurfaceShadow().matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(title) view")
    }
}

/// Kind filter pills with quiet counts, only for kinds present in the current view.
struct KindChips: View {
    @Bindable var model: WorkspaceModel
    let items: [FileItem]
    @Namespace private var pill

    var body: some View {
        let chips = KindFilter.chips(for: items)
        HStack(spacing: 0) {
            ForEach(chips, id: \.filter) { chip in
                let selected = model.filter == chip.filter
                Button {
                    withAnimation(.snappy(duration: 0.25)) { model.filter = chip.filter }
                } label: {
                    HStack(spacing: 6) {
                        Text(chip.filter.kind?.pluralTitle ?? "All")
                            .foregroundStyle(selected ? Hero.foreground : Hero.muted)
                        Text("\(chip.count)")
                            .monospacedDigit()
                            .foregroundStyle(Hero.muted.opacity(selected ? 1 : 0.8))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background {
                        if selected {
                            Capsule().fill(Hero.segment).heroSurfaceShadow().matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(chip.filter.kind?.pluralTitle ?? "All"), \(chip.count)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Hero.default, in: .capsule)
        .fixedSize()
    }
}

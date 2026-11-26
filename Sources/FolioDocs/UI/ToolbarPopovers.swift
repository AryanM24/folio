import AppKit
import FolioKit
import SwiftUI

// Popovers opened from the formatting toolbar: colors, links and the table picker.

/// Text color and highlight buttons, each with a swatch popover and "More…" for the
/// system color panel.
struct ColorButtons: View {
    let controller: DocumentEditorController
    @State private var showsText = false
    @State private var showsHighlight = false

    /// Pastel marker colors that keep black text readable.
    private static let highlights: [Color] = [
        Color(hex: 0xFFF3A3), Color(hex: 0xC8F7C5), Color(hex: 0xBFE3FF), Color(hex: 0xFFD1E3), Color(hex: 0xFFD8B0), Color(hex: 0xE3D5FF),
    ]

    var body: some View {
        ToolbarIconButton(title: "Text Color", symbol: "character", selected: showsText) { showsText = true }
            .popover(isPresented: $showsText, arrowEdge: .bottom) {
                ColorPopover(title: "Text color", colors: ColorSwatches.ink, noneTitle: "Automatic") { color in
                    controller.setTextColor(color.map(NSColor.init))
                } more: {
                    showsText = false
                    controller.showColors()
                }
            }
        ToolbarIconButton(title: "Highlight", symbol: "highlighter", selected: showsHighlight) { showsHighlight = true }
            .popover(isPresented: $showsHighlight, arrowEdge: .bottom) {
                ColorPopover(title: "Highlight", colors: Self.highlights, noneTitle: "None") { color in
                    controller.setHighlight(color.map(NSColor.init))
                } more: {
                    showsHighlight = false
                    controller.showColors(highlight: true)
                }
            }
    }
}

private struct ColorPopover: View {
    let title: String
    let colors: [Color]
    let noneTitle: String
    let choose: (Color?) -> Void
    let more: () -> Void
    @State private var picked: Color = .clear

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSection(LocalizedStringKey(title)) {
                ColorSwatches(
                    colors,
                    selection: Binding(
                        get: { picked },
                        set: {
                            picked = $0; choose($0)
                        }))
            }
            HStack(spacing: 8) {
                Button(noneTitle) { choose(nil) }.buttonStyle(.hero(.tertiary, size: .sm))
                Button("More…", action: more).buttonStyle(.hero(.ghost, size: .sm))
            }
        }
        .padding(16)
    }
}

/// Link, image and table buttons, plus a menu for rules and page breaks.
struct InsertButtons: View {
    let controller: DocumentEditorController
    @State private var showsTable = false

    var body: some View {
        ToolbarIconButton(title: "Link", symbol: "link", selected: controller.selection.link != nil, shortcut: "⌘K") {
            controller.showsLinkEditor = true
        }
        .popover(isPresented: Bindable(controller).showsLinkEditor, arrowEdge: .bottom) {
            LinkPopover(current: controller.selection.link) { url in
                controller.showsLinkEditor = false
                if let url { controller.insertLink(url) } else { controller.removeLink() }
            }
        }
        ToolbarIconButton(title: "Insert Image", symbol: "photo") { controller.chooseImages() }
        ToolbarIconButton(title: "Insert Table", symbol: "tablecells", selected: showsTable) { showsTable = true }
            .popover(isPresented: $showsTable, arrowEdge: .bottom) {
                TableSizePicker { rows, columns in
                    showsTable = false
                    controller.insertTable(rows: rows, columns: columns)
                }
            }
        Menu {
            Button("Horizontal Rule") { controller.insertHorizontalRule() }
            Button("Page Break") { controller.insertPageBreak() }
        } label: {
            Label("Insert", systemImage: "plus")
        }
        .heroToolbarMenu(iconOnly: true)
        .help("Insert rule or page break")
    }
}

/// URL field with a primary "Add Link" action, and "Remove" for an existing link.
private struct LinkPopover: View {
    let current: URL?
    let done: (URL?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSection("Link") {
                TextField("https://example.com", text: $text)
                    .textFieldStyle(.hero)
                    .focused($focused)
                    .frame(width: 260)
                    .onSubmit(add)
            }
            HStack(spacing: 8) {
                if current != nil {
                    Button("Remove") { done(nil) }.buttonStyle(.hero(.dangerSoft, size: .sm))
                }
                Spacer()
                Button(current == nil ? "Add Link" : "Update", action: add)
                    .buttonStyle(.hero(.primary, size: .sm))
                    .disabled(url == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear {
            text = current?.absoluteString ?? ""
            focused = true
        }
    }

    /// Accepts bare domains ("folio.app") and email addresses as well as full URLs.
    private var url: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if trimmed.contains("@"), !trimmed.contains("://"), !trimmed.hasPrefix("mailto:") { return URL(string: "mailto:" + trimmed) }
        if trimmed.contains("://") || trimmed.hasPrefix("mailto:") { return URL(string: trimmed) }
        return URL(string: "https://" + trimmed)
    }

    private func add() { if let url { done(url) } }
}

/// Word-style grid: hover to size the table, click to insert. Every cell is a button,
/// so it works with the keyboard and VoiceOver too.
private struct TableSizePicker: View {
    let insert: (Int, Int) -> Void
    @State private var hover = (rows: 3, columns: 3)
    private let maxRows = 8, maxColumns = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(hover.rows) × \(hover.columns) table")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Hero.muted)
                .monospacedDigit()
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(1...maxRows, id: \.self) { row in
                    GridRow {
                        ForEach(1...maxColumns, id: \.self) { column in
                            let on = row <= hover.rows && column <= hover.columns
                            Button {
                                insert(row, column)
                            } label: {
                                RoundedRectangle(cornerRadius: Hero.Radius.sm)
                                    .fill(on ? Hero.accentSoft : Hero.default)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: Hero.Radius.sm).strokeBorder(
                                            on ? Hero.accent : Hero.border, lineWidth: on ? 1 : 0.5)
                                    }
                                    .frame(width: 18, height: 18)
                            }
                            .buttonStyle(.plain)
                            .onHover { if $0 { hover = (row, column) } }
                            .accessibilityLabel("\(row) by \(column) table")
                        }
                    }
                }
            }
        }
        .padding(16)
    }
}

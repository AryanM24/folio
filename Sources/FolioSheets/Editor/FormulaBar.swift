import FolioKit
import SwiftUI

/// Name box (where you are / jump anywhere) and the formula field (what's in the cell).
struct FormulaBar: View {
    @Bindable var controller: SheetController
    @State private var name = "A1"
    @FocusState private var nameFocused: Bool
    @FocusState private var formulaFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Cell", text: $name)
                .textFieldStyle(.hero)
                .monospacedDigit()
                .frame(width: 104)
                .focused($nameFocused)
                .onSubmit {
                    if !controller.go(to: name) { NSSound.beep() }
                    name = selectionName
                }
                .accessibilityLabel("Name box")
                .help("Type a cell like B12 or a range like A1:C10, then press Return")
            Image(systemName: "function")
                .font(.system(size: 14))
                .foregroundStyle(Hero.muted)
                .accessibilityHidden(true)
            TextField("Value or formula", text: $controller.formulaText)
                .textFieldStyle(.hero)
                .focused($formulaFocused)
                .onSubmit { controller.commitFormulaBar() }
                .onExitCommand {
                    controller.formulaText = controller.sheet[controller.selection.active]
                    controller.grid?.focus()
                }
                .accessibilityLabel("Formula")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Hero.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Hero.separator).frame(height: 1) }
        .onChange(of: controller.selection) { if !nameFocused { name = selectionName } }
        .onAppear { name = selectionName }
    }

    private var selectionName: String {
        let s = controller.selection
        switch s.kind {
        case .cells: return CellRange(s.anchor, s.cursor).a1
        case .rows: return "\(min(s.anchor.row, s.cursor.row) + 1):\(max(s.anchor.row, s.cursor.row) + 1)"
        case .columns:
            return "\(CellRef.columnName(min(s.anchor.col, s.cursor.col))):\(CellRef.columnName(max(s.anchor.col, s.cursor.col)))"
        }
    }
}

/// Find & replace, floating over the top-right of the grid.
struct FindBar: View {
    @Bindable var controller: SheetController
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Find", text: $controller.findText)
                    .textFieldStyle(.hero)
                    .focused($findFocused)
                    .onSubmit { controller.findNext() }
                Text(matchLabel)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Hero.muted)
                    .frame(minWidth: 54, alignment: .trailing)
                Button {
                    controller.findNext(backwards: true)
                } label: {
                    Label("Previous Match", systemImage: "chevron.up")
                }
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .help("Previous Match ⇧⌘G")
                Button {
                    controller.findNext()
                } label: {
                    Label("Next Match", systemImage: "chevron.down")
                }
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .help("Next Match ⌘G")
                Button {
                    close()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            HStack(spacing: 6) {
                TextField("Replace with", text: $controller.replaceText)
                    .textFieldStyle(.hero)
                    .onSubmit { controller.replaceCurrent() }
                Button("Replace") { controller.replaceCurrent() }
                    .buttonStyle(.hero(.tertiary, size: .sm))
                Button("All") { controller.replaceAll() }
                    .buttonStyle(.hero(.secondary, size: .sm))
                    .help("Replace All")
            }
            Toggle("Match case", isOn: $controller.matchCase)
                .toggleStyle(.hero)
                .font(.system(size: 12))
        }
        .padding(12)
        .frame(width: 400)
        .heroOverlay()
        .onAppear { findFocused = true }
    }

    private var matchLabel: String {
        guard !controller.findText.isEmpty else { return "" }
        let n = controller.findMatches.count
        return n == 1 ? "1 match" : "\(n) matches"
    }

    private func close() {
        controller.showFind = false
        controller.grid?.focus()
    }
}

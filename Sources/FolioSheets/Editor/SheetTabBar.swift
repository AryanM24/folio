import FolioKit
import SwiftUI

/// Bottom bar: sheet tabs (select, add, rename, reorder, delete) and selection statistics.
struct SheetTabBar: View {
    let controller: SheetController

    var body: some View {
        let _ = controller.revision
        let sheets = controller.document.workbook.sheets
        let active = controller.document.activeSheetIndex
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    HStack(spacing: 0) {
                        ForEach(Array(sheets.enumerated()), id: \.element.id) { index, sheet in
                            SheetTab(controller: controller, index: index, name: sheet.name, isActive: index == active, count: sheets.count)
                        }
                    }
                    .padding(3)
                    .background(Hero.default, in: .capsule)
                    Button {
                        controller.addSheet()
                    } label: {
                        Label("Add Sheet", systemImage: "plus")
                    }
                    .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                    .help("Add Sheet")
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            SelectionStats(controller: controller)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Hero.surface)
        .overlay(alignment: .top) { Rectangle().fill(Hero.separator).frame(height: 1) }
    }
}

private struct SheetTab: View {
    let controller: SheetController
    let index: Int
    let name: String
    let isActive: Bool
    let count: Int
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if controller.renamingSheet == index {
                TextField("Sheet name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .focused($focused)
                    .frame(width: max(60, CGFloat(draft.count) * 7 + 16))
                    .onSubmit { controller.renameSheet(index, to: draft) }
                    .onExitCommand { controller.renamingSheet = nil }
                    .onAppear {
                        draft = name; focused = true
                    }
                    .onChange(of: focused) { _, now in if !now { controller.renameSheet(index, to: draft) } }
            } else {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? Hero.foreground : Hero.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background {
            if isActive { Capsule().fill(Hero.segment).shadow(color: .black.opacity(0.06), radius: 1, y: 1) }
        }
        .contentShape(.capsule)
        .onTapGesture(count: 2) { controller.renamingSheet = index }
        .onTapGesture { controller.selectSheet(index) }
        .contextMenu {
            Button("Rename…") { controller.renamingSheet = index }
            Button("Move Left") { controller.moveSheet(index, by: -1) }.disabled(index == 0)
            Button("Move Right") { controller.moveSheet(index, by: 1) }.disabled(index == count - 1)
            Divider()
            Button("Delete Sheet", role: .destructive) { controller.deleteSheet(index) }.disabled(count < 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("Sheet \(name)")
        .accessibilityAction(named: "Rename") { controller.renamingSheet = index }
    }
}

/// "Sum · Average · Count" of the selection, like Numbers' status bar.
private struct SelectionStats: View {
    let controller: SheetController

    var body: some View {
        HStack(spacing: 16) {
            if let s = controller.stats {
                if s.numbers > 0 {
                    stat("Sum", Self.format(s.sum))
                    if let avg = s.average { stat("Average", Self.format(avg)) }
                }
                stat("Count", String(s.count))
            } else {
                Text(cellSummary)
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(Hero.muted)
        .lineLimit(1)
    }

    /// Grouped, at most two decimals: "60,886", "2,899.33".
    private static func format(_ n: Double) -> String {
        abs(n) >= 1e15 ? ValueFormatter.general(n) : n.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
            Text(value).foregroundStyle(Hero.foreground)
        }
        .accessibilityElement(children: .combine)
    }

    /// For a single cell: what an error means, or the row count of the sheet.
    private var cellSummary: String {
        _ = controller.revision
        if let e = controller.document.value(at: controller.selection.active).errorValue { return e.explanation }
        let rows = controller.sheet.maxRow + 1
        return rows > 0 ? "\(rows.formatted()) rows" : ""
    }
}

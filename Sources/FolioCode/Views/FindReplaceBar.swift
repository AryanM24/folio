import SwiftUI
import FolioKit

/// Find & Replace with regular expressions (⌥⌘F). The native find bar (⌘F) stays available
/// for plain searches; this one adds regex, `$1` templates and replace-all as one undo step.
struct FindReplaceBar: View {
    @Bindable var controller: EditorController
    @FocusState private var field: Field?

    private enum Field { case find, replace }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find", text: $controller.find.query)
                .textFieldStyle(.hero)
                .focused($field, equals: .find)
                .onSubmit { controller.findNext() }
                .frame(minWidth: 140, maxWidth: 240)
                .accessibilityLabel("Find")
            TextField("Replace", text: $controller.find.replacement)
                .textFieldStyle(.hero)
                .focused($field, equals: .replace)
                .onSubmit { controller.replaceCurrent() }
                .frame(minWidth: 120, maxWidth: 220)
                .accessibilityLabel("Replace with")

            Button { controller.find.isRegex.toggle() } label: {
                Label("Regular expression", systemImage: "asterisk")
            }
            .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true, isSelected: controller.find.isRegex))
            .help("Regular expression")
            .accessibilityValue(controller.find.isRegex ? "On" : "Off")

            Button { controller.find.matchCase.toggle() } label: {
                Label("Match case", systemImage: "textformat")
            }
            .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true, isSelected: controller.find.matchCase))
            .help("Match case")
            .accessibilityValue(controller.find.matchCase ? "On" : "Off")

            HeroToolbarDivider()

            Button { controller.findNext(backwards: true) } label: { Label("Previous match", systemImage: "chevron.up") }
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .help("Previous match")
            Button { controller.findNext() } label: { Label("Next match", systemImage: "chevron.down") }
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .help("Next match ↩")
            Button("Replace") { controller.replaceCurrent() }
                .buttonStyle(.hero(.tertiary, size: .sm))
            Button("Replace All") { controller.replaceAll() }
                .buttonStyle(.hero(.tertiary, size: .sm))

            Text(controller.find.status)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(controller.find.isError ? Hero.danger : Hero.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { controller.hideFindReplace() } label: { Label("Close", systemImage: "xmark") }
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Hero.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Hero.separator).frame(height: 1) }
        .onAppear { field = .find }
        .onChange(of: controller.find.query) { controller.find.status = "" }
    }
}

/// ⌘L: jump to a line, or `line:column`.
struct GoToLineSheet: View {
    let lineCount: Int
    let go: (Int, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    private var target: (line: Int, column: Int)? {
        let parts = input.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let first = parts.first, let line = first, (1...lineCount).contains(line) else { return nil }
        let column = parts.count > 1 ? (parts[1] ?? 1) : 1
        return (line, max(1, column))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Go to line").font(.system(size: 13, weight: .semibold)).foregroundStyle(Hero.foreground)
                Text("1 – \(lineCount.formatted()). Add “:column” to land mid-line.")
                    .font(.system(size: 12))
                    .foregroundStyle(Hero.muted)
            }
            TextField("Line number", text: $input)
                .textFieldStyle(.hero)
                .onSubmit(submit)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.hero(.tertiary))
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: submit)
                    .buttonStyle(.hero(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(Hero.overlay)
    }

    private func submit() {
        guard let target else { return }
        dismiss()
        go(target.line, target.column)
    }
}

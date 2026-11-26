import SwiftUI
import FolioKit

/// Ln/Col, selection, counts and JSON status on the left; language, indentation, encoding
/// and line endings on the right, each a menu that changes it.
struct CodeStatusBar: View {
    @ObservedObject var document: CodeDocument
    let controller: EditorController

    var body: some View {
        StatusBar {
            Text("Ln \(controller.caretLine + 1), Col \(controller.caretColumn)")
                .accessibilityLabel("Line \(controller.caretLine + 1), column \(controller.caretColumn)")
            if controller.selectionLength > 0 {
                Text("\(controller.selectionLength.formatted()) selected")
            }
            Text("\(controller.wordCount.formatted()) words · \(controller.characterCount.formatted()) characters")
            jsonStatus
            Spacer(minLength: 8)
            StatusMenu(title: document.language.title, help: "Language") {
                Picker("Language", selection: $document.language) {
                    ForEach(Language.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
            StatusMenu(title: document.indent.title, help: "Indentation") {
                Picker("Indentation", selection: Binding(get: { document.indent }, set: { controller.setIndent($0) })) {
                    ForEach(IndentStyle.choices, id: \.self) { style in
                        Text(style.usesTabs ? "Tabs" : "\(style.width) spaces").tag(style)
                    }
                }
                .pickerStyle(.inline)
            }
            StatusMenu(title: document.format.encoding.title, help: "Encoding used when saving") {
                Picker("Save with encoding", selection: Binding(get: { document.format.encoding }, set: { controller.setEncoding($0) })) {
                    ForEach(TextEncoding.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
            StatusMenu(title: document.format.lineEnding.title, help: "Line endings used when saving") {
                Picker("Line endings", selection: Binding(get: { document.format.lineEnding }, set: { controller.setLineEnding($0) })) {
                    ForEach(LineEnding.allCases) { Text($0.detail).tag($0) }
                }
                .pickerStyle(.inline)
            }
        }
    }

    @ViewBuilder private var jsonStatus: some View {
        if document.language == .json {
            if let issue = controller.jsonIssue {
                Button { controller.reveal(issue) } label: {
                    Label(issue.description, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Hero.danger)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Go to the error")
            } else if controller.jsonChecked {
                Label("Valid JSON", systemImage: "checkmark.circle")
            }
        }
    }
}

/// A status-bar item that opens a menu: plain muted text, like the rest of the bar.
private struct StatusMenu<Content: View>: View {
    let title: String
    let help: String
    @ViewBuilder let content: Content

    @State private var hovered = false

    var body: some View {
        Menu { content } label: {
            Text(title)
                .foregroundStyle(hovered ? Hero.foreground : Hero.muted)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel("\(help): \(title)")
    }
}

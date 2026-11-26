public import SwiftUI

/// The Text menu: every code-editor command with its shortcut, so they're discoverable and
/// reachable by keyboard and VoiceOver. Mount with `.commands { CodeCommands() }`.
///
/// Items are disabled unless a code editor window is focused. The same shortcuts also work
/// inside the editor when this isn't mounted (see `CodeTextView.performKeyEquivalent`).
public struct CodeCommands: Commands {
    @FocusedValue(\.codeEditor) private var editor
    @AppStorage(EditorSettings.Key.wrapLines) private var wrapLines = true
    @AppStorage(EditorSettings.Key.showLineNumbers) private var showLineNumbers = true
    @AppStorage(EditorSettings.Key.showInvisibles) private var showInvisibles = false

    public init() {}

    public var body: some Commands {
        CommandMenu("Text") {
            Group {
                Button("Toggle Comment") { editor?.toggleComment() }
                    .keyboardShortcut("/", modifiers: .command)
                Button("Indent") { editor?.indent() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Outdent") { editor?.outdent() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Move Line Up") { editor?.moveLines(up: true) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Move Line Down") { editor?.moveLines(up: false) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Duplicate Line") { editor?.duplicateLines() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Go to Line…") { editor?.showGoToLine() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Find and Replace with Pattern…") { editor?.showFindReplace() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
            }
            .disabled(editor == nil)

            Divider()
            Group {
                Button("Bold") { editor?.bold() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Italic") { editor?.italic() }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Link…") { editor?.insertLink() }
                    .keyboardShortcut("k", modifiers: .command)
            }
            .disabled(editor?.language != .markdown)

            Group {
                Button("Format JSON") { editor?.formatJSON() }
                    .keyboardShortcut("f", modifiers: [.command, .option, .shift])
                Button("Minify JSON") { editor?.minifyJSON() }
                Button("Validate JSON") { editor?.validateJSON() }
            }
            .disabled(editor?.language != .json)

            Divider()
            Group {
                Toggle("Wrap Lines", isOn: $wrapLines)
                Toggle("Show Line Numbers", isOn: $showLineNumbers)
                Toggle("Show Invisibles", isOn: $showInvisibles)
                Button("Bigger") { editor?.zoom(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller") { editor?.zoom(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { editor?.resetZoom() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            .disabled(editor == nil)

            Divider()
            Menu("Export Markdown") {
                Button("HTML…") { editor?.export(.html) }
                Button("PDF…") { editor?.export(.pdf) }
                Button("Word Document…") { editor?.export(.docx) }
            }
            .disabled(editor?.language != .markdown)
            Button("Print…") { editor?.printDocument() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(editor == nil)
        }
    }
}

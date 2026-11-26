import AppKit
public import SwiftUI

/// Menu bar commands for the document editor: a Format menu mirroring the toolbar,
/// View items (outline, zoom, paper), Export, Print, and the system text commands
/// (Find, Spelling and Grammar, Substitutions, Transformations, Speech).
///
/// Mount once on the app's scenes: `.commands { DocumentCommands() }`. Items act on
/// the document editor in the key window and are disabled when there is none.
public struct DocumentCommands: Commands {
    @FocusedValue(\.documentEditor) private var editor

    public init() {}

    public var body: some Commands {
        TextEditingCommands()

        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                if let editor {
                    editor.print()
                } else {
                    // Other editors keep the standard document printing path.
                    NSApp.sendAction(#selector(NSDocument.printDocument(_:)), to: nil, from: nil)
                }
            }
            .keyboardShortcut("p")
        }

        CommandGroup(after: .importExport) {
            Menu("Export To") {
                ForEach(DocFormat.exportable) { format in
                    Button(format.title + "…") { editor?.export(format) }
                }
            }
            .disabled(editor == nil)
        }

        CommandGroup(after: .sidebar) {
            Button(editor?.showsOutline == true ? "Hide Outline" : "Show Outline") { editor?.showsOutline.toggle() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(editor == nil)
            Toggle("Wrap to Window", isOn: Binding(get: { editor?.wrapsToWindow ?? false }, set: { editor?.wrapsToWindow = $0 }))
                .disabled(editor == nil)
            Menu("Paper Size") {
                Button(PageSetup.Paper.letter.title) { editor?.setPaper(.letter) }
                Button(PageSetup.Paper.a4.title) { editor?.setPaper(.a4) }
            }
            .disabled(editor == nil)
            Divider()
            Button("Actual Size") { editor?.zoom = 1 }.keyboardShortcut("0").disabled(editor == nil)
            Button("Zoom In") { editor?.zoomIn() }.keyboardShortcut(">").disabled(editor == nil)
            Button("Zoom Out") { editor?.zoomOut() }.keyboardShortcut("<").disabled(editor == nil)
            Divider()
        }

        // Joins the system Format menu (one Format menu app-wide, shared with Spreadsheets).
        CommandGroup(after: .textFormatting) {
            Group {
                Menu("Font") {
                    Button("Show Fonts") { editor?.showFonts() }.keyboardShortcut("t")
                    Divider()
                    Button("Bold") { editor?.toggleBold() }.keyboardShortcut("b")
                    Button("Italic") { editor?.toggleItalic() }.keyboardShortcut("i")
                    Button("Underline") { editor?.toggleUnderline() }.keyboardShortcut("u")
                    Button("Strikethrough") { editor?.toggleStrikethrough() }.keyboardShortcut("x", modifiers: [.command, .shift])
                    Divider()
                    Button("Bigger") { editor?.biggerFont() }.keyboardShortcut("+")
                    Button("Smaller") { editor?.smallerFont() }.keyboardShortcut("-")
                    Divider()
                    Button("Superscript") { editor?.setBaseline(1) }.keyboardShortcut("=", modifiers: [.command, .control])
                    Button("Subscript") { editor?.setBaseline(-1) }.keyboardShortcut("-", modifiers: [.command, .control])
                    Divider()
                    Button("Show Colors") { editor?.showColors() }.keyboardShortcut("c", modifiers: [.command, .shift])
                }
                Menu("Paragraph Style") {
                    ForEach(TextStyle.allCases) { style in
                        styleButton(style)
                    }
                }
                Menu("Text") {
                    Button("Align Left") { editor?.setAlignment(.left) }.keyboardShortcut("{")
                    Button("Center") { editor?.setAlignment(.center) }.keyboardShortcut("|")
                    Button("Justify") { editor?.setAlignment(.justified) }
                    Button("Align Right") { editor?.setAlignment(.right) }.keyboardShortcut("}")
                    Divider()
                    Menu("Line Spacing") {
                        ForEach([1, 1.15, 1.5, 2] as [CGFloat], id: \.self) { value in
                            Button(String(format: "%g", Double(value))) { editor?.setLineSpacing(value) }
                        }
                    }
                    Divider()
                    Button("Increase Indent") { editor?.indent() }.keyboardShortcut("]")
                    Button("Decrease Indent") { editor?.outdent() }.keyboardShortcut("[")
                }
                Menu("Lists") {
                    Button(ListKind.bullet.title) { editor?.toggleList(.bullet) }.keyboardShortcut("8", modifiers: [.command, .shift])
                    Button(ListKind.numbered.title) { editor?.toggleList(.numbered) }.keyboardShortcut("7", modifiers: [.command, .shift])
                    Button(ListKind.checklist.title) { editor?.toggleList(.checklist) }.keyboardShortcut(
                        "9", modifiers: [.command, .shift])
                    Divider()
                    Button("Toggle Checkbox") { editor?.toggleCheckbox() }
                }
            }
            .disabled(editor == nil)

            Divider()

            Group {
                Menu("Insert") {
                    Button("Link…") { editor?.showsLinkEditor = true }.keyboardShortcut("k")
                    Button("Image…") { editor?.chooseImages() }
                    Menu("Table") {
                        ForEach([(2, 2), (3, 3), (4, 4), (3, 5)], id: \.1) { size in
                            Button("\(size.0) × \(size.1)") { editor?.insertTable(rows: size.0, columns: size.1) }
                        }
                    }
                    Divider()
                    Button("Horizontal Rule") { editor?.insertHorizontalRule() }
                    Button("Page Break") { editor?.insertPageBreak() }.keyboardShortcut(.return, modifiers: .command)
                }
                Menu("Table") {
                    Button("Add Row Above") { editor?.editTable(.rowAbove) }
                    Button("Add Row Below") { editor?.editTable(.rowBelow) }
                    Button("Add Column Left") { editor?.editTable(.columnLeft) }
                    Button("Add Column Right") { editor?.editTable(.columnRight) }
                    Divider()
                    Button("Delete Row") { editor?.editTable(.deleteRow) }
                    Button("Delete Column") { editor?.editTable(.deleteColumn) }
                    Button("Delete Table") { editor?.editTable(.deleteTable) }
                }
                .disabled(editor?.selection.inTable != true)
                Button("Remove Link") { editor?.removeLink() }
                    .disabled(editor?.selection.link == nil)
                Divider()
                Button("Copy Style") { editor?.copyStyle() }.keyboardShortcut("c", modifiers: [.command, .option])
                Button("Paste Style") { editor?.pasteStyle() }.keyboardShortcut("v", modifiers: [.command, .option])
                Button("Clear Formatting") { editor?.clearFormatting() }
            }
            .disabled(editor == nil)
        }
    }

    /// Title ⌥⌘1, Heading 1–3 ⌥⌘2–4, Body ⌥⌘0, like Pages' style shortcuts.
    @ViewBuilder private func styleButton(_ style: TextStyle) -> some View {
        let shortcut: KeyEquivalent? =
            switch style {
            case .title: "1"
            case .heading1: "2"
            case .heading2: "3"
            case .heading3: "4"
            case .body: "0"
            default: nil
            }
        if let shortcut {
            Button(style.name) { editor?.applyStyle(style) }.keyboardShortcut(shortcut, modifiers: [.command, .option])
        } else {
            Button(style.name) { editor?.applyStyle(style) }
        }
    }
}

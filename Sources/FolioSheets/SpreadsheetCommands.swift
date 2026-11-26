public import SwiftUI

/// Insert, Format and Data menu commands for the spreadsheet editor in the key window.
/// Mount in the app's scene: `.commands { SpreadsheetCommands() }`.
///
/// Bold/Italic/Underline (⌘B/⌘I/⌘U) and Fill Down/Right (⌘D/⌘R) are also handled by
/// the grid itself, so they work even where another editor's menus claim the same keys.
public struct SpreadsheetCommands: Commands {
    @FocusedValue(\.spreadsheet) private var sheet

    public init() {}

    public var body: some Commands {
        CommandMenu("Insert") {
            Button("Row Above") { sheet?.insertRows(above: true) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Row Below") { sheet?.insertRows(above: false) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Column Left") { sheet?.insertColumns(left: true) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Column Right") { sheet?.insertColumns(left: false) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Divider()
            Button("Sheet") { sheet?.addSheet() }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
            Button("Chart") { sheet?.insertChart() }
        }

        CommandGroup(after: .textFormatting) {
            Menu("Cells") {
                Button("Bold") { sheet?.toggleBold() }
                Button("Italic") { sheet?.toggleItalic() }
                Button("Underline") { sheet?.toggleUnderline() }
                Divider()
                Button("Align Left") { sheet?.setAlignment(.left) }
                Button("Center") { sheet?.setAlignment(.center) }
                Button("Align Right") { sheet?.setAlignment(.right) }
                Divider()
                ForEach(NumberFormat.allCases, id: \.self) { f in
                    Button(f.title) { sheet?.setNumberFormat(f) }
                }
                Divider()
                Button("Clear Formatting") { sheet?.clearFormatting() }
            }
            .disabled(sheet == nil)
        }

        CommandMenu("Data") {
            Button("Sort Ascending") { sheet?.sort(ascending: true) }
            Button("Sort Descending") { sheet?.sort(ascending: false) }
            Divider()
            Button("Fill Down") { sheet?.fill(.down) }
                .keyboardShortcut("d")
            Button("Fill Right") { sheet?.fill(.right) }
                .keyboardShortcut("r")
            Divider()
            Button("Delete Row") { sheet?.deleteRows() }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
            Button("Delete Column") { sheet?.deleteColumns() }
            Divider()
            Button(sheet?.isHeaderRowFrozen == true ? "Unfreeze Header Row" : "Freeze Header Row") { sheet?.toggleFrozenHeaderRow() }
            Button("Find and Replace…") { sheet?.showFind = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }
    }
}

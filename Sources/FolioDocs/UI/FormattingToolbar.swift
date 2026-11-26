import AppKit
import FolioKit
import SwiftUI

/// The floating HeroUI formatting toolbar above the paper.
///
/// Ghost icon buttons with tooltips (DESIGN.md "Toolbars"), menus for choices with
/// more than two options. As the window narrows, less-used controls move into a
/// "More" menu, and in the narrowest windows the pill scrolls sideways.
struct FormattingToolbar: View {
    let controller: DocumentEditorController

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HeroToolbar { full }.fixedSize()
            HeroToolbar { medium }.fixedSize()
            HeroToolbar { compact }.fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HeroToolbar { compact }.fixedSize().padding(.vertical, 16).padding(.horizontal, 2)
            }
            .padding(.vertical, -16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Formatting")
    }

    private var s: SelectionState { controller.selection }

    @ViewBuilder private var full: some View {
        StyleMenu(controller: controller)
        HeroToolbarDivider()
        FontFamilyMenu(family: s.fontFamily) { controller.setFontFamily($0) }.equatable()
        FontSizeMenu(size: s.fontSize) { controller.setFontSize($0) }
        HeroToolbarDivider()
        characterButtons
        baselineButtons
        ColorButtons(controller: controller)
        HeroToolbarDivider()
        AlignmentMenu(controller: controller)
        LineSpacingMenu(controller: controller)
        HeroToolbarDivider()
        listButtons
        indentButtons
        HeroToolbarDivider()
        InsertButtons(controller: controller)
        contextual
        HeroToolbarDivider()
        tool("Clear Formatting", "eraser", selected: false) { controller.clearFormatting() }
        moreMenu
    }

    /// Full minus super/subscript, line spacing, indents and Clear, which move to More.
    @ViewBuilder private var medium: some View {
        StyleMenu(controller: controller)
        HeroToolbarDivider()
        FontFamilyMenu(family: s.fontFamily) { controller.setFontFamily($0) }.equatable()
        FontSizeMenu(size: s.fontSize) { controller.setFontSize($0) }
        HeroToolbarDivider()
        characterButtons
        ColorButtons(controller: controller)
        HeroToolbarDivider()
        AlignmentMenu(controller: controller)
        listButtons
        HeroToolbarDivider()
        InsertButtons(controller: controller)
        contextual
        moreMenu
    }

    @ViewBuilder private var compact: some View {
        StyleMenu(controller: controller)
        HeroToolbarDivider()
        characterButtons
        ColorButtons(controller: controller)
        HeroToolbarDivider()
        AlignmentMenu(controller: controller)
        listButtons
        HeroToolbarDivider()
        InsertButtons(controller: controller)
        contextual
        moreMenu
    }

    private var moreMenu: some View {
        Menu {
            Button("Superscript") { controller.setBaseline(1) }
            Button("Subscript") { controller.setBaseline(-1) }
            Divider()
            Menu("Line Spacing") {
                ForEach([1, 1.15, 1.5, 2] as [CGFloat], id: \.self) { value in
                    Button(String(format: "%g", Double(value))) { controller.setLineSpacing(value) }
                }
            }
            Button("Indent") { controller.indent() }
            Button("Outdent") { controller.outdent() }
            Divider()
            Button("Copy Style") { controller.copyStyle() }
            Button("Paste Style") { controller.pasteStyle() }
            Divider()
            Button("Show Fonts") { controller.showFonts() }
            Button("Clear Formatting") { controller.clearFormatting() }
        } label: {
            Label("More Formatting", systemImage: "ellipsis")
        }
        .heroToolbarMenu(iconOnly: true)
        .help("More formatting")
    }

    @ViewBuilder private var characterButtons: some View {
        tool("Bold", "bold", selected: s.bold, shortcut: "⌘B") { controller.toggleBold() }
        tool("Italic", "italic", selected: s.italic, shortcut: "⌘I") { controller.toggleItalic() }
        tool("Underline", "underline", selected: s.underline, shortcut: "⌘U") { controller.toggleUnderline() }
        tool("Strikethrough", "strikethrough", selected: s.strikethrough, shortcut: "⇧⌘X") { controller.toggleStrikethrough() }
    }

    @ViewBuilder private var baselineButtons: some View {
        tool("Superscript", "textformat.superscript", selected: s.baseline > 0, shortcut: "⌃⌘=") { controller.setBaseline(1) }
        tool("Subscript", "textformat.subscript", selected: s.baseline < 0, shortcut: "⌃⌘-") { controller.setBaseline(-1) }
    }

    @ViewBuilder private var listButtons: some View {
        ForEach(ListKind.allCases, id: \.self) { kind in
            tool(kind.title, kind.symbol, selected: s.list == kind) { controller.toggleList(kind) }
        }
    }

    @ViewBuilder private var indentButtons: some View {
        tool("Outdent", "decrease.indent", selected: false, shortcut: "⌘[") { controller.outdent() }
        tool("Indent", "increase.indent", selected: false, shortcut: "⌘]") { controller.indent() }
    }

    /// Table and image controls appear only when they apply.
    @ViewBuilder private var contextual: some View {
        if s.inTable { TableMenu(controller: controller) }
        if s.imageSelected { ImageSizeMenu(controller: controller) }
    }

    private func tool(_ title: String, _ symbol: String, selected: Bool, shortcut: String? = nil, action: @escaping () -> Void) -> some View
    {
        ToolbarIconButton(title: title, symbol: symbol, selected: selected, shortcut: shortcut, action: action)
    }
}

/// A ghost icon button: the DESIGN.md toolbar control.
struct ToolbarIconButton: View {
    let title: String
    let symbol: String
    var selected = false
    var shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true, isSelected: selected))
            .help(shortcut.map { "\(title) \($0)" } ?? title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    /// A `Menu` drawn as a ghost toolbar button.
    func heroToolbarMenu(iconOnly: Bool = false) -> some View {
        self.menuStyle(.button)
            .menuIndicator(iconOnly ? .hidden : .visible)
            .buttonStyle(.hero(.ghost, size: .sm, iconOnly: iconOnly))
            .fixedSize()
    }
}

// MARK: - Menus

private struct StyleMenu: View {
    let controller: DocumentEditorController
    var body: some View {
        Menu {
            ForEach(TextStyle.allCases) { style in
                Button {
                    controller.applyStyle(style)
                } label: {
                    if controller.selection.style == style { Label(style.name, systemImage: "checkmark") } else { Text(style.name) }
                }
            }
        } label: {
            Text(controller.selection.style.name).frame(width: 76, alignment: .leading)
        }
        .heroToolbarMenu()
        .help("Paragraph style")
        .accessibilityLabel("Paragraph style")
        .accessibilityValue(controller.selection.style.name)
    }
}

/// Separate view so the long family list is rebuilt only when the family changes.
private struct FontFamilyMenu: View, Equatable {
    let family: String
    let choose: (String) -> Void

    static func == (a: Self, b: Self) -> Bool { a.family == b.family }

    var body: some View {
        Menu {
            ForEach(Self.families, id: \.self) { name in
                Button(name) { choose(name) }
            }
        } label: {
            Text(family).lineLimit(1).frame(width: 96, alignment: .leading)
        }
        .heroToolbarMenu()
        .help("Font")
        .accessibilityLabel("Font")
        .accessibilityValue(family)
    }

    private static let families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
}

private struct FontSizeMenu: View {
    let size: CGFloat
    let choose: (CGFloat) -> Void
    private static let sizes: [CGFloat] = [8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72, 96]

    var body: some View {
        Menu {
            ForEach(Self.sizes, id: \.self) { s in
                Button(String(format: "%g", Double(s))) { choose(s) }
            }
        } label: {
            Text(String(format: "%g", Double(size))).monospacedDigit().frame(width: 22)
        }
        .heroToolbarMenu()
        .help("Font size")
        .accessibilityLabel("Font size")
        .accessibilityValue("\(String(format: "%g", Double(size))) points")
    }
}

private struct AlignmentMenu: View {
    let controller: DocumentEditorController
    private static let options: [(NSTextAlignment, String, String)] = [
        (.left, "Align Left", "text.alignleft"), (.center, "Center", "text.aligncenter"),
        (.right, "Align Right", "text.alignright"), (.justified, "Justify", "text.justify"),
    ]

    var body: some View {
        let current = controller.selection.alignment
        let symbol = Self.options.first { $0.0 == current }?.2 ?? "text.alignleft"
        Menu {
            ForEach(Self.options, id: \.1) { option in
                Button {
                    controller.setAlignment(option.0)
                } label: {
                    Label(option.1, systemImage: option.2)
                }
            }
        } label: {
            Label("Alignment", systemImage: symbol)
        }
        .heroToolbarMenu(iconOnly: true)
        .help("Alignment")
    }
}

private struct LineSpacingMenu: View {
    let controller: DocumentEditorController
    private static let options: [CGFloat] = [1, 1.15, 1.5, 2]

    var body: some View {
        Menu {
            ForEach(Self.options, id: \.self) { value in
                Button {
                    controller.setLineSpacing(value)
                } label: {
                    let title = String(format: "%g", Double(value))
                    if abs(controller.selection.lineSpacing - value) < 0.01 { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            Label("Line Spacing", systemImage: "arrow.up.and.down.text.horizontal")
        }
        .heroToolbarMenu(iconOnly: true)
        .help("Line spacing")
    }
}

private struct TableMenu: View {
    let controller: DocumentEditorController
    var body: some View {
        Menu {
            Button("Add Row Above") { controller.editTable(.rowAbove) }
            Button("Add Row Below") { controller.editTable(.rowBelow) }
            Button("Add Column Left") { controller.editTable(.columnLeft) }
            Button("Add Column Right") { controller.editTable(.columnRight) }
            Divider()
            Button("Delete Row") { controller.editTable(.deleteRow) }
            Button("Delete Column") { controller.editTable(.deleteColumn) }
            Button("Delete Table", role: .destructive) { controller.editTable(.deleteTable) }
        } label: {
            Label("Table", systemImage: "tablecells.badge.ellipsis")
        }
        .heroToolbarMenu(iconOnly: true)
        .help("Table rows and columns")
    }
}

private struct ImageSizeMenu: View {
    let controller: DocumentEditorController
    var body: some View {
        Menu {
            ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                Button("\(Int(fraction * 100))% of Text Width") { controller.setImageWidth(fraction) }
            }
            Divider()
            Button("Original Size") { controller.setImageWidth(nil) }
        } label: {
            Label("Image Size", systemImage: "photo.badge.arrow.down")
        }
        .heroToolbarMenu(iconOnly: true)
        .help("Image size")
    }
}

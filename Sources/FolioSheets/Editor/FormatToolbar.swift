import FolioKit
import SwiftUI

/// The formatting bar above the grid: Hero ghost icon buttons, grouped by divider.
struct FormatToolbar: View {
    let controller: SheetController
    @State private var showFill = false
    @State private var showText = false

    var body: some View {
        let style = activeStyle
        HStack(spacing: 2) {
            toggle("Bold", "bold", "⌘B", style.bold) { controller.toggleBold() }
            toggle("Italic", "italic", "⌘I", style.italic) { controller.toggleItalic() }
            toggle("Underline", "underline", "⌘U", style.underline) { controller.toggleUnderline() }
            HeroToolbarDivider()
            toggle("Align Left", "text.alignleft", nil, style.alignment == .left) { controller.setAlignment(.left) }
            toggle("Center", "text.aligncenter", nil, style.alignment == .center) { controller.setAlignment(.center) }
            toggle("Align Right", "text.alignright", nil, style.alignment == .right) { controller.setAlignment(.right) }
            HeroToolbarDivider()
            colorButton("Fill Color", symbol: "paintbrush", current: style.fill, isPresented: $showFill) { controller.setFill($0) }
            colorButton("Text Color", symbol: "textformat", current: style.textColor, isPresented: $showText) {
                controller.setTextColor($0)
            }
            numberFormatMenu(style.numberFormat)
            icon("Clear Formatting", "eraser") { controller.clearFormatting() }
            HeroToolbarDivider()
            tableMenu
            sortMenu
            toggle("Freeze Header Row", "rectangle.topthird.inset.filled", nil, isFrozen) { controller.toggleFrozenHeaderRow() }
            Spacer(minLength: 8)
            icon("Find and Replace", "magnifyingglass", help: "Find and Replace ⌘F") { controller.showFind.toggle() }
            toggle("Chart", "chart.bar.xaxis", nil, controller.chart != nil) {
                controller.chart == nil ? controller.insertChart() : (controller.chart = nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Hero.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Hero.separator).frame(height: 1) }
    }

    private var activeStyle: CellStyle {
        _ = controller.revision
        return controller.activeStyle
    }

    private var isFrozen: Bool {
        _ = controller.revision
        return controller.isHeaderRowFrozen
    }

    private func toggle(_ title: String, _ symbol: String, _ shortcut: String?, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true, isSelected: on))
            .help(shortcut.map { "\(title) \($0)" } ?? title)
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func icon(_ title: String, _ symbol: String, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
            .help(help ?? title)
    }

    private func colorButton(
        _ title: String, symbol: String, current: RGBColor?, isPresented: Binding<Bool>, pick: @escaping (RGBColor?) -> Void
    ) -> some View {
        Button {
            isPresented.wrappedValue.toggle()
        } label: {
            Label {
                Text(title)
            } icon: {
                ZStack(alignment: .bottom) {
                    Image(systemName: symbol)
                    // A bar under the icon shows the current colour.
                    Capsule()
                        .fill(current.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Color.clear)
                        .frame(width: 14, height: 3)
                        .offset(y: 5)
                }
            }
        }
        .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
        .help(title)
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            SwatchGrid(title: title, current: current) { color in
                pick(color)
                isPresented.wrappedValue = false
            }
        }
    }

    private func numberFormatMenu(_ current: NumberFormat) -> some View {
        Menu {
            ForEach(NumberFormat.allCases, id: \.self) { f in
                Button {
                    controller.setNumberFormat(f)
                } label: {
                    if f == current { Label(f.title, systemImage: "checkmark") } else { Text(f.title) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current.title)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Hero.foreground)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Hero.default, in: .capsule)
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Number Format")
        .accessibilityLabel("Number Format: \(current.title)")
        .padding(.horizontal, 4)
    }

    private var tableMenu: some View {
        Menu {
            Button("Insert Row Above") { controller.insertRows(above: true) }
            Button("Insert Row Below") { controller.insertRows(above: false) }
            Button("Insert Column Left") { controller.insertColumns(left: true) }
            Button("Insert Column Right") { controller.insertColumns(left: false) }
            Divider()
            Button("Delete Row") { controller.deleteRows() }
            Button("Delete Column") { controller.deleteColumns() }
        } label: {
            Label("Rows and Columns", systemImage: "tablecells.badge.ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Rows and Columns")
    }

    private var sortMenu: some View {
        Menu {
            Button("Sort Ascending") { controller.sort(ascending: true) }
            Button("Sort Descending") { controller.sort(ascending: false) }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort by the selected column")
    }
}

/// A palette of fill/text colours in a Hero popover.
struct SwatchGrid: View {
    let title: String
    let current: RGBColor?
    let pick: (RGBColor?) -> Void

    /// Soft tints for fills plus strong colours for text; readable in light and dark.
    static let palette: [UInt32] = [
        0x18181B, 0x71717A, 0xA1A1AA, 0xE4E4E7, 0xFFFFFF, 0x0485F7, 0x17C964, 0xF5A524,
        0xFF383C, 0x9353D3, 0xDBEAFE, 0xDCFCE7, 0xFEF3C7, 0xFEE2E2, 0xF3E8FF, 0xFCE7F3,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Hero.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 8), spacing: 6) {
                ForEach(Self.palette, id: \.self) { hex in
                    let color = RGBColor(hex: hex)
                    Button {
                        pick(color)
                    } label: {
                        Circle()
                            .fill(Color(red: color.red, green: color.green, blue: color.blue))
                            .overlay(Circle().strokeBorder(Hero.border))
                            .overlay {
                                if current == color {
                                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(color.isLight ? Color.black : .white)
                                }
                            }
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("#\(color.hexString)"))
                }
            }
            Button("None") { pick(nil) }
                .buttonStyle(.hero(.tertiary, size: .sm, fullWidth: true))
        }
        .padding(16)
        .frame(width: 236)
    }
}

extension RGBColor {
    /// Whether dark marks read better on this colour (perceived luminance).
    var isLight: Bool { 0.299 * red + 0.587 * green + 0.114 * blue > 0.6 }
}
